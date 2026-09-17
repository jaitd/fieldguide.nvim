// Does the pi extension load, register the verbs as tools, and wire the hooks?
//
//   node --test tests/extension.test.ts
//
// Without this, "the extension is broken" is only discoverable by a user who
// has already configured a provider and opened the sidebar.
//
// The extension imports `typebox` and pi's own types, which live inside pi's
// install rather than this repo — there is no npm install here, by design
//. So the test resolves them the way pi's launcher does, through jiti,
// and skips itself with a readable reason when pi is not installed.

import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EXTENSION = path.join(HERE, "..", "extension", "nvim.ts");

/** pi's launcher exports a NODE_PATH naming its private module directories. */
function piModulePaths(): string[] {
  // `command -v` exits non-zero when pi is absent, and execFileSync turns a
  // non-zero exit into a throw. Without this the "skips itself" promise above
  // is only kept on machines that do have pi — the Linux container has none.
  let launcher = "";
  try {
    launcher = execFileSync("sh", ["-c", "command -v pi"], { encoding: "utf8" }).trim();
  } catch {
    return [];
  }
  if (!launcher) return [];
  const source = readFileSync(launcher, "utf8");
  const match = source.match(/NODE_PATH="([^"]+)"/);
  return match ? match[1].split(":").filter(Boolean) : [];
}

type StubTool = {
  name: string;
  description: string;
  parameters: unknown;
  execute: (...args: unknown[]) => Promise<unknown>;
};

type Handler = (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<unknown>;

async function loadExtension(env: Record<string, string>) {
  const modulePaths = piModulePaths();
  if (modulePaths.length === 0) return null;

  const require = createRequire(path.join(modulePaths[0], "index.js"));
  let createJiti: (id: string, opts?: unknown) => { import: (id: string) => Promise<unknown> };
  try {
    createJiti = require("jiti").createJiti;
  } catch {
    return null;
  }

  const previous: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(env)) {
    previous[key] = process.env[key];
    process.env[key] = value;
  }

  const jiti = createJiti(EXTENSION, {
    alias: { typebox: require.resolve("typebox") },
    moduleCache: false,
  });

  try {
    const mod = (await jiti.import(EXTENSION)) as { default: (pi: unknown) => void };
    const tools = new Map<string, StubTool>();
    const handlers = new Map<string, Handler[]>();

    const pi = {
      registerTool: (t: StubTool) => tools.set(t.name, t),
      on: (name: string, fn: Handler) => {
        handlers.set(name, [...(handlers.get(name) ?? []), fn]);
      },
      registerCommand: () => {},
      exec: async () => ({ stdout: "", stderr: "", code: 0 }),
    };

    mod.default(pi);
    return { tools, handlers };
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

const SKIP = { skip: "pi is not installed, so its typebox/jiti are unavailable" };

test("pi extension", async (t) => {
  const root = await realpath(await mkdtemp(path.join(tmpdir(), "fieldguide-ext-")));
  const configRoot = path.join(root, "config");
  const docRoot = path.join(root, "docs");
  await mkdir(configRoot, { recursive: true });
  await mkdir(docRoot, { recursive: true });
  await writeFile(path.join(configRoot, "init.lua"), "-- x\n");

  const loaded = await loadExtension({
    FIELDGUIDE_CONFIG_DIR: configRoot,
    FIELDGUIDE_DOC_ROOTS: docRoot,
    FIELDGUIDE_VERBS: "state,docs,explain_keymap,verify,reload",
    FIELDGUIDE_BIN: "/nonexistent/fieldguide",
    FIELDGUIDE_ADDR: "/nonexistent.sock",
  });

  if (!loaded) {
    await rm(root, { recursive: true, force: true });
    // The test image installs pi, so a skip there means the install broke.
    if (process.env.FIELDGUIDE_TEST_REQUIRE_PI) assert.fail(SKIP.skip);
    t.skip(SKIP.skip);
    return;
  }
  const { tools, handlers } = loaded;

  await t.test("registers one tool per enabled verb", () => {
    assert.deepEqual(
      [...tools.keys()].sort(),
      ["nvim_docs", "nvim_explain_keymap", "nvim_reload", "nvim_state", "nvim_verify"],
    );
  });

  await t.test("the index tools stay away when there is no index", () => {
    // Not an error and not a warning: most machines will never have one, and
    // the agent should be offered nothing it cannot use.
    assert.ok(!tools.has("nvim_plugins"));
    assert.ok(!tools.has("nvim_plugin"));
  });

  await t.test("...and appear when there is one", async () => {
    const db = path.join(root, "index.db");
    const sqlite = new DatabaseSync(db);
    sqlite.exec("create table meta (key text primary key, value text)");
    // The schema row is what the extension checks: the index is released on its
    // own track, so an unrecognised one must register no tools at all.
    sqlite.prepare("insert into meta values (?,?)").run("schema", "1.0.0");
    sqlite.close();

    const withIndex = await loadExtension({
      FIELDGUIDE_CONFIG_DIR: configRoot,
      FIELDGUIDE_DOC_ROOTS: docRoot,
      FIELDGUIDE_VERBS: "state",
      FIELDGUIDE_BIN: "/nonexistent/fieldguide",
      FIELDGUIDE_ADDR: "/nonexistent.sock",
      FIELDGUIDE_PLUGIN_INDEX: db,
    });
    assert.ok(withIndex);
    assert.ok(withIndex.tools.has("nvim_plugins"));
    assert.ok(withIndex.tools.has("nvim_plugin"));
  });

  await t.test("...but not from an index this build cannot read", async () => {
    const stale = path.join(root, "stale.db");
    const sqlite = new DatabaseSync(stale);
    sqlite.exec("create table meta (key text primary key, value text)");
    sqlite.prepare("insert into meta values (?,?)").run("schema", "9.0.0");
    sqlite.close();

    const loaded2 = await loadExtension({
      FIELDGUIDE_CONFIG_DIR: configRoot,
      FIELDGUIDE_DOC_ROOTS: docRoot,
      FIELDGUIDE_VERBS: "state",
      FIELDGUIDE_BIN: "/nonexistent/fieldguide",
      FIELDGUIDE_ADDR: "/nonexistent.sock",
      FIELDGUIDE_PLUGIN_INDEX: stale,
    });
    assert.ok(loaded2);
    assert.ok(!loaded2.tools.has("nvim_plugins"), "a mismatched index must offer nothing");
  });

  await t.test("every tool describes itself to the model", () => {
    for (const [name, tool] of tools) {
      assert.ok(tool.description.length > 60, `${name} needs a real description`);
      assert.ok(tool.parameters, `${name} needs a parameter schema`);
    }
  });

  await t.test("hooks are wired for the gate and for auto-verify", () => {
    assert.ok(handlers.get("tool_call")?.length, "no tool_call handler: the path gate is not installed");
    assert.ok(handlers.get("tool_result")?.length, "no tool_result handler: auto-verify is not installed");
  });

  await t.test("the gate is reachable through the hook", async () => {
    const gate = handlers.get("tool_call")![0];
    const ctx = { cwd: configRoot };

    const allowed = await gate({ toolName: "read", input: { path: "init.lua" } }, ctx);
    assert.equal(allowed, undefined, "a read inside the config tree must pass through");

    const blocked = (await gate({ toolName: "read", input: { path: "/etc/passwd" } }, ctx)) as {
      block?: boolean;
      reason?: string;
    };
    assert.equal(blocked?.block, true);
    assert.match(blocked!.reason!, /outside fieldguide's zones/);

    const shell = (await gate({ toolName: "bash", input: { command: "id" } }, ctx)) as { block?: boolean };
    assert.equal(shell?.block, true, "bash must be refused at the hook too");
  });

  await t.test("auto-verify ignores writes outside the config tree", async () => {
    const onResult = handlers.get("tool_result")![0];
    const patch = await onResult(
      { toolName: "write", input: { path: path.join(root, "elsewhere.lua") }, content: [], isError: false },
      { cwd: configRoot, signal: undefined },
    );
    assert.equal(patch, undefined);
  });

  await t.test("auto-verify ignores failed writes", async () => {
    const onResult = handlers.get("tool_result")![0];
    const patch = await onResult(
      { toolName: "write", input: { path: "init.lua" }, content: [], isError: true },
      { cwd: configRoot, signal: undefined },
    );
    assert.equal(patch, undefined);
  });

  await t.test("a write inside the tree reports rather than throwing when nvim is gone", async () => {
    const onResult = handlers.get("tool_result")![0];
    const patch = (await onResult(
      { toolName: "write", input: { path: "init.lua" }, content: [{ type: "text", text: "wrote" }], isError: false },
      { cwd: configRoot, signal: undefined },
    )) as { content: { text: string }[] };
    assert.ok(patch, "a write inside the config tree must be annotated");
    const appended = patch.content.at(-1)!.text;
    assert.match(appended, /fieldguide/);
  });

  await t.test("a wedged editor costs one tool call, not the session", async () => {
    // A stand-in for an nvim that never returns — a confirm() prompt nobody
    // answered, or a socket that accepts and then goes quiet. It has to ignore
    // its arguments, which `sleep` will not.
    const stub = path.join(root, "stub-nvim");
    await writeFile(stub, "#!/bin/sh\nsleep 30\n", { mode: 0o755 });

    const stalled = await loadExtension({
      FIELDGUIDE_CONFIG_DIR: configRoot,
      FIELDGUIDE_DOC_ROOTS: docRoot,
      FIELDGUIDE_VERBS: "state",
      FIELDGUIDE_BIN: "/dev/null",
      FIELDGUIDE_NVIM: stub,
      FIELDGUIDE_ADDR: "/nonexistent.sock",
      FIELDGUIDE_CALL_TIMEOUT_MS: "700",
    });
    const tool = stalled!.tools.get("nvim_state")!;
    const started = Date.now();
    await assert.rejects(
      () => tool.execute("id", {}, undefined, undefined, { cwd: configRoot }) as Promise<unknown>,
      /did not return within/,
    );
    assert.ok(Date.now() - started < 5000, "the timeout must fire well before the harness gives up");
  });

  await t.test("a disabled verb registers no tool", async () => {
    const narrowed = await loadExtension({
      FIELDGUIDE_CONFIG_DIR: configRoot,
      FIELDGUIDE_DOC_ROOTS: docRoot,
      FIELDGUIDE_VERBS: "state,docs",
      FIELDGUIDE_BIN: "/nonexistent/fieldguide",
      FIELDGUIDE_ADDR: "/nonexistent.sock",
    });
    assert.deepEqual([...narrowed!.tools.keys()].sort(), ["nvim_docs", "nvim_state"]);
  });

  await rm(root, { recursive: true, force: true });
});

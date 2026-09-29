// The MCP server: the verbs, offered to harnesses that are not pi.
//
//   node --test tests/mcp.test.ts
//
// Drives `extension/mcp.ts` as a subprocess over stdio, the way a harness
// does. The calls that reach Neovim go to a real headless instance with every
// XDG directory pointed into a temp dir, so a checkpoint here can never land in
// the shadow repo of the config you actually use.

import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { createRequire } from "node:module";
import { existsSync, readFileSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { after, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, "..");
const SERVER = path.join(ROOT, "extension", "mcp.ts");
const ALL_VERBS = "state,docs,explain_keymap,verify,reload";

type Json = Record<string, any>;

/** A harness's side of the conversation: one request, one matching response. */
class Client {
  private proc: ChildProcess;
  private buffer = "";
  private waiting = new Map<unknown, (message: Json) => void>();
  private nextId = 1;
  readonly received: Json[] = [];
  readonly exited: Promise<number | null>;

  constructor(env: Record<string, string>, cwd = ROOT) {
    this.proc = spawn(process.execPath, [SERVER], {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc.stdout!.setEncoding("utf8");
    this.proc.stdout!.on("data", (chunk: string) => {
      this.buffer += chunk;
      let nl: number;
      while ((nl = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, nl);
        this.buffer = this.buffer.slice(nl + 1);
        const message = JSON.parse(line) as Json;
        this.received.push(message);
        this.waiting.get(message.id)?.(message);
        this.waiting.delete(message.id);
      }
    });
    this.exited = new Promise((resolve) => this.proc.on("close", (code) => resolve(code)));
  }

  raw(line: string) {
    this.proc.stdin!.write(line + "\n");
  }

  /** Resolves with the whole response envelope, so tests can see error vs result. */
  request(method: string, params?: Json, timeoutMs = 30_000): Promise<Json> {
    const id = this.nextId++;
    return this.requestWithId(id, method, params, timeoutMs);
  }

  requestWithId(id: unknown, method: string, params?: Json, timeoutMs = 30_000): Promise<Json> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no response to ${method} #${id}`)), timeoutMs);
      // A cancelled request is never answered; its timer must not hold the
      // test process open for the full timeout.
      timer.unref();
      this.waiting.set(id, (message) => {
        clearTimeout(timer);
        resolve(message);
      });
      this.raw(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  notify(method: string, params?: Json) {
    this.raw(JSON.stringify({ jsonrpc: "2.0", method, params }));
  }

  async initialize() {
    const res = await this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "test", version: "0" },
    });
    this.notify("notifications/initialized");
    return res;
  }

  close() {
    this.proc.stdin!.end();
    return this.exited;
  }

  kill() {
    this.proc.kill("SIGKILL");
  }
}

function hookRun(args: string[], env: Record<string, string>, cwd: string) {
  return new Promise<{ code: number | null; stdout: string; stderr: string }>((resolve) => {
    const child = spawn(process.execPath, [SERVER, ...args], {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (d: string) => (stdout += d));
    child.stderr.setEncoding("utf8").on("data", (d: string) => (stderr += d));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

let root = "";
let configRoot = "";
let docRoot = "";
let base: Record<string, string> = {};

before(async () => {
  root = await realpath(await mkdtemp(path.join(tmpdir(), "fieldguide-mcp-")));
  configRoot = path.join(root, "config", "nvim");
  docRoot = path.join(root, "docs");
  await mkdir(configRoot, { recursive: true });
  await mkdir(docRoot, { recursive: true });
  await writeFile(path.join(configRoot, "init.lua"), "vim.g.mcp_fixture = 1\n");
  base = {
    FIELDGUIDE_CONFIG_DIR: configRoot,
    FIELDGUIDE_DOC_ROOTS: docRoot,
    FIELDGUIDE_VERBS: ALL_VERBS,
    FIELDGUIDE_ADDR: path.join(root, "nonexistent.sock"),
    FIELDGUIDE_PLUGIN_INDEX: "",
  };
});

after(async () => {
  await rm(root, { recursive: true, force: true });
});

test("handshake", async (t) => {
  const client = new Client(base);
  t.after(() => client.kill());

  await t.test("answers initialize with the version it was asked for", async () => {
    const res = await client.initialize();
    assert.equal(res.result.protocolVersion, "2025-06-18");
    assert.equal(res.result.serverInfo.name, "fieldguide");
    assert.ok(res.result.capabilities.tools, "must advertise tools");
  });

  await t.test("offers its newest version for one it does not know", async () => {
    const res = await client.request("initialize", { protocolVersion: "1999-01-01" });
    assert.match(res.result.protocolVersion, /^\d{4}-\d{2}-\d{2}$/);
    assert.notEqual(res.result.protocolVersion, "1999-01-01");
  });

  await t.test("answers ping", async () => {
    const res = await client.request("ping");
    assert.deepEqual(res.result, {});
  });

  await t.test("exits when the harness closes stdin", async () => {
    assert.equal(await client.close(), 0);
  });
});

test("tools/list", async (t) => {
  await t.test("one tool per enabled verb, and no index tools without an index", async () => {
    const client = new Client(base);
    t.after(() => client.kill());
    await client.initialize();
    const res = await client.request("tools/list");
    const names = res.result.tools.map((tool: Json) => tool.name).sort();
    assert.deepEqual(names, ["nvim_docs", "nvim_explain_keymap", "nvim_reload", "nvim_state", "nvim_verify"]);
    for (const tool of res.result.tools) {
      assert.ok(tool.description.length > 60, `${tool.name} needs a real description`);
      assert.equal(tool.inputSchema.type, "object", `${tool.name} needs an object schema`);
    }
  });

  await t.test("the configured verbs are the ceiling", async () => {
    // Subtractive only, as in the pi extension: a verb the user turned off
    // must not come back just because the harness changed.
    const client = new Client({ ...base, FIELDGUIDE_VERBS: "state,docs" });
    t.after(() => client.kill());
    await client.initialize();
    const res = await client.request("tools/list");
    assert.deepEqual(res.result.tools.map((tool: Json) => tool.name).sort(), ["nvim_docs", "nvim_state"]);
  });

  await t.test("schemas carry required fields and nothing that is not JSON", async () => {
    const client = new Client(base);
    t.after(() => client.kill());
    await client.initialize();
    const res = await client.request("tools/list");
    const docs = res.result.tools.find((tool: Json) => tool.name === "nvim_docs");
    assert.deepEqual(docs.inputSchema.required, ["query"]);
    assert.equal(docs.inputSchema.properties.fetch.type, "boolean");
    const state = res.result.tools.find((tool: Json) => tool.name === "nvim_state");
    assert.equal(state.inputSchema.required, undefined, "every nvim_state argument is optional");
  });

  await t.test("pi's prompt guidelines reach the model through the description", async () => {
    const client = new Client(base);
    t.after(() => client.kill());
    await client.initialize();
    const res = await client.request("tools/list");
    const state = res.result.tools.find((tool: Json) => tool.name === "nvim_state");
    assert.match(state.description, /Call nvim_state before answering/);
  });

  await t.test("the index tools appear when there is an index", async () => {
    const db = path.join(root, "index.db");
    const sqlite = new DatabaseSync(db);
    sqlite.exec("create table meta (key text primary key, value text)");
    sqlite.prepare("insert into meta values (?,?)").run("schema", "1.0.0");
    sqlite.close();

    const client = new Client({ ...base, FIELDGUIDE_VERBS: "state", FIELDGUIDE_PLUGIN_INDEX: db });
    t.after(() => client.kill());
    await client.initialize();
    const res = await client.request("tools/list");
    const names = res.result.tools.map((tool: Json) => tool.name).sort();
    assert.deepEqual(names, ["nvim_plugin", "nvim_plugins", "nvim_state"]);
    const plugins = res.result.tools.find((tool: Json) => tool.name === "nvim_plugins");
    assert.equal(plugins.inputSchema.properties.check.type, "array");
    assert.equal(plugins.inputSchema.properties.check.items.type, "string");
  });
});

/** pi's launcher exports a NODE_PATH naming its private module directories. */
function piModulePaths(): string[] {
  let launcher = "";
  try {
    launcher = execFileSync("sh", ["-c", "command -v pi"], { encoding: "utf8" }).trim();
  } catch {
    return [];
  }
  if (!launcher) return [];
  const match = readFileSync(launcher, "utf8").match(/NODE_PATH="([^"]+)"/);
  return match ? match[1].split(":").filter(Boolean) : [];
}

test("the typebox shim emits what typebox emits", async (t) => {
  // mcp.ts stands a shim in for typebox so it runs without pi. Where pi *is*
  // installed, load nvim.ts against the real typebox and hold the two to the
  // same schemas, so the shim cannot drift from what pi sends its models.
  const modulePaths = piModulePaths();
  let createJiti: ((id: string, opts?: unknown) => { import: (id: string) => Promise<unknown> }) | null = null;
  let require: NodeJS.Require | null = null;
  if (modulePaths.length) {
    require = createRequire(path.join(modulePaths[0], "index.js"));
    try {
      createJiti = require("jiti").createJiti;
    } catch {
      createJiti = null;
    }
  }
  if (!createJiti || !require) {
    if (process.env.FIELDGUIDE_TEST_REQUIRE_PI) assert.fail("pi is not installed");
    t.skip("pi is not installed, so there is no real typebox to compare against");
    return;
  }

  const db = path.join(root, "shim-index.db");
  const sqlite = new DatabaseSync(db);
  sqlite.exec("create table meta (key text primary key, value text)");
  sqlite.prepare("insert into meta values (?,?)").run("schema", "1.0.0");
  sqlite.close();
  const env = { ...base, FIELDGUIDE_PLUGIN_INDEX: db };

  const previous: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(env)) {
    previous[key] = process.env[key];
    process.env[key] = value;
  }
  const expected = new Map<string, unknown>();
  try {
    const extension = path.join(ROOT, "extension", "nvim.ts");
    const jiti = createJiti(extension, { alias: { typebox: require.resolve("typebox") }, moduleCache: false });
    const mod = (await jiti.import(extension)) as { default: (pi: unknown) => void };
    mod.default({
      registerTool: (tool: Json) => expected.set(tool.name, JSON.parse(JSON.stringify(tool.parameters))),
      on: () => {},
    });
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }

  const client = new Client(env);
  t.after(() => client.kill());
  await client.initialize();
  const res = await client.request("tools/list");
  assert.equal(res.result.tools.length, expected.size);
  for (const tool of res.result.tools) {
    assert.deepEqual(tool.inputSchema, expected.get(tool.name), `${tool.name}: shim and typebox disagree`);
  }
});

test("errors", async (t) => {
  const client = new Client(base);
  t.after(() => client.kill());
  await client.initialize();

  await t.test("an unreachable editor is a tool error the model can read", async () => {
    const res = await client.request("tools/call", { name: "nvim_state", arguments: { what: "nvim" } });
    assert.equal(res.result.isError, true);
    assert.match(res.result.content[0].text, /^state: .*cannot connect to Neovim/);
  });

  await t.test("a tool that was never offered is a protocol error", async () => {
    const res = await client.request("tools/call", { name: "bash", arguments: { command: "id" } });
    assert.equal(res.error.code, -32602);
  });

  await t.test("a disabled verb is not callable either", async () => {
    const narrow = new Client({ ...base, FIELDGUIDE_VERBS: "state" });
    t.after(() => narrow.kill());
    await narrow.initialize();
    const res = await narrow.request("tools/call", { name: "nvim_reload", arguments: {} });
    assert.equal(res.error.code, -32602);
  });

  await t.test("an unknown method is named, not ignored", async () => {
    const res = await client.request("resources/list");
    assert.equal(res.error.code, -32601);
  });

  await t.test("null params are read as none, not a crash", async () => {
    // A destructuring default applies to undefined only; null used to reach
    // `params.protocolVersion` and take the whole server down.
    const init = await client.request("initialize", null as unknown as Json);
    assert.match(init.result.protocolVersion, /^\d{4}-\d{2}-\d{2}$/);
    const call = await client.request("tools/call", null as unknown as Json);
    assert.equal(call.error.code, -32602);
    client.notify("notifications/cancelled", null as unknown as Json);
    assert.deepEqual((await client.request("ping")).result, {});
  });

  await t.test("a garbled line is answered and survived", async () => {
    client.raw("{not json");
    await sleep(100);
    const garbled = client.received.find((m) => m.error?.code === -32700);
    assert.ok(garbled, "expected a parse error response");
    assert.equal(garbled.id, null);
    assert.deepEqual((await client.request("ping")).result, {});
  });
});

test("notifications", async (t) => {
  // A stand-in for `nvim -l` that leaves a mark if it is ever run.
  const mark = path.join(root, "ran.mark");
  const fake = path.join(root, "marking-nvim");
  await writeFile(fake, `#!/bin/sh\ntouch ${mark}\necho '{"ok":true,"result":{}}'\n`);
  await chmod(fake, 0o755);

  const client = new Client({ ...base, FIELDGUIDE_NVIM: fake });
  t.after(() => client.kill());
  await client.initialize();

  await t.test("a request without an id runs nothing and is not answered", async () => {
    const before = client.received.length;
    for (const method of ["tools/call", "tools/list", "ping"]) {
      client.notify(method, { name: "nvim_state", arguments: {} });
    }
    // A request after them, answered in order, shows the three were read.
    await client.request("ping");
    await sleep(200);
    assert.equal(existsSync(mark), false, "a notification must not run a tool");
    assert.equal(client.received.length, before + 1, JSON.stringify(client.received.slice(before)));
  });
});

test("cancellation", async (t) => {
  // A stand-in for `nvim -l`: records its pid, then hangs, the way a verb does
  // when the editor sits on a confirm() prompt.
  const pidFile = path.join(root, "hung.pid");
  const fake = path.join(root, "hung-nvim");
  await writeFile(fake, `#!/bin/sh\necho $$ > ${pidFile}\nexec sleep 60\n`);
  await chmod(fake, 0o755);

  const client = new Client({ ...base, FIELDGUIDE_NVIM: fake });
  t.after(() => client.kill());
  await client.initialize();

  const id = 4242;
  let answered = false;
  client.requestWithId(id, "tools/call", { name: "nvim_state", arguments: {} }, 60_000).then(
    () => (answered = true),
    () => {},
  );
  for (let i = 0; i < 50 && !existsSync(pidFile); i++) await sleep(50);
  const pid = Number((await readFile(pidFile, "utf8")).trim());

  await t.test("a hung call does not hold up the next request", async () => {
    assert.deepEqual((await client.request("ping")).result, {});
  });

  await t.test("cancelling kills the client and sends nothing back", async () => {
    // exec keeps the pid: the recorded one is the sleep the signal must reach.
    client.notify("notifications/cancelled", { requestId: id, reason: "user interrupt" });
    let alive = true;
    for (let i = 0; i < 40 && alive; i++) {
      await sleep(50);
      try {
        process.kill(pid, 0);
      } catch {
        alive = false;
      }
    }
    assert.equal(alive, false, "the hung client must be killed");
    await client.request("ping");
    assert.equal(answered, false, "a cancelled request gets no response");
  });
});

test("against a live editor", async (t) => {
  // Every XDG root in the temp dir: the checkpoint below writes a shadow repo
  // under stdpath("state"), and that must never be the real one.
  const xdg = {
    XDG_CONFIG_HOME: path.join(root, "config"),
    XDG_STATE_HOME: path.join(root, "state"),
    XDG_DATA_HOME: path.join(root, "data"),
    XDG_CACHE_HOME: path.join(root, "cache"),
  };
  const sock = path.join(root, "nvim.sock");
  const nvim = spawn(
    "nvim",
    ["--clean", "--headless", "--listen", sock, "-c", `set rtp+=${ROOT}`, "-c", "lua require('fieldguide').setup({})"],
    { env: { ...process.env, ...xdg }, stdio: "ignore" },
  );
  t.after(() => nvim.kill("SIGKILL"));
  for (let i = 0; i < 100 && !existsSync(sock); i++) await sleep(50);
  assert.ok(existsSync(sock), "headless nvim never started listening");

  const env = { ...base, ...xdg, FIELDGUIDE_ADDR: sock };

  await t.test("a verb reaches the editor and comes back as text", async () => {
    const client = new Client(env);
    t.after(() => client.kill());
    await client.initialize();
    const res = await client.request("tools/call", { name: "nvim_state", arguments: { what: "nvim" } });
    assert.notEqual(res.result.isError, true, res.result.content[0].text);
    const state = JSON.parse(res.result.content[0].text);
    assert.equal(await realpath(state.nvim.config_dir), configRoot);
  });

  await t.test("verify boots through the CLI's split, not inside the editor", async () => {
    const client = new Client(env);
    t.after(() => client.kill());
    await client.initialize();
    const res = await client.request("tools/call", { name: "nvim_verify", arguments: {} }, 60_000);
    assert.notEqual(res.result.isError, true, res.result.content[0].text);
    const verify = JSON.parse(res.result.content[0].text);
    // bwrap or seatbelt may be missing on a given machine; either way the
    // answer is a verify result, not a transport error.
    assert.ok("ok" in verify, JSON.stringify(verify).slice(0, 300));
  });

  await t.test("--after-write checkpoints and reports the boot", async () => {
    // The sequence a harness runs: snapshot, write, then check. Without the
    // snapshot, the shadow repo's first commit would swallow the edit itself
    // and there would be nothing left to checkpoint.
    const target = path.join(configRoot, "init.lua");
    assert.equal((await hookRun(["--before-write", target], env, configRoot)).code, 0);
    await writeFile(target, "vim.g.mcp_fixture = 2\n");
    const res = await hookRun(["--after-write", target], env, configRoot);
    assert.equal(res.code, 0, res.stderr);
    assert.match(res.stdout, /^\[fieldguide\] (boot OK|boot FAILED|boot TIMED OUT|verify unavailable)/);
    assert.match(res.stdout, /checkpoint [0-9a-f]+ \(undo with :FieldguideUndo\)/);
  });

  await t.test("--after-write says nothing about a path outside the config", async () => {
    const res = await hookRun(["--after-write", path.join(docRoot, "x.txt")], env, configRoot);
    assert.equal(res.code, 0, res.stderr);
    assert.equal(res.stdout, "");
  });

  await t.test("--before-write lets a config write through", async () => {
    const res = await hookRun(["--before-write", "lua/new.lua"], env, configRoot);
    assert.equal(res.code, 0, res.stderr);
  });

  await t.test("--before-write refuses the doc zone and everything outside", async () => {
    const docs = await hookRun(["--before-write", path.join(docRoot, "x.txt")], env, configRoot);
    assert.equal(docs.code, 2);
    assert.match(docs.stderr, /doc zone is read-only/);
    const outside = await hookRun(["--before-write", "../../outside.txt"], env, configRoot);
    assert.equal(outside.code, 2);
    assert.match(outside.stderr, /outside fieldguide's zones/);
  });

  await t.test("an --after-write with no path is a usage error", async () => {
    const res = await hookRun(["--after-write"], env, configRoot);
    assert.equal(res.code, 1);
  });

  // Claude Code reads any exit but 2 as a hook that failed *without* blocking,
  // and runs the tool anyway. A pre-write hook that cannot decide must refuse.
  await t.test("a --before-write with no path refuses, with exit 2", async () => {
    const res = await hookRun(["--before-write"], env, configRoot);
    assert.equal(res.code, 2);
    assert.match(res.stderr, /needs a path/);
  });
});

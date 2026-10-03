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
import { chmod, lstat, mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
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

  /** `args` picks the mode: none is the stdio server, `--relay <sock>` its socket twin. */
  constructor(env: Record<string, string>, cwd = ROOT, args: string[] = []) {
    this.proc = spawn(process.execPath, [SERVER, ...args], {
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

/**
 * The server as the editor will run it: outside the sandbox, on a socket, with
 * a pipe on stdin that ties its life to the caller's.
 */
async function listen(sock: string, env: Record<string, string>) {
  const proc = spawn(process.execPath, [SERVER, "--listen", sock], {
    env: { ...process.env, ...env },
    stdio: ["pipe", "ignore", "pipe"],
  });
  let stderr = "";
  proc.stderr!.setEncoding("utf8").on("data", (d: string) => (stderr += d));
  const exited = new Promise<number | null>((resolve) => proc.on("close", (code) => resolve(code)));
  for (let i = 0; i < 100 && !stderr.includes("MCP on") && proc.exitCode === null; i++) await sleep(50);
  return { proc, exited, stderr: () => stderr };
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

  await t.test("a method that is not a string is an invalid request, not a crash", async () => {
    client.raw(JSON.stringify({ jsonrpc: "2.0", method: 123 }));
    const res = await client.requestWithId(77, 123 as unknown as string);
    assert.equal(res.error.code, -32600);
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

test("over a socket", async (t) => {
  const sock = path.join(root, "mcp.sock");
  const server = await listen(sock, base);
  t.after(() => server.proc.kill("SIGKILL"));
  // Inside the sandbox none of the editor's variables exist; the relay and the
  // hooks must not need them.
  const inside = { FIELDGUIDE_ADDR: "", FIELDGUIDE_BIN: "", FIELDGUIDE_CONFIG_DIR: "", FIELDGUIDE_MCP_SOCKET: sock };

  await t.test("the socket is the owner's alone", async () => {
    assert.equal((await stat(sock)).mode & 0o777, 0o600);
  });

  await t.test("a relay carries a whole MCP session", async () => {
    const client = new Client(inside, root, ["--relay", sock]);
    t.after(() => client.kill());
    const init = await client.initialize();
    assert.equal(init.result.serverInfo.name, "fieldguide");
    const list = await client.request("tools/list");
    assert.ok(list.result.tools.some((tool: Json) => tool.name === "nvim_state"));
  });

  await t.test("the write hooks are not offered as tools", async () => {
    const client = new Client(inside, root, ["--relay", sock]);
    t.after(() => client.kill());
    await client.initialize();
    const names = (await client.request("tools/list")).result.tools.map((tool: Json) => tool.name);
    assert.ok(!names.some((name: string) => name.includes("Write")), names.join(", "));
  });

  await t.test("two sessions at once keep their own ids", async () => {
    const a = new Client(inside, root, ["--relay", sock]);
    const b = new Client(inside, root, ["--relay", sock]);
    t.after(() => (a.kill(), b.kill()));
    await Promise.all([a.initialize(), b.initialize()]);
    // Both use id 2 next; each must get its own answer back.
    const [pa, lb] = await Promise.all([a.request("ping"), b.request("tools/list")]);
    assert.deepEqual(pa.result, {});
    assert.ok(Array.isArray(lb.result.tools));
  });

  await t.test("a relay with nothing to reach says so and exits", async () => {
    const res = await hookRun(["--relay", path.join(root, "absent.sock")], inside, root);
    assert.equal(res.code, 1);
    assert.match(res.stderr, /no fieldguide server is listening/);
  });

  await t.test("a pre-write the server refuses is exit 2, with its reason", async () => {
    const res = await hookRun(["--before-write", path.join(docRoot, "x.txt")], inside, configRoot);
    assert.equal(res.code, 2);
    assert.match(res.stderr, /doc zone is read-only/);
  });

  await t.test("a path the agent made in its own /tmp is refused out here", async () => {
    // Inside, /tmp is a tmpfs: whatever the agent built there does not exist on
    // the real filesystem, which is the one the gate decides on.
    const res = await hookRun(["--before-write", "/tmp/fieldguide-agent-only/init.lua"], inside, configRoot);
    assert.equal(res.code, 2);
    assert.match(res.stderr, /outside fieldguide's zones/);
  });

  await t.test("a relative path is taken against the hook's cwd", async () => {
    const res = await hookRun(["--before-write", "../../outside.txt"], inside, configRoot);
    assert.equal(res.code, 2);
    assert.match(res.stderr, /outside fieldguide's zones/);
  });

  await t.test("a pre-write with no server to ask refuses, with exit 2", async () => {
    const res = await hookRun(
      ["--before-write", "init.lua"],
      { ...inside, FIELDGUIDE_MCP_SOCKET: path.join(root, "absent.sock") },
      configRoot,
    );
    assert.equal(res.code, 2);
    assert.match(res.stderr, /cannot vet this write/);
  });

  await t.test("a pre-write the server never answers refuses, with exit 2", async () => {
    // A socket that accepts and then says nothing: a wedged server.
    const mute = path.join(root, "mute.sock");
    const silent = createServer(() => {});
    await new Promise<void>((resolve) => silent.listen(mute, resolve));
    t.after(() => silent.close());
    const res = await hookRun(
      ["--before-write", "init.lua"],
      { ...inside, FIELDGUIDE_MCP_SOCKET: mute, FIELDGUIDE_HOOK_TIMEOUT_MS: "500" },
      configRoot,
    );
    assert.equal(res.code, 2);
    assert.match(res.stderr, /no answer/);
  });

  await t.test("an after-write with no server to ask is content, not a failure", async () => {
    const res = await hookRun(
      ["--after-write", path.join(configRoot, "init.lua")],
      { ...inside, FIELDGUIDE_MCP_SOCKET: path.join(root, "absent.sock") },
      configRoot,
    );
    assert.equal(res.code, 0);
    assert.match(res.stdout, /^\[fieldguide\] verify unavailable/);
  });

  await t.test("a live server is not taken over by a second", async () => {
    const second = await listen(sock, base);
    assert.equal(await second.exited, 1);
    assert.match(second.stderr(), /already being served/);
  });

  await t.test("a socket path too long to bind says so, rather than EINVAL", async () => {
    const long = path.join(root, "x".repeat(120) + ".sock");
    const res = await listen(long, base);
    assert.equal(await res.exited, 1);
    assert.match(res.stderr(), /must fit in \d+/);
  });

  await t.test("a file that is not a socket is never deleted", async () => {
    const plain = path.join(root, "plain.file");
    await writeFile(plain, "mine\n");
    const other = await listen(plain, base);
    assert.equal(await other.exited, 1);
    assert.match(other.stderr(), /not a socket/);
    assert.equal(await readFile(plain, "utf8"), "mine\n");
  });

  await t.test("the server goes, and takes its socket, when its caller does", async () => {
    server.proc.stdin!.end();
    assert.equal(await server.exited, 0);
    assert.equal(existsSync(sock), false);
  });

  await t.test("a stale socket left behind is replaced", async () => {
    // A server killed outright leaves its socket file with nobody behind it.
    const stale = path.join(root, "stale.sock");
    const dead = await listen(stale, base);
    dead.proc.kill("SIGKILL");
    await dead.exited;
    assert.ok((await lstat(stale)).isSocket(), "the killed server should leave its socket behind");
    const fresh = await listen(stale, base);
    t.after(() => fresh.proc.kill("SIGKILL"));
    assert.match(fresh.stderr(), /MCP on/);
    const client = new Client(inside, root, ["--relay", stale]);
    t.after(() => client.kill());
    assert.equal((await client.initialize()).result.serverInfo.name, "fieldguide");
  });
});

test("a socket that is not this server's", async (t) => {
  await t.test("is left alone when the server shuts down", async () => {
    // Someone else's socket now sits at the path this server bound: removing
    // it on the way out would cut off a server that is still running.
    const sock = path.join(root, "replaced.sock");
    const first = await listen(sock, base);
    await rm(sock);
    const other = createServer(() => {});
    await new Promise<void>((resolve) => other.listen(sock, resolve));
    t.after(() => other.close());
    first.proc.stdin!.end();
    assert.equal(await first.exited, 0);
    assert.ok((await lstat(sock)).isSocket(), "the other server's socket must survive");
  });

  await t.test("means this server is unreachable, so it exits", async () => {
    const sock = path.join(root, "orphan.sock");
    const orphan = await listen(sock, base);
    t.after(() => orphan.proc.kill("SIGKILL"));
    await rm(sock);
    const code = await Promise.race([orphan.exited, sleep(5000).then(() => "still running")]);
    assert.equal(code, 0);
    assert.match(orphan.stderr(), /no longer this server's/);
  });

  await t.test("is never taken from a server that won the race for a stale one", async () => {
    // Several servers asked for the same dead socket at once: whichever binds
    // it must stay reachable, and every other one must step aside.
    for (let round = 0; round < 3; round++) {
      const stale = path.join(root, `race-${round}.sock`);
      const dead = await listen(stale, base);
      dead.proc.kill("SIGKILL");
      await dead.exited;
      const racers = await Promise.all([0, 1, 2, 3, 4].map(() => listen(stale, base)));
      t.after(() => racers.forEach((r) => r.proc.kill("SIGKILL")));
      await sleep(300);
      const running = racers.filter((r) => r.proc.exitCode === null);
      assert.equal(running.length, 1, `round ${round}: exactly one server keeps running`);
      const client = new Client({ FIELDGUIDE_MCP_SOCKET: stale }, root, ["--relay", stale]);
      t.after(() => client.kill());
      assert.equal((await client.initialize()).result.serverInfo.name, "fieldguide", `round ${round}: and it is reachable`);
    }
  });
});

test("a write hook given up on", async (t) => {
  // The hook stops waiting, and the checkpoint and verify it asked for must
  // stop too, rather than run on behind a result nobody will read.
  const pidFile = path.join(root, "hook-hung.pid");
  const fake = path.join(root, "hook-hung-nvim");
  await writeFile(fake, `#!/bin/sh\necho $$ > ${pidFile}\nexec sleep 60\n`);
  await chmod(fake, 0o755);
  const sock = path.join(root, "hook-hung.sock");
  const server = await listen(sock, { ...base, FIELDGUIDE_NVIM: fake });
  t.after(() => server.proc.kill("SIGKILL"));

  for (const which of ["--before-write", "--after-write"]) {
    await t.test(`${which}: the editor-side work is abandoned with it`, async () => {
      await rm(pidFile, { force: true });
      const res = await hookRun(
        [which, path.join(configRoot, "init.lua")],
        { FIELDGUIDE_MCP_SOCKET: sock, FIELDGUIDE_HOOK_TIMEOUT_MS: "1500" },
        configRoot,
      );
      assert.equal(res.code, which === "--before-write" ? 2 : 0, res.stderr);
      assert.ok(existsSync(pidFile), "the server should have started the checkpoint");
      const pid = Number((await readFile(pidFile, "utf8")).trim());
      let alive = true;
      for (let i = 0; i < 40 && alive; i++) {
        await sleep(50);
        try {
          process.kill(pid, 0);
        } catch {
          alive = false;
        }
      }
      assert.equal(alive, false, "the hung checkpoint must be killed");
    });
  }
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

  // The sandboxed shape: the server outside with the editor's variables, and
  // the relay and hooks inside with none of them.
  const mcpSock = path.join(root, "live-mcp.sock");
  const server = await listen(mcpSock, env);
  t.after(() => server.proc.kill("SIGKILL"));
  const inside = { FIELDGUIDE_ADDR: "", FIELDGUIDE_BIN: "", FIELDGUIDE_CONFIG_DIR: "", FIELDGUIDE_MCP_SOCKET: mcpSock };

  await t.test("through the relay, a verb reaches the editor", async () => {
    const client = new Client(inside, root, ["--relay", mcpSock]);
    t.after(() => client.kill());
    await client.initialize();
    const res = await client.request("tools/call", { name: "nvim_state", arguments: { what: "nvim" } });
    assert.notEqual(res.result.isError, true, res.result.content[0].text);
    assert.equal(await realpath(JSON.parse(res.result.content[0].text).nvim.config_dir), configRoot);
  });

  await t.test("through the socket, --before-write lets a config write through", async () => {
    const res = await hookRun(["--before-write", "lua/via-socket.lua"], inside, configRoot);
    assert.equal(res.code, 0, res.stderr);
  });

  await t.test("through the socket, --after-write checkpoints and verifies", async () => {
    const target = path.join(configRoot, "lua", "via-socket.lua");
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, "return 2\n");
    const res = await hookRun(["--after-write", target], inside, configRoot);
    assert.equal(res.code, 0, res.stderr);
    assert.match(res.stdout, /^\[fieldguide\] (boot OK|boot FAILED|boot TIMED OUT|verify unavailable)/);
    assert.match(res.stdout, /checkpoint [0-9a-f]+ \(undo with :FieldguideUndo\)/);
  });
});

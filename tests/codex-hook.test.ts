// Codex's PreToolUse / PostToolUse hook: the gate on apply_patch, and the
// checkpoint and verify around writes, whether they come by patch or by shell.
//
//   node --test tests/codex-hook.test.ts
//
// The table half calls `decide` directly. The process half runs the hook the
// way Codex does, JSON on stdin, in a copied tree whose mcp.ts is a stand-in
// that logs what it was asked, so each checkpoint and verify can be counted.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { after, before, describe, test } from "node:test";

import { decide, DENY_PREFIX, fingerprint, type HookEvent } from "../extension/harness/codex-hook.ts";
import type { Zones } from "../extension/gate.ts";

const REPO = path.resolve(import.meta.dirname, "..");

//   root/
//     config/            <- config zone (rw); cwd
//       init.lua
//       link -> ../outside
//     docs/doc/x.txt     <- doc zone (ro)
//     outside/secret.txt <- neither
let root: string;
let zones: Zones;

before(async () => {
  root = await realpath(await mkdtemp(path.join(tmpdir(), "fieldguide-codex-hook-")));
  await mkdir(path.join(root, "config/lua"), { recursive: true });
  await writeFile(path.join(root, "config/init.lua"), "-- config\n");
  await mkdir(path.join(root, "docs/doc"), { recursive: true });
  await writeFile(path.join(root, "docs/doc/x.txt"), "*x.txt*\n");
  await mkdir(path.join(root, "outside"), { recursive: true });
  await writeFile(path.join(root, "outside/secret.txt"), "CANARY\n");
  await symlink(path.join(root, "outside"), path.join(root, "config/link"));
  zones = { cwd: path.join(root, "config"), configRoot: path.join(root, "config"), docRoots: [path.join(root, "docs")] };
});

after(async () => {
  await rm(root, { recursive: true, force: true });
});

const patch = (...headers: string[]) => ["*** Begin Patch", ...headers, "@@", "+x", "*** End Patch"].join("\n");
const ev = (tool_name: string, tool_input: Record<string, unknown>, extra: Partial<HookEvent> = {}): HookEvent => ({
  hook_event_name: "PreToolUse",
  tool_name,
  tool_input,
  tool_use_id: "call_1",
  cwd: zones.cwd,
  ...extra,
});

describe("decide", () => {
  const cases: [string, string, () => Record<string, unknown>, boolean][] = [
    ["a patch in the config", "apply_patch", () => ({ command: patch("*** Update File: init.lua") }), true],
    ["a patch by absolute path", "apply_patch", () => ({ command: patch(`*** Add File: ${zones.configRoot}/lua/new.lua`) }), true],
    ["a patch into the docs", "apply_patch", () => ({ command: patch(`*** Update File: ${root}/docs/doc/x.txt`) }), false],
    ["a patch outside", "apply_patch", () => ({ command: patch("*** Add File: ../outside/evil.lua") }), false],
    ["a patch through a symlink out", "apply_patch", () => ({ command: patch("*** Update File: link/secret.txt") }), false],
    ["a patch whose second file is outside", "apply_patch", () => ({ command: patch("*** Update File: init.lua", "*** Delete File: /etc/hosts") }), false],
    ["a patch that moves a file out", "apply_patch", () => ({ command: patch("*** Update File: init.lua", "*** Move to: ../outside/x.lua") }), false],
    ["a patch that does not parse", "apply_patch", () => ({ command: "rm -rf ~" }), false],
    ["a patch with no text", "apply_patch", () => ({}), false],
    // The sandbox around Codex bounds the shell; a hook only sees a string.
    ["the shell", "Bash", () => ({ command: "cat init.lua" }), true],
    ["our own verbs", "mcp__fieldguide__nvim_state", () => ({ what: "nvim" }), true],
    ["the plan", "update_plan", () => ({ plan: [] }), true],
    ["another MCP server's tool", "mcp__github__create_issue", () => ({}), false],
    ["a lookalike of ours", "mcp__fieldguide2__nvim_state", () => ({}), false],
    ["web search", "web_search", () => ({ query: "x" }), false],
    ["a tool this gate has never heard of", "shiny_new_tool", () => ({}), false],
  ];
  for (const [name, tool, input, allow] of cases) {
    test(`${allow ? "allow" : "block"}: ${name}`, async () => {
      const d = await decide(ev(tool, input()), zones);
      assert.equal(d.allow, allow, d.allow ? "allowed" : (d as { reason: string }).reason);
    });
  }

  test("with no config root, nothing but our verbs is allowed", async () => {
    const none = { ...zones, configRoot: "" };
    assert.equal((await decide(ev("Bash", { command: "ls" }), none)).allow, false);
    assert.equal((await decide(ev("mcp__fieldguide__nvim_state", {}), none)).allow, true);
  });

  test("a patch reports every file it writes", async () => {
    const d = await decide(ev("apply_patch", { command: patch("*** Update File: init.lua", "*** Move to: lua/b.lua") }), zones);
    assert.deepEqual(d.writes, ["init.lua", "lua/b.lua"]);
  });
});

describe("fingerprint", () => {
  test("is stable while nothing changes, and moves when a file does", async () => {
    const dir = await mkdtemp(path.join(root, "fp-"));
    await writeFile(path.join(dir, "a.lua"), "a");
    const one = fingerprint(dir);
    assert.equal(fingerprint(dir), one);
    await writeFile(path.join(dir, "a.lua"), "ab");
    assert.notEqual(fingerprint(dir), one);
  });

  test("sees a new file, and not a commit in .git", async () => {
    const dir = await mkdtemp(path.join(root, "fp-"));
    const one = fingerprint(dir);
    await mkdir(path.join(dir, ".git"));
    await writeFile(path.join(dir, ".git/HEAD"), "ref");
    assert.equal(fingerprint(dir), one, ".git is not the config");
    await writeFile(path.join(dir, "new.lua"), "");
    assert.notEqual(fingerprint(dir), one);
  });
});

// ---------------------------------------------------------------------------
// The hook process, with a stand-in mcp.ts.
// ---------------------------------------------------------------------------

describe("the hook process", () => {
  let tree: string;
  let log: string;
  let state: string;
  before(async () => {
    tree = path.join(root, "plugin");
    await mkdir(path.join(tree, "extension/harness"), { recursive: true });
    for (const f of ["extension/gate.ts", "extension/harness/patch.ts", "extension/harness/write-hooks.ts", "extension/harness/codex-hook.ts"]) {
      await copyFile(path.join(REPO, f), path.join(tree, f));
    }
    log = path.join(root, "server.log");
    state = path.join(root, "hook-state");
    // Logs every call; refuses a path with "refuse-me" the way mcp.ts does.
    await writeFile(
      path.join(tree, "extension/mcp.ts"),
      `import { appendFileSync } from "node:fs";
const [mode, target] = process.argv.slice(2);
appendFileSync(${JSON.stringify(log)}, mode + " " + target + "\\n");
if (mode === "--before-write" && target.includes("refuse-me")) { console.error("nope: " + target); process.exit(2); }
if (mode === "--after-write") console.log("[fieldguide] boot OK, 9ms; checkpoint abc");
`,
    );
  });

  const hook = () => path.join(tree, "extension/harness/codex-hook.ts");
  const run = (mode: string, event: HookEvent, env: Record<string, string> = {}) =>
    spawnSync(process.execPath, [hook(), mode], {
      input: JSON.stringify(event),
      encoding: "utf8",
      env: {
        PATH: process.env.PATH ?? "",
        FIELDGUIDE_CONFIG_DIR: zones.configRoot,
        FIELDGUIDE_DOC_ROOTS: zones.docRoots.join(":"),
        FIELDGUIDE_VERBS: "state,verify",
        FIELDGUIDE_HOOK_STATE: state,
        ...env,
      },
    });
  const calls = async () => (await readFile(log, "utf8").catch(() => "")).split("\n").filter(Boolean);
  const reset = async () => {
    await writeFile(log, "");
    await rm(state, { recursive: true, force: true });
  };

  test("a refusal is exit 2 with the reason, and the server is never asked", async () => {
    await reset();
    const res = run("pre", ev("apply_patch", { command: patch(`*** Update File: ${root}/docs/doc/x.txt`) }));
    assert.equal(res.status, 2);
    assert.ok(res.stderr.startsWith(DENY_PREFIX), res.stderr);
    assert.match(res.stderr, /read-only/);
    assert.deepEqual(await calls(), []);
  });

  test("a tool fieldguide does not grant is refused", async () => {
    const res = run("pre", ev("web_search", { query: "x" }));
    assert.equal(res.status, 2);
    assert.match(res.stderr, /does not grant web_search/);
  });

  test("unreadable input is a refusal, not a pass", () => {
    const res = spawnSync(process.execPath, [hook(), "pre"], { input: "not json", encoding: "utf8" });
    assert.equal(res.status, 2);
  });

  test("a patch is checkpointed before and verified after, and the model is told", async () => {
    await reset();
    const event = ev("apply_patch", { command: patch("*** Update File: init.lua") });
    assert.equal(run("pre", event).status, 0);
    const post = run("post", { ...event, hook_event_name: "PostToolUse", tool_response: {} });
    assert.equal(post.status, 0, post.stderr);
    const target = path.join(zones.configRoot, "init.lua");
    assert.deepEqual(await calls(), [`--before-write ${target}`, `--after-write ${target}`]);
    const out = JSON.parse(post.stdout);
    assert.equal(out.hookSpecificOutput.hookEventName, "PostToolUse");
    assert.match(out.hookSpecificOutput.additionalContext, /boot OK/);
  });

  test("a patch the server refuses before writing is refused", async () => {
    await reset();
    const res = run("pre", ev("apply_patch", { command: patch("*** Add File: lua/refuse-me.lua") }));
    assert.equal(res.status, 2);
    assert.match(res.stderr, /nope:/);
  });

  test("a patch that failed is not verified", async () => {
    await reset();
    const event = ev("apply_patch", { command: patch("*** Update File: init.lua") }, { hook_event_name: "PostToolUse" });
    const res = run("post", { ...event, tool_response: { success: false } });
    assert.equal(res.stdout, "");
    assert.deepEqual(await calls(), []);
  });

  test("a shell command that changes nothing costs no checkpoint and no verify", async () => {
    await reset();
    const first = ev("Bash", { command: "cat init.lua" }, { tool_use_id: "b1" });
    assert.equal(run("pre", first).status, 0);
    // The first command of a session commits the tree as it stands.
    assert.deepEqual(await calls(), [`--before-write ${zones.configRoot}`]);
    const post = run("post", { ...first, hook_event_name: "PostToolUse" });
    assert.equal(post.stdout, "", "nothing changed, nothing to say");
    const second = ev("Bash", { command: "ls" }, { tool_use_id: "b2" });
    run("pre", second);
    run("post", { ...second, hook_event_name: "PostToolUse" });
    assert.deepEqual(await calls(), [`--before-write ${zones.configRoot}`], "no further server calls");
  });

  test("a shell command that changes the config is checkpointed and verified", async () => {
    await reset();
    const cmd = ev("Bash", { command: "echo x >> init.lua" }, { tool_use_id: "b3" });
    run("pre", cmd);
    await writeFile(path.join(zones.configRoot, "init.lua"), "-- config\nvim.g.x = 1\n");
    const post = run("post", { ...cmd, hook_event_name: "PostToolUse" });
    assert.match(JSON.parse(post.stdout).hookSpecificOutput.additionalContext, /boot OK/);
    assert.deepEqual(await calls(), [`--before-write ${zones.configRoot}`, `--after-write ${zones.configRoot}`]);
  });

  test("the user's own edits between commands are committed before the next one runs", async () => {
    await reset();
    const a = ev("Bash", { command: "ls" }, { tool_use_id: "b4" });
    run("pre", a);
    run("post", { ...a, hook_event_name: "PostToolUse" });
    await writeFile(log, "");
    await writeFile(path.join(zones.configRoot, "lua/mine.lua"), "-- by hand\n");
    const b = ev("Bash", { command: "ls" }, { tool_use_id: "b5" });
    run("pre", b);
    assert.deepEqual(await calls(), [`--before-write ${zones.configRoot}`], "a checkpoint of the user's change first");
  });

  test("without verify, the shell and patches run with no server calls", async () => {
    await reset();
    run("pre", ev("Bash", { command: "ls" }), { FIELDGUIDE_VERBS: "state" });
    run("pre", ev("apply_patch", { command: patch("*** Update File: init.lua") }), { FIELDGUIDE_VERBS: "state" });
    assert.deepEqual(await calls(), []);
  });

  test("check mode answers without reading any input", () => {
    const res = spawnSync(process.execPath, [hook(), "check"], { input: "", encoding: "utf8" });
    assert.equal(res.status, 0);
    assert.equal(res.stdout.trim(), "ok");
  });
});

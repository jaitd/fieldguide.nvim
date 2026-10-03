// The gate in opencode's vocabulary, and the plugin that wires it in.
//
//   node --test tests/opencode.test.ts
//
// The same fixture as gate.test.ts: a symlinked config dir inside a larger repo
// with a secret in it, a symlink out, and a read-only doc zone. What is new here
// is where opencode hides paths — a `path`, a patch body, a glob pattern — so
// that is what the table exercises.

import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, mkdir, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import type { Zones } from "../extension/gate.ts";
import { decide, globRoot, patchPaths } from "../extension/harness/opencode-gate.ts";
import type { ToolEvent } from "../extension/harness/opencode/plugin.ts";

const HERE = path.dirname(fileURLToPath(import.meta.url));

let root: string;
let config: string;
let docs: string;
let zones: Zones;

before(async () => {
  root = await realpath(await mkdtemp(path.join(tmpdir(), "fieldguide-opencode-")));
  config = path.join(root, "dotfiles/nvim/.config/nvim");
  await mkdir(config, { recursive: true });
  await writeFile(path.join(config, "init.lua"), "-- config\n");
  await writeFile(path.join(root, "dotfiles/secrets.env"), "TOKEN=hunter2\n");
  await symlink(path.join(root, "dotfiles"), path.join(config, "escape"));
  await mkdir(path.join(root, "xdg"), { recursive: true });
  await symlink(config, path.join(root, "xdg/nvim"));
  docs = path.join(root, "share/nvim/lazy");
  await mkdir(path.join(docs, "vim-fugitive/doc"), { recursive: true });
  await writeFile(path.join(docs, "vim-fugitive/doc/fugitive.txt"), "*fugitive.txt*\n");

  zones = { cwd: path.join(root, "xdg/nvim"), configRoot: config, docRoots: [docs] };
});

after(async () => {
  await rm(root, { recursive: true, force: true });
});

const patch = (...headers: string[]) => ["*** Begin Patch", ...headers, "@@", "+x", "*** End Patch"].join("\n");

type Case = { name: string; tool: string; args: () => Record<string, unknown>; allow: boolean };

// opencode v2's tools and argument names: `path`, not v1's `filePath`; `patch`,
// not `apply_patch`; `shell`, `subagent`, and no `list`.
const CASES: Case[] = [
  // --- allowed --------------------------------------------------------------
  { name: "read in the config", tool: "read", args: () => ({ path: "init.lua" }), allow: true },
  { name: "read a help file", tool: "read", args: () => ({ path: `${docs}/vim-fugitive/doc/fugitive.txt` }), allow: true },
  { name: "write a new file in the config", tool: "write", args: () => ({ path: "lua/new.lua", content: "" }), allow: true },
  { name: "edit in the config", tool: "edit", args: () => ({ path: "init.lua", oldString: "a", newString: "b" }), allow: true },
  { name: "patch in the config", tool: "patch", args: () => ({ patchText: patch("*** Update File: init.lua") }), allow: true },
  { name: "grep the doc zone", tool: "grep", args: () => ({ pattern: "Gwrite", path: docs, include: "*.txt" }), allow: true },
  { name: "grep with no path", tool: "grep", args: () => ({ pattern: "keymap" }), allow: true },
  { name: "glob a relative pattern", tool: "glob", args: () => ({ pattern: "**/*.lua" }), allow: true },
  { name: "glob a relative pattern under a config subdirectory", tool: "glob", args: () => ({ pattern: "lua/**/*.lua" }), allow: true },
  { name: "glob an absolute pattern into the docs", tool: "glob", args: () => ({ pattern: `${docs}/**/*.txt` }), allow: true },
  { name: "fieldguide's own MCP tool", tool: "fieldguide_nvim_state", args: () => ({}), allow: true },
  // Code mode: a script that can only call tools, each gated on its own.
  { name: "code mode, whose calls are each gated", tool: "execute", args: () => ({ code: "return 1" }), allow: true },

  // --- refused: tools fieldguide does not grant -----------------------------
  { name: "a shell", tool: "shell", args: () => ({ command: "cat /etc/passwd" }), allow: false },
  { name: "v1's shell, should it come back", tool: "bash", args: () => ({ command: "ls" }), allow: false },
  { name: "the network", tool: "webfetch", args: () => ({ url: "https://example.com" }), allow: false },
  { name: "web search", tool: "websearch", args: () => ({ query: "x" }), allow: false },
  { name: "a subagent", tool: "subagent", args: () => ({ prompt: "x" }), allow: false },
  { name: "a skill", tool: "skill", args: () => ({ name: "x" }), allow: false },
  { name: "a question for a user who cannot see it", tool: "question", args: () => ({ questions: [] }), allow: false },
  { name: "renaming the user's opencode sessions", tool: "opencode_session_rename", args: () => ({}), allow: false },
  { name: "moving the user's opencode sessions", tool: "opencode_session_move", args: () => ({}), allow: false },
  { name: "another MCP server's resources", tool: "opencode_read_mcp_resource", args: () => ({}), allow: false },
  { name: "a tool this gate has never heard of", tool: "shiny_new_tool", args: () => ({}), allow: false },
  { name: "another MCP server's tool", tool: "github_create_issue", args: () => ({}), allow: false },
  { name: "a lookalike of ours from another server", tool: "fieldguide2_nvim_state", args: () => ({}), allow: false },

  // --- refused: paths out of the zones --------------------------------------
  { name: "read ../ out of the config", tool: "read", args: () => ({ path: "../../../secrets.env" }), allow: false },
  { name: "read through a symlink out", tool: "read", args: () => ({ path: "escape/secrets.env" }), allow: false },
  { name: "read /etc/passwd", tool: "read", args: () => ({ path: "/etc/passwd" }), allow: false },
  { name: "write a help file", tool: "write", args: () => ({ path: `${docs}/vim-fugitive/doc/fugitive.txt`, content: "" }), allow: false },
  { name: "a file tool with no path", tool: "read", args: () => ({}), allow: false },
  { name: "v1's filePath is not read as a path", tool: "read", args: () => ({ filePath: "init.lua" }), allow: false },
  { name: "a path that is not a string", tool: "edit", args: () => ({ path: ["init.lua"] }), allow: false },
  { name: "grep through the symlink out", tool: "grep", args: () => ({ pattern: "TOKEN", path: "escape" }), allow: false },
  { name: "grep with an include that climbs", tool: "grep", args: () => ({ pattern: "TOKEN", include: "../../*.env" }), allow: false },
  { name: "glob a pattern that climbs", tool: "glob", args: () => ({ pattern: "../../../*.env" }), allow: false },
  // No `..`, but its fixed prefix is a symlink in the config tree that leads out.
  { name: "glob a relative pattern through the symlink out", tool: "glob", args: () => ({ pattern: "escape/*.env" }), allow: false },
  { name: "grep with an include through the symlink out", tool: "grep", args: () => ({ pattern: "TOKEN", include: "escape/*.env" }), allow: false },
  { name: "glob an absolute pattern outside", tool: "glob", args: () => ({ pattern: `${root}/dotfiles/*.env` }), allow: false },
  { name: "glob with a path outside", tool: "glob", args: () => ({ pattern: "*", path: "/etc" }), allow: false },

  // --- refused: patches ----------------------------------------------------
  { name: "a patch that adds a file outside", tool: "patch", args: () => ({ patchText: patch("*** Add File: ../../../evil.lua") }), allow: false },
  {
    name: "a patch whose second file is outside",
    tool: "patch",
    args: () => ({ patchText: patch("*** Update File: init.lua", "*** Delete File: /etc/hosts") }),
    allow: false,
  },
  {
    name: "a patch that moves a config file out",
    tool: "patch",
    args: () => ({ patchText: patch("*** Update File: init.lua", "*** Move to: ../../../stolen.lua") }),
    allow: false,
  },
  { name: "a patch into the doc zone", tool: "patch", args: () => ({ patchText: patch(`*** Update File: ${docs}/x.txt`) }), allow: false },
  { name: "a patch that does not parse", tool: "patch", args: () => ({ patchText: "rm -rf ~" }), allow: false },
  { name: "a patch naming no files", tool: "patch", args: () => ({ patchText: "*** Begin Patch\n*** End Patch" }), allow: false },
  { name: "a patch with no text", tool: "patch", args: () => ({}), allow: false },
];

for (const c of CASES) {
  test(`${c.allow ? "allow" : "block"}: ${c.name}`, async () => {
    const verdict = await decide(c.tool, c.args(), zones);
    assert.equal(verdict.allow, c.allow, verdict.allow ? "allowed" : (verdict as { reason: string }).reason);
  });
}

test("writes report every file they touch, reads none", async () => {
  const p = await decide("patch", { patchText: patch("*** Update File: init.lua", "*** Move to: lua/moved.lua") }, zones);
  assert.deepEqual(p.writes, ["init.lua", "lua/moved.lua"]);
  assert.deepEqual((await decide("write", { path: "a.lua" }, zones)).writes, ["a.lua"]);
  assert.equal((await decide("read", { path: "init.lua" }, zones)).writes, undefined);
});

test("patchPaths reads every header kind and nothing else", () => {
  const text = patch("*** Add File: a", "*** Update File: b", "*** Move to: c", "*** Delete File: d") + "\n+*** Add File: e";
  assert.deepEqual(patchPaths(text), ["a", "b", "c", "d"]);
  assert.equal(patchPaths("*** Add File: a"), null, "no Begin Patch: not a patch");
});

test("globRoot finds the fixed prefix of a pattern, absolute or relative", () => {
  assert.deepEqual(globRoot("/a/b/**/*.lua"), { root: "/a/b", climbs: false });
  assert.deepEqual(globRoot("a/b/**/*.lua"), { root: "a/b", climbs: false });
  assert.deepEqual(globRoot("**/*.lua"), { climbs: false });
  assert.deepEqual(globRoot("a/../../b"), { climbs: true });
});

// ---------------------------------------------------------------------------
// The plugin, with the write hooks stubbed by a script that logs its calls.
// ---------------------------------------------------------------------------

test("the plugin gates, checkpoints before a write, and appends the verify report", async () => {
  const log = path.join(root, "hook.log");
  await writeFile(log, "");
  process.env.FIELDGUIDE_CONFIG_DIR = config;
  process.env.FIELDGUIDE_DOC_ROOTS = docs;
  process.env.FIELDGUIDE_NODE = path.join(HERE, "fixtures/fake-write-hook.sh");
  process.env.FAKE_HOOK_LOG = log;
  const ready = path.join(root, "gate-ready");
  process.env.FIELDGUIDE_GATE_READY = ready;

  // opencode v2 loads the directory through index.js and calls setup(ctx) on
  // its default export, with hooks registered by name.
  const mod = await import("../extension/harness/opencode/index.js");
  assert.deepEqual(Object.keys(mod), ["default"], "only the plugin itself is exported");
  const hooks = new Map<string, (event: ToolEvent) => Promise<unknown>>();
  await mod.default.setup({
    location: { directory: zones.cwd },
    tool: { hook: async (name: string, fn: (event: ToolEvent) => Promise<unknown>) => void hooks.set(name, fn) },
  });
  assert.equal(mod.default.id, "fieldguide");
  assert.ok(existsSync(ready), "a plugin that loaded says so");
  const before = (tool: string, id: string, input: Record<string, unknown>) => hooks.get("execute.before")!({ tool, id, input });
  const after = (tool: string, id: string, text: string, status = "completed") => {
    const event: ToolEvent = { tool, id, status, result: { content: [{ type: "text", text }] } };
    return hooks.get("execute.after")!(event).then(() => event.result!.content!.map((c) => c.text).join("\n\n"));
  };

  await assert.rejects(before("read", "1", { path: "../../../secrets.env" }), /outside/);
  await assert.rejects(before("shell", "2", { command: "ls" }), /does not grant shell/);
  assert.equal(await readFile(log, "utf8"), "", "refused calls never reach the write hooks");

  await before("read", "3", { path: "init.lua" });
  assert.equal(await after("read", "3", "contents"), "contents", "a read gets no verify report");
  assert.equal(await readFile(log, "utf8"), "", "a read runs no write hook");

  await before("edit", "4", { path: "init.lua", oldString: "a", newString: "b" });
  assert.match(await after("edit", "4", "Edited init.lua"), /^Edited init\.lua\n\n\[fieldguide\] boot OK/);
  assert.equal(await readFile(log, "utf8"), "--before-write init.lua\n--after-write init.lua\n");

  // Refused by the pre-write hook itself (pi's gate inside mcp.ts).
  await assert.rejects(before("write", "5", { path: "refuse-me.lua" }), /outside/);

  // Nothing printed by --after-write means nothing appended.
  await before("write", "6", { path: "quiet.lua" });
  assert.equal(await after("write", "6", "Wrote file."), "Wrote file.");

  // A write that failed has nothing to checkpoint or verify.
  await writeFile(log, "");
  await before("write", "11", { path: "failed.lua" });
  assert.equal(await after("write", "11", "EACCES", "error"), "EACCES");
  assert.equal(await readFile(log, "utf8"), "--before-write failed.lua\n", "no after-write for a failed write");

  // A post-write hook that fails is said, not mistaken for nothing to report:
  // the write landed without the checkpoint and verify it was promised.
  await before("write", "8", { path: "fail-after.lua" });
  assert.match(await after("write", "8", "Wrote file."), /^Wrote file\.\n\n\[fieldguide\] verify unavailable: .*checkpoint store is locked/);

  // A pre-write hook that never answers refuses the write, rather than holding
  // the tool call forever.
  process.env.FIELDGUIDE_PLUGIN_HOOK_TIMEOUT_MS = "500";
  await assert.rejects(before("write", "9", { path: "hang.lua" }), /did not answer/);
  delete process.env.FIELDGUIDE_PLUGIN_HOOK_TIMEOUT_MS;

  // A hook that cannot run at all refuses the write: no checkpoint, no write.
  process.env.FIELDGUIDE_NODE = path.join(root, "no-such-node");
  await assert.rejects(before("write", "7", { path: "a.lua" }));

  // ...and after a write, it is said rather than read as nothing to report.
  process.env.FIELDGUIDE_NODE = path.join(HERE, "fixtures/fake-write-hook.sh");
  await before("write", "10", { path: "b.lua" });
  process.env.FIELDGUIDE_NODE = path.join(root, "no-such-node");
  assert.match(await after("write", "10", "Wrote file."), /\[fieldguide\] verify unavailable/);
});

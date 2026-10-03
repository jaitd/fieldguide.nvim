// The gate in opencode's vocabulary, and the plugin that wires it in.
//
//   node --test tests/opencode.test.ts
//
// The same fixture as gate.test.ts: a symlinked config dir inside a larger repo
// with a secret in it, a symlink out, and a read-only doc zone. What is new here
// is where opencode hides paths — `filePath`, a patch body, a glob pattern — so
// that is what the table exercises.

import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import type { Zones } from "../extension/gate.ts";
import { decide, globRoot, patchPaths } from "../extension/harness/opencode-gate.ts";

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

const CASES: Case[] = [
  // --- allowed --------------------------------------------------------------
  { name: "read by filePath in the config", tool: "read", args: () => ({ filePath: "init.lua" }), allow: true },
  { name: "read a help file", tool: "read", args: () => ({ filePath: `${docs}/vim-fugitive/doc/fugitive.txt` }), allow: true },
  { name: "write a new file in the config", tool: "write", args: () => ({ filePath: "lua/new.lua", content: "" }), allow: true },
  { name: "edit in the config", tool: "edit", args: () => ({ filePath: "init.lua", oldString: "a", newString: "b" }), allow: true },
  { name: "multiedit in the config", tool: "multiedit", args: () => ({ filePath: "init.lua", edits: [] }), allow: true },
  { name: "apply_patch in the config", tool: "apply_patch", args: () => ({ patchText: patch("*** Update File: init.lua") }), allow: true },
  { name: "grep the doc zone", tool: "grep", args: () => ({ pattern: "Gwrite", path: docs, include: "*.txt" }), allow: true },
  { name: "grep with no path", tool: "grep", args: () => ({ pattern: "keymap" }), allow: true },
  { name: "glob a relative pattern", tool: "glob", args: () => ({ pattern: "**/*.lua" }), allow: true },
  { name: "glob a relative pattern under a config subdirectory", tool: "glob", args: () => ({ pattern: "lua/**/*.lua" }), allow: true },
  { name: "glob an absolute pattern into the docs", tool: "glob", args: () => ({ pattern: `${docs}/**/*.txt` }), allow: true },
  { name: "list the config", tool: "list", args: () => ({ path: "." }), allow: true },
  { name: "fieldguide's own MCP tool", tool: "fieldguide_nvim_state", args: () => ({}), allow: true },
  { name: "the todo list", tool: "todowrite", args: () => ({ todos: [] }), allow: true },

  // --- refused: tools fieldguide does not grant -----------------------------
  { name: "a shell", tool: "bash", args: () => ({ command: "cat /etc/passwd" }), allow: false },
  { name: "the network", tool: "webfetch", args: () => ({ url: "https://example.com" }), allow: false },
  { name: "a subagent", tool: "task", args: () => ({ prompt: "x" }), allow: false },
  { name: "a tool this gate has never heard of", tool: "shiny_new_tool", args: () => ({}), allow: false },
  { name: "another MCP server's tool", tool: "github_create_issue", args: () => ({}), allow: false },
  { name: "a lookalike of ours from another server", tool: "fieldguide2_nvim_state", args: () => ({}), allow: false },

  // --- refused: paths out of the zones --------------------------------------
  { name: "read ../ out of the config", tool: "read", args: () => ({ filePath: "../../../secrets.env" }), allow: false },
  { name: "read through a symlink out", tool: "read", args: () => ({ filePath: "escape/secrets.env" }), allow: false },
  { name: "read /etc/passwd", tool: "read", args: () => ({ filePath: "/etc/passwd" }), allow: false },
  { name: "write a help file", tool: "write", args: () => ({ filePath: `${docs}/vim-fugitive/doc/fugitive.txt`, content: "" }), allow: false },
  { name: "a file tool with no filePath", tool: "read", args: () => ({ path: "init.lua" }), allow: false },
  { name: "a filePath that is not a string", tool: "edit", args: () => ({ filePath: ["init.lua"] }), allow: false },
  { name: "list outside", tool: "list", args: () => ({ path: root }), allow: false },
  { name: "grep through the symlink out", tool: "grep", args: () => ({ pattern: "TOKEN", path: "escape" }), allow: false },
  { name: "grep with an include that climbs", tool: "grep", args: () => ({ pattern: "TOKEN", include: "../../*.env" }), allow: false },
  { name: "glob a pattern that climbs", tool: "glob", args: () => ({ pattern: "../../../*.env" }), allow: false },
  // No `..`, but its fixed prefix is a symlink in the config tree that leads out.
  { name: "glob a relative pattern through the symlink out", tool: "glob", args: () => ({ pattern: "escape/*.env" }), allow: false },
  { name: "grep with an include through the symlink out", tool: "grep", args: () => ({ pattern: "TOKEN", include: "escape/*.env" }), allow: false },
  { name: "glob an absolute pattern outside", tool: "glob", args: () => ({ pattern: `${root}/dotfiles/*.env` }), allow: false },
  { name: "glob with a path outside", tool: "glob", args: () => ({ pattern: "*", path: "/etc" }), allow: false },

  // --- refused: patches ----------------------------------------------------
  { name: "a patch that adds a file outside", tool: "apply_patch", args: () => ({ patchText: patch("*** Add File: ../../../evil.lua") }), allow: false },
  {
    name: "a patch whose second file is outside",
    tool: "apply_patch",
    args: () => ({ patchText: patch("*** Update File: init.lua", "*** Delete File: /etc/hosts") }),
    allow: false,
  },
  {
    name: "a patch that moves a config file out",
    tool: "apply_patch",
    args: () => ({ patchText: patch("*** Update File: init.lua", "*** Move to: ../../../stolen.lua") }),
    allow: false,
  },
  { name: "a patch into the doc zone", tool: "apply_patch", args: () => ({ patchText: patch(`*** Update File: ${docs}/x.txt`) }), allow: false },
  { name: "a patch that does not parse", tool: "apply_patch", args: () => ({ patchText: "rm -rf ~" }), allow: false },
  { name: "a patch naming no files", tool: "apply_patch", args: () => ({ patchText: "*** Begin Patch\n*** End Patch" }), allow: false },
  { name: "a patch with no text", tool: "apply_patch", args: () => ({}), allow: false },
];

for (const c of CASES) {
  test(`${c.allow ? "allow" : "block"}: ${c.name}`, async () => {
    const verdict = await decide(c.tool, c.args(), zones);
    assert.equal(verdict.allow, c.allow, verdict.allow ? "allowed" : (verdict as { reason: string }).reason);
  });
}

test("writes report every file they touch, reads none", async () => {
  const p = await decide("apply_patch", { patchText: patch("*** Update File: init.lua", "*** Move to: lua/moved.lua") }, zones);
  assert.deepEqual(p.writes, ["init.lua", "lua/moved.lua"]);
  assert.deepEqual((await decide("write", { filePath: "a.lua" }, zones)).writes, ["a.lua"]);
  assert.equal((await decide("read", { filePath: "init.lua" }, zones)).writes, undefined);
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

  const mod = await import("../extension/harness/opencode-plugin.ts");
  // opencode calls every exported function as a plugin.
  assert.deepEqual(Object.keys(mod), ["FieldguidePlugin"]);
  const hooks = await mod.FieldguidePlugin({ directory: zones.cwd });
  const before = hooks["tool.execute.before"];
  const after = hooks["tool.execute.after"];

  await assert.rejects(before({ tool: "read", callID: "1" }, { args: { filePath: "../../../secrets.env" } }), /outside/);
  await assert.rejects(before({ tool: "bash", callID: "2" }, { args: { command: "ls" } }), /does not grant bash/);
  assert.equal(await readFile(log, "utf8"), "", "refused calls never reach the write hooks");

  await before({ tool: "read", callID: "3" }, { args: { filePath: "init.lua" } });
  const readOut = { output: "contents" };
  await after({ tool: "read", callID: "3" }, readOut);
  assert.equal(readOut.output, "contents", "a read gets no verify report");
  assert.equal(await readFile(log, "utf8"), "", "a read runs no write hook");

  await before({ tool: "edit", callID: "4" }, { args: { filePath: "init.lua", oldString: "a", newString: "b" } });
  const editOut = { output: "Edit applied." };
  await after({ tool: "edit", callID: "4" }, editOut);
  assert.match(editOut.output, /^Edit applied\.\n\n\[fieldguide\] boot OK/);
  assert.equal(await readFile(log, "utf8"), "--before-write init.lua\n--after-write init.lua\n");

  // Refused by the pre-write hook itself (pi's gate inside mcp.ts).
  await assert.rejects(before({ tool: "write", callID: "5" }, { args: { filePath: "refuse-me.lua" } }), /outside/);

  // Nothing printed by --after-write means nothing appended.
  await before({ tool: "write", callID: "6" }, { args: { filePath: "quiet.lua" } });
  const quietOut = { output: "Wrote file." };
  await after({ tool: "write", callID: "6" }, quietOut);
  assert.equal(quietOut.output, "Wrote file.");

  // A post-write hook that fails is said, not mistaken for nothing to report:
  // the write landed without the checkpoint and verify it was promised.
  await before({ tool: "write", callID: "8" }, { args: { filePath: "fail-after.lua" } });
  const failedOut = { output: "Wrote file." };
  await after({ tool: "write", callID: "8" }, failedOut);
  assert.match(failedOut.output, /^Wrote file\.\n\n\[fieldguide\] verify unavailable: .*checkpoint store is locked/);

  // A pre-write hook that never answers refuses the write, rather than holding
  // the tool call forever.
  process.env.FIELDGUIDE_PLUGIN_HOOK_TIMEOUT_MS = "500";
  await assert.rejects(before({ tool: "write", callID: "9" }, { args: { filePath: "hang.lua" } }), /did not answer/);
  delete process.env.FIELDGUIDE_PLUGIN_HOOK_TIMEOUT_MS;

  // A hook that cannot run at all refuses the write: no checkpoint, no write.
  process.env.FIELDGUIDE_NODE = path.join(root, "no-such-node");
  await assert.rejects(before({ tool: "write", callID: "7" }, { args: { filePath: "a.lua" } }));

  // ...and after a write, it is said rather than read as nothing to report.
  process.env.FIELDGUIDE_NODE = path.join(HERE, "fixtures/fake-write-hook.sh");
  await before({ tool: "write", callID: "10" }, { args: { filePath: "b.lua" } });
  process.env.FIELDGUIDE_NODE = path.join(root, "no-such-node");
  const missingOut = { output: "Wrote file." };
  await after({ tool: "write", callID: "10" }, missingOut);
  assert.match(missingOut.output, /\[fieldguide\] verify unavailable/);
});

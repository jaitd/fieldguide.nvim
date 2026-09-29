// Claude Code's PreToolUse / PostToolUse hook: the gate, spoken in Claude's
// tool names, and the verify that follows a write.
//
//   node --test tests/claude-hook.test.ts
//
// The table half calls `decide` directly. The process half runs the hook the
// way Claude does — JSON on stdin, JSON on stdout — because the failure modes
// that matter here (a crash, an unset zone) are about the process, not the
// function: Claude runs the tool anyway when a hook merely errors.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { after, before, describe, test } from "node:test";

import { decide, DENY_PREFIX, patternRoot, type HookEvent } from "../extension/harness/claude-hook.ts";
import type { Zones } from "../extension/gate.ts";

const REPO = path.resolve(import.meta.dirname, "..");
const HOOK = path.join(REPO, "extension/harness/claude-hook.ts");

//   root/
//     config/            <- config zone (rw); cwd
//       init.lua
//       lua/
//       link -> ../outside
//     docs/doc/x.txt     <- doc zone (ro)
//     outside/secret.txt <- neither
let root: string;
let zones: Zones;

before(async () => {
  root = await realpath(await mkdtemp(path.join(tmpdir(), "fieldguide-claude-hook-")));
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

const ev = (tool_name: string, tool_input: Record<string, unknown>): HookEvent => ({
  hook_event_name: "PreToolUse",
  tool_name,
  tool_input,
  cwd: zones.cwd,
});

describe("decide", () => {
  const cases: [string, string, Record<string, unknown>, boolean][] = [
    ["Read in config", "Read", { file_path: "init.lua" }, true],
    ["Read absolute in config", "Read", { file_path: "@@CONFIG@@/init.lua" }, true],
    ["Read in docs", "Read", { file_path: "@@DOCS@@/doc/x.txt" }, true],
    ["Read outside", "Read", { file_path: "../outside/secret.txt" }, false],
    ["Read through a symlink out", "Read", { file_path: "link/secret.txt" }, false],
    ["Write in config", "Write", { file_path: "lua/new.lua", content: "" }, true],
    ["Write in docs", "Write", { file_path: "@@DOCS@@/doc/new.txt", content: "" }, false],
    ["Edit in docs", "Edit", { file_path: "@@DOCS@@/doc/x.txt", old_string: "a", new_string: "b" }, false],
    ["MultiEdit outside", "MultiEdit", { file_path: "../outside/secret.txt", edits: [] }, false],
    ["NotebookEdit outside", "NotebookEdit", { notebook_path: "../outside/n.ipynb", new_source: "" }, false],
    ["Grep with no path", "Grep", { pattern: "x" }, true],
    ["Grep in docs", "Grep", { pattern: "x", path: "@@DOCS@@" }, true],
    ["Grep outside", "Grep", { pattern: "x", path: "../outside" }, false],
    ["Grep through the link", "Grep", { pattern: "x", path: "link" }, false],
    ["Grep glob climbing", "Grep", { pattern: "x", glob: "../outside/**" }, false],
    ["Grep glob absolute", "Grep", { pattern: "x", glob: "/etc/*" }, false],
    ["Grep glob ordinary", "Grep", { pattern: "x", glob: "*.lua" }, true],
    ["Glob ordinary", "Glob", { pattern: "**/*.lua" }, true],
    ["Glob pattern climbing", "Glob", { pattern: "../outside/*" }, false],
    ["Glob pattern absolute outside", "Glob", { pattern: "@@ROOT@@/outside/*" }, false],
    ["Glob pattern absolute in docs", "Glob", { pattern: "@@DOCS@@/**/*.txt" }, true],
    ["Glob climbing after a wildcard", "Glob", { pattern: "**/../../outside/*" }, false],
    ["Glob climbing from its path", "Glob", { pattern: "../../outside/*", path: "lua" }, false],
    ["Glob climbing within config", "Glob", { pattern: "../*.lua", path: "lua" }, true],
    ["Glob path outside", "Glob", { pattern: "*", path: "../outside" }, false],
    ["a dotted name is not a climb", "Read", { file_path: "lua/a..b.lua" }, true],
    ["our MCP verbs", "mcp__fieldguide__nvim_state", { what: "nvim" }, true],
    ["someone else's MCP", "mcp__other__read", {}, false],
    ["Bash", "Bash", { command: "cat ../outside/secret.txt" }, false],
    ["WebFetch", "WebFetch", { url: "https://example.com" }, false],
  ];

  for (const [name, tool, input, allowed] of cases) {
    test(`${allowed ? "allows" : "denies"}: ${name}`, async () => {
      const fill = (v: unknown) =>
        typeof v === "string"
          ? v
              .replace("@@CONFIG@@", zones.configRoot)
              .replace("@@DOCS@@", zones.docRoots[0])
              .replace("@@ROOT@@", root)
          : v;
      const filled = Object.fromEntries(Object.entries(input).map(([k, v]) => [k, fill(v)]));
      const d = await decide(ev(tool, filled), zones);
      assert.equal(d.allow, allowed, d.allow ? "allowed" : d.reason);
    });
  }

  test("denies everything file-shaped when the config zone is unset", async () => {
    const d = await decide(ev("Read", { file_path: "init.lua" }), { ...zones, configRoot: "" });
    assert.equal(d.allow, false);
  });
});

describe("patternRoot", () => {
  test("leaves ordinary patterns alone", () => {
    assert.deepEqual(patternRoot("**/*.lua"), {});
    assert.deepEqual(patternRoot("lua/*.lua"), {});
  });
  test("finds the directory an absolute pattern names", () => {
    assert.deepEqual(patternRoot("/a/b/*.lua"), { root: "/a/b" });
    assert.deepEqual(patternRoot("/a/b/init*"), { root: "/a/b" });
    assert.deepEqual(patternRoot("/*"), { root: "/" });
  });
  test("refuses a climb it cannot place", () => {
    assert.ok(patternRoot("**/../x").refuse);
  });
});

// ---------------------------------------------------------------------------
// As a process.
// ---------------------------------------------------------------------------

function runHook(hook: string, mode: string, input: string, env: Record<string, string> = {}) {
  return spawnSync(process.execPath, [hook, mode], {
    input,
    encoding: "utf8",
    env: {
      PATH: process.env.PATH ?? "",
      FIELDGUIDE_CONFIG_DIR: zones.configRoot,
      FIELDGUIDE_DOC_ROOTS: zones.docRoots.join(":"),
      FIELDGUIDE_VERBS: "state,verify",
      // A checkpoint needs a Neovim on a socket; none here, and it must not
      // matter to the decision.
      FIELDGUIDE_BIN: "",
      ...env,
    },
  });
}

describe("the hook process", () => {
  test("a denial is a PreToolUse deny, with a reason the panel can recognise", () => {
    const res = runHook(HOOK, "pre", JSON.stringify(ev("Read", { file_path: "../outside/secret.txt" })));
    assert.equal(res.status, 0, res.stderr);
    const out = JSON.parse(res.stdout);
    assert.equal(out.hookSpecificOutput.permissionDecision, "deny");
    assert.ok(out.hookSpecificOutput.permissionDecisionReason.startsWith(DENY_PREFIX));
    assert.ok(!res.stdout.includes("CANARY"));
  });

  test("an allowed call prints nothing, which Claude reads as no opinion", () => {
    const res = runHook(HOOK, "pre", JSON.stringify(ev("Read", { file_path: "init.lua" })));
    assert.equal(res.status, 0, res.stderr);
    assert.equal(res.stdout, "");
  });

  test("unreadable input exits 2, the one failure Claude treats as blocking", () => {
    const res = runHook(HOOK, "pre", "not json");
    assert.equal(res.status, 2);
  });

  test("with no zone configured, a read inside the would-be config is still denied", () => {
    const res = runHook(HOOK, "pre", JSON.stringify(ev("Read", { file_path: "init.lua" })), {
      FIELDGUIDE_CONFIG_DIR: "",
    });
    assert.equal(JSON.parse(res.stdout).hookSpecificOutput.permissionDecision, "deny");
  });

  describe("post-write", () => {
    // A copy of the extension tree with a stand-in for mcp.ts, because the hook
    // finds the server next to itself, and a symlinked copy would resolve back
    // to the real tree.
    let tree: string;
    before(async () => {
      tree = path.join(root, "plugin");
      await mkdir(path.join(tree, "extension/harness"), { recursive: true });
      await copyFile(path.join(REPO, "extension/gate.ts"), path.join(tree, "extension/gate.ts"));
      await copyFile(HOOK, path.join(tree, "extension/harness/claude-hook.ts"));
    });

    const hook = () => path.join(tree, "extension/harness/claude-hook.ts");
    const writeEvent = (file_path: string) => JSON.stringify(ev("Write", { file_path, content: "x" }));
    const decision = (stdout: string) => (stdout ? JSON.parse(stdout).hookSpecificOutput.permissionDecision : "none");

    test("a write with no server to checkpoint it is denied", async () => {
      await rm(path.join(tree, "extension/mcp.ts"), { force: true });
      const res = runHook(hook(), "pre", writeEvent("init.lua"));
      assert.equal(decision(res.stdout), "deny");
      assert.match(res.stdout, /cannot checkpoint/);
    });

    test("a write the server refuses (exit 2) is denied with its reason", async () => {
      await writeFile(
        path.join(tree, "extension/mcp.ts"),
        `if (process.argv[2] === "--before-write") { console.error("nope: " + process.argv[3]); process.exit(2); }\n`,
      );
      const res = runHook(hook(), "pre", writeEvent("init.lua"));
      assert.equal(decision(res.stdout), "deny");
      assert.ok(res.stdout.includes(`nope: ${path.join(zones.configRoot, "init.lua")}`));
    });

    test("a write the server checkpointed (exit 0) goes ahead", async () => {
      await writeFile(path.join(tree, "extension/mcp.ts"), `process.exit(0);\n`);
      const res = runHook(hook(), "pre", writeEvent("init.lua"));
      assert.equal(res.status, 0, res.stderr);
      assert.equal(decision(res.stdout), "none");
    });

    test("the server is not asked about a write the gate already refused", async () => {
      await writeFile(path.join(tree, "extension/mcp.ts"), `process.exit(0);\n`);
      const res = runHook(hook(), "pre", writeEvent(path.join(zones.docRoots[0], "doc/new.txt")));
      assert.equal(decision(res.stdout), "deny");
      assert.match(res.stdout, /read-only/);
    });

    const postEvent = (file_path: string, id = "toolu_1") =>
      JSON.stringify({
        hook_event_name: "PostToolUse",
        tool_name: "Edit",
        tool_use_id: id,
        tool_input: { file_path, old_string: "a", new_string: "b" },
        tool_response: {},
        cwd: zones.cwd,
      });

    test("says so when the server is missing, rather than staying quiet", async () => {
      await rm(path.join(tree, "extension/mcp.ts"), { force: true });
      const res = runHook(path.join(tree, "extension/harness/claude-hook.ts"), "post", postEvent("init.lua"));
      assert.equal(res.status, 0, res.stderr);
      const out = JSON.parse(res.stdout);
      assert.match(out.hookSpecificOutput.additionalContext, /verify unavailable/);
    });

    test("hands the verify paragraph to the model and names the tool call it belongs to", async () => {
      await writeFile(
        path.join(tree, "extension/mcp.ts"),
        `if (process.argv[2] === "--after-write") console.log("[fieldguide] boot OK, 7ms for " + process.argv[3]);\n`,
      );
      const res = runHook(path.join(tree, "extension/harness/claude-hook.ts"), "post", postEvent("init.lua", "toolu_X"));
      assert.equal(res.status, 0, res.stderr);
      const out = JSON.parse(res.stdout);
      const expected = `[fieldguide] boot OK, 7ms for ${path.join(zones.configRoot, "init.lua")}`;
      assert.equal(out.hookSpecificOutput.hookEventName, "PostToolUse");
      assert.equal(out.hookSpecificOutput.additionalContext, expected);
      assert.deepEqual(out.fieldguide, { tool_use_id: "toolu_X", verify: expected });
    });

    test("empty output from the server attaches nothing", async () => {
      await writeFile(path.join(tree, "extension/mcp.ts"), `process.exit(0);\n`);
      const res = runHook(path.join(tree, "extension/harness/claude-hook.ts"), "post", postEvent("init.lua"));
      assert.equal(res.status, 0, res.stderr);
      assert.equal(res.stdout, "");
    });

    test("a server that fails is reported, not swallowed", async () => {
      await writeFile(path.join(tree, "extension/mcp.ts"), `console.error("socket gone"); process.exit(1);\n`);
      const res = runHook(path.join(tree, "extension/harness/claude-hook.ts"), "post", postEvent("init.lua"));
      assert.match(JSON.parse(res.stdout).hookSpecificOutput.additionalContext, /verify unavailable: socket gone/);
    });

    test("a write outside the config zone is not verified", () => {
      const res = runHook(
        path.join(tree, "extension/harness/claude-hook.ts"),
        "post",
        postEvent(path.join(zones.docRoots[0], "doc/x.txt")),
      );
      assert.equal(res.stdout, "");
    });

    test("nothing to verify when verify is not an enabled verb", () => {
      const res = runHook(path.join(tree, "extension/harness/claude-hook.ts"), "post", postEvent("init.lua"), {
        FIELDGUIDE_VERBS: "state",
      });
      assert.equal(res.stdout, "");
    });
  });
});

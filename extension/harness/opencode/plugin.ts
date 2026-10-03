// fieldguide's opencode plugin: the pi extension's hooks, on opencode v2's.
//
//   execute.before  the three-zone gate (../opencode-gate.ts), then for a write,
//                   `mcp.ts --before-write`: pi's own pre-write gate and
//                   checkpoint, so undo means the same thing here
//   execute.after   `mcp.ts --after-write`: checkpoint and verify, with the
//                   report added to the tool's result, where the model reads it
//                   before its next step
//
// opencode v2 loads this directory through index.js and calls the default
// export's `setup(ctx)`, nothing else: v1's `server()` hooks are never run.
// The hooks are registered on `ctx.tool.hook`. Throwing from execute.before is
// how a call is refused, and the message is what the model reads.
//
// A plugin that silently fails to load is a gate that is silently off, and v2
// says so in nothing but its log. So once the hooks are registered this
// writes the file named by FIELDGUIDE_GATE_READY, and fieldguide refuses the
// session when that file never appears. Never run opencode with --pure: it
// drops this plugin too.

import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { decide } from "../opencode-gate.ts";

const MCP = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "mcp.ts");

type Run = { code: number | null; stdout: string; stderr: string };

// How long each hook may take: past mcp.ts's own wait on the server (75s for
// a pre-write, one verb; 135s for a post-write, two), so its answer arrives
// first when there is one. A hook that outlives this is killed, and the
// server abandons the work when its connection drops.
const HOOK_TIMEOUT_MS = { "--before-write": 80_000, "--after-write": 140_000 };

/** A hook entry point of the MCP server, run from the config tree. */
function runHook(mode: "--before-write" | "--after-write", target: string, cwd: string): Promise<Run> {
  const limit = Number(process.env.FIELDGUIDE_PLUGIN_HOOK_TIMEOUT_MS) || HOOK_TIMEOUT_MS[mode];
  return new Promise((resolve) => {
    // node, not this process: opencode runs plugins in its own runtime, and
    // mcp.ts leans on node's module hooks.
    const child = spawn(process.env.FIELDGUIDE_NODE || "node", [MCP, mode, target], {
      cwd,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (d: string) => (stdout += d));
    child.stderr.on("data", (d: string) => (stderr += d));
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      resolve({ code: null, stdout, stderr: `${mode} did not answer within ${limit / 1000}s` });
    }, limit);
    const done = (run: Run) => {
      clearTimeout(timer);
      resolve(run);
    };
    child.on("error", (err) => done({ code: null, stdout, stderr: String(err) }));
    child.on("close", (code) => done({ code, stdout, stderr }));
  });
}

/** The slice of opencode v2's plugin context this plugin uses. */
type Ctx = {
  location: { directory: string };
  tool: { hook: (name: string, fn: (event: ToolEvent) => unknown) => Promise<unknown> };
};

/** What v2 hands execute.before and execute.after. */
export type ToolEvent = {
  tool: string;
  id: string;
  input?: Record<string, unknown>;
  status?: string;
  result?: { content?: { type: string; text?: string }[] };
};

async function setup(ctx: Ctx) {
  const directory = ctx.location.directory;
  // The same variables the pi extension reads, from the same `env.agent()`.
  // Unset means an empty config root, and an empty root admits nothing.
  const zones = {
    cwd: directory,
    configRoot: process.env.FIELDGUIDE_CONFIG_DIR || "",
    docRoots: (process.env.FIELDGUIDE_DOC_ROOTS || "").split(":").filter(Boolean),
  };
  // What each write touched, from before to after, by tool call id.
  const writes = new Map<string, string[]>();

  await ctx.tool.hook("execute.before", async (event) => {
    const verdict = await decide(event.tool, event.input ?? {}, zones);
    if (!verdict.allow) throw new Error(verdict.reason);
    if (!verdict.writes?.length) return;

    for (const target of verdict.writes) {
      const run = await runHook("--before-write", target, directory);
      if (run.code !== 0) {
        // 2 is a refusal with its reason; anything else is the hook itself
        // failing, and a write with no checkpoint behind it is not one to let
        // through.
        throw new Error(run.stderr.trim() || `fieldguide: pre-write hook failed (exit ${run.code})`);
      }
    }
    writes.set(event.id, verdict.writes);
  });

  await ctx.tool.hook("execute.after", async (event) => {
    const touched = writes.get(event.id);
    writes.delete(event.id);
    // Nothing written, or the write failed and has nothing to checkpoint.
    if (!touched?.length || event.status !== "completed") return;
    // One report per write, as pi gives: the first path is the one it names.
    const run = await runHook("--after-write", touched[0], directory);
    // The write has landed either way, so a failure is said, not thrown: a
    // hook that failed or never started means no checkpoint and no verify,
    // and silence would read as a clean boot.
    const report =
      run.code === 0 ? run.stdout.trim() : `[fieldguide] verify unavailable: ${run.stderr.trim() || `exit ${run.code}`}`;
    // Empty is "nothing to attach": a path outside the config, or verify off.
    if (report && event.result) (event.result.content ??= []).push({ type: "text", text: report });
  });

  // Said once both hooks are in place, so a setup that throws above never
  // claims to be ready.
  if (process.env.FIELDGUIDE_GATE_READY) writeFileSync(process.env.FIELDGUIDE_GATE_READY, `${process.pid}\n`);
}

export default { id: "fieldguide", setup };

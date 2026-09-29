// fieldguide's opencode plugin: the pi extension's hooks, on opencode's.
//
//   tool.execute.before  the three-zone gate (./opencode-gate.ts), then for a
//                        write, `mcp.ts --before-write`: pi's own pre-write
//                        gate and checkpoint, so undo means the same thing here
//   tool.execute.after   `mcp.ts --after-write`: checkpoint and verify, with the
//                        report appended to the tool's output, where the model
//                        reads it before its next step
//
// Loaded through the `plugin` list of the config fieldguide generates. Never
// run opencode with --pure: it drops this plugin too, and the gate with it,
// without a word.
//
// Only the plugin is exported. opencode treats every exported function as a
// plugin, so the logic lives in ./opencode-gate.ts.

import { spawn } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { decide } from "./opencode-gate.ts";

const MCP = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "mcp.ts");

type Run = { code: number | null; stdout: string; stderr: string };

/** A hook entry point of the MCP server, run from the config tree. */
function runHook(mode: "--before-write" | "--after-write", target: string, cwd: string): Promise<Run> {
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
    child.on("error", (err) => resolve({ code: null, stdout, stderr: String(err) }));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

export const FieldguidePlugin = async ({ directory }: { directory: string }) => {
  // The same variables the pi extension reads, from the same `env.agent()`.
  // Unset means an empty config root, and an empty root admits nothing.
  const zones = {
    cwd: directory,
    configRoot: process.env.FIELDGUIDE_CONFIG_DIR || "",
    docRoots: (process.env.FIELDGUIDE_DOC_ROOTS || "").split(":").filter(Boolean),
  };
  // What each write touched, from `before` to `after`: opencode does not hand
  // the arguments to the second hook.
  const writes = new Map<string, string[]>();

  return {
    "tool.execute.before": async (
      input: { tool: string; callID?: string },
      output: { args: Record<string, unknown> },
    ) => {
      const verdict = await decide(input.tool, output.args, zones);
      // Throwing is how an opencode hook refuses a call; the message becomes
      // the tool's error, which the model reads.
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
      if (input.callID) writes.set(input.callID, verdict.writes);
    },

    "tool.execute.after": async (input: { tool: string; callID?: string }, output: { output?: string }) => {
      const touched = input.callID ? writes.get(input.callID) : undefined;
      if (!touched?.length) return;
      writes.delete(input.callID!);
      // One report per write, as pi gives: the first path is the one it names.
      const run = await runHook("--after-write", touched[0], directory);
      const report = run.stdout.trim();
      // Empty is "nothing to attach": a path outside the config, or verify off.
      if (report) output.output = `${output.output ?? ""}\n\n${report}`;
    },
  };
};

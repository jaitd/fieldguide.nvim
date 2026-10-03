// Codex's side of the path gate: a PreToolUse / PostToolUse command hook.
//
//   node extension/harness/codex-hook.ts pre    < hook event on stdin
//   node extension/harness/codex-hook.ts post   < hook event on stdin
//   node extension/harness/codex-hook.ts stop   < Stop event on stdin
//   node extension/harness/codex-hook.ts prompt < UserPromptSubmit event on stdin
//
// Codex has no file tools of its own beyond `apply_patch`: it reads, and can
// write, through its shell, and a hook sees a shell call only as a command
// string. So reads are not gated here at all. The agent sandbox around Codex
// is the read gate, and the profile refuses to launch without one. What is
// gated here is what a hook can see whole:
//
//   apply_patch       every path the patch names, through gate.ts's checkAccess,
//                     then the pre-write checkpoint; checkpoint and verify after
//   Bash              allowed, the sandbox bounding it; checkpoint and verify
//                     after any command that changed the config tree
//   (end of turn)     the same, for a write a backgrounded command made later
//   (next prompt)     the same, for anything changed since the last look
//   mcp__fieldguide__ our own verbs, narrowed on the Neovim side
//
// Anything else is refused. A refusal is exit 2 with the reason on stderr,
// the one answer Codex treats as blocking.
//
// Whether the config tree changed is the MCP server's to know, not this
// hook's: the hook runs inside the sandbox, where anything it kept the agent
// could rewrite. The server, outside, fingerprints the tree and remembers it.

import { readFileSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { checkAccess, isUnder, resolveTarget, type Decision, type Zones } from "../gate.ts";
import { patchPaths } from "./patch.ts";
import { afterWrite, beforeWrite, hookEnv, treeAfter, treeBefore } from "./write-hooks.ts";

export const MCP_PREFIX = "mcp__fieldguide__";

// Prefixed so a gate refusal reads differently from a tool that failed.
export const DENY_PREFIX = "blocked by fieldguide: ";

/** Tools let through that touch nothing: the model's own plan. */
const PASS = new Set(["update_plan"]);

export type HookEvent = {
  hook_event_name?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  tool_use_id?: string;
  tool_response?: unknown;
  cwd?: string;
};

export type Verdict = Decision & { writes?: string[] };

/** The patch text, wherever this Codex puts it. */
function patchText(input: Record<string, unknown>): unknown {
  return input.command ?? input.patch ?? input.input;
}

export async function decide(ev: HookEvent, zones: Zones): Promise<Verdict> {
  const name = ev.tool_name ?? "";
  const input = ev.tool_input ?? {};

  if (name.startsWith(MCP_PREFIX) || PASS.has(name)) return { allow: true };

  // Without a config root there is no zone to be inside, and allowing would
  // mean allowing everything.
  if (!zones.configRoot) {
    return { allow: false, reason: "FIELDGUIDE_CONFIG_DIR is unset, so the path gate has no zones" };
  }

  // The sandbox is the gate for a shell: see the top of this file.
  if (name === "Bash") return { allow: true };

  if (name === "apply_patch") {
    const paths = patchPaths(patchText(input));
    if (!paths) return { allow: false, reason: "apply_patch: could not read which files the patch touches" };
    for (const p of paths) {
      const d = await checkAccess("edit", { path: p }, zones);
      if (!d.allow) return d;
    }
    return { allow: true, writes: paths };
  }

  return { allow: false, reason: `fieldguide does not grant ${name || "this tool"}` };
}

// ---------------------------------------------------------------------------
// The hooks.
// ---------------------------------------------------------------------------

/** Whether a PostToolUse event reports a call that went through. */
function succeeded(ev: HookEvent): boolean {
  if (ev.hook_event_name && ev.hook_event_name !== "PostToolUse") return false;
  const res = ev.tool_response;
  if (res && typeof res === "object") {
    const r = res as Record<string, unknown>;
    if (r.success === false || r.is_error === true || (typeof r.error === "string" && r.error !== "")) return false;
  }
  return true;
}

/** Null to let the call through, or why not. */
async function pre(ev: HookEvent): Promise<string | null> {
  const { zones, verbs } = hookEnv();
  const cwd = ev.cwd || process.cwd();
  const z = zones(cwd);
  const verdict = await decide(ev, z);
  if (!verdict.allow) return verdict.reason;
  if (!verbs.has("verify")) return null;

  if (ev.tool_name === "apply_patch") {
    for (const raw of verdict.writes ?? []) {
      const target = await resolveTarget(cwd, raw);
      if (!isUnder(target, z.configRoot)) continue;
      const before = beforeWrite(target);
      if (!before.allow) return before.reason;
    }
    return null;
  }

  if (ev.tool_name === "Bash") {
    // The user's own edits since the last checkpoint, committed now, so what
    // this command does is undoable on its own.
    const before = treeBefore();
    if (!before.allow) return before.reason;
  }
  return null;
}

/** The checkpoint-and-verify paragraph for the model, or null for nothing. */
async function post(ev: HookEvent): Promise<string | null> {
  const { zones, verbs } = hookEnv();
  if (!verbs.has("verify")) return null;
  const cwd = ev.cwd || process.cwd();
  const z = zones(cwd);

  if (ev.tool_name === "apply_patch") {
    if (!succeeded(ev)) return null;
    const paths = patchPaths(patchText(ev.tool_input ?? {})) ?? [];
    for (const raw of paths) {
      const target = await resolveTarget(cwd, raw);
      if (!isUnder(target, z.configRoot)) continue;
      // One report per write, as pi gives: the first config path is the one
      // it names.
      return afterWrite(target) || null;
    }
    return null;
  }

  if (ev.tool_name === "Bash") {
    // Unchanged (an `ls`, a `cat`): the server says nothing, at no cost.
    return treeAfter() || null;
  }
  return null;
}

async function main(mode: string): Promise<void> {
  if (mode === "check") {
    process.stdout.write("ok\n");
    return;
  }
  // End of turn: anything a backgrounded command wrote after the last hook
  // looked is checkpointed and verified now. Codex shows a Stop hook's output
  // nowhere, so a report goes to the model as a block: the turn carries on
  // just long enough for it to answer. Once only: a turn this hook already
  // kept going (`stop_hook_active`) is let end without looking, so a later
  // change stays unhandled on the server and the next prompt reports it.
  if (mode === "stop") {
    let active = false;
    try {
      active = (JSON.parse(readFileSync(0, "utf8")) as { stop_hook_active?: boolean }).stop_hook_active === true;
    } catch {}
    if (active || !hookEnv().verbs.has("verify")) return;
    const text = treeAfter();
    if (text) {
      process.stdout.write(
        JSON.stringify({
          decision: "block",
          reason: `A write to the config was found after your last tool call, and checked:\n${text}`,
        }),
      );
    }
    return;
  }
  // A new prompt: whatever changed since the last look, a write the end of
  // the last turn let pass or the user's own edits, is checkpointed and
  // verified, and the report goes in with the prompt.
  if (mode === "prompt") {
    try {
      readFileSync(0);
    } catch {}
    if (!hookEnv().verbs.has("verify")) return;
    const text = treeAfter();
    if (text) {
      process.stdout.write(
        JSON.stringify({
          hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext: `The config changed since the last turn, and was checked:\n${text}`,
          },
        }),
      );
    }
    return;
  }
  let ev: HookEvent;
  try {
    ev = JSON.parse(readFileSync(0, "utf8")) as HookEvent;
  } catch (err) {
    process.stderr.write(`${DENY_PREFIX}unreadable hook input: ${String(err)}\n`);
    process.exit(2);
  }
  if (mode === "pre") {
    let reason: string | null;
    try {
      reason = await pre(ev);
    } catch (err) {
      reason = `the gate failed: ${String(err)}`;
    }
    if (reason !== null) {
      process.stderr.write(DENY_PREFIX + reason + "\n");
      process.exit(2);
    }
  } else if (mode === "post") {
    const text = await post(ev);
    if (text) {
      process.stdout.write(
        JSON.stringify({ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: text } }),
      );
    }
  } else {
    process.stderr.write(`codex-hook: unknown mode ${mode}\n`);
    process.exit(2);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  // Exit 2 is the one failure Codex treats as blocking. Reached only if
  // something throws outside the handled paths above. Not for the reports:
  // to Stop, 2 keeps the agent going, and to UserPromptSubmit it drops the
  // user's prompt.
  const report = process.argv[2] === "stop" || process.argv[2] === "prompt";
  const bail = (err: unknown) => {
    process.stderr.write(`${DENY_PREFIX}${String(err)}\n`);
    process.exit(report ? 1 : 2);
  };
  process.on("uncaughtException", bail);
  process.on("unhandledRejection", bail);
  await main(process.argv[2] ?? "");
}


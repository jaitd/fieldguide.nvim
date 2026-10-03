// Codex's side of the path gate: a PreToolUse / PostToolUse command hook.
//
//   node extension/harness/codex-hook.ts pre    < hook event on stdin
//   node extension/harness/codex-hook.ts post   < hook event on stdin
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
//   mcp__fieldguide__ our own verbs, narrowed on the Neovim side
//
// Anything else is refused. A refusal is exit 2 with the reason on stderr,
// the one answer Codex treats as blocking.

import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { checkAccess, isUnder, resolveTarget, type Decision, type Zones } from "../gate.ts";
import { patchPaths } from "./patch.ts";
import { afterWrite, beforeWrite, hookEnv } from "./write-hooks.ts";

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
// The config tree, as of the last time fieldguide looked at it.
// ---------------------------------------------------------------------------

// Beyond this many entries the tree is not walked, and every shell command
// counts as a change: a verify too many, never a write missed.
const FINGERPRINT_LIMIT = 20_000;

/**
 * What the config tree looks like: every entry's path, size and modification
 * time, hashed. A link is taken by where it points and what is there, so a
 * stow-style config changed through its dotfiles tree still counts. `.git` is
 * left out: a commit there is not a change to the config.
 */
export function fingerprint(root: string): string {
  const hash = createHash("sha256");
  let count = 0;
  const walk = (dir: string, rel: string): boolean => {
    let names: string[];
    try {
      names = readdirSync(dir).sort();
    } catch {
      return true;
    }
    for (const name of names) {
      if (name === ".git") continue;
      if (++count > FINGERPRINT_LIMIT) return false;
      const full = path.join(dir, name);
      const at = rel ? `${rel}/${name}` : name;
      let st;
      try {
        st = lstatSync(full);
        if (st.isSymbolicLink()) st = statSync(full);
      } catch {
        hash.update(`${at}\0missing\n`);
        continue;
      }
      if (st.isDirectory() && !lstatSync(full).isSymbolicLink()) {
        hash.update(`${at}/\n`);
        if (!walk(full, at)) return false;
      } else {
        hash.update(`${at}\0${st.size}\0${st.mtimeMs}\n`);
      }
    }
    return true;
  };
  return walk(root, "") ? hash.digest("hex") : `unbounded-${Date.now()}`;
}

/** Where a session's fingerprints live, or undefined if the profile set none. */
function stateDir(): string | undefined {
  const dir = process.env.FIELDGUIDE_HOOK_STATE;
  if (!dir) return undefined;
  mkdirSync(dir, { recursive: true });
  return dir;
}

function readState(name: string): string | undefined {
  const dir = stateDir();
  if (!dir) return undefined;
  try {
    return readFileSync(path.join(dir, name), "utf8");
  } catch {
    return undefined;
  }
}

function writeState(name: string, value: string) {
  const dir = stateDir();
  if (dir) writeFileSync(path.join(dir, name), value);
}

function takeState(name: string): string | undefined {
  const value = readState(name);
  const dir = stateDir();
  if (dir) {
    try {
      unlinkSync(path.join(dir, name));
    } catch {}
  }
  return value;
}

/** A tool_use_id as a file name: it comes from Codex, not from us. */
function idName(id: string | undefined): string {
  return `pre-${(id ?? "none").replace(/[^A-Za-z0-9_.-]/g, "_")}`;
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
    // Changed since fieldguide last looked (the user's own edits, or a first
    // command): committed now, so whatever this command does is undoable on
    // its own rather than folded in with them.
    const now = fingerprint(z.configRoot);
    if (readState("last") !== now) {
      const before = beforeWrite(z.configRoot);
      if (!before.allow) return before.reason;
      writeState("last", now);
    }
    writeState(idName(ev.tool_use_id), now);
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
      const text = afterWrite(target);
      writeState("last", fingerprint(z.configRoot));
      return text || null;
    }
    return null;
  }

  if (ev.tool_name === "Bash") {
    const before = takeState(idName(ev.tool_use_id));
    const now = fingerprint(z.configRoot);
    // Unchanged: an `ls`, a `cat`, a grep. Nothing to checkpoint or verify.
    if (before !== undefined && before === now) return null;
    const text = afterWrite(z.configRoot);
    writeState("last", fingerprint(z.configRoot));
    return text || null;
  }
  return null;
}

async function main(mode: string): Promise<void> {
  if (mode === "check") {
    process.stdout.write("ok\n");
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
  // something throws outside the handled paths above.
  const bail = (err: unknown) => {
    process.stderr.write(`${DENY_PREFIX}${String(err)}\n`);
    process.exit(2);
  };
  process.on("uncaughtException", bail);
  process.on("unhandledRejection", bail);
  await main(process.argv[2] ?? "");
}


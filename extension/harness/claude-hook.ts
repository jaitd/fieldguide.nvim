// Claude Code's side of the path gate: a PreToolUse / PostToolUse command hook.
//
//   node extension/harness/claude-hook.ts pre    < hook event on stdin
//   node extension/harness/claude-hook.ts post   < hook event on stdin
//
// The decision itself is `checkAccess` from gate.ts, unchanged. This file only
// translates Claude's tool names and argument names into the ones the gate
// already knows, and covers the places Claude hides a path that `candidatePaths`
// cannot see: a Glob `pattern` that is absolute or climbs with `..`, and Grep's
// `glob` filter.
//
// Claude treats a hook that *crashes* as a non-blocking error and runs the tool
// anyway. So every failure here is turned into a deny, and anything that gets
// past that exits 2, which Claude does treat as blocking. The gate fails closed
// or it is not a gate.

import { readFileSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { checkAccess, isUnder, resolveTarget, type Zones } from "../gate.ts";
import { afterWrite, beforeWrite, hookEnv as env } from "./write-hooks.ts";

// Claude's tool -> the gate's tool. Anything absent is denied outright: the
// allowlist in --tools is the first line, and this holds if it ever widens.
const TOOL_MAP: Record<string, string> = {
  Read: "read",
  Write: "write",
  Edit: "edit",
  MultiEdit: "edit",
  NotebookEdit: "edit",
  Grep: "grep",
  Glob: "find",
};

export const WRITE_TOOLS = new Set(["Write", "Edit", "MultiEdit", "NotebookEdit"]);
export const MCP_PREFIX = "mcp__fieldguide__";

// Prefixed so the panel can tell a gate refusal from a tool that failed on its
// own: Claude reports both as an errored tool_result.
export const DENY_PREFIX = "blocked by fieldguide: ";

export type HookEvent = {
  hook_event_name?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  tool_use_id?: string;
  tool_response?: unknown;
  cwd?: string;
};

export type Decision = { allow: true } | { allow: false; reason: string };

const GLOB_META = /[*?[{]/;

/** True when any path segment is `..`. A substring test would refuse `a..b.lua`. */
function climbs(p: string): boolean {
  return p.split(/[\\/]/).includes("..");
}

/**
 * The directory a glob pattern can reach, if the pattern names one itself.
 *
 * Claude's Glob accepts `../outside/*` or `/etc/*` as the pattern with no `path`
 * at all, so the path is inside the pattern. The literal prefix before the first
 * metacharacter is the part that is a directory; a `..` *after* a metacharacter
 * (`**\/../x`) cannot be resolved to one place, so it is refused rather than
 * guessed at.
 */
export function patternRoot(pattern: string): { root?: string; refuse?: string } {
  if (!path.isAbsolute(pattern) && !climbs(pattern)) return {};
  const meta = pattern.search(GLOB_META);
  const literal = meta === -1 ? pattern : pattern.slice(0, meta);
  const rest = meta === -1 ? "" : pattern.slice(meta);
  if (climbs(rest)) return { refuse: `glob pattern climbs out of its directory: ${pattern}` };
  // Everything up to the last separator of the literal part is a directory;
  // the tail is a partial name like `init` in `/cfg/init*`.
  const cut = literal.lastIndexOf("/");
  return { root: cut <= 0 ? (path.isAbsolute(pattern) ? "/" : ".") : literal.slice(0, cut) };
}

/** Claude's argument names, spelled the way `candidatePaths` reads them. */
export function gateInput(tool: string, input: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const key of ["file_path", "notebook_path", "path"]) {
    const value = input[key];
    if (typeof value === "string" && value.length > 0) {
      out.path = value;
      break;
    }
  }
  const extra: string[] = [];
  if (tool === "Glob" && typeof input.pattern === "string") {
    const { root } = patternRoot(input.pattern);
    // A relative pattern is relative to the search directory, not to cwd:
    // `path: "lua", pattern: "../../x/*"` climbs from lua/.
    // Joined rather than resolved: the result stays relative, and the gate
    // resolves it against the agent's cwd, not this process's.
    if (root) {
      extra.push(typeof out.path === "string" && !path.isAbsolute(root) ? path.join(out.path, root) : root);
    }
  }
  if (extra.length > 0) out.paths = extra;
  return out;
}

export async function decide(ev: HookEvent, zones: Zones): Promise<Decision> {
  const name = ev.tool_name ?? "";
  const input = ev.tool_input ?? {};

  // Our own verbs carry no paths the gate would understand; they are narrowed on
  // the Neovim side, by the dispatch table.
  if (name.startsWith(MCP_PREFIX)) return { allow: true };

  const tool = TOOL_MAP[name];
  if (!tool) return { allow: false, reason: `fieldguide does not grant ${name || "this tool"}` };

  // Without a config root there is no zone to be inside, and allowing would
  // mean allowing everything.
  if (!zones.configRoot) {
    return { allow: false, reason: "FIELDGUIDE_CONFIG_DIR is unset, so the path gate has no zones" };
  }

  if (name === "Glob" && typeof input.pattern === "string") {
    const { refuse } = patternRoot(input.pattern);
    if (refuse) return { allow: false, reason: refuse };
  }
  // Grep's `glob` only filters inside the search root, and ripgrep will not
  // follow it outwards. Refused anyway when it looks like a path, because
  // "ripgrep happens to behave" is not a property this gate should rest on.
  if (name === "Grep" && typeof input.glob === "string") {
    if (path.isAbsolute(input.glob) || climbs(input.glob)) {
      return { allow: false, reason: `grep glob names a path outside the search root: ${input.glob}` };
    }
  }

  return checkAccess(tool, gateInput(name, input), zones);
}

/** Whether a PostToolUse event reports a write that happened. */
function wrote(ev: HookEvent): boolean {
  if (ev.hook_event_name && ev.hook_event_name !== "PostToolUse") return false;
  const res = ev.tool_response;
  if (typeof res === "string") return !/^\s*(<tool_use_error>|error)/i.test(res);
  if (res && typeof res === "object") {
    const r = res as Record<string, unknown>;
    if (r.is_error === true || r.success === false || (typeof r.error === "string" && r.error !== "")) return false;
  }
  return true;
}

function deny(reason: string): object {
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: DENY_PREFIX + reason,
    },
  };
}

function firstPath(input: Record<string, unknown>): string | undefined {
  for (const key of ["file_path", "notebook_path", "path"]) {
    const value = input[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
}

async function pre(ev: HookEvent): Promise<object | null> {
  const { zones, verbs } = env();
  const cwd = ev.cwd || process.cwd();
  const z = zones(cwd);
  const decision = await decide(ev, z);
  if (!decision.allow) return deny(decision.reason);
  if (WRITE_TOOLS.has(ev.tool_name ?? "") && verbs.has("verify")) {
    const raw = firstPath(ev.tool_input ?? {});
    const target = raw ? await resolveTarget(cwd, raw) : "";
    if (target && isUnder(target, z.configRoot)) {
      const before = beforeWrite(target);
      if (!before.allow) return deny(before.reason);
    }
  }
  return null;
}

async function post(ev: HookEvent): Promise<object | null> {
  const { zones, verbs } = env();
  if (!WRITE_TOOLS.has(ev.tool_name ?? "") || !verbs.has("verify")) return null;
  // A write that did not land has nothing to checkpoint or verify. Claude
  // 2.1 sends those as PostToolUseFailure, which is not registered, but a
  // failure that arrives here anyway is skipped rather than trusted.
  if (!wrote(ev)) return null;
  const cwd = ev.cwd || process.cwd();
  const raw = firstPath(ev.tool_input ?? {});
  if (!raw) return null;
  const target = await resolveTarget(cwd, raw);
  if (!isUnder(target, zones(cwd).configRoot)) return null;

  const text = afterWrite(target);
  if (!text) return null;
  return {
    // Claude ignores keys it does not know, and passes the hook's stdout through
    // to the stream untouched. That is the only way to say which tool call this
    // verify belongs to: the hook_response event itself carries no tool_use_id.
    fieldguide: { tool_use_id: ev.tool_use_id, verify: text },
    hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: text },
  };
}

async function main(mode: string): Promise<void> {
  // Launch-time proof that this interpreter can run this file: TypeScript
  // stripped, every import resolved. Reads no input, so preflight can call it.
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
  let out: object | null;
  if (mode === "pre") {
    try {
      out = await pre(ev);
    } catch (err) {
      out = deny(`the gate failed: ${String(err)}`);
    }
  } else if (mode === "post") {
    out = await post(ev);
  } else {
    process.stderr.write(`claude-hook: unknown mode ${mode}\n`);
    process.exit(2);
  }
  if (out) process.stdout.write(JSON.stringify(out));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  // Exit 2 is the one failure Claude treats as blocking. Reached only if
  // something throws outside the handled paths above.
  const bail = (err: unknown) => {
    process.stderr.write(`${DENY_PREFIX}${String(err)}\n`);
    process.exit(2);
  };
  process.on("uncaughtException", bail);
  process.on("unhandledRejection", bail);
  await main(process.argv[2] ?? "");
}

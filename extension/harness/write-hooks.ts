// The write hooks' side of the editor, shared by every harness whose hooks run
// as a command per tool call (Claude Code, Codex): the zones and verbs from the
// environment `env.agent()` hands the harness, and the MCP server's pre-write
// and post-write entry points, reached over its socket when it has one.

import { spawnSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import type { Decision, Zones } from "../gate.ts";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

/**
 * Whether the module at `url` is the one node was asked to run. By real path
 * on both sides: node resolves symlinks in the module's own URL but leaves
 * argv[1] as it was given, so a plugin reached through a link (a dotfiles
 * tree, macOS's /var) would otherwise never run its hook and fail every check.
 */
export function isMain(url: string): boolean {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(url));
  } catch {
    return false;
  }
}

export function hookEnv(): {
  zones: (cwd: string) => Zones;
  verbs: Set<string>;
} {
  const configRoot = process.env.FIELDGUIDE_CONFIG_DIR || "";
  const docRoots = (process.env.FIELDGUIDE_DOC_ROOTS || "").split(":").filter(Boolean);
  return {
    zones: (cwd) => ({ cwd, configRoot, docRoots }),
    verbs: new Set((process.env.FIELDGUIDE_VERBS || "").split(",").filter(Boolean)),
  };
}

const SERVER = path.join(ROOT, "extension", "mcp.ts");

/**
 * The pi extension's own pre-write step, replayed by the MCP server: its gate
 * again, then the tree as it stands committed before the write lands. Without
 * that commit, anything the user changed by hand since the last agent write is
 * folded into the agent's checkpoint, and undoing the agent undoes the user too.
 *
 * Exit 2 is the server's deny. Anything else that is not 0 — a crash, a missing
 * server, a timeout — is a deny too: a write with no checkpoint behind it cannot
 * be undone the way the panel promises.
 */
export function beforeWrite(target: string, mode = "--before-write"): Decision {
  if (!existsSync(SERVER)) return { allow: false, reason: `cannot checkpoint before writing: ${SERVER} is missing` };
  // Past mcp.ts's own 75s wait on the server, so its refusal arrives first,
  // and short of the harness's 90s on the hook (Claude's and Codex's alike).
  // See the hook timeouts in lua/fieldguide/harness/claude.lua for the chain.
  const args = mode === "--before-write" ? [SERVER, mode, target] : [SERVER, mode];
  const res = spawnSync(process.execPath, args, { encoding: "utf8", timeout: 80_000 });
  if (res.status === 0) return { allow: true };
  const why = (res.stderr || "").trim() || res.error?.message || `exit ${res.status ?? res.signal}`;
  return { allow: false, reason: res.status === 2 ? why : `cannot checkpoint before writing: ${why}` };
}

/**
 * Checkpoint and verify, as one paragraph for the model. Failure is content.
 * Empty means the server had nothing to say about this path.
 */
export function afterWrite(target: string, mode = "--after-write"): string {
  if (!existsSync(SERVER)) return `[fieldguide] verify unavailable: ${SERVER} is missing`;
  // Past mcp.ts's 135s, short of the harness's 150s.
  const args = mode === "--after-write" ? [SERVER, mode, target] : [SERVER, mode];
  const res = spawnSync(process.execPath, args, { encoding: "utf8", timeout: 140_000 });
  if (res.status === 0) return (res.stdout || "").trim();
  return `[fieldguide] verify unavailable: ${(res.stderr || "").trim() || res.error?.message || `exit ${res.status}`}`;
}

/**
 * Before a command that may write the config tree without saying so (a
 * shell): the server checkpoints the tree if it changed since it last did, so
 * the user's own edits are their own point in history. It keeps that state
 * itself, out of the agent's reach; see `treeHook` in extension/mcp.ts.
 */
export function treeBefore(): Decision {
  return beforeWrite("", "--tree-before");
}

/** After one: checkpoint and verify if the tree changed, or "" if not. */
export function treeAfter(): string {
  return afterWrite("", "--tree-after");
}

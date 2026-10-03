// The write hooks' side of the editor, shared by every harness whose hooks run
// as a command per tool call (Claude Code, Codex): the zones and verbs from the
// environment `env.agent()` hands the harness, and the MCP server's pre-write
// and post-write entry points, reached over its socket when it has one.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import type { Decision, Zones } from "../gate.ts";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

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
export function beforeWrite(target: string): Decision {
  if (!existsSync(SERVER)) return { allow: false, reason: `cannot checkpoint before writing: ${SERVER} is missing` };
  // Past mcp.ts's own 75s wait on the server, so its refusal arrives first,
  // and short of the harness's 90s on the hook (Claude's and Codex's alike).
  // See the hook timeouts in lua/fieldguide/harness/claude.lua for the chain.
  const res = spawnSync(process.execPath, [SERVER, "--before-write", target], { encoding: "utf8", timeout: 80_000 });
  if (res.status === 0) return { allow: true };
  const why = (res.stderr || "").trim() || res.error?.message || `exit ${res.status ?? res.signal}`;
  return { allow: false, reason: res.status === 2 ? why : `cannot checkpoint before writing: ${why}` };
}

/**
 * Checkpoint and verify, as one paragraph for the model. Failure is content.
 * Empty means the server had nothing to say about this path.
 */
export function afterWrite(target: string): string {
  if (!existsSync(SERVER)) return `[fieldguide] verify unavailable: ${SERVER} is missing`;
  // Past mcp.ts's 135s, short of the harness's 150s.
  const res = spawnSync(process.execPath, [SERVER, "--after-write", target], { encoding: "utf8", timeout: 140_000 });
  if (res.status === 0) return (res.stdout || "").trim();
  return `[fieldguide] verify unavailable: ${(res.stderr || "").trim() || res.error?.message || `exit ${res.status}`}`;
}


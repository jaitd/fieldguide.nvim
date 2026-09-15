// The three-zone path gate, as a pure function so it can be tested
// without a pi session. This is the security-relevant code in the extension.
//
// | Zone            | Access    | Contents                                    |
// |-----------------|-----------|---------------------------------------------|
// | Config tree     | read/write| resolve(stdpath("config"))                  |
// | Doc trees       | read-only | ~/.local/share/nvim/lazy/, $VIMRUNTIME      |
// | Everything else | blocked   | the rest of $HOME, and any repo the config  |
// |                 |           | tree happens to sit inside                  |

import { realpath } from "node:fs/promises";
import * as path from "node:path";

export const FILE_TOOLS = new Set(["read", "write", "edit", "grep", "find", "ls"]);
export const WRITE_TOOLS = new Set(["write", "edit"]);

export type Zones = {
  cwd: string;
  configRoot: string;
  docRoots: string[];
};

export type Decision = { allow: true } | { allow: false; reason: string };

/**
 * Resolve symlinks on *both* sides before comparing. Dotfile managers routinely
 * make ~/.config/nvim a symlink into a repo elsewhere, so the real root is not
 * the path Neovim reports, and a naive prefix test on the unresolved path fails
 * open.
 *
 * A path that does not exist yet (writing a new file, possibly several
 * directories deep) is resolved by walking up to its nearest existing ancestor
 * and re-appending the tail. Resolving nothing would let a symlinked ancestor
 * slip through — and when cwd itself is the symlink, which is the common
 * dotfiles case, *every* new file would land outside the resolved root and be
 * wrongly blocked.
 */
export async function resolveTarget(cwd: string, raw: string): Promise<string> {
  // Some models include the @ prefix in path arguments; built-in tools strip
  // it, so the gate has to see the same path the tool will act on.
  const cleaned = raw.startsWith("@") ? raw.slice(1) : raw;
  const absolute = path.resolve(cwd, cleaned);

  const tail: string[] = [];
  let current = absolute;
  for (;;) {
    try {
      const resolved = await realpath(current);
      return tail.length === 0 ? resolved : path.join(resolved, ...tail);
    } catch {
      const parent = path.dirname(current);
      if (parent === current) return absolute; // hit the filesystem root
      tail.unshift(path.basename(current));
      current = parent;
    }
  }
}

/** Prefix test that will not let /foo/barbaz match the root /foo/bar. */
export function isUnder(target: string, root: string): boolean {
  if (!root) return false;
  return target === root || target.startsWith(root + path.sep);
}

/** Every path-ish argument a built-in tool might carry. */
export function candidatePaths(input: Record<string, unknown>): string[] {
  const out: string[] = [];
  for (const key of ["path", "dir"]) {
    const value = input[key];
    if (typeof value === "string" && value.length > 0) out.push(value);
  }
  if (Array.isArray(input.paths)) {
    for (const value of input.paths) if (typeof value === "string") out.push(value);
  }
  return out;
}

/**
 * The decision. `cwd` is where the agent *starts*, not a boundary it cannot
 * cross with ../../ — which is exactly why this check exists.
 */
export async function checkAccess(
  toolName: string,
  input: Record<string, unknown>,
  zones: Zones,
): Promise<Decision> {
  // Defence in depth: `bash` is absent from the --tools allowlist already, and
  // this holds if a refactor ever widens that list.
  if (toolName === "bash") {
    return { allow: false, reason: "fieldguide does not grant a shell" };
  }
  if (!FILE_TOOLS.has(toolName)) return { allow: true };

  const raws = candidatePaths(input);
  // grep/find/ls with no path argument default to cwd, which is the config root.
  if (raws.length === 0) return { allow: true };

  for (const raw of raws) {
    const target = await resolveTarget(zones.cwd, raw);

    if (isUnder(target, zones.configRoot)) continue;

    const inDocs = zones.docRoots.some((root) => isUnder(target, root));
    if (inDocs && !WRITE_TOOLS.has(toolName)) continue;

    return {
      allow: false,
      reason:
        (inDocs ? `the doc zone is read-only: ${target}` : `outside fieldguide's zones: ${target}`) +
        `\nReadable+writable: ${zones.configRoot}` +
        `\nReadable only: ${zones.docRoots.join(", ") || "(none)"}`,
    };
  }

  return { allow: true };
}

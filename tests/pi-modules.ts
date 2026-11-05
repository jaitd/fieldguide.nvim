// Where pi's private modules (typebox, jiti) can be required from, for the
// tests that load the extension against the real thing. Not a test itself.

import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import path from "node:path";

/**
 * Directories to resolve pi's modules from, first one first, or none when pi
 * is not installed. pnpm 10's launcher exports a NODE_PATH naming them; pnpm
 * 11 and later export none, but record pi's entry script in a trailing
 * `# cmd-shim-target=` comment. pi's dependencies resolve from beside its real
 * path: the target is a symlink into pnpm's store, where they live.
 */
export function piModulePaths(): string[] {
  // `command -v` exits non-zero when pi is absent, and execFileSync turns a
  // non-zero exit into a throw. Without this the tests' "skips itself"
  // promise is only kept on machines that do have pi.
  let launcher = "";
  try {
    launcher = execFileSync("sh", ["-c", "command -v pi"], { encoding: "utf8" }).trim();
  } catch {
    return [];
  }
  if (!launcher) return [];
  const source = readFileSync(launcher, "utf8");
  const nodePath = source.match(/NODE_PATH="([^"]+)"/);
  if (nodePath) return nodePath[1].split(":").filter(Boolean);
  const target = source.match(/^# cmd-shim-target=(.+)$/m);
  if (!target) return [];
  try {
    return [path.dirname(realpathSync(target[1].trim()))];
  } catch {
    return [];
  }
}

// What a config tree looks like right now, as one string that changes when
// any file in it does. The MCP server keeps one of these from the last
// checkpoint and compares, to find writes nobody announced: a harness's shell.

import { createHash } from "node:crypto";
import { lstatSync, readdirSync, statSync } from "node:fs";
import * as path from "node:path";

// Beyond this many entries the tree is not walked, and every call counts as a
// change: a verify too many, never a write missed.
const LIMIT = 20_000;

/**
 * Every entry's path, size, modification time, change time and inode, hashed.
 * The change time is the one an unprivileged write cannot set back: `touch -r`,
 * `cp -p` and `rsync -t` restore an mtime, and an equal-length rewrite keeps
 * the size, but the ctime still moves. The inode catches a file replaced by
 * rename. A link is taken by where it points and what is there, so a
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
      if (++count > LIMIT) return false;
      const full = path.join(dir, name);
      const at = rel ? `${rel}/${name}` : name;
      let st;
      let link = false;
      try {
        st = lstatSync(full);
        link = st.isSymbolicLink();
        if (link) st = statSync(full);
      } catch {
        hash.update(`${at}\0missing\n`);
        continue;
      }
      if (st.isDirectory() && !link) {
        hash.update(`${at}/\n`);
        if (!walk(full, at)) return false;
      } else {
        hash.update(`${at}\0${st.size}\0${st.mtimeMs}\0${st.ctimeMs}\0${st.ino}\n`);
      }
    }
    return true;
  };
  return walk(root, "") ? hash.digest("hex") : `unbounded-${Date.now()}`;
}

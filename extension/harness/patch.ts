// The `*** Begin Patch` format that opencode's `patch` tool and Codex's
// `apply_patch` both write, read for the one thing a gate needs: which files
// it touches. Paths stay as written; the gate resolves them.

/**
 * Every file a patch touches, including where a move sends it. `null` when the
 * text is not a patch this parser understands — refused, never guessed at.
 */
export function patchPaths(text: unknown): string[] | null {
  if (typeof text !== "string" || !text.includes("*** Begin Patch")) return null;
  const out: string[] = [];
  for (const line of text.split("\n")) {
    const m = /^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/.exec(line.replace(/\r$/, ""));
    if (m) out.push(m[1].trim());
  }
  return out.length > 0 ? out : null;
}

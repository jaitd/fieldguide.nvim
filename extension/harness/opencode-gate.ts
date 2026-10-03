// The three-zone gate, in opencode v2's vocabulary.
//
// `checkAccess` in ../gate.ts is the decision and stays the only one. This file
// translates opencode's tools and arguments into pi's, and handles what pi's
// tools never needed: paths carried inside a patch body and inside a glob
// pattern. Kept apart from the plugin itself because opencode calls every
// function a plugin module exports as a plugin, and these are not.
//
// Everything here fails closed. A tool not named below, an argument of the
// wrong type, a patch that does not parse: all are refused, because the
// alternative is a gate that opens whenever opencode renames something.

import * as path from "node:path";
import { checkAccess, type Decision, type Zones } from "../gate.ts";

/** opencode v2's file tools, as the pi tool the gate already has rules for. */
const AS_PI: Record<string, string> = {
  read: "read",
  write: "write",
  edit: "edit",
  patch: "edit",
  grep: "grep",
  glob: "find",
};

/**
 * Tools let through without a path of their own. `execute` is code mode: a
 * script that can call tools and nothing else (no filesystem, process, network
 * or imports, by opencode's own design), and every tool it calls comes back
 * through this gate on its own. The todo list touches nothing.
 */
const PASS = new Set(["execute", "todowrite"]);

/** fieldguide's verbs over MCP, namespaced by opencode as `<server>_<tool>`. */
const OURS = /^fieldguide_nvim_[a-z_]+$/;

export type Verdict = Decision & { writes?: string[] };

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

/**
 * The directory a glob pattern starts from: the segments before its first
 * wildcard. An absolute pattern names a path in its own right. A relative one
 * names a path under the search path, and that path is checked too, because
 * a symlink in the config tree (`escape/*.env`) leads out without a `..`. One
 * that climbs is refused outright rather than resolved, since which
 * directories `**` will match cannot be known here. Past the first wildcard,
 * a link can only be caught by the OS sandbox around the harness.
 */
export function globRoot(pattern: string): { root?: string; climbs: boolean } {
  const segments = pattern.split(/[\\/]/);
  if (segments.includes("..")) return { climbs: true };
  // The last segment is the file part, not a directory, even with no wildcard.
  const dirs = segments.slice(0, -1);
  const fixed: string[] = [];
  for (const segment of dirs) {
    if (/[*?[\]{}]/.test(segment)) break;
    fixed.push(segment);
  }
  if (path.isAbsolute(pattern)) return { root: fixed.join("/") || "/", climbs: false };
  const root = fixed.filter((s) => s !== "" && s !== ".").join("/");
  return root ? { root, climbs: false } : { climbs: false };
}

const deny = (reason: string): Verdict => ({ allow: false, reason });

/** One path through the gate, as the pi tool `piTool` would be. */
async function one(piTool: string, target: unknown, zones: Zones): Promise<Decision> {
  if (target === undefined) return checkAccess(piTool, {}, zones);
  if (typeof target !== "string" || target === "") return deny(`${piTool}: unreadable path argument`);
  return checkAccess(piTool, { path: target }, zones);
}

export async function decide(tool: string, args: Record<string, unknown>, zones: Zones): Promise<Verdict> {
  if (OURS.test(tool) || PASS.has(tool)) return { allow: true };
  const piTool = AS_PI[tool];
  if (!piTool) return deny(`fieldguide does not grant ${tool}`);
  args = args ?? {};

  if (tool === "patch") {
    const paths = patchPaths(args.patchText);
    if (!paths) return deny(`${tool}: could not read which files the patch touches`);
    for (const p of paths) {
      const d = await one(piTool, p, zones);
      if (!d.allow) return d;
    }
    return { allow: true, writes: paths };
  }

  if (piTool === "read" || piTool === "write" || piTool === "edit") {
    // Required, unlike pi's optional `path`: a file tool with no file is a
    // malformed call, not one that defaults to the config root.
    if (typeof args.path !== "string" || args.path === "") return deny(`${tool}: missing path`);
    const d = await one(piTool, args.path, zones);
    if (!d.allow) return d;
    return piTool === "read" ? { allow: true } : { allow: true, writes: [args.path] };
  }

  // grep, glob: an optional directory, defaulting to cwd.
  const d = await one(piTool, args.path, zones);
  if (!d.allow) return d;

  const patterns: unknown[] = tool === "glob" ? [args.pattern] : tool === "grep" ? [args.include] : [];
  for (const pattern of patterns) {
    if (pattern === undefined) continue;
    if (typeof pattern !== "string") return deny(`${tool}: unreadable pattern`);
    const { root, climbs } = globRoot(pattern);
    if (climbs) return deny(`${tool}: a pattern may not climb out with ..: ${pattern}`);
    if (root) {
      // A relative prefix is taken against the search path, as the tool will.
      const base = typeof args.path === "string" && args.path !== "" ? args.path : undefined;
      const target = path.isAbsolute(root) || !base ? root : path.join(base, root);
      const r = await one(piTool, target, zones);
      if (!r.allow) return r;
    }
  }
  return { allow: true };
}

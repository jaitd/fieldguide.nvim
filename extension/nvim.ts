// fieldguide's pi extension.
//
// Three jobs, in order of how much they matter:
//
//   1. The three-zone path gate, in the `tool_call` hook. This is what turns
//      "scoped to your config" from a convention into a check.
//   2. Auto-`verify` on every write, in the `tool_result` hook, so the loop
//      closes at the write rather than a turn later.
//   3. The verbs, registered as tools. Thin wrappers over `bin/fieldguide`.
//
// The extension is an adapter, not the architecture. Everything with value here
// lives behind the CLI seam and survives the harness being swapped out.

import { spawn } from "node:child_process";
import * as path from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { candidatePaths, checkAccess, isUnder, resolveTarget, WRITE_TOOLS, type Zones } from "./gate.ts";
import { Index, UnreadableIndex } from "./plugins.ts";

// ---------------------------------------------------------------------------
// Environment, handed over by the sidebar.
// ---------------------------------------------------------------------------

const NVIM = process.env.FIELDGUIDE_NVIM || "nvim";
const CLIENT = process.env.FIELDGUIDE_BIN || "";
const ADDR = process.env.FIELDGUIDE_ADDR || "";
const CONFIG_ROOT = process.env.FIELDGUIDE_CONFIG_DIR || "";
const DOC_ROOTS = (process.env.FIELDGUIDE_DOC_ROOTS || "").split(":").filter(Boolean);
const VERBS = new Set((process.env.FIELDGUIDE_VERBS || "").split(",").filter(Boolean));
const RELOAD_LEVEL = process.env.FIELDGUIDE_RELOAD_LEVEL || "auto";
const CALL_TIMEOUT_MS = Number(process.env.FIELDGUIDE_CALL_TIMEOUT_MS) || 60_000;
// The plugin index, if this machine has one. Absent is the normal case:
// the two tools below are simply not registered, exactly as a disabled verb is.
const PLUGIN_INDEX = process.env.FIELDGUIDE_PLUGIN_INDEX || "";

// ---------------------------------------------------------------------------
// Transport: one subprocess per verb call.
// ---------------------------------------------------------------------------

type VerbResult = { ok: boolean; result?: unknown; error?: string };

/**
 * ~50ms of process startup, irrelevant next to an LLM round trip, and worth it
 * to keep one dispatch path shared by every future consumer.
 */
function callVerb(verb: string, args: Record<string, unknown>, signal?: AbortSignal): Promise<VerbResult> {
  return new Promise((resolve) => {
    if (!CLIENT) {
      resolve({ ok: false, error: "FIELDGUIDE_BIN is unset — launch the agent via :Fieldguide" });
      return;
    }
    const child = spawn(NVIM, ["-l", CLIENT, "--json", JSON.stringify({ verb, args })], {
      env: { ...process.env, FIELDGUIDE_ADDR: ADDR },
      stdio: ["ignore", "pipe", "pipe"],
      signal,
    });

    // A backstop, not a policy. `verify` caps its own sandboxed boot at 15s and
    // `reload` can sit on a confirm() prompt, so this is set well clear of both
    // — it exists so that an editor wedged on the far side of the socket costs
    // one tool call rather than the whole session.
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill("SIGKILL");
      resolve({
        ok: false,
        error:
          `${verb} did not return within ${CALL_TIMEOUT_MS / 1000}s. The editor may be waiting on a ` +
          `prompt — check it, then retry.`,
      });
    }, CALL_TIMEOUT_MS);

    const done = (result: VerbResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };

    let stdout = "";
    let stderr = "";
    // Decoded by the stream, not per chunk: a multi-byte character that
    // straddles a 64 KiB pipe boundary would otherwise arrive as two U+FFFDs.
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (d: string) => (stdout += d));
    child.stderr.on("data", (d: string) => (stderr += d));
    child.on("error", (err) => done({ ok: false, error: String(err) }));
    child.on("close", () => {
      const trimmed = stdout.trim();
      if (!trimmed) {
        // Agents recover well from clear errors and badly from empty output.
        done({ ok: false, error: stderr.trim() || "no output from the fieldguide client" });
        return;
      }
      try {
        done(JSON.parse(trimmed) as VerbResult);
      } catch {
        done({ ok: false, error: `unparseable client output: ${trimmed.slice(0, 400)}` });
      }
    });
  });
}

function asToolResult(verb: string, res: VerbResult) {
  if (!res.ok) {
    // Throwing is how pi marks a tool result as failed.
    throw new Error(`${verb}: ${res.error ?? "unknown error"}`);
  }
  return {
    content: [{ type: "text" as const, text: JSON.stringify(res.result, null, 1) }],
    details: { verb, result: res.result },
  };
}

// ---------------------------------------------------------------------------
// Extension entry point.
// ---------------------------------------------------------------------------

export default function (pi: ExtensionAPI) {
  // -- 1. The gate ---------------------------------------------------

  pi.on("tool_call", async (event, ctx) => {
    const zones: Zones = { cwd: ctx.cwd, configRoot: CONFIG_ROOT, docRoots: DOC_ROOTS };
    const decision = await checkAccess(event.toolName, (event.input ?? {}) as Record<string, unknown>, zones);
    if (!decision.allow) {
      return { block: true, reason: decision.reason };
    }
    // A write about to land on the config gets the tree as it stands committed
    // first. Without this, anything the user changed by hand since the last
    // agent write would be folded into the agent's own checkpoint, and undoing
    // the agent would undo the user too. Unchanged trees cost one cheap no-op.
    if (WRITE_TOOLS.has(event.toolName) && VERBS.has("verify")) {
      const raws = candidatePaths((event.input ?? {}) as Record<string, unknown>);
      if (raws.length > 0) {
        const target = await resolveTarget(ctx.cwd, raws[0]);
        if (isUnder(target, CONFIG_ROOT)) {
          await callVerb("checkpoint", { label: "before agent write" }, ctx.signal);
        }
      }
    }
  });

  // -- 2. Auto-verify on write --------------------------------------

  pi.on("tool_result", async (event, ctx) => {
    if (!WRITE_TOOLS.has(event.toolName) || event.isError) return;
    if (!VERBS.has("verify")) return;

    const input = (event.input ?? {}) as Record<string, unknown>;
    const raws = candidatePaths(input);
    if (raws.length === 0) return;
    const target = await resolveTarget(ctx.cwd, raws[0]);
    if (!isUnder(target, CONFIG_ROOT)) return;

    // Every agent write auto-commits to the shadow repo. Undo is a git
    // checkout away and the user's real repo never sees it.
    const checkpoint = await callVerb("checkpoint", { label: `${event.toolName} ${path.basename(target)}` }, ctx.signal);

    const verify = await callVerb("verify", {}, ctx.signal);
    const line = summarize(verify, checkpoint);

    return {
      content: [...event.content, { type: "text" as const, text: line }],
    };
  });

  // -- 3. The verbs as tools ------------------------------------------------

  if (VERBS.has("state")) {
    pi.registerTool({
      name: "nvim_state",
      label: "nvim state",
      description:
        "Live state of the running Neovim: buffers, diagnostics, installed plugins with their " +
        "resolved revisions and load reasons, keymaps, windows, LSP clients, recent :messages. " +
        "Paths come back relative to the config directory, so they can be passed straight to read/edit. " +
        "Sections are opt-in: ask for the narrow set you need.",
      promptSnippet: "Inspect the live Neovim session (buffers, plugins, keymaps, diagnostics, LSP)",
      promptGuidelines: [
        "Call nvim_state before answering anything about what is installed or configured — " +
          "training data describes a different setup than the one in front of you.",
      ],
      parameters: Type.Object({
        what: Type.Optional(
          Type.String({
            description:
              "Comma-separated sections: nvim, buffers, diagnostics, plugins, keymaps, windows, lsp, messages. " +
              "Default: nvim,buffers,diagnostics,plugins,keymaps",
          }),
        ),
        full: Type.Optional(
          Type.Boolean({ description: "Expand diagnostics from per-file counts to full items" }),
        ),
      }),
      async execute(_id, params, signal) {
        return asToolResult("state", await callVerb("state", params, signal));
      },
    });
  }

  if (VERBS.has("docs")) {
    pi.registerTool({
      name: "nvim_docs",
      label: "nvim docs",
      description:
        "Resolve a helptag or plugin name against the documentation of the plugins THIS Neovim " +
        "actually has installed, at the revisions actually on disk. Returns absolute doc paths and " +
        "line anchors; read or grep them for the content. Plugins that ship no doc/ resolve to their " +
        "README. A query that matches nothing means the plugin is not installed here.",
      promptSnippet: "Resolve a helptag or plugin name to docs from the installed plugin set",
      promptGuidelines: [
        "Use nvim_docs before answering plugin questions, then read the path it returns — " +
          "the installed revision is the authority, not recollection of the plugin's README.",
        "If nvim_docs finds nothing for a plugin, say it is not installed rather than writing config for it.",
      ],
      parameters: Type.Object({
        query: Type.String({ description: "A helptag (e.g. 'fugitive-maps') or a plugin name (e.g. 'telescope')" }),
        fetch: Type.Optional(
          Type.Boolean({ description: "Also return a raw text slice at the first exact tag anchor" }),
        ),
        lines: Type.Optional(Type.Number({ description: "Lines to return when fetch is true (default 60)" })),
      }),
      async execute(_id, params, signal) {
        return asToolResult("docs", await callVerb("docs", params, signal));
      },
    });
  }

  if (VERBS.has("explain_keymap")) {
    pi.registerTool({
      name: "nvim_explain_keymap",
      label: "nvim explain_keymap",
      description:
        "Explain a key mapping end to end: the live mapping, where it was defined (file and line, " +
        "or the owning plugin), any lazy.nvim spec that owns the lhs as a load trigger, and the " +
        "owning plugin's documentation. Use this rather than grepping for the lhs.",
      promptSnippet: "Trace a keymap to its definition site, owning plugin, and docs",
      promptGuidelines: [
        "Use nvim_explain_keymap for any 'what is this key' or 'why didn't my keymap take' question.",
      ],
      parameters: Type.Object({
        lhs: Type.String({ description: "The mapping as typed, e.g. '<leader>gs' or 'gcc'" }),
        mode: Type.Optional(Type.String({ description: "Restrict to one mode: n, v, x, s, o, i, c, t" })),
      }),
      async execute(_id, params, signal) {
        return asToolResult("explain_keymap", await callVerb("explain_keymap", params, signal));
      },
    });
  }

  if (VERBS.has("verify")) {
    pi.registerTool({
      name: "nvim_verify",
      label: "nvim verify",
      description:
        "Boot the config as it is on disk, headless, in a sandbox with no network and read-only " +
        "mounts. Returns startup errors with tracebacks, :messages, per-plugin load status, duration, " +
        "and a diff against the previous run. ~70ms. It runs automatically after every write, so call " +
        "it explicitly only for the diff, or to re-check after editing outside the tools. " +
        "It boots and quits: it proves the config loads, not that it behaves.",
      promptSnippet: "Sandboxed headless boot of the config on disk (~70ms)",
      parameters: Type.Object({
        timeout_ms: Type.Optional(Type.Number({ description: "Kill the boot after this long (default 15000)" })),
      }),
      async execute(_id, params, signal) {
        return asToolResult("verify", await callVerb("verify", params, signal));
      },
    });
  }

  if (VERBS.has("reload")) {
    pi.registerTool({
      name: "nvim_reload",
      label: "nvim reload",
      description:
        "Purge and re-require the config's Lua modules in the RUNNING editor, so changes take effect " +
        "without a restart. This executes the config's code unsandboxed. It does not cover plugin " +
        "specs — a changed lazy.nvim spec needs a real restart, and nvim_verify is the honest check " +
        "for those. Side effects do not unregister: a renamed keymap leaks its old binding.",
      promptSnippet: "Re-require changed config modules in the running editor",
      promptGuidelines: [
        "Prefer nvim_verify over nvim_reload to check whether an edit is correct; " +
          "call nvim_reload only when the user wants the change live in the editor they are using now.",
        "Tell the user a restart is needed when the edit touched a plugin spec — nvim_reload does not cover those.",
      ],
      parameters: Type.Object({}),
      async execute(_id, _params, signal) {
        return asToolResult("reload", await callVerb("reload", {}, signal));
      },
    });
  }

  // -- 4. The plugin index --------------------------------------------
  //
  // Everything above answers from the editor in front of us. These two answer
  // about plugins that are *not* installed, which is the one question the live
  // session cannot be asked. They are deliberately silent about installed ones:
  // nvim_docs reads the revision actually on disk, which no index can improve on.

  // Opened once here rather than lazily, so an index this build cannot read
  // costs a startup notice and no tools, instead of an error on whichever tool
  // call happens to touch it first.
  let index: Index | null = null;
  let indexProblem: string | null = null;
  if (PLUGIN_INDEX) {
    try {
      index = new Index(PLUGIN_INDEX);
    } catch (err) {
      indexProblem = err instanceof UnreadableIndex ? err.message : String(err);
    }
  }

  if (index) {
    const open = () => index!;

    pi.registerTool({
      name: "nvim_plugins",
      label: "nvim plugins",
      description:
        "Search the plugin index: a snapshot of the Neovim plugin ecosystem with each project's " +
        "stars, category, last commit date, and whether its maintainer has withdrawn it. " +
        "Use `query` to find plugins for a need. Use `check` with the names nvim_state reports " +
        "(the `repo` field where present, else `name`) to find out which of the user's installed " +
        "plugins were archived or replaced. " +
        "Results are ranked by relevance against popularity; archived projects are held back " +
        "unless nothing else matches, or include_archived is set.",
      promptSnippet: "Find plugins by need, or check installed ones against the index",
      promptGuidelines: [
        "Use nvim_plugins before recommending any plugin the user does not already have — " +
          "a recommendation is worth nothing if the project was archived or replaced after training.",
        "status is what the maintainer declared, not a health score. 'active' means only that " +
          "they have not archived it or named a successor.",
        "last_push is a date, not a verdict. Plenty of the best-regarded plugins are finished " +
          "and have not needed a commit in years; do not warn about age on its own.",
        "For a plugin the user already has installed, prefer nvim_docs: it reads the revision on disk.",
      ],
      parameters: Type.Object({
        query: Type.Optional(Type.String({ description: "What the plugin should do, in plain words" })),
        check: Type.Optional(
          Type.Array(Type.String(), {
            description: "Installed plugin names to check against the index: 'owner/repo', or the bare repo name",
          }),
        ),
        category: Type.Optional(Type.String({ description: "Restrict to one category; omit query to list them" })),
        limit: Type.Optional(Type.Number({ description: "Max results (default 10, cap 50)" })),
        include_archived: Type.Optional(
          Type.Boolean({ description: "Include archived projects (default false)" }),
        ),
      }),
      async execute(_id, params, _signal) {
        const ix = open();
        const p = params as {
          query?: string;
          check?: string[];
          category?: string;
          limit?: number;
          include_archived?: boolean;
        };
        let result: unknown;
        if (p.check?.length) {
          const stale = ix.audit(p.check);
          result = { built: ix.built().built_at, checked: p.check.length, needs_attention: stale };
        } else if (p.query) {
          const opts = { limit: p.limit, category: p.category, includeArchived: p.include_archived };
          result = { built: ix.built().built_at, results: ix.search(p.query, opts) };
        } else {
          result = { built: ix.built().built_at, categories: ix.categories() };
        }
        return {
          content: [{ type: "text" as const, text: JSON.stringify(result, null, 1) }],
          details: { verb: "plugins", result },
        };
      },
    });

    pi.registerTool({
      name: "nvim_plugin",
      label: "nvim plugin",
      description:
        "One plugin from the index in full: description, licence, stars, how long since the last " +
        "commit, what it depends on, and what depends on it. The dependency edges come from lazy " +
        "specs and naming conventions, so they carry how they were concluded — treat a 'naming' " +
        "edge as weaker than a 'lazy-spec' one.",
      promptSnippet: "Look up one plugin: liveness, licence, and its dependency edges",
      parameters: Type.Object({
        name: Type.String({ description: "'owner/repo', or just the repo name" }),
      }),
      async execute(_id, params, _signal) {
        const found = open().show((params as { name: string }).name);
        if (!found) {
          throw new Error(
            `plugins: ${(params as { name: string }).name} is not in the index — ` +
              `it may be too new, unlisted, or not a Neovim plugin`,
          );
        }
        return {
          content: [{ type: "text" as const, text: JSON.stringify(found, null, 1) }],
          details: { verb: "plugin", result: found },
        };
      },
    });
  }

  pi.on("session_start", async (_event, ctx) => {
    if (!CONFIG_ROOT) {
      ctx.ui.notify(
        "fieldguide: FIELDGUIDE_CONFIG_DIR is unset — the path gate is not active. " +
          "Launch this session with :Fieldguide from inside Neovim.",
        "error",
      );
      return;
    }
    // A stale or unreadable index is worth saying once, at the top. Silence
    // would read as the plugin index simply not existing.
    if (indexProblem) {
      ctx.ui.notify(`fieldguide: ${indexProblem}`, "warning");
    }
    const built = index?.built().built_at;
    ctx.ui.setStatus(
      "fieldguide",
      `nvim: ${path.basename(CONFIG_ROOT)} · ${DOC_ROOTS.length} doc root(s) · reload=${RELOAD_LEVEL}` +
        (built ? ` · index ${built.slice(0, 10)}` : ""),
    );
  });
}

/**
 * One line appended to the write tool's own result. Deliberately reads as
 * information, not alarm: during a multi-file edit the agent will see
 * mid-sequence failures that are expected.
 */
function summarize(verify: VerbResult, checkpoint: VerbResult): string {
  const parts: string[] = [];

  if (!verify.ok) {
    parts.push(`[fieldguide] verify unavailable: ${verify.error}`);
  } else {
    const r = verify.result as {
      ok?: boolean;
      duration_ms?: number;
      errors?: string[];
      timed_out?: boolean;
      note?: string;
      escape_alarms?: { kind: string; line: string }[];
    };
    if (r.timed_out) {
      parts.push(`[fieldguide] boot TIMED OUT after ${Math.round(r.duration_ms ?? 0)}ms`);
    } else if (r.ok) {
      parts.push(`[fieldguide] boot OK, ${Math.round(r.duration_ms ?? 0)}ms`);
    } else {
      parts.push(
        `[fieldguide] boot FAILED: ${r.errors?.[0] ?? "unknown error"}` +
          `\n  (expected mid-sequence if this edit is one of several — finish the set, then check nvim_verify)`,
      );
    }
    if (r.note) parts.push(`  ${r.note}`);
    if (r.escape_alarms?.length) {
      parts.push(
        `  escape alarm: ${r.escape_alarms.map((a) => `${a.kind}: ${a.line}`).join("; ")}` +
          `\n  (an alarm, not a verdict — nothing was reverted)`,
      );
    }
  }

  if (checkpoint.ok) {
    const c = checkpoint.result as { sha?: string; unchanged?: boolean };
    if (c?.sha) parts.push(`  checkpoint ${c.sha} (undo with :FieldguideUndo)`);
  }

  return parts.join("\n");
}

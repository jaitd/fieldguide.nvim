// fieldguide's MCP server: the same verbs, for harnesses that are not pi.
//
//   node extension/mcp.ts                        stdio MCP server
//   node extension/mcp.ts --listen <socket>      the same server, on a unix socket
//   node extension/mcp.ts --relay [socket]       stdio <-> socket, for inside the sandbox
//   node extension/mcp.ts --before-write <path>  gate + checkpoint, for a pre-write hook
//   node extension/mcp.ts --after-write <path>   checkpoint + verify, for a post-write hook
//   node extension/mcp.ts --tree-before          checkpoint if the config tree changed, before a shell command
//   node extension/mcp.ts --tree-after           checkpoint + verify if it changed, after one
//
// When the agent runs sandboxed, the server runs *outside*, with --listen, and
// only its socket is bound in. The harness launches --relay as its MCP server,
// and the two hooks, seeing FIELDGUIDE_MCP_SOCKET, ask the server rather than
// the editor. Neovim's own socket never enters the sandbox: it speaks the whole
// Neovim API, and an agent with a shell could run any Lua there, outside the
// sandbox, with it. This socket speaks the verbs and nothing else.
//
// This file is a protocol adapter and nothing else. It hosts the pi extension
// (nvim.ts) behind a stand-in for pi's ExtensionAPI and speaks MCP on its
// behalf, so the tool names, descriptions, schemas, the verb transport and the
// write hooks all have exactly one definition. A second copy would drift, and
// the first thing to drift would be a description the model reads.
//
// Environment is the one `env.agent()` hands pi: FIELDGUIDE_ADDR, _BIN, _NVIM,
// _CONFIG_DIR, _DOC_ROOTS, _VERBS, _RELOAD_LEVEL, _PLUGIN_INDEX. The harness
// passes it through its MCP server config.
//
// Zero dependencies, like the rest of the extension: newline-delimited
// JSON-RPC over stdio is small enough to speak by hand.

import { chmodSync, fstatSync, lstatSync, mkdirSync, rmdirSync, statSync, unlinkSync } from "node:fs";
import { registerHooks } from "node:module";
import { createConnection, createServer, type Socket } from "node:net";
import * as path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { fingerprint } from "./harness/fingerprint.ts";

// nvim.ts builds its schemas with typebox, which resolves only inside pi's own
// install. A harness user may have no pi at all, so `typebox` is aliased to a
// shim that emits the plain JSON Schema typebox would have. Only the builders
// nvim.ts uses exist: a new one fails at load, loudly, rather than producing a
// schema that is quietly wrong. tests/mcp.test.ts holds the shim to typebox's
// output whenever pi is installed.
const TYPEBOX_SHIM = `
const OPTIONAL = Symbol("optional");
export const Type = {
  Object(properties, options = {}) {
    const required = Object.keys(properties).filter((k) => !properties[k][OPTIONAL]);
    return { ...options, type: "object", properties, ...(required.length ? { required } : {}) };
  },
  String: (options = {}) => ({ ...options, type: "string" }),
  Number: (options = {}) => ({ ...options, type: "number" }),
  Boolean: (options = {}) => ({ ...options, type: "boolean" }),
  Array: (items, options = {}) => ({ ...options, type: "array", items }),
  Optional: (schema) => ({ ...schema, [OPTIONAL]: true }),
};
`;

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "typebox") {
      return { url: "data:text/javascript," + encodeURIComponent(TYPEBOX_SHIM), shortCircuit: true };
    }
    return next(specifier, context);
  },
});

// Read by nvim.ts at import time, so it has to be settled first. The client
// ships beside this file; defaulting to it means a harness config that forgets
// the variable still reaches the editor rather than failing every call.
const HERE = path.dirname(fileURLToPath(import.meta.url));
process.env.FIELDGUIDE_BIN ||= path.join(HERE, "..", "bin", "fieldguide");

type Content = { type: string; text?: string };
type ToolResult = { content: Content[] };
type Tool = {
  name: string;
  label?: string;
  description: string;
  promptGuidelines?: string[];
  parameters: unknown;
  execute: (id: string, params: unknown, signal?: AbortSignal) => Promise<ToolResult>;
};
type Handler = (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<unknown>;

const tools = new Map<string, Tool>();
const handlers = new Map<string, Handler[]>();

/**
 * Only the modes that talk to the editor load the extension. The relay and the
 * socket-mode hooks run inside the sandbox, where there is no editor to reach
 * and nothing of nvim.ts should be.
 */
// The post-write report's words for a write not handled, from nvim.ts, which
// writes them. Set when the extension loads; nothing reads them before.
let VERIFY_UNAVAILABLE = "[fieldguide] verify unavailable";
let CHECKPOINT_FAILED = "checkpoint failed";

async function loadExtension() {
  const mod = (await import("./nvim.ts")) as {
    default: (pi: unknown) => void;
    VERIFY_UNAVAILABLE: string;
    CHECKPOINT_FAILED: string;
  };
  const extension = mod.default;
  VERIFY_UNAVAILABLE = mod.VERIFY_UNAVAILABLE;
  CHECKPOINT_FAILED = mod.CHECKPOINT_FAILED;
  extension({
    registerTool: (tool: Tool) => tools.set(tool.name, tool),
    on: (name: string, fn: Handler) => handlers.set(name, [...(handlers.get(name) ?? []), fn]),
  });

  // pi's notices go to its UI; ours have nowhere to go but stderr, which every
  // harness keeps in its MCP server log. Silence would read as the index simply
  // not existing.
  const ui = {
    notify: (message: string) => process.stderr.write(message + "\n"),
    setStatus: () => {},
  };
  for (const fn of handlers.get("session_start") ?? []) await fn({}, { ui });
}

async function hook(name: string, event: Record<string, unknown>, signal?: AbortSignal): Promise<unknown> {
  const [fn] = handlers.get(name) ?? [];
  return fn ? fn(event, { cwd: process.cwd(), signal }) : undefined;
}

// ---------------------------------------------------------------------------
// Hook entry points. A harness hook runs a command per tool call; these replay
// the pi extension's own hooks for one write, so a checkpoint and a verify mean
// the same thing whichever harness asked for them.
// ---------------------------------------------------------------------------

type BeforeWrite = { allow: true } | { allow: false; reason: string };

function writeEvent(target: string) {
  return { toolName: "write", input: { path: target }, content: [], isError: false };
}

async function beforeWrite(target: string, signal?: AbortSignal): Promise<BeforeWrite> {
  const decision = (await hook("tool_call", writeEvent(target), signal)) as
    | { block?: boolean; reason?: string }
    | undefined;
  return decision?.block ? { allow: false, reason: decision.reason ?? "blocked" } : { allow: true };
}

/** Empty means nothing to report: a path outside the config tree, or verify disabled. */
async function afterWrite(target: string, signal?: AbortSignal): Promise<string> {
  const result = (await hook("tool_result", writeEvent(target), signal)) as ToolResult | undefined;
  return (result?.content ?? []).map((c) => c.text ?? "").join("\n");
}

/**
 * The hook's side of a socket: one request, one answer, then close. The path
 * is made absolute here, against the cwd the agent saw, and resolved again by
 * the server against the real filesystem — the one the gate decides on. See
 * `writeHook` for why the two views differing can only fail closed.
 */
function askServer(
  socketPath: string,
  method: string,
  target: string,
  timeoutMs: number,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const conn = createConnection(socketPath);
    let buffer = "";
    let settled = false;
    const settle = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      conn.destroy();
      fn();
    };
    const timer = setTimeout(
      () => settle(() => reject(new Error(`no answer from ${socketPath} within ${timeoutMs / 1000}s`))),
      timeoutMs,
    );
    conn.setEncoding("utf8");
    conn.on("connect", () => {
      conn.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: { path: path.resolve(target) } }) + "\n");
    });
    conn.on("data", (chunk: string) => {
      buffer += chunk;
      const nl = buffer.indexOf("\n");
      if (nl < 0) return;
      settle(() => {
        try {
          const message = JSON.parse(buffer.slice(0, nl));
          if (message.error) reject(new Error(message.error.message ?? "server error"));
          else resolve(message.result ?? {});
        } catch (err) {
          reject(err);
        }
      });
    });
    conn.on("error", (err) => settle(() => reject(err)));
    conn.on("close", () => settle(() => reject(new Error(`${socketPath} closed without an answer`))));
  });
}

// Clear of what the server may spend, so it answers first when it can: each
// verb has the editor-side backstop (FIELDGUIDE_CALL_TIMEOUT_MS, 60s by
// default), a pre-write runs one (the checkpoint) and a post-write two (the
// checkpoint, then verify). A hook that gives up anyway closes its connection,
// and the server abandons the work rather than finish it for nobody.
const HOOK_TIMEOUT_MS: Record<string, number> = {
  "--before-write": Number(process.env.FIELDGUIDE_HOOK_TIMEOUT_MS) || 75_000,
  "--after-write": Number(process.env.FIELDGUIDE_HOOK_TIMEOUT_MS) || 135_000,
  "--tree-before": Number(process.env.FIELDGUIDE_HOOK_TIMEOUT_MS) || 75_000,
  "--tree-after": Number(process.env.FIELDGUIDE_HOOK_TIMEOUT_MS) || 135_000,
};

/** The server method each hook mode asks, over the socket. */
const HOOK_METHOD: Record<string, string> = {
  "--before-write": "fieldguide/beforeWrite",
  "--after-write": "fieldguide/afterWrite",
  "--tree-before": "fieldguide/treeBefore",
  "--tree-after": "fieldguide/treeAfter",
};

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

async function runHook(which: string, target: string | undefined): Promise<number> {
  if (!target) {
    process.stderr.write(`fieldguide: ${which} needs a path\n`);
    // A pre-write hook that cannot decide refuses: Claude Code reads any exit
    // but 2 as a hook that failed without blocking, and writes anyway.
    return which === "--before-write" || which === "--tree-before" ? 2 : 1;
  }
  const socketPath = process.env.FIELDGUIDE_MCP_SOCKET;
  const tree = which === "--tree-before" || which === "--tree-after";

  if (which === "--before-write" || which === "--tree-before") {
    // Deny is exit 2 with the reason on stderr: the convention Claude Code's
    // hooks use, and the easiest for any other harness's hook to map. So is a
    // server that cannot be reached or does not answer: a write nobody vetted
    // is not one to let through.
    let decision: BeforeWrite;
    try {
      if (socketPath) {
        decision = (await askServer(socketPath, HOOK_METHOD[which], target, HOOK_TIMEOUT_MS[which])) as BeforeWrite;
      } else {
        // No server, so no memory of the tree between calls: checkpoint.
        await loadExtension();
        decision = await beforeWrite(target);
      }
    } catch (err) {
      process.stderr.write(`fieldguide: cannot vet this write: ${message(err)}\n`);
      return 2;
    }
    if (decision.allow !== true) {
      process.stderr.write(((decision as { reason?: string }).reason ?? "blocked") + "\n");
      return 2;
    }
    return 0;
  }

  // A failed boot is content, not an error, and so is a server that cannot be
  // reached: the write has already happened, and the model is better told.
  let text: string;
  try {
    if (socketPath) {
      const result = await askServer(socketPath, HOOK_METHOD[which], target, HOOK_TIMEOUT_MS[which]);
      text = typeof result.text === "string" ? result.text : "";
    } else {
      // No server, so no memory of the tree: verify whatever was written.
      await loadExtension();
      text = await afterWrite(target);
    }
  } catch (err) {
    text = `[fieldguide] verify unavailable: ${message(err)}`;
  }
  if (text) process.stdout.write(text + "\n");
  return 0;
}

// ---------------------------------------------------------------------------
// The MCP server.
// ---------------------------------------------------------------------------

// Newest first. A client asking for one of these gets it back; anything else is
// offered the newest, and the client decides whether it can live with that.
const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];

type Id = string | number;
type Message = { jsonrpc?: string; id?: Id | null; method?: string; params?: Record<string, unknown> };

/**
 * One MCP conversation: stdio, or one connection to the socket. Request ids are
 * the client's, so two sessions may well both use id 1; everything keyed by id
 * lives here rather than in the process.
 */
class Session {
  readonly inflight = new Map<Id, AbortController>();
  // A plain field, not a parameter property: node strips types, and does not
  // compile the ones that would generate code.
  private readonly write: (line: string) => void;

  constructor(write: (line: string) => void) {
    this.write = write;
  }

  send(message: Record<string, unknown>) {
    this.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
  }

  fail(id: Id | null, code: number, message: string) {
    this.send({ id, error: { code, message } });
  }

  /** Nobody is left to read a result, so in-flight calls are abandoned. */
  abandon() {
    for (const controller of this.inflight.values()) controller.abort();
  }
}

/**
 * pi puts `promptGuidelines` in its system prompt. MCP has no such slot that
 * every client honours, and the description is the one field every client
 * shows the model, so the guidance rides along there instead of being dropped.
 */
function describe(tool: Tool): string {
  if (!tool.promptGuidelines?.length) return tool.description;
  return tool.description + "\n\n" + tool.promptGuidelines.map((g) => `- ${g}`).join("\n");
}

function listTools() {
  return [...tools.values()].map((tool) => ({
    name: tool.name,
    title: tool.label,
    description: describe(tool),
    // Round-tripped through JSON so nothing but plain schema reaches the wire.
    inputSchema: JSON.parse(JSON.stringify(tool.parameters)),
  }));
}

async function callTool(session: Session, id: Id, params: Record<string, unknown>) {
  const tool = tools.get(String(params.name));
  if (!tool) {
    // A protocol error, not a tool error: the model asked for a tool it was
    // never offered, which is a client bug or a disabled verb.
    session.fail(id, -32602, `unknown tool: ${String(params.name)}`);
    return;
  }
  const controller = new AbortController();
  session.inflight.set(id, controller);
  try {
    const result = await tool.execute(String(id), params.arguments ?? {}, controller.signal);
    if (controller.signal.aborted) return;
    session.send({ id, result: { content: result.content } });
  } catch (err) {
    if (controller.signal.aborted) return;
    // pi marks a failed tool by throwing; MCP by isError. Either way the model
    // sees the message — agents recover well from clear errors.
    session.send({ id, result: { content: [{ type: "text", text: message(err) }], isError: true } });
  } finally {
    session.inflight.delete(id);
  }
}

/**
 * The two write hooks, for a hook running inside the sandbox. Not tools: they
 * are absent from tools/list, and no model is offered them. An agent with a
 * shell can still connect to the socket and call them directly, which grants
 * nothing it does not already have:
 *
 *   beforeWrite  the path gate, which only answers, plus a checkpoint, which
 *                commits the config tree to the shadow repo. Any write the
 *                agent makes already does both.
 *   afterWrite   the same checkpoint, plus verify, which is an agent verb in
 *                its own right.
 *
 * Neither reads a file for the caller, runs anything the caller chose, or
 * reaches Neovim beyond the verbs. A refusal names the path the gate resolved,
 * which tells the caller where a path outside its sandbox leads: the same the
 * pi agent learns from the gate, and never a file's contents.
 *
 * The path is decided on the real filesystem, and the agent writes to its own
 * view of it. The two agree everywhere the agent can write — the config tree
 * is bound at its own path — and differ only under the tmpfs'd /tmp, $HOME and
 * $XDG_RUNTIME_DIR. A path there resolves, out here, to something the agent
 * never made: outside the zones, and refused. The one other case is a path
 * that leads into the config tree out here but not in there (a link in $HOME,
 * say): allowed, and the agent's write lands in its own tmpfs, where it is
 * thrown away. Both fail closed.
 */
// The config tree as of the last checkpoint this server made, to tell a
// shell command that wrote something from one that did not. Kept here, out of
// the agent's reach: a hook runs inside the sandbox, where anything it stored
// the agent could rewrite.
let lastTree: string | undefined;
// Whether any hook has looked yet. Before then there is no "since": the tree
// as it stands is the user's, to checkpoint as the baseline, not to report.
let looked = false;

/**
 * Whether a post-write report says the write was handled: checkpointed, and
 * verified (a boot that failed is still a verify). If not, the tree is not
 * taken as the new baseline, and the next look sees the same change again.
 */
function handled(report: string): boolean {
  return !report.includes(VERIFY_UNAVAILABLE) && !report.includes(CHECKPOINT_FAILED);
}

function configRoot(): string {
  return process.env.FIELDGUIDE_CONFIG_DIR || "";
}

/**
 * The tree hooks, for a harness whose shell can write anywhere in the config
 * tree unannounced (Codex). The server fingerprints its own config root, never
 * a path the caller names, and compares with the tree as last checkpointed:
 *
 *   treeBefore  changed since (the user's own edits): checkpoint them now, so
 *               what the agent does next is undoable on its own
 *   treeAfter   changed since: checkpoint and verify, and say so; as the
 *               first look of all, with no "since", the same as treeBefore
 *
 * Calling either directly grants nothing: the most either does is a
 * checkpoint and a verify. And neither can be talked into skipping a change,
 * because the only state is here. This is a safety net, not the boundary: a
 * shell can write after the last call that looks, and a checkpoint is git's
 * `add`, whose stat cache can miss a same-size rewrite with its mtime put back
 * (which the fingerprint, by its change time, still sees and verifies). The
 * agent sandbox is what keeps all of those writes inside the config tree.
 */
async function treeHook(session: Session, id: Id, which: "before" | "after") {
  const root = configRoot();
  if (!root) {
    session.fail(id, -32602, "FIELDGUIDE_CONFIG_DIR is unset");
    return;
  }
  const controller = new AbortController();
  session.inflight.set(id, controller);
  const { signal } = controller;
  try {
    const first = !looked;
    looked = true;
    const now = fingerprint(root);
    let result: Record<string, unknown>;
    if (now === lastTree) {
      result = which === "before" ? { allow: true } : { text: "" };
    } else if (which === "before" || first) {
      const decision = await beforeWrite(root, signal);
      if (decision.allow) lastTree = now;
      if (which === "before") result = decision;
      else if (decision.allow) result = { text: "" };
      else {
        // No baseline after all: the next look is the first again, so the
        // config as it stands is not reported as a change the agent made.
        looked = false;
        result = {
          text: `[fieldguide] ${CHECKPOINT_FAILED}: ${decision.reason} — the config as it stands has no checkpoint, so :FieldguideUndo cannot go back to it`,
        };
      }
    } else {
      const text = await afterWrite(root, signal);
      if (handled(text)) lastTree = fingerprint(root);
      result = { text };
    }
    if (!signal.aborted) session.send({ id, result });
  } catch (err) {
    if (!signal.aborted) session.fail(id, -32603, message(err));
  } finally {
    session.inflight.delete(id);
  }
}

async function writeHook(session: Session, id: Id, which: "before" | "after", params: Record<string, unknown>) {
  const target = params.path;
  if (typeof target !== "string" || !path.isAbsolute(target)) {
    session.fail(id, -32602, "path must be absolute");
    return;
  }
  // In flight like a tool call, so a hook that hangs up — gave up waiting, or
  // was killed — aborts the checkpoint or verify it asked for.
  looked = true;
  const controller = new AbortController();
  session.inflight.set(id, controller);
  const { signal } = controller;
  try {
    const result =
      which === "before" ? await beforeWrite(target, signal) : { text: await afterWrite(target, signal) };
    // A write that was checkpointed and verified is the tree's new baseline.
    if (which === "after" && configRoot() && handled(String((result as { text?: string }).text ?? ""))) {
      lastTree = fingerprint(configRoot());
    }
    if (!signal.aborted) session.send({ id, result });
  } catch (err) {
    if (!signal.aborted) session.fail(id, -32603, message(err));
  } finally {
    session.inflight.delete(id);
  }
}

function dispatch(session: Session, message: Message) {
  const { id, method } = message;
  // `?? {}` and not a destructuring default, which lets null through.
  const params = message.params ?? {};
  const isRequest = id !== undefined && id !== null;

  // A request without an id is a notification, and a notification is never
  // answered. None of these has any use as one, and a tools/call has side
  // effects, so they are dropped rather than run.
  if (
    !isRequest &&
    (method === "initialize" || method === "ping" || method?.startsWith("tools/") || method?.startsWith("fieldguide/"))
  ) {
    return;
  }

  switch (method) {
    case "initialize": {
      const asked = String(params.protocolVersion ?? "");
      session.send({
        id,
        result: {
          protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "fieldguide", version: "0" },
        },
      });
      return;
    }
    case "ping":
      session.send({ id, result: {} });
      return;
    case "tools/list":
      session.send({ id, result: { tools: listTools() } });
      return;
    case "tools/call":
      // Not awaited: a slow verify must not hold up a ping, or a cancellation
      // of itself.
      void callTool(session, id as Id, params);
      return;
    case "fieldguide/beforeWrite":
      void writeHook(session, id as Id, "before", params);
      return;
    case "fieldguide/afterWrite":
      void writeHook(session, id as Id, "after", params);
      return;
    case "fieldguide/treeBefore":
      void treeHook(session, id as Id, "before");
      return;
    case "fieldguide/treeAfter":
      void treeHook(session, id as Id, "after");
      return;
    case "notifications/cancelled": {
      // The spec asks for no response to a cancelled request. Aborting kills
      // the client process; the editor finishes whatever it had started.
      const controller = session.inflight.get(params.requestId as Id);
      controller?.abort();
      return;
    }
    default:
      // Notifications we have no use for (initialized, progress, roots) are
      // ignored; a request we do not know gets told so rather than silence.
      if (isRequest) session.fail(id as Id, -32601, `method not found: ${String(method)}`);
  }
}

/** Read one newline-delimited JSON-RPC stream into a session. */
function attach(session: Session, input: NodeJS.ReadableStream, onClose: () => void) {
  const lines = createInterface({ input, crlfDelay: Infinity });
  lines.on("line", (line) => {
    if (!line.trim()) return;
    let message: Message;
    try {
      message = JSON.parse(line);
    } catch {
      session.fail(null, -32700, "parse error");
      return;
    }
    // A string method, checked here once, so nothing downstream has to guard
    // every use of it: a number in its place used to crash the server.
    if (
      typeof message !== "object" ||
      message === null ||
      Array.isArray(message) ||
      typeof message.method !== "string" ||
      !message.method
    ) {
      session.fail((message as Message)?.id ?? null, -32600, "invalid request");
      return;
    }
    dispatch(session, message);
  });
  lines.on("close", () => {
    session.abandon();
    onClose();
  });
}

function serveStdio() {
  // The harness closing our stdin is the end of the session. The process then
  // ends on its own once the aborted clients are reaped; the timer is only for
  // a client that ignores the signal.
  const session = new Session((line) => process.stdout.write(line));
  attach(session, process.stdin, () => setTimeout(() => process.exit(0), 2000).unref());
}

type Identity = { dev: number; ino: number };

/** Which file a path names right now, or null if it names none. */
function identity(p: string): Identity | null {
  try {
    const { dev, ino } = lstatSync(p);
    return { dev, ino };
  } catch {
    return null;
  }
}

function same(a: Identity | null, b: Identity | null): boolean {
  return !!a && !!b && a.dev === b.dev && a.ino === b.ino;
}

/**
 * Removes the path only if it still names the file that was looked at. Between
 * a look and an unlink another server may have bound a socket of its own
 * there, and unlinking that would leave it running with nobody able to reach
 * it.
 */
function unlinkIfSame(p: string, seen: Identity): boolean {
  if (!same(identity(p), seen)) return false;
  try {
    unlinkSync(p);
  } catch {}
  return true;
}

/**
 * Takes over a path only when it is a dead socket: a live one is another
 * server, and anything else is not ours to delete. Looked at again if it
 * changed while being probed: someone else got there first, and what they
 * left is decided on its own merits.
 */
async function clearStale(socketPath: string): Promise<string | null> {
  for (let attempt = 0; attempt < 5; attempt++) {
    let stat;
    try {
      stat = lstatSync(socketPath);
    } catch {
      return null;
    }
    if (!stat.isSocket()) return `${socketPath} exists and is not a socket`;
    const seen = { dev: stat.dev, ino: stat.ino };
    const live = await new Promise<boolean>((resolve) => {
      const probe = createConnection(socketPath);
      probe.on("connect", () => {
        probe.destroy();
        resolve(true);
      });
      probe.on("error", () => resolve(false));
    });
    if (live) return `${socketPath} is already being served`;
    if (unlinkIfSame(socketPath, seen)) return null;
  }
  return `${socketPath} kept changing while it was being taken over`;
}

const TAKEOVER_LOCK_STALE_MS = 5_000;

/**
 * Runs `fn` holding `<socket>.lock`, a directory, because mkdir either makes
 * it or fails: two servers can never both hold it. A takeover takes
 * milliseconds, so a lock older than a few seconds was left by a server that
 * died holding it, and is taken over in turn.
 */
async function withTakeoverLock<T>(socketPath: string, fn: () => Promise<T>): Promise<T> {
  const lock = `${socketPath}.lock`;
  const deadline = Date.now() + 2 * TAKEOVER_LOCK_STALE_MS;
  for (;;) {
    try {
      mkdirSync(lock, 0o700);
      break;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
    }
    try {
      if (Date.now() - statSync(lock).mtimeMs > TAKEOVER_LOCK_STALE_MS) rmdirSync(lock);
    } catch {}
    if (Date.now() > deadline) throw new Error(`${lock} is held and has not been released`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  try {
    return await fn();
  } finally {
    try {
      rmdirSync(lock);
    } catch {}
  }
}

// sun_path is 104 bytes on macOS and 108 on Linux, NUL included. Past that the
// kernel answers EINVAL, which names neither the limit nor the path's length.
const SOCKET_PATH_MAX = 103;

async function serveSocket(socketPath: string) {
  const length = Buffer.byteLength(socketPath);
  if (length > SOCKET_PATH_MAX) {
    process.stderr.write(
      `fieldguide: ${socketPath} is ${length} bytes; a unix socket path must fit in ${SOCKET_PATH_MAX}. ` +
        `Put it somewhere shorter, such as $XDG_RUNTIME_DIR.\n`,
    );
    process.exit(1);
  }
  const refuse = (why: string) => {
    process.stderr.write(`fieldguide: ${why}\n`);
    process.exit(1);
  };

  const server = createServer((conn: Socket) => {
    conn.setEncoding("utf8");
    const session = new Session((line) => {
      if (!conn.destroyed) conn.write(line);
    });
    // A connection that errors (a relay killed mid-write) is one session
    // ending, not the server.
    conn.on("error", () => conn.destroy());
    attach(session, conn, () => conn.end());
  });

  // Probe, clear and bind as one step, under the lock: another server doing
  // the same at the same time would otherwise see the same dead socket, and
  // one of the two would unlink the other's fresh one.
  let own: Identity | null = null;
  const refusal = await withTakeoverLock(socketPath, async () => {
    const stale = await clearStale(socketPath);
    if (stale) return stale;
    // Owner-only from the moment it exists, not after a chmod: the socket is a
    // way to run the verbs, and nobody else on the machine should have it.
    const previous = process.umask(0o177);
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(socketPath, () => resolve());
      });
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "EADDRINUSE") return `${socketPath} is already being served`;
      throw err;
    } finally {
      process.umask(previous);
    }
    chmodSync(socketPath, 0o600);
    // The socket this server bound. Only this one is ever removed on the way out.
    own = identity(socketPath);
    return null;
  });
  if (refusal) refuse(refusal);

  let closing = false;
  const shutdown = () => {
    if (closing) return;
    closing = true;
    // Not server.close(): libuv unlinks a listening socket's path when it
    // closes it, whatever file is there by then. Exiting drops the
    // connections all the same, and the path is removed only if it is ours.
    if (own) unlinkIfSame(socketPath, own);
    process.exit(0);
  };
  // A server whose socket is gone, or is now another server's, can never be
  // reached again. It goes rather than run on as an orphan, and leaves the
  // path to whoever holds it.
  setInterval(() => {
    if (closing || same(identity(socketPath), own)) return;
    process.stderr.write(`fieldguide: ${socketPath} is no longer this server's; exiting\n`);
    closing = true;
    process.exit(0);
  }, 1000).unref();
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  process.on("SIGHUP", shutdown);
  // Launched with a pipe on stdin, the server lives as long as whoever holds
  // the other end: an editor that dies without a word takes it along. libuv's
  // "pipe" is a socketpair, not a FIFO, so both count. /dev/null and a
  // terminal do not, and leave the server to its signals.
  try {
    const stdin = fstatSync(0);
    if (stdin.isFIFO() || stdin.isSocket()) {
      process.stdin.on("end", shutdown);
      process.stdin.on("close", shutdown);
      process.stdin.resume();
    }
  } catch {}
  process.stderr.write(`fieldguide: MCP on ${socketPath}\n`);
}

/**
 * The harness's MCP server, from inside the sandbox: bytes both ways and
 * nothing else. It never loads nvim.ts and needs none of the editor's
 * variables, because everything it relays is decided out there.
 */
function relay(socketPath: string | undefined) {
  if (!socketPath) {
    process.stderr.write("fieldguide: --relay needs a socket path, or FIELDGUIDE_MCP_SOCKET\n");
    process.exit(1);
  }
  const conn = createConnection(socketPath);
  conn.on("error", (err: NodeJS.ErrnoException) => {
    const why =
      err.code === "ENOENT" || err.code === "ECONNREFUSED" ? "no fieldguide server is listening there" : err.message;
    process.stderr.write(`fieldguide: cannot reach ${socketPath}: ${why}\n`);
    process.exit(1);
  });
  conn.on("connect", () => {
    process.stdin.pipe(conn);
    conn.pipe(process.stdout);
  });
  // Either side ending is the end: the harness closed stdin, or the server went.
  conn.on("close", () => process.exit(0));
}

// ---------------------------------------------------------------------------

const mode = process.argv[2];
if (mode === "--before-write" || mode === "--after-write") {
  // exitCode rather than exit(): stdout to a pipe is asynchronous on macOS, and
  // exiting outright can drop the very line the hook is waiting for.
  process.exitCode = await runHook(mode, process.argv[3]);
} else if (mode === "--tree-before" || mode === "--tree-after") {
  // The tree is the config root; a server ignores the path and uses its own.
  process.exitCode = await runHook(mode, process.env.FIELDGUIDE_CONFIG_DIR || process.cwd());
} else if (mode === "--relay") {
  relay(process.argv[3] ?? process.env.FIELDGUIDE_MCP_SOCKET);
} else if (mode === "--listen") {
  if (!process.argv[3]) {
    process.stderr.write("fieldguide: --listen needs a socket path\n");
    process.exit(1);
  }
  await loadExtension();
  await serveSocket(process.argv[3]);
} else {
  await loadExtension();
  serveStdio();
}

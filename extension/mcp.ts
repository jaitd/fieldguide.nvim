// fieldguide's MCP server: the same verbs, for harnesses that are not pi.
//
//   node extension/mcp.ts                        stdio MCP server
//   node extension/mcp.ts --before-write <path>  gate + checkpoint, for a pre-write hook
//   node extension/mcp.ts --after-write <path>   checkpoint + verify, for a post-write hook
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

import { registerHooks } from "node:module";
import * as path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

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

const { default: extension } = (await import("./nvim.ts")) as { default: (pi: unknown) => void };
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

async function hook(name: string, event: Record<string, unknown>, signal?: AbortSignal): Promise<unknown> {
  const [fn] = handlers.get(name) ?? [];
  return fn ? fn(event, { cwd: process.cwd(), signal }) : undefined;
}

// ---------------------------------------------------------------------------
// Hook entry points. A harness hook runs a command per tool call; these replay
// the pi extension's own hooks for one write, so a checkpoint and a verify mean
// the same thing whichever harness asked for them.
// ---------------------------------------------------------------------------

async function runHook(which: string, target: string | undefined): Promise<number> {
  if (!target) {
    process.stderr.write(`fieldguide: ${which} needs a path\n`);
    return 1;
  }
  const event = { toolName: "write", input: { path: target }, content: [], isError: false };

  if (which === "--before-write") {
    // Deny is exit 2 with the reason on stderr: the convention Claude Code's
    // hooks use, and the easiest for any other harness's hook to map.
    const decision = (await hook("tool_call", event)) as { block?: boolean; reason?: string } | undefined;
    if (decision?.block) {
      process.stderr.write((decision.reason ?? "blocked") + "\n");
      return 2;
    }
    return 0;
  }

  // Nothing printed means nothing to report: a path outside the config tree,
  // or verify disabled. A failed boot is content, not an error, so exit 0.
  const result = (await hook("tool_result", event)) as ToolResult | undefined;
  const text = (result?.content ?? []).map((c) => c.text ?? "").join("\n");
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

function send(message: Record<string, unknown>) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
}

function fail(id: Id | null, code: number, message: string) {
  send({ id, error: { code, message } });
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

const inflight = new Map<Id, AbortController>();

async function callTool(id: Id, params: Record<string, unknown>) {
  const tool = tools.get(String(params.name));
  if (!tool) {
    // A protocol error, not a tool error: the model asked for a tool it was
    // never offered, which is a client bug or a disabled verb.
    fail(id, -32602, `unknown tool: ${String(params.name)}`);
    return;
  }
  const controller = new AbortController();
  inflight.set(id, controller);
  try {
    const result = await tool.execute(String(id), params.arguments ?? {}, controller.signal);
    if (controller.signal.aborted) return;
    send({ id, result: { content: result.content } });
  } catch (err) {
    if (controller.signal.aborted) return;
    // pi marks a failed tool by throwing; MCP by isError. Either way the model
    // sees the message — agents recover well from clear errors.
    const text = err instanceof Error ? err.message : String(err);
    send({ id, result: { content: [{ type: "text", text }], isError: true } });
  } finally {
    inflight.delete(id);
  }
}

function dispatch(message: Message) {
  const { id, method, params = {} } = message;
  const isRequest = id !== undefined && id !== null;

  switch (method) {
    case "initialize": {
      const asked = String(params.protocolVersion ?? "");
      send({
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
      send({ id, result: {} });
      return;
    case "tools/list":
      send({ id, result: { tools: listTools() } });
      return;
    case "tools/call":
      // Not awaited: a slow verify must not hold up a ping, or a cancellation
      // of itself.
      void callTool(id as Id, params);
      return;
    case "notifications/cancelled": {
      // The spec asks for no response to a cancelled request. Aborting kills
      // the client process; the editor finishes whatever it had started.
      const controller = inflight.get(params.requestId as Id);
      controller?.abort();
      return;
    }
    default:
      // Notifications we have no use for (initialized, progress, roots) are
      // ignored; a request we do not know gets told so rather than silence.
      if (isRequest) fail(id as Id, -32601, `method not found: ${String(method)}`);
  }
}

function serve() {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  lines.on("line", (line) => {
    if (!line.trim()) return;
    let message: Message;
    try {
      message = JSON.parse(line);
    } catch {
      fail(null, -32700, "parse error");
      return;
    }
    if (typeof message !== "object" || message === null || Array.isArray(message) || !message.method) {
      fail((message as Message)?.id ?? null, -32600, "invalid request");
      return;
    }
    dispatch(message);
  });

  // The harness closing our stdin is the end of the session. Nobody is left to
  // read a result, so in-flight calls are abandoned rather than waited on. The
  // process then ends on its own once the aborted clients are reaped; the timer
  // is only for a client that ignores the signal.
  lines.on("close", () => {
    for (const controller of inflight.values()) controller.abort();
    setTimeout(() => process.exit(0), 2000).unref();
  });
}

// ---------------------------------------------------------------------------

const mode = process.argv[2];
if (mode === "--before-write" || mode === "--after-write") {
  // exitCode rather than exit(): stdout to a pipe is asynchronous on macOS, and
  // exiting outright can drop the very line the hook is waiting for.
  process.exitCode = await runHook(mode, process.argv[3]);
} else {
  serve();
}

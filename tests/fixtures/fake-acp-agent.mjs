// A scripted stand-in for an ACP agent (`opencode acp`, claude-agent-acp, …).
//
// The ACP twin of fake-agent.sh: a realistic session without a provider, a key
// or a network. Where that one only streams, this one also *asks* — permission
// prompts and a file read the client never offered — and waits for the answers,
// because an unanswered agent request is the failure unique to this protocol.
//
//   node fake-acp-agent.mjs <log> [deltas]
//
// Everything the client sends is appended to <log>, one JSON object per line,
// so a test can assert on the replies as well as on the events.
//
//   FAKE_NO_LOAD=1   advertise no session/load, to exercise the fallback

import { appendFileSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

const [logPath, deltasArg] = process.argv.slice(2);
const DELTAS = Number(deltasArg || 200);
writeFileSync(logPath, "");

const emit = (m) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
const update = (sessionId, u) => emit({ method: "session/update", params: { sessionId, update: u } });

// Requests we make of the client, resolved by its reply.
let nextId = 0;
const waiting = new Map();
const ask = (method, params) =>
  new Promise((resolve) => {
    const id = nextId++;
    waiting.set(id, resolve);
    emit({ id, method, params });
  });

let prompts = 0;

async function runPrompt(id, sessionId) {
  prompts++;
  if (prompts > 1) {
    // The second turn is short and ends at the output limit.
    update(sessionId, { sessionUpdate: "agent_message_chunk", messageId: "m-2", content: { type: "text", text: "second" } });
    emit({ id, result: { stopReason: "max_tokens" } });
    return;
  }

  update(sessionId, { sessionUpdate: "available_commands_update", availableCommands: [] });
  update(sessionId, { sessionUpdate: "agent_thought_chunk", messageId: "m-1", content: { type: "text", text: "pondering" } });
  for (let i = 1; i <= DELTAS; i++) {
    update(sessionId, { sessionUpdate: "agent_message_chunk", messageId: "m-1", content: { type: "text", text: `tok${i} ` } });
  }
  // One large chunk, to cross read boundaries in a single message.
  update(sessionId, { sessionUpdate: "agent_message_chunk", messageId: "m-1", content: { type: "text", text: "x".repeat(20000) } });
  // U+2028 / U+2029 inside a string: JSON.stringify leaves them raw.
  update(sessionId, { sessionUpdate: "agent_message_chunk", messageId: "m-1", content: { type: "text", text: "before mid after" } });

  // A file tool, announced before its arguments exist, as opencode does.
  update(sessionId, { sessionUpdate: "tool_call", toolCallId: "tc-read", title: "read", kind: "read", status: "pending", locations: [], rawInput: {} });
  update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "tc-read", status: "in_progress", kind: "read", title: "read", locations: [{ path: "/cfg/init.lua" }], rawInput: { filePath: "/cfg/init.lua" } });
  update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "tc-read", status: "completed", title: "cfg/init.lua", content: [{ type: "content", content: { type: "text", text: "vim.g.x = 1" } }] });

  // One of fieldguide's own tools, under the harness's MCP namespace.
  update(sessionId, { sessionUpdate: "tool_call", toolCallId: "tc-state", title: "fieldguide_nvim_state", kind: "other", status: "pending", rawInput: {} });
  update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "tc-state", status: "completed", content: [{ type: "content", content: { type: "text", text: "STATE" } }] });

  // An edit that asks first. The agent is stalled until the client answers.
  update(sessionId, { sessionUpdate: "tool_call", toolCallId: "tc-edit", title: "apply_patch", kind: "edit", status: "pending", rawInput: {} });
  const options = [
    { optionId: "once", kind: "allow_once", name: "Allow once" },
    { optionId: "always", kind: "allow_always", name: "Always allow" },
    { optionId: "reject", kind: "reject_once", name: "Reject" },
  ];
  const edit = await ask("session/request_permission", { sessionId, toolCall: { toolCallId: "tc-edit", kind: "edit", title: "cfg/init.lua" }, options });
  const allowed = edit.result?.outcome?.optionId === "once";
  update(sessionId, {
    sessionUpdate: "tool_call_update",
    toolCallId: "tc-edit",
    status: allowed ? "completed" : "failed",
    rawInput: { patchText: "*** Begin Patch\n*** Update File: /cfg/init.lua\n@@\n+-- hi\n*** End Patch" },
    content: [{ type: "content", content: { type: "text", text: allowed ? "Success" : "rejected" } }],
  });

  // A shell, which no fieldguide profile grants. Must be refused.
  await ask("session/request_permission", { sessionId, toolCall: { toolCallId: "tc-sh", kind: "execute", title: "cat ../secret" }, options });
  // A file read through the client, which the client never offered.
  await ask("fs/read_text_file", { sessionId, path: "/etc/passwd" });

  // A tool that fails.
  update(sessionId, { sessionUpdate: "tool_call", toolCallId: "tc-bad", title: "grep", kind: "search", status: "pending", rawInput: { pattern: "x", path: "/elsewhere" } });
  update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "tc-bad", status: "failed", content: [{ type: "content", content: { type: "text", text: "outside fieldguide's zones" } }] });

  update(sessionId, { sessionUpdate: "usage_update", used: 1, size: 2 });
  // Something newer than the adapter. Must surface, never vanish.
  update(sessionId, { sessionUpdate: "some_future_update", payload: 1 });
  // A malformed line. Reported as data, never thrown.
  process.stdout.write('{"jsonrpc":"2.0","method":"session/update", BROKEN\n');

  update(sessionId, { sessionUpdate: "agent_message_chunk", messageId: "m-1b", content: { type: "text", text: "afterthetools" } });
  emit({ id, result: { stopReason: "end_turn" } });
}

function replay(sessionId) {
  update(sessionId, { sessionUpdate: "user_message_chunk", messageId: "u-1", content: { type: "text", text: "first " } });
  update(sessionId, { sessionUpdate: "user_message_chunk", messageId: "u-1", content: { type: "text", text: "question" } });
  update(sessionId, { sessionUpdate: "agent_message_chunk", messageId: "a-1", content: { type: "text", text: "first answer" } });
  // A replayed call carries its result's title, not its name.
  update(sessionId, { sessionUpdate: "tool_call", toolCallId: "r-read", title: "Makefile", kind: "read", status: "pending", locations: [{ path: "/cfg/Makefile" }], rawInput: { filePath: "/cfg/Makefile" } });
  update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "r-read", status: "completed", content: [{ type: "content", content: { type: "text", text: "all:" } }] });
  update(sessionId, { sessionUpdate: "user_message_chunk", messageId: "u-2", content: { type: "text", text: "second question" } });
  update(sessionId, { sessionUpdate: "agent_message_chunk", messageId: "a-2", content: { type: "text", text: "second answer" } });
}

createInterface({ input: process.stdin }).on("line", (line) => {
  appendFileSync(logPath, line + "\n");
  let m;
  try {
    m = JSON.parse(line);
  } catch {
    return;
  }
  if (m.method === undefined && waiting.has(m.id)) {
    waiting.get(m.id)(m);
    waiting.delete(m.id);
    return;
  }
  switch (m.method) {
    case "initialize":
      emit({ id: m.id, result: { protocolVersion: 1, agentCapabilities: { loadSession: !process.env.FAKE_NO_LOAD }, authMethods: [] } });
      break;
    case "session/new":
      emit({ id: m.id, result: { sessionId: "sess-new" } });
      break;
    case "session/load":
      replay(m.params.sessionId);
      emit({ id: m.id, result: null });
      break;
    case "session/prompt":
      runPrompt(m.id, m.params.sessionId);
      break;
    case "session/cancel":
      break; // a notification: logged above, answered by nothing
    default:
      if (m.id !== undefined) emit({ id: m.id, error: { code: -32601, message: "method not found" } });
  }
});

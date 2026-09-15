#!/usr/bin/env bash
# A scripted stand-in for `pi --mode rpc`.
#
# Emits a realistic event stream so the adapter can be tested for framing,
# ordering and loss without a provider, an API key, or a network. Reads commands
# on stdin the way the real thing does, so send/response correlation is
# exercised too.
#
#   fake-agent.sh [deltas] [hold-seconds]
#
# `hold-seconds` pauses mid-stream, so a test can drive a session that is
# genuinely still running — bash emits even 20k lines in a fraction of a second,
# which is far too quick to submit into.
#
# Deliberately writes with no flush discipline and no alignment between writes
# and reads: the kernel will split these into chunks wherever it likes, which is
# the condition the framer exists for.

set -u
DELTAS="${1:-200}"
HOLD="${2:-0}"

emit() { printf '%s\n' "$1"; }

# The event stream runs in the background and stdin is read in the foreground,
# not the other way around. When job control is off — which it always is for a
# non-interactive script — POSIX redirects an async command's stdin from
# /dev/null, so a backgrounded reader silently receives nothing.
emit_stream() {

emit '{"type":"agent_start"}'
emit '{"type":"turn_start"}'
emit '{"type":"message_start","message":{"role":"assistant"}}'
emit '{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}'

# The load case.
i=1
while [ "$i" -le "$DELTAS" ]; do
  emit "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"tok$i \"}}"
  i=$((i + 1))
done

# Optional pause, so a caller can interact with a session that is still live.
[ "$HOLD" != "0" ] && sleep "$HOLD"

# A single large delta, to cross read-buffer boundaries in one message.
BIG=$(head -c 20000 /dev/zero | tr '\0' 'x')
emit "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"$BIG\"}}"

# U+2028 and U+2029 inside a string. A line reader that splits on these
# corrupts the message; this is why the framer exists.
printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"before\xe2\x80\xa8mid\xe2\x80\xa9after"}}\n'

emit '{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"done"}}'

# A tool round trip, then more prose. The agent talking again after a tool call
# is the ordinary shape of an answer, and it is where the two have to be kept
# visually apart.
emit '{"type":"tool_execution_start","toolCallId":"tc-1","toolName":"nvim_state","input":{"what":"nvim"}}'
emit '{"type":"tool_execution_end","toolCallId":"tc-1","toolName":"nvim_state","args":{"what":"nvim"},"result":{"content":[{"type":"text","text":"{\"ok\":true,\"result\":{\"nvim\":{\"version\":\"0.12.4\"}}}"}],"details":{}},"isError":false}'
emit '{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":1}}'
emit '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"  \n afterthetool"}}'
emit '{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":1,"content":"afterthetool"}}'

# A blocking dialog: the agent stalls here until the client answers.
emit '{"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Reload config modules?","message":"fieldguide","timeout":5000}'

# Progress events the renderer folds into one status line.
emit '{"type":"compaction_start"}'
emit '{"type":"compaction_end"}'

# Something we do not know about. Must surface, never be dropped silently.
emit '{"type":"some_future_event","payload":1}'

# A malformed line. Must be reported as data, not throw.
emit '{"type":"message_update", BROKEN'

emit '{"type":"message_end","message":{"role":"assistant","content":"done"}}'
emit '{"type":"turn_end","message":{},"toolResults":[]}'
emit '{"type":"agent_end","willRetry":false}'

# No trailing newline on the final line: flush() must still surface it.
printf '{"type":"agent_settled"}'
}

emit_stream &
STREAM=$!

# Reading stays in the foreground, where stdin is real. Answer commands as the
# agent does; `extension_ui_response` is a reply to us, not a command, so it
# gets no response of its own.
grace=0
while :; do
  if IFS= read -r -t 0.1 line; then
    id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    cmd=$(printf '%s' "$line" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
    if [ -n "$cmd" ] && [ "$cmd" != "extension_ui_response" ]; then
      emit "{\"type\":\"response\",\"id\":\"$id\",\"command\":\"$cmd\",\"success\":true}"
    fi
  fi
  # Once the scripted stream is done, linger briefly for in-flight replies.
  if ! kill -0 "$STREAM" 2>/dev/null; then
    grace=$((grace + 1))
    [ "$grace" -gt 3 ] && break
  fi
done
exit 0

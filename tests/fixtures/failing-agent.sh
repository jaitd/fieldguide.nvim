#!/usr/bin/env bash
# An agent whose reply ends badly.
#
# A provider that refuses — a model the account may not use, a subscription
# that has run out — does not send an error event. It sends an ordinary
# assistant message with no content, carrying the reason in `stopReason` and
# `errorMessage`, and then settles as if all were well. This is that stream.
#
#   failing-agent.sh [reason]

set -u
REASON="${1:-error}"

emit() { printf '%s\n' "$1"; }

emit_stream() {
  emit '{"type":"agent_start"}'
  emit '{"type":"turn_start"}'
  emit '{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"hi"}],"timestamp":1}}'
  emit '{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"hi"}],"timestamp":1}}'
  if [ "$REASON" = "length" ]; then
    emit '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"length","timestamp":2}}'
    emit '{"type":"turn_end","message":{"role":"assistant","content":[],"stopReason":"length","timestamp":2},"toolResults":[]}'
  else
    emit '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"Codex error: that model is not available on this account.","timestamp":2}}'
    emit '{"type":"turn_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"Codex error: that model is not available on this account.","timestamp":2},"toolResults":[]}'
  fi
  emit '{"type":"agent_end","willRetry":false}'
  emit '{"type":"agent_settled"}'
}

emit_stream &
STREAM=$!

grace=0
while :; do
  if IFS= read -r -t 0.1 line; then
    id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    cmd=$(printf '%s' "$line" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
    if [ -n "$cmd" ] && [ "$cmd" != "extension_ui_response" ]; then
      emit "{\"type\":\"response\",\"id\":\"$id\",\"command\":\"$cmd\",\"success\":true}"
    fi
  fi
  if ! kill -0 "$STREAM" 2>/dev/null; then
    grace=$((grace + 1))
    [ "$grace" -gt 3 ] && break
  fi
done
exit 0

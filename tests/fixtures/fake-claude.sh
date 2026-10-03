#!/usr/bin/env bash
# A scripted stand-in for `claude -p --input-format stream-json
# --output-format stream-json`.
#
# One process for the whole session, as the real one is. Each user line on
# stdin is answered with one turn: init, an echo of the prompt, a result. A
# prompt containing "slow" holds its turn open until an interrupt arrives,
# which is answered as Claude answers one: a control_response, then a result
# whose terminal_reason says the turn was aborted. The session id is the one
# given with --resume, or a new one.

set -u
session="s-new"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--resume" ]; then
    session="${args[$((i + 1))]}"
  fi
done

init() {
  printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$session\",\"model\":\"fake\"}"
}
result() {
  printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"stop_reason\":\"end_turn\",\"session_id\":\"$session\",\"uuid\":\"r-$1\"$2}"
}

n=0
while IFS= read -r line; do
  case "$line" in
    *'"control_request"'*)
      id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
      printf '%s\n' "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\"}}"
      result "$n" ',"terminal_reason":"aborted_streaming"'
      ;;
    *'"type":"user"'*)
      n=$((n + 1))
      init
      text=$(printf '%s' "$line" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
      printf '%s\n' "{\"type\":\"assistant\",\"session_id\":\"$session\",\"message\":{\"id\":\"m-$n\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"you said: $text\"}]}}"
      case "$text" in
        *slow*) ;;
        *) result "$n" "" ;;
      esac
      ;;
  esac
done

#!/usr/bin/env bash
# A scripted stand-in for `codex exec --json [resume <thread>] -`.
#
# Reads its prompt from stdin the way the real one does, and answers with the
# events of one turn. The thread it reports is the one it was asked to resume,
# or a new one, so a session can be seen carrying it from run to run. A prompt
# containing "slow" holds the turn open, for interrupting; one containing
# "fail" ends it in turn.failed.

set -u
thread="t-new"
# The thread is the argument before the final "-", when "resume" was given.
args=("$@")
n=${#args[@]}
for ((i = 0; i < n; i++)); do
  if [ "${args[$i]}" = "resume" ]; then
    thread="${args[$((n - 2))]}"
  fi
done

prompt=$(cat)
# Codex's own log, on stderr, as the real one writes it on every run.
echo "2026-10-03T15:02:03Z ERROR codex_skills_extension::loader::host: failed to walk skills root" >&2
case "$prompt" in
  *refuse*)
    echo "2026-10-03T15:02:14Z ERROR codex_core::tools::router: error=Command blocked by PreToolUse hook: blocked by fieldguide: the doc zone is read-only: /docs/x.txt. Command: *** Begin Patch" >&2
    ;;
  *die*)
    echo "fatal: cannot load auth" >&2
    exit 3
    ;;
esac
printf '%s\n' "{\"type\":\"thread.started\",\"thread_id\":\"$thread\"}"
printf '%s\n' '{"type":"turn.started"}'
case "$prompt" in
  # exec, so a stop reaches the sleep itself and nothing holds stdout open.
  *slow*) exec sleep 30 ;;
esac
case "$prompt" in
  *fail*)
    printf '%s\n' '{"type":"error","message":"model overloaded"}'
    printf '%s\n' '{"type":"turn.failed","error":{"message":"model overloaded"}}'
    exit 1
    ;;
esac
text="heard: $prompt (thread $thread)"
printf '%s\n' "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"$text\"}}"
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'

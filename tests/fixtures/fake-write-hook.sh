#!/usr/bin/env bash
# Stands in for `node extension/mcp.ts --before-write|--after-write <path>`, so
# the opencode plugin's wiring can be tested without an editor to verify in.
#
#   $1 the script the real node would run (ignored)   $2 mode   $3 path
#
# Every call is appended to $FAKE_HOOK_LOG. A path containing "refuse-me" is
# refused the way mcp.ts refuses: exit 2, reason on stderr. "fail-after" makes
# --after-write fail outright, and "hang" never answers at all.

printf '%s %s\n' "$2" "$3" >>"${FAKE_HOOK_LOG:?}"
case "$3" in *hang*) exec sleep 30 ;; esac
case "$2" in
  --before-write)
    case "$3" in
      *refuse-me*)
        echo "outside fieldguide's zones: $3" >&2
        exit 2
        ;;
    esac
    ;;
  --after-write)
    case "$3" in
      *quiet*) ;;
      *fail-after*)
        echo "the checkpoint store is locked" >&2
        exit 1
        ;;
      *) echo "[fieldguide] boot OK, 12ms" ;;
    esac
    ;;
esac
exit 0

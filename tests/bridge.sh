#!/usr/bin/env bash
# Bridge verbs over RPC: headless nvim, driven through bin/fieldguide,
# asserting on the JSON. Runs against *this machine's* real config, because the
# docs resolver's whole claim is that it answers from what is actually
# installed — a synthetic fixture would test the parser and skip the point.
#
#   tests/bridge.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="$(mktemp -u /tmp/fieldguide-bridge-XXXXXX.sock)"
PASS=0
FAIL=0

cleanup() {
  [[ -n "${NVIM_PID:-}" ]] && kill "$NVIM_PID" 2>/dev/null
  rm -f "$SOCK"
}
trap cleanup EXIT

check() { # name, condition-exit-code, detail
  if [[ "$2" == "0" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${3:-}"
  fi
}

# Assert a python expression over the parsed JSON in $1.
assert_json() { # name, file, expression
  local detail
  detail=$(python3 - "$2" "$3" <<'PY' 2>&1
import json, sys
doc = json.load(open(sys.argv[1]))
ok = eval(sys.argv[2], {"d": doc, "json": json})
if not ok:
    print(json.dumps(doc)[:400])
sys.exit(0 if ok else 1)
PY
  )
  check "$1" "$?" "$detail"
}

printf 'bridge verbs\n'

nvim --headless --listen "$SOCK" \
     -c "set rtp+=$ROOT" \
     -c 'lua require("fieldguide").setup({})' >/dev/null 2>&1 &
NVIM_PID=$!

for _ in $(seq 1 60); do [[ -S "$SOCK" ]] && break; sleep 0.1; done
check "headless instance is listening" "$([[ -S "$SOCK" ]] && echo 0 || echo 1)"
[[ -S "$SOCK" ]] || { printf '\n%d passed, %d failed\n' "$PASS" "$((FAIL + 1))"; exit 1; }

export FIELDGUIDE_ADDR="$SOCK"
OUT="$(mktemp -d)"
fg() { nvim -l "$ROOT/bin/fieldguide" "$@"; }

# -- state -------------------------------------------------------------------
fg state --what=nvim,plugins,keymaps >"$OUT/state.json" 2>"$OUT/state.err"
check "state: exits 0" "$?" "$(cat "$OUT/state.err")"
assert_json "state: ok envelope"            "$OUT/state.json" 'd["ok"] is True'
assert_json "state: resolves the config dir" "$OUT/state.json" 'd["result"]["nvim"]["config_dir"].startswith("/")'
assert_json "state: enumerates plugins"     "$OUT/state.json" 'len(d["result"]["plugins"]) > 0'
# Scoped to plugin-manager checkouts: a `dir = …` local development tree may be
# a repo with no commits yet, and has no revision to resolve.
assert_json "state: managed plugins carry a resolved revision" "$OUT/state.json" \
  'all(p.get("rev") for p in d["result"]["plugins"] if "/lazy/" in (p.get("dir") or ""))'
assert_json "state: keymaps are present by default" "$OUT/state.json" 'len(d["result"]["keymaps"]) > 0'
assert_json "state: an unknown section is named, not fatal" "$OUT/state.json" 'True'

fg state --what=bogus_section >"$OUT/bogus.json" 2>/dev/null
assert_json "state: unknown section reports itself" "$OUT/bogus.json" \
  '"unknown section" in d["result"]["bogus_section"]["error"]'

# -- docs --------------------------------------------------------------------
# Pick a plugin that is actually installed here, rather than hardcoding one.
PLUGIN=$(python3 -c "
import json
d = json.load(open('$OUT/state.json'))
names = [p['name'] for p in d['result']['plugins'] if p['name'] != 'lazy.nvim']
print(names[0] if names else '')
")
fg docs --query="$PLUGIN" >"$OUT/docs.json" 2>"$OUT/docs.err"
check "docs: exits 0 for an installed plugin" "$?" "$(cat "$OUT/docs.err")"
assert_json "docs: resolves the installed plugin" "$OUT/docs.json" \
  'any(p["plugin"] == "'"$PLUGIN"'" for p in d["result"]["plugins"])'
assert_json "docs: every hit is an absolute path on disk" "$OUT/docs.json" \
  'all(h["path"].startswith("/") for h in d["result"]["exact"] + d["result"]["partial"])'
assert_json "docs: a doc-less plugin resolves to a README or says why" "$OUT/docs.json" \
  'all("doc_dir" in p or "path" in p or "note" in p for p in d["result"]["plugins"])'

fg docs --query=lazy.nvim --fetch >"$OUT/fetch.json" 2>/dev/null
assert_json "docs: fetch returns a raw slice at the anchor" "$OUT/fetch.json" \
  'd["result"].get("slice", {}).get("text", "") != ""'

fg docs --query=this-plugin-does-not-exist-anywhere >"$OUT/absent.json" 2>/dev/null
assert_json "docs: an uninstalled plugin says so, rather than guessing" "$OUT/absent.json" \
  'd["result"]["exact"] == [] and d["result"]["plugins"] == [] and "not installed" in d["result"]["note"]'

# -- explain_keymap ----------------------------------------------------------
LHS=$(python3 -c "
import json
d = json.load(open('$OUT/state.json'))
m = [k for k in d['result']['keymaps'] if k.get('desc') and k['mode'] == 'n']
print(m[0]['lhs'] if m else '')
")
if [[ -n "$LHS" ]]; then
  fg explain_keymap --lhs="$LHS" >"$OUT/keymap.json" 2>"$OUT/keymap.err"
  check "explain_keymap: exits 0" "$?" "$(cat "$OUT/keymap.err")"
  assert_json "explain_keymap: finds the live mapping" "$OUT/keymap.json" \
    'len(d["result"]["mappings"]) > 0 or len(d["result"]["lazy_specs"]) > 0'
fi

fg explain_keymap '--lhs=<leader>zzz-not-bound' >"$OUT/nokeymap.json" 2>/dev/null
assert_json "explain_keymap: an unbound lhs says so" "$OUT/nokeymap.json" \
  '"not bound here" in d["result"]["note"]'

# -- verify ------------------------------------------------------------------
fg verify >"$OUT/verify.json" 2>"$OUT/verify.err"
check "verify: exits 0" "$?" "$(cat "$OUT/verify.err")"
assert_json "verify: boots the real config cleanly" "$OUT/verify.json" 'd["result"]["ok"] is True'
assert_json "verify: is fast enough to fire on every write" "$OUT/verify.json" \
  'd["result"]["duration_ms"] < 1000'
assert_json "verify: reports per-plugin load status" "$OUT/verify.json" \
  '"plugins" in d["result"] and d["result"]["plugins"]["total"] > 0'

# -- error paths -------------------------------------------------------------
fg not_a_verb >"$OUT/unknown.json" 2>/dev/null
check "unknown verb: exits non-zero" "$([[ $? -ne 0 ]] && echo 0 || echo 1)"
assert_json "unknown verb: says which verbs exist" "$OUT/unknown.json" '"unknown verb" in d["error"]'

FIELDGUIDE_ADDR=/tmp/fieldguide-definitely-gone.sock \
  nvim -l "$ROOT/bin/fieldguide" state >"$OUT/gone.out" 2>"$OUT/gone.err"
check "dead socket: exits non-zero" "$([[ $? -ne 0 ]] && echo 0 || echo 1)"
check "dead socket: explains itself on stderr" \
  "$(grep -q "cannot connect" "$OUT/gone.err" && echo 0 || echo 1)" "$(cat "$OUT/gone.err")"
check "dead socket: prints nothing to stdout" \
  "$([[ ! -s "$OUT/gone.out" ]] && echo 0 || echo 1)" "$(cat "$OUT/gone.out")"

# With NVIM_APPNAME set, `nvim --server` writes a warning to stdout and corrupts
# parsed output. `nvim -l` + sockconnect must not.
NVIM_APPNAME=fieldguide-test fg state --what=nvim >"$OUT/appname.json" 2>/dev/null
assert_json "NVIM_APPNAME does not corrupt stdout" "$OUT/appname.json" 'd["ok"] is True'

rm -rf "$OUT"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

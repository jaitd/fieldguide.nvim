#!/usr/bin/env bash
# What this machine can and cannot run. Every dependency here is checked at
# launch too — this just reports them all at once instead of one failure at a
# time.
#
#   mise run doctor

set -uo pipefail
MISSING=0
# This checkout's fieldguide, in an editor without the user's config: the zones
# come from stdpath(), not from anything the config does.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

row() { # label, found, note
  if [[ -n "$2" ]]; then
    printf '  \033[32m✓\033[0m %-8s %s\n' "$1" "$2"
  else
    printf '  \033[31m✗\033[0m %-8s %s\n' "$1" "$3"
    MISSING=1
  fi
}

printf '\nfieldguide requirements\n'

row nvim  "$(nvim --version 2>/dev/null | head -1)" "not on PATH — 0.12+ required"
row node  "$(node --version 2>/dev/null)"           "not on PATH — 24+ required by the extension and the hooks"
row git   "$(git --version 2>/dev/null)"            "not on PATH — the shadow repo needs it"
# The sandbox verify boots in, which is not the same program on every OS.
if [[ "$(uname -s)" == "Darwin" ]]; then
  row sandbox "$(command -v sandbox-exec >/dev/null 2>&1 && echo 'seatbelt (sandbox-exec)')" \
    "sandbox-exec missing — verify refuses to boot unsandboxed"
else
  row sandbox "$(bwrap --version 2>/dev/null)" \
    "bwrap not on PATH — verify refuses to boot unsandboxed"
fi

printf '\nresolved zones\n'
nvim --headless --clean --cmd "set rtp^=$ROOT" -c 'lua
  local ok, cfg = pcall(require, "fieldguide.config")
  if not ok then
    io.write("  ! fieldguide is not on this instance'"'"'s runtimepath\n")
    return
  end
  cfg.setup({})
  local p = cfg.paths()
  io.write(("  config (rw)  %s\n"):format(p.config_dir))
  if p.config_dir ~= p.config_dir_declared then
    io.write(("               via symlink from %s\n"):format(p.config_dir_declared))
  end
  for _, root in ipairs(p.doc_roots) do
    io.write(("  docs   (ro)  %s\n"):format(root))
  end
  io.write(("  shadow       %s/repos/\n"):format(p.state_dir))
' -c 'qa' 2>&1

printf '\nagents (any one will do; :FieldguideSetup picks)\n'
# The checks the setup wizard runs, which are the ones each launch runs.
if ! nvim --headless --clean --cmd "set rtp^=$ROOT" -c 'lua
  local ok = pcall(require, "fieldguide.onboarding")
  if not ok then
    io.write("  ! fieldguide is not on this instance'"'"'s runtimepath\n")
    vim.cmd("cquit 1")
  end
  require("fieldguide.config").setup({})
  local launch = require("fieldguide.launch")
  local any = false
  for _, row in ipairs(require("fieldguide.onboarding").check()) do
    any = any or row.ready
    local mark = row.ready and "\27[32m✓\27[0m" or "\27[31m✗\27[0m"
    io.write(("  %s %-8s %s\n"):format(mark, row.name, row.ready and "ready" or row.why))
  end
  local c = launch.current()
  io.write(("  chosen: %s\n"):format(launch.chosen() and c.name .. (c.model and (" with " .. c.model) or "") or "none yet"))
  if not any then
    vim.cmd("cquit 1")
  end
' -c 'qa' 2>&1; then
  MISSING=1
fi

if command -v pi >/dev/null 2>&1; then
  # `pi --list-models` exits 0 either way, so the exit code says nothing.
  if pi --list-models 2>&1 | grep -q "No models available"; then
    printf '  \033[33m!\033[0m pi has no provider — run `pi` and use /login, or export OPENROUTER_API_KEY\n'
  fi
fi

printf '\n'
exit "$MISSING"

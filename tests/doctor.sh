#!/usr/bin/env bash
# What this machine can and cannot run. Every dependency here is checked at
# launch too — this just reports them all at once instead of one failure at a
# time.
#
#   mise run doctor

set -uo pipefail
MISSING=0
# This checkout's fieldguide, with the options the user's config gives it.
export FIELDGUIDE_DOCTOR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Named through the environment, not on the command line, where a path with a
# space in it would be split.
NVIM_DOCTOR=(nvim --headless -c 'lua dofile(vim.env.FIELDGUIDE_DOCTOR_ROOT .. "/tests/doctor-env.lua")')

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
"${NVIM_DOCTOR[@]}" -c 'lua
  local p = require("fieldguide.config").paths()
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
if ! "${NVIM_DOCTOR[@]}" -c 'lua
  local launch = require("fieldguide.launch")
  local any = false
  for _, row in ipairs(require("fieldguide.onboarding").check()) do
    any = any or row.ready
    local mark = row.ready and "\27[32m✓\27[0m" or "\27[31m✗\27[0m"
    local why = vim.split(row.why or "", "\n", { plain = true })[1]
    io.write(("  %s %-8s %s\n"):format(mark, row.name, row.ready and "ready" or why))
    if row.name == "pi" and row.ready and #require("fieldguide.harness.pi").models() == 0 then
      io.write("    \27[33m!\27[0m but it lists no models: run it and use /login, or export a provider key\n")
    end
  end
  local c = launch.current()
  io.write(("  chosen: %s\n"):format(launch.chosen() and c.name .. (c.model and (" with " .. c.model) or "") or "none yet"))
  if not any then
    vim.cmd("cquit 1")
  end
' -c 'qa' 2>&1; then
  MISSING=1
fi

printf '\n'
exit "$MISSING"

#!/usr/bin/env bash
# What this machine can and cannot run. Every dependency here is checked at
# launch too — this just reports them all at once instead of one failure at a
# time.
#
#   mise run doctor

set -uo pipefail
MISSING=0

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
row node  "$(node --version 2>/dev/null)"           "not on PATH — 22+ required by the pi extension"
row git   "$(git --version 2>/dev/null)"            "not on PATH — the shadow repo needs it"
# The sandbox verify boots in, which is not the same program on every OS.
if [[ "$(uname -s)" == "Darwin" ]]; then
  row sandbox "$(command -v sandbox-exec >/dev/null 2>&1 && echo 'seatbelt (sandbox-exec)')" \
    "sandbox-exec missing — verify refuses to boot unsandboxed"
else
  row sandbox "$(bwrap --version 2>/dev/null)" \
    "bwrap not on PATH — verify refuses to boot unsandboxed"
fi
row pi    "$(pi --version 2>/dev/null)"             "not on PATH — pnpm add -g @earendil-works/pi-coding-agent"

printf '\nresolved zones\n'
nvim --headless -c 'lua
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

printf '\nprovider\n'
# `pi --list-models` exits 0 either way, so the exit code says nothing.
if pi --list-models 2>&1 | grep -qv "No models available" && \
   ! pi --list-models 2>&1 | grep -q "No models available"; then
  printf '  \033[32m✓\033[0m pi has a provider configured\n'
else
  printf '  \033[33m!\033[0m no pi provider — run `pi` and use /login, or export OPENROUTER_API_KEY\n'
  printf '    (steps 1-4 of the build order work with no agent at all)\n'
fi

printf '\n'
exit "$MISSING"

#!/usr/bin/env bash
# Record the demo as an asciinema cast, driven by demo/script.txt.
#
#   mise run demo
#   mise run demo -- --gif        # also render demo/fieldguide.gif (needs agg)
#
# Scripted rather than performed, so the demo can be made again after a UI
# change instead of re-enacted. The keystrokes go in over Neovim's own RPC
# socket — the same way tests/bridge.sh drives a headless instance — while
# asciinema records the terminal the editor is drawing in.
#
# The recording runs against demo/config, never your own: XDG_CONFIG_HOME and
# the data, state and cache directories all point inside a throwaway profile in
# your temp directory. No path of yours reaches the screen, including in the
# answers, which quote the files they came from.
#
# It does talk to a model, through whichever provider pi is logged in to
# (FIELDGUIDE_DEMO_PROVIDER and FIELDGUIDE_DEMO_MODEL override it), so the
# words differ between takes. The script is repeatable; the answers are not.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# Outside the checkout and outside $HOME: the agent quotes paths in its answers
# — the file a keymap came from, the config it read — and those go on screen.
# From here they read /tmp/fieldguide-demo/..., which says nothing about whose
# machine recorded the take.
# /var/tmp, not /tmp: verify's sandbox mounts a tmpfs over /tmp, so a profile
# there takes the demo's plugins away from the boot it is checking, and the
# take ends on a failed verify. /var/tmp is as anonymous and survives.
PROFILE="${FIELDGUIDE_DEMO_PROFILE:-/var/tmp/fieldguide-demo}"
CAST="$HERE/fieldguide.cast"
SOCK="$(mktemp -u /tmp/fieldguide-demo-XXXXXX.sock)"
GIF=

[ "${1:-}" = "--gif" ] && GIF=1

for tool in nvim asciinema git node; do
  command -v "$tool" >/dev/null || { echo "$tool is not on PATH" >&2; exit 1; }
done
[ -n "$GIF" ] && ! command -v agg >/dev/null &&
  { echo "agg is not on PATH: cargo install --git https://github.com/asciinema/agg" >&2; exit 1; }

export XDG_CONFIG_HOME="$PROFILE/config"
export XDG_DATA_HOME="$PROFILE/data"
export XDG_STATE_HOME="$PROFILE/state"
export XDG_CACHE_HOME="$PROFILE/cache"
# Unset by default: the demo installs the plugin from GitHub, so the take shows
# what a user gets and the agent can read the plugin's docs in its own zone.
if [ "${FIELDGUIDE_DEMO_LOCAL:-}" = "1" ]; then export FIELDGUIDE_DEMO_REPO="$REPO"; fi

mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
# Copied in, not symlinked: the config tree is the agent's read/write zone, and
# a symlink would make that zone this checkout's tracked files. Copying leaves
# the throwaway profile as the only thing it can reach.
rm -rf "$XDG_CONFIG_HOME/nvim"
cp -R "$HERE/config" "$XDG_CONFIG_HOME/nvim"

# A repository, because the take ends by toggling gitsigns' line blame, and
# gitsigns attaches to nothing else. Committed under a name that is not yours:
# blame text goes on screen.
if [ ! -d "$XDG_CONFIG_HOME/nvim/.git" ]; then
  git -C "$XDG_CONFIG_HOME/nvim" init -q
  git -C "$XDG_CONFIG_HOME/nvim" add -A
  git -C "$XDG_CONFIG_HOME/nvim" \
    -c user.name="fieldguide demo" -c user.email="demo@example.com" \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q -m "the demo config"
fi

# Plugins first, off camera: a take that opens on lazy.nvim cloning
# repositories is a take about lazy.nvim. `restore` rather than `install`, so
# every take runs the revisions in demo/config/lazy-lock.json: a plugin that
# released between two takes must not change what the answers say.
echo "installing the demo config's plugins..."
nvim --headless "+Lazy! restore" +qa

# The index the third question is answered from. It is released separately from
# the plugin, so a fresh profile has none until it is fetched.
if [ ! -f "$XDG_STATE_HOME/nvim/fieldguide/nvim-plugins.db" ]; then
  echo "fetching the plugin index..."
  node "$REPO/extension/index-fetch.ts" "$XDG_STATE_HOME/nvim/fieldguide/nvim-plugins.db" ||
    echo "warning: no plugin index — the third question will say so" >&2
fi

# The driver: it waits for the editor to be listening, then plays the script
# into it. Runs beside the recording rather than inside it, so none of this
# shows up in the cast.
drive() {
  # Its own log: anything the driver prints during a take would be printed
  # into the take.
  exec >>"$PROFILE/driver.log" 2>&1
  for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.2; done
  [ -S "$SOCK" ] || { echo "the editor never opened its socket" >&2; return 1; }
  sleep 1

  while IFS= read -r line; do
    case "$line" in
      ""|"#"*) continue ;;
      "wait "*) sleep "${line#wait }" ;;
      "send "*) nvim --server "$SOCK" --remote-send "${line#send }" ;;
      *) echo "demo/script.txt: cannot read '$line'" >&2; return 1 ;;
    esac
  done < "$HERE/script.txt"

  # Quit the editor, which is what ends the recording. The <CR> first: a
  # command that printed something leaves a hit-enter prompt, and everything
  # sent after it is eaten by that prompt rather than run.
  nvim --server "$SOCK" --remote-send '<CR><C-\><C-n>:qa!<CR>' || true

  # And if it is still up ten seconds later, end it anyway: a take that never
  # stops is worse than one that ends abruptly, and a stuck editor would sit
  # there recording until someone noticed.
  for _ in $(seq 50); do [ -S "$SOCK" ] || return 0; sleep 0.2; done
  # By pid, and only the editor: the recorder's own command line carries the
  # same socket path, so a pattern kill takes the recording down with it.
  for pid in $(pgrep -f -- "--listen $SOCK"); do
    [ "$(ps -p "$pid" -o comm=)" = "nvim" ] && kill "$pid"
  done
  return 0
}

rm -f "$CAST"
drive &
DRIVER=$!
trap 'kill "$DRIVER" 2>/dev/null || true; rm -f "$SOCK"' EXIT

# --idle-time-limit caps the wait on a model at two seconds of playback, which
# is what keeps a three-minute take watchable.
asciinema rec "$CAST" \
  --idle-time-limit 2 \
  --cols 120 --rows 32 \
  --title "fieldguide.nvim" \
  --command "nvim --listen $SOCK '+e $XDG_CONFIG_HOME/nvim/init.lua'"

wait "$DRIVER" || true

# Trim the quit off the end. The driver ends the take by typing `:qa!`, and
# whatever is last in the cast is what a looping gif rests on — the editor
# tearing down rather than the answer worth reading.
node -e '
  const fs = require("node:fs");
  const path = process.argv[1];
  const lines = fs.readFileSync(path, "utf8").split("\n").filter(Boolean);
  const cut = lines.findIndex((l, i) => i > 0 && /qa!/.test(JSON.parse(l)[2]));
  if (cut > 0) fs.writeFileSync(path, lines.slice(0, cut).join("\n") + "\n");
' "$CAST"

echo "wrote $CAST"
echo "  play:   asciinema play $CAST"
echo "  share:  asciinema upload $CAST"

if [ -n "$GIF" ]; then
  # --last-frame-duration: a gif loops, and without a pause on the end the
  # last answer is gone before it can be read. Long enough to take in what is
  # on screen, short enough not to look like the recording has hung.
  agg --font-size 20 --theme asciinema --last-frame-duration 8 "$CAST" "$HERE/fieldguide.gif"
  echo "wrote $HERE/fieldguide.gif"
fi

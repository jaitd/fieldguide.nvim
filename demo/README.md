# The demo recording

```
mise run demo              # records demo/fieldguide.cast
mise run demo -- --gif     # ...and renders demo/fieldguide.gif (needs agg)
```

Scripted rather than performed, so it can be made again after a UI change
instead of re-enacted. `record.sh` starts Neovim under `asciinema` and plays
`script.txt` into it over Neovim's own RPC socket — the same way
`tests/bridge.sh` drives a headless instance.

| File | |
|---|---|
| `script.txt` | what the recording does: `send <keys>`, `wait <seconds>` |
| `config/` | the Neovim config the recording answers from |
| `config/lazy-lock.json` | its plugins, pinned, so takes stay comparable |
| `record.sh` | the recorder |
| `/tmp/fieldguide-demo/` | the throwaway Neovim profile the take runs in |

## It does not record your config

`XDG_CONFIG_HOME` and the data, state and cache directories all point inside
`/tmp/fieldguide-demo`, and `config/` is copied there rather than symlinked, so
the agent's read/write zone is the throwaway copy and not this checkout.

The profile lives outside `$HOME` because the answers quote paths — the file a
keymap came from, the config that was read — so a profile under your home would
put your home on screen. From a temp directory those lines read
`/tmp/fieldguide-demo/config/nvim/init.lua`, which says nothing about whose
machine recorded the take. `FIELDGUIDE_DEMO_PROFILE` moves it. Worth checking the cast before publishing anyway:
`asciinema play demo/fieldguide.cast`, and it is JSON, so `grep` works on it.

## It does not record the same words twice

The answers come from a model, through whichever provider `pi` is logged in to
(`FIELDGUIDE_DEMO_PROVIDER` and `FIELDGUIDE_DEMO_MODEL` override it). The script
is repeatable; the replies are not. The waits in `script.txt` are wall-clock
waits on that model, so they are generous, and `--idle-time-limit` caps the dead
air in playback — a wait that is too long costs a second of playback, one that
is too short costs the take.

If a take catches a reply mid-stream, raise the `wait` after that question.

## Sharing it

A cast plays in a terminal (`asciinema play`) or from asciinema.org
(`asciinema upload`, which is public). GitHub strips JavaScript, so a README
cannot embed the player: render a GIF instead, with
[agg](https://github.com/asciinema/agg).

VHS is the obvious alternative and was tried first. It drives a headless Chrome
through `ttyd`, and on a machine whose Chromium is a confined snap it produced
no output and reported success, which is a bad failure to debug mid-demo. The
RPC driver here needs nothing but Neovim.

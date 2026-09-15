# Design notes

Details that do not fit in the README: what `verify` does and does not
guarantee, how the two sandboxes differ, and how the panel behaves.

## What `verify` does not catch

`verify` boots your config and quits. Anything deferred past startup never runs
under it: autocmd callbacks, keymap right-hand sides, `on_attach`, `defer_fn`
and plugin `config` functions. A payload in any of those still returns "boot
ok". [`tests/fixtures/deferred-payload/`](../tests/fixtures/deferred-payload/)
is such a config, and the suite asserts that `verify` reports it clean.

`verify` is a correctness check, not a security control. The risk to plan for
is prompt injection through the plugin docs the agent reads: it reads a large
amount of third-party help text unattended, and nothing stands between that
reading and `reload`.

What does hold is the path gate on the three zones, the fixed set of tools, the
sandbox around `verify`, and the shadow repo.

## The two sandboxes

`verify` will not boot unsandboxed, and which sandbox it gets depends on the OS.
`verify.sandbox` is `"auto"`: bwrap on Linux, seatbelt (`sandbox-exec`, which
ships with macOS) on macOS. Pin one with `verify = { sandbox = "bwrap" }` or
`"seatbelt"`; there is no `"none"`.

They are built differently:

| | bwrap | seatbelt |
|---|---|---|
| built | a namespace, from nothing up | the whole machine, with things taken away |
| config tree | bound in read-only | symlinked in, all writes denied |
| `$HOME` | a tmpfs — secrets are *absent* | reads denied — secrets are `EPERM` |
| state, cache, `/tmp` | tmpfs | XDG-pointed at a scratch box, deleted after |
| network | `--unshare-net` | `(deny network*)`, unix sockets kept |
| processes | `--unshare-pid`, `--new-session` | no equivalent |

Under both, the config tree cannot be written, the boot cannot reach the
network, and everything it writes is thrown away. Process isolation is Linux
only: on macOS the booted config shares a PID namespace and a session with your
editor.

A stow-style config, where `~/.config/nvim` is a real directory full of links
into a dotfiles repo, is read through those links: the directories they point
at are added to the sandbox's read list one level of indirection at a time, and
`$HOME` itself is never added back.

## No `package.json`

There is no `npm install`. The extension's only runtime import is `typebox`,
which pi resolves from its own installation, so the plugin directory never
contains a `node_modules/`.

## The panel stays at the edge

A split made with the cursor in the panel lands in the editor area instead, and
the panel rebuilds itself at the edge. A horizontal split made from inside the
panel opens as a vertical one.

The panel keeps its width. If `<C-w>|` or a similar command squeezes it, it
restores its width afterwards. A width you set yourself, by dragging or with
`<C-w><`, is remembered and restored instead of the configured one.

## Past sessions

`<C-o>` in either half of the panel, or `:FieldguideHistory` from anywhere,
lists what you have asked before, newest first, titled by your opening
question. `keys = { history = "<leader>fh" }` binds it globally, alongside
`toggle`, `focus` and `reload`; `panel_keys = { history = … }` moves it inside
the panel.

Picking a session replays it and resumes the agent's context, so the next
question continues that conversation.

Sessions are stored in `stdpath("state")/fieldguide/sessions`, separately from
pi's own sessions, so neither shows up in the other's history. Set
`chat = { session_dir = … }` to move them.

A replayed session renders exactly as it did live: tool calls fold, jump and
highlight the same way.

## Reading the transcript

`j` and `k` move through the transcript by answer. While more of the current
answer is below the window they scroll it; once its end is visible, the same
key moves to the start of the next one. The arrow keys, `gj`/`gk` and
`<C-e>`/`<C-y>` keep their usual line-by-line behaviour.

The view only scrolls when it has to. Moving to an answer that is already fully
visible moves the cursor without scrolling; an answer that runs off the bottom
is brought to the top. `scrolloff` is `0` inside the panel.

The answer under the cursor is marked with a bar in the sign column,
highlighted with `FieldguideCurrent`. The sign column is always reserved, so
text does not shift when the bar moves; `chat = { mark_current = false }`
removes the bar and gives back those two columns.

`<F5>` puts the Ex command under the cursor on the command line, and stops
there: you read it and press Enter. Lines with a command are marked `▶`. A
command is either a line in a ```` ```vim ```` fence or a code span that starts
with a colon, such as `` `:Telescope live_grep` ``.

**`<F5>` never runs the command.** Transcript text can come from third-party
docs the agent has read. Control characters are stripped when the command is
loaded, so a carriage return in the text cannot submit it.

## Tool calls in the transcript

Tool calls are indented four spaces, so markdown renderers such as
render-markdown treat them as code and leave paths intact.

Each opens with a glyph — `▪` ran, `✓` passed, `✗` failed — and is dimmed to
the comment colour, so the agent's answer stands out. Five highlight groups,
all linked with `default` so a colourscheme can override them:

| | |
|---|---|
| `FieldguideTool` | the summary text of a tool call |
| `FieldguideToolDetail` | its expanded body |
| `FieldguideToolIcon` | the leading glyph |
| `FieldguideToolOk` / `FieldguideToolError` | the glyph when a call passed or failed |

Your own turns are labelled with your login name, highlighted with
`FieldguideUser`. Set `chat = { user_name = "…" }` to use a different name.

An `edit` collapses its diff behind a summary line counted as `+2 −1`, with
added and removed lines in `FieldguideDiffAdd` and `FieldguideDiffDelete`
(linked to `Added` and `Removed`). `gf` on that line opens the file at the
first change.

The transcript's winbar shows the panel's name and the model answering. The row
above the prompt is empty until the agent is working, then shows a spinner and
how long it has been working. An empty prompt shows placeholder text naming its
two main bindings. These use `FieldguideTitle`, `FieldguideSession` and
`FieldguidePlaceholder`.

## The CLI

Every tool is also a command, run against a Neovim listening on a socket:

```
FIELDGUIDE_ADDR=/run/nvim.sock nvim -l bin/fieldguide docs --query=fugitive --fetch
```

## Testing the other sandbox

`verify` has a sandbox per OS, so a single machine can only exercise one of
them. `mise run test:linux` builds the image in
[`tests/docker/`](../tests/docker/) — Neovim from the release tarball,
bubblewrap, mise, and a small config with plugins at pinned revisions for the
bridge tests — mounts the repo read-only, and runs the same task list against
bwrap. Docker Desktop or OrbStack is enough.

```
mise run test:linux                         # the whole task list
mise run test:linux -- mise run test:verify # one task
mise run test:linux -- bash                 # a shell in there
```

The container runs with `seccomp=unconfined`, `SYS_ADMIN` and `NET_ADMIN`, which
bwrap needs to build its sandbox inside a container; this is less than
`--privileged`, and the sandbox under test is the one that ships.
`tests/docker/run.sh` documents each flag.

`pi` is not installed in the image, so `test:extension` skips itself there and
says so. If a rebuild fails with apt reporting Debian release files as "not
valid yet", the VM's clock is behind the host's, which happens after a Mac
sleeps; `run.sh` detects the skew and reports it.

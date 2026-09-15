# Design notes

The reasoning behind fieldguide's choices, moved out of the README so that
the README can be read in one sitting. Section numbers (§) refer to the
original design document, which is not part of this repository.

## Why `verify` is not a security control

`verify` is not the gate. It boots and quits, so autocmd callbacks, keymap RHS,
`on_attach`, `defer_fn` and plugin `config` functions never run — a payload in
any of those returns "boot ok". There is a fixture in
[`tests/fixtures/deferred-payload/`](../tests/fixtures/deferred-payload/) and a test
asserting that `verify` reports it clean, kept as a regression test on the
*documentation* so nobody later mistakes `verify` for a security control.

The real threat is not the agent turning evil. It is prompt injection through the
doc zone: the agent autonomously reads tens of thousands of lines of third-party
help text, and there is no human between that read and `reload`.

What does hold: the three-zone path gate, the closed verb table, a sandbox on
`verify`, and the shadow repo. See §6 of the design for the full table.

## The two sandboxes

`verify` will not boot unsandboxed, and which sandbox it gets depends on the OS.
`verify.sandbox` is `"auto"`: bwrap on Linux, seatbelt (`sandbox-exec`, which
ships with macOS) on macOS. Pin one with `verify = { sandbox = "bwrap" }` or
`"seatbelt"`; there is no `"none"`.

They are not the same sandbox, and the difference is worth knowing before you
read a clean `verify` as more than it is:

| | bwrap | seatbelt |
|---|---|---|
| built | a namespace, from nothing up | the whole machine, with things taken away |
| config tree | bound in read-only | symlinked in, all writes denied |
| `$HOME` | a tmpfs — secrets are *absent* | reads denied — secrets are `EPERM` |
| state, cache, `/tmp` | tmpfs | XDG-pointed at a scratch box, deleted after |
| network | `--unshare-net` | `(deny network*)`, unix sockets kept |
| processes | `--unshare-pid`, `--new-session` | no equivalent |

The three properties `verify` leans on hold under both: the config tree cannot
be written, the boot cannot reach the network, and everything it writes lands
somewhere that is thrown away. Process isolation is the one that does not
survive the crossing — on macOS the booted config shares a PID namespace and a
session with your editor. `verify` was never a security control (§6); on macOS
it is a little less of one.

A stow-style config — `~/.config/nvim` a real directory full of links into a
dotfiles repo — is read through those links deliberately: the directories they
point at are added to the sandbox's read list, one level of indirection at a
time, and `$HOME` itself is never added back.

## Why there is no `package.json`

There is **no `npm install`**. The extension's only runtime import is `typebox`,
which pi resolves from its own installation — a `package.json` here would mean a
`node_modules/` inside a directory a plugin manager also `git checkout`s (§5.2).

## Keeping the panel at the edge

The sidebar holds its edge. Vim has no notion of an edge window, so a `:vsplit`
with the cursor in the transcript splits *the transcript* — the prompt ends up
stranded in the middle of the screen and the editor sharing a column with the
panel. Rather than forbid the split, the panel checks its own layout whenever a
window opens or closes and rebuilds itself at the edge when it has been
displaced. The split still happens; it lands in the editor area, which is where
you meant it. A horizontal split made from inside the panel comes back as a
vertical one, because by the time the panel is out of the way there is no row
left to stack it in.

`winfixwidth` keeps the panel its own width the rest of the time, but it is also
what makes `<C-w>|` unrecoverable: maximising a window squeezes every other one
down to `winminwidth` regardless, and the equalise you would reach for next
skips fixed-width windows — leaving the panel one column wide with nothing able
to widen it. So the panel takes its width back itself. A width you *chose*, by
dragging or `<C-w><`, is remembered and restored instead of the configured one.

## Past sessions

`<C-o>` in either half of the panel, or `:FieldguideHistory` from anywhere,
lists what you have asked before, newest first, titled by the question you opened
with. `keys = { history = "<leader>fh" }` binds it globally, alongside `toggle`,
`focus` and `reload`; `panel_keys = { history = … }` moves it inside the panel. Picking one
replays it and hands the agent back its *context*, not a transcript of it — pi
persists every session and takes `--session <id>`, so the next thing you ask
lands in the conversation you are looking at rather than beside it.

Sessions live in `stdpath("state")/fieldguide/sessions`, ours rather than pi's
own default, so a field guide session stays out of the history of whatever else
you use pi for and that history stays out of this picker. Set
`chat = { session_dir = … }` to move them.

The replay goes through the same renderer as the live stream, so a tool call
read back off disk folds, jumps and paints exactly as the original did — it is
the same code path. The log stores whole messages where the stream delivers
deltas, and that difference stops inside `chat/history.lua`.

## Reading the transcript

The transcript is a page you read, not a file you edit, so `j` and `k` advance
through an *answer* rather than through a line: while there is more of the one
you are on below the fold they scroll it, and once its end is on screen the same
key lands on the top of the next. An answer taller than the window is the case a
plain jump-to-next-message would skip straight past. Nothing is taken away —
the arrow keys, `gj`/`gk` and `<C-e>`/`<C-y>` are ordinary motion, for when you
want to yank one line out of a code block.

The page moves only when it has to. Landing on a reply that is already whole on
screen moves the cursor and leaves the text alone; only a turn that runs off the
bottom is brought up to the top. `scrolloff` is set to `0` inside the panel to
make that hold — it is enforced at redraw and overrides a topline set from Lua,
so with a normal `scrolloff` a reply you could already see still slid a couple of
lines every time you pressed `j`.

The message you are on is bracketed by a bar down the sign column — a bar rather
than a tint across the message, because a turn can be a hundred lines and
colouring all of them makes the thing you are reading the loudest thing on the
screen instead of the clearest. The column is permanently reserved, not `auto`,
so the transcript cannot jump sideways when the bar appears; that costs two
columns of the panel's width, and `chat = { mark_current = false }` buys them
back. The bar is `FieldguideCurrent`.

`<F5>` puts the Ex command under the cursor on the command line, and stops
there. You read it and press Enter. It is marked with a `▶` so you can see which
lines have one: either a line in a ```` ```vim ```` fence, or a code span that
starts with a colon, which is what a model writes most of the time — `` `:Telescope
live_grep` `` is unambiguous where a bare `` `<Space><Space>` `` is a key, a path or
a plugin name.

**It loads the command, it does not run it.** The agent reads tens of thousands
of lines of third-party help text on its own and with nobody watching, and a key
that executed whatever came back would leave nothing between that and this
editor — a bigger surface than `reload`, which at least only re-requires your
own config modules. What is worth automating is the retyping, not the deciding.
Control bytes are stripped when the command is read, because a carriage return
anywhere in the text would end the command line for us, and that is the one way
this key could execute something after all.

## Rendering tool calls

Tool calls are not markdown, and are indented four spaces so that the parser
agrees: consecutive tool lines are otherwise a single paragraph, and the `~` in
one path pairs with the `~` in the next to strike through everything between
them. Four spaces makes the run an indented code block, which has no inline
parsing at all and which render-markdown leaves alone.

They open with a glyph — `▪` ran, `✓` passed, `✗` failed — and are dimmed to the
colour of a comment, which leaves the agent's own answer as the only thing on the
page in the foreground colour. A markdown list marker would have put them in the
same visual bucket as the bullet lists the agent writes itself. Five groups, all
linked with `default` so a colourscheme can claim them:

| | |
|---|---|
| `FieldguideTool` | the summary text of a tool call |
| `FieldguideToolDetail` | its expanded body |
| `FieldguideToolIcon` | the leading glyph |
| `FieldguideToolOk` / `FieldguideToolError` | the glyph when a call passed or failed |

Your own turns are attributed by name, taken from the passwd entry — `whoami`
without a subprocess — and painted with `FieldguideUser`. Set
`chat = { user_name = "…" }` to be called something else.

An `edit` collapses pi's own diff behind it, counted in the summary as `+2 −1`,
with added and removed lines in `FieldguideDiffAdd` / `FieldguideDiffDelete` —
`Added` and `Removed`, not `DiffAdd`, which is a background fill meant for a diff
window. `gf` on that line opens the file at the first change.

The transcript's winbar names the panel and the model answering, and is the only
place the name appears; the row above the prompt is blank unless the agent is
doing something, and carries a spinner and how long it has been doing it when it
is — "thinking" and "thinking, still, ninety seconds in" are different situations
and the word alone cannot tell them apart. That row is there even when it is
blank: a winbar set to the empty string is not drawn at all, so a status that
came and went took a row of the prompt with it every time. An empty
prompt shows what it is for and names the two bindings that are not guessable.
These use `FieldguideTitle`, `FieldguideSession` and `FieldguidePlaceholder`.

## Why the CLI exists

The verbs are also a plain CLI, which is the seam that makes the harness an
adapter rather than the architecture (§5.4):

```
FIELDGUIDE_ADDR=/run/nvim.sock nvim -l bin/fieldguide docs --query=fugitive --fetch
```

## Testing the other sandbox

`verify` has two sandbox backends and a machine has one kernel, so half of it is
unreachable from wherever you are sitting. `mise run test:linux` builds the
image in [`docker/`](../docker/) — Neovim from the release tarball, bubblewrap,
mise, and a small real config with plugins at real revisions for the bridge
tests to answer from — mounts the repo read-only, and runs the same task list
against bwrap. Docker Desktop or OrbStack is enough; there is no separate VM to
keep.

```
mise run test:linux                        # the whole task list
mise run test:linux -- mise run test:verify # one task
mise run test:linux -- bash                 # a shell in there
```

The container needs `seccomp=unconfined`, `SYS_ADMIN` and `NET_ADMIN` for bwrap
to build the sandbox it builds outside one — less than `--privileged`, and
enough that what runs under test is the sandbox that ships rather than a
weakened stand-in. `docker/run.sh` says which flag buys what.

`pi` is not installed in the image, so `test:extension` skips itself there and
says so. A Mac that has slept comes back with the VM's clock behind the host's,
which surfaces as apt refusing every Debian release file as "not valid yet"
during a rebuild; `run.sh` measures the skew and names it, because nothing else
about that error suggests a clock.

## Build order

Steps 1–4 are useful with no agent at all, and step 4 is the part nothing else
does. See §9 of the design.

- [x] 1. `api.lua` with `state`, plus `bin/fieldguide`
- [x] 2. `verify`: the sandbox profiles, the structured payload, the escape alarm
- [x] 3. the three-zone path gate and its test table
- [x] 4. `docs` resolver, `explain_keymap` composed on top
- [x] 5. pi extension: verbs as tools, `tool_result` hook, `--tools` allowlist
- [x] 6. shadow repo, `reload`, levels, `:FieldguideReload` / `:FieldguideUndo`
- [x] 7. sidebar

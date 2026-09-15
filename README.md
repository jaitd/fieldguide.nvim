# fieldguide.nvim

A field guide to *your* Neovim.

An agent in a sidebar that answers questions about the Neovim config you
actually run: the plugins you have installed, at the versions you have pinned,
joined against the live session those files produced. Ask it why a keymap does
what it does, what a plugin's option means, or to make a change and check that
your config still boots.

A general coding agent can grep your config. It cannot enumerate your installed
plugins and read only those docs, at only those versions. That join is the
point.

It does not interrupt you, review your diffs, or help with code outside your
Neovim config. [sidekick.nvim](https://github.com/folke/sidekick.nvim) and
[claudecode.nvim](https://github.com/coder/claudecode.nvim) cover that.

> **Status:** early. Everything described here works and is tested, but expect
> rough edges. The agent runs on top of [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
> from your `PATH`.

## What it can do

| Tool | What it answers from |
|---|---|
| `docs` | the help files of the plugins you have installed, at the revision on disk |
| `explain_keymap` | a mapping, where it was defined, which plugin owns it, and that plugin's docs |
| `state` | the live session: buffers, diagnostics, plugins and their revisions, keymaps, windows, LSP |
| `verify` | a sandboxed headless boot of your config: errors, messages, load status, timing |
| `reload` | re-require your config modules in the running editor |
| `plugins` | optional: an index of the plugin ecosystem, for plugins you do *not* have |

The agent works inside your Neovim config directory (`~/.config/nvim` by
default) and nowhere else. When you ask it to change something, it edits the
files there. After each edit, `verify` boots the edited config in a sandbox
and reports whether it still starts, and that report is attached to the edit
so the agent cannot skip the check. Each edit is also committed to a shadow git
repo, separate from any repo of your own, so `:FieldguideUndo` puts your config
back.

## What it can and cannot see

| Can | Cannot |
|---|---|
| read and edit files in your config directory | read or write anything else on disk |
| read the help files of your installed plugins | read the contents of your open buffers |
| see which buffers are open, by name, plus their diagnostics | see your terminal, clipboard, or other windows' text |
| see keymaps, loaded plugins and their versions, LSP clients | reach the network from `verify` |
| search a downloaded index of the plugin ecosystem, if you fetched one | reach the network at all, except that download |

The agent never reads what is in your buffers. `state` reports names, paths,
and diagnostics messages, not lines. A path gate in the extension enforces the
two readable zones, with a test table covering the ways around it.

## Requirements

| | |
|---|---|
| Neovim | 0.12 or newer |
| node | 22 or newer |
| git | for the shadow repo |
| a sandbox | `bwrap` on Linux, `sandbox-exec` on macOS (ships with the OS) |
| pi | 0.79 or newer, with a model provider configured |

To install pi and check it can reach a model:

```
npm install -g @earendil-works/pi-coding-agent
pi --list-models
pi auth check --provider <name>
```

There is no build step and nothing to `npm install` in this repo.

If you use [mise](https://mise.jdx.dev), `mise run doctor` reports what your
machine is missing.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "jaitd/fieldguide.nvim",
  lazy = false,
  opts = {},
  keys = {
    { "<leader>fg", "<cmd>Fieldguide<cr>", desc = "Toggle fieldguide" },
    { "<leader>fh", "<cmd>FieldguideHistory<cr>", desc = "Fieldguide sessions" },
  },
}
```

fieldguide binds no global keys by default. The `keys` above are a suggestion;
lazy's `keys` field also lazy-loads the plugin for free.

## First run

1. Run `:Fieldguide`. The panel opens on the right with the cursor in the prompt.
2. Ask something about your setup. For example: *what does `<leader>ff` do?*
   or *why is my LSP not attaching to Lua files?*
3. Press `Enter` to send. `Shift+Enter` inserts a newline. `<C-c>` interrupts.

The agent answers from your installed plugins' docs and the live session. If it
edits a file, you will see a `verify` line under the edit saying whether your
config still boots.

`:Fieldguide` again hides the panel without ending the session. `<C-o>` lists
past sessions to pick up where you left off.

## Read this before enabling `reload`

`reload` executes agent-written code in your running editor, unsandboxed. At
`reload.level = "auto"` nothing stands between an agent write and that
execution. `verify` is not that gate: it boots and quits, so anything deferred
to an autocmd, a keymap, or a plugin `config` function never runs under it.

The realistic risk is prompt injection through the docs the agent reads, not
the agent deciding to misbehave: it reads tens of thousands of lines of
third-party help text with nobody watching.

The default is `"auto"`. If you would rather keep a hand on it, start at
`"verify-only"` and switch to `:FieldguideLevel auto` when you are watching:

```lua
opts = { reload = { level = "verify-only" } }
```

More on what does and does not hold in [docs/design-notes.md](docs/design-notes.md).

## Keys inside the panel

| Key | |
|---|---|
| `Enter` | send |
| `Shift+Enter`, `Alt+Enter` | new line |
| `<C-s>` | send, from anywhere in the panel |
| `<C-c>` | interrupt the agent |
| `<C-q>` | hide the panel |
| `<C-o>` | past sessions |
| `<Up>` / `<Down>` | page through prompts already sent |
| `<Tab>` | expand or collapse the tool output under the cursor |
| `j` / `k` | in the transcript, move through answers |
| `i` | from the transcript, jump to the prompt |
| `gf`, `<C-]>` | from a tool line, open the file that call was about |
| `<F5>` | put the Ex command under the cursor on the command line, without running it |

`Shift+Enter` only reaches Neovim on terminals with the Kitty keyboard protocol
(Ghostty, kitty, WezTerm, foot). Elsewhere use `Alt+Enter`.

Override with `panel_keys = { hide = "...", history = "..." }`.

## Commands

| | |
|---|---|
| `:Fieldguide` | toggle the panel; hides, never kills, so the agent keeps its context |
| `:FieldguideFocus` | jump to the prompt |
| `:FieldguideHistory` | pick a past session and carry on |
| `:FieldguideStop` | stop the agent session |
| `:FieldguideVerify` | sandboxed boot of your config, right now |
| `:FieldguideReload` | re-require config modules |
| `:FieldguideUndo [ref]` | restore the config tree from the shadow repo (default `HEAD~1`) |
| `:FieldguideLog` | list shadow-repo checkpoints |
| `:FieldguideLevel <level>` | `auto`, `verify-only` or `manual`, for this session |
| `:FieldguideDocs <query>` | the docs resolver, without an agent |
| `:FieldguideKeymap <lhs>` | explain a keymap, without an agent |
| `:FieldguideState [sections]` | dump live state |
| `:FieldguideIndex` | download or refresh the plugin index |
| `:FieldguideRpc` | the raw event stream, for protocol work |
| `:FieldguideTerm` | an embedded-terminal sidebar, kept as a fallback |

## The plugin index (optional)

Everything above answers from the editor in front of you, which says nothing
about a plugin you have *not* installed. That is most of the question when you
ask what to install, or whether the thing you are using has been archived since
the model was trained.

An optional index closes that gap: one SQLite file describing the ecosystem,
with each plugin's stars, category, last commit date, and whether its
maintainer has archived it or named a successor. Nothing fetches it for you:

```
:FieldguideIndex
```

That downloads the published index (a few megabytes, from a GitHub release)
into `stdpath("state")/fieldguide/`. With it, the agent gets two more tools:
`nvim_plugins` to search by need and to check your installed plugins for
withdrawal, and `nvim_plugin` for one plugin in full, with its dependency
edges. Without it, those tools are simply absent.

```
ggandor/lightspeed.nvim      1553★  archived — successor: ggandor/leap.nvim
b3nj5m1n/kommentary           528★  superseded by numToStr/Comment.nvim
numToStr/Comment.nvim        4666★  active, last commit 24 months ago
```

Age is reported and never judged: Comment.nvim has not needed a commit in two
years and is still the right answer. Only what a maintainer declared counts.

A background refresh is available and off by default, because a plugin that
reaches for the network at startup uninvited has made a decision that was not
its to make:

```lua
index = {
  auto = false,          -- refresh in the background at startup
  max_age_days = 14,     -- ...at most this often
},
```

An update never disturbs a session in progress: the download is verified, then
swapped in, and a running session keeps the index it started with. The index
and the plugin are versioned independently, and a mismatch names which side to
update. How the index is built, and what stops a repository describing itself
into it, is in [tools/plugin-index/README.md](tools/plugin-index/README.md).

## Configuration

Everything below is the default. Pass only what you want to change to `opts`.

```lua
{
  -- nil: whatever pi resolves from its own settings.
  provider = nil,
  model = nil,
  cmd = "pi",

  window = { side = "right", width = 80 },

  -- Which tools the agent gets. Can be shrunk, never grown.
  verbs = { "state", "docs", "explain_keymap", "verify", "reload" },
  state = { default = { "nvim", "buffers", "diagnostics", "plugins", "keymaps" } },

  -- "auto" picks bwrap on Linux and sandbox-exec on macOS. There is no "none".
  verify = { timeout_ms = 15000, sandbox = "auto" },

  -- auto | verify-only | manual. See "Read this before enabling reload".
  reload = { level = "auto" },

  chat = {
    flush_hz = 20,          -- how often streamed text is written to the buffer
    prompt_height = 5,
    show_thinking = false,
    user_name = nil,        -- nil: your login name
    mark_current = true,    -- a bar beside the message you are reading
    session_dir = nil,      -- nil: stdpath("state")/fieldguide/sessions
    max_tool_lines = 40,    -- lines shown for a collapsed tool result
  },

  -- Global keys. Empty by default; set any of toggle / focus / reload / history.
  keys = {},

  -- The plugin index. See "The plugin index" above.
  index = { path = nil, repo = nil, auto = false, max_age_days = 14 },

  -- Keys inside the panel's own buffers.
  panel_keys = { hide = "<C-q>", history = "<C-o>" },
}
```

### Picking a provider and model

`provider` and `model` are passed straight to pi and must agree.
`pi --list-models` shows the valid pairs. A ChatGPT subscription is the
`openai-codex` provider:

```lua
provider = "openai-codex",
model = "gpt-5.5",         -- not "openai/gpt-5.5"
```

A model id from the wrong provider is not caught up front. pi passes it through
and the refusal arrives mid-reply, which the panel shows as `agent error:`.

API keys come from the environment only, for example `OPENROUTER_API_KEY`.
There is no key field in the config, because Neovim configs get committed to
public repos.

### Markdown rendering

The transcript is a plain `markdown` buffer, so treesitter highlights it with
nothing extra. For concealed markers, styled headings and drawn tables, install
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim);
it attaches on its own.

### Highlight groups

All linked with `default`, so a colourscheme can claim them.

| Group | |
|---|---|
| `FieldguideUser` | your turns |
| `FieldguideCurrent` | the bar beside the message you are reading |
| `FieldguideTool`, `FieldguideToolDetail`, `FieldguideToolIcon` | a tool call, its body, its glyph |
| `FieldguideToolOk`, `FieldguideToolError` | the glyph when a call passed or failed |
| `FieldguideDiffAdd`, `FieldguideDiffDelete` | lines in a collapsed edit |
| `FieldguideTitle`, `FieldguideSession`, `FieldguidePlaceholder` | the winbar, the status row, the empty prompt |

## How it works, briefly

- **Three zones.** The agent can read and write your config directory, read
  the installed plugins' docs, and nothing else. The path gate is enforced in
  the extension, with a test table that is the security-relevant part of the
  suite.
- **verify** boots your config headless inside an OS sandbox: config read-only,
  no network, all writes thrown away. It reports errors, `:messages`, which
  plugins loaded, and how long it took. It is a correctness check, not a
  security boundary.
- **The shadow repo** is a git dir kept out of your config directory that
  shares its work tree. Every agent write is a commit there. Your real repo,
  if you have one, never sees it.
- **The CLI.** Every tool is also `bin/fieldguide <verb>`, which talks to the
  running editor over its socket. The agent harness is an adapter on top.

The reasoning behind these choices, the differences between the two sandboxes,
and the panel's layout behaviour are in [docs/design-notes.md](docs/design-notes.md).

## Development

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers how to
propose a change, report a bug or a security issue, and use AI assistance
responsibly.

To run from a local checkout, point lazy at it:

```lua
{ dir = "~/path/to/fieldguide", name = "fieldguide.nvim", opts = {} }
```

Keep the checkout **outside** your config directory. That directory is the
agent's read/write zone, and a checkout inside it would be too.

### Tests

```
mise run test          # the whole suite
mise run test:gate     # the path gate table
mise run test:linux    # the suite again under bwrap, in a container
mise run fmt
mise run index:fetch   # download the published plugin index
mise run index         # build the plugin index from scratch (slow; needs a GitHub token and a model)
```

`tools/plugin-index/` builds the index; the index itself is a SQLite file on
its own release track and is never committed here. Everything else at the top
level ships to a user's machine when a plugin manager checks the repo out.

Without mise: `node --test tests/*.test.ts`, then `nvim -l tests/<name>.lua`
for each file in `tests/`, and `./tests/bridge.sh`. The bridge tests run
against *your* real config on purpose: the docs resolver's whole claim is that
it answers from what is actually installed.

### Conventions

Commits are [conventional](https://www.conventionalcommits.org):
`<type>(<scope>): <subject>`, with types `feat fix chore docs refactor perf
test build ci` and the subject under 72 characters. Branches are named the same
way: `<type>/<short-kebab-description>`, for example `fix/seatbelt-sandbox`.

Both are enforced by git hooks, installed once per clone:

```
mise run hooks
```

| Hook | Checks |
|---|---|
| pre-commit | `stylua --check` on staged Lua; the path gate suite when the extension changed |
| commit-msg | the conventional-commit shape |
| pre-push | the branch name, then the whole suite |

Merge, revert and fixup subjects are let through, because git writes those.

## License

[Apache-2.0](LICENSE).

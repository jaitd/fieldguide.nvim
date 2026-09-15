# The plugin index

One SQLite file describing the Neovim plugin ecosystem, so the agent can answer
about plugins that are **not** installed.

Everything else in fieldguide answers from the editor in front of it, and for
installed plugins that is strictly better than any index: `nvim_docs` resolves
helptags at the revision on disk, and `grep` reaches the whole of `lazy_root`
through the read-only doc zone. Those are the exact bytes the user is running.
This file exists for the four questions the live session cannot be asked:

| | |
|---|---|
| **discovery** | plugins they do not have |
| **withdrawal** | archived, or superseded by a named successor |
| **integration** | what works with what |
| **freshness** | upstream moved past the pinned revision |

Withdrawal pays for the rest. A model cannot know from training data that a
plugin was archived after its cutoff, and recommending a plugin whose own
README now points elsewhere is worse than recommending nothing.

It is deliberately narrow. Only what the maintainer declared counts — the
GitHub archive flag, or the repository saying of itself that something replaced
it. Time since the last commit is stored and reported but never turned into a
verdict, because a finished plugin and an abandoned one look identical from the
outside and the popular ones are mostly finished.

## Getting one

Users run `:FieldguideIndex`. From a checkout:

```sh
mise run index:fetch     # download the published index
mise run index           # build one from scratch (slow, needs a token and a provider)
```

## Versioning

The index is **released on its own track**, never tied to a fieldguide version.
The two move at different speeds and a user may hold any combination of them.

`meta.schema` is a semver describing the shape of the file:

| | |
|---|---|
| major | a reader at the old version cannot cope — a column dropped, renamed, retyped, or a value whose meaning changed |
| minor | additive: a new column or table an older reader can ignore |
| patch | how a column is populated, shape identical |

A reader accepts a range rather than an exact value — major equal, minor and
patch at least its own — which is the point of the semver: adding a column must
not lock out every reader already installed. Anything outside the range is
refused whole, because half-understood columns surface as an agent answering
confidently from fields that no longer mean what it thinks they mean.

`SCHEMA_VERSION` in `build.ts` and `READS_SCHEMA` in `extension/plugins.ts` are
the two halves. Change one and the tests will tell you about the other.

## Releases

One release per schema major, with the asset replaced in place:

```
index-v1/nvim-plugins.db.gz
index-v1/nvim-plugins.db.gz.sha256
```

The digest is served by the same host as the file, so it catches a truncated or
corrupted transfer and nothing else — it is **not** a signature, and it would
not survive a compromised release. Being a few bytes against a few megabytes it
also makes "is there anything new" free, which is what the fetcher asks for
first. Signing is the upgrade path when it is worth the key management.

No dates in the tag. A reader knows the major it was built against and nothing
about which minor it will be offered months from now, so it cannot construct an
exact-version URL — a channel tag it can. The precise version lives in the
file's `meta` and the release title; `built_at` says how fresh the data is. The
version answers *can I read this*, the date answers *how current is this*, and
neither pretends to be the other.

Rolling to a new major means creating `index-v2` and keeping `index-v1` fed
until it is retired, so nobody's editor loses the tools the day the schema
moves.

The weekly job replaces the asset **only when something material changed** —
the plugin set, a withdrawal flag, a blurb, a category, keywords. Star counts
drift on nearly every repository every week and republishing 18MB over that
moves `built_at` without moving what the index can answer. `changed.ts` decides,
and prints its reasoning into the job log.

`last_push` is treated as noise for that decision, which is a judgement worth
knowing about: it feeds no verdict any more, and roughly a fifth of the corpus
takes a commit in any given week, so counting it would mean the answer was
always yes. The count is printed regardless.

## What ships, and what does not

No third-party prose. READMEs and help files are read during the build and
discarded; the artifact carries metadata, the CC0 blurbs from awesome-neovim,
and blurbs written here, which are our own text. That is a licensing posture as
much as a size one — a corpus of a few thousand repositories contains some with
no licence at all, and "public on GitHub" is not a grant to redistribute.

## How a plugin gets described

awesome-neovim supplies a curated blurb and a category for the plugins it
lists, and a human line beats a generated one, so those are kept as they are.
The rest — the long tail from the topic sweep, and the curated entries whose
GitHub description is a joke and an emoji — are described by a model, from the
repository's **shape** rather than its prose:

```
top-level files    colors/ means colorscheme and nothing else does
lua/ modules       gitsigns is blame.lua, hunks.lua, diffthis.lua
doc/               the author explaining their own work to a user
README             last, and labelled as the marketing copy it is
```

It returns a blurb, a category from the fixed list in `categories.json`, and
three to eight **keywords**. The keywords are the point: they are where
"autocompletion" gets written down next to "completion", and `gutter` next to
`statuscolumn`. That is the vocabulary bridge an embedding would otherwise be
needed for, done once at build time with no query-time inference and no
runtime dependency.

Each blurb is cached in `blurbs.json` against the release tag it describes, or
the commit where there is no tag — a little over half of plugins never tag. CI
commits that file back, so a weekly rebuild asks the model only about plugins
that are new or have moved: a few dozen calls rather than a few thousand.

## Guards

The material fed to the model is untrusted text from strangers, and its output
lands in a database read by an agent that can write to your config. Four things
hold, and only the last is a model:

- **Constrained output.** The category must be one of the 72 in
  `categories.json`; a blurb over 200 characters or an empty keyword list is
  refused rather than repaired. A rejected plugin falls back to its GitHub
  description, which is worse and is not laundered prose.
- **The committed cache.** A blurb a poisoned repository talked the model into
  writing appears as a diff before it reaches anyone.
- **A structural cross-check.** A claimed category is tested against the file
  tree: `colors/` is asserted in both directions, because it is the one marker
  that is unambiguous. Everything else would be a guess dressed as a check.
- **The tree grounding itself.** Writing plausible code is harder than writing
  an eloquent paragraph. This raises the bar; it does not remove the problem.

## The graph

`edge` records **how each edge was concluded**:

- `lazy-spec` — the plugin's own README declares it in a `dependencies` block.
- `naming` — the repo name says so, `cmp-*` extending `nvim-cmp`. The
  ecosystem's conventions are strong enough that most integration edges fall
  out of the name alone.

A caller that cannot tell those apart will present a guess as a fact, so the
evidence travels with the edge and `nvim_plugin` reports it.

## Ranking

`plugin_fts` is a contentless FTS5 index over name, blurb, keywords and
description, weighted in that order. Relevance alone surfaces whichever project
wrote the most prose about a term; popularity alone surfaces whatever is
biggest regardless of the question. The coefficient balancing them is fitted
against the sample queries in `tests/plugins.test.ts`. Distros and plugin
managers are excluded outright: a distro bundles every feature, so it matches
everything and helps with nothing.

## Running the builder

It needs a GitHub token — `GITHUB_TOKEN`, or whatever `gh auth token` prints —
and, unless given `--no-llm`, a provider for the blurbs:

```sh
FIELDGUIDE_INDEX_PROVIDER=openrouter \
FIELDGUIDE_INDEX_MODEL=deepseek/deepseek-v4.1-flash \
  node tools/plugin-index/build.ts out.db
```

Blurbs are written with thinking off (`FIELDGUIDE_INDEX_THINKING=off`, passed
to pi as `--thinking`). Turn it up, or set it empty to take pi's default, and
every call will spend minutes thinking about a sentence and trip the timeout.
Cataloguing is a summarising job; keep it fast.

Run `pi update --models` first, with the provider's key in the environment. The
catalog pi ships with lags OpenRouter's, and a model missing from it runs as a
custom id with no reasoning support: pi warns `Using custom model id`, drops
`--thinking off`, and the model reasons at its own default. CI refreshes before
every build for the same reason.

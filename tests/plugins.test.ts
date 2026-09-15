// The plugin index (§12): ranking, withdrawal, and the queries the tools run.
//
// Every case builds its own miniature index in memory rather than leaning on a
// downloaded one. The real file is 18MB of GitHub metadata that changes weekly;
// a test that depended on it would be testing the ecosystem, not the code.

import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { classify, toMatch, readable, advice, Index, UnreadableIndex } from "../extension/plugins.ts";

const SCHEMA = `
create table plugin (
  id integer primary key, full_name text not null unique, owner text not null, repo text not null,
  description text, blurb text, blurb_source text not null, keywords text not null default '[]',
  homepage text, stars integer not null default 0, forks integer not null default 0,
  open_issues integer not null default 0, pushed_at text, created_at text,
  archived integer not null default 0, superseded_by text, license text, ref text, topics text,
  modules text not null default '[]', has_colors integer not null default 0, has_doc integer not null default 0);
create table category (id integer primary key, name text not null unique);
create table plugin_category (plugin_id integer not null, category_id integer not null,
  primary key (plugin_id, category_id));
create table edge (src integer not null, dst integer not null, kind text not null, evidence text not null,
  primary key (src, dst, kind));
create virtual table plugin_fts using fts5(full_name, blurb, keywords, description,
  content = '', tokenize = 'porter unicode61');
create table meta (key text primary key, value text);
`;

type Seed = {
  name: string; blurb: string; stars: number; ago: number;
  archived?: boolean; supersededBy?: string; category?: string; keywords?: string[];
};

function build(
  seeds: Seed[],
  edges: [string, string, string, string][] = [],
  schema = "1.0.0",
): { path: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "fg-index-"));
  const path = join(dir, "test.db");
  const db = new DatabaseSync(path);
  db.exec(SCHEMA);
  const ids = new Map<string, number>();
  for (const s of seeds) {
    const pushed = new Date(Date.now() - s.ago * 30.44 * 864e5).toISOString();
    const keywords = s.keywords ?? [];
    const id = Number(
      db.prepare(
        `insert into plugin (full_name, owner, repo, description, blurb, blurb_source, keywords,
           stars, pushed_at, archived, superseded_by) values (?,?,?,?,?,?,?,?,?,?,?)`,
      ).run(s.name, s.name.split("/")[0], s.name.split("/")[1], s.blurb, s.blurb, "generated",
            JSON.stringify(keywords), s.stars, pushed, s.archived ? 1 : 0,
            s.supersededBy ?? null).lastInsertRowid,
    );
    ids.set(s.name, id);
    const cat = s.category ?? "Utility";
    db.prepare("insert or ignore into category (name) values (?)").run(cat);
    const cid = (db.prepare("select id from category where name = ?").get(cat) as { id: number }).id;
    db.prepare("insert into plugin_category values (?,?)").run(id, cid);
    db.prepare("insert into plugin_fts (rowid, full_name, blurb, keywords, description) values (?,?,?,?,?)")
      .run(id, s.name, s.blurb, keywords.join(" "), s.blurb);
  }
  for (const [src, dst, kind, evidence] of edges) {
    db.prepare("insert into edge values (?,?,?,?)").run(ids.get(src), ids.get(dst), kind, evidence);
  }
  db.prepare("insert into meta values (?,?)").run("built_at", new Date().toISOString());
  db.prepare("insert into meta values (?,?)").run("schema", schema);
  db.close();
  return { path, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test("status reports what a maintainer declared and never infers it from the calendar", () => {
  const now = new Date("2026-08-31");
  assert.equal(classify("2026-08-01T00:00:00Z", false, null, now)[0], "active");
  // vim-surround: 14k stars, 26 months quiet, and still the answer for surround.
  // No amount of silence makes a finished plugin into an abandoned one.
  assert.equal(classify("2024-06-01T00:00:00Z", false, null, now)[0], "active");
  assert.equal(classify("2019-01-01T00:00:00Z", false, null, now)[0], "active");
  // Both of the things that do count are statements, not measurements.
  assert.equal(classify("2026-08-25T00:00:00Z", true, null, now)[0], "archived");
  assert.equal(classify("2024-01-01T00:00:00Z", false, "numToStr/Comment.nvim", now)[0], "superseded");
  // Archived outranks a successor: the button is harder evidence than the prose.
  assert.equal(classify("2024-01-01T00:00:00Z", true, "numToStr/Comment.nvim", now)[0], "archived");
  // The age is still reported, it just decides nothing.
  assert.equal(classify("2024-06-01T00:00:00Z", false, null, now)[1], 27);
  assert.equal(classify(null, false, null, now)[0], "active");
  assert.equal(classify(null, false, null, now)[1], null);
});

test("a question in prose becomes terms, and its concepts survive as groups", () => {
  const { strict, loose } = toMatch("What is the best plugin for fuzzy finding files?");
  // 'what', 'best', 'plugin', 'for' carry no signal and would match everything.
  assert.ok(!strict.includes("best") && !strict.includes("plugin"));
  assert.ok(strict.includes("fuzzy") && strict.includes("files"));
  assert.ok(strict.includes(" AND ") && loose.includes(" OR "));
  assert.deepEqual(toMatch("!!! ???"), { strict: "", loose: "" });
});

test("punctuation in a query cannot become FTS syntax", () => {
  const { path, cleanup } = build([{ name: "a/b", blurb: "quoting", stars: 1, ago: 1 }]);
  const ix = new Index(path);
  // Each of these is a syntax error if it reaches FTS5 unquoted.
  for (const q of ['a "quoted" thing', "NEAR(x y)", "a OR b AND (c", 'say "hi""'  ]) {
    assert.doesNotThrow(() => ix.search(q), q);
  }
  ix.close();
  cleanup();
});

test("popularity is weighed against relevance, and neither wins outright", () => {
  const { path, cleanup } = build([
    // The obscure one says the word more often; the popular one is the answer.
    { name: "tiny/picker.nvim", blurb: "fuzzy finder", stars: 40, ago: 1, keywords: ["fuzzy", "finder", "fuzzy finder"] },
    { name: "nvim-telescope/telescope.nvim", blurb: "a highly extendable fuzzy finder over lists",
      stars: 19000, ago: 0, keywords: ["fuzzy", "finder", "picker"] },
    // A distro's README names every feature it bundles, so it matches anything.
    { name: "distro/kickstart.nvim", blurb: "a launch point for your config with a fuzzy finder and completion",
      stars: 31000, ago: 1, category: "Pre-made Configuration", keywords: ["fuzzy", "finder", "lsp"] },
  ]);
  const ix = new Index(path);
  const names = ix.search("fuzzy finder").map((h) => h.name);
  assert.equal(names[0], "nvim-telescope/telescope.nvim");
  assert.ok(!names.includes("distro/kickstart.nvim"), "a distro is never the answer to 'what should I use'");
  ix.close();
  cleanup();
});

test("a finished plugin is still an answer, and a long silence hides nothing", () => {
  const { path, cleanup } = build([
    // Comment.nvim as it really stands: 4,666 stars, two years without a commit,
    // and the plugin everyone means when they say "commenting".
    { name: "numToStr/Comment.nvim", blurb: "comment toggling", stars: 4666, ago: 24 },
    { name: "b3nj5m1n/kommentary", blurb: "comment toggling", stars: 528, ago: 33,
      supersededBy: "numToStr/Comment.nvim" },
    { name: "gone/commentary.nvim", blurb: "comment toggling", stars: 900, ago: 40, archived: true },
  ]);
  const ix = new Index(path);
  const names = ix.search("comment toggling").map((h) => h.name);
  assert.equal(names[0], "numToStr/Comment.nvim", "24 months of silence is not a demotion");
  // Superseded still answers — the successor rides along and the caller decides.
  const superseded = ix.search("comment toggling").find((h) => h.name === "b3nj5m1n/kommentary");
  assert.equal(superseded?.status, "superseded");
  assert.equal(superseded?.superseded_by, "numToStr/Comment.nvim");
  // Archived is the one thing held back, because it is the one hard fact.
  assert.ok(!names.includes("gone/commentary.nvim"));
  assert.equal(ix.search("comment toggling", { includeArchived: true }).length, 3);
  ix.close();
  cleanup();
});

test("an archived plugin still comes back when it is the only answer", () => {
  const { path, cleanup } = build([
    { name: "only/hologram.nvim", blurb: "terminal image protocol", stars: 1400, ago: 33, archived: true },
  ]);
  const ix = new Index(path);
  // Saying "here, and it is archived" beats saying "none".
  const fallback = ix.search("terminal image protocol");
  assert.equal(fallback[0].name, "only/hologram.nvim");
  assert.equal(fallback[0].status, "archived");
  ix.close();
  cleanup();
});

test("an installed set is checked, and only the trouble comes back", () => {
  const { path, cleanup } = build([
    // Two years quiet and perfectly fine. Flagging this would bury the two below
    // it under thirty warnings nobody can act on.
    { name: "numToStr/Comment.nvim", blurb: "comments", stars: 4666, ago: 24 },
    { name: "godlygeek/tabular", blurb: "alignment", stars: 2661, ago: 26 },
    { name: "ggandor/lightspeed.nvim", blurb: "motions", stars: 1500, ago: 33, archived: true },
    { name: "b3nj5m1n/kommentary", blurb: "comments", stars: 528, ago: 33,
      supersededBy: "numToStr/Comment.nvim" },
    { name: "lewis6991/gitsigns.nvim", blurb: "git signs", stars: 7000, ago: 1 },
  ]);
  const ix = new Index(path);
  const stale = ix.audit([
    "numToStr/Comment.nvim", "godlygeek/tabular", "ggandor/lightspeed.nvim",
    "b3nj5m1n/kommentary", "lewis6991/gitsigns.nvim", "not/here",
  ]);
  assert.deepEqual(stale.map((h) => h.name), ["ggandor/lightspeed.nvim", "b3nj5m1n/kommentary"]);
  assert.equal(stale[0].status, "archived");
  assert.equal(stale[1].superseded_by, "numToStr/Comment.nvim");
  assert.deepEqual(ix.audit([]), []);
  // What nvim_state actually reports: lazy's bare repo names, in whatever case
  // the spec spelled them. Both must still find the row.
  assert.deepEqual(
    ix.audit(["Comment.nvim", "lightspeed.nvim", "KOMMENTARY"]).map((h) => h.name),
    ["ggandor/lightspeed.nvim", "b3nj5m1n/kommentary"],
  );
  assert.deepEqual(ix.audit(["NUMTOSTR/comment.nvim", "B3NJ5M1N/kommentary"]).map((h) => h.name), [
    "b3nj5m1n/kommentary",
  ]);
  ix.close();
  cleanup();
});

test("an edge carries how it was concluded, so a guess is not read as a fact", () => {
  const { path, cleanup } = build(
    [
      { name: "hrsh7th/nvim-cmp", blurb: "completion", stars: 9000, ago: 2 },
      { name: "hrsh7th/cmp-buffer", blurb: "buffer source", stars: 700, ago: 5 },
      { name: "user/thing.nvim", blurb: "a thing", stars: 10, ago: 1 },
    ],
    [
      ["hrsh7th/cmp-buffer", "hrsh7th/nvim-cmp", "extends", "naming"],
      ["user/thing.nvim", "hrsh7th/nvim-cmp", "depends", "lazy-spec"],
    ],
  );
  const ix = new Index(path);
  const cmp = ix.show("nvim-cmp");
  assert.ok(cmp);
  assert.equal(cmp.depended_on_by.length, 2);
  assert.deepEqual(cmp.depended_on_by.map((d) => d.via).sort(), ["lazy-spec", "naming"]);
  // Resolvable by bare repo name as well as owner/repo, since that is how
  // people and lazy specs both refer to plugins in conversation.
  assert.equal(ix.show("hrsh7th/cmp-buffer")?.depends_on[0].name, "hrsh7th/nvim-cmp");
  assert.equal(ix.show("nothing/here"), null);
  ix.close();
  cleanup();
});

test("the accepted schema range is a semver caret, not an exact match", () => {
  // The whole point of the range: an additive change to the index must not
  // lock out every reader already in the wild.
  assert.ok(readable("1.0.0", "1.0.0"));
  assert.ok(readable("1.4.0", "1.0.0"), "a newer minor only adds columns this build ignores");
  assert.ok(readable("1.0.9", "1.0.0"));
  assert.ok(readable("1.2.0", "1.1.9"), "minor outranks patch");

  // Older is refused too: this build may read a column that index never had.
  assert.ok(!readable("1.0.0", "1.1.0"));
  assert.ok(!readable("1.1.0", "1.1.1"));
  // A different major is a different contract in either direction.
  assert.ok(!readable("2.0.0", "1.0.0"));
  assert.ok(!readable("0.9.9", "1.0.0"));
  // Nothing that is not a semver is read hopefully.
  assert.ok(!readable(undefined));
  assert.ok(!readable("3"));
  assert.ok(!readable("1.0"));
  assert.ok(!readable("v1.0.0"));

  // The two mismatches need opposite actions, so the refusal names the right one.
  assert.match(advice("2.0.0", "1.0.0"), /Update fieldguide/);
  assert.match(advice("1.0.0", "1.4.0"), /Fetch a current index/);
  assert.match(advice("0.9.0", "1.0.0"), /Fetch a current index/);
  assert.match(advice(undefined), /Fetch a current index/);
});

test("an index from a different era is refused whole, not read optimistically", () => {
  // The index ships on its own release track, so any plugin version can meet
  // any index version. Reading half-understood columns would surface as the
  // agent answering confidently from fields that no longer mean what it thinks.
  const older = build([{ name: "a/b", blurb: "x", stars: 1, ago: 1 }], [], "0.9.0");
  assert.throws(() => new Index(older.path), UnreadableIndex);
  try {
    new Index(older.path);
  } catch (e) {
    assert.match(String((e as Error).message), /schema 0\.9\.0 .* reads 1\.0\.0/);
  }
  older.cleanup();

  const future = build([{ name: "a/b", blurb: "x", stars: 1, ago: 1 }], [], "2.0.0");
  assert.throws(() => new Index(future.path), UnreadableIndex);
  future.cleanup();

  // The integer schema this replaced must not be read as though it were 3.0.0.
  const legacy = build([{ name: "a/b", blurb: "x", stars: 1, ago: 1 }], [], "3");
  assert.throws(() => new Index(legacy.path), UnreadableIndex);
  legacy.cleanup();

  const additive = build([{ name: "a/b", blurb: "x", stars: 1, ago: 1 }], [], "1.3.0");
  const newer = new Index(additive.path);
  assert.equal(newer.built().schema, "1.3.0");
  newer.close();
  additive.cleanup();

  const current = build([{ name: "a/b", blurb: "x", stars: 1, ago: 1 }]);
  const ix = new Index(current.path);
  assert.equal(ix.built().schema, "1.0.0");
  ix.close();
  current.cleanup();
});

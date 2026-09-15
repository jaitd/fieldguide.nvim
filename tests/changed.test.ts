// The publish gate (§12): does a fresh crawl differ from the published index
// in a way anyone would notice?
//
// It decides whether a build replaces the index everyone downloads, so both
// its failure modes cost something. Saying yes to noise churns 18MB a week and
// moves built_at without moving what the index can answer. Saying no to real
// news leaves the ecosystem's answer stale until somebody notices by hand.

import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

type Plug = {
  name: string;
  blurb?: string;
  category?: string;
  keywords?: string;
  stars?: number;
  archived?: number;
  superseded_by?: string | null;
  pushed_at?: string;
};

function index(dir: string, file: string, plugins: Plug[]): string {
  const path = join(dir, file);
  const db = new DatabaseSync(path);
  db.exec(`
    create table plugin (id integer primary key, full_name text not null unique, blurb text,
      keywords text not null default '[]', stars integer not null default 0,
      archived integer not null default 0, superseded_by text, pushed_at text);
    create table category (id integer primary key, name text not null unique);
    create table plugin_category (plugin_id integer not null, category_id integer not null);
  `);
  for (const p of plugins) {
    const id = Number(
      db.prepare(
        "insert into plugin (full_name, blurb, keywords, stars, archived, superseded_by, pushed_at) values (?,?,?,?,?,?,?)",
      ).run(p.name, p.blurb ?? "does a thing", p.keywords ?? '["a"]', p.stars ?? 100,
            p.archived ?? 0, p.superseded_by ?? null, p.pushed_at ?? "2026-01-01").lastInsertRowid,
    );
    const cat = p.category ?? "Utility";
    db.prepare("insert or ignore into category (name) values (?)").run(cat);
    const cid = (db.prepare("select id from category where name = ?").get(cat) as { id: number }).id;
    db.prepare("insert into plugin_category values (?,?)").run(id, cid);
  }
  db.close();
  return path;
}

function compare(before: Plug[], after: Plug[]) {
  const dir = mkdtempSync(join(tmpdir(), "fg-changed-"));
  try {
    const out = execFileSync(
      process.execPath,
      ["tools/plugin-index/changed.ts", index(dir, "old.db", before), index(dir, "new.db", after)],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    return JSON.parse(out);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("star drift alone is not worth republishing an 18MB file over", () => {
  const before = [{ name: "a/b", stars: 19004 }, { name: "c/d", stars: 900 }];
  const after = [{ name: "a/b", stars: 19017 }, { name: "c/d", stars: 913 }];
  assert.equal(compare(before, after).material, false);
});

test("last_push moving is reported but does not force a republish", () => {
  // A fifth of the corpus takes a commit in any given week. Counting it would
  // make the answer always yes, and last_push feeds no verdict any more.
  const out = compare(
    [{ name: "a/b", pushed_at: "2026-01-01" }],
    [{ name: "a/b", pushed_at: "2026-08-30" }],
  );
  assert.equal(out.material, false);
  assert.equal(out.pushed_at_moved, 1, "still counted, so the choice stays reviewable");
});

test("everything a reader would actually notice forces a republish", () => {
  const base = [{ name: "a/b" }];
  // A plugin appearing or disappearing from the ecosystem.
  assert.equal(compare(base, [...base, { name: "new/one" }]).material, true);
  assert.equal(compare([...base, { name: "gone/one" }], base).material, true);
  // The two withdrawal signals, which are the whole reason the index exists.
  assert.equal(compare(base, [{ name: "a/b", archived: 1 }]).material, true);
  assert.equal(compare(base, [{ name: "a/b", superseded_by: "x/y" }]).material, true);
  // And what search matches on.
  assert.equal(compare(base, [{ name: "a/b", blurb: "does another thing" }]).material, true);
  assert.equal(compare(base, [{ name: "a/b", keywords: '["b"]' }]).material, true);
  assert.equal(compare(base, [{ name: "a/b", category: "Git" }]).material, true);
});

test("the verdict carries enough detail to review it in a job log", () => {
  const out = compare([{ name: "a/b" }, { name: "drop/me" }], [{ name: "a/b", archived: 1 }, { name: "add/me" }]);
  assert.equal(out.added, 1);
  assert.equal(out.removed, 1);
  assert.equal(out.changed, 1);
  assert.deepEqual(out.examples.added, ["add/me"]);
  assert.deepEqual(out.examples.removed, ["drop/me"]);
  assert.deepEqual(out.examples.changed["a/b"], ["archived"]);
});

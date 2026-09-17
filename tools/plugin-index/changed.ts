// Does a fresh build differ from the published one in a way anyone would
// notice?
//
//   node tools/plugin-index/changed.ts <published.db> <fresh.db>
//
// The weekly job replaces the release asset only when this says yes. Star
// counts drift on almost every repository every week, and republishing 18MB so
// that telescope can go from 19,004 to 19,017 buys nobody anything: it moves
// built_at without moving what the index can answer, which makes the freshness
// date lie about how fresh the *content* is.
//
// last_push is deliberately noise here. It is reported beside a status and no
// longer feeds one, and roughly a fifth of the corpus takes a commit in any
// given week — counting it would mean the answer is always yes and this file
// may as well not exist. The count is printed anyway, so the choice stays
// visible rather than buried.

import { DatabaseSync } from "node:sqlite";

type Row = {
  full_name: string;
  blurb: string | null;
  category: string | null;
  keywords: string;
  archived: number;
  superseded_by: string | null;
  pushed_at: string | null;
};

const MATERIAL = ["blurb", "category", "keywords", "archived", "superseded_by"] as const;

function read(path: string): Map<string, Row> {
  const db = new DatabaseSync(path, { readOnly: true });
  const rows = db
    .prepare(
      `select p.full_name, p.blurb, p.keywords, p.archived, p.superseded_by, p.pushed_at,
              (select c.name from category c
                 join plugin_category pc on pc.category_id = c.id
                where pc.plugin_id = p.id limit 1) category
         from plugin p`,
    )
    .all() as Row[];
  db.close();
  return new Map(rows.map((r) => [r.full_name, r]));
}

const [oldPath, newPath] = process.argv.slice(2);
const before = read(oldPath);
const after = read(newPath);

const added = [...after.keys()].filter((k) => !before.has(k));
const removed = [...before.keys()].filter((k) => !after.has(k));
const changed: Record<string, string[]> = {};
let pushes = 0;

for (const [name, now] of after) {
  const was = before.get(name);
  if (!was) continue;
  if (was.pushed_at !== now.pushed_at) pushes++;
  const fields = MATERIAL.filter((f) => was[f] !== now[f]);
  if (fields.length > 0) changed[name] = [...fields];
}

const material = added.length > 0 || removed.length > 0 || Object.keys(changed).length > 0;

process.stdout.write(
  JSON.stringify(
    {
      material,
      added: added.length,
      removed: removed.length,
      changed: Object.keys(changed).length,
      // Not material, printed so the decision to treat it as noise stays open
      // to review every week rather than being settled once in a comment.
      pushed_at_moved: pushes,
      examples: {
        added: added.slice(0, 10),
        removed: removed.slice(0, 10),
        changed: Object.fromEntries(Object.entries(changed).slice(0, 10)),
      },
    },
    null,
    1,
  ) + "\n",
);

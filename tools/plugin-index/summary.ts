// What the index came out as. Used by CI twice — once to decide whether the
// build is worth publishing, once for the release notes — so the numbers in the
// gate and the numbers in the notes cannot drift apart.
//
//   node tools/plugin-index/summary.ts <db> [--notes]

import { DatabaseSync } from "node:sqlite";

const [path, flag] = process.argv.slice(2);
const db = new DatabaseSync(path, { readOnly: true });
const one = (sql: string): number => (db.prepare(sql).get() as { n: number }).n;

const stats = {
  plugins: one("select count(*) n from plugin"),
  curated: one("select count(*) n from plugin where blurb_source = 'awesome'"),
  generated: one("select count(*) n from plugin where blurb_source = 'generated'"),
  described: one("select count(*) n from plugin where blurb is not null and trim(blurb) <> ''"),
  categories: one("select count(*) n from category"),
  edges: one("select count(*) n from edge"),
  archived: one("select count(*) n from plugin where archived = 1"),
  superseded: one("select count(*) n from plugin where superseded_by is not null"),
};

if (flag === "--notes") {
  process.stdout.write(
    `${stats.plugins} plugins across ${stats.categories} categories, ` +
      `${stats.curated} with a curated blurb and ${stats.generated} with a generated one. ` +
      `${stats.edges} dependency edges. ` +
      `${stats.archived} archived, ${stats.superseded} pointing at a successor.\n\n` +
      `Rebuilt ${new Date().toISOString()} from awesome-neovim and the GitHub API. ` +
      `Contains no third-party README or help text.\n`,
  );
} else {
  process.stdout.write(JSON.stringify(stats) + "\n");
}

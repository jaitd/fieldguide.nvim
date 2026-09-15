// Queries against the plugin index.
//
// Separated from `nvim.ts` for the same reason `gate.ts` is: the interesting
// logic is a pure function of the database, and a pure function can be tested
// without booting an editor or an agent.
//
// Read-only throughout. The index is a cache of public metadata; nothing about
// the user is written to it.

import { DatabaseSync } from "node:sqlite";

/**
 * The index schema this build was written against, and the range it accepts.
 *
 * The index ships on its own cadence, from its own release track, so any
 * plugin version can meet any index version. The tag is not the contract —
 * this is.
 *
 * Semver, with the range following from what each part means:
 *
 *   major  a reader at the old version cannot cope — a column dropped,
 *          renamed, retyped, or a value whose meaning changed
 *   minor  additive: a new column or table an older reader can ignore
 *   patch  how a column is populated, with the shape identical
 *
 * So the major must match exactly, and the index's minor and patch must be at
 * least this build's. Newer-but-compatible is fine; older is not, because this
 * build may read a column that an older index does not carry. Anything outside
 * the range is refused whole rather than read optimistically — half-understood
 * columns surface as an agent answering confidently from fields that no longer
 * mean what it thinks they mean.
 */
export const READS_SCHEMA = "1.0.0";

export class UnreadableIndex extends Error {}

type Semver = [number, number, number];

function parseSemver(v: string): Semver | null {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v.trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

/**
 * Which way the mismatch runs decides what the user should do about it, so the
 * refusal says which rather than leaving them to work it out from two numbers.
 */
export function advice(version: string | undefined, reads = READS_SCHEMA): string {
  const have = version === undefined ? null : parseSemver(version);
  const want = parseSemver(reads)!;
  if (!have) return "Fetch a current index.";
  if (have[0] > want[0]) return "Update fieldguide.";
  return "Fetch a current index.";
}

/** True when an index at `version` carries everything this build reads. */
export function readable(version: string | undefined, reads = READS_SCHEMA): boolean {
  const have = version === undefined ? null : parseSemver(version);
  const want = parseSemver(reads);
  if (!have || !want) return false;
  if (have[0] !== want[0]) return false;
  return have[1] !== want[1] ? have[1] > want[1] : have[2] >= want[2];
}

export type Status = "active" | "superseded" | "archived";

export type Hit = {
  name: string;
  blurb: string | null;
  stars: number;
  status: Status;
  superseded_by: string | null;
  last_push: string | null;
  months_since_push: number | null;
  category: string | null;
  source: string;
};

export type Detail = Hit & {
  description: string | null;
  homepage: string | null;
  license: string | null;
  open_issues: number;
  ref: string | null;
  modules: string[];
  keywords: string[];
  depends_on: { name: string; via: string }[];
  depended_on_by: { name: string; stars: number; via: string }[];
};

/**
 * Only what the maintainer has actually said. Archived is a GitHub flag they
 * set; superseded is the repository declaring in its own words that something
 * replaced it. Neither is inferred from the calendar.
 *
 * Time since the last commit is reported as a fact beside this and never
 * folded into it, because it does not carry the meaning it looks like it
 * carries. Measured against the sample this was built on: vim-surround at
 * 14,103 stars, tabular, vim-repeat, easy-align and Comment.nvim had all gone
 * two years without a commit, and each is still the right answer to its
 * question — they are finished, not abandoned. Sitting beside them at the same
 * age were kommentary and galaxyline, which really are over. Nothing mechanical
 * separates the two: issues-per-star does not (0.8% for vim-surround, 1.5% for
 * kommentary), and neither does recent issue traffic (zero for both — one
 * because there is nothing left to report, the other because nobody is
 * looking). A threshold here would only launder a guess into a verdict, so
 * there is none.
 */
export function classify(
  pushedAt: string | null,
  archived: boolean,
  supersededBy: string | null = null,
  now = new Date(),
): [Status, number | null] {
  const age = months(pushedAt, now);
  if (archived) return ["archived", age];
  if (supersededBy) return ["superseded", age];
  return ["active", age];
}

function months(iso: string | null, now: Date): number | null {
  if (!iso) return null;
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return null;
  return Math.max(0, Math.round((now.getTime() - then.getTime()) / (1000 * 60 * 60 * 24 * 30.44)));
}

/**
 * FTS5 treats punctuation as syntax, so a question phrased in prose has to be
 * reduced to quoted terms first. Two queries come back: every term, and any
 * term. The strict one is asked first because a row matching all of them is
 * almost always the better answer.
 *
 * There is no synonym table here any more. Bridging "autocompletion" to
 * "completion" is the `keywords` column's job, written once per plugin when the
 * index is built rather than maintained by hand for the whole language.
 */
export function toMatch(query: string): { strict: string; loose: string } {
  const terms = [
    ...new Set(
      query
        .toLowerCase()
        .split(/[^\p{L}\p{N}._-]+/u)
        .filter((t) => t.length > 1 && !STOP.has(t))
        .map((t) => `"${t.replace(/"/g, '""')}"`),
    ),
  ];
  return { strict: terms.join(" AND "), loose: terms.join(" OR ") };
}

const STOP = new Set([
  "a", "an", "the", "for", "with", "and", "or", "of", "to", "in", "on", "is", "it",
  "that", "this", "plugin", "plugins", "nvim", "neovim", "vim", "lua",
  "best", "good", "any", "some", "what", "which", "how", "do", "does", "can", "i",
  "use", "using", "there", "something", "anything", "recommend", "looking", "need",
]);

// bm25 column weights, in the order the FTS table declares them: full_name,
// blurb, keywords, description. The blurb is the best statement of what a
// plugin is for, and the keywords are the only place a user's word for it is
// written down, so those two carry the query. GitHub's own description is
// frequently a joke and an emoji.
const WEIGHTS = "12.0, 10.0, 9.0, 4.0";

// Relevance alone surfaces whichever project wrote the most prose about a term;
// popularity alone surfaces whatever is biggest regardless of the question.
// This balances them, fitted against the sample queries in tests/plugins.test.ts.
const POPULARITY = 1.2;

// A distro is never the answer to "what should I use for X": it bundles every
// feature, so it matches everything and helps with nothing.
const NOT_A_PLUGIN = ["Pre-made Configuration", "Plugin Manager"];

const COLUMNS = `p.id, p.full_name, p.blurb, p.stars, p.pushed_at, p.archived, p.superseded_by, p.blurb_source,
  (select c.name from plugin_category pc join category c on c.id = pc.category_id
    where pc.plugin_id = p.id limit 1) category`;

export class Index {
  private db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path, { readOnly: true });
    let schema: string | undefined;
    try {
      schema = (this.db.prepare("select value from meta where key = 'schema'").get() as { value: string })?.value;
    } catch {
      schema = undefined;
    }
    if (!readable(schema)) {
      this.db.close();
      throw new UnreadableIndex(
        `index schema ${schema ?? "(unknown)"} — this fieldguide reads ${READS_SCHEMA}. ${advice(schema)}`,
      );
    }
  }

  close() {
    this.db.close();
  }

  /** How many plugins are in here, for a caller deciding whether to trust it. */
  count(): number {
    return (this.db.prepare("select count(*) n from plugin").get() as { n: number }).n;
  }

  built(): Record<string, string> {
    const rows = this.db.prepare("select key, value from meta").all() as { key: string; value: string }[];
    return Object.fromEntries(rows.map((r) => [r.key, r.value]));
  }

  search(query: string, opts: { limit?: number; category?: string; includeArchived?: boolean } = {}): Hit[] {
    const limit = Math.min(opts.limit ?? 10, 50);
    const { strict, loose } = toMatch(query);
    if (!strict) return [];

    const seen = new Set<string>();
    const hits: Hit[] = [];
    for (const match of strict === loose ? [strict] : [strict, loose]) {
      for (const row of this.matching(match, opts.category, limit * 4)) {
        if (seen.has(row.full_name)) continue;
        seen.add(row.full_name);
        hits.push(this.hit(row));
      }
      if (hits.length >= limit * 2) break;
    }

    // Archived is the only thing held back, because it is the only hard fact:
    // a maintainer pressed the button. A superseded plugin is still returned —
    // its successor rides along in the row, and the question may well have been
    // about the one someone already has. Age holds nothing back at all.
    const live = opts.includeArchived ? hits : hits.filter((h) => h.status !== "archived");
    // Falling back rather than returning nothing: for an old or niche need the
    // only answers may be archived ones, and saying so beats saying "none".
    return (live.length > 0 ? live : hits).slice(0, limit);
  }

  private matching(match: string, category: string | undefined, limit: number): Row[] {
    // Both filters are subqueries rather than joins: bm25() is an FTS5
    // auxiliary function, and SQLite refuses it once a join has forced the
    // GROUP BY that a category join would need.
    const marks = NOT_A_PLUGIN.map(() => "?").join(",");
    return this.db
      .prepare(
        `select ${COLUMNS}
           from plugin_fts f
           join plugin p on p.id = f.rowid
          where plugin_fts match ?
            ${category
              ? `and p.id in (select pc.plugin_id from plugin_category pc
                   join category c on c.id = pc.category_id where c.name = ? collate nocase)`
              : ""}
            and p.id not in (
              select pc2.plugin_id from plugin_category pc2
                join category c2 on c2.id = pc2.category_id where c2.name in (${marks}))
          order by bm25(plugin_fts, ${WEIGHTS}) - ${POPULARITY} * log10(p.stars + 10)
          limit ?`,
      )
      .all(...[match, ...(category ? [category] : []), ...NOT_A_PLUGIN, limit]) as Row[];
  }

  show(name: string): Detail | null {
    const row = this.db
      .prepare(
        `select ${COLUMNS}, p.description, p.homepage, p.license, p.open_issues, p.ref, p.modules, p.keywords
           from plugin p where p.full_name = ? collate nocase or p.repo = ? collate nocase
          order by p.stars desc limit 1`,
      )
      .get(name, name) as
      | (Row & {
          description: string | null; homepage: string | null; license: string | null;
          open_issues: number; ref: string | null; modules: string; keywords: string;
        })
      | undefined;
    if (!row) return null;

    const depends = this.db
      .prepare(
        `select p.full_name name, e.evidence via from edge e
           join plugin p on p.id = e.dst where e.src = ? order by p.stars desc`,
      )
      .all(row.id) as { name: string; via: string }[];
    const dependents = this.db
      .prepare(
        `select p.full_name name, p.stars, e.evidence via from edge e
           join plugin p on p.id = e.src where e.dst = ? order by p.stars desc limit 25`,
      )
      .all(row.id) as { name: string; stars: number; via: string }[];

    return {
      ...this.hit(row),
      description: row.description,
      homepage: row.homepage,
      license: row.license,
      open_issues: row.open_issues,
      ref: row.ref,
      modules: parse(row.modules),
      keywords: parse(row.keywords),
      depends_on: depends,
      depended_on_by: dependents,
    };
  }

  /**
   * What the user already has, checked against the index for trouble. Trouble
   * is a maintainer withdrawing the plugin, not a quiet year: flagging every
   * finished plugin would bury the two that matter under thirty that do not.
   */
  audit(installed: string[]): Hit[] {
    if (installed.length === 0) return [];
    // Installed names arrive as whatever the plugin manager calls them —
    // 'owner/repo' from a spec, or the bare repo name lazy uses as a key — so
    // both columns are tried, like show(). Lowercased on both sides: a COLLATE
    // after an IN list applies to nothing, so it cannot do that here.
    const names = installed.map((n) => n.toLowerCase());
    const marks = names.map(() => "?").join(",");
    const rows = this.db
      .prepare(
        `select ${COLUMNS} from plugin p
          where lower(p.full_name) in (${marks}) or lower(p.repo) in (${marks})`,
      )
      .all(...names, ...names) as Row[];
    return rows
      .map((r) => this.hit(r))
      .filter((h) => h.status === "archived" || h.status === "superseded")
      .sort((a, b) => b.stars - a.stars);
  }

  categories(): { name: string; count: number }[] {
    return this.db
      .prepare(
        `select c.name, count(*) count from category c
           join plugin_category pc on pc.category_id = c.id group by 1 order by count desc`,
      )
      .all() as { name: string; count: number }[];
  }

  private hit(row: Row): Hit {
    const [status, age] = classify(row.pushed_at, row.archived === 1, row.superseded_by);
    return {
      name: row.full_name,
      blurb: row.blurb,
      stars: row.stars,
      status,
      superseded_by: row.superseded_by,
      last_push: row.pushed_at ? row.pushed_at.slice(0, 10) : null,
      months_since_push: age,
      category: row.category,
      source: row.blurb_source,
    };
  }
}

function parse(json: string): string[] {
  try {
    const v = JSON.parse(json);
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

type Row = {
  id: number;
  full_name: string;
  blurb: string | null;
  stars: number;
  pushed_at: string | null;
  superseded_by: string | null;
  archived: number;
  blurb_source: string;
  category: string | null;
};

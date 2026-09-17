// Builds the plugin index: one SQLite file describing the Neovim plugin
// ecosystem, so the agent can answer about plugins that are *not* installed.
//
// The installed set is already covered, and better: nvim_docs resolves helptags
// at the revision on disk, and grep reaches all of lazy_root through the
// read-only doc zone. Those are the exact bytes the user is running. This file
// answers the four questions the live session cannot be asked — discovery,
// withdrawal, integration, freshness — of which withdrawal pays for the rest,
// because no model can know from training data that a plugin was archived or
// handed over to a successor after its cutoff.
//
// No third-party prose is shipped. READMEs and help files are read during the
// build and discarded; what lands in the artifact is metadata, the CC0 blurbs
// from awesome-neovim, and blurbs generated here, which are our own text.
//
//   node tools/plugin-index/build.ts [out.db] [--no-llm] [--limit N]

import { renameSync, rmSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import * as gh from "./github.ts";
import { loadCache, saveCache, describe, modelFromEnv, type Cache } from "./blurbs.ts";
import { isConfig } from "./shape.ts";

const CACHE = new URL("./blurbs.json", import.meta.url).pathname;

/**
 * The shape of the file, semver, and the contract with every reader in the
 * wild. Bump the major for a column dropped, renamed, retyped, or a value whose
 * meaning changed; the minor for an additive column or table; the patch for a
 * change in how a column is populated. `readable()` in extension/plugins.ts is
 * the other half — change one and the tests will tell you about the other.
 */
const SCHEMA_VERSION = "1.0.0";

const SCHEMA = `
create table plugin (
  id            integer primary key,
  full_name     text not null unique,
  owner         text not null,
  repo          text not null,
  description   text,
  blurb         text,
  blurb_source  text not null,
  keywords      text not null default '[]',
  homepage      text,
  stars         integer not null default 0,
  forks         integer not null default 0,
  open_issues   integer not null default 0,
  pushed_at     text,
  created_at    text,
  archived      integer not null default 0,
  superseded_by text,
  license       text,
  ref           text,
  topics        text,
  modules       text not null default '[]',
  has_colors    integer not null default 0,
  has_doc       integer not null default 0
);
create index plugin_stars on plugin(stars desc);
create index plugin_pushed on plugin(pushed_at desc);

create table category (id integer primary key, name text not null unique);
create table plugin_category (
  plugin_id integer not null references plugin(id),
  category_id integer not null references category(id),
  primary key (plugin_id, category_id)
);

-- Directed, and carrying how it was concluded. An edge read out of a lazy spec
-- is stronger evidence than one inferred from a repo name, and a caller that
-- cannot tell them apart will present a guess as a fact.
create table edge (
  src integer not null references plugin(id),
  dst integer not null references plugin(id),
  kind text not null,
  evidence text not null,
  primary key (src, dst, kind)
);
create index edge_dst on edge(dst);

create virtual table plugin_fts using fts5(
  full_name, blurb, keywords, description,
  content = '', tokenize = 'porter unicode61'
);

create table meta (key text primary key, value text);
`;

// Repos matching a prefix extend the hub they name. The ecosystem's naming
// conventions are strong enough that most integration edges fall out of the
// repo name, with no model and no heuristics beyond this table.
const HUBS: Record<string, string> = {
  "cmp-": "hrsh7th/nvim-cmp",
  "telescope-": "nvim-telescope/telescope.nvim",
  "telescope_": "nvim-telescope/telescope.nvim",
  "lualine-": "nvim-lualine/lualine.nvim",
  "null-ls-": "nvimtools/none-ls.nvim",
  "none-ls-": "nvimtools/none-ls.nvim",
  "neotest-": "nvim-neotest/neotest",
  "nvim-dap-": "mfussenegger/nvim-dap",
  "blink-": "saghen/blink.cmp",
  "blink.": "saghen/blink.cmp",
  "heirline-": "rebelot/heirline.nvim",
  "lush-": "rktjmp/lush.nvim",
  "mason-": "mason-org/mason.nvim",
};

/** Plugins named in a lazy spec's `dependencies` are declared, not inferred. */
function dependencies(readme: string): string[] {
  const out = new Set<string>();
  for (const m of readme.matchAll(/dependencies\s*=\s*(\{[\s\S]{0,600}?\}|"[^"]+"|'[^']+')/g)) {
    for (const dep of m[1].matchAll(/["']([\w.-]+\/[\w.-]+)["']/g)) out.add(dep[1]);
  }
  return [...out];
}

async function main() {
  const args = process.argv.slice(2);
  const out = args.find((a) => !a.startsWith("--")) ?? "nvim-plugins.db";
  const noLlm = args.includes("--no-llm");
  const limitArg = args.indexOf("--limit");
  const limit = limitArg === -1 ? Infinity : Number(args[limitArg + 1]);

  const auth = gh.token();
  const say = (s: string) => process.stderr.write(s);

  say("reading awesome-neovim\n");
  const curated = await gh.awesome();
  const curatedBy = new Map(curated.map((s) => [s.full.toLowerCase(), s]));
  say(`  ${curated.length} curated plugins\n`);

  say("sweeping GitHub topics\n");
  const swept = await gh.sweep(auth);
  say(`  ${swept.length} repos at >=${gh.STAR_FLOOR} stars\n`);

  const names = [...new Set([...curated.map((s) => s.full), ...swept])].slice(0, limit);
  say(`querying GitHub for ${names.length} repos\n`);
  const repos = await gh.enrich(names, auth, (d, t) => say(`\r  enriched ${d}/${t}`));
  say(`\n  ${repos.size} resolved\n`);

  // A curated plugin stays in whatever its stars; the sweep's floor is the only
  // thing keeping the long tail from being mostly abandoned experiments.
  const floored = [...repos.values()].filter(
    (r) => !r.isFork && (curatedBy.has(r.nameWithOwner.toLowerCase()) || r.stargazerCount >= gh.STAR_FLOOR),
  );
  say(`  ${floored.length} after filtering forks and the floor\n`);

  // Dotfiles and personal configs, dropped before the blurbs. Curated repos
  // are exempt: the distributions are configs on purpose.
  const keep = floored.filter(
    (r) =>
      curatedBy.has(r.nameWithOwner.toLowerCase()) ||
      !isConfig({
        nameWithOwner: r.nameWithOwner,
        top: r.tree?.entries?.map((e) => e.name) ?? null,
        hasLua: (r.luaTree?.entries?.length ?? 0) > 0,
      }),
  );
  say(`  ${keep.length} after dropping ${floored.length - keep.length} configs and dotfiles\n`);

  // --- blurbs ---------------------------------------------------------------
  const cache: Cache = loadCache(CACHE);
  const needs = keep.filter((r) => {
    if (curatedBy.get(r.nameWithOwner.toLowerCase())?.note) return false; // a human wrote it
    const hit = cache[r.nameWithOwner];
    return !hit || hit.ref !== gh.refOf(r); // unseen, or moved since we looked
  });

  if (!noLlm && needs.length > 0) {
    const model = modelFromEnv();
    say(`describing ${needs.length} plugins with ${model.provider}/${model.model} (thinking: ${model.thinking || "pi's default"})\n`);
    const docs = await gh.docHeads(needs, auth);
    let done = 0;
    let failed = 0;
    // Eight at a time: each is its own pi process, and the provider's rate limit
    // rather than this machine is what the number is chosen against.
    const queue = [...needs];
    await Promise.all(
      Array.from({ length: 8 }, async () => {
        for (;;) {
          const repo = queue.shift();
          if (!repo) return;
          const blurb = await describe(
            repo,
            docs.get(repo.nameWithOwner.toLowerCase()) ?? null,
            model,
            (name, why) => {
              failed++;
              // The first few in full, then a count: a misconfigured provider
              // fails on every plugin, and 2,000 identical lines would bury the
              // one line that says which.
              if (failed <= 5) say(`\n  skipped ${name}: ${why}\n`);
            },
          );
          if (blurb) cache[repo.nameWithOwner] = blurb;
          // Written as it goes, not only at the end: every blurb here is paid
          // for, and a run cancelled or timed out an hour in should keep the
          // hour. CI uploads whatever is on disk however the job ends.
          if (++done % 50 === 0) saveCache(CACHE, cache);
          say(`\r  described ${done}/${needs.length}`);
        }
      }),
    );
    say(`\n  ${failed} could not be described and fall back to their GitHub description\n`);
    saveCache(CACHE, cache);
  } else if (needs.length > 0) {
    say(`skipping ${needs.length} blurbs (--no-llm)\n`);
  }

  // --- assemble -------------------------------------------------------------
  // Built beside the target and moved onto it at the end. Opening `out`
  // directly would find last week's tables already there — and a crash here
  // would leave a half-written file where a whole one used to be.
  const staging = `${out}.building`;
  rmSync(staging, { force: true });
  const db = new DatabaseSync(staging);
  db.exec("pragma journal_mode = off");
  db.exec(SCHEMA);

  const insPlugin = db.prepare(
    `insert into plugin (full_name, owner, repo, description, blurb, blurb_source, keywords,
       homepage, stars, forks, open_issues, pushed_at, created_at, archived, superseded_by,
       license, ref, topics, modules, has_colors, has_doc)
     values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
  );
  const insCategory = db.prepare("insert or ignore into category (name) values (?)");
  const getCategory = db.prepare("select id from category where name = ?");
  const insMember = db.prepare("insert or ignore into plugin_category values (?,?)");
  const insFts = db.prepare("insert into plugin_fts (rowid, full_name, blurb, keywords, description) values (?,?,?,?,?)");
  const insEdge = db.prepare("insert or ignore into edge values (?,?,?,?)");

  const ids = new Map<string, number>();
  const readmes = new Map<string, string>();
  const counts = { awesome: 0, generated: 0, github: 0 };

  db.exec("begin");
  for (const repo of keep) {
    const key = repo.nameWithOwner.toLowerCase();
    const seed = curatedBy.get(key);
    const cached = cache[repo.nameWithOwner];

    let blurb: string | null = null;
    let source: string;
    let keywords: string[] = [];
    let category: string | null = null;
    let supersededBy: string | null = null;

    if (seed?.note) {
      blurb = seed.note;
      source = "awesome";
      category = seed.category;
      counts.awesome++;
    } else if (cached) {
      blurb = cached.blurb;
      source = "generated";
      keywords = cached.keywords;
      category = cached.category;
      supersededBy = cached.superseded_by ?? null;
      counts.generated++;
    } else {
      blurb = repo.description;
      source = "github";
      category = seed?.category ?? null;
      counts.github++;
    }

    const top = new Set((repo.tree?.entries ?? []).map((e) => e.name));
    const modules = (repo.luaTree?.entries ?? []).map((e) => e.name.replace(/\.lua$/, ""));
    const [owner, name] = repo.nameWithOwner.split("/");

    const id = Number(
      insPlugin.run(
        repo.nameWithOwner, owner, name, repo.description, blurb, source, JSON.stringify(keywords),
        repo.homepageUrl, repo.stargazerCount, repo.forkCount, repo.issues.totalCount,
        repo.pushedAt, repo.createdAt, repo.isArchived ? 1 : 0, supersededBy,
        repo.licenseInfo?.spdxId ?? null,
        gh.refOf(repo), JSON.stringify(repo.repositoryTopics.nodes.map((n) => n.topic.name)),
        JSON.stringify(modules), top.has("colors") ? 1 : 0, top.has("doc") ? 1 : 0,
      ).lastInsertRowid,
    );
    ids.set(key, id);
    insFts.run(id, repo.nameWithOwner, blurb ?? "", keywords.join(" "), repo.description ?? "");

    if (category) {
      insCategory.run(category);
      insMember.run(id, (getCategory.get(category) as { id: number }).id);
    }
    // Kept in memory for the edge pass, then dropped: the README is build
    // input, never artifact content.
    const text = repo.readme?.text ?? repo.readmeLower?.text ?? "";
    if (text) readmes.set(key, text);
  }
  db.exec("commit");

  db.exec("begin");
  let named = 0;
  let declared = 0;
  for (const [key, id] of ids) {
    const repo = key.split("/")[1];
    for (const [prefix, hub] of Object.entries(HUBS)) {
      const target = ids.get(hub.toLowerCase());
      if (target && target !== id && repo.startsWith(prefix)) {
        insEdge.run(id, target, "extends", "naming");
        named++;
      }
    }
    for (const dep of dependencies(readmes.get(key) ?? "")) {
      const target = ids.get(dep.toLowerCase());
      if (target && target !== id) {
        insEdge.run(id, target, "depends", "lazy-spec");
        declared++;
      }
    }
  }
  db.exec("commit");

  const meta = db.prepare("insert into meta values (?,?)");
  meta.run("built_at", new Date().toISOString());
  meta.run("plugins", String(ids.size));
  meta.run("schema", SCHEMA_VERSION);
  db.exec("vacuum");
  db.close();
  renameSync(staging, out);

  say(
    `wrote ${out}: ${ids.size} plugins ` +
      `(${counts.awesome} curated, ${counts.generated} generated, ${counts.github} description only), ` +
      `${declared} declared edges, ${named} naming edges\n`,
  );
}

await main();

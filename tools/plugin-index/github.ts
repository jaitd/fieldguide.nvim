// Everything the index knows before a model sees it.
//
// Two sources, deliberately unequal. awesome-neovim is a curated list with a
// category taxonomy and a human-written line per plugin, and a human line is
// better than a generated one — it is kept, never regenerated. The topic sweep
// is the long tail: wider, unlabelled, and the reason the blurb pipeline exists.
//
// No dependencies: `fetch` is built in, which is what keeps this repo free of a
// package.json.

import { execFileSync } from "node:child_process";

const AWESOME = "https://raw.githubusercontent.com/rockerBOO/awesome-neovim/main/README.md";
const GRAPHQL = "https://api.github.com/graphql";
const SEARCH = "https://api.github.com/search/repositories";

/** Below this a repo is overwhelmingly somebody's abandoned experiment. */
export const STAR_FLOOR = 10;

export type Seed = { full: string; category: string | null; note: string | null };

export function token(): string {
  const fromEnv = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (fromEnv) return fromEnv;
  try {
    return execFileSync("gh", ["auth", "token"], { encoding: "utf8" }).trim();
  } catch {
    throw new Error("no GitHub token: set GITHUB_TOKEN or run `gh auth login`");
  }
}

/** Parses the curated list into plugins, their category, and their blurb. */
export async function awesome(): Promise<Seed[]> {
  const md = await (await fetch(AWESOME)).text();
  const out: Seed[] = [];
  const seen = new Set<string>();
  let category = "Utility";

  for (const line of md.split("\n")) {
    const heading = line.match(/^#{2,4}\s+(.+?)\s*$/);
    if (heading) {
      category = heading[1].replace(/\s*\[.*$/, "").trim();
      continue;
    }
    const item = line.match(
      /^\s*[-*]\s+\[[^\]]+\]\(https:\/\/github\.com\/([^/)]+)\/([^/)#?]+?)\/?\)\s*[-–—]?\s*(.*)$/,
    );
    if (!item) continue;
    const full = `${item[1]}/${item[2]}`.replace(/\.git$/, "");
    if (seen.has(full.toLowerCase())) continue;
    seen.add(full.toLowerCase());
    out.push({ full, category, note: item[3].trim() || null });
  }
  return out;
}

/**
 * The long tail, by topic. Search caps out at 1,000 results per query however
 * you page it, so each topic is sliced by star band until every slice fits
 * under the cap. Sorting differently would not help: the cap is on the result
 * set, not the page.
 */
const SWEEP_RETRIES = 5;

/** Seconds the server asked us to wait, in ms, if it said. */
function retryAfter(res: Response): number | undefined {
  const header = res.headers.get("retry-after");
  if (header === null) return undefined;
  const seconds = Number(header);
  if (!Number.isFinite(seconds) || seconds <= 0) return undefined;
  return Math.min(seconds, 120) * 1000;
}

export async function sweep(auth: string): Promise<string[]> {
  const found = new Set<string>();
  const bands = [
    `stars:${STAR_FLOOR}..24`, `stars:25..49`, `stars:50..99`,
    `stars:100..299`, `stars:300..999`, `stars:>=1000`,
  ];
  for (const topic of ["neovim-plugin", "nvim-plugin", "nvim", "neovim-lua"]) {
    for (const band of bands) {
      let throttled = 0;
      for (let page = 1; page <= 10; page++) {
        const q = encodeURIComponent(`topic:${topic} ${band}`);
        const res = await fetch(`${SEARCH}?q=${q}&per_page=100&page=${page}`, {
          headers: { authorization: `bearer ${auth}`, accept: "application/vnd.github+json" },
        });
        if (res.status === 403 || res.status === 429) {
          // The search endpoint has its own much smaller budget than GraphQL.
          // A 403 that outlives a few waits is not the rate limiter, though:
          // it is a token that cannot search, and waiting on it would run
          // until the job timeout with nothing to show for it.
          if (++throttled > SWEEP_RETRIES) {
            throw new Error(
              `GitHub search ${res.status} for '${topic} ${band}' after ${SWEEP_RETRIES} waits: ` +
                (await res.text()).slice(0, 300),
            );
          }
          const wait = retryAfter(res) ?? 20_000;
          process.stderr.write(`  search ${res.status}; waiting ${Math.round(wait / 1000)}s\n`);
          await new Promise((r) => setTimeout(r, wait));
          page--;
          continue;
        }
        if (!res.ok) break;
        throttled = 0;
        const body = (await res.json()) as { items?: { full_name: string; fork: boolean }[] };
        for (const item of body.items ?? []) {
          if (!item.fork) found.add(item.full_name);
        }
        if ((body.items?.length ?? 0) < 100) break;
      }
    }
  }
  return [...found];
}

export type Repo = {
  nameWithOwner: string;
  description: string | null;
  homepageUrl: string | null;
  stargazerCount: number;
  forkCount: number;
  isArchived: boolean;
  isFork: boolean;
  pushedAt: string | null;
  createdAt: string | null;
  licenseInfo: { spdxId: string | null } | null;
  defaultBranchRef: { name: string; target: { oid: string } | null } | null;
  repositoryTopics: { nodes: { topic: { name: string } }[] };
  issues: { totalCount: number };
  releases: { nodes: { tagName: string }[] };
  tags: { nodes: { name: string }[] };
  tree: { entries: { name: string; type: string }[] } | null;
  luaTree: { entries: { name: string; type: string }[] } | null;
  docTree: { entries: { name: string; type: string }[] } | null;
  readme: { text?: string } | null;
  readmeLower: { text?: string } | null;
};

// The tree fields are what let a blurb be written from the code rather than
// from the prose about it. `colors/` means colorscheme and nothing else;
// `lua/<name>/` is the module listing, which for a plugin like gitsigns
// (blame.lua, hunks.lua, diffthis.lua) describes it better than its README.
const FRAGMENT = `
fragment R on Repository {
  nameWithOwner description homepageUrl stargazerCount forkCount
  isArchived isFork pushedAt createdAt
  licenseInfo { spdxId }
  defaultBranchRef { name target { oid } }
  repositoryTopics(first: 20) { nodes { topic { name } } }
  issues(states: OPEN) { totalCount }
  releases(first: 1, orderBy: { field: CREATED_AT, direction: DESC }) { nodes { tagName } }
  tags: refs(refPrefix: "refs/tags/", first: 1, orderBy: { field: TAG_COMMIT_DATE, direction: DESC }) { nodes { name } }
  tree: object(expression: "HEAD:") { ... on Tree { entries { name type } } }
  luaTree: object(expression: "HEAD:lua") { ... on Tree { entries { name type } } }
  docTree: object(expression: "HEAD:doc") { ... on Tree { entries { name type } } }
  readme: object(expression: "HEAD:README.md") { ... on Blob { text } }
  readmeLower: object(expression: "HEAD:readme.md") { ... on Blob { text } }
}`;

type Posted<T> = { ok: true; data: T } | { ok: false; status: number | null; why: string };

/**
 * One GraphQL request, read to the end. A query GitHub gives up on does not
 * always come back as a 502: sometimes the connection is simply closed, often
 * mid-body after the status already said 200, and `fetch` throws. Both are the
 * same event, so both come back here as a failure (`status: null` for the
 * dropped connection) rather than one of them escaping as an exception that
 * takes the whole build down with it.
 */
async function graphql<T>(query: string, auth: string): Promise<Posted<T>> {
  try {
    const res = await fetch(GRAPHQL, {
      method: "POST",
      headers: { authorization: `bearer ${auth}`, "content-type": "application/json" },
      body: JSON.stringify({ query }),
      // GitHub stops a query at about ten seconds; a socket still open long
      // after that is not coming back, and would otherwise hold the job until
      // its timeout.
      signal: AbortSignal.timeout(60_000),
    });
    if (!res.ok) return { ok: false, status: res.status, why: (await res.text()).slice(0, 300) };
    const body = (await res.json()) as { data?: T };
    return { ok: true, data: body.data ?? ({} as T) };
  } catch (err) {
    const cause = (err as { cause?: { message?: string } }).cause?.message;
    return { ok: false, status: null, why: [(err as Error).message, cause].filter(Boolean).join(": ") };
  }
}

/**
 * Twenty-five per request. The trees and READMEs travel in the same response
 * and GitHub answers an oversized query with a 502 or a dropped connection, so
 * a failed batch is halved and retried rather than abandoned — an unattended
 * weekly run has to expect it.
 */
export async function enrich(
  names: string[],
  auth: string,
  onProgress?: (done: number, total: number) => void,
): Promise<Map<string, Repo>> {
  const found = new Map<string, Repo>();
  const BATCH = 25;
  for (let i = 0; i < names.length; i += BATCH) {
    await batch(names.slice(i, i + BATCH), auth, found, 0);
    onProgress?.(Math.min(i + BATCH, names.length), names.length);
  }
  return found;
}

async function batch(slice: string[], auth: string, into: Map<string, Repo>, depth: number): Promise<void> {
  const aliases = slice
    .map((full, n) => {
      const [owner, repo] = full.split("/");
      return `r${n}: repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(repo)}) { ...R }`;
    })
    .join("\n");

  let res: Posted<Record<string, Repo | null>> | undefined;
  for (let attempt = 1; attempt <= 3; attempt++) {
    res = await graphql(`query {\n${aliases}\n}\n${FRAGMENT}`, auth);
    if (res.ok) break;
    // A dropped connection or a 5xx is GitHub having a moment; 403 and 429 are
    // the rate limiter asking for quiet. Any other 4xx is a bug in the query,
    // and retrying wastes quota.
    const { status } = res;
    if (!(status === null || status >= 500 || status === 403 || status === 429)) {
      throw new Error(`GitHub GraphQL ${status}: ${res.why}`);
    }
    if (attempt < 3) await new Promise((r) => setTimeout(r, 2000 * 2 ** (attempt - 1)));
  }

  if (!res!.ok) {
    const what = res!.status === null ? res!.why : `GraphQL ${res!.status}`;
    if (slice.length === 1 || depth >= 4) {
      process.stderr.write(`\n  giving up on ${slice.join(", ")}: ${what}\n`);
      return;
    }
    process.stderr.write(`\n  ${what}; splitting a batch of ${slice.length}\n`);
    const half = Math.ceil(slice.length / 2);
    await batch(slice.slice(0, half), auth, into, depth + 1);
    await batch(slice.slice(half), auth, into, depth + 1);
    return;
  }

  for (const repo of Object.values(res!.data)) {
    // A null alias is a repo that moved, went private, or was deleted. Counted
    // at the end rather than aborting: a dead link must not cost the index.
    if (repo?.nameWithOwner) into.set(repo.nameWithOwner.toLowerCase(), repo);
  }
}

/** The ref a blurb describes: a release where there is one, else the commit. */
export function refOf(repo: Repo): string {
  return (
    repo.releases.nodes[0]?.tagName ??
    repo.tags.nodes[0]?.name ??
    repo.defaultBranchRef?.target?.oid?.slice(0, 12) ??
    "HEAD"
  );
}

/**
 * The head of a plugin's own help file, for the repos about to be described.
 * A second pass because doc filenames vary and cannot be guessed in the first;
 * it runs only for what still needs a blurb, which after the cache is a small
 * fraction of the corpus.
 *
 * An author writing `:help my-plugin` is explaining their work to a user, which
 * makes it the most useful prose in the repository and the least like a pitch.
 */
export async function docHeads(
  repos: Repo[],
  auth: string,
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const wanted = repos
    .map((r) => ({ repo: r, file: (r.docTree?.entries ?? []).find((e) => /\.(txt|nvim)$/.test(e.name))?.name }))
    .filter((w): w is { repo: Repo; file: string } => Boolean(w.file));

  const BATCH = 25;
  for (let i = 0; i < wanted.length; i += BATCH) {
    const slice = wanted.slice(i, i + BATCH);
    const aliases = slice
      .map((w, n) => {
        const [owner, repo] = w.repo.nameWithOwner.split("/");
        return `d${n}: repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(repo)}) {
          nameWithOwner
          doc: object(expression: ${JSON.stringify(`HEAD:doc/${w.file}`)}) { ... on Blob { text } } }`;
      })
      .join("\n");
    // Best effort: a batch that fails costs those plugins their help text, and
    // the blurb is written from the README and trees instead.
    const res = await graphql<Record<string, { nameWithOwner: string; doc: { text?: string } | null } | null>>(
      `query {\n${aliases}\n}`,
      auth,
    );
    if (!res.ok) continue;
    for (const entry of Object.values(res.data)) {
      const text = entry?.doc?.text;
      if (entry && text) out.set(entry.nameWithOwner.toLowerCase(), text.slice(0, 4000));
    }
  }
  return out;
}

// Fetching and replacing the plugin index.
//
//   node extension/index-fetch.ts <dest> [--repo owner/name] [--max-age-days N]
//
// Blue-green, because the extension holds the index open for the life of a
// session. Writing into that file — curl -o over it, gunzip on top of it —
// mutates a database under a live reader and surfaces as SQLITE_CORRUPT in the
// middle of somebody's conversation. So nothing is ever written in place: the
// download lands on a sibling temp file, is verified there, and only then
// replaces the target with rename(2).
//
// rename is atomic and does not disturb an open descriptor. A session that is
// already running keeps the inode it opened and finishes on the index it
// started with; the next session opens the new one. The old deployment drains
// rather than being shot. Nothing hot-swaps mid-session on purpose either: an
// agent whose earlier and later tool results come from different datasets is a
// subtler wrong answer than one that is a week behind.
//
// The temp file is a sibling rather than /tmp because rename is only atomic
// within a filesystem. On Windows renaming over an open file fails outright,
// which reports rather than corrupts — the right failure for a project that
// already assumes bwrap or seatbelt.

import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, rename, rm, readFile, writeFile, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { createGunzip } from "node:zlib";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";
import { dirname, basename, join } from "node:path";
import { Index, UnreadableIndex, READS_SCHEMA } from "./plugins.ts";

const DEFAULT_REPO = "jaitd/fieldguide.nvim";

/**
 * A build asks for the schema major it reads, never for "the newest". A
 * refresh that pulled a file this build cannot open would take working tools
 * away from someone who only asked to be up to date.
 */
export function assetUrl(repo: string, name: string, reads = READS_SCHEMA, base = GITHUB): string {
  const major = reads.split(".")[0];
  return `${base}/${repo}/releases/download/fg-plugin-index-v${major}/${name}`;
}

const GITHUB = "https://github.com";

/** Below this the crawl clearly failed, whatever the file says about itself. */
const MIN_PLUGINS = 1500;

export type Outcome =
  | { status: "current"; reason: string; built_at?: string }
  | { status: "installed"; built_at: string; schema: string; plugins: number }
  | { status: "failed"; reason: string };

async function fetchText(url: string): Promise<string | null> {
  const res = await fetch(url, { redirect: "follow" });
  return res.ok ? (await res.text()).trim() : null;
}

/**
 * The digest is served by the same host as the file, so it is a check against a
 * truncated or corrupted transfer, not against a hostile GitHub. Saying so
 * plainly is better than implying an integrity guarantee this does not have.
 */
function digestOf(text: string): string {
  return text.split(/\s+/)[0].toLowerCase();
}

export async function fetchIndex(opts: {
  dest: string;
  repo?: string;
  maxAgeDays?: number;
  /** Overridden only by the tests, which serve the same paths from localhost. */
  baseUrl?: string;
}): Promise<Outcome> {
  const repo = opts.repo || DEFAULT_REPO;
  const host = opts.baseUrl || GITHUB;
  const dir = dirname(opts.dest);
  const base = basename(opts.dest);
  const stamp = join(dir, `${base}.sha256`);
  const gz = join(dir, `${base}.download`);
  const staged = join(dir, `${base}.staged`);

  await mkdir(dir, { recursive: true });

  // An index younger than the caller's threshold is left alone without a single
  // request. Freshness is a fact inside the file, not something to ask about.
  if (opts.maxAgeDays !== undefined) {
    const age = await ageInDays(opts.dest);
    if (age !== null && age < opts.maxAgeDays) {
      return { status: "current", reason: `index is ${age.toFixed(1)} days old` };
    }
  }

  const wanted = await fetchText(assetUrl(repo, "nvim-plugins.db.gz.sha256", READS_SCHEMA, host));
  if (wanted === null) {
    return {
      status: "failed",
      reason: `no index published for schema ${READS_SCHEMA.split(".")[0]}.x — update fieldguide`,
    };
  }
  const want = digestOf(wanted);

  // The digest is a few bytes and the index is megabytes, so asking for it
  // first turns "is there anything new" into a free question. With the
  // publisher replacing the asset only on a material change, an unchanged
  // digest means there is genuinely nothing to download.
  const have = await readFile(stamp, "utf8").catch(() => null);
  if (have?.trim() === want && (await exists(opts.dest))) {
    return { status: "current", reason: "already holding the published index" };
  }

  try {
    const res = await fetch(assetUrl(repo, "nvim-plugins.db.gz", READS_SCHEMA, host), { redirect: "follow" });
    if (!res.ok || !res.body) return { status: "failed", reason: `download failed: HTTP ${res.status}` };

    const hash = createHash("sha256");
    const body = Readable.fromWeb(res.body as never);
    body.on("data", (chunk) => hash.update(chunk));
    await pipeline(body, createWriteStream(gz));

    const got = hash.digest("hex");
    if (got !== want) {
      return { status: "failed", reason: `digest mismatch — got ${got.slice(0, 12)}, expected ${want.slice(0, 12)}` };
    }

    await gunzipTo(gz, staged);

    // Verified with the class that will read it in anger, so "verified" means
    // the consumer can open it rather than that it parsed as some SQLite file.
    const check = inspect(staged);
    if (check.problem) return { status: "failed", reason: check.problem };

    // The one irreversible step, and the last one. Everything above can fail
    // without the live index having been touched.
    await rename(staged, opts.dest);
    await writeFile(stamp, want + "\n");
    return { status: "installed", built_at: check.built_at!, schema: check.schema!, plugins: check.plugins! };
  } finally {
    await rm(gz, { force: true });
    await rm(staged, { force: true });
  }
}

async function gunzipTo(from: string, to: string): Promise<void> {
  await pipeline(createReadStream(from), createGunzip(), createWriteStream(to));
}

function inspect(path: string): { problem?: string; built_at?: string; schema?: string; plugins?: number } {
  let ix: Index | undefined;
  try {
    ix = new Index(path);
    const meta = ix.built();
    const plugins = ix.count();
    if (plugins < MIN_PLUGINS) return { problem: `only ${plugins} plugins in the download — refusing it` };
    return { built_at: meta.built_at, schema: meta.schema, plugins };
  } catch (e) {
    if (e instanceof UnreadableIndex) return { problem: e.message };
    return { problem: `not a readable index: ${(e as Error).message}` };
  } finally {
    ix?.close();
  }
}

async function ageInDays(path: string): Promise<number | null> {
  try {
    const ix = new Index(path);
    const built = ix.built().built_at;
    ix.close();
    if (!built) return null;
    const ms = Date.now() - new Date(built).getTime();
    return Number.isNaN(ms) ? null : ms / 864e5;
  } catch {
    return null;
  }
}

async function exists(path: string): Promise<boolean> {
  return stat(path).then(
    () => true,
    () => false,
  );
}

if (process.argv[1] && import.meta.url.endsWith(basename(process.argv[1]))) {
  const args = process.argv.slice(2);
  const flag = (name: string): string | undefined => {
    const i = args.indexOf(`--${name}`);
    return i === -1 ? undefined : args[i + 1];
  };
  const flagged = new Set<string>();
  for (const name of ["repo", "max-age-days"]) {
    const i = args.indexOf(`--${name}`);
    if (i !== -1) {
      flagged.add(args[i]);
      flagged.add(args[i + 1]);
    }
  }
  const dest = args.find((a) => !flagged.has(a) && !a.startsWith("--"));
  if (!dest) {
    process.stderr.write("usage: index-fetch.ts <dest> [--repo owner/name] [--max-age-days N]\n");
    process.exit(2);
  }
  const maxAge = flag("max-age-days");
  const out = await fetchIndex({
    dest,
    repo: flag("repo"),
    maxAgeDays: maxAge === undefined ? undefined : Number(maxAge),
  });
  process.stdout.write(JSON.stringify(out) + "\n");
  process.exit(out.status === "failed" ? 1 : 0);
}

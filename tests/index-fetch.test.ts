// Replacing the index under a running session (§12).
//
// The extension holds the index open for the life of a session, so the whole
// question here is whether an update can hurt someone mid-conversation. These
// tests hold a reader open across a swap and assert it never notices.

import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { createServer } from "node:http";
import { gzipSync } from "node:zlib";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Index } from "../extension/plugins.ts";
import { fetchIndex, assetUrl } from "../extension/index-fetch.ts";

const SCHEMA = `
create table plugin (id integer primary key, full_name text not null unique, owner text not null,
  repo text not null, description text, blurb text, blurb_source text not null,
  keywords text not null default '[]', homepage text, stars integer not null default 0,
  forks integer not null default 0, open_issues integer not null default 0, pushed_at text,
  created_at text, archived integer not null default 0, superseded_by text, license text,
  ref text, topics text, modules text not null default '[]', has_colors integer not null default 0,
  has_doc integer not null default 0);
create table category (id integer primary key, name text not null unique);
create table plugin_category (plugin_id integer not null, category_id integer not null,
  primary key (plugin_id, category_id));
create table edge (src integer not null, dst integer not null, kind text not null,
  evidence text not null, primary key (src, dst, kind));
create virtual table plugin_fts using fts5(full_name, blurb, keywords, description,
  content = '', tokenize = 'porter unicode61');
create table meta (key text primary key, value text);
`;

/** An index of `n` plugins, named so a reader can tell two of them apart. */
function makeIndex(path: string, marker: string, n = 1600, schema = "1.0.0"): void {
  const db = new DatabaseSync(path);
  db.exec(SCHEMA);
  db.exec("begin");
  const ins = db.prepare(
    "insert into plugin (full_name, owner, repo, blurb, blurb_source, stars, pushed_at) values (?,?,?,?,?,?,?)",
  );
  const fts = db.prepare("insert into plugin_fts (rowid, full_name, blurb, keywords, description) values (?,?,?,?,?)");
  for (let i = 0; i < n; i++) {
    const name = `${marker}/plugin-${i}`;
    const id = Number(ins.run(name, marker, `plugin-${i}`, `${marker} blurb`, "generated", 100, "2026-01-01").lastInsertRowid);
    fts.run(id, name, `${marker} blurb`, "", "");
  }
  db.exec("commit");
  db.prepare("insert into meta values (?,?)").run("built_at", new Date().toISOString());
  db.prepare("insert into meta values (?,?)").run("schema", schema);
  db.prepare("insert into meta values (?,?)").run("marker", marker);
  db.close();
}

/** Serves the two release assets the fetcher asks for, from localhost. */
async function serving(gzBody: Buffer, opts: { corruptDigest?: boolean } = {}) {
  const digest = opts.corruptDigest ? "0".repeat(64) : createHash("sha256").update(gzBody).digest("hex");
  const server = createServer((req, res) => {
    if (req.url?.endsWith(".sha256")) {
      res.writeHead(200).end(`${digest}  nvim-plugins.db.gz\n`);
    } else if (req.url?.endsWith(".gz")) {
      res.writeHead(200).end(gzBody);
    } else {
      res.writeHead(404).end();
    }
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;
  return { base: `http://127.0.0.1:${port}`, close: () => server.close() };
}

function scratch(): { dir: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "fg-fetch-"));
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test("a running session keeps the index it opened when a new one is installed", async () => {
  const { dir, cleanup } = scratch();
  try {
    const dest = join(dir, "nvim-plugins.db");
    makeIndex(dest, "before");

    // A session, mid-conversation, holding the file open.
    const live = new Index(dest);
    assert.equal(live.built().marker, "before");

    const fresh = join(dir, "fresh.db");
    makeIndex(fresh, "after");
    const srv = await serving(gzipSync(readFileSync(fresh)));
    try {
      const out = await fetchIndex({ dest, baseUrl: srv.base });
      assert.equal(out.status, "installed");
    } finally {
      srv.close();
    }

    // The point of the whole exercise: rename(2) left this descriptor pointing
    // at the inode it opened. The session finishes on the data it started with.
    assert.equal(live.built().marker, "before");
    assert.equal(live.search("before blurb").length > 0, true, "and it still answers queries");
    live.close();

    // The next session gets the new one.
    const next = new Index(dest);
    assert.equal(next.built().marker, "after");
    next.close();
  } finally {
    cleanup();
  }
});

test("a corrupted download never replaces a working index", async () => {
  const { dir, cleanup } = scratch();
  try {
    const dest = join(dir, "nvim-plugins.db");
    makeIndex(dest, "good");

    const srv = await serving(gzipSync(Buffer.from("this is not a database")), { corruptDigest: false });
    try {
      const out = await fetchIndex({ dest, baseUrl: srv.base });
      assert.equal(out.status, "failed");
    } finally {
      srv.close();
    }

    const still = new Index(dest);
    assert.equal(still.built().marker, "good", "the live index was never touched");
    still.close();
  } finally {
    cleanup();
  }
});

test("a digest that does not match is refused before anything is unpacked", async () => {
  const { dir, cleanup } = scratch();
  try {
    const dest = join(dir, "nvim-plugins.db");
    makeIndex(dest, "good");
    const fresh = join(dir, "fresh.db");
    makeIndex(fresh, "after");

    const srv = await serving(gzipSync(readFileSync(fresh)), { corruptDigest: true });
    try {
      const out = await fetchIndex({ dest, baseUrl: srv.base });
      assert.equal(out.status, "failed");
      assert.match((out as { reason: string }).reason, /digest mismatch/);
    } finally {
      srv.close();
    }

    const still = new Index(dest);
    assert.equal(still.built().marker, "good");
    still.close();
  } finally {
    cleanup();
  }
});

test("an index this build cannot read is refused rather than installed", async () => {
  const { dir, cleanup } = scratch();
  try {
    const dest = join(dir, "nvim-plugins.db");
    makeIndex(dest, "good");
    const fresh = join(dir, "fresh.db");
    makeIndex(fresh, "after", 1600, "2.0.0");

    const srv = await serving(gzipSync(readFileSync(fresh)));
    try {
      const out = await fetchIndex({ dest, baseUrl: srv.base });
      assert.equal(out.status, "failed");
      assert.match((out as { reason: string }).reason, /schema 2\.0\.0/);
    } finally {
      srv.close();
    }

    const still = new Index(dest);
    assert.equal(still.built().marker, "good");
    still.close();
  } finally {
    cleanup();
  }
});

test("a half-crawled index is refused however valid the file is", async () => {
  const { dir, cleanup } = scratch();
  try {
    const dest = join(dir, "nvim-plugins.db");
    const fresh = join(dir, "fresh.db");
    makeIndex(fresh, "thin", 40);

    const srv = await serving(gzipSync(readFileSync(fresh)));
    try {
      const out = await fetchIndex({ dest, baseUrl: srv.base });
      assert.equal(out.status, "failed");
      assert.match((out as { reason: string }).reason, /only 40 plugins/);
    } finally {
      srv.close();
    }
    assert.equal(existsSync(dest), false, "and nothing was left behind");
  } finally {
    cleanup();
  }
});

test("the published digest is asked for first, so an unchanged index costs nothing", async () => {
  const { dir, cleanup } = scratch();
  try {
    const dest = join(dir, "nvim-plugins.db");
    const fresh = join(dir, "fresh.db");
    makeIndex(fresh, "same");
    const body = gzipSync(readFileSync(fresh));

    let gzRequests = 0;
    const digest = createHash("sha256").update(body).digest("hex");
    const server = createServer((req, res) => {
      if (req.url?.endsWith(".sha256")) res.writeHead(200).end(`${digest}\n`);
      else {
        gzRequests++;
        res.writeHead(200).end(body);
      }
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
    try {
      assert.equal((await fetchIndex({ dest, baseUrl: base })).status, "installed");
      assert.equal(gzRequests, 1);
      const again = await fetchIndex({ dest, baseUrl: base });
      assert.equal(again.status, "current");
      assert.equal(gzRequests, 1, "the second run downloaded nothing");
    } finally {
      server.close();
    }
  } finally {
    cleanup();
  }
});

test("a young index is not even asked about", async () => {
  const { dir, cleanup } = scratch();
  try {
    const dest = join(dir, "nvim-plugins.db");
    makeIndex(dest, "young");
    // No server at all: any request would fail the test by failing the fetch.
    const out = await fetchIndex({ dest, baseUrl: "http://127.0.0.1:1", maxAgeDays: 14 });
    assert.equal(out.status, "current");
    assert.match((out as { reason: string }).reason, /days old/);
  } finally {
    cleanup();
  }
});

test("a build asks for its own schema major, never for whatever is newest", () => {
  assert.equal(
    assetUrl("o/r", "nvim-plugins.db.gz", "1.4.2"),
    "https://github.com/o/r/releases/download/index-v1/nvim-plugins.db.gz",
  );
  assert.equal(
    assetUrl("o/r", "nvim-plugins.db.gz", "2.0.0"),
    "https://github.com/o/r/releases/download/index-v2/nvim-plugins.db.gz",
  );
});

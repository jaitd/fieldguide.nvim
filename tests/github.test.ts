// The crawl's GitHub client (§12).
//
// An unattended weekly run meets GitHub at its worst: queries it gives up on,
// connections it closes halfway through a response. None of that may cost the
// build more than the handful of repos it was about, so these tests stand in
// for GitHub with a `fetch` that misbehaves on cue.

import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { enrich, docHeads, type Repo } from "../tools/plugin-index/github.ts";

function repo(full: string): Repo {
  return {
    nameWithOwner: full, description: null, homepageUrl: null, stargazerCount: 10, forkCount: 0,
    isArchived: false, isFork: false, pushedAt: null, createdAt: null, licenseInfo: null,
    defaultBranchRef: null, repositoryTopics: { nodes: [] }, issues: { totalCount: 0 },
    releases: { nodes: [] }, tags: { nodes: [] }, tree: null, luaTree: null, docTree: null,
    readme: null, readmeLower: null,
  };
}

/** Answers every alias in the query with its repo, as GitHub would. */
function answer(query: string): Response {
  const data: Record<string, Repo> = {};
  for (const m of query.matchAll(/(r\d+): repository\(owner: "([^"]+)", name: "([^"]+)"\)/g)) {
    data[m[1]] = repo(`${m[2]}/${m[3]}`);
  }
  return Response.json({ data });
}

/** A 200 whose body stops partway, the way undici reports a closed socket. */
function cutOff(): Response {
  const body = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode('{"data":{"r0":{"nameWith'));
      c.error(new TypeError("terminated", { cause: new Error("other side closed") }));
    },
  });
  return new Response(body, { status: 200 });
}

/**
 * Runs `fn` with `fetch` replaced and the retry backoff fast-forwarded, so a
 * test that retries does not also sit through the waits.
 */
async function withGitHub<T>(handler: (query: string) => Response | Promise<Response>, fn: () => Promise<T>): Promise<T> {
  const real = globalThis.fetch;
  const stderr = process.stderr.write;
  globalThis.fetch = (async (_url: string, init: RequestInit) =>
    handler(JSON.parse(init.body as string).query)) as typeof fetch;
  process.stderr.write = (() => true) as typeof process.stderr.write;
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const p = fn();
    let settled = false;
    p.then(() => (settled = true), () => (settled = true));
    while (!settled) {
      await new Promise((r) => setImmediate(r));
      mock.timers.tick(60_000);
    }
    return await p;
  } finally {
    mock.timers.reset();
    process.stderr.write = stderr;
    globalThis.fetch = real;
  }
}

test("a connection closed mid-response is retried, not fatal", async () => {
  let calls = 0;
  const found = await withGitHub(
    (q) => (++calls === 1 ? cutOff() : answer(q)),
    () => enrich(["a/one", "b/two"], "token"),
  );
  assert.equal(calls, 2);
  assert.deepEqual([...found.keys()].sort(), ["a/one", "b/two"]);
});

test("a repo whose query always drops the connection costs only its own pair", async () => {
  const names = Array.from({ length: 30 }, (_, i) => `owner/p${i}`);
  const found = await withGitHub(
    (q) => {
      if (q.includes('name: "p7"')) throw new TypeError("fetch failed", { cause: new Error("other side closed") });
      return answer(q);
    },
    () => enrich(names, "token"),
  );
  // Halving stops at a pair (depth 4 from a batch of 25), so the one repo that
  // shares the last split with it goes too. Everything else is kept.
  assert.equal(found.size, 28);
  assert.ok(!found.has("owner/p7"));
});

test("a query GitHub rejects as malformed still fails loudly", async () => {
  await assert.rejects(
    withGitHub(() => new Response("bad credentials", { status: 401 }), () => enrich(["a/one"], "token")),
    /GitHub GraphQL 401/,
  );
});

test("help files are best effort when the connection drops", async () => {
  const withDoc = { ...repo("a/one"), docTree: { entries: [{ name: "one.txt", type: "blob" }] } };
  const docs = await withGitHub(() => cutOff(), () => docHeads([withDoc], "token"));
  assert.equal(docs.size, 0);
});

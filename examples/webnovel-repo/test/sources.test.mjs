import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadSource } from "../../../sdk/shelf-repo/lib/runner.mjs";

// Offline tests against saved pages. When the sites change, save fresh copies of the
// pages into fixtures/ and update the selectors until these pass again.

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = (name) => readFile(path.join(here, "fixtures", name), "utf8");

function fakeFetch(routes) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, ...init });
    for (const [pattern, reply] of routes) {
      if (pattern.test(url)) {
        const r = typeof reply === "function" ? await reply(url, init) : reply;
        return { status: r.status ?? 200, url, headers: Object.entries(r.headers ?? {}), text: async () => r.body ?? "" };
      }
    }
    return { status: 404, url, headers: [], text: async () => "" };
  };
  impl.calls = calls;
  return impl;
}

const nu = path.join(here, "../sources/novel-updates");
const sites = path.join(here, "../sources/translator-sites");

test("novel updates: search reads results and paging", async () => {
  const fetchImpl = fakeFetch([[/series-finder/, { body: await fixture("series-finder.html") }]]);
  const { call } = await loadSource(nu, { fetchImpl });
  const page = await call("search", "quiet", 1);
  assert.equal(page.hasMore, true);
  assert.equal(page.results.length, 2);
  assert.deepEqual(page.results[0].id, "the-quiet-cultivator");
  assert.equal(page.results[0].coverURL, "https://cdn.novelupdates.com/imgmid/series_10.jpg");
  assert.deepEqual(page.results[0].tags, ["Action", "Xianxia"]);
  assert.match(page.results[0].blurb, /live forever…$/);
  assert.equal(page.results[1].coverURL, undefined, "placeholder covers are dropped");
  assert.match(fetchImpl.calls[0].url, /sh=quiet&.*pg=1/);
});

test("novel updates: work page", async () => {
  const fetchImpl = fakeFetch([[/\/series\//, { body: await fixture("series.html") }]]);
  const { call } = await loadSource(nu, { fetchImpl });
  const work = await call("getWork", "the-quiet-cultivator");
  assert.equal(work.title, "The Quiet Cultivator");
  assert.deepEqual(work.authors, ["Mo Shan"]);
  assert.equal(work.status, "Completed");
  assert.equal(work.originalLanguage, "Chinese");
  assert.deepEqual(work.fandoms, ["Web Novel"]);
  assert.deepEqual(work.tags, ["Action", "Xianxia", "Calm Protagonist", "Farming"]);
  assert.match(work.summaryHTML, /jade slip/);
});

test("novel updates: chapters come oldest first, as links", async () => {
  const fetchImpl = fakeFetch([
    [/\/series\//, { body: await fixture("series.html") }],
    [/admin-ajax/, async (url, init) => {
      assert.equal(init.method, "POST");
      assert.match(init.body, /action=nd_getchapters/);
      assert.match(init.body, /mypostid=40213/);
      return { body: await fixture("chapters.html") };
    }],
  ]);
  const { call } = await loadSource(nu, { fetchImpl });
  const chapters = await call("getChapters", "the-quiet-cultivator");
  assert.deepEqual(chapters.map((c) => c.id), ["900001", "900002", "900003"]);
  assert.deepEqual(chapters.map((c) => c.number), [1, 2, 3]);
  assert.equal(chapters[1].title, "c2 part 1");
  assert.equal(chapters[0].link, "https://www.novelupdates.com/extnu/900001/");
});

test("novel updates: chapter content is the redirect target, not followed", async () => {
  const fetchImpl = fakeFetch([
    [/extnu\/900001/, { status: 302, headers: { Location: "https://quietcultivator.wordpress.com/2024/01/01/chapter-1/" } }],
    [/wordpress\.com/, () => assert.fail("the redirect should not be followed")],
  ]);
  const { call } = await loadSource(nu, { fetchImpl });
  assert.deepEqual(await call("getChapterContent", "the-quiet-cultivator", "900001"), {
    type: "link",
    url: "https://quietcultivator.wordpress.com/2024/01/01/chapter-1/",
  });
});

test("translator sites: keeps the story, drops navigation and sharing", async () => {
  const fetchImpl = fakeFetch([[/wordpress\.com/, { body: await fixture("chapter-wordpress.html") }]]);
  const { call, implements: has } = await loadSource(sites, { fetchImpl });
  assert.ok(has("resolveLink"));
  const content = await call("resolveLink", "https://quietcultivator.wordpress.com/2024/01/01/chapter-1/");
  assert.equal(content.type, "text");
  assert.equal((content.html.match(/Lin Feng/g) || []).length, 6);
  assert.match(content.html, /Translator's note/);
  assert.doesNotMatch(content.html, /Next Chapter|Previous|Share this|window\.ads|style=/);
});

test("translator sites: refuses hosts it didn't declare", async () => {
  const { call } = await loadSource(sites, { fetchImpl: fakeFetch([]) });
  await assert.rejects(call("resolveLink", "https://example.org/chapter-1"), /didn't declare/);
});

// node --test test/*.test.ts (Node 23+ runs the TypeScript as it is).
import assert from "node:assert/strict";
import { test } from "node:test";
import { identify, ModelError, verdict } from "../src/agent.ts";
import { details, related } from "../src/details.ts";
import { cacheKey, comparable, readSource } from "../src/source.ts";
import { TMDB, UpstreamError } from "../src/tmdb.ts";

const json = (value: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json", ...headers } });

// A Gemini that answers with the given turns in order, and records what it was sent.
function model(turns: any[][]) {
  const sent: any[] = [];
  const fetcher = async (_url: string, init?: RequestInit) => {
    sent.push(JSON.parse(String(init?.body)));
    const parts = turns.shift();
    if (!parts) return json({ error: "no more turns" }, 400);
    return json({ candidates: [{ content: { role: "model", parts } }], usageMetadata: { totalTokenCount: 100 } });
  };
  return { gemini: { key: "k", model: "m", fetcher }, sent };
}

const call = (name: string, args: unknown, id = name) => ({ functionCall: { name, args, id }, thoughtSignature: "sig-" + id });

test("TMDB text with a web address is left out", async () => {
  const tmdb = new TMDB("t", async () => json({ id: 1, name: "庆余年", tagline: "看片网：4488𝟰6𝟵.com", overview: "好看", vote_count: 0, seasons: [] }), null);
  const value = await details(tmdb, "tv", 1, "zh-CN", null);
  assert.equal(value!.tagline, "");
  assert.equal(value!.overview, "好看");
});

test("recommendations come first, then similar titles, each once and only with a poster", () => {
  const item = {
    id: 1,
    recommendations: { results: [
      { media_type: "movie", id: 2, title: "甲", poster_path: "/a.jpg", release_date: "2020-05-01" },
      { media_type: "tv", id: 3, name: "乙", poster_path: null },
      { media_type: "tv", id: 4, name: "丙", poster_path: "/c.jpg", adult: true },
      { media_type: "tv", id: 1, name: "本剧", poster_path: "/self.jpg" },
    ] },
    similar: { results: [
      { id: 5, name: "丁", original_name: "D", poster_path: "/d.jpg", first_air_date: "2019-01-01" },
      { id: 6, name: "看片网 x.com", poster_path: "/e.jpg" },
      { id: 7, name: "戊", poster_path: "/f.jpg" },
    ] },
  };
  const titles = related(item, "tv");
  assert.deepEqual(titles.map((title) => `${title.mediaType}:${title.id}`), ["movie:2", "tv:5", "tv:7"]);
  assert.equal(titles[0].year, 2020);
  assert.equal(titles[1].originalName, "D");
  assert.match(titles[1].poster, /^https:\/\/images\.tmdb\.org\/t\/p\/w342\/d\.jpg$/);
  assert.equal(related(item, "tv", 1).length, 1);
  assert.deepEqual(related({ id: 1 }, "movie"), []);
});

test("comparable keeps numbers and season words, drops width, case and spacing", () => {
  assert.equal(comparable("  亚瑟罗宾  第四季 "), "亚瑟罗宾 第四季");
  assert.equal(comparable("ＡＢＣ２"), "abc2");
  assert.notEqual(cacheKey({ title: "流浪地球" }), cacheKey({ title: "流浪地球2" }));
  assert.equal(cacheKey({ title: "Friends", year: "1994" }), cacheKey({ title: "FRIENDS ", year: "1994" }));
});

test("readSource needs a title and keeps only a four-digit year", () => {
  assert.equal(readSource({ title: "  " }), null);
  const source = readSource({ title: "繁花", year: "23年", type: "series", episodes: ["第1集", 3] })!;
  assert.equal(source.year, null);
  assert.equal(readSource({ title: "繁花", year: "2023年" })!.year, "2023");
  assert.equal(source.type, null);
  assert.deepEqual(source.episodes, ["第1集", ""]);
});

test("verdict only names works the tools showed, and needs confidence to match", () => {
  const seen = new Map<string, unknown>([["tv:1", {}], ["tv:2", {}], ["movie:3", {}]]);
  assert.equal(verdict({ status: "matched", mediaType: "tv", id: 99, confidence: 0.95 }, seen).status, "notFound");
  const weak = verdict({ status: "matched", mediaType: "tv", id: 1, confidence: 0.6, candidates: [{ mediaType: "tv", id: 2 }] }, seen);
  assert.equal(weak.status, "ambiguous");
  assert.deepEqual(weak.candidates, [{ mediaType: "tv", id: 1 }, { mediaType: "tv", id: 2 }]);
  const strong = verdict({ status: "matched", mediaType: "tv", id: 1, season: 4, confidence: 0.9, unmatched: "第四季" }, seen);
  assert.equal(strong.status, "matched");
  assert.equal(strong.season, 4);
  assert.equal(strong.unmatched, "第四季");
  assert.equal(verdict({ status: "matched", mediaType: "movie", id: 3, season: 2, confidence: 0.9 }, seen).season, null);
  assert.equal(verdict({ status: "matched", mediaType: "tv", id: 2, confidence: 0.9 }, seen).season, 1);
  assert.equal(verdict({ status: "matched", mediaType: "tv", id: 2, firstEpisode: 26, confidence: 0.9 }, seen).offset, 25);
  assert.equal(verdict({ status: "matched", mediaType: "tv", id: 2, firstEpisode: 1, confidence: 0.9 }, seen).offset, 0);
  assert.equal(verdict({ status: "matched", mediaType: "movie", id: 3, firstEpisode: 5, confidence: 0.9 }, seen).offset, 0);
});

test("identify searches, checks details, and submits", async () => {
  const requests: string[] = [];
  const tmdb = new TMDB("t", async (url) => {
    requests.push(url);
    if (url.includes("/search/tv")) return json({ page: 1, total_pages: 1, total_results: 1, results: [{ id: 7, name: "亚瑟罗宾", original_name: "Arthur", first_air_date: "2019-01-01" }] });
    if (url.includes("/tv/7?")) return json({ id: 7, name: "亚瑟罗宾", original_name: "Arthur", first_air_date: "2019-01-01", seasons: [{ season_number: 4, episode_count: 10 }] });
    return json({}, 404);
  }, null);
  const { gemini, sent } = model([
    [call("search", { query: "亚瑟罗宾", type: "tv" })],
    [call("details", { mediaType: "tv", id: 7 })],
    [call("submit", { status: "matched", mediaType: "tv", id: 7, season: 4, numbering: "season", confidence: 0.92, unmatched: "第四季", reason: "Name and season agree." })],
  ]);
  const events: any[] = [];
  const outcome = await identify({ title: "亚瑟罗宾第四季", episodes: ["第1集", "第2集"] }, tmdb, gemini, (event) => events.push(event));
  assert.equal(outcome.verdict.status, "matched");
  assert.equal(outcome.verdict.id, 7);
  assert.equal(outcome.turns, 3);
  assert.deepEqual(events.filter((event) => event.step !== "thinking"), [
    { step: "search", query: "亚瑟罗宾" },
    { step: "details", name: "亚瑟罗宾", year: 2019 },
  ]);
  assert.match(sent[0].contents[0].parts[0].text, /^Which TMDB work is this source video\?/);
  // The model's own turns go back with their thought signatures, each answer under its call's id.
  assert.equal(sent[1].contents[1].parts[0].thoughtSignature, "sig-search");
  assert.equal(sent[1].contents[2].parts[0].functionResponse.id, "search");
  assert.equal(requests.length, 2);
});

test("identify can answer before any search, for an AI-generated video", async () => {
  let requests = 0;
  const tmdb = new TMDB("t", async () => (requests++, json({ results: [] })), null);
  const { gemini, sent } = model([[call("submit", { status: "notFound", confidence: 0, reason: "AI-generated: 漫剧 category." })]]);
  const outcome = await identify({ title: "异变：辐射", category: "漫剧" }, tmdb, gemini, () => {});
  assert.equal(outcome.verdict.status, "notFound");
  assert.equal(requests, 0);
  assert.match(sent[0].contents[0].parts[0].text, /"category": "漫剧"/);
});

test("search results come with their first results' details, which the details tool reuses", async () => {
  const requests: string[] = [];
  const tmdb = new TMDB("t", async (url) => {
    requests.push(url);
    if (url.includes("/search/multi")) return json({ results: [1, 2, 3, 4].map((id) => ({ id, media_type: "movie", title: "繁花" + id })) });
    const id = Number(/\/movie\/(\d+)/.exec(url)?.[1]);
    return json({ id, title: "繁花" + id, original_title: "Blossoms", release_date: "2023-12-27", genres: [{ name: "剧情" }] });
  }, null);
  const { gemini, sent } = model([
    [call("search", { query: "繁花", type: "multi" })],
    [call("details", { mediaType: "movie", id: 2 })],
    [call("submit", { status: "matched", mediaType: "movie", id: 2, confidence: 0.9, reason: "x" })],
  ]);
  const outcome = await identify({ title: "繁花" }, tmdb, gemini, () => {});
  assert.equal(outcome.verdict.id, 2);
  // One search and the details of its first three results; the details call needed no request of its own.
  assert.equal(requests.length, 4);
  const shown = sent[1].contents[2].parts[0].functionResponse.response.result.results;
  assert.deepEqual(shown.map((item: any) => Boolean(item.genres)), [true, true, true, false]);
});

test("a cached prefix is named instead of sent, except on the last turn", async () => {
  const tmdb = new TMDB("t", async () => json({ results: [] }), null);
  const { gemini, sent } = model([[call("search", { query: "a", type: "tv" }, "a")], [call("submit", { status: "notFound", confidence: 0, reason: "none" })]]);
  await identify({ title: "x" }, tmdb, { ...gemini, cache: "cachedContents/abc" }, () => {}, { searches: 8, details: 6, seasons: 3, turns: 2 });
  assert.equal(sent[0].cachedContent, "cachedContents/abc");
  assert.equal(sent[0].systemInstruction, undefined);
  assert.equal(sent[0].tools, undefined);
  assert.equal(sent[1].cachedContent, undefined);
  assert.deepEqual(sent[1].toolConfig.functionCallingConfig.allowedFunctionNames, ["submit"]);
});

test("a run whose cache is gone carries on without it", async () => {
  const tmdb = new TMDB("t", async () => json({ results: [] }), null);
  const sent: any[] = [];
  const fetcher = async (_url: string, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body));
    sent.push(body);
    if (body.cachedContent) return json({ error: { code: 403, message: "CachedContent not found (or permission denied)" } }, 403);
    return json({ candidates: [{ content: { role: "model", parts: [call("submit", { status: "notFound", confidence: 0, reason: "none" })] } }] });
  };
  let lost = 0;
  const outcome = await identify({ title: "x" }, tmdb, { key: "k", model: "m", fetcher, cache: "cachedContents/old", cacheLost: () => lost++ }, () => {});
  assert.equal(outcome.verdict.status, "notFound");
  assert.equal(lost, 1);
  assert.equal(sent.length, 2);
  assert.ok(sent[1].systemInstruction);
});

test("identify stops when TMDB refuses, instead of answering not found", async () => {
  const tmdb = new TMDB("t", async () => json({ status_message: "Invalid API key" }, 401), null);
  const { gemini } = model([[call("search", { query: "x", type: "multi" })]]);
  await assert.rejects(identify({ title: "x" }, tmdb, gemini, () => {}), UpstreamError);
});

test("identify gives the last turn only submit, and fails when the model never answers", async () => {
  const tmdb = new TMDB("t", async () => json({ results: [] }), null);
  const turns = Array.from({ length: 3 }, (_, index) => [call("search", { query: "q" + index, type: "tv" }, "s" + index)]);
  const { gemini, sent } = model(turns);
  await assert.rejects(identify({ title: "x" }, tmdb, gemini, () => {}, { searches: 8, details: 6, seasons: 3, turns: 3 }), ModelError);
  assert.deepEqual(sent[2].toolConfig.functionCallingConfig.allowedFunctionNames, ["submit"]);
});

test("search budget is enforced by the tools", async () => {
  let searches = 0;
  const tmdb = new TMDB("t", async () => (searches++, json({ results: [] })), null);
  const { gemini, sent } = model([
    [call("search", { query: "a", type: "tv" }, "a"), call("search", { query: "b", type: "tv" }, "b")],
    [call("submit", { status: "notFound", confidence: 0, reason: "none" })],
  ]);
  const outcome = await identify({ title: "x" }, tmdb, gemini, () => {}, { searches: 1, details: 1, seasons: 1, turns: 4 });
  assert.equal(outcome.verdict.status, "notFound");
  assert.equal(searches, 1);
  assert.match(JSON.stringify(sent[1].contents[2]), /No searches left/);
});

test("TMDB waits out a 429 and tries again", async () => {
  let calls = 0;
  const tmdb = new TMDB("t", async () => (++calls === 1 ? json({}, 429, { "retry-after": "0" }) : json({ ok: true })), null);
  assert.deepEqual(await tmdb.get("/x"), { ok: true });
  assert.equal(calls, 2);
});

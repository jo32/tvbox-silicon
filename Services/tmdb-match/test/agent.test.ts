// node --test test/*.test.ts (Node 23+ runs the TypeScript as it is).
import assert from "node:assert/strict";
import { test } from "node:test";
import { identify, ModelError, verdict } from "../src/agent.ts";
import { details } from "../src/details.ts";
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

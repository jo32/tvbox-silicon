import assert from "node:assert/strict";
import { test } from "node:test";
import { doubanSearchTitle, featured, matchDouban } from "../src/featured.ts";
import { TMDB } from "../src/tmdb.ts";

const art = { poster_path: "/p.jpg", backdrop_path: "/b.jpg" };
const charts = async (input: string) => {
  if (input.startsWith("https://api.graphql.imdb.com/")) return Response.json({ data: {
    movie: { edges: [{ node: { id: "tt0000001" } }, { node: { id: "bad'id" } }] },
    tv: { edges: [{ node: { id: "tt0000002" } }] },
  } });
  if (input.includes("/movie_hot_gaia/")) return Response.json({ subject_collection_items: [
    { id: "1", title: "不存在的罪人", type: "movie", year: "2026" }, { id: "2", title: "A book", type: "book" }] });
  if (input.includes("/tv_hot/")) return Response.json({ subject_collection_items: [{ id: "3", title: "现在就出发 第四季", type: "tv", year: "2026" }] });
  return new Response(null, { status: 500 });
};
const tmdbAnswers = async (input: string) => {
  const url = new URL(input);
  if (url.pathname === "/3/find/tt0000001") return Response.json({ movie_results: [{ id: 11, title: "IMDb Film", release_date: "2026-01-01", ...art }], tv_results: [] });
  if (url.pathname === "/3/find/tt0000002") return Response.json({ movie_results: [], tv_results: [{ id: 12, name: "IMDb Series", first_air_date: "2025-01-01", ...art }] });
  if (url.pathname === "/3/search/movie") return Response.json({ results: [{ id: 21, title: "不存在的罪人", release_date: "2026-09-30", ...art }] });
  if (url.pathname === "/3/search/tv" && url.searchParams.get("query") === "现在就出发") return Response.json({ results: [{ id: 22, name: "现在就出发", first_air_date: "2023-10-01", ...art }] });
  if (url.pathname === "/3/trending/all/week") return Response.json({ results: [
    { id: 11, media_type: "movie", title: "IMDb Film", ...art }, { id: 31, media_type: "tv", name: "Trending", ...art },
    { id: 32, media_type: "tv", name: "No backdrop", poster_path: "/p.jpg" }] });
  return new Response(null, { status: 404 });
};

test("featured mixes Douban's and IMDb's charts as TMDB titles, Douban first in Chinese, topped up from trending", async () => {
  const value = await featured(new TMDB("test", tmdbAnswers, null), "zh-CN", charts);
  assert.deepEqual(value.items.map((item) => `${item.mediaType}:${item.id}`), ["movie:21", "movie:11", "tv:22", "tv:12", "tv:31"]);
  assert.equal(value.complete, true);
  const english = await featured(new TMDB("test", tmdbAnswers, null), "en-US", charts);
  assert.equal(english.items[0].id, 11);
});

test("featured keeps the other chart when one fails", async () => {
  const noDouban = async (input: string) => input.includes("douban") ? new Response(null, { status: 403 }) : charts(input);
  const value = await featured(new TMDB("test", tmdbAnswers, null), "zh-CN", noDouban);
  assert.deepEqual(value.items.map((item) => item.id), [11, 12, 31]);
  assert.equal(value.complete, false);
});

test("Douban titles match TMDB by name and year, and a season by the series name", () => {
  assert.equal(doubanSearchTitle("现在就出发 第四季", "tv"), "现在就出发");
  assert.equal(doubanSearchTitle("我家那闺女2026", "tv"), "我家那闺女");
  assert.equal(doubanSearchTitle("银翼杀手2049", "movie"), "银翼杀手2049");
  const result = (id: number, name: string, year: number | null) => ({ id, mediaType: "movie" as const, name, originalName: "", date: null, year,
    overview: "", poster: null, backdrop: null, rating: null, genreIDs: [] });
  assert.equal(matchDouban({ type: "movie", title: "点红", year: 2026 }, [result(1, "点红", 2010), result(2, "点红", 2026)])?.id, 2);
  assert.equal(matchDouban({ type: "movie", title: "别名", year: 2026 }, [result(3, "Other", 2025)])?.id, 3);
  assert.equal(matchDouban({ type: "movie", title: "别名", year: null }, [result(3, "Other", 2025)]), null);
});

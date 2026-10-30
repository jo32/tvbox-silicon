import assert from "node:assert/strict";
import { test } from "node:test";
import { readCatalogSearch, catalogSearch } from "../src/catalog-search.ts";
import { TMDB } from "../src/tmdb.ts";
const read = (s: string) => readCatalogSearch(new URLSearchParams(s));
test("catalog search validates bounds and never accepts arbitrary upstream paths", () => {
  for (const q of ["q=x&kind=../../account", "q=x&page=501", "q=x&page=1.2", "q=x&mode=discover&kind=person", "q=x&mode=discover&genres=999999", "q=x&from=2025&to=2020", "q=x&rating=11", "q=x&region=ZZ", "q=x&minRuntime=120&maxRuntime=90", "mode=person&id=0", "mode=keywords&q=", "q=x&sort=anything"]) assert.throws(() => read(q), q);
  assert.throws(() => read(`q=${"x".repeat(101)}`));
});
test("TV discovery maps date, language, genres and network filters without silently becoming movie filters", async () => {
  let requested: URL | undefined;
  const tmdb = new TMDB("test", async (url) => { requested = new URL(url); return Response.json({results: [{id: 1, name: "Series"}], total_pages: 900}); }, null);
  const input = read("mode=discover&kind=tv&page=2&genres=18,80&from=2020&to=2026&sort=date.desc&region=KR&originalLanguage=ko&networks=213&rating=7&votes=100&keywords=12,13");
  const result = await catalogSearch(tmdb, input, "zh-CN");
  assert.equal(requested!.pathname, "/3/discover/tv");
  assert.equal(requested!.searchParams.get("first_air_date.gte"), "2020-01-01");
  assert.equal(requested!.searchParams.get("sort_by"), "first_air_date.desc");
  assert.equal(requested!.searchParams.get("with_networks"), "213");
  assert.equal(requested!.searchParams.get("with_keywords"), "12,13");
  assert.equal(requested!.searchParams.get("include_adult"), "false");
  assert.equal(result.items[0].mediaType, "tv"); assert.equal(result.totalPages, 500);
});
test("person search keeps known works, filters invalid entries and uses independent pagination", async () => {
  let requested: URL | undefined;
  const tmdb = new TMDB("test", async (url) => { requested = new URL(url); return Response.json({results: [
    {id: 7, name: "Actor", known_for_department: "Acting", known_for: [{id: 3, media_type: "movie", title: "Film"}]},
    {id: 7, name: "Duplicate"}, {id: 8, name: "Adult", adult: true}, {id: -1, name: "Invalid"},
  ], total_pages: 4}); }, null);
  const result = await catalogSearch(tmdb, read("q=Actor&kind=person&page=3"), "ja-JP");
  assert.equal(requested!.pathname, "/3/search/person"); assert.equal(requested!.searchParams.get("page"), "3");
  assert.equal(result.people.length, 1); assert.equal(result.people[0].works[0].name, "Film");
  assert.equal(result.items.length, 0);
});
test("filmography deduplicates cast and crew while preserving movie/TV typed identity", async () => {
  const tmdb = new TMDB("test", async () => Response.json({cast: [{id: 7, media_type: "movie", title: "Film"}], crew: [
    {id: 7, media_type: "movie", title: "Film"}, {id: 7, media_type: "tv", name: "Series"},
  ]}), null);
  const result = await catalogSearch(tmdb, read("mode=person&id=10"), "en-US");
  assert.deepEqual(result.items.map(x => x.mediaType), ["movie", "tv"]);
});
test("filtering a typed title retains its query and applies year, genre and rating", async () => {
  let requested: URL | undefined;
  const tmdb = new TMDB("test", async url => {
    requested = new URL(url);
    return Response.json({ results: [
      {id: 1, title: "Inception", release_date: "2010-07-16", genre_ids: [28,878], vote_average: 8.4},
      {id: 2, title: "Other", release_date: "2020-01-01", genre_ids: [28], vote_average: 9},
      {id: 3, title: "Wrong genre", release_date: "2010-01-01", genre_ids: [35], vote_average: 8},
    ], total_pages: 2 });
  }, null);
  const result = await catalogSearch(tmdb, read("mode=discover&kind=movie&q=Inception&from=2010&to=2010&genres=28&rating=7"), "zh-CN");
  assert.equal(requested!.pathname, "/3/search/movie");
  assert.equal(requested!.searchParams.get("query"), "Inception");
  assert.deepEqual(result.items.map(x => x.id), [1]);
  assert.equal(result.totalPages, 2);
});
test("advanced title filters inspect details instead of silently dropping the platform", async () => {
  const paths: string[] = [];
  const tmdb = new TMDB("test", async url => {
    const path = new URL(url).pathname; paths.push(path);
    if (path.endsWith("search/tv")) return Response.json({results: [{id: 7, name: "Series"}, {id: 8, name: "Other"}], total_pages: 1});
    return Response.json({networks: [{id: path.endsWith("/7") ? 213 : 49}], origin_country: ["US"]});
  }, null);
  const result = await catalogSearch(tmdb, read("mode=discover&kind=tv&q=Series&networks=213&region=US"), "en-US");
  assert.deepEqual(result.items.map(x => x.id), [7]);
  assert.equal(paths.length, 3);
});

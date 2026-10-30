import assert from "node:assert/strict";
import { test } from "node:test";
import { catalog, catalogItems, catalogCollections, isCatalogFeed } from "../src/catalog.ts";
import { TMDB } from "../src/tmdb.ts";
import { details, heroPoster, trailer } from "../src/details.ts";

test("detail visual rails deduplicate landscape stills and keep native trailer identifiers", async () => {
  const tmdb = new TMDB("test", async () => Response.json({ id: 7, name: "Series", original_name: "Series",
    external_ids: { imdb_id: "tt1234567" }, networks: [{ name: "Studio", logo_path: "/studio.png" }],
    images: { backdrops: [{ file_path: "/a.jpg", aspect_ratio: 1.78 }, { file_path: "/a.jpg", aspect_ratio: 1.78 }, { file_path: "/portrait.jpg", aspect_ratio: 0.67 }] },
  }), null);
  const value = await details(tmdb, "tv", 7, "zh-CN", null);
  assert.deepEqual(value!.stills, ["https://image.tmdb.org/t/p/w780/a.jpg"]);
  assert.deepEqual(value!.studios, [{ name: "Studio", logo: "https://image.tmdb.org/t/p/w300/studio.png" }]);
  assert.deepEqual(value!.trailer, { site: "IMDb", key: "tt1234567" });
});

test("hero trailer picks a validated official trailer over clips and rejects injected keys", () => {
  assert.deepEqual(trailer({ results: [
    { site: "YouTube", key: "abcdefghijk", type: "Clip", official: true },
    { site: "YouTube", key: "bad'id", type: "Trailer", official: true },
    { site: "YouTube", key: "abcdefghij1", type: "Teaser", official: true },
    { site: "YouTube", key: "abcdefghij2", type: "Trailer", official: true, iso_639_1: "zh" },
  ] }, "zh-CN"), { site: "YouTube", key: "abcdefghij2" });
  assert.equal(trailer(null, "zh-CN"), null);
  assert.deepEqual(trailer(null, "zh-CN", "tt2531336"), { site: "IMDb", key: "tt2531336" });
  assert.equal(trailer(null, "zh-CN", "injected-id"), null);
});

test("hero cover prefers an unlettered portrait and falls back without changing catalog posters", () => {
  assert.equal(heroPoster({ posters: [
    { file_path: "/localized.jpg", iso_639_1: "zh", aspect_ratio: 0.67, vote_count: 100 },
    { file_path: "/wide.jpg", iso_639_1: null, aspect_ratio: 1.78, vote_count: 100 },
    { file_path: "/clean.jpg", iso_639_1: null, aspect_ratio: 0.67, vote_count: 2 },
  ] }, "/fallback.jpg"), "https://image.tmdb.org/t/p/w780/clean.jpg");
  assert.equal(heroPoster(null, "/fallback.jpg"), "https://image.tmdb.org/t/p/w780/fallback.jpg");
  assert.equal(heroPoster(null, null), null);
});

test("catalog keeps movie and series identities distinct and rejects unsupported records", () => {
  const body = { results: [
    { id: 7, media_type: "movie", title: "Film", poster_path: "/a.jpg", release_date: "2024-01-02", vote_count: 10, vote_average: 8.2 },
    { id: 7, media_type: "tv", name: "Series", first_air_date: "2025-02-03" },
    { id: 7, media_type: "movie", title: "Duplicate" },
    { id: 8, media_type: "person", name: "Person" },
    { id: 9, media_type: "movie", title: "Adult", adult: true },
    { id: -1, media_type: "movie", title: "Invalid" },
  ] };
  const items = catalogItems(body);
  assert.deepEqual(items.map((item) => `${item.mediaType}:${item.id}`), ["movie:7", "tv:7"]);
  assert.equal(items[0].rating, 8.2);
  assert.equal(items[1].rating, null);
  assert.equal(items[1].year, 2025);
  assert.equal(items[0].poster, "https://image.tmdb.org/t/p/w500/a.jpg");
  assert.equal(catalogItems({ results: [{ id: 1, title: "Movie" }] }, "movie")[0].mediaType, "movie");
  assert.deepEqual(catalogItems(null), []);
});

test("catalog requests use a fixed allowlist, preserve language and page, and hide adults", async () => {
  assert.equal(isCatalogFeed("trending"), true);
  assert.equal(isCatalogFeed("__proto__"), false);
  assert.equal(isCatalogFeed("/account"), false);
  let requested: URL | undefined;
  const tmdb = new TMDB("test", async (url) => {
    requested = new URL(url);
    return Response.json({ total_pages: 1000, results: [{ id: 1, name: "Animation" }] });
  }, null);
  const page = await catalog(tmdb, "animation", "zh-CN", 2);
  assert.equal(requested!.pathname, "/3/discover/tv");
  assert.equal(requested!.searchParams.get("with_genres"), "16");
  assert.equal(requested!.searchParams.get("include_adult"), "false");
  assert.equal(requested!.searchParams.get("language"), "zh-CN");
  assert.equal(requested!.searchParams.get("page"), "2");
  assert.equal(page.totalPages, 500);
  assert.equal(page.items[0].mediaType, "tv");
});


test("collections keep usable brands when one logo request fails, and omit adult people", async () => {
  const tmdb = new TMDB("test", async (url) => {
    const path = new URL(url).pathname;
    if (path.includes("/network/2739")) return new Response(null, { status: 503 });
    if (path.endsWith("/person/popular")) return Response.json({ results: [
      { id: 3, name: "Actor", profile_path: "/p.jpg", known_for: [{ id: 8, media_type: "movie", title: "Known film" }] },
      { id: 4, name: "Adult", adult: true, profile_path: "/q.jpg" },
    ] });
    return Response.json({ name: "Brand", logo_path: "/logo.png" });
  }, null);
  const value = await catalogCollections(tmdb, "zh-CN");
  assert.equal(value.people.length, 1);
  assert.equal(value.people[0].works[0].mediaType, "movie");
  assert.equal(value.networks.length, 3);
  assert.equal(value.companies.length, 4);
});

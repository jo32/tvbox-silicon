import assert from "node:assert/strict";
import { test } from "node:test";
import { catalogPerson, personWorks } from "../src/catalog-person.ts";
import { details } from "../src/details.ts";
import { catalogSearch, readCatalogSearch } from "../src/catalog-search.ts";
import { TMDB } from "../src/tmdb.ts";

test("timeline merges contributions without losing typed identity, orders dates and keeps undated works", () => {
  const works = personWorks({ cast: [
    { id: 7, media_type: "movie", title: "Film", release_date: "2024-03-02", character: "Lead" },
    { id: 7, media_type: "tv", name: "Series", first_air_date: "2025-01-01", character: "Guest" },
    { id: 8, media_type: "movie", title: "Undated" },
    { id: 9, media_type: "movie", title: "Excluded", adult: true },
  ], crew: [{ id: 7, media_type: "movie", title: "Film", release_date: "2024-03-02", job: "Producer", department: "Production" }] });
  assert.deepEqual(works.map(x => [x.item.mediaType, x.item.id]), [["tv", 7], ["movie", 7], ["movie", 8]]);
  assert.deepEqual(works[1].roles, ["Lead", "Producer"]);
  assert.deepEqual(works[1].departments, ["Acting", "Production"]);
  assert.equal(works[2].date, null);
});

test("profile loads localized credits and falls back to English biography with bounded social handles", async () => {
  let request: URL;
  const tmdb = new TMDB("test", async url => {
    request = new URL(url);
    return Response.json({ name: "Actor", biography: "", translations: { translations: [{ iso_639_1: "en", data: { biography: "Biography" } }] },
      external_ids: { instagram_id: "../bad?token=x" }, combined_credits: { cast: [] } });
  }, null);
  const profile = await catalogPerson(tmdb, 31, "zh-CN");
  assert.equal(request!.pathname, "/3/person/31");
  assert.equal(request!.searchParams.get("language"), "zh-CN");
  assert.equal(profile.biography, "Biography"); assert.equal(profile.instagram, null);
  assert.throws(() => readCatalogSearch(new URLSearchParams("mode=profile&id=../../account")));
  assert.throws(() => readCatalogSearch(new URLSearchParams("mode=profile")));
});

test("detail navigation retains actor, genre and network identities independently of translated names", async () => {
  const tmdb = new TMDB("test", async () => Response.json({ id: 1416, name: "Series", genres: [{ id: 18, name: "剧情" }],
    aggregate_credits: { cast: [{ id: 18352, name: "Actor", roles: [{ character: "Lead" }] }] },
    networks: [{ id: 2, name: "ABC" }], created_by: [{ id: 1, name: "Creator" }] }), null);
  const result = await details(tmdb, "tv", 1416, "zh-CN", null);
  assert.equal(result!.cast[0].id, 18352); assert.equal(result!.crew[0].id, 1);
  assert.deepEqual(result!.genreItems, [{ id: 18, name: "剧情" }]);
  assert.deepEqual(result!.studios[0], { id: 2, kind: "network", name: "ABC", logo: null });
});

test("arbitrary valid platform IDs use typed discover filters and retain page and sort", async () => {
  let request: URL;
  const tmdb = new TMDB("test", async url => { request = new URL(url); return Response.json({ results: [], total_pages: 4 }); }, null);
  await catalogSearch(tmdb, readCatalogSearch(new URLSearchParams("mode=discover&kind=tv&networks=2&page=2&sort=date.desc")), "en-US");
  assert.equal(request!.pathname, "/3/discover/tv"); assert.equal(request!.searchParams.get("with_networks"), "2");
  assert.equal(request!.searchParams.get("page"), "2"); assert.equal(request!.searchParams.get("sort_by"), "first_air_date.desc");
  await catalogSearch(tmdb, readCatalogSearch(new URLSearchParams("mode=discover&kind=movie&companies=9999")), "en-US");
  assert.equal(request!.searchParams.get("with_companies"), "9999"); assert.equal(request!.searchParams.get("with_networks"), null);
  for (const value of ["0", "-1", "../../account", "1|2", "10000000000"]) {
    assert.throws(() => readCatalogSearch(new URLSearchParams(`mode=discover&kind=tv&networks=${value}`)));
  }
});

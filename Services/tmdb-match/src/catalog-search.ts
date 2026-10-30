// Discover search is a catalog browser, independent of source-video/global search.
import { catalogItems } from "./catalog.ts";
import { image, type TMDB } from "./tmdb.ts";

const kinds = new Set(["movie", "tv", "person"]);
const feeds = new Set(["day", "week", "popular"]);
const languages = new Set(["zh", "en", "ja", "ko", "fr", "de", "es", "it", "hi", "th"]);
const regions = new Set(["CN", "HK", "TW", "US", "GB", "JP", "KR", "FR", "DE", "IN", "TH"]);
const sorts = new Set(["popularity.desc", "popularity.asc", "vote_average.desc", "vote_average.asc", "date.desc", "date.asc", "revenue.desc", "vote_count.desc"]);
const movieGenres = new Set([28,12,16,35,80,99,18,10751,14,36,27,10402,9648,10749,878,10770,53,10752,37]);
const tvGenres = new Set([10759,16,35,80,99,18,10751,10762,9648,10763,10764,10765,10766,10767,10768,37]);

function integer(p: URLSearchParams, key: string, min: number, max: number): number | undefined {
  const raw = p.get(key);
  if (raw == null || raw === "") return undefined;
  if (!/^\d+$/.test(raw)) throw new Error(key);
  const n = Number(raw);
  if (!Number.isSafeInteger(n) || n < min || n > max) throw new Error(key);
  return n;
}
function choice(p: URLSearchParams, key: string, values: Set<string>, fallback = ""): string {
  const value = p.get(key) || fallback;
  if (value && !values.has(value)) throw new Error(key);
  return value;
}
function ids(p: URLSearchParams, key: string, allowed?: Set<number>): string | undefined {
  const raw = p.get(key);
  if (!raw) return undefined;
  const values = raw.split(",");
  if (values.length > 8 || values.some(x => !/^\d{1,9}$/.test(x) || Number(x) < 1 || (allowed && !allowed.has(Number(x))))) throw new Error(key);
  return [...new Set(values)].join(",");
}
export function readCatalogSearch(p: URLSearchParams) {
  const kind = choice(p, "kind", kinds, "movie");
  const mode = choice(p, "mode", new Set(["search", "discover", "recommend", "person", "keywords"]), "search");
  const query = (p.get("q") ?? "").trim();
  if (query.length > 100 || ((mode === "search" || mode === "keywords") && !query)) throw new Error("q");
  if (mode === "discover" && kind === "person") throw new Error("kind");
  const page = integer(p, "page", 1, 500) ?? 1;
  const sort = choice(p, "sort", sorts, "popularity.desc");
  if (kind === "tv" && sort === "revenue.desc") throw new Error("sort");
  const from = integer(p, "from", 1870, 2100), to = integer(p, "to", 1870, 2100);
  if (from && to && from > to) throw new Error("years");
  const minRuntime = integer(p, "minRuntime", 0, 600), maxRuntime = integer(p, "maxRuntime", 0, 600);
  if (minRuntime != null && maxRuntime != null && minRuntime > maxRuntime) throw new Error("runtime");
  const personID = integer(p, "id", 1, 2147483647);
  if (mode === "person" && !personID) throw new Error("id");
  const params: Record<string, string | number | undefined> = {
    with_genres: ids(p, "genres", kind === "tv" ? tvGenres : movieGenres),
    with_original_language: choice(p, "originalLanguage", languages),
    with_origin_country: choice(p, "region", regions),
    "vote_average.gte": integer(p, "rating", 0, 10),
    "vote_count.gte": integer(p, "votes", 0, 1000000),
    "with_runtime.gte": minRuntime, "with_runtime.lte": maxRuntime,
    with_keywords: ids(p, "keywords"),
    with_networks: kind === "tv" ? ids(p, "networks", new Set([213,2739,2552,49])) : undefined,
    with_companies: kind === "movie" ? ids(p, "companies", new Set([174,33,4,34,2])) : undefined,
    sort_by: sort.replace("date.", kind === "tv" ? "first_air_date." : "primary_release_date."),
    [kind === "tv" ? "first_air_date.gte" : "primary_release_date.gte"]: from ? `${from}-01-01` : undefined,
    [kind === "tv" ? "first_air_date.lte" : "primary_release_date.lte"]: to ? `${to}-12-31` : undefined,
  };
  return { kind, mode, query, page, feed: choice(p, "feed", feeds, "week"), personID, params };
}
function people(body: any) {
  const seen = new Set<number>();
  return (Array.isArray(body?.results) ? body.results : []).filter((p: any) => {
    if (p.adult || !Number.isSafeInteger(p.id) || p.id <= 0 || typeof p.name !== "string" || !p.name.trim() || seen.has(p.id)) return false;
    seen.add(p.id); return true;
  }).map((p: any) => ({ id: p.id, name: p.name.trim().slice(0, 200), profile: image(p.profile_path, "w185"),
    department: typeof p.known_for_department === "string" ? p.known_for_department.slice(0, 80) : null,
    works: catalogItems({ results: p.known_for }) }));
}
export async function catalogSearch(tmdb: TMDB, input: ReturnType<typeof readCatalogSearch>, language: string) {
  const { mode, kind, query, page, feed } = input;
  if (mode === "person") {
    const body = await tmdb.get(`/person/${input.personID}/combined_credits`, { language });
    const credits = [...(body?.cast ?? []), ...(body?.crew ?? [])].sort((a, b) => (b.popularity ?? 0) - (a.popularity ?? 0));
    return { items: catalogItems({ results: credits }).slice(0, 200), people: [], keywords: [], page: 1, totalPages: 1 };
  }
  if (mode === "keywords") {
    const body = await tmdb.get("/search/keyword", { query, page: 1 });
    return { items: [], people: [], keywords: (body?.results ?? []).filter((x: any) => Number.isSafeInteger(x.id) && x.id > 0 && typeof x.name === "string").slice(0, 20)
      .map((x: any) => ({ id: x.id, name: x.name.slice(0, 100) })), page: 1, totalPages: 1 };
  }
  const searching = mode === "search" || (mode === "discover" && !!query);
  const path = searching ? `/search/${kind}` : mode === "discover" ? `/discover/${kind}`
    : feed === "popular" ? `/${kind}/popular` : `/trending/${kind}/${feed}`;
  let body = await tmdb.get(path, { ...(mode === "discover" && !searching ? input.params : {}), language, page, include_adult: "false",
    query: searching ? query : undefined });
  // TMDB discover has no title-query parameter. Preserve the typed title when
  // changing Rex-style chips: search the selected kind, then apply constraints.
  if (mode === "discover" && searching) {
    const p = input.params;
    const selectedIDs = (key: string) => String(p[key] || "").split(",").filter(Boolean).map(Number);
    let results = (body?.results ?? []).filter((item: any) => {
      const date = String(item[kind === "tv" ? "first_air_date" : "release_date"] || "");
      const lower = p[kind === "tv" ? "first_air_date.gte" : "primary_release_date.gte"];
      const upper = p[kind === "tv" ? "first_air_date.lte" : "primary_release_date.lte"];
      return !item.adult && selectedIDs("with_genres").every(id => item.genre_ids?.includes(id))
        && (!p.with_original_language || item.original_language === p.with_original_language)
        && (!lower || date >= lower) && (!upper || (!!date && date <= upper))
        && (!p["vote_average.gte"] || item.vote_average >= Number(p["vote_average.gte"]))
        && (!p["vote_count.gte"] || item.vote_count >= Number(p["vote_count.gte"]));
    });
    if (p.with_origin_country || p.with_companies || p.with_networks || p.with_keywords || p["with_runtime.gte"] || p["with_runtime.lte"] || p.sort_by === "revenue.desc") {
      const detailed: any[] = [];
      for (let offset = 0; offset < results.length; offset += 4) {
        detailed.push(...await Promise.all(results.slice(offset, offset + 4).map(async (item: any) => {
          const detail = await tmdb.get(`/${kind}/${item.id}`, { language, append_to_response: p.with_keywords ? "keywords" : undefined });
          return { ...item, ...detail, genre_ids: item.genre_ids };
        })));
      }
      results = detailed.filter((item: any) => {
        const runtime = item.runtime ?? item.episode_run_time?.[0];
        const keywords = item.keywords?.keywords ?? item.keywords?.results ?? [];
        return (!p.with_origin_country || (item.origin_country ?? item.production_countries?.map((x: any) => x.iso_3166_1) ?? []).includes(p.with_origin_country))
          && selectedIDs("with_companies").every(id => item.production_companies?.some((x: any) => x.id === id))
          && selectedIDs("with_networks").every(id => item.networks?.some((x: any) => x.id === id))
          && selectedIDs("with_keywords").every(id => keywords.some((x: any) => x.id === id))
          && (!p["with_runtime.gte"] || runtime >= Number(p["with_runtime.gte"]))
          && (!p["with_runtime.lte"] || runtime <= Number(p["with_runtime.lte"]));
      });
    }
    const [sortKey, direction] = String(p.sort_by).split(".");
    const property = sortKey === "primary_release_date" ? "release_date" : sortKey;
    results.sort((a: any, b: any) => {
      const left = a[property] ?? 0, right = b[property] ?? 0;
      return (typeof left === "string" ? left.localeCompare(String(right)) : left - right) * (direction === "asc" ? 1 : -1);
    });
    body = { ...body, results };
  }
  return { items: kind === "person" ? [] : catalogItems(body, kind as "movie" | "tv"), people: kind === "person" ? people(body) : [], keywords: [],
    page, totalPages: Math.min(500, Math.max(page, Number(body?.total_pages) || page)) };
}

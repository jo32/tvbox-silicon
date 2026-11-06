// Discover's featured carousel (#631): IMDb's most popular films and series mixed with Douban's hot films and
// series, each opened as its TMDB title (artwork, overview, the app's detail page). Both charts move daily, unlike
// TMDB's weekly trending list the carousel used before. A chart that fails is left out; TMDB trending fills the rest.
import { catalog, catalogItems } from "./catalog.ts";
import type { Fetcher, MediaType, TMDB } from "./tmdb.ts";

export const FEATURED_COUNT = 10;
// Titles taken from each of the four charts: some have no TMDB match or artwork, or appear on both sites.
const PER_CHART = 5;
const TIMEOUT = 8000;

type Item = ReturnType<typeof catalogItems>[number];
export interface ChartEntry { type: MediaType; imdb?: string; title?: string; year?: number | null }

export async function imdbPopular(fetcher: Fetcher, count = PER_CHART): Promise<ChartEntry[]> {
  const chart = (name: string) => `chartTitles(first: ${count}, chart: {chartType: ${name}}) { edges { node { id } } }`;
  const response = await fetcher("https://api.graphql.imdb.com/", {
    method: "POST",
    // Without IMDb's own Origin and Referer the API answers 403.
    headers: { "content-type": "application/json", origin: "https://www.imdb.com", referer: "https://www.imdb.com/", "user-agent": "Mozilla/5.0" },
    body: JSON.stringify({ query: `{ movie: ${chart("MOST_POPULAR_MOVIES")} tv: ${chart("MOST_POPULAR_TV_SHOWS")} }` }),
    signal: AbortSignal.timeout(TIMEOUT),
  });
  if (!response.ok) throw new Error(`IMDb ${response.status}`);
  const body: any = await response.json();
  const ids = (type: MediaType): ChartEntry[] => (Array.isArray(body?.data?.[type]?.edges) ? body.data[type].edges : [])
    .map((edge: any) => edge?.node?.id).filter((id: unknown) => typeof id === "string" && /^tt\d{5,12}$/.test(id))
    .map((imdb: string) => ({ type, imdb }));
  return interleave(ids("movie"), ids("tv"));
}

export async function doubanHot(fetcher: Fetcher, count = PER_CHART): Promise<ChartEntry[]> {
  const list = async (collection: string): Promise<ChartEntry[]> => {
    const response = await fetcher(`https://m.douban.com/rexxar/api/v2/subject_collection/${collection}/items?start=0&count=${count}`, {
      // Douban's mobile API answers only with its own Referer.
      headers: { referer: "https://m.douban.com/movie/", "user-agent": "Mozilla/5.0" },
      signal: AbortSignal.timeout(TIMEOUT),
    });
    if (!response.ok) throw new Error(`Douban ${response.status}`);
    const body: any = await response.json();
    return (Array.isArray(body?.subject_collection_items) ? body.subject_collection_items : []).flatMap((row: any) => {
      const title = typeof row?.title === "string" ? row.title.trim() : "";
      if ((row?.type !== "movie" && row?.type !== "tv") || !title) return [];
      const year = Number(row.year);
      return [{ type: row.type as MediaType, title, year: Number.isInteger(year) && year > 1800 ? year : null }];
    });
  };
  const [movies, series] = await Promise.allSettled([list("movie_hot_gaia"), list("tv_hot")]);
  if (movies.status === "rejected" && series.status === "rejected") throw movies.reason;
  return interleave(movies.status === "fulfilled" ? movies.value : [], series.status === "fulfilled" ? series.value : []);
}

// Douban names each season as its own title ("现在就出发 第四季", for some shows the year: "我家那闺女2026"); TMDB has
// one series with seasons. A film keeps its name ("银翼杀手2049"). Same rule as the app's DoubanCatalog.searchTitle.
export function doubanSearchTitle(title: string, type: MediaType): string {
  const pattern = type === "tv" ? /(\s*第[一二三四五六七八九十百零〇\d]+季|(?<=\D)\s*(19|20)\d\d)$/u : /\s*第[一二三四五六七八九十百零〇\d]+季$/u;
  const found = pattern.exec(title);
  return found && found.index > 0 ? title.slice(0, found.index) : title;
}

const normalized = (text: string) => text.normalize("NFKC").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");

// The TMDB title for a Douban one, as the app's DoubanCatalog.match: same kind and name, a year at most one apart
// (not compared for a later season), else the first result of that kind and year. null rather than a guess.
export function matchDouban(entry: ChartEntry, results: Item[]): Item | null {
  const name = doubanSearchTitle(entry.title ?? "", entry.type);
  const season = name !== entry.title;
  const key = normalized(name);
  const kind = results.filter((result) => result.mediaType === entry.type);
  const fits = (result: Item) => season || entry.year == null || result.year == null || Math.abs(entry.year - result.year) <= 1;
  const exact = kind.find((result) => (normalized(result.name) === key || normalized(result.originalName) === key) && fits(result));
  if (exact) return exact;
  if (season || entry.year == null) return null;
  return kind.find((result) => result.year != null && fits(result)) ?? null;
}

async function resolve(tmdb: TMDB, entry: ChartEntry, language: string): Promise<Item | null> {
  if (entry.imdb) {
    const body = await tmdb.get(`/find/${entry.imdb}`, { external_source: "imdb_id", language });
    return catalogItems({ results: body?.[entry.type === "movie" ? "movie_results" : "tv_results"] }, entry.type)[0] ?? null;
  }
  const query = doubanSearchTitle(entry.title ?? "", entry.type);
  const body = await tmdb.get(`/search/${entry.type}`, { query, language, include_adult: "false" });
  return matchDouban(entry, catalogItems(body, entry.type));
}

function interleave<T>(a: T[], b: T[]): T[] {
  const out: T[] = [];
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    if (index < a.length) out.push(a[index]);
    if (index < b.length) out.push(b[index]);
  }
  return out;
}

// Douban first for Chinese viewers, IMDb first for the rest. `complete` says both charts answered, so the caller
// can keep the list longer than one built while a chart was down.
export async function featured(tmdb: TMDB, language: string, fetcher: Fetcher = (input, init) => fetch(input, init)) {
  const [imdb, douban] = await Promise.allSettled([imdbPopular(fetcher), doubanHot(fetcher)]);
  const fromIMDb = imdb.status === "fulfilled" ? imdb.value : [];
  const fromDouban = douban.status === "fulfilled" ? douban.value : [];
  const entries = language.startsWith("zh") ? interleave(fromDouban, fromIMDb) : interleave(fromIMDb, fromDouban);
  const resolved = await Promise.all(entries.map((entry) => resolve(tmdb, entry, language).catch(() => null)));
  const items: Item[] = [];
  const seen = new Set<string>();
  const add = (item: Item | null) => {
    const key = item && `${item.mediaType}:${item.id}`;
    if (!item || !key || items.length >= FEATURED_COUNT || seen.has(key) || !item.poster || !item.backdrop) return;
    seen.add(key);
    items.push(item);
  };
  resolved.forEach(add);
  if (items.length < FEATURED_COUNT) (await catalog(tmdb, "trending", language, 1).catch(() => null))?.items.forEach(add);
  return { items, page: 1, totalPages: 1, complete: imdb.status === "fulfilled" && douban.status === "fulfilled" };
}

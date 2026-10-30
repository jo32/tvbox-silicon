// Public, bounded catalog lists for the app's Discover tab. Credentials stay in the Worker.
import { image, type MediaType, type TMDB, yearOf } from "./tmdb.ts";

export const catalogFeeds = {
  trending: { path: "/trending/all/week" },
  movies: { path: "/movie/popular", type: "movie" },
  television: { path: "/tv/popular", type: "tv" },
  onTheAir: { path: "/tv/on_the_air", type: "tv" },
  nowPlaying: { path: "/movie/now_playing", type: "movie" },
  upcoming: { path: "/movie/upcoming", type: "movie" },
  topMovies: { path: "/movie/top_rated", type: "movie" },
  topTelevision: { path: "/tv/top_rated", type: "tv" },
  animation: { path: "/discover/tv", type: "tv", params: { with_genres: 16, sort_by: "popularity.desc" } },
  chinese: { path: "/discover/tv", type: "tv", params: { with_original_language: "zh", sort_by: "popularity.desc" } },
  korean: { path: "/discover/tv", type: "tv", params: { with_original_language: "ko", sort_by: "popularity.desc" } },
  variety: { path: "/discover/tv", type: "tv", params: { with_genres: "10764|10767", with_original_language: "zh", sort_by: "popularity.desc" } },
  family: { path: "/discover/movie", type: "movie", params: { with_genres: 10751, sort_by: "popularity.desc" } },
  kids: { path: "/discover/tv", type: "tv", params: { with_genres: 10762, sort_by: "popularity.desc" } },
  netflix: { path: "/discover/tv", type: "tv", params: { with_networks: 213, sort_by: "popularity.desc" } },
  disney: { path: "/discover/tv", type: "tv", params: { with_networks: 2739, sort_by: "popularity.desc" } },
  appleTV: { path: "/discover/tv", type: "tv", params: { with_networks: 2552, sort_by: "popularity.desc" } },
  hbo: { path: "/discover/tv", type: "tv", params: { with_networks: 49, sort_by: "popularity.desc" } },
  warner: { path: "/discover/movie", type: "movie", params: { with_companies: 174, sort_by: "popularity.desc" } },
  universal: { path: "/discover/movie", type: "movie", params: { with_companies: 33, sort_by: "popularity.desc" } },
  paramount: { path: "/discover/movie", type: "movie", params: { with_companies: 4, sort_by: "popularity.desc" } },
  sony: { path: "/discover/movie", type: "movie", params: { with_companies: 34, sort_by: "popularity.desc" } },
} satisfies Record<string, { path: string; type?: MediaType; params?: Record<string, string | number> }>;

export type CatalogFeed = keyof typeof catalogFeeds;

export function isCatalogFeed(value: string): value is CatalogFeed {
  return Object.hasOwn(catalogFeeds, value);
}

// Ignore malformed, adult, person and duplicate results; keep the type in the identity because
// a movie and a series can share a numeric TMDB ID.
export function catalogItems(body: any, fallbackType?: MediaType) {
  const seen = new Set<string>();
  return (Array.isArray(body?.results) ? body.results : []).flatMap((item: any) => {
    const mediaType = item.media_type ?? fallbackType;
    if (mediaType !== "movie" && mediaType !== "tv") return [];
    const name = mediaType === "tv" ? item.name : item.title;
    const key = `${mediaType}:${item.id}`;
    if (item.adult || !Number.isSafeInteger(item.id) || item.id <= 0 || typeof name !== "string" || !name.trim() || seen.has(key)) return [];
    seen.add(key);
    return [{
      id: item.id,
      mediaType,
      name: name.trim().slice(0, 200),
      originalName: String((mediaType === "tv" ? item.original_name : item.original_title) ?? "").slice(0, 200),
      date: typeof (mediaType === "tv" ? item.first_air_date : item.release_date) === "string" ? (mediaType === "tv" ? item.first_air_date : item.release_date) : null,
      year: yearOf(mediaType === "tv" ? item.first_air_date : item.release_date),
      overview: typeof item.overview === "string" ? item.overview.slice(0, 2000) : "",
      poster: image(item.poster_path, "w500"),
      backdrop: image(item.backdrop_path, "w1280"),
      rating: item.vote_count > 0 && typeof item.vote_average === "number" && Number.isFinite(item.vote_average) ? item.vote_average : null,
      genreIDs: Array.isArray(item.genre_ids) ? item.genre_ids.filter((id: unknown) => Number.isSafeInteger(id)) : [],
    }];
  });
}

export async function catalog(tmdb: TMDB, feed: CatalogFeed, language: string, page: number) {
  const source: { path: string; type?: MediaType; params?: Record<string, string | number> } = catalogFeeds[feed];
  const body = await tmdb.get(source.path, { ...source.params, language, page, include_adult: "false" });
  return {
    items: catalogItems(body, source.type),
    page,
    totalPages: Math.min(500, Math.max(page, Number(body?.total_pages) || page)),
  };
}

export async function catalogCollections(tmdb: TMDB, language: string) {
  const brands = async (kind: "network" | "company", entries: [number, CatalogFeed][]) => Promise.all(entries.map(async ([id, feed]) => {
    try {
      const value = await tmdb.get(`/${kind}/${id}`);
      return value ? { feed, name: String(value.name ?? ""), logo: image(value.logo_path, "w500") } : null;
    } catch { return null; }
  }));
  const [people, networks, companies] = await Promise.all([
    tmdb.get("/person/popular", { language, page: 1 }),
    brands("network", [[213, "netflix"], [2739, "disney"], [2552, "appleTV"], [49, "hbo"]]),
    brands("company", [[174, "warner"], [33, "universal"], [4, "paramount"], [34, "sony"]]),
  ]);
  return {
    people: (Array.isArray(people?.results) ? people.results : []).filter((person: any) => !person.adult && person.profile_path && Number.isSafeInteger(person.id))
      .slice(0, 16).map((person: any) => ({ id: person.id, name: String(person.name ?? ""), profile: image(person.profile_path, "w185"),
        works: catalogItems({ results: person.known_for }) })).filter((person: any) => person.works.length > 0),
    networks: networks.filter(Boolean), companies: companies.filter(Boolean),
  };
}

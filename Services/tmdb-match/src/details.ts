// What the app shows for a title (`Details`), and what the agent reads to check a candidate (`facts`).
import { image, type MediaType, type TMDB, yearOf } from "./tmdb.ts";

export interface Person {
  id: number | null;
  name: string;
  role: string | null;
  profile: string | null;
}

export interface SeasonSummary {
  number: number;
  name: string;
  episodeCount: number;
  year: number | null;
  poster: string | null;
}

export interface EpisodeInfo {
  number: number;
  name: string;
  overview: string;
  still: string | null;
  airDate: string | null;
  runtime: number | null;
  rating: number | null;
}

/** A title TMDB suggests beside this one. */
export interface Related {
  mediaType: MediaType;
  id: number;
  name: string;
  originalName: string | null;
  year: number | null;
  poster: string;
  overview: string | null;
}

export interface Details {
  mediaType: MediaType;
  id: number;
  name: string;
  originalName: string;
  tagline: string;
  overview: string;
  year: number | null;
  date: string | null;
  genres: string[];
  genreItems: { id: number; name: string }[];
  runtime: number | null;
  rating: number | null;
  voteCount: number;
  countries: string[];
  status: string | null;
  poster: string | null;
  backdrop: string | null;
  logo: string | null;
  heroPoster: string | null;
  trailer: { site: "YouTube" | "IMDb"; key: string } | null;
  stills: string[];
  studios: { id: number | null; kind: "network" | "company"; name: string; logo: string | null }[];
  cast: Person[];
  crew: Person[];
  networks: string[];
  seasons: SeasonSummary[];
  season: { number: number; name: string; overview: string; poster: string | null; year: number | null; episodes: EpisodeInfo[] } | null;
  /** "You may like": TMDB's recommendations, topped up with similar titles. */
  recommendations: Related[];
  link: string;
}

// TMDB is edited by anyone, and spam gets in (a zh-CN tagline once advertised a porn site): text with a web
// address or the styled letters spammers use to slip past filters (𝟰, 𝐀) is left out.
const spam = /https?:\/\/|www\.|[a-z0-9-]+\.(?:com|net|org|cc|top|xyz|vip|me|tv|co|info|io|app|club|site|live|link|shop|fun|icu|pw)\b|[\u{1D400}-\u{1D7FF}]/iu;
const clip = (value: unknown, max: number) => (typeof value === "string" && !spam.test(value) ? value.trim().slice(0, max) : "");
const list = (value: unknown): any[] => (Array.isArray(value) ? value : []);
const number = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : null);

// The first of these translations with text: TMDB leaves a field empty where nobody translated it.
function fallbacks(language: string) {
  const zh = ["zh-CN", "zh-SG", "zh-TW", "zh-HK"];
  const first = language.startsWith("zh") ? [language, ...zh.filter((code) => code !== language)] : [language];
  return [...first, "en-US"];
}

function translated(translations: any, language: string, field: string) {
  const items = list(translations?.translations);
  for (const code of fallbacks(language)) {
    const [lang, region] = code.split("-");
    const item = items.find((entry) => entry.iso_639_1 === lang && entry.iso_3166_1 === region) ?? (region ? null : items.find((entry) => entry.iso_639_1 === lang));
    const text = clip(item?.data?.[field], 2000);
    if (text) return text;
  }
  return "";
}

// What people who liked this went on to watch, then titles like it while there are fewer than `limit`.
// Only titles with a poster: the app shows them as a row of posters.
export function related(item: any, type: MediaType, limit = 12): Related[] {
  const seen = new Set([`${type}:${item.id}`]);
  const titles: Related[] = [];
  for (const result of [...list(item.recommendations?.results), ...list(item.similar?.results)]) {
    if (titles.length >= limit) break;
    const mediaType: MediaType = result.media_type === "tv" || result.media_type === "movie" ? result.media_type : type;
    const tv = mediaType === "tv";
    const name = clip(tv ? result.name : result.title, 120);
    const poster = image(result.poster_path, "w342");
    const key = `${mediaType}:${result.id}`;
    if (result.adult || typeof result.id !== "number" || !name || !poster || seen.has(key)) continue;
    seen.add(key);
    titles.push({
      mediaType,
      id: result.id,
      name,
      originalName: clip(tv ? result.original_name : result.original_title, 120) || null,
      year: yearOf(tv ? result.first_air_date : result.release_date),
      poster,
      overview: clip(result.overview, 200) || null,
    });
  }
  return titles;
}

// A logo in the viewer's language if there is one, else English, else one without text. PNGs only: the app can't draw SVG.
function logo(images: any, language: string) {
  const logos = list(images?.logos).filter((entry) => typeof entry.file_path === "string" && entry.file_path.endsWith(".png"));
  const lang = language.split("-")[0];
  const pick = logos.find((entry) => entry.iso_639_1 === lang) ?? logos.find((entry) => entry.iso_639_1 === "en") ?? logos.find((entry) => !entry.iso_639_1);
  return image(pick?.file_path, "w500");
}

// A separate wordmark sits over the home cover. Prefer a text-free portrait so the title
// isn't printed twice; ordinary catalog cards keep TMDB's localized poster.
export function heroPoster(images: any, fallback: unknown): string | null {
  const posters = list(images?.posters).filter((entry) => entry.iso_639_1 == null &&
    typeof entry.file_path === "string" && typeof entry.aspect_ratio === "number" &&
    entry.aspect_ratio >= 0.5 && entry.aspect_ratio <= 0.85);
  posters.sort((a, b) => (b.vote_count ?? 0) - (a.vote_count ?? 0) || (b.width ?? 0) - (a.width ?? 0));
  return image(posters[0]?.file_path ?? fallback, "w780");
}

export function trailer(videos: any, language: string, imdbID?: unknown): Details["trailer"] {
  if (typeof imdbID === "string" && /^tt\d{5,12}$/.test(imdbID)) return { site: "IMDb", key: imdbID };
  const lang = language.split("-")[0];
  const candidates = list(videos?.results).filter((entry) => entry.site === "YouTube" &&
    typeof entry.key === "string" && /^[A-Za-z0-9_-]{11}$/.test(entry.key) && ["Trailer", "Teaser"].includes(entry.type));
  const score = (entry: any) => (entry.official ? 8 : 0) + (entry.type === "Trailer" ? 4 : 0) + (entry.iso_639_1 === lang ? 2 : 0);
  candidates.sort((a, b) => score(b) - score(a) || String(b.published_at ?? "").localeCompare(String(a.published_at ?? "")));
  return candidates[0] ? { site: "YouTube", key: candidates[0].key } : null;
}

export async function details(tmdb: TMDB, type: MediaType, id: number, language: string, seasonNumber: number | null): Promise<Details | null> {
  const lang = language.split("-")[0];
  const item = await tmdb.get(`/${type}/${id}`, {
    language,
    append_to_response: type === "tv" ? "aggregate_credits,images,translations,recommendations,similar,videos,external_ids" : "credits,images,translations,recommendations,similar,videos",
    include_image_language: `${lang},en,null`,
    include_video_language: `${lang},en,null`,
  });
  if (!item) return null;
  const tv = type === "tv";
  const credits = tv ? item.aggregate_credits : item.credits;
  const cast: Person[] = list(credits?.cast)
    .slice(0, 16)
    .map((person) => ({
      id: Number.isSafeInteger(person.id) && person.id > 0 ? person.id : null,
      name: clip(person.name, 80),
      role: clip(tv ? person.roles?.[0]?.character : person.character, 80) || null,
      profile: image(person.profile_path, "w185"),
    }));
  const crew: Person[] = tv
    ? list(item.created_by).slice(0, 4).map((person) => ({ id: Number.isSafeInteger(person.id) && person.id > 0 ? person.id : null, name: clip(person.name, 80), role: "Creator", profile: image(person.profile_path, "w185") }))
    : list(credits?.crew)
        .filter((person) => person.job === "Director")
        .slice(0, 3)
        .map((person) => ({ id: Number.isSafeInteger(person.id) && person.id > 0 ? person.id : null, name: clip(person.name, 80), role: "Director", profile: image(person.profile_path, "w185") }));
  const seasons: SeasonSummary[] = list(item.seasons).map((season) => ({
    number: season.season_number,
    name: clip(season.name, 80),
    episodeCount: season.episode_count ?? 0,
    year: yearOf(season.air_date),
    poster: image(season.poster_path, "w342"),
  }));
  let season: Details["season"] = null;
  if (tv && seasonNumber !== null && seasons.some((entry) => entry.number === seasonNumber)) {
    const value = await tmdb.get(`/tv/${id}/season/${seasonNumber}`, { language });
    if (value) {
      season = {
        number: seasonNumber,
        name: clip(value.name, 80),
        overview: clip(value.overview, 2000),
        poster: image(value.poster_path, "w342"),
        year: yearOf(value.air_date),
        episodes: list(value.episodes).map((episode) => ({
          number: episode.episode_number,
          name: clip(episode.name, 120),
          overview: clip(episode.overview, 600),
          still: image(episode.still_path, "w300"),
          airDate: typeof episode.air_date === "string" ? episode.air_date : null,
          runtime: number(episode.runtime),
          rating: episode.vote_count > 0 ? number(episode.vote_average) : null,
        })),
      };
    }
  }
  const date = (tv ? item.first_air_date : item.release_date) || null;
  return {
    mediaType: type,
    id,
    name: clip(tv ? item.name : item.title, 200) || translated(item.translations, language, tv ? "name" : "title"),
    originalName: clip(tv ? item.original_name : item.original_title, 200),
    tagline: clip(item.tagline, 300) || translated(item.translations, language, "tagline"),
    overview: clip(item.overview, 2000) || translated(item.translations, language, "overview"),
    year: yearOf(date),
    date,
    genres: list(item.genres).map((genre) => clip(genre.name, 40)).filter(Boolean),
    genreItems: list(item.genres).filter((genre) => Number.isSafeInteger(genre.id) && genre.id > 0 && clip(genre.name, 40)).map((genre) => ({ id: genre.id, name: clip(genre.name, 40) })),
    runtime: tv ? number(item.episode_run_time?.[0]) : number(item.runtime),
    rating: item.vote_count > 0 ? number(item.vote_average) : null,
    voteCount: item.vote_count ?? 0,
    countries: tv ? list(item.origin_country).map(String) : list(item.production_countries).map((country) => String(country.iso_3166_1)),
    status: clip(item.status, 40) || null,
    poster: image(item.poster_path, "w500"),
    backdrop: image(item.backdrop_path, "w1280"),
    logo: logo(item.images, language),
    heroPoster: heroPoster(item.images, item.poster_path),
    trailer: trailer(item.videos, language, item.imdb_id ?? item.external_ids?.imdb_id),
    stills: [...new Set(list(item.images?.backdrops).filter((entry) => typeof entry.file_path === "string" && entry.aspect_ratio > 1).map((entry) => image(entry.file_path, "w780")!))].slice(0, 8),
    studios: list(tv ? item.networks : item.production_companies).slice(0, 8).map((entry) => ({ id: Number.isSafeInteger(entry.id) && entry.id > 0 ? entry.id : null, kind: tv ? "network" : "company", name: clip(entry.name, 60), logo: image(entry.logo_path, "w300") })),
    cast,
    crew,
    networks: list(tv ? item.networks : item.production_companies).slice(0, 3).map((entry) => clip(entry.name, 60)),
    seasons,
    season,
    recommendations: related(item, type),
    link: `https://www.themoviedb.org/${type}/${id}`,
  };
}

// A candidate as the agent sees it: every name it goes by, and what tells apart works of the same name.
export async function facts(tmdb: TMDB, type: MediaType, id: number) {
  const item = await tmdb.get(`/${type}/${id}`, { language: "zh-CN", append_to_response: "alternative_titles,translations" });
  if (!item) return { error: "No such title." };
  const tv = type === "tv";
  const names = new Set<string>();
  for (const entry of list(tv ? item.alternative_titles?.results : item.alternative_titles?.titles)) names.add(clip(entry.title, 80));
  for (const entry of list(item.translations?.translations)) names.add(clip(entry.data?.[tv ? "name" : "title"], 80));
  names.delete("");
  return {
    mediaType: type,
    id,
    name: tv ? item.name : item.title,
    originalName: tv ? item.original_name : item.original_title,
    otherNames: [...names].slice(0, 30),
    year: yearOf(tv ? item.first_air_date : item.release_date),
    countries: tv ? item.origin_country : list(item.production_countries).map((country) => country.iso_3166_1),
    originalLanguage: item.original_language,
    genres: list(item.genres).map((genre) => genre.name),
    overview: clip(item.overview, 240) || clip(list(item.translations?.translations).find((entry) => entry.iso_639_1 === "en")?.data?.overview, 240),
    ...(tv
      ? {
          episodes: item.number_of_episodes,
          seasons: list(item.seasons).map((season) => ({ number: season.season_number, name: season.name, episodes: season.episode_count, year: yearOf(season.air_date) })),
        }
      : { runtime: item.runtime, collection: item.belongs_to_collection?.name ?? null }),
  };
}

// One search result, short: the agent reads many of these.
export function brief(result: any, type?: MediaType) {
  const mediaType: MediaType = type ?? result.media_type;
  const tv = mediaType === "tv";
  return {
    mediaType,
    id: result.id as number,
    name: (tv ? result.name : result.title) as string,
    originalName: (tv ? result.original_name : result.original_title) as string,
    year: yearOf(tv ? result.first_air_date : result.release_date),
    countries: tv ? result.origin_country : undefined,
    originalLanguage: result.original_language,
    votes: result.vote_count,
    overview: clip(result.overview, 100),
    poster: image(result.poster_path, "w342"),
  };
}

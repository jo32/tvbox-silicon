// Weekly airing calendars for the app: anime (番剧) and TV series, Monday to Sunday in China time.
// Each kind asks its best source first and falls back to the next one when a source fails or answers with too
// little to be real; the last good calendar kept in D1 is the final fallback. See README.md › Calendar.
//
//   anime: Bangumi /calendar (Chinese names, covers, ratings), with air times and TMDB IDs and streaming links from
//          bangumi-data and episode numbers from Simkl  →  Simkl's anime calendar  →  bangumi-data alone
//   tv:    TMDB's discover by air date (localized names, IDs the detail page opens), per region  →  TVmaze's schedule
//
// AniList's airing schedule would be the natural second source, but it answers 403 ("manually blocked") to every
// request from Cloudflare Workers. Sized for the Workers Free plan: one build makes at most ~30 outside requests.
import { image, TMDB } from "./tmdb.ts";

export type CalendarKind = "anime" | "tv";
export const ZONE = "Asia/Shanghai";
const OFFSET = 8 * 3600_000; // China time has no daylight saving.
const DAY_MS = 86400_000;
const UA = "yingxia-calendar/1.0 (+https://yingxia.getmegaportal.com)";
// Fewer than this many shows in a week means the source is broken, not that nothing airs.
const MINIMUM = { anime: 20, tv: 10 };

export interface CalendarItem {
  title: string;
  originalTitle: string;
  cover: string | null;
  airsAt: string | null; // ISO time, when the source knows it
  episode: number | null;
  season: number | null;
  rating: number | null; // out of 10
  network: string | null;
  overview: string | null; // a line or two about the show, when the source has one
  bangumi: number | null; // bgm.tv subject ID
  tmdb: { type: "tv" | "movie"; id: number; season: number | null } | null;
  links: { site: string; name: string; url: string }[]; // where it streams
}

export interface CalendarDay {
  date: string; // YYYY-MM-DD, China time
  weekday: number; // 1 = Monday … 7 = Sunday
  items: CalendarItem[];
}

export interface Calendar {
  kind: CalendarKind;
  source: string; // the source the list came from
  fallback: boolean; // true when that is not the kind's first choice
  stale: boolean; // true when every source failed and this is an older copy
  built: number; // unix seconds
  timeZone: string;
  days: CalendarDay[];
  attribution: { name: string; url: string }[];
  issues: string[]; // sources that failed or were skipped, for checking from outside
}

export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export interface Upstream {
  fetch: Fetch;
  now: number; // ms
  tmdb?: TMDB | null;
  language?: string;
  region?: Region; // TV only
  retryDelay?: number; // ms
}

// TV by where it's made: TMDB's origin countries, and TVmaze's for the fallback. Reality shows count where they are
// popular variety (China, Hong Kong and Taiwan, Korea); `all` is Chinese-language plus the regions below.
export const REGIONS = {
  all: { countries: "", tvmaze: ["CN"], reality: true },
  cn: { countries: "CN", tvmaze: ["CN"], reality: true },
  hktw: { countries: "HK|TW", tvmaze: ["HK", "TW"], reality: true },
  us: { countries: "US", tvmaze: ["US"], reality: false },
  jp: { countries: "JP", tvmaze: ["JP"], reality: false },
  kr: { countries: "KR", tvmaze: ["KR"], reality: true },
  gb: { countries: "GB", tvmaze: ["GB"], reality: false },
} as const;
export type Region = keyof typeof REGIONS;
export const isRegion = (value: string): value is Region => Object.hasOwn(REGIONS, value);

const CREDITS = {
  bangumi: { name: "Bangumi 番组计划", url: "https://bgm.tv" },
  bangumiData: { name: "bangumi-data (CC BY 4.0)", url: "https://github.com/bangumi-data/bangumi-data" },
  simkl: { name: "Simkl", url: "https://simkl.com" },
  tmdb: { name: "TMDB", url: "https://www.themoviedb.org" },
  tvmaze: { name: "TVmaze (CC BY-SA 4.0)", url: "https://www.tvmaze.com" },
};

// The Monday–Sunday week, China time, that holds `now`: its start and end as UTC ms and its seven dates.
export function week(now: number) {
  const local = new Date(now + OFFSET);
  const weekday = local.getUTCDay() || 7;
  const start = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate()) - (weekday - 1) * DAY_MS - OFFSET;
  const dates = Array.from({ length: 7 }, (_, i) => new Date(start + OFFSET + i * DAY_MS).toISOString().slice(0, 10));
  return { start, end: start + 7 * DAY_MS, dates };
}
type Week = ReturnType<typeof week>;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const https = (url: unknown) => (typeof url === "string" && url ? url.replace(/^http:\/\//, "https://") : null);
const str = (value: unknown, max = 200) => (typeof value === "string" ? value.trim().slice(0, max) : "");
const int = (value: unknown) => (Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : null);
const score = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.round(value * 10) / 10 : null);

// JSON from a source. Network errors, 429s and 5xx are tried once more; a 404 is null; anything else throws.
async function getJSON(up: Upstream, url: string, init: RequestInit = {}, tries = 2): Promise<any> {
  const host = new URL(url).host;
  let last: Error = new Error(`${host}: no answer`);
  for (let attempt = 0; attempt < tries; attempt++) {
    if (attempt) await sleep(up.retryDelay ?? 800);
    let response: Response;
    try {
      response = await up.fetch(url, {
        ...init,
        headers: { "user-agent": UA, accept: "application/json", ...(init.headers as Record<string, string> | undefined) },
        signal: AbortSignal.timeout(10_000),
      });
    } catch (error) {
      last = new Error(`${host}: ${(error as Error).message}`);
      continue;
    }
    if (response.status === 404) return null;
    if (response.ok) {
      try { return await response.json(); } catch { last = new Error(`${host}: not JSON`); continue; }
    }
    last = new Error(`${host} ${response.status}`);
    if (response.status !== 429 && response.status < 500) break;
  }
  throw last;
}

// At most `limit` requests at a time, so a source's rate limit isn't hit in one burst.
async function mapLimit<T, R>(values: T[], limit: number, task: (value: T) => Promise<R>): Promise<PromiseSettledResult<R>[]> {
  const results: PromiseSettledResult<R>[] = new Array(values.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, values.length) }, async () => {
    while (next < values.length) {
      const index = next++;
      try { results[index] = { status: "fulfilled", value: await task(values[index]) }; } catch (reason) { results[index] = { status: "rejected", reason }; }
    }
  }));
  return results;
}

// Seven days of items: `day` picks each item's day (0–6) or drops it with null.
function bucket<T>(w: Week, values: T[], day: (value: T) => number | null, item: (value: T) => CalendarItem, order: (a: CalendarItem, b: CalendarItem) => number): CalendarDay[] {
  const days: CalendarDay[] = w.dates.map((date, index) => ({ date, weekday: index + 1, items: [] }));
  for (const value of values) {
    const index = day(value);
    if (index !== null && index >= 0 && index < 7) days[index].items.push(item(value));
  }
  for (const each of days) each.items.sort(order);
  return days;
}
const count = (days: CalendarDay[]) => days.reduce((total, day) => total + day.items.length, 0);
const dayOf = (w: Week, ms: number) => Math.floor((ms - w.start) / DAY_MS);
// Timed shows first, by time; then the rest in the source's order.
const byTime = (a: CalendarItem, b: CalendarItem) => (a.airsAt ? (b.airsAt ? a.airsAt.localeCompare(b.airsAt) : -1) : b.airsAt ? 1 : 0);
const asGiven = () => 0;

// ---- Anime ----

// bangumi-data's streaming sites the app can link to (its data/sites/onair.json).
const SITES: Record<string, [string, string]> = {
  bilibili: ["哔哩哔哩", "https://www.bilibili.com/bangumi/media/md{{id}}/"],
  bilibili_hk_mo_tw: ["哔哩哔哩（港澳台）", "https://www.bilibili.com/bangumi/media/md{{id}}/"],
  bilibili_hk_mo: ["哔哩哔哩（港澳）", "https://www.bilibili.com/bangumi/media/md{{id}}/"],
  bilibili_tw: ["哔哩哔哩（台灣）", "https://www.bilibili.com/bangumi/media/md{{id}}/"],
  iqiyi: ["爱奇艺", "https://www.iqiyi.com/{{id}}.html"],
  qq: ["腾讯视频", "https://v.qq.com/detail/{{id}}.html"],
  youku: ["优酷", "https://list.youku.com/show/id_z{{id}}.html"],
  mgtv: ["芒果TV", "https://www.mgtv.com/h/{{id}}.html"],
  acfun: ["AcFun", "https://www.acfun.cn/bangumi/aa{{id}}"],
  netflix: ["Netflix", "https://www.netflix.com/title/{{id}}"],
};

export interface Entry {
  title: string;
  zh: string | null;
  bangumi: number | null;
  mal: number | null; // MyAnimeList, which Simkl lists by
  tmdb: CalendarItem["tmdb"];
  links: CalendarItem["links"];
  broadcast: { start: number; period: number } | null; // ms; period 0 = once
  end: number | null;
}

export function readEntry(raw: any): Entry | null {
  if (!raw || typeof raw.title !== "string") return null;
  const sites: any[] = Array.isArray(raw.sites) ? raw.sites : [];
  const id = (site: string) => sites.find((each) => each?.site === site)?.id;
  const tmdb = /^(tv|movie)\/(\d+)(?:\/season\/(\d+))?/.exec(String(id("tmdb") ?? ""));
  const rule = /^R\/([^/]+)\/P(\d+)D$/.exec(String(raw.broadcast ?? ""));
  const start = rule ? Date.parse(rule[1]) : NaN;
  const end = raw.end ? Date.parse(raw.end) : NaN;
  const links: CalendarItem["links"] = [];
  for (const site of sites) {
    const meta = SITES[site?.site];
    if (!meta || (!site.id && !site.url)) continue;
    const url = https(site.url) ?? meta[1].replace("{{id}}", encodeURIComponent(String(site.id)));
    if (/^https:\/\//.test(url) && !links.some((link) => link.url === url)) links.push({ site: site.site, name: meta[0], url });
  }
  return {
    title: str(raw.title),
    zh: str(raw.titleTranslate?.["zh-Hans"]?.[0]) || null,
    bangumi: int(id("bangumi")),
    mal: int(id("mal")),
    tmdb: tmdb ? { type: tmdb[1] as "tv" | "movie", id: Number(tmdb[2]), season: tmdb[3] ? Number(tmdb[3]) : null } : null,
    links,
    broadcast: Number.isFinite(start) ? { start, period: Number(rule![2]) * DAY_MS } : null,
    end: Number.isFinite(end) ? end : null,
  };
}

// When an entry airs in the week, from its broadcast rule (`R/<first>/P7D`).
export function airings(entry: Entry, w: Week): number[] {
  const rule = entry.broadcast;
  if (!rule || rule.start >= w.end) return [];
  const last = Math.min(w.end, entry.end !== null ? entry.end + DAY_MS : Infinity);
  if (rule.period === 0) return rule.start >= w.start && rule.start < last ? [rule.start] : [];
  const times: number[] = [];
  for (let at = rule.start + Math.max(0, Math.ceil((w.start - rule.start) / rule.period)) * rule.period; at < last && times.length < 7; at += rule.period) times.push(at);
  return times;
}

// The months whose bangumi-data files hold this season's shows: this month and the starts of this and the last
// three-month season (most shows begin in January, April, July or October and run one or two seasons).
export function months(now: number) {
  const local = new Date(now + OFFSET);
  const year = local.getUTCFullYear();
  const month = local.getUTCMonth();
  const season = month - (month % 3);
  const names = [month, season, season - 3].map((m) => {
    const date = new Date(Date.UTC(year, m, 1));
    return `${date.getUTCFullYear()}/${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
  });
  return [...new Set(names)];
}

async function bangumiData(up: Upstream): Promise<Entry[]> {
  const files = await Promise.all(months(up.now).map(async (month) => {
    const path = `data/items/${month}.json`;
    try {
      return await getJSON(up, `https://cdn.jsdelivr.net/gh/bangumi-data/bangumi-data@master/${path}`, {}, 1);
    } catch {
      return getJSON(up, `https://raw.githubusercontent.com/bangumi-data/bangumi-data/master/${path}`, {}, 1);
    }
  }));
  return files.flatMap((file) => (Array.isArray(file) ? file : [])).map(readEntry).filter((entry): entry is Entry => entry !== null);
}

// An episode from Simkl's anime calendar, a static file for the coming weeks. `at` is null where Simkl writes 00:00
// Japan time, its way of saying "that day" (late-night shows usually say 24:00 or later on the day before).
interface Airing { at: number | null; day: number; episode: number | null; mal: number; title: string; cover: string | null; rating: number | null }

async function simkl(up: Upstream, w: Week): Promise<Airing[]> {
  const body = await getJSON(up, "https://data.simkl.in/calendar/anime.json");
  if (!Array.isArray(body)) throw new Error("data.simkl.in: no calendar");
  return body.flatMap((each: any) => {
    const mal = int(each?.ids?.mal);
    const parts = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/.exec(String(each?.date ?? ""));
    const at = Date.parse(each?.date);
    if (!mal || !parts || !Number.isFinite(at)) return [];
    const timed = parts[2] !== "00" || parts[3] !== "00";
    // An untimed episode goes on its own date, China time.
    const day = dayOf(w, timed ? at : Date.parse(`${parts[1]}T00:00:00Z`) - OFFSET);
    if (day < 0 || day > 6) return [];
    const poster = str(each.poster);
    return [{ at: timed ? at : null, day, episode: int(each.episode?.episode), mal, title: str(each.title),
      cover: /^[\w/]+$/.test(poster) ? `https://simkl.in/posters/${poster}_m.jpg` : null, rating: score(each.ratings?.simkl?.rating) }];
  }).sort((a, b) => a.day - b.day || (a.at ?? 0) - (b.at ?? 0));
}

interface Subject { id: number; weekday: number; title: string; original: string; cover: string | null; rating: number | null }

async function bangumi(up: Upstream): Promise<Subject[]> {
  const body = await getJSON(up, "https://api.bgm.tv/calendar");
  if (!Array.isArray(body)) throw new Error("api.bgm.tv: no calendar");
  return body.flatMap((day: any) => {
    const weekday = int(day?.weekday?.id);
    if (!weekday || weekday > 7 || !Array.isArray(day.items)) return [];
    return day.items.flatMap((item: any) => {
      const id = int(item?.id);
      const original = str(item?.name);
      if (!id || !original) return [];
      return [{ id, weekday, title: str(item.name_cn) || original, original, cover: https(item.images?.common ?? item.images?.large), rating: score(item.rating?.score) }];
    });
  });
}

const blank = (): Omit<CalendarItem, "title" | "originalTitle"> => ({ cover: null, airsAt: null, episode: null, season: null, rating: null, network: null, overview: null, bangumi: null, tmdb: null, links: [] });

export async function buildAnime(up: Upstream): Promise<Calendar> {
  const w = week(up.now);
  // All three at once: each is needed whichever ends up as the list.
  const [subjects, entries, schedule] = await Promise.allSettled([bangumi(up), bangumiData(up), simkl(up, w)]);
  const data = entries.status === "fulfilled" ? entries.value : [];
  const airing = schedule.status === "fulfilled" ? schedule.value : [];
  const byBangumi = new Map(data.filter((entry) => entry.bangumi).map((entry) => [entry.bangumi!, entry]));
  const byMal = new Map(data.filter((entry) => entry.mal).map((entry) => [entry.mal!, entry]));
  const failures: string[] = [];
  const reason = (result: PromiseSettledResult<unknown>) => (result.status === "rejected" ? String(result.reason?.message ?? result.reason) : null);
  // The helpers' failures too: a Bangumi list without Simkl has no episode numbers.
  const issues = () => [...failures, ...[entries, schedule].map(reason).filter((value): value is string => value !== null && !failures.includes(value))];
  const made = (source: string, fallback: boolean, days: CalendarDay[], credits: { name: string; url: string }[]): Calendar =>
    ({ kind: "anime", source, fallback, stale: false, built: Math.floor(up.now / 1000), timeZone: ZONE, days, attribution: credits, issues: issues() });

  // 1. Bangumi: every show of the season on its weekday, timed by bangumi-data's broadcast rule (or Simkl), with
  //    Simkl's episode number.
  if (subjects.status === "fulfilled") {
    const firstAiring = new Map<number, Airing>();
    for (const each of airing) {
      const id = byMal.get(each.mal)?.bangumi;
      if (id && !firstAiring.has(id)) firstAiring.set(id, each);
    }
    const slot = (subject: Subject) => {
      const entry = byBangumi.get(subject.id);
      const episode = firstAiring.get(subject.id);
      const at = (entry ? airings(entry, w)[0] : undefined) ?? episode?.at ?? undefined;
      return { entry, episode, at, day: at !== undefined ? dayOf(w, at) : episode ? episode.day : subject.weekday - 1 };
    };
    const days = bucket(w, subjects.value, (subject) => slot(subject).day, (subject) => {
      const { entry, episode, at } = slot(subject);
      return { ...blank(), title: subject.title, originalTitle: subject.original, cover: subject.cover, rating: subject.rating, bangumi: subject.id,
        airsAt: at !== undefined ? new Date(at).toISOString() : null, episode: episode?.episode ?? null, tmdb: entry?.tmdb ?? null, links: entry?.links ?? [] };
    }, byTime);
    if (count(days) >= MINIMUM.anime) {
      return made("bangumi", false, days, [CREDITS.bangumi, ...(data.length ? [CREDITS.bangumiData] : []), ...(airing.length ? [CREDITS.simkl] : [])]);
    }
    failures.push(`bangumi: ${count(days)} shows`);
  } else failures.push(String(subjects.reason?.message ?? subjects.reason));

  // 2. Simkl: every episode that airs this week, named in Chinese and timed from bangumi-data where it knows the show.
  if (schedule.status === "fulfilled") {
    const days = bucket(w, airing, (each) => each.day, (each) => {
      const entry = byMal.get(each.mal);
      const at = (entry ? airings(entry, w).find((time) => dayOf(w, time) === each.day) : undefined) ?? each.at;
      return { ...blank(), title: entry?.zh ?? each.title, originalTitle: entry?.title ?? each.title, cover: each.cover, rating: each.rating,
        airsAt: at !== null ? new Date(at).toISOString() : null, episode: each.episode, bangumi: entry?.bangumi ?? null, tmdb: entry?.tmdb ?? null, links: entry?.links ?? [] };
    }, byTime);
    if (count(days) >= MINIMUM.anime) return made("simkl", true, days, [CREDITS.simkl, ...(data.length ? [CREDITS.bangumiData] : [])]);
    failures.push(`simkl: ${count(days)} episodes`);
  } else failures.push(String(schedule.reason?.message ?? schedule.reason));

  // 3. bangumi-data alone: this season's shows by their broadcast rules (no covers).
  const timed = data.flatMap((entry) => airings(entry, w).map((at) => ({ entry, at })));
  const days = bucket(w, timed, ({ at }) => dayOf(w, at), ({ entry, at }) => ({ ...blank(), title: entry.zh ?? entry.title, originalTitle: entry.title,
    airsAt: new Date(at).toISOString(), bangumi: entry.bangumi, tmdb: entry.tmdb, links: entry.links }), byTime);
  if (count(days) >= MINIMUM.anime) return made("bangumi-data", true, days, [CREDITS.bangumiData]);
  failures.push(entries.status === "rejected" ? String(entries.reason?.message ?? entries.reason) : `bangumi-data: ${count(days)} shows`);
  throw new Error(`No anime calendar: ${failures.join("; ")}`);
}

// ---- TV ----

// TMDB: the most popular series with an episode on each day, in Chinese, and from the places the app's viewers watch
// most (by popularity alone, European game shows and soaps filled the list). Animation (the anime calendar has it),
// news, daily soaps and talk shows are left out, and reality shows unless they are Chinese (variety shows).
const ABROAD = "US|GB|KR|JP|TW|HK|TH";
const genres = (reality: boolean) => (reality ? "16,10763,10766,10767" : "16,10763,10764,10766,10767");
// The start of a synopsis: the card shows two or three lines, so the rest would only make the response bigger.
function blurb(text: unknown): string | null {
  const clean = str(text).replace(/\s+/g, " ").trim();
  if (!clean) return null;
  return clean.length > 120 ? clean.slice(0, 119).trimEnd() + "…" : clean;
}

async function tmdbWeek(up: Upstream, w: Week): Promise<CalendarDay[]> {
  if (!up.tmdb) throw new Error("TMDB: no token");
  const region = REGIONS[up.region ?? "all"];
  const chinese = { with_original_language: "zh", without_genres: genres(true) };
  const abroad = { with_origin_country: ABROAD, without_genres: genres(false) };
  // Chinese first for a Chinese-speaking viewer: TMDB's popularity ranks them below the American ones.
  const lists: Record<string, string>[] = region.countries ? [{ with_origin_country: region.countries, without_genres: genres(region.reality) }]
    : (up.language ?? "zh-CN").startsWith("zh") ? [chinese, abroad] : [abroad, chinese];
  const queries = w.dates.flatMap((date, index) => lists.map((extra, list) => ({ index, date, list, extra })));
  const pages = await mapLimit(queries, 4, (query) => up.tmdb!.get("/discover/tv", {
    "air_date.gte": query.date, "air_date.lte": query.date, timezone: ZONE, language: up.language ?? "zh-CN",
    sort_by: "popularity.desc", include_adult: "false", page: 1, ...query.extra,
  }));
  const failed = pages.filter((page) => page.status === "rejected");
  // A stray failure leaves a thinner day; more means TMDB is having trouble.
  if (failed.length > 2) throw new Error(`TMDB: ${(failed[0] as PromiseRejectedResult).reason?.message}`);
  const shows = queries.flatMap((query, i) => {
    const page = pages[i];
    const results = page.status === "fulfilled" && Array.isArray(page.value?.results) ? page.value.results : [];
    return results.map((show: any) => ({ index: query.index, list: query.list, show }));
  });
  const seen = new Set<string>();
  const unique = shows.filter(({ index, show }) => {
    const key = `${index}:${show?.id}`;
    if (!int(show?.id) || !str(show?.name) || !show.poster_path || show.adult || seen.has(key)) return false;
    seen.add(key);
    return true;
  }).sort((a, b) => a.list - b.list || (Number(b.show.popularity) || 0) - (Number(a.show.popularity) || 0));
  return bucket(w, unique, ({ index }) => index, ({ show }) => ({ ...blank(), title: str(show.name), originalTitle: str(show.original_name) || str(show.name),
    cover: image(show.poster_path, "w342"), rating: show.vote_count > 0 ? score(show.vote_average) : null, overview: blurb(show.overview), tmdb: { type: "tv", id: show.id, season: null } }), asGiven);
}

// TVmaze: the region's streaming and broadcast schedules, with episode numbers and times (English or pinyin names).
async function tvmazeWeek(up: Upstream, w: Week): Promise<CalendarDay[]> {
  const queries = w.dates.flatMap((date, index) => REGIONS[up.region ?? "all"].tvmaze.flatMap((country) => [
    { index, url: `https://api.tvmaze.com/schedule/web?date=${date}&country=${country}` },
    { index, url: `https://api.tvmaze.com/schedule?country=${country}&date=${date}` },
  ]));
  const pages = await mapLimit(queries, 3, (query) => getJSON(up, query.url));
  const failed = pages.filter((page) => page.status === "rejected");
  if (failed.length > 2) throw new Error(String((failed[0] as PromiseRejectedResult).reason?.message));
  const seen = new Set<string>();
  const episodes = queries.flatMap((query, i) => {
    const page = pages[i];
    return (page.status === "fulfilled" && Array.isArray(page.value) ? page.value : []).flatMap((episode: any) => {
      const show = episode?._embedded?.show ?? episode?.show;
      const key = `${query.index}:${show?.id}`;
      if (!int(show?.id) || !str(show?.name) || seen.has(key)) return [];
      if (["News", "Sports", "Talk Show"].includes(show.type) || (Array.isArray(show.genres) && show.genres.includes("Anime"))) return [];
      seen.add(key);
      return [{ index: query.index, episode, show }];
    });
  }).sort((a, b) => (Number(b.show.weight) || 0) - (Number(a.show.weight) || 0));
  return bucket(w, episodes, ({ index }) => index, ({ episode, show }) => {
    const at = Date.parse(episode.airstamp);
    return { ...blank(), title: str(show.name), originalTitle: str(show.name), cover: https(show.image?.medium), airsAt: Number.isFinite(at) ? new Date(at).toISOString() : null,
      episode: int(episode.number), season: int(episode.season), rating: score(show.rating?.average), network: str((show.network ?? show.webChannel)?.name) || null,
      overview: blurb(str(show.summary).replace(/<[^>]*>/g, "")) };
  }, asGiven);
}

export async function buildTV(up: Upstream): Promise<Calendar> {
  const w = week(up.now);
  const failures: string[] = [];
  const made = (source: string, fallback: boolean, days: CalendarDay[], credit: { name: string; url: string }): Calendar =>
    ({ kind: "tv", source, fallback, stale: false, built: Math.floor(up.now / 1000), timeZone: ZONE, days, attribution: [credit], issues: [...failures] });
  try {
    const days = await tmdbWeek(up, w);
    if (count(days) >= MINIMUM.tv) return made("tmdb", false, days, CREDITS.tmdb);
    failures.push(`tmdb: ${count(days)} shows`);
  } catch (error) { failures.push((error as Error).message); }
  try {
    const days = await tvmazeWeek(up, w);
    if (count(days) >= MINIMUM.tv) return made("tvmaze", true, days, CREDITS.tvmaze);
    failures.push(`tvmaze: ${count(days)} shows`);
  } catch (error) { failures.push((error as Error).message); }
  throw new Error(`No TV calendar: ${failures.join("; ")}`);
}

// Bangumi's image host is unreachable on some networks (its DNS answers poisoned, connections reset) where this
// Worker's own domain is not, and its "common" cover is only 150 px wide. Covers go out as this Worker's
// /v1/cover/<path>, a 400 px resize of the large cover that the Worker fetches and caches.
const BANGUMI_COVER = /^https?:\/\/lain\.bgm\.tv\/(?:r\/\d+\/)?pic\/cover\/[a-z]\/([0-9a-f]{2}\/[0-9a-f]{2}\/\w+\.(?:jpe?g|png|webp|gif))$/i;
const COVER_PATH = /^r\/400\/pic\/cover\/l\/[0-9a-f]{2}\/[0-9a-f]{2}\/\w+\.(?:jpe?g|png|webp|gif)$/i;

/** The calendar with its Bangumi covers served from `origin` (this Worker's), others untouched. */
export function servingCovers(calendar: Calendar, origin: string): Calendar {
  const cover = (url: string | null) => {
    const match = url ? BANGUMI_COVER.exec(url) : null;
    return match ? `${origin}/v1/cover/r/400/pic/cover/l/${match[1]}` : url;
  };
  return { ...calendar, days: calendar.days.map((day) => ({ ...day, items: day.items.map((item) => ({ ...item, cover: cover(item.cover) })) })) };
}

/** The Bangumi image a /v1/cover/<path> stands for, or null for any other path: this is not an open proxy. */
export const coverSource = (path: string) => (COVER_PATH.test(path) ? `https://lain.bgm.tv/${path}` : null);

export const buildCalendar = (kind: CalendarKind, up: Upstream) => (kind === "anime" ? buildAnime(up) : buildTV(up));

// ---- Keeping and serving ----

export interface CalendarStore {
  load(kind: CalendarKind, language: string): Promise<string | null>;
  save(kind: CalendarKind, language: string, calendar: Calendar): Promise<void>;
}

const FRESH = 6 * 3600; // a calendar from the first-choice source is rebuilt after this
const FRESH_FALLBACK = 3600; // one from a fallback sooner, to get back to the first choice
const OLD = 24 * 3600; // older than this, it says it's stale
const RETRY = 5 * 60_000; // after a failed build, wait this long before trying again

// A calendar kept from an earlier week, moved onto this one by weekday: shows air on the same weekday each week.
// Episode numbers no longer hold, so they go.
export function redate(calendar: Calendar, now: number): Calendar {
  const w = week(now);
  const weeks = Math.round((w.start - (Date.parse(calendar.days[0]?.date + "T00:00:00Z") - OFFSET)) / (7 * DAY_MS));
  if (!weeks) return calendar;
  return {
    ...calendar,
    stale: true,
    days: calendar.days.map((day, index) => ({
      ...day,
      date: w.dates[index],
      items: day.items.map((item) => ({ ...item, episode: null, airsAt: item.airsAt ? new Date(Date.parse(item.airsAt) + weeks * 7 * DAY_MS).toISOString() : null })),
    })),
  };
}

const building = new Map<string, Promise<Calendar>>();
const failedAt = new Map<string, number>();

// This week's calendar: the kept one while it's fresh; past that, the kept one now and a rebuild in the background;
// with none for this week, a rebuild now, or when that fails, the last one kept (moved onto this week).
export async function calendarFor(kind: CalendarKind, language: string, store: CalendarStore, build: () => Promise<Calendar>, now: number, background: (job: Promise<unknown>) => void): Promise<Calendar> {
  const key = `${kind}|${language}`;
  const kept = await store.load(kind, language).catch(() => null);
  let saved: Calendar | null = null;
  try { saved = kept ? JSON.parse(kept) : null; } catch {}
  const rebuild = () => {
    let job = building.get(key);
    if (!job) {
      job = build()
        .then(async (calendar) => { failedAt.delete(key); await store.save(kind, language, calendar).catch((error) => console.error("calendar save", error.message)); return calendar; })
        .catch((error) => { failedAt.set(key, Date.now()); console.warn("calendar", key, error.message); throw error; })
        .finally(() => building.delete(key));
      building.set(key, job);
    }
    return job;
  };
  const resting = Date.now() - (failedAt.get(key) ?? 0) < RETRY;
  const age = saved ? Math.floor(now / 1000) - saved.built : Infinity;
  if (saved && saved.days?.[0]?.date === week(now).dates[0]) {
    if (age > (saved.fallback ? FRESH_FALLBACK : FRESH) && !resting) background(rebuild().catch(() => undefined));
    return age > OLD ? { ...saved, stale: true } : saved;
  }
  if (!saved) return rebuild();
  if (!resting) {
    try { return await rebuild(); } catch {}
  }
  return { ...redate(saved, now), stale: true };
}

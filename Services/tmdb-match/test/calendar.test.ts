import assert from "node:assert/strict";
import { test } from "node:test";
import { airings, buildAnime, buildTV, type Calendar, calendarFor, type CalendarStore, coverSource, months, readEntry, redate, servingCovers, week } from "../src/calendar.ts";
import { TMDB } from "../src/tmdb.ts";

// Wednesday 4 November 2026, noon in China.
const NOW = Date.parse("2026-11-04T04:00:00Z");

type Route = (url: string, init?: RequestInit) => Response | Promise<Response>;
function fetcher(routes: [RegExp, Route][], calls: string[] = []) {
  return async (url: string, init?: RequestInit) => {
    calls.push(url);
    for (const [pattern, route] of routes) if (pattern.test(url)) return route(url, init);
    return new Response("not found", { status: 404 });
  };
}
const down = () => new Response("down", { status: 503 });

const subjects = Array.from({ length: 25 }, (_, i) => ({ id: i + 1, name: `Show ${i + 1}`, name_cn: `番剧${i + 1}`, images: { common: `http://lain.bgm.tv/c/${i + 1}.jpg` }, rating: { score: 7.5 }, weekday: (i % 7) + 1 }));
const bangumiCalendar = () => Response.json(Array.from({ length: 7 }, (_, d) => ({ weekday: { id: d + 1, en: "" }, items: subjects.filter((s) => s.weekday === d + 1) })));
const entry = (n: number, extra: Record<string, unknown> = {}) => ({
  title: `日本語${n}`, titleTranslate: { "zh-Hans": [`中文${n}`] }, type: "tv", begin: "2026-10-07T15:00:00.000Z",
  broadcast: `R/2026-10-0${(n % 7) + 1}T15:00:00.000Z/P7D`, end: "",
  sites: [{ site: "bangumi", id: String(n) }, { site: "mal", id: String(100 + n) }, { site: "tmdb", id: `tv/${500 + n}/season/2` }, { site: "bilibili", id: "28" }, { site: "dmhy", id: "x" }],
  ...extra,
});
const october = () => Response.json(Array.from({ length: 22 }, (_, i) => entry(i + 1)));
// Simkl's calendar: a timed episode Thursday 00:30 Japan time (Wednesday 23:30 in China), then untimed ones on Friday.
const schedule = (n: number) => () => Response.json(Array.from({ length: n }, (_, i) => ({
  title: `English ${i}`, date: i === 0 ? "2026-11-05T00:30:00+09:00" : "2026-11-06T00:00:00+09:00", poster: `15/abc${i}`,
  ids: { simkl_id: 9000 + i, mal: String(101 + i) }, episode: { episode: 5 }, ratings: { simkl: { rating: 8.06 } },
})).concat([{ title: "Next week", date: "2026-11-12T00:00:00+09:00", poster: "x", ids: { mal: "999" }, episode: { episode: 1 } } as any]));

test("the week runs Monday to Sunday in China time", () => {
  const w = week(NOW);
  assert.deepEqual(w.dates, ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"]);
  assert.equal(new Date(w.start).toISOString(), "2026-11-01T16:00:00.000Z");
  // Sunday 23:30 in China is still the same week; Monday 00:30 is the next.
  assert.equal(week(Date.parse("2026-11-08T15:30:00Z")).dates[0], "2026-11-02");
  assert.equal(week(Date.parse("2026-11-08T16:30:00Z")).dates[0], "2026-11-09");
  assert.deepEqual(months(NOW), ["2026/11", "2026/10", "2026/07"]);
  assert.deepEqual(months(Date.parse("2027-01-10T00:00:00Z")), ["2027/01", "2026/10"]);
});

test("bangumi-data entries give links, TMDB IDs and this week's airings", () => {
  const value = readEntry(entry(3))!;
  assert.equal(value.zh, "中文3");
  assert.deepEqual(value.tmdb, { type: "tv", id: 503, season: 2 });
  assert.deepEqual(value.links, [{ site: "bilibili", name: "哔哩哔哩", url: "https://www.bilibili.com/bangumi/media/md28/" }]);
  assert.deepEqual(airings(value, week(NOW)).map((at) => new Date(at).toISOString()), ["2026-11-08T15:00:00.000Z"]);
  assert.deepEqual(airings(readEntry(entry(3, { end: "2026-10-28T15:00:00.000Z" }))!, week(NOW)), []);
  assert.deepEqual(airings(readEntry(entry(3, { broadcast: "" }))!, week(NOW)), []);
});

test("anime comes from Bangumi, timed and linked by bangumi-data, numbered by Simkl", async () => {
  const calls: string[] = [];
  const calendar = await buildAnime({ now: NOW, retryDelay: 0, fetch: fetcher([
    [/api\.bgm\.tv\/calendar/, bangumiCalendar],
    [/items\/2026\/10\.json/, october],
    [/items\/2026\/07\.json/, () => Response.json([])],
    [/simkl/, schedule(1)],
  ], calls) });
  assert.equal(calendar.source, "bangumi");
  assert.equal(calendar.fallback, false);
  assert.deepEqual(calendar.days.map((day) => day.date)[0], "2026-11-02");
  assert.equal(calendar.days.reduce((n, day) => n + day.items.length, 0), 25);
  // Show 1 is a Monday show on Bangumi; bangumi-data's rule puts this week's episode on Friday night, China time,
  // and Simkl numbers it.
  const show = calendar.days[4].items.find((item) => item.bangumi === 1)!;
  assert.equal(show.title, "番剧1");
  assert.equal(show.airsAt, "2026-11-06T15:00:00.000Z");
  assert.equal(show.episode, 5);
  assert.equal(show.cover, "https://lain.bgm.tv/c/1.jpg");
  assert.deepEqual(show.tmdb, { type: "tv", id: 501, season: 2 });
  assert.equal(show.links[0].site, "bilibili");
  // Show 2 has no Simkl episode: timed, but unnumbered.
  const second = calendar.days.flatMap((day) => day.items).find((item) => item.bangumi === 2)!;
  assert.ok(second.airsAt);
  assert.equal(second.episode, null);
  assert.deepEqual(calendar.attribution.map((credit) => credit.url), ["https://bgm.tv", "https://github.com/bangumi-data/bangumi-data", "https://simkl.com"]);
  assert.ok(calls.some((url) => url.startsWith("https://cdn.jsdelivr.net/")));
  assert.ok(!calls.some((url) => url.includes("raw.githubusercontent")));
  assert.deepEqual(calendar.issues, []);
});

test("anime falls back to Simkl, then bangumi-data, and fails only when all three do", async () => {
  const fromSimkl = await buildAnime({ now: NOW, retryDelay: 0, fetch: fetcher([
    [/api\.bgm\.tv/, down], [/jsdelivr.*items\/2026\/10/, down], [/githubusercontent.*items\/2026\/10/, october], [/simkl/, schedule(24)],
  ]) });
  assert.equal(fromSimkl.source, "simkl");
  assert.equal(fromSimkl.fallback, true);
  // Simkl's 00:30 Japan time is Wednesday 23:30 in China; bangumi-data has no Wednesday rule for show 1, so Simkl's
  // time stands. Names come from bangumi-data (its mirror), not Simkl's English.
  const first = fromSimkl.days[2].items[0];
  assert.equal(first.title, "中文1");
  assert.equal(first.originalTitle, "日本語1");
  assert.equal(first.airsAt, "2026-11-04T15:30:00.000Z");
  assert.equal(first.bangumi, 1);
  assert.equal(first.rating, 8.1);
  assert.equal(first.cover, "https://simkl.in/posters/15/abc0_m.jpg");
  // Untimed Friday episodes take bangumi-data's Friday time where it has one; next week's is left out.
  assert.equal(fromSimkl.days[4].items.length, 23);
  assert.ok(!fromSimkl.days.flatMap((day) => day.items).some((item) => item.title === "Next week"));
  assert.deepEqual(fromSimkl.issues, ["api.bgm.tv 503"]);

  // Bangumi answers but with almost nothing: that's broken, not a quiet week.
  const thin = () => Response.json([{ weekday: { id: 1 }, items: subjects.slice(0, 2) }]);
  const data = await buildAnime({ now: NOW, retryDelay: 0, fetch: fetcher([[/api\.bgm\.tv/, thin], [/items\/2026\/10/, october], [/simkl/, down]]) });
  assert.equal(data.source, "bangumi-data");
  assert.equal(data.days.reduce((n, day) => n + day.items.length, 0), 22);
  assert.equal(data.days[0].items[0].cover, null);
  assert.deepEqual(data.issues, ["bangumi: 2 shows", "data.simkl.in 503"]);

  await assert.rejects(buildAnime({ now: NOW, retryDelay: 0, fetch: fetcher([[/./, down]]) }), /No anime calendar: api\.bgm\.tv 503/);
});

const tmdbShows = (offset: number) => Response.json({ results: Array.from({ length: 8 }, (_, i) => ({ id: offset + i, name: `剧${offset + i}`, original_name: `Drama ${offset + i}`, poster_path: `/${i}.jpg`, popularity: 100 - i, vote_count: 3, vote_average: 7.25 })) });
const tvmaze = (url: string) => Response.json(url.includes("/web") ? [
  { airstamp: "2026-11-04T12:00:00+00:00", season: 1, number: 7, _embedded: { show: { id: 1, name: "Wan Jie Du Zun", type: "Scripted", genres: [], weight: 90, image: { medium: "https://static.tvmaze.com/1.jpg" }, webChannel: { name: "Tencent QQ" }, rating: { average: 8 } } } },
  { airstamp: "2026-11-04T13:00:00+00:00", season: 1, number: 8, _embedded: { show: { id: 1, name: "Wan Jie Du Zun", type: "Scripted", genres: [], weight: 90 } } },
] : [
  { airstamp: "2026-11-04T11:00:00+00:00", season: 1, number: 1, show: { id: 2, name: "News", type: "News", genres: [], weight: 99 } },
  { airstamp: "2026-11-04T11:00:00+00:00", season: 1, number: 2, show: { id: 3, name: "Anime", type: "Animation", genres: ["Anime"], weight: 99 } },
  { airstamp: "2026-11-04T11:30:00+00:00", season: 2, number: 3, show: { id: 4, name: "Drama Four", type: "Scripted", genres: ["Drama"], weight: 10 } },
]);

test("TV comes from TMDB by air date, Chinese-language titles included", async () => {
  const urls: string[] = [];
  const tmdb = new TMDB("token", async (url) => { urls.push(url); return url.includes("with_original_language=zh") ? tmdbShows(1000) : tmdbShows(1); }, null);
  const calendar = await buildTV({ now: NOW, retryDelay: 0, tmdb, language: "zh-TW", fetch: fetcher([[/tvmaze/, tvmaze]]) });
  assert.equal(calendar.source, "tmdb");
  assert.equal(urls.length, 14);
  assert.ok(urls[0].includes("air_date.gte=2026-11-02") && urls[0].includes("air_date.lte=2026-11-02") && urls[0].includes("language=zh-TW"));
  // Chinese first for a Chinese-speaking viewer; reality shows only from the Chinese list.
  assert.ok(urls[0].includes("timezone=Asia%2FShanghai") && urls[0].includes("with_original_language=zh") && urls[0].includes("without_genres=16%2C10763%2C10766%2C10767"));
  assert.ok(urls[1].includes("with_origin_country=US%7CGB%7CKR%7CJP%7CTW%7CHK%7CTH") && urls[1].includes("without_genres=16%2C10763%2C10764%2C10766%2C10767"));
  const day = calendar.days[2];
  assert.equal(day.items.length, 16);
  assert.deepEqual(day.items.map((item) => item.tmdb!.id).slice(0, 9), [1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1]);
  assert.equal(day.items[0].cover, "https://images.tmdb.org/t/p/w342/0.jpg");
  assert.equal(day.items[0].rating, 7.3);
});

test("a TV region asks TMDB for its origin countries, and TVmaze for its own schedules", async () => {
  const urls: string[] = [];
  const tmdb = new TMDB("token", async (url) => { urls.push(url); return tmdbShows(1); }, null);
  const us = await buildTV({ now: NOW, retryDelay: 0, tmdb, region: "us", fetch: fetcher([]) });
  assert.equal(us.source, "tmdb");
  assert.equal(urls.length, 7);
  assert.ok(urls.every((url) => url.includes("with_origin_country=US&") && url.includes("without_genres=16%2C10763%2C10764%2C10766%2C10767") && !url.includes("with_original_language")));
  const korean = await buildTV({ now: NOW, retryDelay: 0, tmdb, region: "kr", fetch: fetcher([]) });
  assert.ok(urls.at(-1)!.includes("with_origin_country=KR&") && urls.at(-1)!.includes("without_genres=16%2C10763%2C10766%2C10767"));
  assert.equal(korean.source, "tmdb");
  const asked: string[] = [];
  const fallback = await buildTV({ now: NOW, retryDelay: 0, tmdb: null, region: "hktw", fetch: fetcher([[/tvmaze/, tvmaze]], asked) });
  assert.equal(fallback.source, "tvmaze");
  assert.equal(asked.length, 28);
  assert.ok(asked.some((url) => url.includes("country=HK")) && asked.some((url) => url.includes("country=TW")));
});

test("TV falls back to TVmaze when TMDB fails or comes back empty", async () => {
  for (const answer of [() => new Response("", { status: 500 }), () => Response.json({ results: [] })]) {
    const tmdb = new TMDB("token", async () => answer(), null);
    const calendar = await buildTV({ now: NOW, retryDelay: 0, tmdb, fetch: fetcher([[/tvmaze/, tvmaze]]) });
    assert.equal(calendar.source, "tvmaze");
    assert.equal(calendar.fallback, true);
    assert.equal(calendar.attribution[0].url, "https://www.tvmaze.com");
    assert.equal(calendar.issues.length, 1);
    // One item per show per day (news and anime left out), with its episode and time.
    assert.deepEqual(calendar.days[2].items.map((item) => [item.title, item.episode, item.airsAt, item.network]), [["Wan Jie Du Zun", 7, "2026-11-04T12:00:00.000Z", "Tencent QQ"], ["Drama Four", 3, "2026-11-04T11:30:00.000Z", null]]);
  }
  const none = await buildTV({ now: NOW, retryDelay: 0, tmdb: null, fetch: fetcher([[/tvmaze/, tvmaze]]) });
  assert.equal(none.source, "tvmaze");
  await assert.rejects(buildTV({ now: NOW, retryDelay: 0, tmdb: null, fetch: fetcher([[/./, down]]) }), /No TV calendar: TMDB: no token; api\.tvmaze\.com 503/);
});

function memory(initial?: Calendar) {
  const rows = new Map<string, string>();
  const store: CalendarStore & { rows: typeof rows } = {
    rows,
    load: async (kind, language) => rows.get(`${kind}|${language}`) ?? null,
    save: async (kind, language, calendar) => void rows.set(`${kind}|${language}`, JSON.stringify(calendar)),
  };
  if (initial) rows.set(`${initial.kind}|test`, JSON.stringify(initial));
  return store;
}
const made = (now: number, source = "bangumi", fallback = false): Calendar => ({ kind: "anime", source, fallback, stale: false, built: Math.floor(now / 1000), timeZone: "Asia/Shanghai",
  days: week(now).dates.map((date, i) => ({ date, weekday: i + 1, items: [{ title: "A", originalTitle: "A", cover: null, airsAt: `${date}T15:00:00.000Z`, episode: 3, season: null, rating: null, network: null, bangumi: 1, tmdb: null, links: [] }] })), attribution: [], issues: [] });

test("a kept calendar is served while fresh and rebuilt in the background once it ages", async () => {
  let builds = 0;
  const jobs: Promise<unknown>[] = [];
  const build = async () => { builds++; return made(NOW, "bangumi"); };
  const fresh = memory(made(NOW - 3600_000));
  assert.equal((await calendarFor("anime", "test", fresh, build, NOW, (job) => jobs.push(job))).source, "bangumi");
  assert.equal(builds, 0);

  const aging = memory(made(NOW - 7 * 3600_000));
  const served = await calendarFor("anime", "test", aging, build, NOW, (job) => jobs.push(job));
  assert.equal(served.built, Math.floor((NOW - 7 * 3600_000) / 1000));
  await Promise.all(jobs);
  assert.equal(builds, 1);
  assert.equal(JSON.parse(aging.rows.get("anime|test")!).built, Math.floor(NOW / 1000));

  // One from a fallback source is retried after an hour.
  const fallback = memory(made(NOW - 2 * 3600_000, "anilist", true));
  await calendarFor("anime", "test-fallback", { ...fallback, load: async () => fallback.rows.get("anime|test")! }, build, NOW, (job) => jobs.push(job));
  await Promise.all(jobs);
  assert.equal(builds, 2);
});

test("when every source fails, last week's calendar is moved onto this week; with none, the error shows", async () => {
  const lastWeek = NOW - 7 * 86400_000;
  const failing = async (): Promise<Calendar> => { throw new Error("No anime calendar: all down"); };
  const served = await calendarFor("anime", "test", memory(made(lastWeek)), failing, NOW, () => {});
  assert.equal(served.stale, true);
  assert.equal(served.days[0].date, "2026-11-02");
  assert.equal(served.days[2].items[0].airsAt, "2026-11-04T15:00:00.000Z");
  assert.equal(served.days[2].items[0].episode, null);
  assert.equal(redate(made(NOW), NOW).stale, false);

  await assert.rejects(calendarFor("anime", "test-none", memory(), failing, NOW, () => {}), /all down/);
  // A kept copy from today is never rebuilt inline, even right after a failure.
  const today = await calendarFor("anime", "test", memory({ ...made(NOW - 30 * 3600_000), kind: "anime" }), failing, NOW, () => {});
  assert.equal(today.stale, true);
});

test("Bangumi covers are served by the Worker at 400 px, and the cover route only fetches Bangumi covers", () => {
  const item = (cover: string | null) => ({ title: "t", originalTitle: "t", cover, airsAt: null, episode: null, season: null, rating: null, network: null, overview: null, bangumi: null, tmdb: null, links: [] });
  const calendar = { ...made(NOW), days: [{ date: "2026-11-04", weekday: 3, items: [
    item("https://lain.bgm.tv/pic/cover/c/52/fe/418229_gcFij.jpg"), item("https://image.tmdb.org/t/p/w342/x.jpg"), item(null)] }] } as Calendar;
  const served = servingCovers(calendar, "https://w.example").days[0].items.map((each) => each.cover);
  assert.deepEqual(served, ["https://w.example/v1/cover/r/400/pic/cover/l/52/fe/418229_gcFij.jpg", "https://image.tmdb.org/t/p/w342/x.jpg", null]);
  assert.equal(calendar.days[0].items[0].cover, "https://lain.bgm.tv/pic/cover/c/52/fe/418229_gcFij.jpg");
  assert.equal(coverSource("r/400/pic/cover/l/52/fe/418229_gcFij.jpg"), "https://lain.bgm.tv/r/400/pic/cover/l/52/fe/418229_gcFij.jpg");
  for (const path of ["r/400/pic/cover/l/52/fe/../../x.jpg", "r/4000/pic/cover/l/52/fe/a.jpg", "https://evil.example/a.jpg", "pic/user/l/52/fe/a.jpg"]) assert.equal(coverSource(path), null);
});

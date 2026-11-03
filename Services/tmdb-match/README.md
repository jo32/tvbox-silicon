# TMDB match

Finds the TMDB movie or series behind a source's video, so the app's detail page can show TMDB's artwork, cast,
facts, episode stills and "you may like" (TMDB's recommendations, topped up with similar titles, in the same
TMDB request). Worker `yingxia-tmdb` at https://yingxia-tmdb.getmegaportal.com, D1 `yingxia-tmdb`.

## How it works

- `POST /v1/match` takes what the source knows about the video: `title`, and optionally `year`, `type` (`tv`|`movie`),
  `remarks`, `synopsis`, `area`, `category` (the source's category and genre tags), `episodes` (names, in order),
  `language` (`zh-CN`, `zh-TW`, `zh-HK`, `en-US`, `ja-JP`), and `source` (`{key, name}`) + `item` (the video's ID there).
  It answers with JSON lines: `{"type":"progress","step":"search","query":"…"}` while the agent works, then one
  `{"type":"result",…}` or `{"type":"error","code":"upstream|model|busy|internal",…}`.
- A result is `matched` (with `match` and `details`), `ambiguous` (with `candidates` to choose from) or `notFound`.
  Failures are errors, never `notFound`, and are not kept.
- An AI agent (`src/agent.ts`) defaults to OpenAI Responses with `gpt-6-luna` (`AI_PROVIDER=openai`,
  `OPENAI_MODEL=gpt-6-luna`). Set `AI_PROVIDER=gemini` to use the retained Gemini implementation and
  `GEMINI_MODEL` again. Both providers search TMDB with tools (`search`, `details`, `season`)
  and submit an answer. The agent may only name works the tools showed; `matched` needs confidence ≥ 0.8, else it becomes
  `ambiguous`. Budgets per run: 8 searches (pages count), 6 details, 3 seasons, 10 model turns. Before searching it
  decides whether the video can be on TMDB at all: AI-generated videos and short dramas are `notFound` (reason
  `AI-generated: …` / `Short drama: …`), kept 120 days. The app already skips videos whose source labels them so.
- A search's first 3 results come with their details, so most matches take 2–3 model calls (search, maybe one more
  check, submit). OpenAI replays tool calls and encrypted reasoning with `store: false`; prompt caching is automatic.
  `matches.model`, `tokens` and `cached_tokens` record the selected model and its usage.
  When Gemini is selected, the instructions and tools every call starts with sit in a Gemini context cache
  shared by all runs: cached tokens cost a tenth. A run that finds no live cache (table `gemini_cache`) makes one for an
  hour; a changed prompt, tool or model makes a new one. `matches.cached_tokens` shows how much of each run it covered.
- Model calls use the retained `GeminiRelay` Durable Object. OpenAI uses a US-jurisdiction subnamespace so compute
  runs in the US; a location hint alone is not a guarantee. Gemini keeps its existing objects and North American
  hint to avoid "User location is not supported" errors. The relay accepts only the two providers' API hosts.
  OpenAI requests run in an alarm event with fresh server headers, so the viewer's edge metadata is not forwarded.
  Pending requests stay in memory while their fetch handlers wait; only the alarm time is persisted. Buffered
  response bytes return to the corresponding caller, since streams cannot cross event contexts. Each upstream
  request has a 60-second timeout; a relay failure uses the transport's normal retry/error handling.
- Answers are kept in D1 by `version|title|year|type` for every viewer: matched 120 days, ambiguous 30, not found 7.
  The title is compared after NFKC, lower case and collapsed spaces only; `第四季` or a `2` still makes another title.
  Bump `VERSION` in `src/source.ts` when the prompt changes enough that old answers should go.
- `season`, `numbering` (`season`: the source counts from 1 in that season; `absolute`: across seasons) and `offset`
  (TMDB episodes before the source's first, when TMDB lists two broadcast seasons as one) let the app line its
  episodes up with TMDB's. `unmatched` holds the title's words outside the TMDB name, verbatim.
- `GET /v1/details?type=tv&id=…&season=…&language=…` gives one work's details, for a candidate the viewer picked.
- `GET /v1/catalog?feed=trending&page=1&language=zh-CN` supplies Discover's catalog rails. Feed names are
  allowlisted in `src/catalog.ts`; pages are limited to 1–500. Results retain movie/series identity, artwork,
  year, genre IDs and TMDB rating. Adult results and people are excluded from title lists.
- `GET /v1/catalog/collections?language=zh-CN` supplies popular people with their known works and the
  allowlisted network/studio logos. A failed individual logo lookup does not discard the other brands.
  Both catalog endpoints reuse the details rate limiter and upstream cache; neither invokes an AI model nor
  writes to the match database. TMDB credentials remain on the Worker.
- `GET /v1/catalog/search` powers the separate Discover search. `mode=search&q=…&kind=movie|tv|person`
  returns paged title cards or people; `mode=recommend&feed=day|week|popular` supplies the initial groups.
  `mode=discover` supports bounded genre, year, rating, vote-count, runtime, language, region, network/studio,
  and keyword filters. `mode=keywords&q=…` resolves keyword IDs; `mode=person&id=…` returns a deduplicated
  filmography. The handler validates all parameters before accessing TMDB, has its own 120/minute limiter,
  and never accesses source-video search, AI models or D1. Search history stays on the device.
- Reverse lookup: matched answers and viewers' picks (`POST /v1/link`) are kept in `links`, one row per source video.
  `GET /v1/search?q=…` searches TMDB and says how many source videos each result has; `GET /v1/sources?type=&id=`
  lists them. An agent's answer never replaces a viewer's pick.
- TMDB answers are cached per data center for a day (Cache API). 429s wait for Retry-After and try again. Model 429s
  wait when the wait is short (per-minute limits); exhausted quota and long waits fail at once.
- Limits: 20 runs a minute per IP (only cache misses), `DAILY_RUNS` agent runs a day in all.

## Deploy

```sh
../../website/node_modules/.bin/wrangler d1 execute yingxia-tmdb --remote --file schema.sql
../../website/node_modules/.bin/wrangler secret put OPENAI_API_KEY
../../website/node_modules/.bin/wrangler secret put GEMINI_API_KEY # retained; only needed for Gemini
../../website/node_modules/.bin/wrangler secret put TMDB_TOKEN   # TMDB's v4 read access token
../../website/node_modules/.bin/wrangler deploy
```

Credentials belong in Worker secrets. For local development use an ignored `.dev.vars` file; never put keys in
`wrangler.jsonc`, app sources or the website. Missing selected-provider credentials fail explicitly; there is no
automatic fallback to another provider. Existing cached matches remain valid and are reused until expiry.

An existing database gets new columns and tables from `migrations/` (`wrangler d1 execute … --file migrations/…`).

Test: `node --test test/*.test.ts`. Try the matcher on real sources with the probe (from the repo root):
`swift run TVBoxProbe --tmdb-sample <subscription> <per source> > samples.jsonl`, then
`swift run TVBoxProbe --tmdb-check samples.jsonl [parallel]`, which prints one JSON line per video: the answer, the
steps, the time and how its episodes line up.

Check answers: `wrangler d1 execute yingxia-tmdb --remote --command "SELECT title, status, media_type, tmdb_id, season, confidence, reason FROM matches ORDER BY created DESC LIMIT 50"`.
Fix a wrong one by deleting its row; the next viewer asks again.

This product uses the TMDB API but is not endorsed or certified by TMDB.

### People and related browsing

`GET /v1/catalog/search?mode=profile&id=<person-id>&language=<language>` returns a localized person profile and combined movie/TV credits. Each work retains its full date, roles and contribution departments; duplicate cast/crew appearances merge by typed media identity. Undated works follow dated works.

Title details retain optional person IDs, `genreItems` (ID and localized name), and studio IDs with `network`/`company` kind. Related pages query the existing discover mode with `genres`, `networks` or `companies`, preserving media type, sorting and pagination. Platform IDs accept bounded positive integers instead of only the home page's preset brands. Profile requests share the catalog search limiter.

## Calendar

`GET /v1/calendar?kind=anime|tv&language=zh-CN[&region=all|cn|hktw|us|jp|kr|gb]` gives this week's airing calendar,
Monday to Sunday in China time (`timeZone`, `days[].date`, `days[].weekday` 1–7). Each item has `title`,
`originalTitle`, `cover`, and when the source knows them `airsAt` (ISO), `episode`, `season`, `rating`, `network`,
`bangumi` (bgm.tv ID), `tmdb` (`{type, id, season}`: the app's detail page can open it) and `links` (streaming sites).
`region` (series only, default `all`) picks where they are made. Code: `src/calendar.ts`.

Each kind tries its sources in order. A source that fails, or answers with less than a real week (under 20 anime or
10 series), is skipped for the next:

| kind  | 1st choice | then | then |
|-------|------------|------|------|
| anime | Bangumi `api.bgm.tv/calendar` (Chinese names, covers, ratings), timed and linked by bangumi-data, numbered by Simkl | Simkl's `data.simkl.in/calendar/anime.json`, named in Chinese and timed by bangumi-data | bangumi-data's broadcast rules alone (no covers) |
| tv    | TMDB `/discover/tv` by air date and origin country (no animation, news, daily soaps or talk shows; reality only for cn, hktw, kr). `all` = Chinese-language first, then US, GB, KR, JP, TW, HK, TH | TVmaze `/schedule/web` + `/schedule` for the region's countries (English or pinyin names, with episodes and times) | — |

AniList's airing schedule is not used: it answers 403 "You have been manually blocked" to every request from
Cloudflare Workers. bangumi-data comes per month (this month and this and the last season's first month) from
jsDelivr, or from raw.githubusercontent.com when jsDelivr fails. Requests that fail with a network error, 429 or 5xx
are tried once more. The answer says which source it came from (`source`, and `fallback: true` when it isn't the
first choice), what failed on the way (`issues`), and whom to credit (`attribution`: the app must show these; TVmaze
is CC BY-SA, bangumi-data CC BY).

Calendars are kept in D1 (`calendars`, one row per kind and language|region; anime names don't depend on the
language, so anime is kept once as `*`). A request is answered from D1; a calendar older than 6 hours (1 hour when it
came from a fallback) is rebuilt in the background. With none kept for this week a request waits for a build, and
when every source fails it gets the last calendar kept, moved onto this week by weekday, with `stale: true` and no
episode numbers. A failed build is not retried for 5 minutes. With nothing kept at all, it answers 502 with the
reasons. A build makes at most about 30 outside requests (Workers Free allows 50).

Add the table to an existing database with `migrations/0005-calendars.sql`.

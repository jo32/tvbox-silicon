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

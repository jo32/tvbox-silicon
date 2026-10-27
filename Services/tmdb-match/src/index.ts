// Finds the TMDB movie or series behind a source's video for the app's detail page (Sources/TVCore/TMDBMatch.swift).
// A Gemini agent searches TMDB (src/agent.ts); its answer is kept in D1 by title, so the next viewer of the same
// title, on any source, gets it at once. The app sees progress while the agent works: the answer is a stream of
// JSON lines, the last one the result. TMDB's own answers are cached per data center for a day (src/tmdb.ts).
// It also works the other way: each matched source video is linked to its TMDB work, so a TMDB title found with
// /v1/search lists the source videos viewers found it on (/v1/sources).
import { identify, ModelError, type Source, type Verdict } from "./agent.ts";
import { cacheKey, readSource, readSourceVideo, type SourceVideo, text } from "./source.ts";
import { brief, details } from "./details.ts";
import { type Fetcher, image, type MediaType, TMDB, UpstreamError } from "./tmdb.ts";
import { DurableObject } from "cloudflare:workers";

interface Env {
  DB: D1Database;
  GEMINI_RELAY: DurableObjectNamespace<GeminiRelay>;
  MATCH_LIMITER: RateLimit;
  DETAILS_LIMITER: RateLimit;
  // Secrets: wrangler secret put GEMINI_API_KEY / TMDB_TOKEN (TMDB's v4 read access token).
  GEMINI_API_KEY: string;
  TMDB_TOKEN: string;
  GEMINI_MODEL: string;
  // Agent runs a day, all viewers together: a cap on what a flood of new titles (or abuse) can cost.
  DAILY_RUNS: string;
}

const MAX_BODY = 64 * 1024;
const DAY = 86400;
// How long an answer stands. TMDB adds titles every day, so "not found" is asked again sooner.
const KEEP = { matched: 120 * DAY, ambiguous: 30 * DAY, notFound: 7 * DAY };
// An AI-generated video or a short drama won't turn up on TMDB later: keep that answer as long as a match.
const keep = (verdict: Verdict) => (verdict.status === "notFound" && /^(AI-generated|Short drama)/i.test(verdict.reason) ? KEEP.matched : KEEP[verdict.status]);
const LANGUAGES = new Set(["zh-CN", "zh-TW", "zh-HK", "en-US", "ja-JP"]);

interface Row {
  key: string;
  status: Verdict["status"];
  media_type: MediaType | null;
  tmdb_id: number | null;
  season: number | null;
  numbering: Verdict["numbering"];
  episode_offset: number;
  confidence: number;
  unmatched: string;
  reason: string;
  candidates: string;
}

// What the app gets: the verdict, the candidates to choose from, and for a match its details.
async function result(tmdb: TMDB, verdict: Verdict, candidates: unknown[], language: string, cached: boolean) {
  const matched = verdict.status === "matched" && verdict.mediaType && verdict.id !== null;
  return {
    type: "result",
    status: verdict.status,
    match: matched
      ? { mediaType: verdict.mediaType, id: verdict.id, season: verdict.season, numbering: verdict.numbering, offset: verdict.offset, confidence: verdict.confidence, unmatched: verdict.unmatched }
      : null,
    season: verdict.season,
    numbering: verdict.numbering,
    unmatched: verdict.unmatched,
    candidates,
    details: matched ? await details(tmdb, verdict.mediaType!, verdict.id!, language, verdict.season) : null,
    cached,
  };
}

function fromRow(row: Row): Verdict {
  const candidates = JSON.parse(row.candidates || "[]");
  return {
    status: row.status,
    mediaType: row.media_type,
    id: row.tmdb_id,
    season: row.season,
    numbering: row.numbering,
    offset: row.episode_offset ?? 0,
    confidence: row.confidence,
    unmatched: row.unmatched,
    reason: row.reason,
    candidates: candidates.map((item: any) => ({ mediaType: item.mediaType, id: item.id })),
  };
}

const GEMINI = "https://generativelanguage.googleapis.com/";

// Gemini turns away calls from some places Cloudflare runs Workers (Hong Kong, where viewers in China land:
// "User location is not supported"), and a placement hint did not change what Google sees. A Durable Object made
// with a location hint does run there, so the model's calls go out through one in eastern North America.
export class GeminiRelay extends DurableObject<Env> {
  async fetch(request: Request) {
    if (!request.url.startsWith(GEMINI)) return new Response(null, { status: 400 });
    return fetch(request.url, { method: "POST", headers: request.headers, body: request.body });
  }
}

// A few relays, so one busy object doesn't hold up every lookup.
function relay(env: Env): Fetcher {
  return (url, init) => {
    const name = `gemini-${Math.floor(Math.random() * 4)}`;
    return env.GEMINI_RELAY.get(env.GEMINI_RELAY.idFromName(name), { locationHint: "enam" }).fetch(url, init);
  };
}

// Requests for the same title in this isolate share one agent run.
const running = new Map<string, Promise<{ verdict: Verdict; candidates: unknown[] }>>();

async function match(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY) return new Response(null, { status: 413 });
  let body: any;
  try {
    body = JSON.parse((await request.text()).slice(0, MAX_BODY));
  } catch {
    return new Response(null, { status: 400 });
  }
  const source = readSource(body);
  if (!source) return new Response(null, { status: 400 });
  const video = readSourceVideo(body);
  const language = LANGUAGES.has(body?.language) ? body.language : "zh-CN";
  const key = cacheKey(source);
  const now = Math.floor(Date.now() / 1000);
  const tmdb = new TMDB(env.TMDB_TOKEN);

  const stream = new TransformStream<Uint8Array, Uint8Array>();
  const writer = stream.writable.getWriter();
  const encoder = new TextEncoder();
  // The viewer may leave mid-run; the run still finishes and is kept for the next one.
  const send = (event: Record<string, unknown>) => writer.write(encoder.encode(JSON.stringify(event) + "\n")).catch(() => undefined);

  const job = (async () => {
    try {
      const row = await env.DB.prepare("SELECT * FROM matches WHERE key = ? AND expires > ?").bind(key, now).first<Row>();
      if (row) {
        ctx.waitUntil(env.DB.prepare("UPDATE matches SET hits = hits + 1 WHERE key = ?").bind(key).run());
        const verdict = fromRow(row);
        if (video) ctx.waitUntil(link(env, video, source, verdict, "agent"));
        await send(await result(tmdb, verdict, JSON.parse(row.candidates || "[]"), language, true));
        return;
      }
      let run = running.get(key);
      if (run) {
        await send({ type: "progress", step: "waiting" });
      } else {
        if (!(await env.MATCH_LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "" })).success) {
          await send({ type: "error", code: "busy", message: "Too many lookups. Try again in a minute." });
          return;
        }
        const today = new Date().toISOString().slice(0, 10);
        const usage = await env.DB.prepare("INSERT INTO usage (day, runs) VALUES (?, 1) ON CONFLICT (day) DO UPDATE SET runs = runs + 1 RETURNING runs")
          .bind(today)
          .first<{ runs: number }>();
        if ((usage?.runs ?? 0) > Number(env.DAILY_RUNS || 2000)) {
          await send({ type: "error", code: "busy", message: "The lookup service is at its daily limit. Try again tomorrow." });
          return;
        }
        run = agent(source, key, tmdb, env, (event) => void send({ type: "progress", ...event }));
        running.set(key, run);
        run.finally(() => running.delete(key)).catch(() => undefined);
      }
      const { verdict, candidates } = await run;
      if (video) ctx.waitUntil(link(env, video, source, verdict, "agent"));
      await send({ type: "progress", step: verdict.status === "matched" ? "loading" : "done" });
      await send(await result(tmdb, verdict, candidates, language, false));
    } catch (error) {
      // Failures are not answers: nothing is kept, and the app says the lookup failed rather than "not found".
      const code = error instanceof UpstreamError ? "upstream" : error instanceof ModelError ? "model" : "internal";
      console.error(code, (error as Error).message);
      await send({ type: "error", code, message: (error as Error).message.slice(0, 200) });
    } finally {
      await writer.close().catch(() => undefined);
    }
  })();
  ctx.waitUntil(job);
  return new Response(stream.readable, {
    headers: { "content-type": "application/x-ndjson; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" },
  });
}

async function agent(source: Source, key: string, tmdb: TMDB, env: Env, progress: (event: Record<string, unknown>) => void) {
  const started = Date.now();
  const outcome = await identify(source, tmdb, { key: env.GEMINI_API_KEY, model: env.GEMINI_MODEL, fetcher: relay(env) }, progress);
  const { verdict, seen } = outcome;
  // The candidates as cards (name, year, poster), so a cached answer needs no search to show them.
  const candidates = verdict.candidates.map((item) => seen.get(`${item.mediaType}:${item.id}`)).filter(Boolean);
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `INSERT OR REPLACE INTO matches (key, title, year, type, status, media_type, tmdb_id, season, numbering, episode_offset, confidence, unmatched,
       reason, candidates, model, turns, requests, tokens, millis, created, expires, hits)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)`,
  )
    .bind(
      key,
      source.title,
      source.year ?? null,
      source.type ?? null,
      verdict.status,
      verdict.mediaType,
      verdict.id,
      verdict.season,
      verdict.numbering,
      verdict.offset,
      verdict.confidence,
      verdict.unmatched,
      verdict.reason,
      JSON.stringify(candidates),
      env.GEMINI_MODEL,
      outcome.turns,
      tmdb.requests,
      outcome.tokens,
      Date.now() - started,
      now,
      now + keep(verdict),
    )
    .run();
  return { verdict, candidates };
}

// Links a source video to the work it was matched to. An agent's answer never replaces what a viewer picked.
async function link(env: Env, video: SourceVideo, source: Source, verdict: Pick<Verdict, "status" | "mediaType" | "id" | "season">, via: "agent" | "viewer") {
  if (verdict.status !== "matched" || !verdict.mediaType || verdict.id === null) return;
  await env.DB.prepare(
    `INSERT INTO links (source, item, source_name, title, year, media_type, tmdb_id, season, via, seen) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (source, item) DO UPDATE SET source_name = excluded.source_name, title = excluded.title, year = excluded.year,
       media_type = excluded.media_type, tmdb_id = excluded.tmdb_id, season = excluded.season, via = excluded.via, seen = excluded.seen
     WHERE links.via = 'agent' OR excluded.via = 'viewer'`,
  )
    .bind(video.source, video.item, video.sourceName, source.title, source.year ?? null, verdict.mediaType, verdict.id, verdict.season, via, Math.floor(Date.now() / 1000))
    .run()
    .catch((error) => console.error("link", (error as Error).message));
}

// The viewer picked the work for a source video in the app ("Not this title?"): others see that source for it too.
async function chosen(request: Request, env: Env): Promise<Response> {
  if (!(await env.DETAILS_LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "" })).success) return new Response(null, { status: 429 });
  let body: any;
  try {
    body = JSON.parse((await request.text()).slice(0, MAX_BODY));
  } catch {
    return new Response(null, { status: 400 });
  }
  const source = readSource(body?.request);
  const video = readSourceVideo(body?.request);
  const mediaType = body?.mediaType === "tv" || body?.mediaType === "movie" ? (body.mediaType as MediaType) : null;
  const id = Number(body?.id);
  if (!source || !video || !mediaType || !Number.isInteger(id) || id <= 0) return new Response(null, { status: 400 });
  const season = mediaType === "tv" && Number.isInteger(body?.season) && body.season >= 0 ? (body.season as number) : null;
  await link(env, video, source, { status: "matched", mediaType, id, season }, "viewer");
  return new Response(null, { status: 204 });
}

// TMDB's movies and series for a name, each with how many source videos are linked to it.
async function search(request: Request, env: Env): Promise<Response> {
  if (!(await env.DETAILS_LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "" })).success) return new Response(null, { status: 429 });
  const url = new URL(request.url);
  const query = text(url.searchParams.get("q"), 100);
  const language = url.searchParams.get("language") ?? "zh-CN";
  if (!query || !LANGUAGES.has(language)) return new Response(null, { status: 400 });
  try {
    const value = await new TMDB(env.TMDB_TOKEN).get("/search/multi", { query, language, page: 1, include_adult: "false" });
    const results = ((value?.results ?? []) as any[])
      .filter((item) => item.media_type === "tv" || item.media_type === "movie")
      .map((item) => ({ ...brief(item), votes: undefined, countries: undefined, originalLanguage: undefined, overview: text(item.overview, 300), backdrop: image(item.backdrop_path, "w780") }));
    const counts = new Map<string, number>();
    if (results.length) {
      const rows = await env.DB.prepare(
        `SELECT media_type, tmdb_id, COUNT(*) AS n FROM links WHERE tmdb_id IN (${results.map(() => "?").join(",")}) GROUP BY media_type, tmdb_id`,
      )
        .bind(...results.map((item) => item.id))
        .all<{ media_type: string; tmdb_id: number; n: number }>();
      for (const row of rows.results) counts.set(`${row.media_type}:${row.tmdb_id}`, row.n);
    }
    return Response.json(
      results.map((item) => ({ ...item, sources: counts.get(`${item.mediaType}:${item.id}`) ?? 0 })),
      { headers: { "cache-control": "no-store" } },
    );
  } catch (error) {
    return Response.json({ error: (error as Error).message.slice(0, 200) }, { status: 502 });
  }
}

// The source videos linked to a TMDB work, most recently seen first.
async function sources(request: Request, env: Env): Promise<Response> {
  if (!(await env.DETAILS_LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "" })).success) return new Response(null, { status: 429 });
  const url = new URL(request.url);
  const type = url.searchParams.get("type");
  const id = Number(url.searchParams.get("id"));
  if ((type !== "tv" && type !== "movie") || !Number.isInteger(id) || id <= 0) return new Response(null, { status: 400 });
  const rows = await env.DB.prepare(
    "SELECT source, source_name, item, title, year, season, seen FROM links WHERE tmdb_id = ? AND media_type = ? ORDER BY seen DESC LIMIT 200",
  )
    .bind(id, type)
    .all<{ source: string; source_name: string; item: string; title: string; year: string | null; season: number | null; seen: number }>();
  return Response.json(
    rows.results.map((row) => ({ source: row.source, sourceName: row.source_name, item: row.item, title: row.title, year: row.year, season: row.season, seen: row.seen })),
    { headers: { "cache-control": "no-store" } },
  );
}

// One work's details, for a candidate the viewer picked.
async function lookup(request: Request, env: Env): Promise<Response> {
  if (!(await env.DETAILS_LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "" })).success) return new Response(null, { status: 429 });
  const url = new URL(request.url);
  const type = url.searchParams.get("type");
  const id = Number(url.searchParams.get("id"));
  const season = url.searchParams.get("season");
  const language = url.searchParams.get("language") ?? "zh-CN";
  if ((type !== "tv" && type !== "movie") || !Number.isInteger(id) || id <= 0 || !LANGUAGES.has(language)) return new Response(null, { status: 400 });
  try {
    const value = await details(new TMDB(env.TMDB_TOKEN), type, id, language, season !== null && /^\d{1,3}$/.test(season) ? Number(season) : null);
    if (!value) return new Response(null, { status: 404 });
    return Response.json(value, { headers: { "cache-control": "public, max-age=3600" } });
  } catch (error) {
    return Response.json({ error: (error as Error).message.slice(0, 200) }, { status: 502 });
  }
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/v1/match" && request.method === "POST") return match(request, env, ctx);
    if (pathname === "/v1/details" && request.method === "GET") return lookup(request, env);
    if (pathname === "/v1/search" && request.method === "GET") return search(request, env);
    if (pathname === "/v1/sources" && request.method === "GET") return sources(request, env);
    if (pathname === "/v1/link" && request.method === "POST") return chosen(request, env);
    return new Response(null, { status: 404 });
  },

  // Daily: drop answers that have run out, and old usage counts.
  async scheduled(_event: ScheduledController, env: Env) {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.batch([
      env.DB.prepare("DELETE FROM matches WHERE expires < ?").bind(now),
      env.DB.prepare("DELETE FROM usage WHERE day < ?").bind(new Date((now - 60 * DAY) * 1000).toISOString().slice(0, 10)),
    ]);
  },
} satisfies ExportedHandler<Env>;

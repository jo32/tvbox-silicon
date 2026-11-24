// Apple Music catalog data for the app's music pages (Sources/TVCore/AppleMusicCatalog.swift). See README.md.
// It holds the MusicKit key and answers three questions, each kept at the edge for a day:
//   GET /v1/identify?title=&artist=&duration=&storefront=   the catalog song that is this recording, or null
//   GET /v1/artist?name=&storefront=                        the artist's picture, notes, top songs and albums, or null
//   GET /v1/album?title=&artist=&storefront=                the album's notes, label, genres and tracks, or null
import { AppleMusic, UpstreamError } from "./apple.ts";
import { album, artist, identify, STOREFRONTS } from "./catalog.ts";
import { currentToken } from "./token.ts";

interface Env {
  LIMITER: RateLimit;
  // Secrets (wrangler secret put): the AuthKey_XXXX.p8 text, its Key ID, and the team's ID.
  MUSICKIT_KEY: string;
  MUSICKIT_KEY_ID: string;
  APPLE_TEAM_ID: string;
}

const DAY = 86400;
const MAX_TEXT = 200;

export interface Input {
  kind: "identify" | "artist" | "album";
  storefront: string;
  title: string;
  artists: string[];
  duration: number | null;
  name: string;
}

/// The request's question, or null when it is not one this Worker answers.
export function readInput(url: URL): Input | null {
  const kind = url.pathname.replace(/^\/v1\//, "");
  if (kind !== "identify" && kind !== "artist" && kind !== "album") return null;
  const params = url.searchParams;
  const storefront = params.get("storefront") ?? "cn";
  if (!STOREFRONTS.has(storefront)) return null;
  const field = (key: string) => (params.get(key) ?? "").trim();
  const title = field("title"), name = field("name");
  const artists = params.getAll("artist").map((a) => a.trim()).filter(Boolean).slice(0, 4);
  if ([title, name, ...artists].some((value) => value.length > MAX_TEXT)) return null;
  const seconds = params.get("duration");
  const duration = seconds === null || seconds === "" ? null : Number(seconds);
  if (duration !== null && !(Number.isFinite(duration) && duration > 0 && duration < 6 * 3600)) return null;
  if (kind === "identify" && !title) return null;
  if (kind === "artist" && !name) return null;
  if (kind === "album" && !title) return null;
  return { kind, storefront, title, artists, duration, name };
}

export async function answer(apple: AppleMusic, input: Input): Promise<unknown> {
  switch (input.kind) {
    case "identify": return { song: await identify(apple, input.storefront, { title: input.title, artists: input.artists, duration: input.duration }) };
    case "artist": return { artist: await artist(apple, input.storefront, input.name) };
    case "album": return { album: await album(apple, input.storefront, input.title, input.artists[0] ?? "") };
  }
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") return new Response("Yingxia Apple Music\n", { headers: { "content-type": "text/plain; charset=utf-8" } });
    if (request.method !== "GET") return new Response(null, { status: 405 });
    const input = readInput(url);
    if (!input) return new Response(null, { status: url.pathname.startsWith("/v1/") ? 400 : 404 });
    // The same question from anyone has the same answer: kept at the edge, before any rate limit or token.
    const cache = caches.default;
    const key = new Request(url.toString());
    const kept = await cache.match(key);
    if (kept) return kept;
    if (!(await env.LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "" })).success) return new Response(null, { status: 429 });
    if (!env.MUSICKIT_KEY || !env.MUSICKIT_KEY_ID || !env.APPLE_TEAM_ID) return Response.json({ error: "not configured" }, { status: 503 });
    const apple = new AppleMusic(() => currentToken(env.MUSICKIT_KEY, env.MUSICKIT_KEY_ID, env.APPLE_TEAM_ID));
    try {
      const response = Response.json(await answer(apple, input), { headers: { "cache-control": `public, max-age=${DAY}` } });
      ctx.waitUntil(cache.put(key, response.clone()));
      return response;
    } catch (error) {
      const status = error instanceof UpstreamError && error.status === 401 ? 503 : 502;
      return Response.json({ error: (error as Error).message.slice(0, 200) }, { status });
    }
  },
};

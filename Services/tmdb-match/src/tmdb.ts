// TMDB's v3 API, with every answer kept in the data center's cache for a day: many people open the same titles,
// and search pages, details and seasons barely change within a day.

export class UpstreamError extends Error {
  status: number;
  constructor(message: string, status = 0) {
    super(message);
    this.status = status;
  }
}

export const IMAGE = "https://image.tmdb.org/t/p/";
const API = "https://api.themoviedb.org/3";
const CACHE_SECONDS = 24 * 3600;

export type MediaType = "tv" | "movie";

export interface Fetcher {
  (input: string, init?: RequestInit): Promise<Response>;
}

export class TMDB {
  // One request per path at a time: the agent and the details often ask for the same title at once.
  private pending = new Map<string, Promise<any>>();
  requests = 0;

  private token: string;
  private fetcher: Fetcher;
  private cache: Cache | null;
  private api: string;

  constructor(token: string, fetcher?: Fetcher, cache?: Cache | null, api = API) {
    this.token = token;
    this.fetcher = fetcher ?? ((input, init) => fetch(input, init));
    this.cache = cache !== undefined ? cache : typeof caches === "undefined" ? null : (caches as any).default;
    this.api = api;
  }

  get(path: string, params: Record<string, string | number | undefined> = {}, signal?: AbortSignal): Promise<any> {
    const query = Object.entries(params)
      .filter(([, value]) => value !== undefined && value !== "")
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, value]) => `${key}=${encodeURIComponent(String(value))}`)
      .join("&");
    const url = `${this.api}${path}${query ? "?" + query : ""}`;
    let request = this.pending.get(url);
    if (!request) {
      request = this.load(url, signal).finally(() => this.pending.delete(url));
      this.pending.set(url, request);
    }
    return request;
  }

  private async load(url: string, signal?: AbortSignal): Promise<any> {
    const key = new Request(url);
    const cached = await this.cache?.match(key).catch(() => undefined);
    if (cached) return cached.json();
    // A 429 waits for TMDB's Retry-After (at most a few seconds) and tries again; anything else is reported as it is.
    for (let attempt = 0; ; attempt++) {
      this.requests++;
      let response: Response;
      try {
        response = await this.fetcher(url, { headers: { authorization: `Bearer ${this.token}`, accept: "application/json" }, signal });
      } catch (error) {
        throw new UpstreamError(`TMDB unreachable: ${(error as Error).message}`);
      }
      if (response.status === 429 && attempt < 2) {
        const wait = Math.min(Number(response.headers.get("retry-after")) || 1, 4);
        await new Promise((resolve) => setTimeout(resolve, wait * 1000 * (attempt + 1)));
        continue;
      }
      if (response.status === 404) return null;
      if (!response.ok) throw new UpstreamError(`TMDB ${response.status}`, response.status);
      const body = await response.text();
      await this.cache
        ?.put(key, new Response(body, { headers: { "content-type": "application/json", "cache-control": `max-age=${CACHE_SECONDS}` } }))
        .catch(() => undefined);
      return JSON.parse(body);
    }
  }
}

export const image = (path: unknown, size: string) => (typeof path === "string" && path ? IMAGE + size + path : null);
export const yearOf = (date: unknown) => (typeof date === "string" && /^\d{4}/.test(date) ? Number(date.slice(0, 4)) : null);

// Apple Music API catalog requests, each answer kept in the data center's cache for a day: many people play the same
// songs, and catalog entries barely change within a day.

export class UpstreamError extends Error {
  status: number;
  constructor(message: string, status = 0) {
    super(message);
    this.status = status;
  }
}

const API = "https://api.music.apple.com/v1";
const CACHE_SECONDS = 24 * 3600;

export interface Fetcher {
  (input: string, init?: RequestInit): Promise<Response>;
}

export class AppleMusic {
  private pending = new Map<string, Promise<any>>();
  requests = 0;
  private token: () => Promise<string>;
  private fetcher: Fetcher;
  private cache: Cache | null;

  constructor(token: () => Promise<string>, fetcher?: Fetcher, cache?: Cache | null) {
    this.token = token;
    this.fetcher = fetcher ?? ((input, init) => fetch(input, init));
    this.cache = cache !== undefined ? cache : typeof caches === "undefined" ? null : (caches as any).default;
  }

  get(path: string, params: Record<string, string | number | undefined> = {}): Promise<any> {
    const query = Object.entries(params)
      .filter(([, value]) => value !== undefined && value !== "")
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, value]) => `${key}=${encodeURIComponent(String(value))}`)
      .join("&");
    const url = `${API}${path}${query ? "?" + query : ""}`;
    let request = this.pending.get(url);
    if (!request) {
      request = this.load(url).finally(() => this.pending.delete(url));
      this.pending.set(url, request);
    }
    return request;
  }

  private async load(url: string): Promise<any> {
    const key = new Request(url);
    const cached = await this.cache?.match(key).catch(() => undefined);
    if (cached) return cached.json();
    for (let attempt = 0; ; attempt++) {
      this.requests++;
      let response: Response;
      try {
        response = await this.fetcher(url, { headers: { authorization: `Bearer ${await this.token()}`, accept: "application/json" } });
      } catch (error) {
        throw new UpstreamError(`Apple Music unreachable: ${(error as Error).message}`);
      }
      if (response.status === 429 && attempt < 2) {
        await new Promise((resolve) => setTimeout(resolve, 1000 * (attempt + 1)));
        continue;
      }
      if (response.status === 404) return null;
      if (!response.ok) throw new UpstreamError(`Apple Music ${response.status}`, response.status);
      const body = await response.text();
      await this.cache
        ?.put(key, new Response(body, { headers: { "content-type": "application/json", "cache-control": `max-age=${CACHE_SECONDS}` } }))
        .catch(() => undefined);
      return JSON.parse(body);
    }
  }
}

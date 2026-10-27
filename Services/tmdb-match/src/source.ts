// What the app sends about a video, read defensively, and the key its answer is kept under.
import type { Source } from "./agent.ts";

// Part of every cache key: bump it when the prompt or the rules change enough that old answers should go.
export const VERSION = "1";
export const text = (value: unknown, max: number) => (typeof value === "string" ? value.trim().slice(0, max) : "");

// Width, case and spacing don't make another title; everything else (numbers, 第四季, 特别篇) does.
export function comparable(title: string) {
  return title.normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();
}

export function cacheKey(source: Source) {
  return [VERSION, comparable(source.title), source.year ?? "", source.type ?? ""].join("|");
}

export function readSource(body: any): Source | null {
  const title = text(body?.title, 100);
  if (!title) return null;
  const year = text(body?.year, 4);
  return {
    title,
    year: /^\d{4}$/.test(year) ? year : null,
    type: body?.type === "tv" || body?.type === "movie" ? body.type : null,
    remarks: text(body?.remarks, 80),
    synopsis: text(body?.synopsis, 1000),
    area: text(body?.area, 40),
    category: text(body?.category, 80),
    episodes: (Array.isArray(body?.episodes) ? body.episodes : []).slice(0, 2000).map((name: unknown) => text(name, 60)),
  };
}

// Which source video a request is about, when the app says: the source's key and name, and the video's ID there.
export interface SourceVideo {
  source: string;
  sourceName: string;
  item: string;
}

export function readSourceVideo(body: any): SourceVideo | null {
  const source = text(body?.source?.key, 80);
  const item = text(body?.item, 200);
  if (!source || !item) return null;
  return { source, sourceName: text(body?.source?.name, 60) || source, item };
}

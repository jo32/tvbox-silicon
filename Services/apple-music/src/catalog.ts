// What the app asks Apple Music for, trimmed to what it shows: a song identified by title, artist and length (for
// lyrics of a source's song and ISRCs), an artist's picture, notes and top songs, an album's notes and facts.
// Names compare as Sources/TVCore/MusicMatching.swift does: letters and digits only, versions in brackets set aside.
import type { AppleMusic } from "./apple.ts";

export const STOREFRONTS = new Set(["cn", "tw", "hk", "mo", "sg", "jp", "us", "gb"]);

export interface Song {
  id: string;
  title: string;
  artist: string;
  artists: string[];
  album: string | null;
  duration: number | null;
  isrc: string | null;
  released: string | null;
  genres: string[];
  artwork: string | null;
  url: string | null;
}

export interface AlbumBrief {
  id: string;
  title: string;
  artist: string;
  released: string | null;
  artwork: string | null;
  trackCount: number | null;
  url: string | null;
}

export interface Album extends AlbumBrief {
  notes: string | null;
  label: string | null;
  genres: string[];
  copyright: string | null;
  tracks: Song[];
}

export interface Artist {
  id: string;
  name: string;
  genres: string[];
  artwork: string | null;
  notes: string | null;
  url: string | null;
  topSongs: Song[];
  albums: AlbumBrief[];
}

export const normalize = (text: string) => text.normalize("NFKC").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");

/// A title without its bracketed parts or a " - …" suffix: "晴天 (Live)" and "晴天 - 现场版" are both "晴天".
export const baseTitle = (title: string) => {
  const bare = normalize(title.replace(/[(（\[【「][^)）\]】」]*[)）\]】」]/g, "").replace(/\s[-–—]\s.+$/, ""));
  return bare || normalize(title);
};

/// Apple joins several artists in one name: "A & B", "A, B & C", "A feat. B".
export const splitArtists = (name: string) =>
  name.split(/\s*(?:&|,|，|、|\/|\s+x\s+|\s+feat\.?\s+|\s+ft\.?\s+|\s+and\s+)\s*/i).map((part) => part.trim()).filter(Boolean);

export function sameArtist(wanted: string[], found: string[]): boolean {
  const names = found.map(normalize).filter(Boolean);
  return wanted.map(normalize).filter(Boolean).some((name) => names.some((other) => other === name || (Math.min(other.length, name.length) >= 2 && (other.includes(name) || name.includes(other)))));
}

/// Lengths of one recording differ by a few seconds between catalogs (silence, fades).
export const sameLength = (a: number, b: number) => Math.abs(a - b) <= Math.max(4, 0.03 * Math.max(a, b));

const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : null);

/// Editorial notes come as HTML; the app shows plain text.
export const plain = (html: unknown) => {
  const value = text(html);
  if (!value) return null;
  return value
    .replace(/<br\s*\/?>/gi, "\n").replace(/<\/p>/gi, "\n").replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n\n").trim() || null;
};

const genres = (value: unknown) => (Array.isArray(value) ? value.filter((g): g is string => typeof g === "string" && g !== "Music" && g !== "音乐" && g !== "音樂" && g !== "ミュージック") : []);

export function song(entry: any): Song | null {
  const a = entry?.attributes;
  if (!entry?.id || !text(a?.name) || !text(a?.artistName)) return null;
  return {
    id: String(entry.id), title: a.name.trim(), artist: a.artistName.trim(), artists: splitArtists(a.artistName),
    album: text(a.albumName), duration: typeof a.durationInMillis === "number" ? Math.round(a.durationInMillis / 100) / 10 : null,
    isrc: text(a.isrc), released: text(a.releaseDate), genres: genres(a.genreNames), artwork: text(a.artwork?.url), url: text(a.url),
  };
}

export function albumBrief(entry: any): AlbumBrief | null {
  const a = entry?.attributes;
  if (!entry?.id || !text(a?.name)) return null;
  return {
    id: String(entry.id), title: a.name.trim(), artist: text(a.artistName) ?? "", released: text(a.releaseDate),
    artwork: text(a.artwork?.url), trackCount: typeof a.trackCount === "number" ? a.trackCount : null, url: text(a.url),
  };
}

const list = <T>(entries: unknown, map: (entry: any) => T | null): T[] => (Array.isArray(entries) ? entries.map(map).filter((x): x is T => x !== null) : []);

export interface SongQuery { title: string; artists: string[]; duration: number | null; }

/// The catalog's song that is this recording: the same title, one of its artists, and (when known) its length.
export function pickSong(query: SongQuery, songs: Song[]): Song | null {
  const title = baseTitle(query.title);
  return songs.find((s) => baseTitle(s.title) === title
    && (query.artists.length === 0 || sameArtist(query.artists, s.artists.concat(s.artist)))
    && (query.duration === null || s.duration === null || sameLength(query.duration, s.duration))) ?? null;
}

export async function identify(apple: AppleMusic, storefront: string, query: SongQuery): Promise<Song | null> {
  const term = [query.title, query.artists[0]].filter(Boolean).join(" ");
  const found = await apple.get(`/catalog/${storefront}/search`, { term, types: "songs", limit: 15 });
  return pickSong(query, list(found?.results?.songs?.data, song));
}

export async function artist(apple: AppleMusic, storefront: string, name: string): Promise<Artist | null> {
  const found = await apple.get(`/catalog/${storefront}/search`, { term: name, types: "artists", limit: 5 });
  const wanted = normalize(name);
  const match = (found?.results?.artists?.data ?? []).find((entry: any) => normalize(entry?.attributes?.name ?? "") === wanted);
  if (!match?.id) return null;
  const detail = await apple.get(`/catalog/${storefront}/artists/${encodeURIComponent(match.id)}`, { views: "top-songs,full-albums", extend: "artistBio" });
  const entry = detail?.data?.[0] ?? match, a = entry.attributes ?? {};
  return {
    id: String(entry.id), name: text(a.name) ?? name, genres: genres(a.genreNames), artwork: text(a.artwork?.url),
    notes: plain(a.editorialNotes?.standard) ?? plain(a.artistBio) ?? plain(a.editorialNotes?.short), url: text(a.url),
    topSongs: list(entry.views?.["top-songs"]?.data, song).slice(0, 10), albums: list(entry.views?.["full-albums"]?.data, albumBrief).slice(0, 20),
  };
}

export async function album(apple: AppleMusic, storefront: string, title: string, artistName: string): Promise<Album | null> {
  const term = [title, artistName].filter(Boolean).join(" ");
  const found = await apple.get(`/catalog/${storefront}/search`, { term, types: "albums", limit: 10 });
  const wanted = baseTitle(title), artists = artistName ? splitArtists(artistName) : [];
  const match = (found?.results?.albums?.data ?? []).find((entry: any) => baseTitle(entry?.attributes?.name ?? "") === wanted
    && (artists.length === 0 || sameArtist(artists, splitArtists(entry?.attributes?.artistName ?? ""))));
  if (!match?.id) return null;
  const detail = await apple.get(`/catalog/${storefront}/albums/${encodeURIComponent(match.id)}`);
  const entry = detail?.data?.[0] ?? match, brief = albumBrief(entry);
  if (!brief) return null;
  const a = entry.attributes ?? {};
  return {
    ...brief, notes: plain(a.editorialNotes?.standard) ?? plain(a.editorialNotes?.short), label: text(a.recordLabel), genres: genres(a.genreNames),
    copyright: text(a.copyright), tracks: list(entry.relationships?.tracks?.data, song),
  };
}

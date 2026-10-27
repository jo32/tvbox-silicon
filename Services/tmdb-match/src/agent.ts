// The matcher: Gemini searches TMDB with tools until it can say which movie or series a source's video is.
// It sees the source's own title and details; TMDB answers are the only facts it may cite.
import { brief, facts } from "./details.ts";
import { type Fetcher, type MediaType, type TMDB, UpstreamError } from "./tmdb.ts";

export interface Source {
  title: string;
  year?: string | null;
  type?: MediaType | null;
  remarks?: string;
  synopsis?: string;
  area?: string;
  /** The source's category and genre tags. */
  category?: string;
  episodes?: string[];
}

export interface Verdict {
  status: "matched" | "ambiguous" | "notFound";
  mediaType: MediaType | null;
  id: number | null;
  season: number | null;
  numbering: "season" | "absolute";
  /** TMDB episodes before the source's first one in that season: TMDB sometimes lists two broadcast seasons as one. */
  offset: number;
  confidence: number;
  unmatched: string;
  reason: string;
  candidates: { mediaType: MediaType; id: number }[];
}

export type Progress = (event: Record<string, unknown>) => void;

export interface Limits {
  searches: number;
  details: number;
  seasons: number;
  turns: number;
}

export const LIMITS: Limits = { searches: 8, details: 6, seasons: 3, turns: 10 };

export class ModelError extends Error {}

const PROMPT = `You identify which TMDB movie or TV series a video from a Chinese video source is, using the tools.

The source title is what the site calls it. It often carries extra words that are not part of the work's name: a season (第二季, 第2季, S2, 第二部), a part, an edition or cut (特别篇, 剧场版, 国语版, 粤语版, 未删减, 导演剪辑版, 4K, 蓝光, 先行版, TC), a year, or the site's own tags. Search without them, but keep their meaning: 第N季 points at a season of a series, 剧场版 usually at a movie.

First, before any search, decide whether the video can be on TMDB at all. These are not, so submit notFound at once, without searching, with a reason that starts "AI-generated:" or "Short drama:":
- AI-generated videos: labelled AI, AIGC, AI短剧, AI漫剧 or 漫剧 in the category, title or remarks; or a recent "film" whose synopsis reads like web-novel power fantasy (觉醒, 系统, 重生, 逆袭, 战神, 神兽, mutant beasts, swallowing a monster's essence) with a cast and director you have never heard of.
- Short dramas (短剧, micro-dramas with many 1–3 minute episodes; categories like 爽文短剧, 反转爽剧).
When it could well be a real film or series, search: a known cast, a known studio, a remake or adaptation of something known, or an older year.

How to work:
- Search with the whole title first, then with it cleaned. Use type tv or movie when the source makes it clear (episodes, 更新至, 全N集 mean a series; a single "正片"/"HD" episode usually a movie), else multi. Try other names (traditional characters, an English or original name from the synopsis) only when needed.
- Check the best candidates with details before answering, unless one result has exactly the title's name and its year and type agree with the source.
- Chinese, Korean, Japanese and Western works are often listed on TMDB under their original name, with Chinese only among the other names in details. Compare the source title with every name a candidate goes by.
- Works with the same name: use the year, type, country, episode count and synopsis to choose. Never take popularity or the first search position as proof.
- Sequels and remakes are different works: "X 2", "X2", "X：副标题", "新X" are not "X". A shared prefix alone proves nothing.
- Seasons: for a series give the TMDB season number the source's video is. 第N季 is usually season N, but check the seasons in details (names, years, episode counts); TMDB sometimes lists a sequel season as its own series, then match that series. Without a season marker, choose the season whose year matches the source, else 1. Specials are season 0.
- numbering: "season" when the source numbers its episodes from 1 within the season; "absolute" when its numbers continue across seasons (long anime: 第150集 of a series whose seasons have 24 episodes).
- TMDB sometimes lists two broadcast seasons as one season (第二季 is episodes 26–50 of TMDB's season 1). When the source's season isn't a TMDB season of its own, give that season and firstEpisode: the TMDB episode number of the source's first episode (check with season when unsure). Otherwise leave firstEpisode out.
- Many variety specials are not on TMDB either: answer notFound rather than a near miss.
- unmatched: the words of the source title that are not part of the matched TMDB name, verbatim (e.g. "第四季"), or "".
- matched only with confidence 0.8 or more and no contradicting fact. When two or more works remain plausible, answer ambiguous with them ranked. When nothing fits, notFound.
Only submit ids you have seen in tool results. Be quick: few searches, few details.`;

const declarations = [
  {
    name: "search",
    description: "Search TMDB by name. Returns up to 20 results per page.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", description: "A name, without season or edition words." },
        type: { type: "string", enum: ["tv", "movie", "multi"] },
        year: { type: "integer", description: "Optional. Narrows to this premiere year; leave it out at first: a season's year is not the series' year." },
        page: { type: "integer", description: "Optional, default 1. Only when the first page had many weak results." },
      },
      required: ["query", "type"],
    },
  },
  {
    name: "details",
    description: "A candidate's names in all languages, year, countries, genres, overview, and for a series its seasons with episode counts.",
    parameters: {
      type: "object",
      properties: { mediaType: { type: "string", enum: ["tv", "movie"] }, id: { type: "integer" } },
      required: ["mediaType", "id"],
    },
  },
  {
    name: "season",
    description: "The episode names and air dates of one season of a series, to check how the source's episodes line up.",
    parameters: {
      type: "object",
      properties: { id: { type: "integer" }, season: { type: "integer" } },
      required: ["id", "season"],
    },
  },
  {
    name: "submit",
    description: "The final answer.",
    parameters: {
      type: "object",
      properties: {
        status: { type: "string", enum: ["matched", "ambiguous", "notFound"] },
        mediaType: { type: "string", enum: ["tv", "movie"], description: "For matched." },
        id: { type: "integer", description: "For matched: the TMDB id." },
        season: { type: "integer", description: "For a matched series: the season number." },
        numbering: { type: "string", enum: ["season", "absolute"] },
        firstEpisode: { type: "integer", description: "For a series whose TMDB season holds more than the source's season: the TMDB episode number of the source's first episode." },
        confidence: { type: "number", description: "0 to 1." },
        unmatched: { type: "string" },
        reason: { type: "string", description: "One short English sentence." },
        candidates: {
          type: "array",
          description: "For ambiguous (and as alternatives for matched): the plausible works, best first, at most 5.",
          items: { type: "object", properties: { mediaType: { type: "string", enum: ["tv", "movie"] }, id: { type: "integer" } }, required: ["mediaType", "id"] },
        },
      },
      required: ["status", "confidence", "reason"],
    },
  },
];

export interface Gemini {
  key: string;
  model: string;
  fetcher?: Fetcher;
  api?: string;
}

async function generate(gemini: Gemini, body: unknown, signal?: AbortSignal) {
  const url = `${gemini.api ?? "https://generativelanguage.googleapis.com/v1beta"}/models/${gemini.model}:generateContent`;
  for (let attempt = 0; ; attempt++) {
    let response: Response;
    try {
      response = await (gemini.fetcher ?? fetch)(url, {
        method: "POST",
        headers: { "x-goog-api-key": gemini.key, "content-type": "application/json" },
        body: JSON.stringify(body),
        signal,
      });
    } catch (error) {
      if (attempt < 1 && !signal?.aborted) continue;
      throw new ModelError(`Gemini unreachable: ${(error as Error).message}`);
    }
    // A 429 for the per-minute limit says to retry in seconds: wait that long, a few times. One for the daily limit
    // says hours ("85153s"): waiting can't help, so it fails at once.
    if ((response.status === 429 || response.status >= 500) && attempt < 3) {
      const text = await response.text();
      const asked = Number(/"retryDelay":\s*"(\d+(?:\.\d+)?)s"/.exec(text)?.[1]);
      if (Number.isFinite(asked) && asked > 30) throw new ModelError(`Gemini ${response.status}: ${text.slice(0, 2000)}`);
      await new Promise((resolve) => setTimeout(resolve, Number.isFinite(asked) && asked > 0 ? asked * 1000 : 2000 * (attempt + 1)));
      continue;
    }
    if (!response.ok) throw new ModelError(`Gemini ${response.status}: ${(await response.text()).slice(0, 2000)}`);
    const value: any = await response.json();
    const content = value?.candidates?.[0]?.content;
    if (!content?.parts?.length) throw new ModelError(`Gemini gave no answer (${value?.candidates?.[0]?.finishReason ?? "?"})`);
    return { content, tokens: value?.usageMetadata?.totalTokenCount ?? 0 };
  }
}

// The source as the model reads it: its long lists cut down to what tells the numbering.
export function describe(source: Source) {
  const episodes = source.episodes ?? [];
  const sample = episodes.length > 12 ? [...episodes.slice(0, 8), "…", ...episodes.slice(-3)] : episodes;
  return JSON.stringify(
    {
      title: source.title,
      year: source.year || undefined,
      type: source.type || undefined,
      remarks: source.remarks || undefined,
      area: source.area || undefined,
      category: source.category || undefined,
      synopsis: source.synopsis ? source.synopsis.slice(0, 400) : undefined,
      episodeCount: episodes.length || undefined,
      episodes: sample.length ? sample : undefined,
    },
    null,
    1,
  );
}

const key = (type: string, id: number) => `${type}:${id}`;

export async function identify(source: Source, tmdb: TMDB, gemini: Gemini, progress: Progress, limits = LIMITS, signal?: AbortSignal) {
  // Every work the tools showed, by "type:id": answers may only name these.
  const seen = new Map<string, ReturnType<typeof brief>>();
  const used = { searches: 0, details: 0, seasons: 0 };
  let tokens = 0;
  const contents: any[] = [];

  async function run(name: string, args: any): Promise<unknown> {
    switch (name) {
      case "search": {
        if (used.searches >= limits.searches) return { error: "No searches left. Submit your answer now." };
        used.searches++;
        const type = ["tv", "movie"].includes(args.type) ? args.type : "multi";
        const query = String(args.query ?? "").slice(0, 100);
        progress({ step: "search", query });
        const page = Math.min(Math.max(Number(args.page) || 1, 1), 5);
        const year = Number(args.year) || undefined;
        const value = await tmdb.get(`/search/${type}`, {
          query,
          language: "zh-CN",
          page,
          include_adult: "false",
          ...(year ? (type === "movie" ? { year } : type === "tv" ? { first_air_date_year: year } : {}) : {}),
        });
        const results = ((value?.results ?? []) as any[])
          .filter((item) => type !== "multi" || item.media_type === "tv" || item.media_type === "movie")
          .map((item) => brief(item, type === "multi" ? undefined : type));
        for (const item of results) seen.set(key(item.mediaType, item.id), item);
        return {
          page,
          pages: value?.total_pages ?? 0,
          total: value?.total_results ?? 0,
          results: results.slice(0, 12).map(({ poster, ...rest }) => rest),
        };
      }
      case "details": {
        if (used.details >= limits.details) return { error: "No details left. Submit your answer now." };
        const type: MediaType = args.mediaType === "movie" ? "movie" : "tv";
        const id = Number(args.id);
        used.details++;
        const known = seen.get(key(type, id));
        progress({ step: "details", name: known?.name ?? null, year: known?.year ?? null });
        const value: any = await facts(tmdb, type, id);
        if (!value.error && !known) seen.set(key(type, id), { mediaType: type, id, name: value.name, originalName: value.originalName, year: value.year } as any);
        return value;
      }
      case "season": {
        if (used.seasons >= limits.seasons) return { error: "No season lookups left. Submit your answer now." };
        used.seasons++;
        progress({ step: "season", season: Number(args.season) });
        const value = await tmdb.get(`/tv/${Number(args.id)}/season/${Number(args.season)}`, { language: "zh-CN" });
        if (!value) return { error: "No such season." };
        return {
          name: value.name,
          episodes: ((value.episodes ?? []) as any[]).slice(0, 80).map((episode) => ({ number: episode.episode_number, name: episode.name, airDate: episode.air_date })),
        };
      }
      default:
        return { error: `Unknown tool ${name}.` };
    }
  }

  // No search before the model's first turn: an AI-generated video or a short drama shouldn't reach TMDB at all.
  contents.push({ role: "user", parts: [{ text: `Which TMDB work is this source video?\n${describe(source)}` }] });

  for (let turn = 0; turn < limits.turns; turn++) {
    const last = turn === limits.turns - 1;
    progress({ step: "thinking", turn });
    const { content, tokens: spent } = await generate(
      gemini,
      {
        systemInstruction: { parts: [{ text: PROMPT }] },
        contents,
        tools: [{ functionDeclarations: declarations }],
        toolConfig: { functionCallingConfig: { mode: "ANY", ...(last ? { allowedFunctionNames: ["submit"] } : {}) } },
        generationConfig: { thinkingConfig: { thinkingLevel: "low" } },
      },
      signal,
    );
    tokens += spent;
    // The model's turn goes back as it came, thought signatures included: Gemini needs them to carry on.
    contents.push(content);
    const calls = (content.parts as any[]).filter((part) => part.functionCall).map((part) => part.functionCall);
    const submit = calls.find((call) => call.name === "submit");
    if (submit) return { verdict: verdict(submit.args ?? {}, seen), seen, used, tokens, turns: turn + 1 };
    if (calls.length === 0) {
      contents.push({ role: "user", parts: [{ text: "Use a tool, or submit." }] });
      continue;
    }
    const responses = await Promise.all(
      calls.map(async (call) => {
        let response: unknown;
        try {
          response = await run(call.name, call.args ?? {});
        } catch (error) {
          // TMDB being down or refusing us is not the model's to work around: stop and say so.
          if (error instanceof UpstreamError) throw error;
          response = { error: (error as Error).message };
        }
        return { functionResponse: { name: call.name, ...(call.id ? { id: call.id } : {}), response: { result: response } } };
      }),
    );
    contents.push({ role: "user", parts: responses });
  }
  throw new ModelError("The model did not submit an answer.");
}

// The model's answer, held to the rules: only works it was shown, and no confident answer without confidence.
export function verdict(args: any, seen: Map<string, unknown>): Verdict {
  const valid = (type: unknown, id: unknown) => (type === "tv" || type === "movie") && Number.isInteger(id) && seen.has(key(type, id as number));
  const candidates: Verdict["candidates"] = [];
  for (const item of Array.isArray(args.candidates) ? args.candidates : []) {
    if (valid(item?.mediaType, item?.id) && !candidates.some((entry) => entry.mediaType === item.mediaType && entry.id === item.id)) {
      candidates.push({ mediaType: item.mediaType, id: item.id });
    }
  }
  const confidence = Math.min(Math.max(Number(args.confidence) || 0, 0), 1);
  const base = {
    numbering: args.numbering === "absolute" ? ("absolute" as const) : ("season" as const),
    offset: 0,
    confidence,
    unmatched: typeof args.unmatched === "string" ? args.unmatched.slice(0, 60) : "",
    reason: typeof args.reason === "string" ? args.reason.slice(0, 300) : "",
  };
  if (valid(args.mediaType, args.id) && (args.status === "matched" || args.status === "ambiguous")) {
    const chosen = { mediaType: args.mediaType as MediaType, id: args.id as number };
    const others = candidates.filter((entry) => !(entry.mediaType === chosen.mediaType && entry.id === chosen.id));
    const season = chosen.mediaType === "tv" && Number.isInteger(args.season) && args.season >= 0 ? (args.season as number) : null;
    if (args.status === "matched" && confidence >= 0.8) {
      const first = Number(args.firstEpisode);
      const offset = chosen.mediaType === "tv" && Number.isInteger(first) && first > 1 && first <= 2000 ? first - 1 : 0;
      return { status: "matched", ...chosen, season: chosen.mediaType === "tv" ? (season ?? 1) : null, ...base, offset, candidates: others.slice(0, 4) };
    }
    return { status: "ambiguous", mediaType: null, id: null, season, ...base, candidates: [chosen, ...others].slice(0, 5) };
  }
  if (candidates.length > 0 && args.status !== "notFound") {
    const season = Number.isInteger(args.season) && args.season >= 0 ? (args.season as number) : null;
    return { status: "ambiguous", mediaType: null, id: null, season, ...base, candidates: candidates.slice(0, 5) };
  }
  return { status: "notFound", mediaType: null, id: null, season: null, ...base, candidates: [] };
}

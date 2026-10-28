// Takes the app's error reports and stores them in D1. The app groups repeats and sends at most
// every six hours, so each install costs a request or so a day. No IP address is stored.
// Also turns feedback written in the app's Settings into a GitHub issue (/v1/feedback), and tells the app
// how its issues are doing and what the developer replied (/v1/feedback/replies).

interface Env {
  DB: D1Database;
  LIMITER: RateLimit;
  FEEDBACK_LIMITER: RateLimit;
  // owner/name of the public repository that gets the issues.
  FEEDBACK_REPO: string;
  // Secret: a fine-grained token with Issues read and write on FEEDBACK_REPO only.
  GITHUB_TOKEN?: string;
  // Local tests only (.dev.vars): a stand-in for https://api.github.com.
  GITHUB_API?: string;
}

const MAX_BODY = 64 * 1024;
const MAX_ITEMS = 50;
const KEEP_DAYS = 30;
const PLATFORMS = new Set(["macos", "ios", "tvos"]);

const text = (value: unknown, max: number) => (typeof value === "string" ? value.slice(0, max) : "");
const whole = (value: unknown, max: number) =>
  typeof value === "number" && Number.isFinite(value) ? Math.min(Math.max(Math.trunc(value), 0), max) : 0;

// One bug, many messages: ids, offsets, sizes and durations differ between occurrences. Status and
// error codes stay, so an HTTP 403 and a 500, or a timeout (-1001) and no network (-1009), stay apart.
// The same rules as `groupKey` in Sources/TVCore/ErrorReports.swift: keep them in step.
export function normalize(message: string) {
  return message
    .split("\n")[0]
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, "<id>")
    .replace(/\b[0-9a-f]{12,}\b/gi, "<id>")
    .replace(/\brequest=[0-9A-F]{8}\b/g, "request=#")
    .replace(/\b(offset|at|bytes|duration|length|chunk|aid|cid|room|id|page|elapsed|total|size|seconds)=-?[0-9.]+/g, "$1=#")
    .replace(/\b\d+(?:\.\d+)? ?(?:seconds|sec|ms|s)\b/g, "#s")
    .replace(/(?<![\w.-])\d{5,}\b/g, "#")
    .trim();
}

async function signature(category: string, message: string) {
  const data = new TextEncoder().encode(category + "\n" + normalize(message));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return [...digest.slice(0, 6)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

const address = (request: Request) => request.headers.get("cf-connecting-ip") ?? "";

// The JSON body, or the response that turns it away.
async function parse(request: Request): Promise<any> {
  if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY) return new Response(null, { status: 413 });
  const raw = await request.text();
  if (raw.length > MAX_BODY) return new Response(null, { status: 413 });
  try {
    return JSON.parse(raw);
  } catch {
    return new Response(null, { status: 400 });
  }
}

async function receive(request: Request, env: Env): Promise<Response> {
  if (!(await env.LIMITER.limit({ key: address(request) })).success) return new Response(null, { status: 429 });
  const body = await parse(request);
  if (body instanceof Response) return body;
  const install = text(body?.install, 36);
  const platform = text(body?.platform, 8);
  const items: any[] = Array.isArray(body?.items) ? body.items.slice(0, MAX_ITEMS) : [];
  if (!/^[0-9A-Fa-f-]{36}$/.test(install) || !PLATFORMS.has(platform) || items.length === 0) {
    return new Response(null, { status: 400 });
  }
  const now = Math.floor(Date.now() / 1000);
  const country = text((request as any).cf?.country, 2) || "XX";
  const insert = env.DB.prepare(
    `INSERT INTO reports (received, install, platform, os, model, lang, app, build, country, signature, category, message, count, first, last)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  const rows = [];
  for (const item of items) {
    const category = text(item?.category, 80);
    const message = text(item?.message, 1000);
    if (!category || !message) continue;
    rows.push(
      insert.bind(
        now, install, platform, text(body.os, 24), text(body.model, 32), text(body.lang, 16), text(body.app, 16), text(body.build, 16), country,
        await signature(category, message), category, message,
        Math.max(whole(item.count, 1_000_000), 1), whole(item.first, now), whole(item.last, now),
      ),
    );
  }
  if (rows.length) await env.DB.batch(rows);
  return new Response(null, { status: 204 });
}

const FEEDBACK_MAX = 5000;
// In any 24 hours: per install, and for everyone together, so a flood can't bury the repository.
const FEEDBACK_PER_INSTALL = 5;
const FEEDBACK_PER_DAY = 50;
// FEEDBACK_LIMITER's, in wrangler.jsonc.
const FEEDBACK_PER_MINUTE = 2;

// Which cap refused it, how many it allows and in how many seconds one more fits, so the app can say so
// (`Feedback.refusal` in Sources/TVCore/Feedback.swift).
const tooMany = (limit: "minute" | "install" | "everyone", max: number, retryAfter: number) =>
  Response.json({ limit, max, retryAfter }, { status: 429, headers: { "retry-after": String(retryAfter) } });
const LABELS: Record<string, string[]> = { bug: ["feedback", "bug"], idea: ["feedback", "enhancement"], other: ["feedback"] };
const SYSTEMS: Record<string, string> = { macos: "macOS", ios: "iOS", tvos: "tvOS" };

// The issue is public. Its first line is the title, @names stay text instead of notifying strangers
// (a zero-width space after the @), and the details come from the app, never from the install ID.
export function issue(body: any) {
  const message = text(body?.message, FEEDBACK_MAX).replace(/\r\n?/g, "\n").trim().replace(/@(?=[A-Za-z0-9_-])/g, "@​");
  const line = (message.split("\n").find((row) => row.trim()) ?? "").trim();
  const title = line.length > 80 ? line.slice(0, 79).trimEnd() + "…" : line;
  const cell = (value: unknown, max: number) => text(value, max).replace(/[|\r\n]/g, " ").trim() || "-";
  const details = [
    "| | |",
    "|---|---|",
    `| App | Yingxia ${cell(body?.app, 16)} (${cell(body?.build, 16)}) |`,
    `| System | ${SYSTEMS[body?.platform] ?? "-"} ${cell(body?.os, 24)} · ${cell(body?.model, 32)} |`,
    `| Language | ${cell(body?.lang, 16)} |`,
  ];
  return {
    title,
    body: `${message}\n\n---\n\n${details.join("\n")}\n\n<sub>Sent from Settings → Send Feedback in the app.</sub>`,
    labels: LABELS[body?.kind] ?? [],
  };
}

// The repository's REST API, as the token. `path` follows /repos/<owner>/<name>.
const github = (env: Env, path: string, init: RequestInit = {}) =>
  fetch(`${env.GITHUB_API ?? "https://api.github.com"}/repos/${env.FEEDBACK_REPO}${path}`, {
    ...init,
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      "content-type": "application/json",
      "user-agent": "yingxia-feedback",
      "x-github-api-version": "2022-11-28",
    },
  });

async function feedback(request: Request, env: Env): Promise<Response> {
  if (!env.GITHUB_TOKEN) return new Response(null, { status: 503 });
  if (!(await env.FEEDBACK_LIMITER.limit({ key: address(request) })).success) return tooMany("minute", FEEDBACK_PER_MINUTE, 60);
  const body = await parse(request);
  if (body instanceof Response) return body;
  const install = text(body?.install, 36);
  const platform = text(body?.platform, 8);
  const created = issue(body);
  if (!/^[0-9A-Fa-f-]{36}$/.test(install) || !PLATFORMS.has(platform) || !(body?.kind in LABELS) || !created.title) {
    return new Response(null, { status: 400 });
  }
  const now = Math.floor(Date.now() / 1000);
  const sent = await env.DB.prepare("SELECT COUNT(*) AS everyone, COALESCE(SUM(install = ?), 0) AS mine FROM feedback WHERE received >= ?")
    .bind(install, now - 86400).first<{ everyone: number; mine: number }>();
  if (sent && (sent.mine >= FEEDBACK_PER_INSTALL || sent.everyone >= FEEDBACK_PER_DAY)) {
    const mine = sent.mine >= FEEDBACK_PER_INSTALL;
    const max = mine ? FEEDBACK_PER_INSTALL : FEEDBACK_PER_DAY;
    // The max-th newest message still counted: once it is a day old, one more fits.
    const oldest = await env.DB.prepare(
      `SELECT received FROM feedback WHERE ${mine ? "install = ? AND " : ""}received >= ? ORDER BY received DESC LIMIT 1 OFFSET ?`,
    ).bind(...(mine ? [install] : []), now - 86400, max - 1).first<{ received: number }>();
    return tooMany(mine ? "install" : "everyone", max, oldest ? Math.max(60, oldest.received + 86400 - now) : 3600);
  }

  const response = await github(env, "/issues", { method: "POST", body: JSON.stringify(created) });
  if (!response.ok) return new Response(null, { status: 502 });
  const posted: any = await response.json();
  // The install ID stays here, so the developer can look up the same install's error reports.
  await env.DB.prepare("INSERT INTO feedback (received, install, platform, app, issue) VALUES (?, ?, ?, ?, ?)")
    .bind(now, install, platform, text(body.app, 16), whole(posted.number, Number.MAX_SAFE_INTEGER)).run();
  return Response.json({ number: posted.number, url: posted.html_url }, { status: 201 });
}

// Settings › Your Feedback asks how its issues are doing: each one's state and the developer's replies.
// The issues are public, so their numbers are all it sends; only issues labeled feedback answer.
const REPLIES_ISSUES = 10;
const REPLY_MAX = 4000;
const REPLIES_CACHE = 300; // seconds
const DEVELOPER = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);

// What the person who sent it sees of an issue's comments: the developer's, without HTML comments
// (the coding agent's marker) and without requests to the agent ("@claude fix it").
export function replies(comments: any[]) {
  return comments
    .filter((comment) => DEVELOPER.has(comment?.author_association) && typeof comment?.body === "string")
    .map((comment) => ({ date: text(comment.created_at, 32), text: comment.body.replace(/<!--[\s\S]*?-->/g, "").trim().slice(0, REPLY_MAX) }))
    .filter((reply) => reply.text && !/^@claude\b/i.test(reply.text));
}

// open, closed (done) or declined (closed as not planned), as `Feedback.Status` in Sources/TVCore/Feedback.swift reads it.
export function state(issue: any) {
  return issue?.state !== "closed" ? "open" : issue.state_reason === "not_planned" ? "declined" : "closed";
}

// One issue, from the cache for five minutes. null when it isn't a feedback issue; undefined when GitHub failed.
async function status(number: number, env: Env, origin: string) {
  const key = new Request(`${origin}/v1/feedback/replies/${number}`);
  const hit = await caches.default.match(key);
  if (hit) return hit.json();
  const [issue, comments] = await Promise.all([github(env, `/issues/${number}`), github(env, `/issues/${number}/comments?per_page=100`)]);
  if (!issue.ok && issue.status !== 404 && issue.status !== 410) return undefined;
  const found: any = issue.ok ? await issue.json() : null;
  let result = null;
  if (found && !found.pull_request && found.labels?.some((label: any) => label?.name === "feedback")) {
    if (!comments.ok) return undefined;
    result = { number, state: state(found), replies: replies(await comments.json()) };
  }
  await caches.default.put(key, Response.json(result, { headers: { "cache-control": `max-age=${REPLIES_CACHE}` } }));
  return result;
}

async function feedbackReplies(request: Request, env: Env): Promise<Response> {
  if (!env.GITHUB_TOKEN) return new Response(null, { status: 503 });
  if (!(await env.LIMITER.limit({ key: address(request) })).success) return new Response(null, { status: 429 });
  const url = new URL(request.url);
  const numbers = [...new Set((url.searchParams.get("issues") ?? "").split(",").map(Number))]
    .filter((number) => Number.isSafeInteger(number) && number > 0)
    .slice(0, REPLIES_ISSUES);
  if (!numbers.length) return new Response(null, { status: 400 });
  const found = await Promise.all(numbers.map((number) => status(number, env, url.origin)));
  if (found.some((issue) => issue === undefined)) return new Response(null, { status: 502 });
  return Response.json({ issues: found.filter(Boolean) });
}

const ROUTES: Record<string, [string, (request: Request, env: Env) => Promise<Response>]> = {
  "/v1/reports": ["POST", receive],
  "/v1/feedback": ["POST", feedback],
  "/v1/feedback/replies": ["GET", feedbackReplies],
};

export default {
  async fetch(request, env) {
    const route = ROUTES[new URL(request.url).pathname];
    if (!route) return new Response(null, { status: 404 });
    const [method, handle] = route;
    if (request.method !== method) return new Response(null, { status: 405, headers: { allow: method } });
    return handle(request, env);
  },
  async scheduled(_controller, env) {
    const old = Math.floor(Date.now() / 1000) - KEEP_DAYS * 86400;
    await env.DB.batch([
      env.DB.prepare("DELETE FROM reports WHERE received < ?").bind(old),
      env.DB.prepare("DELETE FROM feedback WHERE received < ?").bind(old),
    ]);
  },
} satisfies ExportedHandler<Env>;

// Feedback that counts for someone: the issues their signed-in installs sent, and whether the developer adopted them.
// The error-reports Worker keeps install → issue for 30 days only, so the rows are copied here: when an install signs
// in (what it sent before) and every 15 minutes (what was sent since). GitHub tells what became of each issue.

import { points } from "./points";
import { grant } from "./pro";
import { User } from "./session";
import { DAY, Env, now, number } from "./util";

export type Status = "open" | "fixed" | "adopted" | "closed" | "declined" | "duplicate";

// What became of an issue. Fixed or adopted only when the developer says so with a label: `fixed` (a reported bug
// fixed) or `adopted` (a suggested idea taken), since those are worth many points; closed as completed without one is just closed. Declined:
// closed as not planned, or labeled invalid / wontfix / spam. Labels win over the state, and duplicate over all.
export function statusOf(issue: any): Status {
  const labels = new Set((issue?.labels ?? []).map((label: any) => String(typeof label === "string" ? label : label?.name ?? "").toLowerCase()));
  if (labels.has("duplicate") || issue?.state_reason === "duplicate") return "duplicate";
  if (labels.has("invalid") || labels.has("wontfix") || labels.has("spam")) return "declined";
  if (labels.has("adopted")) return "adopted";
  if (labels.has("fixed")) return "fixed";
  if (issue?.state === "closed") return issue.state_reason === "not_planned" ? "declined" : "closed";
  return "open";
}

const github = (env: Env, path: string) =>
  fetch(`${env.GITHUB_API ?? "https://api.github.com"}/repos/${env.FEEDBACK_REPO}${path}`, {
    headers: {
      accept: "application/vnd.github+json",
      ...(env.GITHUB_TOKEN ? { authorization: `Bearer ${env.GITHUB_TOKEN}` } : {}),
      "user-agent": "yingxia-accounts",
      "x-github-api-version": "2022-11-28",
    },
  });

async function mark(env: Env, name: string) {
  return (await env.DB.prepare("SELECT value FROM marks WHERE name = ?").bind(name).first<{ value: number }>())?.value ?? 0;
}
const setMark = (env: Env, name: string, value: number) =>
  env.DB.prepare("INSERT INTO marks (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value").bind(name, value).run();

// What an install sent before it signed in (as far back as the error reports keep it).
export async function copyInstall(env: Env, user: User, install: string) {
  const rows = await env.REPORTS.prepare("SELECT install, issue, received FROM feedback WHERE install = ? COLLATE NOCASE")
    .bind(install).all<{ install: string; issue: number; received: number }>();
  if (!rows.results.length) return 0;
  await env.DB.batch(rows.results.map((row) =>
    env.DB.prepare("INSERT OR IGNORE INTO feedback_issues (issue, user_id, install, sent) VALUES (?, ?, ?, ?)")
      .bind(row.issue, user.id, row.install.toUpperCase(), row.received)));
  return rows.results.length;
}

// Feedback sent since the last run by installs that are signed in.
export async function copyNew(env: Env) {
  let from = await mark(env, "reports");
  if (!from) from = now() - 30 * DAY;
  for (let page = 0; page < 10; page++) {
    const rows = await env.REPORTS.prepare("SELECT install, issue, received FROM feedback WHERE received > ? ORDER BY received LIMIT 500")
      .bind(from).all<{ install: string; issue: number; received: number }>();
    if (!rows.results.length) break;
    const installs = [...new Set(rows.results.map((row) => row.install.toUpperCase()))];
    const owners = new Map<string, string>();
    for (let start = 0; start < installs.length; start += 90) {
      const part = installs.slice(start, start + 90);
      const found = await env.DB.prepare(`SELECT install, user_id FROM installs WHERE install IN (${part.map(() => "?").join(",")})`)
        .bind(...part).all<{ install: string; user_id: string }>();
      for (const row of found.results) owners.set(row.install, row.user_id);
    }
    const inserts = rows.results.filter((row) => owners.has(row.install.toUpperCase())).map((row) =>
      env.DB.prepare("INSERT OR IGNORE INTO feedback_issues (issue, user_id, install, sent) VALUES (?, ?, ?, ?)")
        .bind(row.issue, owners.get(row.install.toUpperCase())!, row.install.toUpperCase(), row.received));
    if (inserts.length) await env.DB.batch(inserts);
    from = rows.results[rows.results.length - 1].received;
    await setMark(env, "reports", from);
    if (rows.results.length < 500) break;
  }
}

// Records an issue's status; the first time it is fixed or adopted, its sender may get Pro days (REWARD_DAYS).
async function record(env: Env, issue: any) {
  const status = statusOf(issue);
  const row = await env.DB.prepare("UPDATE feedback_issues SET status = ?, title = ?, updated = ? WHERE issue = ? RETURNING user_id")
    .bind(status, String(issue.title ?? "").slice(0, 200), now(), issue.number).first<{ user_id: string }>();
  const days = number(env.REWARD_DAYS, 0);
  if (row && (status === "fixed" || status === "adopted") && days > 0) await grant(env, row.user_id, "reward", `issue:${issue.number}`, Math.trunc(days), "github");
}

// Reads what changed on GitHub since the last run, then any copied issue that has no status yet.
export async function syncStatuses(env: Env) {
  const since = await mark(env, "github");
  let newest = since;
  for (let page = 1; page <= 5; page++) {
    const query = new URLSearchParams({ labels: "feedback", state: "all", sort: "updated", direction: "asc", per_page: "100", page: String(page) });
    if (since) query.set("since", new Date(since * 1000).toISOString());
    const response = await github(env, `/issues?${query}`);
    if (!response.ok) break;
    const issues: any[] = await response.json();
    const numbers = issues.filter((issue) => !issue.pull_request).map((issue) => issue.number);
    if (numbers.length) {
      const tracked = await env.DB.prepare(`SELECT issue FROM feedback_issues WHERE issue IN (${numbers.map(() => "?").join(",")})`)
        .bind(...numbers).all<{ issue: number }>();
      const ours = new Set(tracked.results.map((row) => row.issue));
      for (const issue of issues) if (ours.has(issue.number)) await record(env, issue);
    }
    for (const issue of issues) newest = Math.max(newest, Math.floor(Date.parse(issue.updated_at) / 1000) || 0);
    if (issues.length < 100) break;
  }
  if (newest > since) await setMark(env, "github", newest);
  await syncUnknown(env, 20);
}

// Copied issues GitHub hasn't told about yet (sent before the install signed in), one request each.
export async function syncUnknown(env: Env, limit: number, userID?: string) {
  const rows = await env.DB.prepare(`SELECT issue FROM feedback_issues WHERE status IS NULL${userID ? " AND user_id = ?" : ""} ORDER BY sent DESC LIMIT ?`)
    .bind(...(userID ? [userID] : []), limit).all<{ issue: number }>();
  for (const row of rows.results) {
    const response = await github(env, `/issues/${row.issue}`);
    if (response.ok) {
      // Only the issue that was asked for (an odd answer must not be written down as it).
      const issue: any = await response.json().catch(() => null);
      if (issue?.number === row.issue) await record(env, issue);
    }
    else if (response.status === 404 || response.status === 410) {
      await env.DB.prepare("UPDATE feedback_issues SET status = 'declined', updated = ? WHERE issue = ?").bind(now(), row.issue).run();
    }
  }
}

export async function stats(env: Env, user: User) {
  const counts = await env.DB.prepare(
    "SELECT COUNT(*) AS sent, COALESCE(SUM(status = 'fixed'), 0) AS fixed, COALESCE(SUM(status = 'adopted'), 0) AS adopted, COALESCE(SUM(status IN ('declined', 'duplicate')), 0) AS declined FROM feedback_issues WHERE user_id = ?",
  ).bind(user.id).first<{ sent: number; fixed: number; adopted: number; declined: number }>();
  const recent = await env.DB.prepare("SELECT issue, title, status, sent FROM feedback_issues WHERE user_id = ? ORDER BY sent DESC LIMIT 20")
    .bind(user.id).all<{ issue: number; title: string; status: Status | null; sent: number }>();
  const sent = counts?.sent ?? 0;
  const adopted = counts?.adopted ?? 0;
  return {
    sent,
    fixed: counts?.fixed ?? 0,
    adopted,
    declined: counts?.declined ?? 0,
    points: (await points(env, user.id)).total,
    rewardDays: number(env.REWARD_DAYS, 0),
    issues: recent.results.map((row) => ({ number: row.issue, title: row.title, status: row.status ?? "open", sent: row.sent })),
  };
}

// Points: what someone's help is worth. They reward feedback and code that get used, far more than volume:
// - each day the app is open while signed in: POINTS_DAILY (an install gives one account its day);
// - each feedback message, from the app or /feedback in the Telegram group: POINTS_SENT, at most SENT_PER_DAY a day,
//   none for duplicates or declined ones;
// - each reported bug the developer fixes (labeled `fixed` on GitHub): POINTS_FIXED;
// - each suggested idea the developer adopts (labeled `adopted`): POINTS_ADOPTED;
// - each merged pull request (src/prs.ts): POINTS_PR;
// - plus or minus what the admin set by hand.
// The total is counted again from those rows every time, so there's no running number to drift or to tamper with.

import { Env, now, number } from "./util";

export const SENT_PER_DAY = 3;
// A day starts at midnight in China (UTC+8), where most people using Yingxia are.
export const DAY_OFFSET = 8 * 3600;
export const dayOf = (seconds: number) => Math.floor((seconds + DAY_OFFSET) / 86400);

export function rules(env: Env) {
  return {
    daily: number(env.POINTS_DAILY, 1),
    sent: number(env.POINTS_SENT, 1),
    sentPerDay: SENT_PER_DAY,
    fixed: number(env.POINTS_FIXED, 50),
    adopted: number(env.POINTS_ADOPTED, 100),
    pullRequest: number(env.POINTS_PR, 500),
  };
}
export type Rules = ReturnType<typeof rules>;

export interface Points {
  total: number;
  days: number; // days the app was used
  sent: number; // feedback messages that earned their point
  fixed: number; // reported bugs fixed
  adopted: number; // suggested ideas adopted
  pullRequests: number;
  adjusted: number; // points the admin added (or took away)
  rules: Rules;
}

export async function points(env: Env, userID: string): Promise<Points> {
  const row = await env.DB.prepare(
    `SELECT
      (SELECT COUNT(*) FROM active_days WHERE user_id = ?1) AS days,
      (SELECT COALESCE(SUM(MIN(n, ${SENT_PER_DAY})), 0) FROM (SELECT COUNT(*) AS n FROM feedback_issues
        WHERE user_id = ?1 AND COALESCE(status, 'open') NOT IN ('declined', 'duplicate') GROUP BY (sent + ${DAY_OFFSET}) / 86400)) AS sent,
      (SELECT COUNT(*) FROM feedback_issues WHERE user_id = ?1 AND status = 'fixed') AS fixed,
      (SELECT COUNT(*) FROM feedback_issues WHERE user_id = ?1 AND status = 'adopted') AS adopted,
      (SELECT COUNT(*) FROM pull_requests WHERE user_id = ?1 AND excluded = 0) AS pullRequests,
      (SELECT COALESCE(SUM(points), 0) FROM point_adjustments WHERE user_id = ?1) AS adjusted`,
  ).bind(userID).first<{ days: number; sent: number; fixed: number; adopted: number; pullRequests: number; adjusted: number }>();
  const rule = rules(env);
  const counts = { days: row?.days ?? 0, sent: row?.sent ?? 0, fixed: row?.fixed ?? 0, adopted: row?.adopted ?? 0, pullRequests: row?.pullRequests ?? 0, adjusted: row?.adjusted ?? 0 };
  const total = counts.days * rule.daily + counts.sent * rule.sent + counts.fixed * rule.fixed + counts.adopted * rule.adopted + counts.pullRequests * rule.pullRequest + counts.adjusted;
  return { total, ...counts, rules: rule };
}

// Whether a feedback message sent at `sent` still earns its point: the first SENT_PER_DAY of that day do.
export async function earnsSentPoint(env: Env, userID: string, issue: number, sent: number) {
  const day = dayOf(sent);
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS before FROM feedback_issues WHERE user_id = ? AND (sent + ${DAY_OFFSET}) / 86400 = ? AND issue != ?
      AND COALESCE(status, 'open') NOT IN ('declined', 'duplicate') AND (sent < ? OR (sent = ? AND issue < ?))`,
  ).bind(userID, day, issue, sent, sent, issue).first<{ before: number }>();
  return (row?.before ?? 0) < SENT_PER_DAY;
}

// The app is open today (POST /v1/me/day). One point a day per account, and each install gives its day to one
// account only, so signing one device in and out of many accounts earns nothing more. True if the day is new.
export async function markDay(env: Env, userID: string, install: string) {
  if (!install) return false;
  const day = dayOf(now());
  const [, added] = await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO install_days (install, day, user_id) VALUES (?, ?, ?)").bind(install, day, userID),
    env.DB.prepare(
      "INSERT OR IGNORE INTO active_days (user_id, day, install) SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM install_days WHERE install = ? AND day = ? AND user_id = ?)",
    ).bind(userID, day, install, install, day, userID),
  ]);
  return added.meta.changes > 0;
}

export const cleanInstallDays = (env: Env) => env.DB.prepare("DELETE FROM install_days WHERE day < ?").bind(dayOf(now()) - 7).run();

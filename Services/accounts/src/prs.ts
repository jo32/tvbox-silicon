// Merged pull requests by other people earn POINTS_PR for the account their description names, in a line like
//   Yingxia account: u_XXXXXXXXXXXXXXXXXXXX     (Settings › Account shows the ID; 映匣账号： works too)
// or the person's Telegram @username, or the email of their Sign in with Apple. A GitHub user whose claim matched
// once keeps earning for that account without writing it again (github_logins).
// Never counted: pull requests by the repository's owners (PR_EXCLUDE) and bots, ones labeled `no-points`, and claims
// that fit more than one account. Each pull request counts once, for one account. The admin can set it by hand.

import { Env, list } from "./util";

// On one line: an empty "Yingxia account:" must not take the next line's first word.
const CLAIM = /(?:yingxia[ \t]*account|映匣[ \t]*账[号户]|映匣[ \t]*帳[號戶])[ \t]*[:：][ \t]*`?([^\s`<>()（）]+)/i;

// What the description claims; HTML comments (the template's hints) don't count.
export function claimOf(body: unknown) {
  const visible = String(body ?? "").replace(/<!--[\s\S]*?-->/g, "");
  const found = CLAIM.exec(visible);
  return found ? found[1].replace(/[.,;:，。；]+$/, "").slice(0, 120) : "";
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

// The one account a claim names, or null (nothing, or more than one).
async function owner(env: Env, claim: string): Promise<{ user: string; how: string } | null> {
  if (!claim) return null;
  if (/^u_[0-9A-Za-z]{20}$/.test(claim)) {
    const found = await env.DB.prepare("SELECT id FROM users WHERE id = ?").bind("u_" + claim.slice(2).toUpperCase()).first<{ id: string }>();
    return found ? { user: found.id, how: "id" } : null;
  }
  const one = async (provider: string, label: string, how: string) => {
    const rows = await env.DB.prepare("SELECT DISTINCT user_id FROM identities WHERE provider = ? AND label = ? COLLATE NOCASE LIMIT 2")
      .bind(provider, label).all<{ user_id: string }>();
    return rows.results.length === 1 ? { user: rows.results[0].user_id, how } : null;
  };
  if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(claim)) return one("apple", claim, "email");
  const telegram = claim.replace(/^(?:https?:\/\/)?t\.me\//i, "").replace(/^@/, "");
  if (/^[A-Za-z][A-Za-z0-9_]{3,31}$/.test(telegram)) return one("telegram", "@" + telegram, "telegram");
  return null;
}

interface Row { number: number; author: string; author_id: number; claim: string; user_id: string | null; how: string }

// Who a pull request counts for: its claim, else its author's remembered account. A matched claim teaches the login.
export async function assign(env: Env, row: Row) {
  if (row.how === "admin") return;
  const claimed = await owner(env, row.claim);
  let user: string | null = null, how = "";
  if (claimed) {
    ({ user, how } = claimed);
    await env.DB.prepare(
      "INSERT INTO github_logins (login_id, login, user_id, how) VALUES (?, ?, ?, ?) ON CONFLICT(login_id) DO UPDATE SET login = excluded.login, user_id = excluded.user_id, how = excluded.how WHERE github_logins.how != 'admin'",
    ).bind(row.author_id, row.author, user, how).run();
  } else {
    const known = await env.DB.prepare("SELECT user_id FROM github_logins WHERE login_id = ?").bind(row.author_id).first<{ user_id: string }>();
    if (known) (user = known.user_id), (how = "github");
  }
  if (user !== row.user_id || how !== row.how) {
    await env.DB.prepare("UPDATE pull_requests SET user_id = ?, how = ? WHERE number = ?").bind(user, how, row.number).run();
  }
}

async function mark(env: Env) {
  return (await env.DB.prepare("SELECT value FROM marks WHERE name = 'pulls'").first<{ value: number }>())?.value ?? 0;
}

// Pull requests closed or edited since the last run (newest first, so the first run reads up to 1,000 back), then
// another try at the ones nobody matched yet (their author may have signed in since).
export async function syncPullRequests(env: Env) {
  const since = await mark(env);
  let newest = since;
  const owners = new Set(list(env.PR_EXCLUDE).map((login) => login.toLowerCase()));
  pages: for (let page = 1; page <= (since ? 3 : 10); page++) {
    const query = new URLSearchParams({ state: "closed", sort: "updated", direction: "desc", per_page: "100", page: String(page) });
    const response = await github(env, `/pulls?${query}`);
    if (!response.ok) break;
    const pulls: any[] = await response.json();
    for (const pull of pulls) {
      const updated = Math.floor(Date.parse(pull.updated_at) / 1000) || 0;
      if (since && updated <= since) break pages;
      newest = Math.max(newest, updated);
      const merged = Math.floor(Date.parse(pull.merged_at ?? "") / 1000);
      const login = String(pull.user?.login ?? "");
      if (!merged || !login || pull.user?.type === "Bot" || owners.has(login.toLowerCase())) continue;
      const excluded = (pull.labels ?? []).some((label: any) => String(label?.name ?? "").toLowerCase() === "no-points") ? 1 : 0;
      const row = await env.DB.prepare(
        `INSERT INTO pull_requests (number, author, author_id, title, merged, claim, excluded) VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(number) DO UPDATE SET author = excluded.author, title = excluded.title, claim = excluded.claim,
           excluded = CASE WHEN pull_requests.how = 'admin' THEN pull_requests.excluded ELSE excluded.excluded END
         RETURNING number, author, author_id, claim, user_id, how`,
      ).bind(pull.number, login, Number(pull.user?.id ?? 0), String(pull.title ?? "").slice(0, 200), merged, claimOf(pull.body), excluded).first<Row>();
      if (row) await assign(env, row);
    }
    if (pulls.length < 100) break;
  }
  if (newest > since) {
    await env.DB.prepare("INSERT INTO marks (name, value) VALUES ('pulls', ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value").bind(newest).run();
  }
  const waiting = await env.DB.prepare("SELECT number, author, author_id, claim, user_id, how FROM pull_requests WHERE user_id IS NULL AND excluded = 0 LIMIT 100").all<Row>();
  for (const row of waiting.results) await assign(env, row);
}

export async function pullRequestsOf(env: Env, userID: string) {
  const rows = await env.DB.prepare("SELECT number, title, merged FROM pull_requests WHERE user_id = ? AND excluded = 0 ORDER BY merged DESC LIMIT 50")
    .bind(userID).all<{ number: number; title: string; merged: number }>();
  return rows.results;
}


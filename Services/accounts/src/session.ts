// People, how they sign in, and the app's session tokens.

import { base64url, bytes, DAY, Env, error, isInstall, now, PLATFORMS, randomText, sha256, text } from "./util";

export const SESSION_DAYS = 365;

export interface User {
  id: string;
  created: number;
  name: string;
  pro_until: number | null;
}

export interface Identity {
  provider: "apple" | "telegram";
  subject: string;
  label?: string;
  name?: string;
  refresh?: string | null;
  client?: string | null;
}

// The person who signs in with `identity`, made the first time. A name or label only fills in what is empty or changed.
export async function userFor(env: Env, identity: Identity): Promise<User> {
  const found = await env.DB.prepare(
    "SELECT u.* FROM identities i JOIN users u ON u.id = i.user_id WHERE i.provider = ? AND i.subject = ?",
  ).bind(identity.provider, identity.subject).first<User>();
  const time = now();
  if (found) {
    const updates = [];
    if (identity.label) updates.push(env.DB.prepare("UPDATE identities SET label = ? WHERE provider = ? AND subject = ?").bind(identity.label, identity.provider, identity.subject));
    if (identity.refresh) {
      updates.push(env.DB.prepare("UPDATE identities SET refresh = ?, client = ? WHERE provider = ? AND subject = ?")
        .bind(identity.refresh, identity.client ?? null, identity.provider, identity.subject));
    }
    if (identity.name && !found.name) {
      updates.push(env.DB.prepare("UPDATE users SET name = ? WHERE id = ?").bind(identity.name, found.id));
      found.name = identity.name;
    }
    if (updates.length) await env.DB.batch(updates);
    return found;
  }
  const user: User = { id: "u_" + randomText(20), created: time, name: identity.name ?? "", pro_until: null };
  await env.DB.batch([
    env.DB.prepare("INSERT INTO users (id, created, name) VALUES (?, ?, ?)").bind(user.id, user.created, user.name),
    env.DB.prepare("INSERT INTO identities (provider, subject, user_id, label, refresh, client, created) VALUES (?, ?, ?, ?, ?, ?, ?)")
      .bind(identity.provider, identity.subject, user.id, identity.label ?? "", identity.refresh ?? null, identity.client ?? null, time),
  ]);
  return user;
}

// Adds a sign-in method to someone already signed in. Refused when it already belongs to someone else.
export async function addIdentity(env: Env, user: User, identity: Identity): Promise<boolean> {
  const owner = await env.DB.prepare("SELECT user_id FROM identities WHERE provider = ? AND subject = ?")
    .bind(identity.provider, identity.subject).first<{ user_id: string }>();
  if (owner) return owner.user_id === user.id;
  await env.DB.prepare("INSERT INTO identities (provider, subject, user_id, label, refresh, client, created) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .bind(identity.provider, identity.subject, user.id, identity.label ?? "", identity.refresh ?? null, identity.client ?? null, now()).run();
  return true;
}

// Ties the install (the ID feedback and error reports carry) to the person, so its feedback counts for them.
export async function link(env: Env, user: User, install: string, platform: string) {
  if (!isInstall(install)) return;
  await env.DB.prepare(
    "INSERT INTO installs (install, user_id, platform, linked) VALUES (?, ?, ?, ?) ON CONFLICT(install) DO UPDATE SET user_id = excluded.user_id, platform = excluded.platform, linked = excluded.linked",
  ).bind(install.toUpperCase(), user.id, PLATFORMS.has(platform) ? platform : "", now()).run();
}

// A new session token for the app. Only its hash is stored.
export async function session(env: Env, user: User, install: string, platform: string) {
  const token = "yxs_" + base64url(bytes(32));
  const time = now();
  await env.DB.prepare("INSERT INTO sessions (hash, user_id, install, platform, created, used, expires) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .bind(await sha256(token), user.id, isInstall(install) ? install.toUpperCase() : "", PLATFORMS.has(platform) ? platform : "", time, time, time + SESSION_DAYS * DAY)
    .run();
  await link(env, user, install, platform);
  return token;
}

export const bearer = (request: Request) => /^Bearer (\S+)$/.exec(request.headers.get("authorization") ?? "")?.[1] ?? "";

// The signed-in person, or the 401 to send. A session in use keeps going: each day of use pushes its end a year out.
export async function authenticate(request: Request, env: Env): Promise<{ user: User; hash: string } | Response> {
  const token = bearer(request);
  if (!token.startsWith("yxs_")) return error(401, "signed_out");
  const hash = await sha256(token);
  const row = await env.DB.prepare(
    "SELECT u.*, s.used AS session_used, s.expires AS session_expires FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.hash = ?",
  ).bind(hash).first<User & { session_used: number; session_expires: number }>();
  const time = now();
  if (!row || row.session_expires < time) return error(401, "signed_out");
  if (time - row.session_used > DAY) {
    await env.DB.prepare("UPDATE sessions SET used = ?, expires = ? WHERE hash = ?").bind(time, time + SESSION_DAYS * DAY, hash).run();
  }
  const { session_used: _used, session_expires: _expires, ...user } = row;
  return { user, hash };
}

export async function identities(env: Env, user: User) {
  const rows = await env.DB.prepare("SELECT provider, label, created FROM identities WHERE user_id = ? ORDER BY created")
    .bind(user.id).all<{ provider: string; label: string; created: number }>();
  return rows.results;
}

// Everything about the person goes, in one transaction (their grants only lose their name). Apple's token is revoked first (src/apple.ts).
export async function erase(env: Env, userID: string) {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM identities WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM installs WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM feedback_issues WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM active_days WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM point_adjustments WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM github_logins WHERE user_id = ?").bind(userID),
    env.DB.prepare("UPDATE pull_requests SET user_id = NULL, how = '' WHERE user_id = ?").bind(userID),
    // Grants stay under a name that no longer leads to anyone: a code's uses are counted from them, and an
    // adopted issue's reward is given once, so deleting and signing in again can't reuse either.
    env.DB.prepare("UPDATE grants SET user_id = 'deleted:' || user_id WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM telegram_logins WHERE user_id = ?").bind(userID),
    env.DB.prepare("DELETE FROM users WHERE id = ?").bind(userID),
  ]);
}

export const display = (value: unknown, max = 80) => text(value, max).replace(/[\u0000-\u001f]/g, "").trim();

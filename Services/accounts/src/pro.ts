// Pro: redeem codes (made by the admin pages), other grants, and the signed entitlement the app keeps.

import { User } from "./session";
import { base64url, DAY, Env, LIFETIME, now, randomText, sha256, unbase64 } from "./util";

// One spelling per code: capitals, no spaces or dashes, and O/I/L read as 0/1 as people often type them.
export function normalize(code: string) {
  return code.toUpperCase().replace(/[\s-]+/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
}
export const validCode = (normalized: string) => /^[A-Z0-9]{6,40}$/.test(normalized);
const format = (raw: string) => raw.match(/.{1,4}/g)!.join("-");

export interface CodeRequest {
  count?: number; // how many to make, when `codes` isn't given
  codes?: string[]; // codes the admin pages chose themselves
  days?: number | null; // null or 0 = lifetime
  maxUses?: number;
  expires?: number | null; // unix seconds
  batch?: string;
  note?: string;
}

export const MAX_CODES = 500;

// Makes the codes and returns them in plain text: this is the only time they can be seen, only their hash is kept.
export async function createCodes(env: Env, request: CodeRequest) {
  const days = request.days ? Math.trunc(request.days) : null;
  if (days !== null && (days < 1 || days > 36500)) throw new Error("days must be 1-36500, or null for lifetime");
  const maxUses = Math.trunc(request.maxUses ?? 1);
  if (maxUses < 1 || maxUses > 100000) throw new Error("maxUses must be 1-100000");
  const expires = request.expires ? Math.trunc(request.expires) : null;
  const wanted = request.codes?.length ? request.codes.map((code) => String(code)) : null;
  const count = wanted ? wanted.length : Math.trunc(request.count ?? 1);
  if (count < 1 || count > MAX_CODES) throw new Error(`count must be 1-${MAX_CODES}`);
  const made = (wanted ?? Array.from({ length: count }, () => format(randomText(16)))).map((code) => ({ code, normalized: normalize(code) }));
  const bad = made.find((item) => !validCode(item.normalized));
  if (bad) throw new Error(`not a valid code: ${bad.code} (6-40 letters and digits)`);
  if (new Set(made.map((item) => item.normalized)).size !== made.length) throw new Error("the same code twice");
  const time = now();
  const rows = await Promise.all(made.map(async (item) => ({
    id: "c_" + randomText(12),
    code: item.code,
    hash: await sha256(item.normalized),
    hint: item.normalized.slice(-4),
  })));
  const taken = await env.DB.prepare(`SELECT hash FROM codes WHERE hash IN (${rows.map(() => "?").join(",")})`).bind(...rows.map((row) => row.hash)).all<{ hash: string }>();
  if (taken.results.length) throw new Error(`${taken.results.length} of these codes already exist`);
  const batch = (request.batch ?? "").slice(0, 80);
  const note = (request.note ?? "").slice(0, 500);
  for (let start = 0; start < rows.length; start += 50) {
    await env.DB.batch(rows.slice(start, start + 50).map((row) =>
      env.DB.prepare("INSERT INTO codes (id, hash, hint, batch, note, days, max_uses, created, expires) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .bind(row.id, row.hash, row.hint, batch, note, days, maxUses, time, expires)));
  }
  return { batch, days, maxUses, expires, codes: rows.map(({ id, code, hint }) => ({ id, code, hint })) };
}

// SQL that moves the person's Pro end by `days` (from now, or from a later end), or to the end of time for null.
const extend = (days: number | null, time: number) =>
  days === null ? `${LIFETIME}` : `CASE WHEN COALESCE(pro_until, 0) >= ${LIFETIME} THEN pro_until ELSE MAX(COALESCE(pro_until, 0), ${time}) + ${Math.trunc(days) * DAY} END`;

export type RedeemFailure = "invalid" | "not_found" | "revoked" | "expired" | "used_up" | "already_redeemed";

export async function redeem(env: Env, user: User, input: string, via: string): Promise<{ days: number | null; proUntil: number } | RedeemFailure> {
  const normalized = normalize(input);
  if (!validCode(normalized)) return "invalid";
  const code = await env.DB.prepare("SELECT * FROM codes WHERE hash = ?").bind(await sha256(normalized))
    .first<{ id: string; days: number | null; max_uses: number; used: number; expires: number | null; revoked: number }>();
  if (!code) return "not_found";
  const time = now();
  if (code.revoked) return "revoked";
  if (code.expires && code.expires <= time) return "expired";
  const mine = await env.DB.prepare("SELECT 1 FROM grants WHERE kind = 'code' AND ref = ? AND user_id = ?").bind(code.id, user.id).first();
  if (mine) return "already_redeemed";
  if (code.used >= code.max_uses) return "used_up";
  // One transaction, so two people can't both take a code's last use: the grant only goes in while uses are left,
  // the count is taken from the grants, and the person's Pro time moves only if their grant went in.
  const at = Date.now();
  const results = await env.DB.batch([
    env.DB.prepare(
      "INSERT OR IGNORE INTO grants (user_id, kind, ref, days, via, at) SELECT ?, 'code', id, days, ?, ? FROM codes WHERE id = ? AND revoked = 0 AND used < max_uses AND (expires IS NULL OR expires > ?)",
    ).bind(user.id, via, at, code.id, time),
    env.DB.prepare("UPDATE codes SET used = (SELECT COUNT(*) FROM grants WHERE kind = 'code' AND ref = ?) WHERE id = ?").bind(code.id, code.id),
    env.DB.prepare(`UPDATE users SET pro_until = ${extend(code.days, time)} WHERE id = ? AND EXISTS (SELECT 1 FROM grants WHERE kind = 'code' AND ref = ? AND user_id = ? AND at = ?)`)
      .bind(user.id, code.id, user.id, at),
  ]);
  if (!results[0].meta.changes) return "used_up";
  const after = await env.DB.prepare("SELECT pro_until FROM users WHERE id = ?").bind(user.id).first<{ pro_until: number }>();
  return { days: code.days, proUntil: after?.pro_until ?? time };
}

// Pro time given another way (a reward, or the admin). Each (kind, ref) is given once, to anyone (an adopted issue's
// reward too, even after its sender deleted their account); false if it already was.
export async function grant(env: Env, userID: string, kind: "reward" | "admin", ref: string, days: number | null, via: string) {
  const at = Date.now();
  const time = now();
  const results = await env.DB.batch([
    env.DB.prepare(
      "INSERT OR IGNORE INTO grants (user_id, kind, ref, days, via, at) SELECT id, ?, ?, ?, ?, ? FROM users WHERE id = ? AND NOT EXISTS (SELECT 1 FROM grants WHERE kind = ? AND ref = ?)",
    ).bind(kind, ref, days, via, at, userID, kind, ref),
    env.DB.prepare(`UPDATE users SET pro_until = ${extend(days, time)} WHERE id = ? AND EXISTS (SELECT 1 FROM grants WHERE kind = ? AND ref = ? AND user_id = ? AND at = ?)`)
      .bind(userID, kind, ref, userID, at),
  ]);
  return Boolean(results[0].meta.changes);
}

export const isPro = (user: User, time = now()) => (user.pro_until ?? 0) > time;

let signer: CryptoKey | null = null;

// What the app keeps to know it is Pro, offline too: the person, when Pro ends, signed with the Ed25519 key whose
// public half is in Sources/TVCore/Account.swift. Null without the key (wrangler secret put ENTITLEMENT_KEY).
export async function entitlement(env: Env, user: User) {
  if (!env.ENTITLEMENT_KEY) return null;
  signer ??= await crypto.subtle.importKey("pkcs8", unbase64(env.ENTITLEMENT_KEY), { name: "Ed25519" }, false, ["sign"]);
  const payload = new TextEncoder().encode(JSON.stringify({ v: 1, user: user.id, until: user.pro_until ?? 0, issued: now() }));
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, signer, payload);
  return { payload: base64url(payload), signature: base64url(signature) };
}

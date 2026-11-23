// Small helpers shared by the routes.

export interface Env {
  DB: D1Database;
  // The error-reports database (Services/error-reports), read only: its `feedback` table ties an issue to an install.
  REPORTS: D1Database;
  LIMITER: RateLimit;
  REDEEM_LIMITER: RateLimit;
  // owner/name of the repository whose feedback issues count.
  FEEDBACK_REPO: string;
  // The bundle IDs Apple's identity tokens may be issued to, comma-separated.
  APPLE_AUDIENCES: string;
  APPLE_TEAM_ID: string;
  // The bot people sign in and redeem with, without the @.
  TELEGRAM_BOT: string;
  // Points (src/points.ts): a day of use, a message sent, one adopted, a merged pull request. And the Pro days an
  // adopted message gives (0 = none).
  POINTS_DAILY: string;
  POINTS_SENT: string;
  POINTS_FIXED: string;
  POINTS_ADOPTED: string;
  POINTS_PR: string;
  REWARD_DAYS: string;
  // GitHub logins whose pull requests never earn points (the repository's owners), comma-separated.
  PR_EXCLUDE: string;
  // Origins of the admin pages, comma-separated, for CORS.
  ADMIN_ORIGINS: string;
  // TestFlight invitations through the bot's /tf (src/tf.ts): places per day in Yingxia Beta and the hour (UTC+8)
  // they open, the mail domains accepted, the days before someone removed for not using it may ask again, the two
  // apps and their external groups, and the address the codes come from.
  TF_DAILY: string;
  TF_OPEN_HOUR: string;
  TF_DOMAINS: string;
  TF_AGAIN_DAYS: string;
  TF_BETA_APP: string;
  TF_BETA_GROUP: string;
  TF_PRO_APP: string;
  TF_PRO_GROUP: string;
  TF_FROM: string;
  ASC_ISSUER: string; // App Store Connect API issuer ID
  // Cloudflare Email Sending (send_email binding), for the codes.
  EMAIL?: { send(message: { to: string; from: string; subject: string; text: string }): Promise<{ messageId: string }> };
  // Secrets.
  ADMIN_TOKEN?: string;
  ENTITLEMENT_KEY?: string; // Ed25519 private key, PKCS#8, base64
  TELEGRAM_WEBHOOK_SECRET?: string; // shared with the bot's Worker (yx-tg ACCOUNTS_SECRET)
  GITHUB_TOKEN?: string;
  APPLE_KEY_ID?: string; // Sign in with Apple key: lets account deletion revoke Apple's token
  APPLE_PRIVATE_KEY?: string; // its .p8, PEM
  ASC_KEY_ID?: string; // App Store Connect API key (App Manager or Admin): invites TestFlight testers
  ASC_PRIVATE_KEY?: string; // its .p8, PEM
  // Local tests only (.dev.vars): stand-ins for Apple and GitHub.
  APPLE_API?: string;
  GITHUB_API?: string;
  ASC_API?: string;
  EMAIL_API?: string;
}

export const MAX_BODY = 64 * 1024;
export const DAY = 86400;
export const LIFETIME = 253402300799; // 9999-12-31
export const PLATFORMS = new Set(["macos", "ios", "tvos"]);

export const now = () => Math.floor(Date.now() / 1000);
export const text = (value: unknown, max: number) => (typeof value === "string" ? value.slice(0, max) : "");
export const address = (request: Request) => request.headers.get("cf-connecting-ip") ?? "";
export const isInstall = (value: string) => /^[0-9A-Fa-f-]{36}$/.test(value);
export const number = (value: string | undefined, fallback: number) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

export const json = (body: unknown, status = 200, headers: HeadersInit = {}) =>
  Response.json(body, { status, headers: { "cache-control": "no-store", ...headers } });
export const error = (status: number, code: string, extra: Record<string, unknown> = {}) => json({ error: code, ...extra }, status);

// The JSON body, or the response that turns it away.
export async function parse(request: Request): Promise<any> {
  if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY) return error(413, "too_large");
  const raw = await request.text();
  if (raw.length > MAX_BODY) return error(413, "too_large");
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return error(400, "bad_json");
  }
}

export const bytes = (length: number) => crypto.getRandomValues(new Uint8Array(length));

export function base64url(data: Uint8Array | ArrayBuffer) {
  const view = data instanceof Uint8Array ? data : new Uint8Array(data);
  let binary = "";
  for (const byte of view) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unbase64(value: string) {
  const plain = value.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  const binary = atob(plain + "=".repeat((4 - (plain.length % 4)) % 4));
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

export async function sha256(value: string) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

// Letters and digits that can't be mistaken for each other (Crockford's base 32).
export const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export function randomText(length: number) {
  return [...bytes(length)].map((byte) => ALPHABET[byte & 31]).join("");
}

// Constant-time comparison for secrets.
export function same(a: string, b: string) {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  let diff = left.length ^ right.length;
  for (let index = 0; index < Math.max(left.length, right.length); index++) diff |= (left[index] ?? 0) ^ (right[index] ?? 0);
  return diff === 0;
}

// A short-lived ES256 JWT signed with an Apple .p8 key (PEM, with or without its header lines).
export async function jwtES256(pem: string, header: Record<string, unknown>, claims: Record<string, unknown>) {
  const raw = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const key = await crypto.subtle.importKey("pkcs8", unbase64(raw), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const body = `${encode({ alg: "ES256", typ: "JWT", ...header })}.${encode(claims)}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(body));
  return `${body}.${base64url(signature)}`;
}

// Chinese for people whose Telegram is in Chinese, English for everyone else.
export const zh = (from: any) => String(from?.language_code ?? "").toLowerCase().startsWith("zh");
export const say = (from: any, english: string, chinese: string) => (zh(from) ? chinese : english);

export const list = (value: string | undefined) => (value ?? "").split(",").map((item) => item.trim()).filter(Boolean);

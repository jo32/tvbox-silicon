// Sign in with Apple: the app's identity token is checked against Apple's public keys. With a Sign in with Apple key
// (APPLE_KEY_ID + APPLE_PRIVATE_KEY) the authorization code also becomes a refresh token, which account deletion revokes,
// as App Review asks (guideline 5.1.1(v)).

import { Env, jwtES256, list, now, unbase64 } from "./util";

const ISSUER = "https://appleid.apple.com";
const api = (env: Env) => env.APPLE_API ?? ISSUER;

let keys: { at: number; keys: any[] } | null = null;

async function appleKeys(env: Env, refresh = false) {
  if (!refresh && keys && Date.now() - keys.at < 3600_000) return keys.keys;
  const response = await fetch(`${api(env)}/auth/keys`);
  if (!response.ok) throw new Error(`Apple keys: HTTP ${response.status}`);
  const body: any = await response.json();
  keys = { at: Date.now(), keys: Array.isArray(body?.keys) ? body.keys : [] };
  return keys.keys;
}

const decode = (part: string) => JSON.parse(new TextDecoder().decode(unbase64(part)));

export interface AppleClaims {
  sub: string;
  aud: string;
  email?: string;
  is_private_email?: boolean | string;
}

// The token's claims when Apple signed it for one of our apps and it hasn't expired; null otherwise.
export async function verify(env: Env, token: string): Promise<AppleClaims | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  let header: any, claims: any;
  try {
    header = decode(parts[0]);
    claims = decode(parts[1]);
  } catch {
    return null;
  }
  if (header?.alg !== "RS256" || typeof header.kid !== "string") return null;
  let jwk = (await appleKeys(env)).find((key) => key.kid === header.kid);
  if (!jwk) jwk = (await appleKeys(env, true)).find((key) => key.kid === header.kid); // Apple rotated its keys
  if (!jwk) return null;
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, unbase64(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!valid) return null;
  const audiences = list(env.APPLE_AUDIENCES);
  if (claims?.iss !== ISSUER || !audiences.includes(claims.aud) || typeof claims.sub !== "string" || !claims.sub) return null;
  if (typeof claims.exp !== "number" || claims.exp < now() - 60) return null;
  return claims;
}

const configured = (env: Env) => Boolean(env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY && env.APPLE_TEAM_ID);

// The client secret Apple's token endpoints take: a short-lived ES256 JWT signed with the Sign in with Apple key.
async function clientSecret(env: Env, client: string) {
  const time = now();
  return jwtES256(env.APPLE_PRIVATE_KEY!, { kid: env.APPLE_KEY_ID }, { iss: env.APPLE_TEAM_ID, iat: time, exp: time + 300, aud: ISSUER, sub: client });
}

// The refresh token for an authorization code, so it can be revoked later. Null without a key or when Apple refuses.
export async function exchange(env: Env, code: string, client: string): Promise<string | null> {
  if (!configured(env) || !code) return null;
  const form = new URLSearchParams({ client_id: client, client_secret: await clientSecret(env, client), code, grant_type: "authorization_code" });
  const response = await fetch(`${api(env)}/auth/token`, { method: "POST", body: form });
  if (!response.ok) return null;
  const body: any = await response.json();
  return typeof body?.refresh_token === "string" ? body.refresh_token : null;
}

export async function revoke(env: Env, refresh: string, client: string) {
  if (!configured(env)) return;
  const form = new URLSearchParams({ client_id: client, client_secret: await clientSecret(env, client), token: refresh, token_type_hint: "refresh_token" });
  await fetch(`${api(env)}/auth/revoke`, { method: "POST", body: form }).catch(() => undefined);
}

// The Apple Music API's developer token: a JWT signed with the team's MusicKit private key (ES256). The key stays in
// this Worker's secrets, as TMDB's token does in yingxia-tmdb; the app never holds it.

const encoder = new TextEncoder();
const base64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const json64 = (value: unknown) => base64url(encoder.encode(JSON.stringify(value)));

/// The DER bytes of a PEM private key (`-----BEGIN PRIVATE KEY-----`, as Apple's AuthKey_XXXX.p8 is).
export function pemBytes(pem: string): Uint8Array {
  const body = pem.replace(/-----(BEGIN|END) [A-Z ]+-----/g, "").replace(/\s+/g, "");
  if (!body) throw new Error("empty key");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

/// Tokens last 30 days (Apple allows six months); a new one is made a day before the old one runs out.
export const LIFETIME = 30 * 86400;

export async function developerToken(pem: string, keyID: string, teamID: string, now = Math.floor(Date.now() / 1000)): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const unsigned = `${json64({ alg: "ES256", kid: keyID })}.${json64({ iss: teamID, iat: now, exp: now + LIFETIME })}`;
  // Web Crypto's ECDSA signature is already r||s, the form JWS wants.
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(unsigned)));
  return `${unsigned}.${base64url(signature)}`;
}

let kept: { token: string; expires: number; keyID: string } | null = null;

/// The token for this isolate, made again when it nears its end or the key changed.
export async function currentToken(pem: string, keyID: string, teamID: string, now = Math.floor(Date.now() / 1000)): Promise<string> {
  if (kept && kept.keyID === keyID && kept.expires - now > 86400) return kept.token;
  const token = await developerToken(pem, keyID, teamID, now);
  kept = { token, expires: now + LIFETIME, keyID };
  return token;
}

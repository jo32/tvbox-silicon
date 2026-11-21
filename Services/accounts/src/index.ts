// Yingxia accounts: sign in with Apple or Telegram, feedback that counts (sent and adopted), and Pro through redeem
// codes made by the admin pages. The app's side is Sources/TVCore/Account.swift and App/AccountView.swift.
// Deploy: ../../website/node_modules/.bin/wrangler deploy (from this folder). Setup and the admin API: README.md.

import { admin, cors } from "./admin";
import { exchange, revoke, verify } from "./apple";
import { copyInstall, copyNew, stats, syncStatuses, syncUnknown } from "./feedback";
import { cleanInstallDays, markDay, points } from "./points";
import { entitlement, isPro, redeem } from "./pro";
import { pullRequestsOf, syncPullRequests } from "./prs";
import { addIdentity, authenticate, bearer, display, erase, identities, session, User, userFor } from "./session";
import { cleanLogins, loginResult, startLogin, telegramFeedback, webhook } from "./telegram";
import { address, Env, error, isInstall, json, LIFETIME, now, parse, PLATFORMS, sha256, text } from "./util";

// What the app shows on Settings › Account, and keeps (the entitlement) to know it is Pro offline.
async function account(env: Env, given: User) {
  // Read again: copying feedback may just have given a reward.
  const user = (await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(given.id).first<User>()) ?? given;
  return {
    id: user.id,
    name: user.name,
    identities: await identities(env, user),
    pro: { active: isPro(user), until: user.pro_until ?? null, lifetime: (user.pro_until ?? 0) >= LIFETIME },
    entitlement: await entitlement(env, user),
    feedback: await stats(env, user),
    points: await points(env, user.id),
    pullRequests: await pullRequestsOf(env, user.id),
    telegramBot: env.TELEGRAM_BOT,
  };
}

// After a sign-in: what the install sent before, and what GitHub says of it. Best effort: it must never cost the
// sign-in itself (a Telegram code is already used up by then).
async function afterSignIn(env: Env, user: User, install: string) {
  try {
    if (install) await copyInstall(env, user, install);
    await syncUnknown(env, 10, user.id);
  } catch (problem) {
    console.error(`after sign-in: ${problem}`);
  }
}

const installOf = (body: any) => {
  const install = text(body?.install, 36);
  return isInstall(install) ? install.toUpperCase() : "";
};
const platformOf = (body: any) => {
  const platform = text(body?.platform, 8);
  return PLATFORMS.has(platform) ? platform : "";
};

async function limited(request: Request, env: Env) {
  return !(await env.LIMITER.limit({ key: address(request) })).success;
}

// The app signed in with Apple: the identity token says who; the name only comes the first time someone signs in.
async function appleSignIn(request: Request, env: Env): Promise<Response> {
  if (await limited(request, env)) return error(429, "too_many");
  const body = await parse(request);
  if (body instanceof Response) return body;
  const claims = await verify(env, text(body?.identityToken, 8192));
  if (!claims) return error(401, "bad_token");
  const refresh = await exchange(env, text(body?.authorizationCode, 1024), claims.aud);
  const label = typeof claims.email === "string" ? display(claims.email) : "Apple";
  const identity = { provider: "apple" as const, subject: claims.sub, label, name: display(body?.name), refresh, client: claims.aud };
  const install = installOf(body);
  const platform = platformOf(body);

  // Already signed in (with Telegram): Apple joins that account.
  if (bearer(request)) {
    const signedIn = await authenticate(request, env);
    if (signedIn instanceof Response) return signedIn;
    if (!(await addIdentity(env, signedIn.user, identity))) return error(409, "identity_taken");
    return json({ account: await account(env, signedIn.user) });
  }
  const user = await userFor(env, identity);
  const token = await session(env, user, install, platform);
  await afterSignIn(env, user, install);
  return json({ token, account: await account(env, user) });
}

async function telegramStart(request: Request, env: Env): Promise<Response> {
  if (!env.TELEGRAM_WEBHOOK_SECRET || !env.TELEGRAM_BOT) return error(503, "no_telegram");
  if (await limited(request, env)) return error(429, "too_many");
  const body = await parse(request);
  if (body instanceof Response) return body;
  let linkUser: string | null = null;
  if (bearer(request)) {
    const signedIn = await authenticate(request, env);
    if (signedIn instanceof Response) return signedIn;
    linkUser = signedIn.user.id;
  }
  return json(await startLogin(env, installOf(body), platformOf(body), linkUser));
}

// Asked every few seconds while the app shows the Telegram link: 202 until the bot has seen it.
async function telegramPoll(request: Request, env: Env): Promise<Response> {
  const body = await parse(request);
  if (body instanceof Response) return body;
  const code = text(body?.code, 64);
  if (!/^[A-Za-z0-9_-]{16,64}$/.test(code)) return error(400, "bad_code");
  const result = await loginResult(env, code);
  if (result === "pending") return json({ status: "pending" }, 202);
  if (result === "expired") return error(410, "expired");
  // A login that added Telegram to an account already signed in keeps that session.
  if (bearer(request)) {
    const signedIn = await authenticate(request, env);
    if (!(signedIn instanceof Response) && signedIn.user.id === result.user.id) return json({ account: await account(env, result.user) });
  }
  const token = await session(env, result.user, result.install, result.platform);
  await afterSignIn(env, result.user, result.install);
  return json({ token, account: await account(env, result.user) });
}

async function me(request: Request, env: Env): Promise<Response> {
  const signedIn = await authenticate(request, env);
  if (signedIn instanceof Response) return signedIn;
  if (request.method === "DELETE") {
    // Apple's tokens are revoked first, as App Review asks; then everything about the person goes.
    const apple = await env.DB.prepare("SELECT refresh, client FROM identities WHERE user_id = ? AND provider = 'apple' AND refresh IS NOT NULL")
      .bind(signedIn.user.id).all<{ refresh: string; client: string }>();
    for (const row of apple.results) await revoke(env, row.refresh, row.client);
    await erase(env, signedIn.user.id);
    return json({ deleted: true });
  }
  await syncUnknown(env, 5, signedIn.user.id).catch((problem) => console.error(`sync: ${problem}`));
  return json(await account(env, signedIn.user));
}

// The app is open (once a day while signed in): today's point for the session's install, then the account.
async function activeDay(request: Request, env: Env): Promise<Response> {
  const signedIn = await authenticate(request, env);
  if (signedIn instanceof Response) return signedIn;
  const row = await env.DB.prepare("SELECT install FROM sessions WHERE hash = ?").bind(signedIn.hash).first<{ install: string }>();
  const counted = await markDay(env, signedIn.user.id, row?.install ?? "");
  return json({ counted, account: await account(env, signedIn.user) });
}

async function redeemCode(request: Request, env: Env): Promise<Response> {
  const signedIn = await authenticate(request, env);
  if (signedIn instanceof Response) return signedIn;
  if (!(await env.REDEEM_LIMITER.limit({ key: signedIn.user.id })).success) return error(429, "too_many");
  const body = await parse(request);
  if (body instanceof Response) return body;
  const result = await redeem(env, signedIn.user, text(body?.code, 80), "app");
  if (typeof result === "string") return error(result === "not_found" || result === "invalid" ? 404 : 409, result);
  return json({ days: result.days, account: await account(env, signedIn.user) });
}

async function signOut(request: Request, env: Env): Promise<Response> {
  const token = bearer(request);
  if (token) await env.DB.prepare("DELETE FROM sessions WHERE hash = ?").bind(await sha256(token)).run();
  return json({ signedOut: true });
}

const health = async (_request: Request, env: Env) =>
  json({
    ok: true,
    apple: env.APPLE_AUDIENCES.split(",").length,
    appleRevoke: Boolean(env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY),
    telegram: Boolean(env.TELEGRAM_BOT && env.TELEGRAM_WEBHOOK_SECRET),
    entitlement: Boolean(env.ENTITLEMENT_KEY),
    github: Boolean(env.GITHUB_TOKEN),
    admin: Boolean(env.ADMIN_TOKEN),
  });

const ROUTES: Record<string, Record<string, (request: Request, env: Env) => Promise<Response>>> = {
  "/v1/health": { GET: health },
  "/v1/auth/apple": { POST: appleSignIn },
  "/v1/auth/telegram": { POST: telegramStart },
  "/v1/auth/telegram/poll": { POST: telegramPoll },
  "/v1/me": { GET: me, DELETE: me },
  "/v1/me/redeem": { POST: redeemCode },
  "/v1/me/day": { POST: activeDay },
  "/v1/sign-out": { POST: signOut },
  "/v1/telegram/webhook": { POST: webhook },
  "/v1/telegram/feedback": { POST: telegramFeedback },
};

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path.startsWith("/v1/admin/")) {
      const headers = cors(request, env);
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
      const response = await admin(request, env, path);
      const out = new Response(response.body, response);
      for (const [name, value] of Object.entries(headers)) out.headers.set(name, value);
      return out;
    }
    const route = ROUTES[path];
    if (!route) return error(404, "not_found");
    const handle = route[request.method];
    if (!handle) return new Response(null, { status: 405, headers: { allow: Object.keys(route).join(", ") } });
    return handle(request, env);
  },
  // Every 15 minutes: copy new feedback of signed-in installs, read what GitHub says about it and about merged pull
  // requests, drop stale sign-ins.
  async scheduled(_controller, env) {
    await copyNew(env);
    await syncStatuses(env);
    await syncPullRequests(env);
    await cleanInstallDays(env);
    await cleanLogins(env);
    await env.DB.prepare("DELETE FROM sessions WHERE expires < ?").bind(now()).run();
  },
} satisfies ExportedHandler<Env>;

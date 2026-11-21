// End-to-end test of the accounts Worker on `wrangler dev`, with stand-ins for Apple, Telegram and GitHub.
// Run: test/run.sh (from Services/accounts). Needs Node 20+.

import { createServer } from "node:http";
import { generateKeyPairSync, createSign, createPublicKey, verify as verifySignature } from "node:crypto";
import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";

const WRANGLER = process.env.WRANGLER;
const PORT = 8790, APPLE = 8791, TELEGRAM = 8792, GITHUB = 8793;
const BASE = `http://127.0.0.1:${PORT}`;
const STATE = "test/.state";
let failures = 0;
const check = (ok, what, extra) => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok || extra === undefined ? "" : " — " + JSON.stringify(extra)}`);
  if (!ok) failures++;
};

// Apple: an RSA key for identity tokens, and a P-256 key standing in for the Sign in with Apple key.
const apple = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...apple.publicKey.export({ format: "jwk" }), kid: "test-kid", alg: "RS256", use: "sig" };
const signIn = generateKeyPairSync("ec", { namedCurve: "P-256" });
const b64 = (value) => Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");
function identityToken(claims) {
  const body = `${b64({ alg: "RS256", kid: "test-kid" })}.${b64({ iss: "https://appleid.apple.com", aud: "com.jo32.yingxia.ios", exp: Math.floor(Date.now() / 1000) + 600, ...claims })}`;
  return `${body}.${createSign("RSA-SHA256").update(body).sign(apple.privateKey).toString("base64url")}`;
}
const revoked = [];
// Entitlement key: the Worker signs with the private half, the test checks with the public half as the app does.
const entitlement = generateKeyPairSync("ed25519");

const telegramSent = [];
const issues = new Map([
  [101, { number: 101, title: "Crash when searching", state: "closed", state_reason: "completed", labels: [{ name: "feedback" }, { name: "fixed" }], updated_at: "2026-11-01T00:00:00Z" }],
  [102, { number: 102, title: "Same as 101", state: "closed", state_reason: "not_planned", labels: [{ name: "feedback" }, { name: "duplicate" }], updated_at: "2026-11-01T00:00:00Z" }],
  [103, { number: 103, title: "Add sleep timer", state: "open", state_reason: null, labels: [{ name: "feedback" }], updated_at: "2026-11-01T00:00:00Z" }],
]);

// Pull requests the GitHub stand-in lists (filled in once the test knows the account IDs).
const pulls = [];

const read = (request) => new Promise((resolve) => { let data = ""; request.on("data", (chunk) => (data += chunk)); request.on("end", () => resolve(data)); });
const servers = [
  createServer(async (request, response) => {
    const body = await read(request);
    if (request.url === "/auth/keys") return response.end(JSON.stringify({ keys: [jwk] }));
    if (request.url === "/auth/token") return response.end(JSON.stringify({ refresh_token: "apple-refresh-1", access_token: "x" }));
    if (request.url === "/auth/revoke") { revoked.push(new URLSearchParams(body).get("token")); return response.end(""); }
    response.statusCode = 404; response.end();
  }).listen(APPLE),
  createServer(async (request, response) => {
    const body = JSON.parse((await read(request)) || "{}");
    telegramSent.push({ method: request.url.split("/").pop(), body });
    response.end(JSON.stringify({ ok: true, result: true }));
  }).listen(TELEGRAM),
  createServer(async (request, response) => {
    const url = new URL(request.url, "http://x");
    const single = /\/issues\/(\d+)$/.exec(url.pathname);
    if (single) {
      // 299: GitHub answering without the issue; nothing may break on it.
      if (single[1] === "299") return response.end("{}");
      const issue = issues.get(Number(single[1]));
      if (!issue) { response.statusCode = 404; return response.end("{}"); }
      return response.end(JSON.stringify(issue));
    }
    if (url.pathname.endsWith("/issues")) return response.end(JSON.stringify([...issues.values()]));
    if (url.pathname.endsWith("/pulls")) return response.end(JSON.stringify(pulls));
    response.statusCode = 404; response.end();
  }).listen(GITHUB),
];

rmSync(STATE, { recursive: true, force: true });
mkdirSync(STATE, { recursive: true });
const p8 = signIn.privateKey.export({ format: "pem", type: "pkcs8" });
writeFileSync(".dev.vars", [
  `APPLE_API=http://127.0.0.1:${APPLE}`,
  `TELEGRAM_API=http://127.0.0.1:${TELEGRAM}`,
  `GITHUB_API=http://127.0.0.1:${GITHUB}`,
  `ADMIN_TOKEN=admin-secret`,
  `TELEGRAM_WEBHOOK_SECRET=hook-secret`,
  `TELEGRAM_BOT=YingxiaTestBot`,
  `GITHUB_TOKEN=gh-test`,
  `APPLE_KEY_ID=KEY123`,
  `APPLE_PRIVATE_KEY=${p8.replace(/\n/g, "")}`,
  `ENTITLEMENT_KEY=${entitlement.privateKey.export({ format: "der", type: "pkcs8" }).toString("base64")}`,
  `REWARD_DAYS=7`,
  `ADMIN_ORIGINS=https://admin.example`,
].join("\n") + "\n");

const d1 = (database, args) => execFileSync(WRANGLER, ["d1", "execute", database, "--local", "--persist-to", STATE, ...args], { stdio: "pipe" });
d1("yingxia-accounts", ["--file", "schema.sql"]);
d1("yingxia-reports", ["--file", "../error-reports/schema.sql"]);

const INSTALL = "11111111-2222-3333-4444-555555555555";
const OTHER = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
const t = Math.floor(Date.now() / 1000);
// Sent before signing in: 101 and 102 by this install, 103 by another.
d1("yingxia-reports", ["--command", `INSERT INTO feedback (received, install, platform, app, issue) VALUES (${t - 3600}, '${INSTALL}', 'ios', '1.8', 101), (${t - 1800}, '${INSTALL}', 'ios', '1.8', 102), (${t - 900}, '${OTHER}', 'tvos', '1.8', 103)`]);

const dev = spawn(WRANGLER, ["dev", "--local", "--port", String(PORT), "--ip", "127.0.0.1", "--persist-to", STATE, "--test-scheduled"], { stdio: ["ignore", "pipe", "pipe"] });
let devLog = "";
dev.stdout.on("data", (chunk) => (devLog += chunk));
dev.stderr.on("data", (chunk) => (devLog += chunk));
for (let i = 0; i < 60; i++) {
  try { if ((await fetch(`${BASE}/v1/health`)).ok) break; } catch {}
  await new Promise((resolve) => setTimeout(resolve, 500));
}

async function call(method, path, body, token, headers = {}) {
  const response = await fetch(BASE + path, {
    method,
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch {}
  return { status: response.status, json, headers: response.headers };
}
const admin = (method, path, body) => call(method, path, body, "admin-secret");
// The bot's Worker (yx-tg) passing on an update; it sends the {text} we answer.
let botSaid = "";
const hook = async (text, from = { id: 777, first_name: "Tele", username: "tele_user", language_code: "en" }, secret = "hook-secret") => {
  const response = await call("POST", "/v1/telegram/webhook", { update_id: 1, message: { message_id: 1, from, chat: { id: from.id, type: "private" }, text } }, null, { "x-telegram-bot-api-secret-token": secret });
  botSaid = response.json?.text ?? "";
  return response;
};
const lastTelegram = () => botSaid;
// The bot's Worker telling about a /feedback from the Telegram group that became `issue`.
const tgFeedback = (from, issue, secret = "hook-secret") =>
  call("POST", "/v1/telegram/feedback", { from, issue, sent: Math.floor(Date.now() / 1000) }, null, { "x-telegram-bot-api-secret-token": secret });

try {
  const health = await call("GET", "/v1/health");
  check(health.status === 200 && health.json.entitlement && health.json.telegram && health.json.appleRevoke, "health shows everything configured", health.json);

  // Sign in with Apple.
  check((await call("POST", "/v1/auth/apple", { identityToken: "a.b.c", install: INSTALL, platform: "ios" })).status === 401, "a forged Apple token is refused");
  const wrongAudience = identityToken({ sub: "apple-1", aud: "com.example.other" });
  check((await call("POST", "/v1/auth/apple", { identityToken: wrongAudience })).status === 401, "another app's Apple token is refused");
  const expired = identityToken({ sub: "apple-1", exp: t - 3600 });
  check((await call("POST", "/v1/auth/apple", { identityToken: expired })).status === 401, "an expired Apple token is refused");
  const apple1 = await call("POST", "/v1/auth/apple", { identityToken: identityToken({ sub: "apple-1", email: "a@privaterelay.appleid.com" }), authorizationCode: "code-1", install: INSTALL, platform: "ios", name: "Ann" });
  check(apple1.status === 200 && apple1.json.token?.startsWith("yxs_"), "Sign in with Apple gives a session", apple1.json);
  const token = apple1.json.token;
  const account = apple1.json.account;
  check(account.name === "Ann" && account.identities[0].provider === "apple" && account.identities[0].label === "a@privaterelay.appleid.com", "the account has the name and Apple identity", account);
  check(account.feedback.sent === 2 && account.feedback.fixed === 1 && account.feedback.adopted === 0 && account.feedback.declined === 1, "feedback sent before signing in counts (2 sent, 1 fixed, 1 duplicate)", account.feedback);
  // 101 (fixed) earns its sent point and 50; 102, a duplicate, earns nothing.
  check(account.points.sent === 1 && account.points.fixed === 1 && account.points.adopted === 0 && account.points.total === 1 + 50 && account.feedback.points === 51,
    "points: +1 a message (not duplicates), +50 a fixed bug", account.points);
  check(account.points.rules.daily === 1 && account.points.rules.fixed === 50 && account.points.rules.adopted === 100 && account.points.rules.sentPerDay === 3 && account.points.rules.pullRequest === 500, "the rules come with the account", account.points.rules);
  check(account.pro.active === true && account.pro.until > t + 6 * 86400, "REWARD_DAYS=7 gave Pro for the adopted issue", account.pro);
  const again = await call("POST", "/v1/auth/apple", { identityToken: identityToken({ sub: "apple-1" }), install: INSTALL, platform: "ios" });
  check(again.json.account.id === account.id && again.json.account.name === "Ann", "signing in again reaches the same account and keeps the name");
  check(again.json.account.pro.until === account.pro.until, "the reward is given once per issue", [again.json.account.pro.until, account.pro.until]);

  // The entitlement verifies with the public key, as the app checks it.
  const ent = account.entitlement;
  const okSignature = verifySignature(null, Buffer.from(ent.payload, "base64url"), entitlement.publicKey, Buffer.from(ent.signature, "base64url"));
  const payload = JSON.parse(Buffer.from(ent.payload, "base64url").toString());
  check(okSignature && payload.user === account.id && payload.until === account.pro.until, "the entitlement is signed and names the person and end", payload);
  const raw = entitlement.publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
  console.log(`     (test public key ${raw})`);

  const me = await call("GET", "/v1/me", undefined, token);
  check(me.status === 200 && me.json.id === account.id, "GET /v1/me with the session");
  check((await call("GET", "/v1/me", undefined, "yxs_wrong")).status === 401, "a wrong session is refused");

  // Codes from the admin pages.
  check((await call("POST", "/v1/admin/codes", { count: 1 }, "wrong")).status === 401, "admin API refuses a wrong token");
  const made = await admin("POST", "/v1/admin/codes", { count: 3, days: 30, batch: "launch", note: "test batch" });
  check(made.status === 201 && made.json.codes.length === 3 && /^[0-9A-Z]{4}(-[0-9A-Z]{4}){3}$/.test(made.json.codes[0].code), "admin makes 3 codes", made.json);
  const [code1, code2, code3] = made.json.codes.map((item) => item.code);
  const custom = await admin("POST", "/v1/admin/codes", { codes: ["SPRING-2026"], days: null, maxUses: 2, batch: "spring" });
  check(custom.status === 201 && custom.json.days === null, "admin adds its own lifetime code with 2 uses", custom.json);
  check((await admin("POST", "/v1/admin/codes", { codes: ["spring 2026"] })).status === 400, "the same code (spelled differently) can't be added twice");
  check((await admin("POST", "/v1/admin/codes", { count: 1, days: -5 })).status === 400, "bad days are refused");

  const before = (await call("GET", "/v1/me", undefined, token)).json.pro.until;
  const r1 = await call("POST", "/v1/me/redeem", { code: code1.toLowerCase().replace(/-/g, " ") }, token);
  check(r1.status === 200 && r1.json.account.pro.until === before + 30 * 86400, "redeeming adds 30 days after the current end (any spelling)", [r1.json, before]);
  check((await call("POST", "/v1/me/redeem", { code: code1 }, token)).json?.error === "already_redeemed", "the same person can't redeem a code twice");
  check((await call("POST", "/v1/me/redeem", { code: "NOPE-NOPE-NOPE" }, token)).json?.error === "not_found", "an unknown code is not found");

  // Telegram: sign in through the bot.
  const start = await call("POST", "/v1/auth/telegram", { install: OTHER, platform: "tvos" });
  check(start.status === 200 && start.json.url === `https://t.me/YingxiaTestBot?start=${start.json.code}`, "Telegram sign-in gives a t.me link", start.json);
  check((await call("POST", "/v1/auth/telegram/poll", { code: start.json.code })).status === 202, "polling waits for the bot");
  check((await hook(`/start ${start.json.code}`, undefined, "wrong")).status === 401, "the webhook refuses a wrong secret");
  check((await hook(`/start ${start.json.code}`)).status === 200 && /signed in/.test(lastTelegram()), "the bot confirms the sign-in", lastTelegram());
  const tg = await call("POST", "/v1/auth/telegram/poll", { code: start.json.code });
  check(tg.status === 200 && tg.json.token && tg.json.account.identities[0].label === "@tele_user", "polling then gives a session for the Telegram account", tg.json);
  // The app's check is often cut off on its way back from Telegram: asking again with the same code still signs in.
  const repeated = await call("POST", "/v1/auth/telegram/poll", { code: start.json.code });
  check(repeated.status === 200 && repeated.json.token && repeated.json.token !== tg.json.token && repeated.json.account.id === tg.json.account.id,
    "a lost answer: the same code signs in again until it expires", repeated.json);
  check(tg.json.account.feedback.sent === 1 && tg.json.account.feedback.issues[0].number === 103, "the TV install's feedback counts for the Telegram account", tg.json.account.feedback);
  const tgToken = tg.json.token;

  check((await call("POST", "/v1/me/redeem", { code: code1 }, tgToken)).json?.error === "used_up", "a one-use code is used up for the next person");
  const life = await call("POST", "/v1/me/redeem", { code: "spring2026" }, tgToken);
  check(life.status === 200 && life.json.account.pro.lifetime === true, "a lifetime code gives lifetime Pro", life.json);
  const lifeAgain = await call("POST", "/v1/me/redeem", { code: code2 }, tgToken);
  check(lifeAgain.json.account.pro.lifetime === true, "days added to lifetime stay lifetime", lifeAgain.json.account.pro);

  // The bot's own commands.
  await hook("/redeem " + code3, { id: 888, first_name: "新", language_code: "zh-hans" });
  check(/兑换成功/.test(lastTelegram()), "redeeming in the bot works (in Chinese for a Chinese Telegram)", lastTelegram());
  await hook("/redeem " + code3, { id: 889, first_name: "Bob", language_code: "en" });
  check(/already been used/.test(lastTelegram()), "the bot says a used code is used", lastTelegram());
  await hook("/me", { id: 888, first_name: "新", language_code: "zh-hans" });
  check(/Pro：有效期至/.test(lastTelegram()), "/me shows Pro in the bot", lastTelegram());
  await hook("hello");
  check(/\/redeem/.test(lastTelegram()), "anything else gets the help text");

  // Adding Telegram to the Apple account.
  const link = await call("POST", "/v1/auth/telegram", { install: INSTALL, platform: "ios" }, token);
  await hook(`/start ${link.json.code}`, { id: 999, first_name: "Ann", username: "ann", language_code: "en" });
  const linked = await call("POST", "/v1/auth/telegram/poll", { code: link.json.code }, token);
  check(linked.status === 200 && !linked.json.token && linked.json.account.identities.length === 2, "a signed-in person can add Telegram to the same account", linked.json);
  const steal = await call("POST", "/v1/auth/telegram", {}, token);
  await hook(`/start ${steal.json.code}`);
  check(/already belongs/.test(lastTelegram()), "a Telegram account of someone else can't be added", lastTelegram());

  // Points for a day of use: once a day per account, and one account per device a day.
  const day1 = await call("POST", "/v1/me/day", undefined, token);
  check(day1.status === 200 && day1.json.counted === true && day1.json.account.points.days === 1, "opening the app counts the day", day1.json);
  const day2 = await call("POST", "/v1/me/day", undefined, token);
  check(day2.json.counted === false && day2.json.account.points.days === 1, "the day counts once", day2.json);
  check((await call("POST", "/v1/me/day")).status === 401, "a day needs a session");
  const sibling = await call("POST", "/v1/auth/apple", { identityToken: identityToken({ sub: "apple-2" }), install: INSTALL, platform: "ios" });
  const day3 = await call("POST", "/v1/me/day", undefined, sibling.json.token);
  check(day3.json.counted === false && day3.json.account.points.days === 0, "another account signed in on the same device doesn't get that day", day3.json);
  await call("POST", "/v1/auth/apple", { identityToken: identityToken({ sub: "apple-1" }), install: INSTALL, platform: "ios" }); // the device is Ann's again

  // /feedback in the Telegram group, passed on by the bot: a point each, 3 a day, each issue once.
  const fan = { id: 4242, first_name: "群友", username: "qun_you", language_code: "zh-hans" };
  check((await tgFeedback(fan, 201, "wrong")).status === 401, "the bot's feedback call needs the secret");
  const said = [];
  for (const issue of [201, 202, 203, 204]) said.push((await tgFeedback(fan, issue)).json?.text ?? "");
  check(said.slice(0, 3).every((text) => /\+1 积分；问题被修复再 \+50，建议被采纳再 \+100/.test(text)) && /已满/.test(said[3]), "group feedback earns a point, 3 a day, and says so", said);
  check((await tgFeedback(fan, 201)).json?.text === null, "the same issue counts once");
  check((await tgFeedback({ ...fan, id: 4343, username: "other" }, 202)).json?.text === null, "and for one person only");
  await tgFeedback({ ...fan, id: 4545, username: "odd" }, 299);
  const odd = await call("POST", "/v1/auth/telegram", { install: OTHER, platform: "ios" });
  await hook(`/start ${odd.json.code}`, { id: 4545, first_name: "Odd", username: "odd", language_code: "en" });
  const oddIn = await call("POST", "/v1/auth/telegram/poll", { code: odd.json.code });
  check(oddIn.status === 200 && oddIn.json.token && oddIn.json.account.feedback.issues[0]?.number === 299,
    "signing in works even when GitHub answers oddly about the person's feedback (and group feedback shows in the app)", oddIn.json);
  for (const [number, extra] of [[201, { labels: [{ name: "feedback" }, { name: "adopted" }] }], [202, { state: "closed", state_reason: "completed" }],
    [203, { labels: [{ name: "feedback" }, { name: "spam" }] }], [204, {}]]) {
    issues.set(number, { number, title: `Group ${number}`, state: "open", labels: [{ name: "feedback" }], updated_at: new Date().toISOString(), ...extra });
  }

  // Merged pull requests, as GitHub lists them.
  const pr = (number, login, id, body, extra = {}) => ({ number, title: `PR ${number}`, user: { login, id, type: "User" }, body, labels: [],
    merged_at: "2026-11-20T00:00:00Z", updated_at: new Date().toISOString(), ...extra });
  pulls.push(
    pr(501, "alice", 11, `Fixes the crash.\n\nYingxia account: ${account.id}`),
    pr(502, "alice", 11, "Another fix, without the account line."),
    pr(503, "bob", 12, "映匣账号：@tele_user"),
    pr(504, "jo32", 1, `Yingxia account: ${account.id}`),
    pr(505, "dependabot[bot]", 2, `Yingxia account: ${account.id}`, { user: { login: "dependabot[bot]", id: 2, type: "Bot" } }),
    pr(506, "carol", 13, `Yingxia account: ${account.id}`, { labels: [{ name: "no-points" }] }),
    pr(507, "dave", 14, `Yingxia account: ${account.id}`, { merged_at: null }),
    pr(508, "erin", 15, "<!-- Yingxia account: your account ID -->\nA fix."),
    pr(509, "frank", 16, "Yingxia account:\ntele_user found this bug."),
  );

  // The 15-minute job: new feedback from a signed-in install, and GitHub adopting it.
  d1("yingxia-reports", ["--command", `INSERT INTO feedback (received, install, platform, app, issue) VALUES (${t + 5}, '${INSTALL}', 'ios', '1.8', 104)`]);
  issues.set(104, { number: 104, title: "Picture in picture", state: "open", labels: [{ name: "feedback" }, { name: "fixed" }], updated_at: new Date().toISOString() });
  const job = await fetch(`${BASE}/__scheduled?cron=*/15+*+*+*+*`);
  check(job.ok, "the scheduled job runs", job.status);
  const after = (await call("GET", "/v1/me", undefined, token)).json;
  check(after.feedback.sent === 3 && after.feedback.fixed === 2 && after.feedback.adopted === 0, "new feedback is copied and its `fixed` label counts as a fixed bug", after.feedback);
  check(after.points.pullRequests === 2 && after.pullRequests.map((item) => item.number).sort().join() === "501,502",
    "a merged pull request counts for the account its description names, and its author's later ones too", after.pullRequests);
  check(after.points.total === after.points.days + after.points.sent + 2 * 50 + 2 * 500, "the total adds up", after.points);
  const tgAfter = (await call("GET", "/v1/me", undefined, tgToken)).json;
  check(tgAfter.points.pullRequests === 1, "a pull request naming a Telegram @username counts for that account", tgAfter.points);
  await hook("/me", fan);
  check(/建议被采纳 1 条：\+100/.test(lastTelegram()) && /反馈 3 条：\+3/.test(lastTelegram()) && /积分规则/.test(lastTelegram()),
    "adopted only by label (closed isn't enough), spam loses its point, and /me explains the rules", lastTelegram());

  // Admin pages.
  const codes = await admin("GET", "/v1/admin/codes?batch=launch");
  check(codes.json.codes.length === 3 && codes.json.codes.every((item) => item.used === 1), "admin lists the batch with uses", codes.json);
  const detail = await admin("GET", `/v1/admin/codes/${made.json.codes[0].id}`);
  check(detail.json.redemptions.length === 1 && detail.json.redemptions[0].user === account.id, "admin sees who redeemed a code", detail.json);
  const extra = await admin("POST", "/v1/admin/codes", { count: 2, days: 7, batch: "promo" });
  check((await admin("POST", "/v1/admin/codes/revoke", { batch: "promo" })).json.revoked === 2, "admin revokes a batch");
  check((await call("POST", "/v1/me/redeem", { code: extra.json.codes[0].code }, token)).json?.error === "revoked", "a revoked code can't be redeemed");
  const expiring = await admin("POST", "/v1/admin/codes", { count: 1, days: 7, expires: t - 10 });
  check((await call("POST", "/v1/me/redeem", { code: expiring.json.codes[0].code }, token)).json?.error === "expired", "an expired code can't be redeemed");
  const users = await admin("GET", "/v1/admin/users?q=tele_user");
  check(users.json.users.length === 1 && users.json.users[0].sent === 1, "admin finds a person by Telegram username", users.json);
  const byInstall = await admin("GET", `/v1/admin/users?q=${INSTALL.toLowerCase()}`);
  check(byInstall.json.users[0]?.id === account.id, "admin finds a person by install ID");
  const manual = await admin("POST", `/v1/admin/users/${tg.json.account.id}/pro`, { until: 0, note: "ended by hand" });
  check(manual.json.proUntil === null, "admin can end someone's Pro", manual.json.proUntil);
  const given = await admin("POST", `/v1/admin/users/${tg.json.account.id}/pro`, { days: 10, note: "gift" });
  check(given.json.proUntil > t + 9 * 86400 && given.json.grants.some((item) => item.kind === "admin"), "admin can give Pro days", given.json);
  const unmatched = await admin("GET", "/v1/admin/pull-requests?unmatched=1");
  check(unmatched.json.pullRequests.map((item) => item.number).sort().join() === "508,509", "admin sees merged pull requests nobody matched (a claim in a comment, or an empty claim line, doesn't count)", unmatched.json);
  const listed = (await admin("GET", "/v1/admin/pull-requests")).json.pullRequests;
  check(listed.some((item) => item.number === 506 && item.excluded === 1) && !listed.some((item) => [504, 505, 507].includes(item.number)),
    "the owner's, bots' and unmerged pull requests never count; no-points is kept but excluded", listed);
  const handed = await admin("POST", "/v1/admin/pull-requests/508", { user: tg.json.account.id });
  check(handed.json.user === tg.json.account.id && handed.json.how === "admin", "admin gives a pull request to an account", handed.json);
  const adjusted = await admin("POST", `/v1/admin/users/${tg.json.account.id}/points`, { points: -50, note: "test" });
  check(adjusted.json.points.pullRequests === 2 && adjusted.json.points.adjusted === -50 && adjusted.json.adjustments.length === 1, "admin adds or takes away points", adjusted.json.points);
  check((await admin("POST", `/v1/admin/users/${tg.json.account.id}/points`, { points: 0 })).status === 400, "zero points is refused");
  const stats = await admin("GET", "/v1/admin/stats");
  check(stats.json.users >= 3 && stats.json.adopted === 3 && stats.json.pullRequests === 4 && stats.json.pullRequestsUnmatched === 1 && stats.json.activeToday === 1, "admin stats", stats.json);
  const preflight = await fetch(`${BASE}/v1/admin/codes`, { method: "OPTIONS", headers: { origin: "https://admin.example" } });
  check(preflight.status === 204 && preflight.headers.get("access-control-allow-origin") === "https://admin.example", "CORS lets the admin pages call");
  const foreign = await fetch(`${BASE}/v1/admin/codes`, { method: "OPTIONS", headers: { origin: "https://evil.example" } });
  check(!foreign.headers.get("access-control-allow-origin"), "CORS refuses other origins");
  check(telegramSent.length === 0, "the accounts Worker never calls Telegram itself (the bot's Worker sends)", telegramSent);

  // Signing out and deleting the account.
  const second = (await call("POST", "/v1/auth/apple", { identityToken: identityToken({ sub: "apple-1" }), install: INSTALL, platform: "ios" })).json.token;
  check((await call("POST", "/v1/sign-out", undefined, second)).status === 200 && (await call("GET", "/v1/me", undefined, second)).status === 401, "sign-out ends that session only");
  check((await call("GET", "/v1/me", undefined, token)).status === 200, "the other session still works");
  const gone = await call("DELETE", "/v1/me", undefined, token);
  check(gone.status === 200 && revoked.includes("apple-refresh-1"), "deleting the account revokes Apple's token", revoked);
  check((await call("GET", "/v1/me", undefined, token)).status === 401, "and the session is gone");
  const orphan = (await admin("GET", "/v1/admin/pull-requests")).json.pullRequests.find((item) => item.number === 501);
  check(orphan && orphan.user === null, "a deleted account's pull requests no longer count for anyone", orphan);
  const fresh = await call("POST", "/v1/auth/apple", { identityToken: identityToken({ sub: "apple-1" }), install: INSTALL, platform: "ios" });
  check(fresh.json.account.id !== account.id && fresh.json.account.pro.active === false, "signing in after deletion starts a new account", fresh.json.account);
} catch (problem) {
  failures++;
  console.log("FAIL", problem);
  console.log(devLog.slice(-4000));
} finally {
  dev.kill();
  servers.forEach((server) => server.close());
  rmSync(".dev.vars", { force: true });
}
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);

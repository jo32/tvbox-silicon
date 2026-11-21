// A local accounts server for app QA: wrangler dev on 127.0.0.1:8790 with stand-ins for Apple, Telegram and GitHub,
// a signed-in person with some feedback, and two codes. Prints the session token and the codes, then keeps running.
//   WRANGLER=… node test/serve.mjs
// App: -qaAccounts http://127.0.0.1:8790 -qaAccountToken <token> -qaSection Settings -qaPage account
// Finish a Telegram sign-in the app started: curl -X POST 127.0.0.1:8790/v1/telegram/webhook -H 'x-telegram-bot-api-secret-token: hook-secret'
//   -H 'content-type: application/json' -d '{"message":{"from":{"id":5,"first_name":"QA"},"chat":{"id":5,"type":"private"},"text":"/start <code>"}}'
// (the code is in the app's QR link; GET 127.0.0.1:8799/logins lists the open ones).

import { createServer } from "node:http";
import { generateKeyPairSync, createSign } from "node:crypto";
import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";

const WRANGLER = process.env.WRANGLER;
const PORT = 8790, APPLE = 8791, TELEGRAM = 8792, GITHUB = 8793;
const BASE = `http://127.0.0.1:${PORT}`;
const STATE = "test/.qa-state";

const apple = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...apple.publicKey.export({ format: "jwk" }), kid: "qa", alg: "RS256", use: "sig" };
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const body = `${b64({ alg: "RS256", kid: "qa" })}.${b64({ iss: "https://appleid.apple.com", aud: "com.jo32.yingxia.ios", sub: "qa-person", email: "qa@privaterelay.appleid.com", exp: Math.floor(Date.now() / 1000) + 600 })}`;
const identityToken = `${body}.${createSign("RSA-SHA256").update(body).sign(apple.privateKey).toString("base64url")}`;
const issues = [
  { number: 1301, title: "Sleep timer for music", state: "closed", state_reason: "completed", labels: [{ name: "feedback" }, { name: "fixed" }], updated_at: "2026-11-10T00:00:00Z" },
  { number: 1302, title: "Subtitles drift after seeking", state: "closed", state_reason: "completed", labels: [{ name: "feedback" }], updated_at: "2026-11-12T00:00:00Z" },
  { number: 1303, title: "Same as the subtitle bug", state: "closed", state_reason: "not_planned", labels: [{ name: "feedback" }, { name: "duplicate" }], updated_at: "2026-11-12T00:00:00Z" },
  { number: 1304, title: "Remember the last source", state: "open", labels: [{ name: "feedback" }], updated_at: "2026-11-15T00:00:00Z" },
];
const read = (request) => new Promise((resolve) => { let data = ""; request.on("data", (chunk) => (data += chunk)); request.on("end", () => resolve(data)); });
// Apple's real keys too, so a real Sign in with Apple on a simulator or device also works against this server.
const appleKeys = await fetch("https://appleid.apple.com/auth/keys").then((response) => response.json()).then((body) => body.keys).catch(() => []);
createServer((request, response) => response.end(JSON.stringify({ keys: [jwk, ...appleKeys] }))).listen(APPLE);
createServer(async (request, response) => { await read(request); response.end('{"ok":true,"result":true}'); }).listen(TELEGRAM);
createServer((request, response) => {
  const single = /\/issues\/(\d+)$/.exec(request.url.split("?")[0]);
  if (single) return response.end(JSON.stringify(issues.find((issue) => issue.number === Number(single[1])) ?? {}));
  response.end(JSON.stringify(issues));
}).listen(GITHUB);

rmSync(STATE, { recursive: true, force: true });
mkdirSync(STATE, { recursive: true });
const entitlement = execFileSync("cat", [`${process.env.HOME}/.config/yingxia/accounts-entitlement.key`]).toString().trim();
writeFileSync(".dev.vars", [
  `APPLE_API=http://127.0.0.1:${APPLE}`, `TELEGRAM_API=http://127.0.0.1:${TELEGRAM}`, `GITHUB_API=http://127.0.0.1:${GITHUB}`,
  "ADMIN_TOKEN=admin-secret", "TELEGRAM_WEBHOOK_SECRET=hook-secret", "TELEGRAM_BOT=yingxia_sup_bot",
  `ENTITLEMENT_KEY=${entitlement}`, "REWARD_DAYS=0",
].join("\n") + "\n");
const d1 = (database, args) => execFileSync(WRANGLER, ["d1", "execute", database, "--local", "--persist-to", STATE, ...args], { stdio: "pipe" });
d1("yingxia-accounts", ["--file", "schema.sql"]);
d1("yingxia-reports", ["--file", "../error-reports/schema.sql"]);
const INSTALL = "0A0A0A0A-1111-2222-3333-444444444444";
const t = Math.floor(Date.now() / 1000);
d1("yingxia-reports", ["--command", `INSERT INTO feedback (received, install, platform, app, issue) VALUES ${issues.map((issue, index) => `(${t - 86400 * (4 - index)}, '${INSTALL}', 'ios', '1.8', ${issue.number})`).join(", ")}`]);

const dev = spawn(WRANGLER, ["dev", "--local", "--port", String(PORT), "--ip", "0.0.0.0", "--persist-to", STATE], { stdio: ["ignore", "inherit", "inherit"] });
process.on("SIGINT", () => { dev.kill(); rmSync(".dev.vars", { force: true }); process.exit(0); });
process.on("SIGTERM", () => { dev.kill(); rmSync(".dev.vars", { force: true }); process.exit(0); });
for (let i = 0; i < 60; i++) {
  try { if ((await fetch(`${BASE}/v1/health`)).ok) break; } catch {}
  await new Promise((resolve) => setTimeout(resolve, 500));
}
const post = async (path, data, token) => (await fetch(BASE + path, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token ?? ""}` }, body: JSON.stringify(data) })).json();
const signIn = await post("/v1/auth/apple", { identityToken, install: INSTALL, platform: "ios", name: "Jo QA" });
const codes = await post("/v1/admin/codes", { count: 2, days: 30, batch: "qa" }, "admin-secret");
await post("/v1/me/redeem", { code: codes.codes[0].code }, signIn.token);
// Points to show: today's use, and a merged pull request that names the account.
await post("/v1/me/day", {}, signIn.token);
d1("yingxia-accounts", ["--command", `INSERT INTO pull_requests (number, author, author_id, title, merged, claim, user_id, how) VALUES (1290, 'qa-dev', 77, 'Sleep timer for music', ${t}, '${signIn.account.id}', '${signIn.account.id}', 'id')`]);
const fresh = await post("/v1/auth/apple", { identityToken: `${b64({ alg: "RS256", kid: "qa" })}.x.y` });
console.log(JSON.stringify({ token: signIn.token, unusedCode: codes.codes[1].code, account: signIn.account.feedback, fresh: fresh.error }));
createServer(async (request, response) => {
  const rows = execFileSync(WRANGLER, ["d1", "execute", "yingxia-accounts", "--local", "--persist-to", STATE, "--json", "--command", "SELECT code FROM telegram_logins WHERE user_id IS NULL"]).toString();
  response.end(rows);
}).listen(8799);

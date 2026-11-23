// TestFlight invitations through the bot's /tf. Yingxia's own TestFlight is full (10,000 testers), so two copies of the
// app take new testers by email invitation:
//   - Yingxia Beta: TF_DAILY places open every day at TF_OPEN_HOUR (UTC+8). The bot announces them in the group and the
//     website shows what's left (GET /v1/tf/slots).
//   - Yingxia Pro: for lifetime Pro people, with no daily limit.
//
//   /tf name@icloud.com   checks the address (an Apple account or Gmail, not invited before) and emails it a code
//   /tf 123456            confirms the code, takes a place (Beta) and has App Store Connect invite the address
//
// One invitation per mailbox and per Telegram account in each app. The daily cleanup on the M5
// (build/tfprune/tfdaily.py) removes Beta testers who stopped using it and reports them here
// (POST /v1/admin/tf/removed); they may ask again TF_AGAIN_DAYS later.

import { User } from "./session";
import { DAY, Env, error, json, jwtES256, LIFETIME, list, now, number, parse, randomText, same, say, sha256 } from "./util";

type App = "beta" | "pro";
const NAME: Record<App, [string, string]> = { beta: ["Yingxia Beta", "映匣 Beta"], pro: ["Yingxia Pro", "映匣 Pro"] };

const CODE_MINUTES = 30;
const CODE_TRIES = 5;
const CODE_GAP = 60; // seconds between two codes for one person
const CODES_PER_DAY = 5; // per Telegram account, and per mailbox
const EMAILS_PER_DAY = 1000; // everyone together: a cap on what the codes can cost

interface Invite {
  id: string;
  app: App;
  telegram: string;
  email: string;
  canonical: string;
  code_hash: string | null;
  code_sent: number;
  tries: number;
  state: string;
  invited: number | null;
  removed: number | null;
}

// Places. A place day starts at TF_OPEN_HOUR in UTC+8.
const shift = (env: Env) => (8 - number(env.TF_OPEN_HOUR, 20)) * 3600;
export const slotDay = (env: Env, time = now()) => Math.floor((time + shift(env)) / DAY);
const opens = (env: Env, day: number) => (day + 1) * DAY - shift(env);
const hour = (env: Env) => `${String(number(env.TF_OPEN_HOUR, 20)).padStart(2, "0")}:00`;

export async function slots(env: Env) {
  const day = slotDay(env);
  const row = await env.DB.prepare("SELECT total, used FROM tf_slots WHERE day = ?").bind(day).first<{ total: number; used: number }>();
  const total = row?.total ?? number(env.TF_DAILY, 100);
  const used = row?.used ?? 0;
  return { day, total, used, left: Math.max(total - used, 0), opens: opens(env, day) };
}

// GET /v1/tf/slots: today's Yingxia Beta places, for the website and the bot's announcement. Public.
export const slotsRoute = async (_request: Request, env: Env) =>
  json(await slots(env), 200, { "access-control-allow-origin": "*", "cache-control": "public, max-age=30" });

async function takeSlot(env: Env, day: number) {
  await env.DB.prepare("INSERT OR IGNORE INTO tf_slots (day, total, used) VALUES (?, ?, 0)").bind(day, number(env.TF_DAILY, 100)).run();
  const taken = await env.DB.prepare("UPDATE tf_slots SET used = used + 1 WHERE day = ? AND used < total").bind(day).run();
  return taken.meta.changes > 0;
}
const giveBack = (env: Env, day: number) => env.DB.prepare("UPDATE tf_slots SET used = MAX(used - 1, 0) WHERE day = ?").bind(day).run();

// Addresses. The canonical spelling stops one mailbox from asking twice: +tags dropped, Gmail's dots dropped, and
// me.com and mac.com as icloud.com (one Apple account answers on all three).
const ADDRESS = /^[a-z0-9._%+-]{1,64}@([a-z0-9-]+\.)+[a-z]{2,}$/;
const APPLE = new Set(["icloud.com", "me.com", "mac.com"]);
const GMAIL = new Set(["gmail.com", "googlemail.com"]);

export function mailbox(env: Env, input: string): { email: string; canonical: string } | "invalid" | "domain" {
  const email = input.trim().toLowerCase();
  if (email.length > 254 || !ADDRESS.test(email)) return "invalid";
  let [local, domain] = email.split("@");
  if (!list(env.TF_DOMAINS).map((d) => d.toLowerCase()).includes(domain)) return "domain";
  local = local.split("+")[0];
  if (GMAIL.has(domain)) [local, domain] = [local.replace(/\./g, ""), "gmail.com"];
  if (APPLE.has(domain)) domain = "icloud.com";
  if (!local) return "invalid";
  return { email, canonical: `${local}@${domain}` };
}

const mask = (email: string) => {
  const [local, domain] = email.split("@");
  return `${local.slice(0, Math.min(2, local.length))}***@${domain}`;
};
const date = (seconds: number) => new Date((seconds + 8 * 3600) * 1000).toISOString().slice(0, 10);
function wait(from: any, seconds: number) {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.max(Math.ceil((seconds % 3600) / 60), hours ? 0 : 1);
  return say(from, hours ? `${hours} h ${minutes} min` : `${minutes} min`, hours ? `${hours} 小时 ${minutes} 分钟` : `${minutes} 分钟`);
}

// The invitation that stops another for this mailbox or this Telegram account in `app`: one sent, or one removed lately.
function blocking(env: Env, app: App, canonical: string, telegram: string) {
  const since = now() - number(env.TF_AGAIN_DAYS, 7) * DAY;
  return env.DB.prepare(
    `SELECT * FROM tf_invites WHERE app = ? AND (canonical = ? OR telegram = ?)
       AND (state = 'invited' OR (state = 'removed' AND removed > ?)) ORDER BY COALESCE(removed, invited) DESC LIMIT 1`)
    .bind(app, canonical, telegram, since).first<Invite>();
}

function heldText(env: Env, from: any, app: App, held: Invite) {
  const [en, cn] = NAME[app];
  if (held.state === "removed") {
    const again = (held.removed ?? now()) + number(env.TF_AGAIN_DAYS, 7) * DAY;
    return say(from,
      `This invitation to ${en} was removed on ${date(held.removed!)} because it wasn't used for 7 days. You can ask again from ${date(again)}.`,
      `这个${cn}邀请已在 ${date(held.removed!)} 因 7 天没有使用被移除，${date(again)} 起可以重新申请。`);
  }
  if (held.telegram === String(from.id)) {
    return say(from,
      `You already have an invitation to ${en}, sent to ${mask(held.email)}. Look for Apple's TestFlight email there (check the spam folder too), or open the TestFlight app on that Apple account.`,
      `你已经有${cn}的邀请了，发到了 ${mask(held.email)}。请在这个邮箱里找 Apple 发来的 TestFlight 邮件（也看看垃圾邮件），或者在登录这个 Apple 账号的设备上打开 TestFlight。`);
  }
  return say(from, `This address has already been invited to ${en}.`, `这个邮箱已经收到过${cn}的邀请。`);
}

const fullText = (env: Env, from: any, total: number, opensAt: number) =>
  say(from,
    `Today's ${total} places in Yingxia Beta are all taken. New places open every day at ${hour(env)} (UTC+8), in ${wait(from, opensAt - now())}.`,
    `今天的 ${total} 个映匣 Beta 名额已经发完了。每天 ${hour(env)}（北京时间）开放新名额，还有 ${wait(from, opensAt - now())}。`);

function usage(env: Env, from: any, app: App, places: Awaited<ReturnType<typeof slots>>) {
  if (app === "pro") {
    return say(from,
      "You have lifetime Pro, which includes Yingxia Pro on TestFlight. Send /tf with your Apple account (iCloud, me.com, mac.com) or Gmail address, for example /tf name@icloud.com. You'll get a code by email to confirm it's yours.",
      "你是永久 Pro，可以加入映匣 Pro 的 TestFlight。发送 /tf 加上你的 Apple 账号邮箱（iCloud、me.com、mac.com）或 Gmail，例如 /tf name@icloud.com。我们会给这个邮箱发验证码，确认是你本人。");
  }
  return say(from,
    `Get a TestFlight invitation to Yingxia Beta: send /tf with your Apple account (iCloud, me.com, mac.com) or Gmail address, for example /tf name@icloud.com. You'll get a code by email to confirm it's yours.\n${places.total} places open every day at ${hour(env)} (UTC+8); ${places.left} left now.`,
    `申请映匣 Beta 的 TestFlight 邀请：发送 /tf 加上你的 Apple 账号邮箱（iCloud、me.com、mac.com）或 Gmail，例如 /tf name@icloud.com。我们会给这个邮箱发验证码，确认是你本人。\n每天 ${hour(env)}（北京时间）开放 ${places.total} 个名额，现在还剩 ${places.left} 个。`);
}

// Cloudflare Email Sending; tests post the message to EMAIL_API instead.
async function sendMail(env: Env, message: { to: string; from: string; subject: string; text: string }) {
  if (env.EMAIL_API) {
    const response = await fetch(env.EMAIL_API, { method: "POST", body: JSON.stringify(message) });
    if (!response.ok) throw new Error(`mail ${response.status}`);
    return;
  }
  await env.EMAIL!.send(message);
}

function sixDigits() {
  return String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, "0");
}

// /tf <address>: emails a code.
async function ask(env: Env, from: any, user: User, app: App, input: string): Promise<string> {
  const box = mailbox(env, input);
  if (box === "invalid") {
    return say(from, "That isn't an email address. Send /tf followed by your address, for example /tf name@icloud.com.",
      "这不是邮箱地址。请发送 /tf 加上你的邮箱，例如 /tf name@icloud.com。");
  }
  if (box === "domain") {
    return say(from, "For now only Apple account addresses (icloud.com, me.com, mac.com) and Gmail are supported.",
      "目前只支持 Apple 账号邮箱（icloud.com、me.com、mac.com）和 Gmail。");
  }
  const telegram = String(from.id);
  const held = await blocking(env, app, box.canonical, telegram);
  if (held) return heldText(env, from, app, held);
  if (app === "beta") {
    const places = await slots(env);
    if (!places.left) return fullText(env, from, places.total, places.opens);
  }
  const time = now();
  const recent = await env.DB.prepare(
    `SELECT COUNT(*) AS everyone, MAX(CASE WHEN telegram = ? THEN code_sent END) AS last,
       SUM(CASE WHEN telegram = ? THEN 1 ELSE 0 END) AS mine, SUM(CASE WHEN canonical = ? THEN 1 ELSE 0 END) AS box
     FROM tf_invites WHERE code_sent > ?`)
    .bind(telegram, telegram, box.canonical, time - DAY).first<{ everyone: number; last: number | null; mine: number | null; box: number | null }>();
  if (recent?.last && recent.last > time - CODE_GAP) {
    return say(from, "A code was just sent. Wait a minute before asking for another.", "刚刚已经发过验证码了，请等一分钟再重新获取。");
  }
  if ((recent?.mine ?? 0) >= CODES_PER_DAY || (recent?.box ?? 0) >= CODES_PER_DAY) {
    return say(from, "Too many codes today. Try again tomorrow.", "今天获取验证码的次数太多了，明天再试。");
  }
  if ((recent?.everyone ?? 0) >= EMAILS_PER_DAY || !(env.EMAIL || env.EMAIL_API)) {
    return say(from, "Codes can't be sent right now. Try again later.", "暂时无法发送验证码，请稍后再试。");
  }
  const id = "tf_" + randomText(16);
  const code = sixDigits();
  const [en, cn] = NAME[app];
  try {
    await sendMail(env, {
      to: box.email,
      from: env.TF_FROM,
      subject: `映匣验证码 ${code} · Yingxia code ${code}`,
      text:
        `你的验证码是 ${code}，${CODE_MINUTES} 分钟内有效。\n请在 Telegram 里给 @${env.TELEGRAM_BOT} 发送：/tf ${code}\n` +
        `确认后，Apple 会把${cn}的 TestFlight 邀请发到这个邮箱。如果不是你本人申请的，忽略这封邮件即可。\n\n` +
        `Your code is ${code}, valid for ${CODE_MINUTES} minutes.\nSend this to @${env.TELEGRAM_BOT} on Telegram: /tf ${code}\n` +
        `Apple will then email a TestFlight invitation to ${en} to this address. If you didn't ask for this, ignore this email.\n`,
    });
  } catch (problem) {
    console.error(`tf email: ${(problem as any)?.code ?? ""} ${problem}`);
    return say(from, "The email couldn't be sent. Check the address, or try again later.", "邮件发送失败。请检查邮箱地址，或稍后再试。");
  }
  await env.DB.batch([
    env.DB.prepare("UPDATE tf_invites SET state = 'replaced', code_hash = NULL WHERE telegram = ? AND state = 'pending'").bind(telegram),
    env.DB.prepare("INSERT INTO tf_invites (id, app, telegram, user_id, email, canonical, code_hash, code_sent, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending')")
      .bind(id, app, telegram, user.id, box.email, box.canonical, await sha256(id + code), time),
  ]);
  return say(from,
    `We emailed a 6-digit code to ${box.email}. Send /tf followed by the code within ${CODE_MINUTES} minutes, for example /tf 123456. (Not there? Check the spam folder.)`,
    `验证码已发到 ${box.email}。请在 ${CODE_MINUTES} 分钟内发送 /tf 加上 6 位验证码，例如 /tf 123456。（没收到的话看看垃圾邮件。）`);
}

// /tf <code>: confirms the address and invites it.
async function confirm(env: Env, from: any, user: User, code: string): Promise<string> {
  const telegram = String(from.id);
  const row = await env.DB.prepare("SELECT * FROM tf_invites WHERE telegram = ? AND state = 'pending' ORDER BY code_sent DESC LIMIT 1")
    .bind(telegram).first<Invite>();
  if (!row || row.code_sent < now() - CODE_MINUTES * 60 || row.tries >= CODE_TRIES) {
    return say(from, "No valid code. Send /tf with your email address to get a new one.", "没有有效的验证码。请发送 /tf 加上你的邮箱，重新获取。");
  }
  if (!same(await sha256(row.id + code), row.code_hash ?? "")) {
    await env.DB.prepare("UPDATE tf_invites SET tries = tries + 1 WHERE id = ?").bind(row.id).run();
    const left = CODE_TRIES - row.tries - 1;
    return left > 0
      ? say(from, `That code isn't right. ${left} ${left === 1 ? "try" : "tries"} left.`, `验证码不对，还可以试 ${left} 次。`)
      : say(from, "That code isn't right. Send /tf with your email address to get a new one.", "验证码不对。请发送 /tf 加上你的邮箱，重新获取。");
  }
  const app = row.app;
  const held = await blocking(env, app, row.canonical, telegram);
  if (held) {
    await env.DB.prepare("UPDATE tf_invites SET state = 'replaced', code_hash = NULL WHERE id = ?").bind(row.id).run();
    return heldText(env, from, app, held);
  }
  const day = slotDay(env);
  if (app === "beta" && !(await takeSlot(env, day))) {
    const places = await slots(env);
    return fullText(env, from, places.total, places.opens);
  }
  let tester: string;
  try {
    tester = await invite(env, app, row.email);
  } catch (problem) {
    console.error(`tf invite: ${problem}`);
    if (app === "beta") await giveBack(env, day);
    return say(from, `The invitation couldn't be sent right now. Your code still works for ${CODE_MINUTES} minutes from when it was sent: send /tf ${code} again in a little while.`,
      `暂时无法发送邀请。验证码在发出后 ${CODE_MINUTES} 分钟内仍然有效，请稍后再发送一次 /tf ${code}。`);
  }
  await env.DB.prepare("UPDATE tf_invites SET state = 'invited', invited = ?, tester = ?, code_hash = NULL, slot_day = ?, user_id = ? WHERE id = ?")
    .bind(now(), tester, app === "beta" ? day : null, user.id, row.id).run();
  const [en, cn] = NAME[app];
  const keep = app === "beta"
    ? ["\nPlaces are limited: every day, testers who haven't opened Yingxia Beta for 7 days are removed to make room for others.",
       "\n名额有限：每天会移除 7 天没有打开映匣 Beta 的测试者，把名额留给别人。"]
    : ["", ""];
  return say(from,
    `Done. Apple will email a TestFlight invitation to ${en} to ${row.email} (if the current build is still in review, once it's approved). Open it on your iPhone or iPad and install TestFlight if asked.${keep[0]}`,
    `完成。Apple 会把${cn}的 TestFlight 邀请发到 ${row.email}（如果当前版本还在审核，会在审核通过后发出）。请在 iPhone 或 iPad 上打开邀请邮件，按提示安装 TestFlight。${keep[1]}`);
}

// The bot's /tf. Lifetime Pro people get Yingxia Pro, everyone else Yingxia Beta.
export async function tfCommand(env: Env, from: any, user: User, argument: string): Promise<string> {
  const app: App = (user.pro_until ?? 0) >= LIFETIME ? "pro" : "beta";
  const input = argument.trim();
  if (/^\d{6}$/.test(input)) return confirm(env, from, user, input);
  if (!input) return usage(env, from, app, await slots(env));
  return ask(env, from, user, app, input);
}

// App Store Connect.
const ASC = "https://api.appstoreconnect.apple.com";

async function asc(env: Env, path: string, method = "GET", body?: unknown) {
  const time = now();
  const token = await jwtES256(env.ASC_PRIVATE_KEY!, { kid: env.ASC_KEY_ID }, { iss: env.ASC_ISSUER, iat: time, exp: time + 600, aud: "appstoreconnect-v1" });
  const response = await fetch((env.ASC_API ?? ASC) + path, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: response.status, data: (await response.json().catch(() => ({}))) as any };
}

// Adds `email` to the app's external group; Apple emails the invitation (for a group whose build isn't approved yet,
// once it is). Answers the tester's ID.
async function invite(env: Env, app: App, email: string): Promise<string> {
  if (!env.ASC_KEY_ID || !env.ASC_PRIVATE_KEY) throw new Error("no App Store Connect key");
  const group = app === "beta" ? env.TF_BETA_GROUP : env.TF_PRO_GROUP;
  const made = await asc(env, "/v1/betaTesters", "POST", {
    data: { type: "betaTesters", attributes: { email }, relationships: { betaGroups: { data: [{ type: "betaGroups", id: group }] } } },
  });
  if (made.status === 201) return made.data.data.id;
  if (made.status !== 409) throw new Error(`betaTesters ${made.status} ${made.data?.errors?.[0]?.detail ?? ""}`);
  // Already a tester of the team (of Yingxia, say): add them to this group and send this app's invitation.
  const found = await asc(env, `/v1/betaTesters?filter[email]=${encodeURIComponent(email)}&limit=1`);
  const id: string | undefined = found.data?.data?.[0]?.id;
  if (!id) throw new Error(`betaTesters 409, then not found (${found.status})`);
  const added = await asc(env, `/v1/betaGroups/${group}/relationships/betaTesters`, "POST", { data: [{ type: "betaTesters", id }] });
  if (added.status >= 300) throw new Error(`betaGroups add ${added.status} ${added.data?.errors?.[0]?.detail ?? ""}`);
  const sent = await asc(env, "/v1/betaTesterInvitations", "POST", {
    data: { type: "betaTesterInvitations", relationships: {
      app: { data: { type: "apps", id: app === "beta" ? env.TF_BETA_APP : env.TF_PRO_APP } },
      betaTester: { data: { type: "betaTesters", id } },
    } },
  });
  if (sent.status >= 300) console.error(`tf invitation email: ${sent.status} ${sent.data?.errors?.[0]?.detail ?? ""}`);
  return id;
}

// Admin API for the daily cleanup (build/tfprune/tfdaily.py on the M5), with the admin token:
//   GET  /v1/admin/tf/invites?app=beta    invited testers: tester ID, when, and whether their account is Pro
//   POST /v1/admin/tf/removed             {testers: [ID...]}: the cleanup removed them; they may ask again later
//   GET  /v1/admin/tf/pro-accounts        Pro accounts and their last active day (the cleanup's Pro guard)
export async function tfAdmin(request: Request, env: Env, path: string): Promise<Response> {
  const url = new URL(request.url);
  if (path === "/v1/admin/tf/invites" && request.method === "GET") {
    const app = url.searchParams.get("app") === "pro" ? "pro" : "beta";
    const rows = await env.DB.prepare(
      `SELECT i.tester, i.invited, i.user_id, COALESCE(u.pro_until, 0) > ? AS pro FROM tf_invites i LEFT JOIN users u ON u.id = i.user_id
       WHERE i.app = ? AND i.state = 'invited' ORDER BY i.invited`).bind(now(), app).all();
    return json({ app, invites: rows.results });
  }
  if (path === "/v1/admin/tf/removed" && request.method === "POST") {
    const body = await parse(request);
    if (body instanceof Response) return body;
    const testers: string[] = Array.isArray(body?.testers) ? body.testers.filter((t: unknown) => typeof t === "string" && /^[A-Za-z0-9-]{1,64}$/.test(t)) : [];
    if (!testers.length || testers.length > 5000) return error(400, "bad_testers");
    const time = now();
    let changed = 0;
    for (let start = 0; start < testers.length; start += 90) {
      const part = testers.slice(start, start + 90);
      const result = await env.DB.prepare(`UPDATE tf_invites SET state = 'removed', removed = ? WHERE state = 'invited' AND tester IN (${part.map(() => "?").join(",")})`)
        .bind(time, ...part).run();
      changed += result.meta.changes;
    }
    return json({ removed: changed });
  }
  if (path === "/v1/admin/tf/pro-accounts" && request.method === "GET") {
    const rows = await env.DB.prepare(
      "SELECT u.id, u.created, (SELECT MAX(day) FROM active_days a WHERE a.user_id = u.id) AS last FROM users u WHERE u.pro_until > ?").bind(now()).all();
    return json({ accounts: rows.results });
  }
  return error(404, "not_found");
}

// Codes nobody confirmed, a week on (kept until then for the daily limits).
export const cleanInvites = (env: Env) =>
  env.DB.prepare("DELETE FROM tf_invites WHERE state IN ('pending', 'replaced') AND code_sent < ?").bind(now() - 7 * DAY).run();

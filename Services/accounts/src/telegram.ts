// Telegram: signing in through the bot (works on every device, the Apple TV too, by QR code), the bot's account
// commands (/redeem <code>, /me), and points for /feedback sent in the Telegram group. The bot is the Yingxia group helper, @yingxia_sup_bot (repository jo32/yx-tg): it
// keeps Telegram's webhook and passes private "/start <code>", /redeem and /me here, then sends the text we answer.
// The app asks for a one-time code, opens t.me/<bot>?start=<code>; the person taps Start; the bot passes
// "/start <code>" here, which ties their Telegram user to the code; the app, asking every few seconds, gets its session.

import { earnsSentPoint, Points, points, Rules, rules } from "./points";
import { isPro, redeem, RedeemFailure } from "./pro";
import { addIdentity, display, Identity, User, userFor } from "./session";
import { base64url, bytes, DAY, Env, now, same } from "./util";

export const LOGIN_SECONDS = 600;

// `linkUser`: someone signed in with Apple adding Telegram, so both reach the same account.
export async function startLogin(env: Env, install: string, platform: string, linkUser: string | null) {
  const code = base64url(bytes(18)); // 24 characters, within the 64 Telegram allows after ?start=
  await env.DB.prepare("INSERT INTO telegram_logins (code, install, platform, created, link_user) VALUES (?, ?, ?, ?, ?)")
    .bind(code, install, platform, now(), linkUser).run();
  return { code, url: `https://t.me/${env.TELEGRAM_BOT}?start=${code}`, expires: now() + LOGIN_SECONDS };
}

// The person the bot has seen for `code`, or "pending" / "expired". Once seen, the code keeps giving that person until
// it expires: the app's check is often cut off as it comes back from Telegram (the answer is lost, though the sign-in
// happened here), and the next check must still sign it in rather than say the link expired. Old codes go in cleanLogins.
export async function loginResult(env: Env, code: string): Promise<{ user: User; install: string; platform: string } | "pending" | "expired"> {
  const row = await env.DB.prepare("SELECT * FROM telegram_logins WHERE code = ?").bind(code)
    .first<{ code: string; install: string; platform: string; created: number; user_id: string | null }>();
  if (!row || row.created < now() - LOGIN_SECONDS) return "expired";
  if (!row.user_id) return "pending";
  const user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(row.user_id).first<User>();
  return user ? { user, install: row.install, platform: row.platform } : "expired";
}

// Chinese for people whose Telegram is in Chinese, English for everyone else.
const zh = (from: any) => String(from?.language_code ?? "").toLowerCase().startsWith("zh");
const say = (from: any, english: string, chinese: string) => (zh(from) ? chinese : english);

const date = (seconds: number) => new Date(seconds * 1000).toISOString().slice(0, 10);

function proLine(from: any, user: User) {
  if (!isPro(user)) return say(from, "Pro: not active", "Pro：未开通");
  if ((user.pro_until ?? 0) >= 253402300799) return say(from, "Pro: lifetime", "Pro：永久");
  return say(from, `Pro: until ${date(user.pro_until!)}`, `Pro：有效期至 ${date(user.pro_until!)}`);
}

const REDEEM_TEXT: Record<RedeemFailure, [string, string]> = {
  invalid: ["That doesn't look like a code. Send /redeem followed by your code.", "这不像是兑换码。请发送 /redeem 加上你的兑换码。"],
  not_found: ["No such code. Check it and try again.", "没有这个兑换码，请检查后重试。"],
  revoked: ["This code has been withdrawn.", "此兑换码已被撤销。"],
  expired: ["This code has expired.", "此兑换码已过期。"],
  used_up: ["This code has already been used.", "此兑换码已被使用。"],
  already_redeemed: ["You've already redeemed this code.", "你已兑换过此兑换码。"],
};

function pointsLines(from: any, counted: Points) {
  const r = counted.rules;
  const adjusted = counted.adjusted ? say(from, `\n· adjusted by the developer: ${counted.adjusted > 0 ? "+" : ""}${counted.adjusted}`, `\n· 作者调整：${counted.adjusted > 0 ? "+" : ""}${counted.adjusted}`) : "";
  return say(from,
    `Points: ${counted.total}\n· ${counted.days} days of use: +${counted.days * r.daily}\n· ${counted.sent} feedback sent: +${counted.sent * r.sent}\n· ${counted.fixed} bugs fixed: +${counted.fixed * r.fixed}\n· ${counted.adopted} ideas adopted: +${counted.adopted * r.adopted}\n· ${counted.pullRequests} merged pull requests: +${counted.pullRequests * r.pullRequest}${adjusted}`,
    `积分：${counted.total}\n· 使用 ${counted.days} 天：+${counted.days * r.daily}\n· 反馈 ${counted.sent} 条：+${counted.sent * r.sent}\n· 问题被修复 ${counted.fixed} 条：+${counted.fixed * r.fixed}\n· 建议被采纳 ${counted.adopted} 条：+${counted.adopted * r.adopted}\n· 合并 PR ${counted.pullRequests} 个：+${counted.pullRequests * r.pullRequest}${adjusted}`);
}

// How points work, everywhere the bot talks about them.
export function rulesText(from: any, r: Rules) {
  return say(from,
    `How points work: +${r.daily} each day you open Yingxia signed in; +${r.sent} for each feedback message (up to ${r.sentPerDay} a day; duplicates and invalid ones don't count); +${r.fixed} when the developer fixes a bug you reported, +${r.adopted} when they adopt an idea you suggested; +${r.pullRequest} for each merged pull request (write "Yingxia account: <your account ID or Telegram @username>" in its description).\nFeedback with your device, build, the source and clear steps is the most likely to be adopted.`,
    `积分规则：登录后每天打开映匣 +${r.daily}；每条反馈 +${r.sent}（每天最多 ${r.sentPerDay} 条，重复或无效的不算）；问题被修复 +${r.fixed}，建议被采纳 +${r.adopted}；PR 合并 +${r.pullRequest}（在 PR 描述里写“映匣账号：你的账号 ID 或 Telegram @用户名”）。\n写清设备、build 号、用的源和复现步骤的反馈最容易被采纳。`);
}

// The bot sends this text back to the person (null: nothing to say).
const answer = (text: string | null) => Response.json({ text });

function identity(from: any): Identity {
  const name = display([from.first_name, from.last_name].filter(Boolean).join(" "));
  return { provider: "telegram", subject: String(from.id), label: from.username ? "@" + display(from.username, 40) : name, name };
}
const telegramUser = (env: Env, from: any) => userFor(env, identity(from));

// POST /v1/telegram/webhook: a Telegram update the bot (yx-tg) passes on, with the secret both Workers share
// (TELEGRAM_WEBHOOK_SECRET here, ACCOUNTS_SECRET there). Answers {text}: what the bot should reply.
export async function webhook(request: Request, env: Env): Promise<Response> {
  if (!env.TELEGRAM_WEBHOOK_SECRET) return new Response(null, { status: 503 });
  if (!same(request.headers.get("x-telegram-bot-api-secret-token") ?? "", env.TELEGRAM_WEBHOOK_SECRET)) return new Response(null, { status: 401 });
  const update: any = await request.json().catch(() => null);
  const message = update?.message;
  const from = message?.from;
  const chat = message?.chat?.id;
  // Only private chats with a person.
  if (!message || !from || from.is_bot || message.chat?.type !== "private" || typeof message.text !== "string") return answer(null);
  const [command, ...rest] = message.text.trim().split(/\s+/);
  const argument = rest.join(" ");
  const name = command.toLowerCase().replace(/@.*$/, "");

  if (name === "/start" && /^[A-Za-z0-9_-]{16,64}$/.test(argument)) {
    const login = await env.DB.prepare("SELECT created, user_id, link_user FROM telegram_logins WHERE code = ?").bind(argument)
      .first<{ created: number; user_id: string | null; link_user: string | null }>();
    if (!login || login.created < now() - LOGIN_SECONDS) {
      return answer(say(from, "This sign-in link has expired. Start again in the app.", "此登录链接已过期，请在 App 中重新开始。"));
    }
    let user: User | null;
    if (login.link_user) {
      user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(login.link_user).first<User>();
      if (!user || !(await addIdentity(env, user, identity(from)))) {
        return answer(say(from,
          "This Telegram account already belongs to another Yingxia account. Sign out in the app and sign in with Telegram instead.",
          "此 Telegram 账号已关联另一个映匣账户。请在 App 中退出登录，再使用 Telegram 登录。"));
      }
    } else {
      user = await telegramUser(env, from);
    }
    await env.DB.prepare("UPDATE telegram_logins SET user_id = ? WHERE code = ?").bind(user.id, argument).run();
    return answer(say(from, "You're signed in to Yingxia. Go back to the app.", "你已登录映匣，请返回 App。"));
  }

  if (name === "/redeem") {
    const user = await telegramUser(env, from);
    if (!(await env.REDEEM_LIMITER.limit({ key: `tg:${from.id}` })).success) {
      return answer(say(from, "Too many tries. Wait a minute.", "尝试次数过多，请稍等一分钟。"));
    }
    const result = await redeem(env, user, argument, "telegram");
    if (typeof result === "string") return answer(say(from, ...REDEEM_TEXT[result]));
    user.pro_until = result.proUntil;
    return answer(say(from,
      `Code redeemed. ${proLine(from, user)}.\nSign in to Yingxia with Telegram (Settings › Account) to use it in the app.`,
      `兑换成功。${proLine(from, user)}。\n在映匣中通过 Telegram 登录（设置 › 账号）即可在 App 中使用。`));
  }

  if (name === "/me" || name === "/status" || name === "/points") {
    const user = await telegramUser(env, from);
    const counted = await points(env, user.id);
    return answer(`${proLine(from, user)}\n${pointsLines(from, counted)}\n\n${rulesText(from, counted.rules)}`);
  }

  return answer(say(from,
    "Yingxia account bot.\n/redeem <code> — redeem a Pro code\n/me — your points and Pro status\nTo sign in, choose Sign in with Telegram in the app's Settings › Account.",
    "映匣账号：\n/redeem <兑换码> — 兑换 Pro\n/me — 查看积分和 Pro 状态\n登录请在 App 的 设置 › 账号 中选择“通过 Telegram 登录”。"));
}

// POST /v1/telegram/feedback, from the bot's Worker with the shared secret: {from, issue, sent} once a /feedback in
// the Telegram group became GitHub issue `issue`. It counts for that Telegram user's account (keyed by their user ID,
// which unlike a @username can't be changed or taken over), made now if they have none, as /redeem and /me do; signing
// in to the app with the same Telegram shows it. Answers {text}: what it earned, for the bot's reply.
export async function telegramFeedback(request: Request, env: Env): Promise<Response> {
  if (!env.TELEGRAM_WEBHOOK_SECRET) return new Response(null, { status: 503 });
  if (!same(request.headers.get("x-telegram-bot-api-secret-token") ?? "", env.TELEGRAM_WEBHOOK_SECRET)) return new Response(null, { status: 401 });
  const body: any = await request.json().catch(() => null);
  const from = body?.from;
  const issue = Number(body?.issue);
  if (!from || typeof from.id !== "number" || from.is_bot || !Number.isInteger(issue) || issue <= 0) return new Response(null, { status: 400 });
  const user = await telegramUser(env, from);
  const sent = Math.min(Math.trunc(Number(body?.sent)) || now(), now());
  const added = await env.DB.prepare("INSERT OR IGNORE INTO feedback_issues (issue, user_id, install, sent) VALUES (?, ?, 'telegram', ?)")
    .bind(issue, user.id, sent).run();
  if (!added.meta.changes) return answer(null);
  const r = rules(env);
  if (await earnsSentPoint(env, user.id, issue, sent)) {
    return answer(say(from,
      `This feedback earned you ${r.sent} point, and ${r.fixed} more if it's a bug that gets fixed, or ${r.adopted} if it's an idea that gets adopted. Send /me to @${env.TELEGRAM_BOT} to see your points.`,
      `这条反馈 +${r.sent} 积分；问题被修复再 +${r.fixed}，建议被采纳再 +${r.adopted}。私聊 @${env.TELEGRAM_BOT} 发 /me 查看积分。`));
  }
  return answer(say(from,
    `You've had today's ${r.sentPerDay} feedback points; this one still earns ${r.fixed} if it's a bug that gets fixed, or ${r.adopted} if it's an idea that gets adopted.`,
    `今天的反馈积分已满（每天 ${r.sentPerDay} 条），这条问题被修复仍会 +${r.fixed}，建议被采纳仍会 +${r.adopted}。`));
}

// Old, unfinished sign-ins.
export const cleanLogins = (env: Env) => env.DB.prepare("DELETE FROM telegram_logins WHERE created < ?").bind(now() - DAY).run();

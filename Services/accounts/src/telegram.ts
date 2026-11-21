// Telegram: signing in through the bot (works on every device, the Apple TV too, by QR code), and the bot's own
// commands: /redeem <code>, /me. The app asks for a one-time code, opens t.me/<bot>?start=<code>; the person taps
// Start; Telegram sends the bot "/start <code>" here (the webhook), which ties their Telegram user to the code; the app,
// asking every few seconds, then gets its session.

import { stats } from "./feedback";
import { isPro, redeem, RedeemFailure } from "./pro";
import { addIdentity, display, Identity, User, userFor } from "./session";
import { base64url, bytes, DAY, Env, now, same } from "./util";

export const LOGIN_SECONDS = 600;

const api = (env: Env, method: string, body: unknown) =>
  fetch(`${env.TELEGRAM_API ?? "https://api.telegram.org"}/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

// `linkUser`: someone signed in with Apple adding Telegram, so both reach the same account.
export async function startLogin(env: Env, install: string, platform: string, linkUser: string | null) {
  const code = base64url(bytes(18)); // 24 characters, within the 64 Telegram allows after ?start=
  await env.DB.prepare("INSERT INTO telegram_logins (code, install, platform, created, link_user) VALUES (?, ?, ?, ?, ?)")
    .bind(code, install, platform, now(), linkUser).run();
  return { code, url: `https://t.me/${env.TELEGRAM_BOT}?start=${code}`, expires: now() + LOGIN_SECONDS };
}

// The person the bot has seen for `code`, or "pending" / "expired".
export async function loginResult(env: Env, code: string): Promise<{ user: User; install: string; platform: string } | "pending" | "expired"> {
  const row = await env.DB.prepare("SELECT * FROM telegram_logins WHERE code = ?").bind(code)
    .first<{ code: string; install: string; platform: string; created: number; user_id: string | null }>();
  if (!row || row.created < now() - LOGIN_SECONDS) return "expired";
  if (!row.user_id) return "pending";
  const user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(row.user_id).first<User>();
  await env.DB.prepare("DELETE FROM telegram_logins WHERE code = ?").bind(code).run();
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

async function reply(env: Env, chat: number, text: string) {
  await api(env, "sendMessage", { chat_id: chat, text, disable_web_page_preview: true });
}

function identity(from: any): Identity {
  const name = display([from.first_name, from.last_name].filter(Boolean).join(" "));
  return { provider: "telegram", subject: String(from.id), label: from.username ? "@" + display(from.username, 40) : name, name };
}
const telegramUser = (env: Env, from: any) => userFor(env, identity(from));

// POST /v1/telegram/webhook. Telegram sends the secret set with setWebhook (POST /v1/admin/telegram/setup).
export async function webhook(request: Request, env: Env): Promise<Response> {
  if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_WEBHOOK_SECRET) return new Response(null, { status: 503 });
  if (!same(request.headers.get("x-telegram-bot-api-secret-token") ?? "", env.TELEGRAM_WEBHOOK_SECRET)) return new Response(null, { status: 401 });
  const update: any = await request.json().catch(() => null);
  const message = update?.message;
  const from = message?.from;
  const chat = message?.chat?.id;
  // Only private chats with a person; anything else is acknowledged and ignored, or Telegram keeps resending it.
  if (!message || !from || from.is_bot || message.chat?.type !== "private" || typeof message.text !== "string") return new Response("ok");
  const [command, ...rest] = message.text.trim().split(/\s+/);
  const argument = rest.join(" ");
  const name = command.toLowerCase().replace(/@.*$/, "");

  if (name === "/start" && /^[A-Za-z0-9_-]{16,64}$/.test(argument)) {
    const login = await env.DB.prepare("SELECT created, user_id, link_user FROM telegram_logins WHERE code = ?").bind(argument)
      .first<{ created: number; user_id: string | null; link_user: string | null }>();
    if (!login || login.created < now() - LOGIN_SECONDS) {
      await reply(env, chat, say(from, "This sign-in link has expired. Start again in the app.", "此登录链接已过期，请在 App 中重新开始。"));
      return new Response("ok");
    }
    let user: User | null;
    if (login.link_user) {
      user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(login.link_user).first<User>();
      if (!user || !(await addIdentity(env, user, identity(from)))) {
        await reply(env, chat, say(from,
          "This Telegram account already belongs to another Yingxia account. Sign out in the app and sign in with Telegram instead.",
          "此 Telegram 账号已关联另一个映匣账户。请在 App 中退出登录，再使用 Telegram 登录。"));
        return new Response("ok");
      }
    } else {
      user = await telegramUser(env, from);
    }
    await env.DB.prepare("UPDATE telegram_logins SET user_id = ? WHERE code = ?").bind(user.id, argument).run();
    await reply(env, chat, say(from, "You're signed in to Yingxia. Go back to the app.", "你已登录映匣，请返回 App。"));
    return new Response("ok");
  }

  if (name === "/redeem") {
    const user = await telegramUser(env, from);
    if (!(await env.REDEEM_LIMITER.limit({ key: `tg:${from.id}` })).success) {
      await reply(env, chat, say(from, "Too many tries. Wait a minute.", "尝试次数过多，请稍等一分钟。"));
      return new Response("ok");
    }
    const result = await redeem(env, user, argument, "telegram");
    if (typeof result === "string") {
      await reply(env, chat, say(from, ...REDEEM_TEXT[result]));
    } else {
      user.pro_until = result.proUntil;
      await reply(env, chat, say(from,
        `Code redeemed. ${proLine(from, user)}.\nSign in to Yingxia with Telegram (Settings › Account) to use it in the app.`,
        `兑换成功。${proLine(from, user)}。\n在映匣中使用 Telegram 登录（设置 › 账户）即可在 App 中使用。`));
    }
    return new Response("ok");
  }

  if (name === "/me" || name === "/status") {
    const user = await telegramUser(env, from);
    const counts = await stats(env, user);
    await reply(env, chat, say(from,
      `${proLine(from, user)}\nFeedback: ${counts.sent} sent, ${counts.adopted} adopted, ${counts.points} points`,
      `${proLine(from, user)}\n反馈：已发送 ${counts.sent} 条，已采纳 ${counts.adopted} 条，积分 ${counts.points}`));
    return new Response("ok");
  }

  await reply(env, chat, say(from,
    "Yingxia account bot.\n/redeem <code> — redeem a Pro code\n/me — your Pro status and feedback\nTo sign in, choose Sign in with Telegram in the app's Settings › Account.",
    "映匣账户机器人。\n/redeem <兑换码> — 兑换 Pro\n/me — 查看 Pro 状态和反馈\n登录请在 App 的 设置 › 账户 中选择“使用 Telegram 登录”。"));
  return new Response("ok");
}

// Points Telegram at the webhook and lists the bot's commands. Run once after deploying (POST /v1/admin/telegram/setup).
export async function setup(env: Env, origin: string) {
  const hook = await api(env, "setWebhook", {
    url: `${origin}/v1/telegram/webhook`,
    secret_token: env.TELEGRAM_WEBHOOK_SECRET,
    allowed_updates: ["message"],
    drop_pending_updates: true,
  });
  const commands = [
    { command: "redeem", description: "Redeem a Pro code" },
    { command: "me", description: "Your Pro status and feedback" },
  ];
  const zhCommands = [
    { command: "redeem", description: "兑换 Pro 兑换码" },
    { command: "me", description: "查看 Pro 状态和反馈" },
  ];
  await api(env, "setMyCommands", { commands });
  await api(env, "setMyCommands", { commands: zhCommands, language_code: "zh" });
  return { webhook: await hook.json() };
}

// Old, unfinished sign-ins.
export const cleanLogins = (env: Env) => env.DB.prepare("DELETE FROM telegram_logins WHERE created < ?").bind(now() - DAY).run();

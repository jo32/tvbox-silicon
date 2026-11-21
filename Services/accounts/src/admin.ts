// The admin API for the Yingxia admin pages: redeem codes, people, Pro time by hand, the Telegram bot's webhook.
// Every request carries `Authorization: Bearer <ADMIN_TOKEN>`. Browsers on ADMIN_ORIGINS may call it (CORS).
// Documented in README.md.

import { stats } from "./feedback";
import { createCodes, grant } from "./pro";
import { erase, identities, User } from "./session";
import { DAY, Env, error, json, LIFETIME, list, now, parse, same } from "./util";

export function cors(request: Request, env: Env): Record<string, string> {
  const origin = request.headers.get("origin") ?? "";
  if (!origin || !list(env.ADMIN_ORIGINS).includes(origin)) return {};
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-headers": "authorization, content-type",
    "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

const page = (url: URL) => ({
  limit: Math.min(Math.max(Math.trunc(Number(url.searchParams.get("limit") ?? 50)) || 50, 1), 200),
  offset: Math.max(Math.trunc(Number(url.searchParams.get("offset") ?? 0)) || 0, 0),
});

async function person(env: Env, user: User) {
  return {
    id: user.id,
    name: user.name,
    created: user.created,
    proUntil: user.pro_until,
    lifetime: (user.pro_until ?? 0) >= LIFETIME,
    identities: await identities(env, user),
    feedback: await stats(env, user),
    grants: (await env.DB.prepare("SELECT kind, ref, days, via, at FROM grants WHERE user_id = ? ORDER BY at DESC LIMIT 100").bind(user.id).all()).results,
    installs: (await env.DB.prepare("SELECT install, platform, linked FROM installs WHERE user_id = ? ORDER BY linked DESC").bind(user.id).all()).results,
  };
}

export async function admin(request: Request, env: Env, path: string): Promise<Response> {
  if (!env.ADMIN_TOKEN) return error(503, "no_admin_token");
  const token = /^Bearer (\S+)$/.exec(request.headers.get("authorization") ?? "")?.[1] ?? "";
  if (!same(token, env.ADMIN_TOKEN)) return error(401, "unauthorized");
  const url = new URL(request.url);
  const method = request.method;
  let match: RegExpExecArray | null;

  // Codes: make, list, revoke.
  if (path === "/v1/admin/codes" && method === "POST") {
    const body = await parse(request);
    if (body instanceof Response) return body;
    try {
      return json(await createCodes(env, body), 201);
    } catch (problem) {
      return error(400, "bad_request", { message: (problem as Error).message });
    }
  }
  if (path === "/v1/admin/codes" && method === "GET") {
    const { limit, offset } = page(url);
    const batch = url.searchParams.get("batch");
    const rows = await env.DB.prepare(
      `SELECT id, hint, batch, note, days, max_uses AS maxUses, used, created, expires, revoked FROM codes${batch !== null ? " WHERE batch = ?" : ""} ORDER BY created DESC, id LIMIT ? OFFSET ?`,
    ).bind(...(batch !== null ? [batch] : []), limit, offset).all();
    return json({ codes: rows.results, limit, offset });
  }
  if ((match = /^\/v1\/admin\/codes\/(c_[A-Z0-9]+)$/.exec(path)) && method === "GET") {
    const code = await env.DB.prepare("SELECT id, hint, batch, note, days, max_uses AS maxUses, used, created, expires, revoked FROM codes WHERE id = ?").bind(match[1]).first();
    if (!code) return error(404, "not_found");
    const redeemed = await env.DB.prepare("SELECT g.user_id AS user, u.name, g.via, g.at FROM grants g LEFT JOIN users u ON u.id = g.user_id WHERE g.kind = 'code' AND g.ref = ? ORDER BY g.at")
      .bind(match[1]).all();
    return json({ ...code, redemptions: redeemed.results });
  }
  if (path === "/v1/admin/codes/revoke" && method === "POST") {
    const body = await parse(request);
    if (body instanceof Response) return body;
    const ids: string[] = Array.isArray(body?.ids) ? body.ids.filter((id: unknown) => typeof id === "string").slice(0, 500) : [];
    let changed = 0;
    if (ids.length) {
      changed += (await env.DB.prepare(`UPDATE codes SET revoked = 1 WHERE id IN (${ids.map(() => "?").join(",")})`).bind(...ids).run()).meta.changes;
    }
    if (typeof body?.batch === "string" && body.batch) {
      changed += (await env.DB.prepare("UPDATE codes SET revoked = 1 WHERE batch = ?").bind(body.batch).run()).meta.changes;
    }
    return json({ revoked: changed });
  }
  if (path === "/v1/admin/batches" && method === "GET") {
    const rows = await env.DB.prepare(
      "SELECT batch, COUNT(*) AS codes, SUM(used) AS used, SUM(max_uses) AS uses, SUM(revoked) AS revoked, MIN(created) AS created, MAX(days) AS days FROM codes GROUP BY batch ORDER BY created DESC",
    ).all();
    return json({ batches: rows.results });
  }

  // People.
  if (path === "/v1/admin/users" && method === "GET") {
    const { limit, offset } = page(url);
    const query = (url.searchParams.get("q") ?? "").trim();
    const pro = url.searchParams.get("pro") === "1";
    const where: string[] = [];
    const values: unknown[] = [];
    if (query) {
      where.push("(u.id = ? OR u.name LIKE ? OR u.id IN (SELECT user_id FROM identities WHERE label LIKE ? OR subject = ?) OR u.id IN (SELECT user_id FROM installs WHERE install = ?))");
      values.push(query, `%${query}%`, `%${query}%`, query, query.toUpperCase());
    }
    if (pro) {
      where.push("u.pro_until > ?");
      values.push(now());
    }
    const rows = await env.DB.prepare(
      `SELECT u.id, u.name, u.created, u.pro_until AS proUntil,
        (SELECT GROUP_CONCAT(provider || ':' || label, ' ') FROM identities WHERE user_id = u.id) AS identities,
        (SELECT COUNT(*) FROM feedback_issues WHERE user_id = u.id) AS sent,
        (SELECT COUNT(*) FROM feedback_issues WHERE user_id = u.id AND status = 'adopted') AS adopted
       FROM users u${where.length ? " WHERE " + where.join(" AND ") : ""} ORDER BY ${url.searchParams.get("sort") === "adopted" ? "adopted DESC," : ""} u.created DESC LIMIT ? OFFSET ?`,
    ).bind(...values, limit, offset).all();
    return json({ users: rows.results, limit, offset });
  }
  if ((match = /^\/v1\/admin\/users\/(u_[A-Z0-9]+)(\/pro)?$/.exec(path))) {
    const user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(match[1]).first<User>();
    if (!user) return error(404, "not_found");
    if (!match[2] && method === "GET") return json(await person(env, user));
    if (!match[2] && method === "DELETE") {
      await erase(env, user.id);
      return json({ deleted: user.id });
    }
    if (match[2] && method === "POST") {
      // {days: n} adds n days; {days: null} gives lifetime; {until: unix seconds} sets the end (0 ends Pro now).
      const body = await parse(request);
      if (body instanceof Response) return body;
      const note = typeof body?.note === "string" ? body.note.slice(0, 200) : "";
      if (typeof body?.until === "number") {
        await env.DB.prepare("UPDATE users SET pro_until = ? WHERE id = ?").bind(Math.trunc(body.until) || null, user.id).run();
        await env.DB.prepare("INSERT INTO grants (user_id, kind, ref, days, via, at) VALUES (?, 'admin', ?, 0, 'admin', ?)")
          .bind(user.id, `${Date.now()}:until ${Math.trunc(body.until)} ${note}`.trim(), Date.now()).run();
      } else if (body?.days === null || (typeof body?.days === "number" && body.days >= 1 && body.days <= 36500)) {
        await grant(env, user.id, "admin", `${Date.now()}:${note}`, body.days === null ? null : Math.trunc(body.days), "admin");
      } else {
        return error(400, "bad_request", { message: "send {days: 1-36500}, {days: null} for lifetime, or {until: unix seconds}" });
      }
      const after = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(user.id).first<User>();
      return json(await person(env, after!));
    }
  }

  if (path === "/v1/admin/stats" && method === "GET") {
    const time = now();
    const counts = await env.DB.prepare(
      `SELECT (SELECT COUNT(*) FROM users) AS users, (SELECT COUNT(*) FROM users WHERE pro_until > ?) AS pro,
        (SELECT COUNT(*) FROM users WHERE created > ?) AS newThisWeek,
        (SELECT COUNT(*) FROM codes) AS codes, (SELECT COALESCE(SUM(used), 0) FROM codes) AS redeemed,
        (SELECT COUNT(*) FROM feedback_issues) AS feedback, (SELECT COUNT(*) FROM feedback_issues WHERE status = 'adopted') AS adopted`,
    ).bind(time, time - 7 * DAY).first();
    return json(counts);
  }

  return error(404, "not_found");
}

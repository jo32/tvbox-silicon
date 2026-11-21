# Yingxia accounts

Worker `yingxia-accounts` at `https://yingxia-accounts.getmegaportal.com`, with its own D1 database `yingxia-accounts`.
It does five things:

- **Sign-in.** Sign in with Apple, where the build has the entitlement, and Telegram through a bot, which works on
  every device; Apple TV shows a QR code. One person can add both.
- **Feedback that counts.** Feedback sent from Settings › Send Feedback while signed in counts for the person. So does
  feedback the same install sent in the 30 days before it signed in, and `/feedback` sent in the Telegram group (the
  bot passes it on, keyed by Telegram user ID). GitHub decides whether a message was **adopted** (labeled `fixed` or
  `adopted`: closing alone isn't enough), just closed, or declined (closed as not planned, or labeled `duplicate`,
  `invalid`, `wontfix` or `spam`). `REWARD_DAYS` > 0 also gives that many Pro days for each adopted message, once per
  issue.
- **Points**, which reward feedback and code that get used far more than volume (`src/points.ts`):

  | For | Points | Limits |
  |---|---|---|
  | each day the app is open, signed in | `POINTS_DAILY` (1) | once a day per account; each device gives its day to one account |
  | each feedback message | `POINTS_SENT` (1) | 3 a day; none for duplicates or declined ones |
  | each reported bug that's fixed | `POINTS_FIXED` (50) | only by the `fixed` label; once per issue |
  | each suggested idea that's adopted | `POINTS_ADOPTED` (100) | only by the `adopted` label (it wins over `fixed`); once per issue |
  | each merged pull request | `POINTS_PR` (500) | see below |

  A merged pull request counts for the account its description names on a line `Yingxia account: <ID>` (the ID is
  in Settings › Account; `.github/pull_request_template.md` asks for it), or the person's Telegram `@username`, or
  the email of their Sign in with Apple. Once a GitHub user's claim has matched, their later pull requests count for
  the same account without it. Never counted: pull requests by `PR_EXCLUDE` (the owner) and bots, ones labeled
  `no-points`, claims inside HTML comments, and claims that fit more than one account. The admin can hand a pull
  request to someone, take it out, or add and take away points (below). Days start at midnight UTC+8. The total is
  counted again from these rows each time, never kept as a running number.
- **Pro.** Pro comes from redeem codes made by the admin pages. People redeem them in the app (Settings › Account) or
  with the Telegram bot (`/redeem CODE`). Pro also comes from rewards, or from the admin by hand. The app keeps an
  Ed25519-signed entitlement, so Pro also works offline. TestFlight, direct Mac downloads, and sideloaded builds
  show Pro status and support in-app code redemption.
- **An admin API** for the admin pages, described below.

The app's side is `Sources/TVCore/Account.swift`, `App/AccountStore.swift` and `App/AccountView.swift`.

It reads (never writes) the error-reports database `yingxia-reports`, whose `feedback` table ties issue numbers to
installs. That table keeps rows for 30 days only, so a job every 15 minutes copies the rows of signed-in installs
here and asks GitHub what became of their issues.

## Setup (once)

From this folder, with `W=../../website/node_modules/.bin/wrangler`:

1. `$W d1 create yingxia-accounts`. Put its id in `wrangler.jsonc`, then run
   `$W d1 execute yingxia-accounts --remote --file schema.sql`.
2. The bot is the Yingxia group helper, [@yingxia_sup_bot](https://t.me/yingxia_sup_bot) (`TELEGRAM_BOT` in
   `wrangler.jsonc`). Its Worker, `yx-tg` (repository jo32/yx-tg), keeps Telegram's webhook and the bot's token. In
   private chats it passes `/start <code>`, `/redeem` and `/me` to `/v1/telegram/webhook` here through a service
   binding and sends the `{text}` this Worker answers. This Worker never calls Telegram.
3. Add the secrets:
   - `$W secret put TELEGRAM_WEBHOOK_SECRET`: a random string, e.g. `openssl rand -hex 24`. yx-tg sends it; set the
     same value there as `ACCOUNTS_SECRET`.
   - `$W secret put ADMIN_TOKEN`: a long random string the admin pages send.
   - `$W secret put ENTITLEMENT_KEY < ~/.config/yingxia/accounts-entitlement.key`: on the M5. Its public half is
     `ProEntitlement.publicKey` in `Sources/TVCore/Account.swift`. If you replace the key, change both.
   - `$W secret put GITHUB_TOKEN`: read access to the issues of jo32/tvbox-silicon is enough. The error-reports token
     works too.
   - Optional: `APPLE_KEY_ID` and `APPLE_PRIVATE_KEY`, a Sign in with Apple key (.p8) from the developer site. With
     them, deleting an account also revokes the person's Apple sign-in, as App Review asks.
4. `$W deploy`
5. `curl https://yingxia-accounts.getmegaportal.com/v1/health` should show `true` for everything you set.

Sign in with Apple also needs the capability on the App IDs `com.jo32.yingxia.ios`, `.tv` and `.macos`, and
regenerated profiles. After that:
- TestFlight: `APPLE_SIGN_IN=1 Scripts/testflight-upload.sh <build>`.
- The Mac release: `Scripts/package-mac-release.sh` turns it on by itself when the Developer ID profile has it.
- Debug builds: pass `ICLOUD_ENTITLEMENTS=Config/AppleSignIn.entitlements APPLE_SIGN_IN=YES`.

Until then the app only offers Telegram. Sideloaded builds are re-signed with someone else's profile, so they always
offer Telegram only.

## Admin API

Every call sends `Authorization: Bearer <ADMIN_TOKEN>`. Browsers may call it from the origins in `ADMIN_ORIGINS`
(comma-separated, in `wrangler.jsonc`). Times are Unix seconds unless a name says otherwise. Errors look like
`{"error": "...", "message": "..."}`.

| Call | Body or query | Answer |
|---|---|---|
| `POST /v1/admin/codes` | `{count, days, maxUses, expires, batch, note}`. Or `{codes: ["MY-CODE", ...], ...}` to choose the codes. `days: null` = lifetime. `maxUses` defaults to 1. At most 500 per call. | `201 {batch, days, maxUses, expires, codes: [{id, code, hint}]}`. **This is the only time the codes are shown.** Only their hashes are kept. |
| `GET /v1/admin/codes` | `?batch=&limit=50&offset=0` | `{codes: [{id, hint, batch, note, days, maxUses, used, created, expires, revoked}]}` |
| `GET /v1/admin/codes/<id>` | | the code plus `redemptions: [{user, name, via, at (ms)}]` |
| `POST /v1/admin/codes/revoke` | `{ids: [...]}` and/or `{batch}` | `{revoked: n}` |
| `GET /v1/admin/batches` | | `{batches: [{batch, codes, used, uses, revoked, created, days}]}` |
| `GET /v1/admin/users` | `?q=` (ID, name, email, @username, Telegram ID or install ID), `&pro=1`, `&sort=adopted`, `&limit&offset` | `{users: [{id, name, created, proUntil, identities, sent, adopted}]}` |
| `GET /v1/admin/users/<id>` | | `{id, name, proUntil, lifetime, identities, feedback, grants, installs}` |
| `POST /v1/admin/users/<id>/pro` | `{days: 30}` adds days, `{days: null}` = lifetime, `{until: 0}` ends Pro, `{until: t}` sets the end. Optional `note`. | the person, as above |
| `DELETE /v1/admin/users/<id>` | | `{deleted}` |
| `POST /v1/admin/users/<id>/points` | `{points: n, note}`; negative takes away | the person, as above, with `points` and `adjustments` |
| `GET /v1/admin/pull-requests` | `?unmatched=1` (nobody's yet), `&limit&offset` | `{pullRequests: [{number, author, title, merged, claim, user, name, how, excluded}]}` |
| `POST /v1/admin/pull-requests/<n>` | `{user: "u_…"}` (also remembers its author), `{user: null}`, `{excluded: true}`, or `{auto: true}` to match by its description again | the pull request |
| `GET /v1/admin/stats` | | `{users, pro, newThisWeek, codes, redeemed, feedback, adopted, pullRequests, pullRequestsUnmatched, activeToday}` |

Codes are case-insensitive and ignore spaces and dashes. O reads as 0, and I and L read as 1. Generated codes look
like `7KQ2-M9XD-4TRB-WN3H`.

Example:

```sh
curl -X POST https://yingxia-accounts.getmegaportal.com/v1/admin/codes \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"count": 10, "days": 30, "batch": "2026-11 giveaway"}'
```

## The app's API

- `POST /v1/auth/apple`: `{identityToken, authorizationCode, name, install, platform}` → `{token, account}`.
- `POST /v1/auth/telegram`: `{install, platform}` → `{code, url, expires}`.
- `POST /v1/auth/telegram/poll`: `{code}` → 202 while waiting, then `{token, account}`.
- `GET /v1/me` → the account. `DELETE /v1/me` deletes it.
- `POST /v1/me/day`: the app is open today → `{counted, account}`. The app sends it once a day when it becomes active.
- `POST /v1/me/redeem`: `{code}` → `{days, account}`. On a 404 or 409 the reason is `not_found`, `revoked`,
  `expired`, `used_up` or `already_redeemed`.
- `POST /v1/sign-out`.

Every one of these needs `Authorization: Bearer <session token>`, except starting a sign-in.

## Test

`test/run.sh` runs the Worker on `wrangler dev` against a throwaway local D1, with stand-ins for Apple, Telegram and
GitHub, and checks about 60 cases end to end.

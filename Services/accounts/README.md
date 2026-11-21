# Yingxia accounts

Worker `yingxia-accounts` at `https://yingxia-accounts.getmegaportal.com`, with its own D1 database `yingxia-accounts`.
It does four things:

- **Sign-in.** Sign in with Apple, where the build has the entitlement, and Telegram through a bot, which works on
  every device; Apple TV shows a QR code. One person can add both.
- **Feedback that counts.** Feedback sent from Settings › Send Feedback while signed in counts for the person. So does
  feedback the same install sent in the 30 days before it signed in. GitHub decides whether a message was
  **adopted** (labeled `fixed`, or closed as completed) or declined (closed as not planned, or labeled
  `duplicate`, `invalid`, `wontfix` or `spam`). Points = sent × `POINTS_SENT` + adopted × `POINTS_ADOPTED`.
  `REWARD_DAYS` > 0 also gives that many Pro days for each adopted message, once per issue.
- **Pro.** Pro comes from redeem codes made by the admin pages. People redeem them in the app (Settings › Account) or
  with the Telegram bot (`/redeem CODE`). Pro also comes from rewards, or from the admin by hand. The app keeps an
  Ed25519-signed entitlement, so Pro also works offline. App Store and TestFlight builds never show Pro or the code
  field (App Review guideline 3.1.1).
- **An admin API** for the admin pages, described below.

The app's side is `Sources/TVCore/Account.swift`, `App/AccountStore.swift` and `App/AccountView.swift`.

It reads (never writes) the error-reports database `yingxia-reports`, whose `feedback` table ties issue numbers to
installs. That table keeps rows for 30 days only, so a job every 15 minutes copies the rows of signed-in installs
here and asks GitHub what became of their issues.

## Setup (once)

From this folder, with `W=../../website/node_modules/.bin/wrangler`:

1. `$W d1 create yingxia-accounts`. Put its id in `wrangler.jsonc`, then run
   `$W d1 execute yingxia-accounts --remote --file schema.sql`.
2. Create the bot with @BotFather (`/newbot`). Put its username, without the @, in `TELEGRAM_BOT` in `wrangler.jsonc`.
3. Add the secrets:
   - `$W secret put TELEGRAM_BOT_TOKEN`: the token BotFather gave.
   - `$W secret put TELEGRAM_WEBHOOK_SECRET`: any random string, e.g. `openssl rand -hex 24`.
   - `$W secret put ADMIN_TOKEN`: a long random string the admin pages send.
   - `$W secret put ENTITLEMENT_KEY < ~/.config/yingxia/accounts-entitlement.key`: on the M5. Its public half is
     `ProEntitlement.publicKey` in `Sources/TVCore/Account.swift`. If you replace the key, change both.
   - `$W secret put GITHUB_TOKEN`: read access to the issues of jo32/tvbox-silicon is enough. The error-reports token
     works too.
   - Optional: `APPLE_KEY_ID` and `APPLE_PRIVATE_KEY`, a Sign in with Apple key (.p8) from the developer site. With
     them, deleting an account also revokes the person's Apple sign-in, as App Review asks.
4. `$W deploy`
5. Point the bot at the Worker:
   `curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" https://yingxia-accounts.getmegaportal.com/v1/admin/telegram/setup`
6. `curl https://yingxia-accounts.getmegaportal.com/v1/health` should show `true` for everything you set.

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
| `GET /v1/admin/stats` | | `{users, pro, newThisWeek, codes, redeemed, feedback, adopted}` |
| `POST /v1/admin/telegram/setup` | | Telegram's answer to setWebhook |

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
- `POST /v1/me/redeem`: `{code}` → `{days, account}`. On a 404 or 409 the reason is `not_found`, `revoked`,
  `expired`, `used_up` or `already_redeemed`.
- `POST /v1/sign-out`.

Every one of these needs `Authorization: Bearer <session token>`, except starting a sign-in.

## Test

`test/run.sh` runs the Worker on `wrangler dev` against a throwaway local D1, with stand-ins for Apple, Telegram and
GitHub, and checks about 60 cases end to end.

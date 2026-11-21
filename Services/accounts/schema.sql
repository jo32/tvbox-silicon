-- Yingxia accounts (Services/accounts): who signed in, where from, their feedback's fate and their Pro time.
-- Apply: wrangler d1 execute yingxia-accounts --remote --file schema.sql

-- One person. pro_until is unix seconds; LIFETIME (year 9999) for a lifetime code; null for never Pro.
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,          -- u_ + 20 random characters
  created INTEGER NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  pro_until INTEGER
);

-- How they sign in: Apple's `sub` or a Telegram user ID. One person can have both.
CREATE TABLE IF NOT EXISTS identities (
  provider TEXT NOT NULL,       -- apple, telegram
  subject TEXT NOT NULL,
  user_id TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '', -- what the app shows: an email, @username or a name
  refresh TEXT,                 -- Apple's refresh token, revoked when the account is deleted
  client TEXT,                  -- the bundle ID Apple's token was issued to
  created INTEGER NOT NULL,
  PRIMARY KEY (provider, subject)
);
CREATE INDEX IF NOT EXISTS identities_user ON identities(user_id);

-- Signed-in apps. Only the SHA-256 of the token is kept.
CREATE TABLE IF NOT EXISTS sessions (
  hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  install TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL DEFAULT '',
  created INTEGER NOT NULL,
  used INTEGER NOT NULL,
  expires INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);

-- The app's random install ID (the one error reports and feedback carry), once it has signed in.
CREATE TABLE IF NOT EXISTS installs (
  install TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  platform TEXT NOT NULL DEFAULT '',
  linked INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS installs_user ON installs(user_id);

-- A Telegram sign-in waiting for the bot to see /start <code>.
CREATE TABLE IF NOT EXISTS telegram_logins (
  code TEXT PRIMARY KEY,
  install TEXT NOT NULL DEFAULT '',
  platform TEXT NOT NULL DEFAULT '',
  created INTEGER NOT NULL,
  link_user TEXT,               -- someone already signed in, adding Telegram to their account
  user_id TEXT                  -- set by the bot
);

-- Feedback issues of signed-in installs, copied from the error-reports database (which forgets them after
-- 30 days), and what became of each on GitHub.
CREATE TABLE IF NOT EXISTS feedback_issues (
  issue INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL,
  install TEXT NOT NULL,        -- the app's install ID, or 'telegram' for /feedback in the Telegram group
  sent INTEGER NOT NULL,        -- unix seconds
  status TEXT,                  -- open, fixed, adopted, closed, declined, duplicate; null until read from GitHub
  title TEXT NOT NULL DEFAULT '',
  updated INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS feedback_issues_user ON feedback_issues(user_id);

-- Redeem codes made by the admin pages (POST /v1/admin/codes). Only the hash of the code is kept.
CREATE TABLE IF NOT EXISTS codes (
  id TEXT PRIMARY KEY,          -- c_ + 12 random characters
  hash TEXT NOT NULL UNIQUE,    -- SHA-256 of the normalized code
  hint TEXT NOT NULL,           -- its last four characters, for the admin pages
  batch TEXT NOT NULL DEFAULT '',
  note TEXT NOT NULL DEFAULT '',
  days INTEGER,                 -- Pro days it gives; null = lifetime
  max_uses INTEGER NOT NULL DEFAULT 1,
  used INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,
  expires INTEGER,              -- can't be redeemed after this (unix seconds)
  revoked INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS codes_batch ON codes(batch);

-- Every time someone got Pro time: a code, a reward for adopted feedback, or the admin by hand.
CREATE TABLE IF NOT EXISTS grants (
  id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL,
  kind TEXT NOT NULL,           -- code, reward, admin
  ref TEXT NOT NULL,            -- the code's id, issue:<n>, or the admin's note
  days INTEGER,                 -- null = lifetime
  via TEXT NOT NULL DEFAULT '', -- app, telegram, admin, github
  at INTEGER NOT NULL,          -- unix milliseconds
  UNIQUE (kind, ref, user_id)
);
CREATE INDEX IF NOT EXISTS grants_user ON grants(user_id);
CREATE INDEX IF NOT EXISTS grants_ref ON grants(kind, ref);

-- Where the copy jobs left off.
CREATE TABLE IF NOT EXISTS marks (
  name TEXT PRIMARY KEY,
  value INTEGER NOT NULL
);

-- Points (src/points.ts). A day the app was open while signed in: one point each. Days start at midnight UTC+8.
CREATE TABLE IF NOT EXISTS active_days (
  user_id TEXT NOT NULL,
  day INTEGER NOT NULL,         -- days since 1970-01-01 in UTC+8
  install TEXT NOT NULL,
  PRIMARY KEY (user_id, day)
);
-- Which account each install gave its day to: one only, so one device can't earn for many accounts.
CREATE TABLE IF NOT EXISTS install_days (
  install TEXT NOT NULL,
  day INTEGER NOT NULL,
  user_id TEXT NOT NULL,
  PRIMARY KEY (install, day)
);

-- Merged pull requests by other people (src/prs.ts), and the account each counts for.
CREATE TABLE IF NOT EXISTS pull_requests (
  number INTEGER PRIMARY KEY,
  author TEXT NOT NULL,         -- GitHub login
  author_id INTEGER NOT NULL,   -- GitHub user ID (a login can be renamed)
  title TEXT NOT NULL DEFAULT '',
  merged INTEGER NOT NULL,      -- unix seconds
  claim TEXT NOT NULL DEFAULT '', -- what its description names: an account ID, @telegram or an email
  user_id TEXT,                 -- who it counts for; null until someone matches
  how TEXT NOT NULL DEFAULT '', -- id, telegram, email, github (the author's remembered account) or admin
  excluded INTEGER NOT NULL DEFAULT 0 -- labeled no-points, or excluded by the admin
);
CREATE INDEX IF NOT EXISTS pull_requests_user ON pull_requests(user_id);

-- GitHub users whose merged pull requests count for an account: learned from a matched claim, or set by the admin.
CREATE TABLE IF NOT EXISTS github_logins (
  login_id INTEGER PRIMARY KEY,
  login TEXT NOT NULL,
  user_id TEXT NOT NULL,
  how TEXT NOT NULL
);

-- Points the admin added or took away by hand.
CREATE TABLE IF NOT EXISTS point_adjustments (
  id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL,
  points INTEGER NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  at INTEGER NOT NULL           -- unix seconds
);
CREATE INDEX IF NOT EXISTS point_adjustments_user ON point_adjustments(user_id);

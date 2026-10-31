-- One row per error group per upload; the app has already summed repeats into `count`.
CREATE TABLE IF NOT EXISTS reports (
  id INTEGER PRIMARY KEY,
  received INTEGER NOT NULL,   -- unix seconds
  install TEXT NOT NULL,       -- random per install, nothing else identifies it
  platform TEXT NOT NULL,      -- macos, ios, tvos
  os TEXT NOT NULL,
  model TEXT NOT NULL DEFAULT '',  -- hardware model, e.g. AppleTV14,1 (added 2026-10-16: migrations/0002)
  lang TEXT NOT NULL DEFAULT '',   -- the app's language
  app TEXT NOT NULL,
  build TEXT NOT NULL,
  country TEXT NOT NULL,
  signature TEXT NOT NULL,     -- groups one bug across installs and versions
  category TEXT NOT NULL,
  message TEXT NOT NULL,
  count INTEGER NOT NULL,
  first INTEGER NOT NULL,
  last INTEGER NOT NULL
);
-- The only index: each one costs a write per row.
CREATE INDEX IF NOT EXISTS reports_received ON reports(received);

-- Feedback sent from Settings, one row per GitHub issue: caps how much one install (and everyone)
-- can post a day, and ties an issue to the install's error reports. Kept 30 days like the reports.
CREATE TABLE IF NOT EXISTS feedback (
  id INTEGER PRIMARY KEY,
  received INTEGER NOT NULL,   -- unix seconds
  install TEXT NOT NULL,
  platform TEXT NOT NULL,
  app TEXT NOT NULL,
  issue INTEGER NOT NULL       -- the GitHub issue number
);
CREATE INDEX IF NOT EXISTS feedback_received ON feedback(received);

-- Pictures, videos and logs uploaded with feedback (/v1/feedback/uploads), one row per file in the FILES
-- bucket: caps how much one install (and everyone) can upload a day, and ties each file to its issue.
-- Rows go after 30 days; a file no message took goes (with its row) after a day, a log after 30 days.
CREATE TABLE IF NOT EXISTS uploads (
  id TEXT PRIMARY KEY,         -- random, also the file's name
  received INTEGER NOT NULL,   -- unix seconds
  install TEXT NOT NULL,
  kind TEXT NOT NULL,          -- image, video or log
  type TEXT NOT NULL,          -- its content type
  size INTEGER NOT NULL,       -- bytes
  key TEXT NOT NULL,           -- where it is in the bucket
  issue INTEGER                -- the GitHub issue it went with; null until the message is sent
);
CREATE INDEX IF NOT EXISTS uploads_received ON uploads(received);

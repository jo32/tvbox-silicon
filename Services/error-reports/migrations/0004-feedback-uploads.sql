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

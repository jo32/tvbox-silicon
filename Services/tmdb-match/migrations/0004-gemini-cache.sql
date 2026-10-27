-- Gemini context caches of the agent's prefix, and how many of a run's tokens came from one.
CREATE TABLE IF NOT EXISTS gemini_cache (
  version TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  expires INTEGER NOT NULL
);
ALTER TABLE matches ADD COLUMN cached_tokens INTEGER NOT NULL DEFAULT 0;

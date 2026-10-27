-- One answer per source title (key = version|title|year|type, see cacheKey in src/index.ts), shared by every viewer.
CREATE TABLE IF NOT EXISTS matches (
  key TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  year TEXT,
  type TEXT,
  status TEXT NOT NULL,          -- matched | ambiguous | notFound
  media_type TEXT,               -- tv | movie, when matched
  tmdb_id INTEGER,
  season INTEGER,
  numbering TEXT NOT NULL,       -- season | absolute
  episode_offset INTEGER NOT NULL DEFAULT 0, -- TMDB episodes before the source's first, when TMDB merges two seasons into one
  confidence REAL NOT NULL,
  unmatched TEXT NOT NULL,       -- words of the source title outside the TMDB name, e.g. 第四季
  reason TEXT NOT NULL,          -- the model's one-line reason, for checking answers by hand
  candidates TEXT NOT NULL,      -- JSON: cards of the other plausible works
  model TEXT NOT NULL,
  turns INTEGER NOT NULL,
  requests INTEGER NOT NULL,     -- TMDB requests the run made
  tokens INTEGER NOT NULL,
  cached_tokens INTEGER NOT NULL DEFAULT 0, -- of those, read from Gemini's context cache (a tenth of the price)
  millis INTEGER NOT NULL,
  created INTEGER NOT NULL,
  expires INTEGER NOT NULL,
  hits INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS matches_expires ON matches (expires);

-- Agent runs per UTC day, against DAILY_RUNS.
CREATE TABLE IF NOT EXISTS usage (
  day TEXT PRIMARY KEY,
  runs INTEGER NOT NULL DEFAULT 0
);

-- Source videos found to be a TMDB work, for the reverse lookup (GET /v1/sources): one row per source video.
-- via: agent (a matched answer) or viewer (picked in the app); an agent answer never replaces a viewer's pick.
CREATE TABLE IF NOT EXISTS links (
  source TEXT NOT NULL,          -- the source's key in the subscription
  item TEXT NOT NULL,            -- the video's ID on that source
  source_name TEXT NOT NULL,
  title TEXT NOT NULL,
  year TEXT,
  media_type TEXT NOT NULL,
  tmdb_id INTEGER NOT NULL,
  season INTEGER,
  via TEXT NOT NULL,
  seen INTEGER NOT NULL,
  PRIMARY KEY (source, item)
);
CREATE INDEX IF NOT EXISTS links_work ON links (tmdb_id, media_type, seen DESC);

-- Gemini context caches of the agent's prefix (instructions and tools), by a hash of the prefix and model.
CREATE TABLE IF NOT EXISTS gemini_cache (
  version TEXT PRIMARY KEY,
  name TEXT NOT NULL,            -- cachedContents/…
  expires INTEGER NOT NULL
);

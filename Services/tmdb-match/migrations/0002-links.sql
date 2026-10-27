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

-- TMDB episodes before the source's first one, when TMDB lists two broadcast seasons as one (青之箱 第二季 = S1E26–).
ALTER TABLE matches ADD COLUMN episode_offset INTEGER NOT NULL DEFAULT 0;

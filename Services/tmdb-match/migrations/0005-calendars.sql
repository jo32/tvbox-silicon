-- The week's airing calendars (GET /v1/calendar), one per kind and language (anime: '*'), rebuilt every few hours.
CREATE TABLE IF NOT EXISTS calendars (
  kind TEXT NOT NULL,            -- anime | tv
  language TEXT NOT NULL,
  source TEXT NOT NULL,          -- bangumi | anilist | bangumi-data | tmdb | tvmaze
  built INTEGER NOT NULL,
  body TEXT NOT NULL,            -- JSON, as served
  PRIMARY KEY (kind, language)
);

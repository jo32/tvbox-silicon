# Apple Music

Apple Music's catalog for the app's music pages, as `yingxia-tmdb` is TMDB's: Worker `yingxia-music` at
https://yingxia-music.getmegaportal.com. It holds the MusicKit private key, so viewers need no Apple Music
subscription and see no permission prompt, and the key never ships in the app. The app's side is
`Sources/TVCore/AppleMusicCatalog.swift`; nothing there is needed to play music.

## Questions

All `GET`, all answering JSON with one key whose value is `null` when the catalog has nothing that fits.
`storefront` is one of `cn tw hk mo sg jp us gb` (default `cn`); the app sends `cn` for Simplified Chinese, `tw`
for Traditional, `jp` for Japanese and `us` otherwise.

- `/v1/identify?title=&artist=&duration=` → `{song}`: the catalog song with that title (versions in brackets set
  aside), one of the artists (`artist` may repeat), and a length within max(4 s, 3%) when `duration` is given.
  Used for a TVBox source's song (#491): its file name is read as title and artist, and the Apple Music song
  found gives the names and length QQ Music and NetEase lyrics are then matched by.
- `/v1/artist?name=` → `{artist}`: the search result with exactly that name, with genres, picture, notes, its
  top 10 songs (which the artist page lists first) and up to 20 albums.
- `/v1/album?title=&artist=` → `{album}`: notes, label, release date, genres, copyright and tracks (with ISRCs).

A song has `id title artist artists album duration isrc released genres artwork url`; `artwork` is Apple's template
with `{w}x{h}` for the size. Notes are plain text (Apple's HTML removed).

## Limits and caching

- Every answer, found or not, is kept at the edge for a day (`caches.default`), as are Apple's own answers
  (`src/apple.ts`), so the same question from many viewers costs Apple one request a day per data center.
- Questions not already kept are limited to 60 a minute per IP address (`LIMITER`).
- Inputs are bounded: 200 characters per field, at most 4 artists, a duration under 6 hours.

## Key and deploy

The developer token is an ES256 JWT (`src/token.ts`) signed with a MusicKit key: in the Apple Developer site,
Identifiers → Media IDs (MusicKit on), then Keys → a key with Media Services (MusicKit). It lasts 30 days and is
made again in each isolate a day before it ends.

```
wrangler secret put MUSICKIT_KEY        # the whole AuthKey_XXXXXXXXXX.p8 text
wrangler secret put MUSICKIT_KEY_ID     # XXXXXXXXXX
wrangler secret put APPLE_TEAM_ID
wrangler deploy
```

Without the secrets every question answers 503 and the app shows its pages as before.

Tests: `node --test test/*.test.ts` (Apple's answers are stubbed).

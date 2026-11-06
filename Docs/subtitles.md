# External subtitles (#576, M1 and M2)

What the first subtitle milestone does, the decisions behind it, and what it leaves for later. The full plan is
issue #576. The other subtitle issues stay open until each is checked: #496, #319, #429/#547, #407/#414.

## Decision: one model, two outputs

- **The item's own subtitles stay AVPlayer's.** This covers the subtitles inside an MP4 or HLS stream, and the
  tracks the repackager makes from a file (`Remux`). AVPlayer draws them in Picture in Picture. On screen, the app
  draws them in the chosen style (`SubtitleCues`, #547).
- **Subtitle files the app fetches itself go to the overlay** (`ExternalSubtitles` → `SubtitleCues.show`). These
  are a source's `subs` beside a video AVPlayer plays directly (an MP4, an HLS stream, a cloud file), and any file
  the viewer adds while watching. The app reads them into a `SubtitleDocument`. The player's clock (a 50 ms periodic
  observer, running only while a file shows) picks the lines through `SubtitleTiming`:
  `display = source × scale + delay`. Before this, those files were dropped on every path except the repackager.
- **The two never show at once.** Choosing a file turns the item's own subtitles off. Choosing one of the item's
  own (in our menu or in AVKit's) puts the file away.
- **Why not wrap every stream in a local HLS master with a WebVTT group?**
  - AirPlay receivers can't reach the device's loopback.
  - A direct MP4 can't be a variant of an HLS master, so it would have to be repackaged just for its subtitles.
  - FairPlay and signed-key streams would need their key loading kept intact.
  - Changing a file during playback would mean rebuilding the item.

  The overlay avoids all of that. It costs Picture in Picture, so the trade-off is in the matrix below.

## Support matrix

| Path | Source's subtitle files | Added by the viewer | PiP | AirPlay |
|---|---|---|---|---|
| Direct MP4 / MOV | Overlay (new) | Overlay | Files not shown | Not shown on the receiver |
| Remote HLS | Overlay (new) | Overlay | Files not shown | Not shown on the receiver |
| MKV/AVI/FLV → repackaged HLS | WebVTT tracks of the stream, as before. Files later than 2 s after the file opens go to the overlay | Overlay | Tracks: yes; files: no | Repackaged streams don't AirPlay (loopback) |
| Cloud drive (CloudStreams) | Overlay | Overlay | Files not shown | Not shown on the receiver |
| DRM / FairPlay | Not touched: no wrapping, no key handling changes | Overlay | Files not shown | Not shown on the receiver |

Not verified on hardware yet: AirPlay video to an Apple TV with a file showing. The overlay stays on the phone, so
the receiver shows no file subtitles.

## What M1 includes

- **Formats.** SRT, WebVTT, ASS and SSA. ASS/SSA is read as plain text, and the menu says so: "ASS styling and
  effects show as plain text."
- **Text encoding.**
  - Automatic: byte order mark, then UTF-8, then Shift-JIS when a fifth of the letters are kana, then GB 18030,
    then Big5.
  - The viewer can override it from the menu: UTF-8, GB 18030, Big5, Shift-JIS, UTF-16 LE or BE.
- **Downloads.**
  - The 8 MiB cap is checked while the bytes arrive, not after (`SubtitleFile.download`). A Content-Length over
    the cap is refused before the body.
  - At most 8 files per episode, 3 at a time, with an 8 s timeout each.
  - Request headers are the video's, never sent to a loopback proxy.
- **Matching files to the video** (`SubtitleMatch`).
  - A drive plugin sends every subtitle in the folder. A file naming a different episode (S01E02, 1x02, EP02,
    第2集, [02]) is left out. Files with no episode number stay.
  - The closest name goes first, and the language comes from the name (chs, cht, eng, 简体, …).
  - The best match comes on by itself, unless the video already shows its own subtitles.
- **Startup.**
  - Files load after the picture starts.
  - The repackager waits at most 2 s past the file opening instead of up to 8 s (`Remux.subtitleGrace`).
  - A file that fails shows its reason in the menu and can be tried again. It never stops the video.
- **Timing.**
  - Delay of ±30 s in 0.5 s steps: earlier as well as later, since the whole file is at hand.
  - Frame-rate correction for 23.976 ↔ 24 ↔ 25.
  - Both are remembered per show (`SubtitleTimingStore`, the last 200 shows). Reset clears it.
- **Adding a file.**
  - iPhone, iPad and Mac: a file panel, or an http(s) address.
  - Mac: drop a file on the player window.
  - Apple TV: the source's files only, picked in the transport bar's Subtitle Files menu. There is no file panel
    on tvOS.
- **WebVTT segments** (`RemuxPlan.cues(_:segment:)`). Each segment now carries every cue that shows during it, with
  its full timing, per RFC 8216 §3.5. A seek into the middle of a long line used to lose it.

## M2: subtitle sources

Subtitle sources are services the viewer turns on in Settings › Subtitle Sources. **Search Online** in the player's
subtitle menu asks them for the playing video. Two come with the app, both off until the viewer gives a key:

- **OpenSubtitles**: REST API, an API key, and optionally a user name and password for the larger download quota.
  Pitfall: the API redirects (301) unless the query parameters are sorted by name and lowercase.
- **射手网 (Assrt)**: an API token. The quota is per account: 20 requests a minute in its docs, but new
  accounts have been seen with 5. A result is an upload, often a whole season, and
  `resolve` picks the episode's file from its file list.

More can be added as scripts by address.

### The contract (`SubtitleProvider`, protocol version 1)

A source is a classic script run on its own QuickJS runtime. The TVBox prelude runs first, then
`assets://subtitles/prelude.js`, then the script. The script sets:

```js
const subtitleSource = {
  manifest: { schema: 1, id: 'example', name: 'Example', version: '1', minimumHost: 1,
              domains: ['api.example.com'], languages: ['en'],
              credentials: [{ key: 'apiKey', title: 'API Key', secret: true, required: true, note: '…' }],
              homepage: 'https://example.com/keys' },
  async search(hint, context) { return [{ id, title, language, format, forced, hearingImpaired,
                                          season, episode, fileMatch, downloads, url, token }]; },
  async resolve(candidate, context) { return { url, headers, name, format, expires } /* or { text, name, format } */; },
};
```

- `hint` is `{ title, year, season, episode, imdbID, tmdbID, fileName, languages }`. The languages are BCP-47,
  most wanted first.
- `context` is `{ credentials, languages }`.
- `candidate` is the result as the app keeps it. `key` is the source's `id`, and `token` is whatever the source
  attached.
- A failure is `throw new SubtitleError(kind, message, retryAfter)`. The kind is one of: `timeout`, `rateLimited`,
  `noResults`, `authRequired`, `authExpired`, `incompatible`, `downloadFailed`, `blocked`, `failed`.
  `SubtitleError.from(response)` maps the usual HTTP statuses.
- A manifest with another `schema` or a later `minimumHost` is refused when the source is added or loaded, with
  `incompatible`. Nothing of it runs.

### Sandbox

- Requests go through `$http.get/post/request`, and only to the manifest's `domains` and their subdomains. The host
  checks every request (`SubtitleHost`). It never follows a redirect itself: the prelude follows each hop, so each
  hop is checked again. An address outside the list fails with `blocked`.
- The address `resolve` gives is checked against the same list before the app downloads it.
- These are gone from the script's globals: `__host`, `req`, `fetch`, `http`, `local` (the plain-text store), and
  the proxy helpers. `import()` of anything but the app's own modules is refused (`allowsRemoteModules`).
- `console` is silent. The diagnostics log records each call's source id, its duration, the result count and the
  error kind. It never records a message, an address, a key or a line of subtitles.
- Keys are kept in the Keychain, one item per source, this device only, readable after the first unlock. They are
  handed to each call and never stored by the script.

### Search (`SubtitleSearch`)

- At most 3 sources are asked at once. Each gets 3 s, and the whole search ends at 3 s whatever is still out.
  A source that is still running is abandoned, not waited for (`SubtitleSearch.race`). Each source's results
  appear as soon as it answers.
- A source missing a required key isn't asked. It shows "Add your key…" instead.
- At most 20 results are kept per source.
- Results for another episode are dropped. The rest are ranked:
  - +100: same file (`fileMatch`)
  - +40: this episode
  - +30 down to +10: the viewer's languages in order; another language is −20
  - +20: release-name similarity of 0.6 or more (Jaccard)
  - up to +10: popularity
  - −10: forced; −3: SDH

  The reasons appear as tags on each result.
- Two results are one when they are the same file (the same address with its signing parameters removed, or the
  same SHA-256 once downloaded) *and* the same language, version (release name), forced flag and SDH flag. A
  different version or flag stays a separate result.
- Caches are isolated per source and per account (a hash of the source id and the viewer's values):
  - Search results are kept for 30 minutes, in memory.
  - Downloaded files are kept on disk up to 100 MiB, least recently used dropped first.
  - Changing a key forgets that source's results.
- An address that has expired (`expires`), or that the server refuses with 401, 403 or 410, is resolved once more.

### Where it shows

- iPhone, iPad, Mac: Search Online… in the Subtitles menu opens a sheet. Title, season and episode can be edited.
  The sheet shows each source's progress and the results, best first. Choosing one downloads it and shows it like
  any added file (timing, encoding and frame rate apply).
- Apple TV: the Subtitle Files menu has an Online section. It has Search Online, the top 12 results as they come in,
  each source's failure, and Search Again. There is no editing the search with the remote.

## Left for later (plan milestones)

- M1 leftovers:
  - ZIP archives.
  - A URL or remote-input path for adding files on tvOS.
  - Listing sibling files in the in-app Cloud Files browser. Plugin `subs` already cover drive folders.
  - Seek-proof cross-segment cues for a file's own embedded subtitles. FFmpeg still places those by start time.
- M2 leftovers:
  - Hashing the video file for OpenSubtitles' `moviehash` (needs the first and last 64 KiB, which a stream doesn't
    give cheaply). Results already carry `fileMatch` for when it is added.
  - TMDB/IMDb ids in the search hint. The catalog's TMDB match isn't passed to the player yet.
  - Archives from a source (Assrt uploads that are only a ZIP or RAR).
  - Verifying the two built-in sources with real keys. Both endpoints answered as documented without one (403
    "You cannot consume this service" and status 20001 "invalid token"), nothing more.
- M3: libass and bitmap (PGS/VobSub) rendering.
- M4: cloud translation.
- M5: on-device speech recognition.

## Tests

- `SubtitleDocumentTests` covers:
  - overlapping and long cues
  - ASS as plain text
  - size and empty files
  - Shift-JIS, GB 18030 and Big5 detection and override
  - the delay and scale maths
  - per-show storage
  - episode parsing and matching
  - the streaming size cap and HTTP errors
- `RemuxTests.subtitleFilesJoinThePlan` covers cues crossing segment boundaries.
- `SubtitleProviderTests` (M2) covers:
  - manifest validation and domain matching
  - hints from catalog names and languages
  - the script contract against a fixture source (`Fixtures/subtitle-source.js`)
  - the sandbox: no `__host`, `req` or `local`, blocked hosts and look-alikes, no remote `import()`
  - every error kind, including a per-call timeout after which the runtime still answers
  - refusing incompatible scripts
  - the built-in sources' manifests and the library
  - three-at-a-time scheduling with partial results
  - the overall deadline with a source that ignores cancellation
  - ranking, dedupe and episode filtering
  - per-account caches
  - the download cache with re-resolve of expired addresses
  - the LRU limit

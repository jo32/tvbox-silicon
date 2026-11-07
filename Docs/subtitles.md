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
  - Apple TV: the source's files, picked in the transport bar's Subtitle Files menu, or an address typed there
    (M1b, below). There is no file panel on tvOS.
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

- `hint` is `{ title, year, season, episode, imdbID, tmdbID, fileName, languages, movieHash, fileSize }`. The languages are BCP-47,
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

## M1b: the M1 and M2 leftovers

### ZIP archives (`SubtitleArchive`)

- A ZIP is accepted wherever a subtitle file is: the file panel and a dropped file (iPhone, iPad, Mac), an address
  (every platform), a source's `subs`, a Cloud Files folder, and a subtitle source's download (Assrt's season uploads).
- It is read in memory only, never unpacked to disk. Apple's Compression framework inflates it (raw DEFLATE, ZIP
  method 8; stored files too). No third-party code was added.
- The whole directory is checked before anything is inflated. Any of these refuses the archive:
  - the archive over 8 MiB; more than 500 entries; ZIP64
  - a path that is absolute, has a drive letter, a `..` part or a NUL
  - a subtitle file declaring more than 8 MiB, the subtitle files together more than 32 MiB, or a file over 64 KiB
    that claims more than 100 times its compressed size (a bomb; subtitles deflate 3 to 10 times)
- Each file then inflates on its own and stops the moment it passes the size its entry declared, so a directory that
  lies about sizes can't make it grow. The result must match the entry's CRC-32.
- Passed over: folders, `__MACOSX/` and `._` resource forks, files that aren't SRT, WebVTT, ASS or SSA, archives
  inside the archive (never opened), and password-protected files. An archive with nothing else left says why
  ("holds only other archives", "protected by a password", "no SRT, WebVTT or ASS files").
- Names without ZIP's UTF-8 flag are read as UTF-8, then GB 18030 (archives made on Chinese Windows), then Latin-1.
  Text inside goes through the usual encoding detection and the menu's override.
- Picking: the files that belong to the playing video (`SubtitleMatch`: other episodes left out, closest name first),
  at most 8. One file shows by itself. Several take the archive's place in the Subtitle Files list, and the list is
  the picker; the best one comes on as any file would. A season archive with no file for this episode says so.
- A subtitle source's archive shows the file for the result's season and episode.
- The repackager (MKV) leaves archives to the player's list rather than making one track of them.
- RAR and 7z are still refused, with a message saying only ZIP is read.

### Apple TV: adding by address

- The transport bar's Subtitle Files menu is always there now (except for live streams), with **Add Subtitles from
  Address…**. It opens a text field for an http(s) address of a subtitle file or a ZIP archive.
- The field takes the Siri Remote's keyboard and dictation, and tvOS offers a nearby iPhone's keyboard by itself
  (the "Apple TV keyboard" notification): that is the "send from iPhone" path, with no companion code of our own.
- An address that isn't one is said at once in an alert. A download that fails shows its reason in the menu.
- The field is a UIKit alert on the player controller, not a SwiftUI `.alert` (the tvOS 27 hang of #272 is in
  SwiftUI alerts on pushed pages).
- The transport bar's menu is still presented while its action runs, and UIKit refuses a second presentation then
  ("already presenting AVUnifiedPlayerContextMenuContainerViewController"; nothing showed). The alert, and the
  "Subtitles Not Added" notice after it, wait until nothing is over the player (`present(_:over:)`, up to 3 s).
- Leaving the keyboard with Menu drops what was typed (the UIKit alert's field); its **done** button keeps it.

### Cloud Files: the folder's subtitles

- Playing a video from Cloud Files (Quark, UC, 115, AList, WebDAV) offers the folder's SRT, WebVTT, ASS and SSA files
  and ZIP archives, as a drive plugin's `subs` are. `SubtitleMatch` leaves out other episodes' files and puts the
  closest name first; it comes on by itself unless the video shows its own subtitles.
- They are `tvbox-files:` addresses. `SubtitleFile.download` asks the drive for the file's link
  (`CloudFiles.source`) and fetches it with the drive's own headers, under the same 8 MiB cap.
- Continue Watching and favorites start a file before its folder is listed: the player lists the folder itself then
  and offers what it finds.
- `.sub`/`.idx` (VobSub) are not offered: they are pictures (M3).

### Embedded subtitles across segments

- Before: FFmpeg hands each subtitle packet to the segment it starts in, so a line from 3.5 s to 6 s was only in
  the segment before 4 s. A seek to 5 s showed nothing until the next line.
- Now the session keeps every embedded cue it has read, by track, and each subtitle segment carries all known cues on
  screen during it (`RemuxPlan.cues`, the same rule as files). Playing through, that is enough: the segment before
  is always read first.
- A seek lands in a segment whose predecessor was never read. With subtitles on (AVPlayer asked for a subtitle
  segment in the last 5 minutes), the session first reads the subtitle packets of the 6 s before the segment
  (`RemuxSession.lookBack`): the other tracks' packets are passed over unread and the cursor goes straight on into
  the segment, so there is no second seek. Its cost is the bytes of those 6 s; nothing is decoded.
- The C side also hands over a packet read before the segment's start that is still on screen at it.
- Lines longer than 6 s that began before an unread segment are still missed after a seek.

### The search hint

- **moviehash.** The playing file's OpenSubtitles hash (`SubtitleFileHash`: size plus the 64-bit words of the
  first and last 64 KiB). It is worked out once a subtitle source is on, in the background:
  - a download: read from disk
  - a repackaged file (MKV): through the repackager's own source
  - a cloud drive stream: two range requests to the drive's link, with its headers
  - a plain HTTP file: two range requests; a server that answers 200 instead of 206 is left at once
  - HLS and DASH: none

  A search waits at most 1.5 s for it. OpenSubtitles sends it as `moviehash`; results that match come back with
  `moviehash_match`, which ranks them first (`fileMatch`, +100).
- **TMDB.** The player is handed the video page's key in `TMDBMatchStore`. When the page kept a match, the hint gets
  its TMDB id, and for a series the season TMDB numbers it in (plus its episode offset). A film's hint drops season
  and episode. A series TMDB numbers across seasons (`absolute`) keeps the source's numbers. OpenSubtitles then
  searches by `tmdb_id` / `parent_tmdb_id`. A viewer's edit of the search is never overwritten.
- **IMDb.** Not filled: the TMDB Worker's answer has no IMDb id. Adding `external_ids` to the Worker would.

### Support matrix additions

| Path | ZIP | Folder siblings | Added on Apple TV | Seek into a long embedded line |
|---|---|---|---|---|
| Direct MP4 / MOV, remote HLS | Overlay, list as picker | n/a | Address | n/a (no embedded text) |
| MKV/AVI/FLV → repackaged HLS | Overlay (not a stream track) | Plugin `subs`, Cloud Files | Address | Yes, up to 6 s before the segment |
| Cloud Files video | Overlay | Yes | Address | Yes for MKV |
| Subtitle source result | Its episode's file | n/a | Search Online | n/a |

### QA (simulators)

- `-qaWebDAVServer <address>` adds that WebDAV share before launch, so `-qaPage play-file:alist:<folder>` plays a
  video from it as Cloud Files does. A local share for this is any server that answers PROPFIND and ranged GET.
- Run 2026-11-08 on throwaway simulators (iPhone 17 Pro and Apple TV 4K, iOS/tvOS 27.2) against a local share holding
  generated files only:
  - iPhone, `-qaPlayURL …/Pack.S01E02.mp4 -qaSubtitleURLs …/Pack.S01.zip` (a ZIP of E01, `Season 1/` E02 chs and
    eng, a `__MACOSX` fork and a readme): the Subtitles menu lists the two E02 files, Chinese chosen and showing.
  - iPhone, Cloud Files folder `Show/` (`Show.S01E02.mp4`, `Show.S01E02.chs.srt`, `Show.S01E01.chs.srt`): the E02
    file comes on by itself; only it was downloaded.
  - Apple TV, Siri Remote driven by an XCUITest: Subtitle Files › Add Subtitles from Address…, typed the ZIP's
    address, Add: the menu then lists the two E02 files and the line shows. An address without a scheme shows
    "Subtitles Not Added".

### Not verified

- OpenSubtitles and Assrt with real keys, so `moviehash` matching and TMDB-id searches against the live API, and an
  Assrt season ZIP from the live service. No keys are available; the request shapes are unit-tested.
- A real Quark, UC or 115 folder: the sibling listing was run against a local WebDAV share only.
- An iPhone's keyboard typing into the Apple TV field (needs a real Apple TV and iPhone).

## Left for later (plan milestones)

- M1 and M2 leftovers still open:
  - RAR and 7z archives.
  - Embedded lines longer than the 6 s look-back, after a seek.
  - IMDb ids in the hint (the TMDB Worker doesn't return them).
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
- `RemuxTests.embeddedLinesCrossingSegmentsSurviveASeek` (M1b) asks for the second segment first, as a seek does, and
  finds a 0.5–6 s embedded line in it (`remux-crossing.mkv` is `remux-copy.mkv` with that line's BlockDuration
  raised to 5.5 s). It fails with the look-back turned off.
- `SubtitleArchiveTests` (M1b) writes its archives in the test, hostile ones included: single and season archives,
  GB 18030 names, size, total, ratio and lying-directory bombs, entry count, path traversal (`..`, absolute, drive
  letters, backslashes), nested and encrypted entries, CRC and truncation, and a source's season ZIP.
- `SubtitleHintTests` (M1b) covers the hash (known sums, wrap-around, disk vs repackager source vs two range
  requests, streams), the TMDB match in the hint, and a Cloud Files folder's subtitle files.
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

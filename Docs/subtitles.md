# External subtitles (#576, M1)

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

## Left for later (plan milestones)

- M1 leftovers:
  - ZIP archives.
  - A URL or remote-input path for adding files on tvOS.
  - Listing sibling files in the in-app Cloud Files browser. Plugin `subs` already cover drive folders.
  - Seek-proof cross-segment cues for a file's own embedded subtitles. FFmpeg still places those by start time.
- M2: subtitle-source plugins: `search` / `resolve`, aggregation, caching.
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

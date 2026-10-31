# MKV, AVI, FLV, WMV and RMVB playback

AVPlayer opens MP4, MOV, MPEG-TS and HLS only. Cloud drives and many sources hand out Matroska (MKV, WebM),
AVI, FLV, WMV/ASF, RealMedia and MPEG program streams, which used to fail ("This video is an MKV file") or fall
back to a drive's smaller transcoded copy. Yingxia now repackages them on the device, on iPhone, iPad, Apple TV
and Mac alike.

## Choice: repackage for AVPlayer, convert only what it can't decode

The file is read with FFmpeg and written out as HLS (fragmented MP4), which the existing `AVPlayer` plays from a
loopback server. Performance decided this over a second player such as KSPlayer's `KSMEPlayer` or VLCKit:

- **Copying costs almost nothing.** H.264, HEVC (8 and 10-bit, HDR10, HLG, Dolby Vision 5 and 8), AAC, AC-3,
  E-AC-3, FLAC and ALAC go into the MP4 fragments unchanged: no decoding, no new encoding, no quality loss. A
  12-second 640×360 MKV took 5 ms of CPU; a 3-minute FLV, 40 ms. Most MKV files are H.264/HEVC with AAC/AC-3/DTS.
- **The picture stays on Apple's hardware decoder** with AVPlayer's buffering, frame pacing, HDR and Dolby Vision
  output, picture in picture and Now Playing, and every player control, subtitle menu and history feature that
  already exists keeps working.
- **Only what Apple can't decode is converted**: VP9, VP8, MPEG-1/2/4 Part 2, WMV, RealVideo, VC-1, H.263,
  Theora, H.264 Hi10/4:2:2, AV1 without a hardware decoder (dav1d) → libavcodec decode, VideoToolbox H.264 (or HEVC 10-bit
  for deep or HDR pictures) hardware encode. DTS, TrueHD, Opus, Vorbis, MP3, MP2, WMA, PCM, Cook → AudioToolbox
  AAC (5.1 kept). MP3 and Opus are converted because AVPlayer refuses them inside fragmented MP4 HLS.
- **Small.** FFmpeg is built with only the demuxers, the MP4 muxer and those decoders (LGPL, no network, no
  filters; dav1d, BSD, for AV1): a static library per platform, built once into a shared cache by `Scripts/build-apple-ffmpeg.sh`.

KSPlayer (GPL) informed the design (its own order is AVPlayer first, FFmpeg player second). Its prebuilt GPL
binaries cover macOS, the iOS simulator and tvOS but not iPhones, and its FFmpeg player renders through Metal
outside AVPlayer, so every control would need a second implementation. VLCKit has the same cost.

## How it works

```
Cloud drive / HTTP / file ──bytes──▶ TVMedia (C, FFmpeg) ──fMP4──▶ RemuxServer (127.0.0.1) ──HLS──▶ AVPlayer
         CloudByteStream                RemuxSession thread            chunked responses
```

- **Detection** (`App/PlaybackView.swift`, `prepare`): a drive file by its first bytes (`Remux.handles`:
  EBML, `RIFF…AVI `, `FLV`, the ASF GUID, `.RMF`, an MPEG pack header); a link or saved file by its extension.
  Quark, UC and AList now hand over such originals instead of the transcoded copy (`CloudFile.playsOriginal`).
  If FFmpeg can't read a drive file, the old path still applies (another line, or the old message).
- **Bytes**: drive files reuse `CloudByteStream` (2 MB chunks, 6 parallel ranges, 8 chunks read ahead), without the
  `hev1` retagging meant for AVPlayer's own MP4 reading. Plain links get the same stream after a `Range: bytes=0-0`
  probe for the length. FFmpeg's synchronous reads block its own thread on the async reads.
- **Plan** (`RemuxPlan`, pure and unit-tested): which streams to copy or convert, the segments, the playlists, the
  codec strings (`avc1`/`hvc1`/`dvh1`/`av01` from the configuration boxes of the initialization segments),
  VIDEO-RANGE, languages (ISO 639-2 → BCP 47), and WebVTT subtitles.
- **Segments** run from keyframe to keyframe (at least 4 s) when the file's index lists them all (Matroska Cues,
  AVI idx1, ASF, RealMedia). Without a full index (FLV, MPEG, MKV without Cues) they are even (6–12 s, a GOP and a
  half); a copied one runs from its first keyframe to the next segment's, and a seek guesses a byte position from
  the bit rate and corrects it, instead of reading the file up to that time.
- **Production** (`RemuxSession`, `Sources/TVMedia/TVMedia.c`): one thread per file, one FFmpeg reader. A segment
  that follows the previous one goes on reading without a seek, so playing through reads the file once; packets
  past a segment's end wait for the next one. The picture, the audio AVPlayer plays and the subtitles come out of
  the same pass; another audio track is made when AVPlayer asks for it. The thread makes one segment ahead of
  AVPlayer when idle. A segment nobody waits for (AVPlayer moved on after a seek) is abandoned. Segments are
  kept within a memory budget (1/24 of RAM, 96–384 MB).
- **Timing**: copied video gets decode times rebuilt from presentation times (Matroska stores only those),
  copied audio is retimed by sample count (Matroska rounds to milliseconds), and every time is offset by 10 s so
  none is negative. Each fragment's decode time is its own (`frag_discont`), and each packet's duration is the gap
  to the next one, so segments made in any order join without gaps.
- **Serving** (`RemuxServer`): a per-launch token, `master.m3u8`, `<track>.m3u8`, `<track>.mp4` (initialization),
  `<track>-<segment>.m4s|vtt`. A segment is sent chunked while it is written, in fragments of about a second,
  so the first frame doesn't wait for the whole segment.
- **HDR on a display without it**: AVPlayer refuses every HDR variant of an HLS stream when
  `AVPlayer.eligibleForHDRPlayback` is false ("cannot be played on the device", CoreMedia -17223), although it tone
  maps the same picture in a plain file. There an HDR10 or HLG picture is converted: swscale's color management
  (`sws_scale_frame`, perceptual intent) maps it to 8-bit BT.709, and the playlist says SDR. Apple TVs and iPhones
  shrink it to 1080p first (4K costs about four times as much); Macs keep its size. Dolby Vision 5 stays as it is.
  Normally none of that runs on the CPU: VideoToolbox decodes the picture, a `VTPixelTransferSession` shrinks it
  and tone maps it to BT.709, and the encoder takes it from a VideoToolbox frame pool. An Apple TV 4K decoding and
  mapping 4K HEVC Main 10 in software ran below real time (6 to 12 s for each 6 s segment), so playback after a
  seek kept stopping. swscale is the fallback when VideoToolbox can't decode the picture or the transfer fails.
  An Apple TV can report HDR playback and still refuse the stream (-11868 with -17223): the player then opens the
  file again converted, and so are the files opened after it until the app quits (`Remux.refusesHDR`). A picture
  whose container has no colour tags (an x265 encode in MKV) is read from its first frame, so its HDR is known.
- **Subtitles**: SubRip, ASS/SSA, WebVTT and tx3g become WebVTT renditions (italics and bold kept, ASS styling and
  drawings dropped), placed with `X-TIMESTAMP-MAP`. Picture subtitles (PGS, VobSub) are not shown yet.

## Limits

- AirPlay video is off for a repackaged file (the receiver can't reach this device's loopback server); the
  picture stays on the device.
- Interlaced MPEG-2/VC-1 pictures are converted without deinterlacing.
- PGS and VobSub subtitles are skipped; ASS styling is reduced to plain text.
- Intel Macs convert without FFmpeg's assembly (no `nasm` on the build Mac); copying, the common case, needs none.
- Live FLV streams are not repackaged (they have no length); the existing live paths still handle them.

## Testing

`Tests/TVCoreTests/RemuxTests.swift` checks the plan, playlists, codec strings and subtitles, and plays two small
fixtures through the whole path (an H.264/AAC/AC-3/SRT MKV copied, an MPEG-4/MP3 AVI converted) until AVPlayer
reports them ready. During development every container above, HEVC 10-bit with E-AC-3 and DTS, VP9/Opus WebM,
Hi10 H.264 with FLAC, and 3-minute FLV and MKV without Cues were checked with ffprobe (no backward or missing
timestamps in any segment order) and played in AVPlayer with seeks and audio switches, without stalls.

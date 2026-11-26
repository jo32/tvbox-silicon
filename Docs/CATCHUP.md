# Provider-declared programme replay

An M3U channel with a supported `catchup-source` template and a program guide offers **Replay Programmes** in the channel list and the player's channel panel. Select a date, an available line and an ended programme. **Back to Live** explicitly returns to the original channel; reaching the end of a replay does not advance to another item.

The M3U header can supply defaults. Attributes on `#EXTINF` override them for that line, including alternate addresses of the same channel. `catchup="none"` or zero/negative `catchup-days` disables replay. A missing retention value allows the explicit template; the guide browses seven days by default, capped at 31 days for larger declared windows. The programme's start must still be inside its provider's retention when selected.

```m3u
#EXTM3U x-tvg-url="https://guide.example/tv.xml" catchup="append" catchup-days="3"
#EXTINF:-1 tvg-id="news" catchup-source="?start={utc}&end={utcend}" catchup-replace="/live/,/replay/",News
https://media.example/live/news.m3u8?signature=provider-value
```

`append` appends the rendered query to the live address, preserving its existing encoded query bytes and fragment. Its optional `catchup-replace="from,to"` performs a literal replacement only in the URL path, never in the host or signature query.

`default` (also used when mode is omitted) resolves the rendered `catchup-source` as an absolute or relative HTTP(S) address:

```m3u
#EXTINF:-1 catchup-source="/archive/{(b)yyyyMMddHHmmss}/{(e)yyyyMMddHHmmss}/news.m3u8" catchup-timezone="Asia/Shanghai",News
https://media.example/live/news.m3u8
```

Supported placeholders, with either `{…}` or `${…}` delimiters:

| Placeholder | Meaning |
| --- | --- |
| `utc`, `utc:timestamp`, `start` | Programme start, Unix seconds |
| `utcend`, `utcend:timestamp`, `end` | Programme end, Unix seconds |
| `duration` | Elapsed seconds between start and end |
| `(b)timestamp`, `(e)timestamp` | Start/end, Unix seconds |
| `(b)yyyyMMddHHmmss`, `(e)yyyy-MM-ddTHH:mm:ss` | Start/end formatted in `catchup-timezone` |

Date formats accept `yyyy`, `MM`, `dd`, `HH`, `mm`, `ss` and `- _ : . T /` separators only. `catchup-timezone` accepts an IANA zone, defaulting to UTC. Unix values are independent of zone. Unknown modes/placeholders, malformed escapes, invalid zones and oversized templates are unavailable rather than guessed.

XMLTV retains the declared history window, subject to what the guide actually supplies. DIYP retains its existing China-time semantics; previous days require `{date}` in the guide URL. An address without `{date}` is used for today only. A guide does not imply that its channels support replay, and recorded MP4/MKV files do not become replay sources because the M3U header declares catchup.

Replay channels carry an explicit finite-programme marker, programme times and original channel identity. That marker and each line's template survive channel/favorite serialization, including older favorites without these fields. Replay addresses can still expire according to the provider. This does not create a separate live-programme history library or catalog identity.

Validation helpers: `python3 Scripts/test-catchup.py`, `python3 Scripts/test-catchup-routing.py`, and `python3 Scripts/typecheck-catchup.py`. The first runs focused Swift Testing fixtures plus a local HTTP server, including signed requests and a cached guide whose history window expands. The second executes production Store/player callbacks. The third typechecks the actual replay UI and player entry points for iOS/tvOS 17 with SDK APIs; it does not build an application.

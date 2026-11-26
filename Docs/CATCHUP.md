# Replaying past programs (catchup)

An M3U channel with a supported `catchup-source` template and a program guide offers **Replay Programs**: in the channel list, and in the player's channel panel. Pick a day (and a line, when more than one declares catchup), then an ended program. **Back to Live** returns to the channel; the end of a replay doesn't move on to another item. On Apple TV the list is a page of its own in Live TV, and a strip in the player's Channel List tab.

The M3U header can supply defaults. Attributes on `#EXTINF` override them for that line, including alternate addresses of the same channel. `catchup="none"` or zero/negative `catchup-days` disables replay. A missing retention value allows the template; the guide keeps seven days by default, at most 31 for longer declared windows. The program's start must still be inside the retention when it's picked.

```m3u
#EXTM3U x-tvg-url="https://guide.example/tv.xml" catchup="append" catchup-days="3"
#EXTINF:-1 tvg-id="news" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}",News
https://media.example/live/news.m3u8?signature=provider-value
```

`append` adds the rendered query to the live address, keeping its existing encoded query bytes. Its optional `catchup-replace="from,to"` replaces text in the URL path only, never in the host or a signed query.

`default` (also when the mode is left out) resolves the rendered `catchup-source` as an absolute or relative HTTP(S) address:

```m3u
#EXTINF:-1 catchup-source="/archive/{(b)yyyyMMddHHmmss}/{(e)yyyyMMddHHmmss}/news.m3u8" catchup-timezone="Asia/Shanghai",News
https://media.example/live/news.m3u8
```

Supported placeholders, with `{…}` or `${…}` delimiters:

| Placeholder | Meaning |
| --- | --- |
| `utc`, `utc:timestamp`, `start` | Program start, Unix seconds |
| `utcend`, `utcend:timestamp`, `end` | Program end, Unix seconds |
| `duration` | Seconds from start to end |
| `(b)timestamp`, `(e)timestamp` | Start/end, Unix seconds |
| `(b)yyyyMMddHHmmss`, `(e)yyyy-MM-ddTHH:mm:ss` | Start/end as local time |

Date formats accept `yyyy`, `MM`, `dd`, `HH`, `mm`, `ss` and `- _ : . T /` separators only. Local time is the `catchup-timezone` (an IANA zone) when the playlist gives one, else the device's own time zone. Unix values don't depend on a zone. Unknown modes or placeholders, malformed escapes, invalid zones and oversized templates leave replay off rather than guess. Replay addresses are HTTP(S) only, and request headers go along only to the live address's own origin (other hosts get just the user agent and accept headers).

An XMLTV guide keeps the declared history. A DIYP guide is asked for each day by its China date; previous days need `{date}` in the guide address, and an address without it has today only. A guide alone never turns replay on, and recorded MP4/MKV files don't become replay sources because the M3U header declares catchup.

Program times show in the device's time zone. A replay carries its program times and the channel it came from; each line's template is saved with favorites, and older favorites without these fields still open.

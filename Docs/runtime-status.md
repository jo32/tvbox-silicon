# Local runtime status

Validation date: October 4, 2026. Mac plugin support remains experimental. iOS and tvOS do not run the Java or JavaScript plugin hosts.

## Fixes and results

The 47-entry subscription audit originally fetched media from 14 sources. The full post-fix JAR/API run plus the final three-source JavaScript retest fetched media from **23 of 47** entries. Eleven previously failing sources passed: music, NewCz, AppTT, seven Bilibili sources, and the children's JavaScript source. Two previously passing sports sources returned upstream HTTP 404. These are sampled media-fetch results, not a guarantee for every title, segment, or decoder.

- Persistent per-source JVM sessions preserve detail-initialized playback configuration (AppTT) and cookies. Playback carries its parent video ID so a restarted process can restore detail state. Preferences survive process restarts. Each request has a 60-second deadline; idle sessions stop after five minutes, and only idle sessions are evicted during navigation.
- Converted Java 6 bytecode now calls Java interface static methods through generated Java 8 bridges. This resolves the music spider's `Comparator` failure without introducing a verifier error.
- All converted OkHttp calls report source HTTP/network failures. NewCz's missing-cookie 403 recursion is bounded; one retry keeps the same session. A persistent upstream 403 is reported with host/status rather than as empty content. This does not guarantee that the upstream service will accept future requests.
- Bilibili quality arrays are selectable. Their DASH proxy identifiers resolve through the upstream progressive MP4 API, with Referer/UA and account access restrictions preserved. Multipart or unavailable MP4 responses are rejected explicitly.
- Mac JavaScript sources now run in bundled Node with module loading, HTTP, HTML parsing, and persistent preferences. All three tested drpy sources load categories and details. The children's source also fetches its MP4; Huya and Douyu still return webpages that require web video detection.
- Already-resolved media addresses can play despite stale `parse=1` flags. Webpage URLs are still rejected. Provider login messages are shown; entries without video IDs are excluded. The `action` field alone does not identify a utility row: Bttwoo also uses it for screenplay credits. Detail loading now has a retry action and accurate busy state.
- Android application/package metadata adapters remove the missing-context failures. This did not repair the two cloud searches' upstream `pc-api.uc.cn` HTTP 404 responses.

## Every configured entry

Results below combine the full post-fix run and the three-source JavaScript retest. “Media fetched” means that the sampled returned URL responded with media or playlist bytes.

| Source | Result |
| --- | --- |
| 豆豆┃片单 | Index recommendations display title/poster and launch global search by title; they do not supply direct playback IDs. |
| 🗂我的云盘┃配置 | Configuration/login actions; no openable video. |
| 👽玩偶哥哥┃4K弹幕 | no single http url: ''; plugin: 未扫码登录无法观看 |
| 🚀叨观荐影┃预告片 | Media fetched. |
| 🎙️易听音乐┃带歌词 | Media fetched. |
| 💡聚剧┃四盘 | tvbox.runtime.PluginSession$EmptyContentException: The plugin returned no content |
| 🌞光影┃不卡 | Media fetched. |
| 👒原创┃不卡 | detail has no playable episodes |
| 📔厂长┃不卡 | Media fetched. |
| 🌟立播┃不卡 | Media fetched. |
| 👀瓜子┃不卡 | Media fetched. |
| 🍄比特┃不卡 | Media fetched. |
| 🍓糯米┃秒播 | Media fetched. |
| 💮文采┃秒播 | tvbox.runtime.HttpDiagnostics$SourceHTTPException: The source www.ghw9zwp5.com returned HTTP 403 [www.ghw9zwp5.com HTTP 403] |
| 🧀奶酪┃秒播 | Media fetched. |
| 📺热播┃多线 | Media fetched. |
| 🌸茉莉┃多线 | media URL returned HTTP 403 |
| 🐻剧圈┃多线 | media URL failed: RemoteDisconnected: Remote end closed connection without response |
| 🥝荐片┃多线 | Media fetched. |
| 🏝奥特┃多线 | Media fetched. |
| 🧲新6V┃磁力 | no single http url: 'magnet:?xt=urn:btih:0cb07a5bbbcaf4d450f95796bb3061dc351cff14&dn=%E5%85%B0%E9%A6%99%E5%A6%82%E6%95%85' |
| 🦉咕咕┃动漫 | Media fetched. |
| 🚌巴士┃动漫 | needs web sniffing / extra parsing (parse=1 jx=0 playUrl=False) |
| ⚽八八┃看球 | needs web sniffing / extra parsing (parse=1 jx=0 playUrl=False) |
| 🏀多多┃回放 | media URL returned HTTP 404 |
| 🏐吃瓜┃看球 | media URL returned HTTP 404 |
| 🎮一直播┃直播 | java.io.IOException: Network request to live.muxia.site failed: SocketTimeoutException |
| 🎶明星┃MV | Media fetched. |
| 🎧有声┃小说 | Media fetched. |
| 🚑急救┃教学 | Media fetched. |
| 🐯虎牙┃直播 | needs web sniffing / extra parsing (parse=1 jx=0 playUrl=False) |
| 🐟斗鱼┃直播 | needs web sniffing / extra parsing (parse=1 jx=0 playUrl=False) |
| 🎈盘搜┃四盘 | tvbox.runtime.HttpDiagnostics$SourceHTTPException: The source pc-api.uc.cn returned HTTP 404 [pc-api.uc.cn HTTP 404] |
| 🦋易搜┃四盘 | tvbox.runtime.HttpDiagnostics$SourceHTTPException: The source pc-api.uc.cn returned HTTP 404 [pc-api.uc.cn HTTP 404] |
| 🐌盘她┃夸父 | no single http url: ''; plugin: 未扫码登录无法观看 |
| 🐞盘他┃嘟嘟 | no single http url: ''; plugin: 超时扫码请点刷新,未扫码授权无法观看 |
| 🍄抠抠┃搜搜 | no single http url: ''; plugin: 未扫码登录无法观看 |
| 🌈优汐┃搜搜 | no single http url: ''; plugin: 未扫码登录无法观看 |
| 🅱哔哔合集┃弹幕 | Media fetched. |
| 🅱哔哔演唱会┃弹幕 | Media fetched. |
| 📚儿童┃启蒙 | Media fetched. |
| 📚少儿┃教育 | Media fetched. |
| 📚小学┃课堂 | Media fetched. |
| 📚初中┃课堂 | Media fetched. |
| 📚高中┃课堂 | Media fetched. |
| 🛴手机┃推送 | Push utility; no pushed item was provided. |
| 请勿信视频中任何广告 | Informational XPath entry; spider cannot be instantiated. |

## Verification and evidence

- 30 Swift tests passed, including quality selection, provider login errors, Bilibili MP4 resolution, detail IDs, and stale parse flags.
- Java regression checks passed for preserved/restored spider state, actual converted-interface execution, HTTP failure handling, and Android application metadata.
- Script-host checks passed for module imports, HTML extraction, request/response protocol, in-process state, and preferences after restart.
- All 136 localization keys passed coverage/format checks in English, Simplified Chinese, Traditional Chinese, and Japanese.
- macOS, iOS, and tvOS builds passed after the runtime changes.
- A native smoke executable linked to the built TVCore exercised the actual Swift session manager, then obtained decoded AVPlayer video frames for AppTT, Bilibili, and the children’s drpy source. See [runtime smoke log](../build/source-fixes/runtime-smoke.log).
- The exact screenshot item, NewCz `movie/20294.html` (峡谷), still received upstream HTTP 403 on the final replay. The app path surfaced `The source www.4kcz.com returned HTTP 403.` rather than empty content. See [exact-item log](../build/source-fixes/newcz-smoke.log). Its sampled full-audit pass should not be read as a guarantee that this title now works.

Evidence: [full post-fix run](../build/source-fixes/full/results.json), [JavaScript retest](../build/source-fixes/js-final/results.json), [combined results](../build/source-fixes/combined-results.json). Each test directory contains per-request parameters, envelopes, and logs under `evidence/`. The [historical audit](source-audit-baseline.md) retains the exact NewCz 峡谷 reproduction and AppTT field-state diagnosis; its architecture and support statements describe the pre-fix version.

## Remaining limitations

Upstream 403/404 responses, disconnected media hosts, broken provider payloads, and required cloud-drive QR login remain. Mac account settings now provide official Quark/UC web sign-in and manual credentials. CatVod and FTY cloud stream proxy adapters are implemented; actual authorized cloud playback has not yet been verified. Android plugin QR dialogs, web video detection, torrent playback, scrolling comments, and full Android compatibility remain unavailable. Catalog access alone does not establish playback support. The tested JAR host targets `ftyguard_v8.so`; other plugin families are not guaranteed.

The runtimes execute configured subscription code locally; they are compatibility processes, not security sandboxes. Only use trusted subscriptions. Node module caches expire after five minutes. Persistent profiles are under `~/Library/Caches/com.tvbox.yingxia/JarHost/`. Runtime diagnostics are now stored under `~/Library/Application Support/com.tvbox.yingxia/Logs/` (inside the container on sandboxed platforms). Settings → Diagnostic Logs provides level/search filters, live refresh, and an export of retained history.

## Build and reproduce

Build both runtimes with `Scripts/build-java-host.sh` and `Scripts/build-script-host.sh`, regenerate the project with XcodeGen, then run `Scripts/verify.sh`. Java requires JDK 19 and Maven; the script host requires a standalone macOS Node binary and its distributed license. Run `Scripts/test-java-host.sh` and `python3 Scripts/test-script-host.py` for host regressions. See [README](../README.md) and [dependency notices](THIRD_PARTY_NOTICES.md) for toolchain and license details.

### Bttwoo detail regression correction

A follow-up app test found that rejecting every record containing `action` incorrectly hid Bttwoo details. The exact user-selected title 我不是大师 (`play/ch4lua32z`) returned `action: 杨哲`, meaning screenplay credits. Removed this filter and added a regression test. All 31 Swift tests and the Mac build passed. The corrected Swift app path resolved 19 episodes and AVPlayer produced a decoded frame: [playback evidence](../build/bit-regression/playback.log). The rebuilt app was restarted for testing.

## Cloud account bridge — 2026-10-04

The baseline login failures above predate the account bridge. Reference behavior was checked against `reference/FongMi-TV/app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java` and `server/process/Proxy.java` / `Local.java`, plus the downloaded FTY plugin's `Cloud_quark`, `Cloud_uc`, `Cloud_ali`, `ProxyOrigin`, and cloud HTTP server contracts. No Android UI or account-access checks are bypassed.

`CloudDriveBridgeTest` exercises private config URLs, rejection of missing capability/cross-origin requests, legacy cookie references, range status/headers/body, and quality array routing. A separate real-plugin probe with synthetic credentials confirmed four configuration fetches and nonempty Quark credential state. Provider authorization and AVPlayer cloud playback require user sign-in and remain unverified.

### Wogg empty details regression — 2026-10-04

The active subscription's `csp_Wogg` archive (`570c25487b2534db3923ffa6b1fa5d73efaa68b6a9fe7bc0671ae8f5f6796605`) differs from the FTY `WoGGGuard` family. Its cloud ordering uses reflective `Object.clone`; without `java.base/java.lang` opened to the plugin JVM, the plugin swallows the access error and stores a null ordering array. Details then silently return empty `vod_play_from` and `vod_play_url`. The app and audit launchers now include that compatibility option, with a regression check for reflective primitive-array cloning.

For `https://woggpan.888484.xyz/voddetail/131201.html` (兰香如故), the original request returned zero episodes. The repaired host returned 10 lines, with episode counts `[39, 22, 39, 22, 39, 22, 47, 42, 47, 42]`, without account credentials. A separate playback request reached the expected provider message `夸克授权失败，请扫码登录`. The optional Android Go accelerator still cannot run on macOS; its startup failure was not the cause of the empty detail list.

The inspected Cloud/Quark/UC class contract now receives inline `cookie`, `uccookie`, and `token` values from saved accounts, including when the source extension omitted those keys. This is scoped to that class contract; unrelated sources do not receive credentials. No real account was available for authorized playback verification.

The rebuilt macOS app was restarted and the same title opened through Watch Now → 玩偶. Its live detail UI displayed all 10 lines and 39 selectable files on the first Quark original-quality line, confirming the repair through the app rather than only the isolated probe.

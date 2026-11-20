# What a TVCore-only fork adds

An inventory of what a TVBox subscription player can do beyond what `main` does today, written so each piece can be taken on its own.

Every row points at the file that holds it. Nothing here needs another row to work, apart from the three that say so in *Needs*.

## How this was measured

`git diff --numstat` between this repository's `main` and the fork's tip, filtered to `.swift`/`.m`/`.h`/`.c`/`.ts`/`.js`/`.py`/`.sh`: **483 files, +206,864 / −5,393**. Grouping them by the module each piece lives in gives the table below. The fork carries 297 commits that `main` does not.

| Piece | Files | + | − |
|---|---|---|---|
| Egress routing and a local proxy | 16 | 5,083 | 0 |
| Source speed, tiers and grouping | 27 | 5,532 | 6 |
| Backup, restore and the passcode vault | 17 | 3,522 | 31 |
| Ad skipping | 9 | 2,902 | 0 |
| Player controls as a board | 4 | 2,564 | 0 |
| The playback dock | 23 | 2,569 | 0 |
| Web cast, Play On, external display | 10 | 1,889 | 6 |
| Everything else (UI, folding, scripts, tests) | 377 | 182,803 | 5,350 |

"Everything else" is mostly the two rewrites this fork also carries — the One-skin watch page and the Duo folding layouts — plus test and script tooling. Those are the parts least likely to be useful here, so they are listed last and marked as such.

---

## 1. Ad skipping

Two pieces, and they answer different situations.

**`Sources/TVCore/AdPrefix.swift`** — a source that splices the same foreign ad into every video. The film comes from one directory for 93–99% of the playlist's seconds; the ads from another. Drop whole directories that hold at most 30% of the total, decline if that would pass 35% or leave the film under 60%. No state, no learning. Already sent as its own pull request.

**`Sources/TVCore/AdAutoLearn.swift`**, **`AdFrameSampler.swift`**, **`AdSignature.swift`** — the ad that is not in a separate directory, so only the picture gives it away. Frames are sampled, hashed, and matched against a library that grows as the viewer marks a range once. The library exports and merges, so a range marked on one device helps on the next.

*Needs:* `EpisodeSkip.swift` (already in `main`) for where a skip is applied.

## 2. Egress routing and a local proxy

**`Sources/TVCore/EgressRouter.swift`** — decides per request whether it leaves directly or through the viewer's proxy, and remembers the answer per host. The comment's own note is the design: a site's API and its artwork usually live on the same host, but its playlist often lives on a different CDN, so a host-keyed table has to know which kind of request it is answering.

**`LocalProxyServer.swift`** — a loopback TCP relay, 1,217 lines. `URLSession` and `AVPlayer` are pointed at `http://127.0.0.1:<port>/…`; the server reads the request and opens the target, direct or through one of the viewer's proxies, relaying bytes both ways. It is what makes a proxy work for AVPlayer at all, which has no proxy setting of its own.

**`CustomProxy.swift`** — the viewer's own HTTP/HTTPS/SOCKS5 endpoints, with the port-pool handling that keeps one stalled request from taking the whole chain down.

**`ForcedNodeHosts.swift`**, **`LoonPlugin.swift`** — for viewers running a rules-based proxy client: learn the hosts it routes directly although they must go through a node, and hand the client a subscription that fixes them.

*Needs:* nothing. `LocalProxyServer` is used by the egress router but also stands alone.

## 3. Source speed, tiers and grouping

The question these answer is "which of my 300 sources is worth opening right now", which `main` answers per source and per page but not in one conclusion.

**`SourceConnectivity.swift`** — one verdict per source from three inputs that were previously read separately: route, probe reading, quality label. A tier (`playable` / `slow` / `unreachable` / `untested`) that grouping and shelves can sort by without each re-deriving it. Readings age: a probe result older than a threshold drops a tier rather than staying green forever.

**`SourceShelfState.swift`**, **`SourceGroups.swift`** — group a source list into collapsible shelves, remember which are open per group, and order inside a group by tier.

**`LineMatrix.swift`** — the same film across channels × sources × lines in one table, so "A's line 2 answers in 40 ms but only sustains 80 KB/s, B's line 1 in 120 ms but 3 MB/s" is a comparison rather than two separate screens. Pure data; the probes are injected, so the ordering is unit-testable.

**`CrossSourceMatch.swift`** — finds the same title across sources so the matrix has rows to compare.

**`ResourceRanking.swift`** — orders a source's results by four measured dimensions rather than the source's own order.

*Needs:* `LineMatrix` needs `CrossSourceMatch` for candidates; it accepts `nil` results and stays testable without either sending anything.

## 4. Backup, restore and the passcode vault

**`FullBackup.swift`** — one portable snapshot of everything a viewer loses when the app is removed: sign-in state (cookies and tokens), playback history, favourites, the vault, custom proxies, and raw preferences that do not travel through iCloud.

**`KeychainBackup.swift`** — the same snapshot, chunked into the Keychain, which survives an uninstall on a sideloaded build. Restored on a fresh launch.

**`CloudDriveBackup.swift`** — the same snapshot to a cloud drive the viewer already signed into.

**`PrivacyVault.swift`** — a passcode that hides chosen subscriptions and sources. Stricter than hiding a row: a hidden source must also stop appearing in search, in history, in the favourites wall, and in anything that counts them.

*Needs:* `FullBackup` is the format the other two write.

## 5. Player controls as a board

**`Sources/TVCore/SlotBoard.swift`** — the viewer's arrangement of player controls as slots: which controls sit in which row, how wide each row is, and what happens when a row cannot hold them all. The point of a separate type is that an overflowing row is a value that can be tested, not a layout that just looks wrong on a device.

*Needs:* nothing in `TVCore`; the SwiftUI side reads the board.

## 6. The playback dock

**`DockLayout.swift`**, **`DockCardAspect.swift`**, **`DockCardClamp.swift`**, **`DockHandleAnchor.swift`**, **`DockScrub.swift`**, **`DockVisibility.swift`**, **`DockSessionSnapshot.swift`** — small videos playing while the viewer browses, positioned and sized so they never leave the screen, with a handle that anchors where it was put and a scrub that drives the same state the full player does.

**`PlaybackCapacity.swift`** — one place that says how many streams this device can play at once, and what each new one costs. The comment is explicit that this exists because the same budget was previously recomputed in several places and they disagreed.

**`DockDecodeResolution.swift`**, **`DockDecodingBudget.swift`** — what to do when the budget is short: lower the dock's decode resolution before refusing the stream.

*Needs:* none of these are `TVCore`-only in intent, but the files are all plain values.

## 7. Web cast, Play On, external display

**`WebCastServer.swift`** — an HTTP server in the app that serves a small web UI, so a browser on the same network can list, browse, search and play any source the app can. It reaches the app through `WebCastDataSource`, a protocol, so `TVCore` does not depend on SwiftUI.

**`PlayOn.swift`** — hand what is playing on one device to another of the same app on the same network, picking up at the same second. Bonjour for discovery, the existing cast channel for the handoff.

**`ExternalDisplay.swift`** (app layer) — a separate window on a connected display, with its own end-of-series screen.

*Needs:* `WebCastServer` needs the app to implement `WebCastDataSource`.

---

## What is probably not wanted here

Listed so nothing is smuggled in:

- **The One-skin watch page** (`App/OneSkin*.swift`, `Sources/TVCore/OneSkin*.swift`) — a reproduction of another app's player layout. It is the largest single piece and the most opinionated; it is a look, not a capability.
- **The Duo folding layouts** (`App/MobilePlayer.swift` and the `Duo*` files) — written for a foldable iPhone. Reference material at best.
- **Rebranding** — the fork renames the app. A pull request should not.
- **The fork's own process files** — `RULES.md`, `PEERS.md`, `REPORT-pro.md`, `.rules.sha`, `Config/DeviceTest.xcconfig`, `Docs/fusion/*`, `Docs/duo/evidence/*`. Internal bookkeeping, 101 files.

## In what order these could land

Each is a separate pull request, smallest first:

1. `AdPrefix` + its four captured fixtures — 1 module, 0 dependencies, 7 tests. *Sent.*
2. `SlotBoard` + its tests — 1 module, plain values.
3. `LineMatrix` + `CrossSourceMatch` — 2 modules, pure.
4. `SourceConnectivity` + shelves — a verdict per source, then the grouping that reads it.
5. `PlaybackCapacity` — one constant, and the call sites that disagree with it today.
6. `PrivacyVault`, then `FullBackup`, then the two transports.
7. `EgressRouter` + `LocalProxyServer` + `CustomProxy` — the largest self-contained group, and the one with the most to explain.
8. Ad learning (`AdAutoLearn` + `AdSignature` + `AdFrameSampler`).

The rest — the two rewrites, the dock, web cast — are large enough that they are better discussed as issues first, unless one of them is what you actually want.

## A note on verification

What is checked, and what is not:

- The two pull requests sent so far each name their own checks in their description.
- Everything else here was migrated and compiled in the fork on iOS, macOS and tvOS — but that was against `1.8.23`, not against today's `main`.
- Nothing in this list has been run on a device from this checkout: it has no FFmpeg or LibASS binaries, so the package does not resolve and `swift test` cannot run here.

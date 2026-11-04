# Notes for coding agents

## Building and releasing

- **Pull from the remote before you build or release.** Run `git fetch origin`, then bring `main` up to date with
  `git pull --ff-only` (or `git rebase origin/main` if you have local commits). Autofix PRs and other sessions merge
  into `main` often. A build made from an out-of-date tree ships without their fixes and has to be rebuilt and
  notarized again, which costs 25 minutes or more.
- Check again right before publishing (`git fetch origin && git merge-base --is-ancestor origin/main HEAD`). If
  `origin/main` moved during the build, pull and rebuild. Never deploy the website or push from a tree behind it.

## End-to-end verification (iPhone Duo)

The toolchain lives in `Scripts/` and is documented in `Docs/真机验收.md` (XCUITest on the real device),
`Docs/iPhone-Duo-模拟器折叠验证.md` (folding the simulator), and `Docs/QA深链参数表.md` (every launch arg).

**Fastest single-screen check (no cable, no tap):** launch the app with QA deep-link args, then screenshot.

```bash
# simulator — any section, any page
xcrun simctl launch <UDID> wda.prdc.yingxia.dev -qaSection sites -qaIsolatedData 1
xcrun simctl launch <UDID> wda.prdc.yingxia.dev -qaPage vault -qaIsolatedData 1
xcrun simctl io <UDID> screenshot out.png

# real device, wireless OK (no tap) — every screen, one command
Scripts/shoot-duo.sh
```

`-qaSection` keys: `home discover live music search sites files favorites history downloads settings more`.
`-qaPage` opens one screen directly: `player`, `detail:<site>:<video>`, `privacy`, `vault`, `resource-order`, … — full
table in `Docs/QA深链参数表.md`.

**The four scripts, by job:**

| Script | What it does | Needs |
|---|---|---|
| `Scripts/e2e-verify.sh` | build → install → screenshot every section on the simulator | simulator only |
| `Scripts/test-duo-ui.sh --simulator <UDID>` | XCUITest: tap + assert + screenshot | simulator; **USB** for real device |
| `Scripts/install-duo.sh --device <UDID>` | build + sign + install + launch on the real Duo | wireless OK |
| `Scripts/hinge/scripts/hinge` | fold / rotate / screenshot the iPhone Duo **simulator** | iOS 27.1 runtime |

**Folding the iPhone Duo simulator:** first install the iOS 27.1 runtime
(`xcodebuild -downloadPlatform iOS -buildVersion 27.1`), create the `iPhone-Duo` device, then
`hinge open|half|close`, `hinge rotate left|right`, `hinge screenshot out.png`. Inner display is
`regular×regular` (the `duoExpanded` branch); outer display is `regular×compact` portrait / `compact×compact`
landscape. Details and gotchas in `Docs/iPhone-Duo-模拟器折叠验证.md`.

**Gotchas that have burned us:**
- Real-device XCUITest fails with `code 74` over wireless — it needs a **USB cable**.
- The `iPhone-Duo` simulator device needs the **iOS 27.1** runtime; 26.5/27.0 report `Incompatible device`.
- `xcodebuild -downloadPlatform` prints progress with `\r`; pipe through `tr '\r' '\n'` to see it. Don't `pkill` at 99% — it restarts near 0.
- The `safe-delete` shim blocks `rm -rf build/DuoUI` (2000+ files); use `python3 -c "import shutil; shutil.rmtree('build/DuoUI', ignore_errors=True)"`.

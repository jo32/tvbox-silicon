---
name: hinge
description: Control the hinge (fold) angle of a foldable iPhone Simulator such as iPhone Duo. Use when you need to fold, unfold, half-open, or animate the fold of a running simulator, read its current hinge angle, or test how an app reacts to hinge and display changes.
---

# hinge

Set and read the hinge angle of a booted foldable iPhone Simulator from the command line. It posts the same HID event as the hidden hinge slider in Xcode's Device Hub (hold Option).

Run the bundled script at `scripts/hinge`, relative to this skill's directory. A `hinge` on `PATH` works too when `hinge -v` prints the same version as `scripts/hinge -v`; an older install lacks `screenshot` and `--json`.

## Commands

```bash
scripts/hinge 120                # set angle: 0 = closed, 180 = flat
scripts/hinge open               # 180°
scripts/hinge close              # 0°
scripts/hinge half               # 90°
scripts/hinge sweep 180 0 2      # animate from 180° to 0° over 2 seconds
scripts/hinge get                # print current angle, e.g. 130.0
scripts/hinge posture            # angle, orientation, and which integrated display is active
scripts/hinge posture --json     # the same as JSON; also works with get, orientation, screenshot
scripts/hinge screenshot out.png # capture the display that hosts the UI
scripts/hinge rotate left        # rotate 90°, like Device Hub's Controls > Rotate Left; prints the new orientation
scripts/hinge rotate right
scripts/hinge orient landscape-left  # portrait, landscape-left, landscape-right, or portrait-upside-down
scripts/hinge orientation        # print current orientation, e.g. landscape-left
scripts/hinge -d "iPhone Duo" 90 # target a simulator by name or UDID (default: $HINGE_DEVICE, else the only booted iPhone Duo)
scripts/hinge -t 0 90            # set without waiting for the angle to be confirmed
```

`open`, `close` and `half` also accept `unfolded`/`flat`, `closed`/`folded` and `half-open`.

## Workflow

1. Make sure a foldable simulator is booted: `xcrun simctl list devices booted`. Without `-d`, `hinge` picks the only booted iPhone Duo; with several, it lists them and exits — pass `-d <udid>` or set `HINGE_DEVICE` instead of guessing.
2. Set the angle. The command returns once the simulator reports the new angle, so a non-zero exit means the fold did not happen — don't poll `get` to check it.
3. Wait for the display to switch before you screenshot or read the UI: it takes 1-2.5 s after the angle changes.
4. `scripts/hinge posture` tells which display hosts the UI (`active`) after a fold. Use `--json` when you parse it: `activeDisplay` names that display.
5. Take screenshots with `scripts/hinge screenshot out.png`. It captures the active display, so the wait in step 3 still applies. Plain `simctl io … screenshot` fails with `Invalid argument` on a foldable unless it gets `--display=LCD` (cover) or `--display=LCD-1` (inner).

## Notes

- Simulator only. It does not work on physical devices.
- The first run compiles a tiny helper with Xcode's clang, caching it under `~/.cache/hinge`. It takes a few seconds.
- A `sweep` runs at 60 Hz in one process. For a smooth animation, use it instead of many `set` calls. It does not confirm the final angle.
- Setting the angle is not the same as switching the display. The angle is confirmed; the display switch is up to the simulator. 0° and 180° usually switch it, angles in between depend on the path the hinge took (a slow `sweep` can keep the previous display until the end), and sometimes the simulator stops following the hinge altogether while still reporting new angles. Always check with `posture` instead of assuming; a simulator that stopped following the hinge keeps reporting correct angles, and a shutdown and boot clears it.
- Which display hosts the UI is `active`, not the backlight: a folded Duo lights its cover as `inactiveOn`, and the backlight lags a fold by up to 3 s.
- Angles outside 0-180 are rejected. A simulator without a hinge fails with "this simulator reports no hinge".
- `orient`, `orientation` and `rotate` use device orientations (the `devicectl` names), not interface orientations: a device in `landscape-right` shows a `landscape-left` interface.
- Orientation on a foldable follows only Device Hub's own event; `xcrun devicectl device orientation set` reports success there but is reverted. `rotate`/`orient` send Device Hub's event and fall back to `devicectl` on simulators that ignore it.
- This uses a private, undocumented protocol. It was verified with Xcode 27.1 and 27.2 on iOS 27.1 and may break in other versions. If setting an angle fails with "the hinge angle did not reach ...", report that the protocol has likely changed.

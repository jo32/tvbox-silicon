# Notes for coding agents

## Building and releasing

- **Pull from the remote before you build or release.** Run `git fetch origin`, then bring `main` up to date with
  `git pull --ff-only` (or `git rebase origin/main` if you have local commits). Autofix PRs and other sessions merge
  into `main` often. A build made from an out-of-date tree ships without their fixes and has to be rebuilt and
  notarized again, which costs 25 minutes or more.
- Check again right before publishing (`git fetch origin && git merge-base --is-ancestor origin/main HEAD`). If
  `origin/main` moved during the build, pull and rebuild. Never deploy the website or push from a tree behind it.

## Verifying

- `Scripts/verify.sh` is the full check (macOS, iOS and tvOS builds, then every test). Run it once, right before you
  open a pull request. While you work, use the narrowest check: `swift test --filter ...` or one platform's build.
- Many sessions share one Mac, so full verifies take turns: at most two run at a time (one while the Mac is already
  loaded), at low priority, and the rest wait and print `Waiting for a verify slot`. Wait for it; don't start a second
  run or work around the line. `VERIFY_DIRECT=1` skips it and is for the developer only.
- `~/Library/Caches/tvbox-verify/runs.log` has one line per run: worktree, seconds waited, seconds run, exit code.

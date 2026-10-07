# QuickJS-ng

Upstream: https://github.com/quickjs-ng/quickjs, tag v0.17.0
(archive SHA-256 559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9), MIT license.

Only the engine sources are vendored, unmodified: `quickjs.c`, `libregexp.c`, `libunicode.c`,
`dtoa.c` and their headers. `TVScript.c` and `include/TVScript.h` are this project's bridge.
Android TVBox runs its JavaScript sources on QuickJS, so scripts behave as their authors expect.

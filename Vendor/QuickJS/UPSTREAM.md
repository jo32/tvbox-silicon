# QuickJS-ng

Upstream: https://github.com/quickjs-ng/quickjs, tag v0.17.0
(archive SHA-256 559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9), MIT license.

Only the engine sources and their headers are vendored. There is one local change to
`quickjs.c` and `quickjs.h`: pending jobs record the scope in which they were enqueued.
The VM thread can unlink a stopped scope's jobs and release their arguments without invoking
their callbacks. Keep this change when updating the engine. Other vendored engine sources
are unmodified. `TVScript.c` and `include/TVScript.h` are this project's bridge.
Android TVBox runs its JavaScript sources on QuickJS, so scripts behave as their authors expect.

Scopes are per runtime, single-threaded and non-nested. Jobs keep FIFO order; a successful
return does not pump or empty the queue. Cancellation scans the queue once (linear in pending
jobs, one 64-bit scope tag per entry) and leaves other scopes' queued jobs alone. A job
enqueued while an older callback is running belongs to the operation currently pumping the VM.
There is no rollback of code that already ran, persistent globals, or a reaction that has not
been enqueued. Cancelled prelude timers are skipped and removed on the next tick, or released
with the VM. No script is evaluated just to clean up an interrupted operation.

C callers can group module initialization and calls with the same token and finish the group
on the VM thread. The bridge holds its own reference until the group finishes, a different
operation begins, or the VM is freed. Ungrouped calls keep their original API. The Swift
session decides completion versus cancellation before handing the VM to another caller.
The existing pending HTTP registries are session-wide: stopping an operation cancels outstanding
pollable requests and drops unclaimed answers, not just the new call's queued JavaScript.

Cancellation is cooperative: error message/stack conversion and JSON serialization remain
under the same interrupt as evaluation. Once stopped, the bridge returns plain error text
instead of requesting further diagnostics from the script. Native work that does not poll
or expose cancellation can still delay return; the token is not a hard real-time deadline.

#ifndef TVSCRIPT_H
#define TVSCRIPT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One QuickJS runtime and context. Not thread safe: use each script from one thread.
typedef struct TVScript TVScript;
/// An operation's cancellation flag. May be signaled from another thread; the VM remains
/// confined to its own thread. Queued operations each have a separate flag.
/// Keep the token alive until the cancellable VM call returns; cancel never frees it.
typedef struct TVScriptCancellation TVScriptCancellation;
TVScriptCancellation *tv_script_cancellation_create(void);
void tv_script_cancellation_cancel(TVScriptCancellation *cancellation);
void tv_script_cancellation_free(TVScriptCancellation *cancellation);

/// Answers `__host(operation, argument)` and module loading ("resolve", "module").
/// Returns a malloc'd UTF-8 string, or NULL for JavaScript null. A result beginning with
/// '\x01' throws an Error whose message is the rest of the string.
typedef char *(*TVScriptHost)(void *opaque, const char *operation, const char *argument);

TVScript *tv_script_create(void *opaque, TVScriptHost host, size_t memory_limit, size_t stack_limit);
void tv_script_free(TVScript *script);

/// Evaluates `source` as the module `name` and waits up to `seconds` for it to settle.
/// Returns NULL on success or a malloc'd error description.
char *tv_script_module(TVScript *script, const char *name, const char *source, double seconds);

/// Evaluates a global expression, waits up to `seconds` if it is a promise, and returns a
/// malloc'd JSON object: {"value": <JSON of the result>} or {"error": "<message and stack>"}.
char *tv_script_call(TVScript *script, const char *expression, double seconds);
char *tv_script_module_cancellable(TVScript *script, const char *name, const char *source, double seconds, TVScriptCancellation *cancellation);
char *tv_script_call_cancellable(TVScript *script, const char *expression, double seconds, TVScriptCancellation *cancellation);

#ifdef __cplusplus
}
#endif

#endif

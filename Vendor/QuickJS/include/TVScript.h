#ifndef TVSCRIPT_H
#define TVSCRIPT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One QuickJS runtime and context. Not thread safe: use each script from one thread.
typedef struct TVScript TVScript;

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

#ifdef __cplusplus
}
#endif

#endif

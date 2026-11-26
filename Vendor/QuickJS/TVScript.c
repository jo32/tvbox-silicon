#include "include/TVScript.h"
#include "quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdbool.h>

struct TVScriptCancellation { atomic_bool cancelled; atomic_uint owners; };
TVScriptCancellation *tv_script_cancellation_create(void) {
    TVScriptCancellation *token = calloc(1, sizeof(TVScriptCancellation));
    if (token) {
        atomic_init(&token->cancelled, false);
        atomic_init(&token->owners, 1);
    }
    return token;
}
void tv_script_cancellation_cancel(TVScriptCancellation *token) { if (token) atomic_store(&token->cancelled, true); }
bool tv_script_cancellation_is_cancelled(const TVScriptCancellation *token) { return token && atomic_load(&token->cancelled); }
void tv_script_cancellation_free(TVScriptCancellation *token) {
    if (token && atomic_fetch_sub(&token->owners, 1) == 1) free(token);
}

struct TVScript {
    JSRuntime *runtime;
    JSContext *context;
    void *opaque;
    TVScriptHost host;
    double deadline;
    TVScriptCancellation *cancellation;
    uint64_t job_scope;
    JSValue timer_scope;
};

static double now_seconds(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

static int interrupt(JSRuntime *runtime, void *opaque) {
    TVScript *script = opaque;
    return tv_script_cancellation_is_cancelled(script->cancellation) || (script->deadline > 0 && now_seconds() >= script->deadline);
}

static JSValue current_timer_scope(JSContext *context, JSValueConst self, int argc, JSValueConst *argv) {
    TVScript *script = JS_GetContextOpaque(context);
    if (JS_IsUndefined(script->timer_scope)) {
        JSValue scope = JS_NewObjectProto(context, JS_NULL);
        if (JS_IsException(scope)) return scope;
        if (JS_DefinePropertyValueStr(context, scope, "cancelled", JS_FALSE, JS_PROP_WRITABLE) < 0) {
            JS_FreeValue(context, scope);
            return JS_EXCEPTION;
        }
        script->timer_scope = scope;
    }
    return JS_DupValue(context, script->timer_scope);
}

static char *copy(const char *text) {
    if (!text) return NULL;
    size_t length = strlen(text);
    char *result = malloc(length + 1);
    if (result) memcpy(result, text, length + 1);
    return result;
}

/// "message\nstack" of the pending exception, malloc'd.
static char *exception_text(TVScript *script) {
    JSContext *context = script->context;
    JSValue exception = JS_GetException(context);
    const char *message = !interrupt(script->runtime, script) ? JS_ToCString(context, exception) : NULL;
    JSValue stack = message && JS_IsObject(exception) && !interrupt(script->runtime, script)
        ? JS_GetPropertyStr(context, exception, "stack") : JS_UNDEFINED;
    const char *trace = !JS_IsUndefined(stack) && !JS_IsException(stack) && !interrupt(script->runtime, script)
        ? JS_ToCString(context, stack) : NULL;
    size_t length = (message ? strlen(message) : 9) + (trace ? strlen(trace) : 0) + 2;
    char *result = malloc(length);
    if (result) snprintf(result, length, "%s%s%s", message ? message : "exception", trace ? "\n" : "", trace ? trace : "");
    if (message) JS_FreeCString(context, message);
    if (trace) JS_FreeCString(context, trace);
    JS_FreeValue(context, stack);
    JS_FreeValue(context, exception);
    if (JS_HasException(context)) JS_FreeValue(context, JS_GetException(context));
    return result;
}

static JSValue host_call(JSContext *context, JSValueConst self, int argc, JSValueConst *argv) {
    TVScript *script = JS_GetContextOpaque(context);
    const char *operation = argc > 0 ? JS_ToCString(context, argv[0]) : NULL;
    const char *argument = argc > 1 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1]) ? JS_ToCString(context, argv[1]) : NULL;
    if (!operation) return JS_ThrowTypeError(context, "__host needs an operation");
    char *answer = script->host(script->opaque, operation, argument ? argument : "");
    JS_FreeCString(context, operation);
    if (argument) JS_FreeCString(context, argument);
    if (!answer) return JS_NULL;
    JSValue result;
    if (answer[0] == '\x01') result = JS_ThrowInternalError(context, "%s", answer + 1);
    else result = JS_NewString(context, answer);
    free(answer);
    return result;
}

static char *normalize(JSContext *context, const char *base, const char *name, void *opaque) {
    TVScript *script = opaque;
    size_t length = strlen(base) + strlen(name) + 2;
    char *request = malloc(length);
    if (!request) return NULL;
    snprintf(request, length, "%s\n%s", base, name);
    char *resolved = script->host(script->opaque, "resolve", request);
    free(request);
    if (!resolved || resolved[0] == '\x01') {
        JS_ThrowReferenceError(context, "cannot resolve module %s: %s", name, resolved ? resolved + 1 : "");
        free(resolved);
        return NULL;
    }
    char *result = js_strdup(context, resolved);
    free(resolved);
    return result;
}

static JSModuleDef *load(JSContext *context, const char *name, void *opaque) {
    TVScript *script = opaque;
    char *source = script->host(script->opaque, "module", name);
    if (!source || source[0] == '\x01') {
        JS_ThrowReferenceError(context, "cannot load module %s: %s", name, source ? source + 1 : "");
        free(source);
        return NULL;
    }
    JSValue compiled = JS_Eval(context, source, strlen(source), name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(source);
    if (JS_IsException(compiled)) return NULL;
    JSModuleDef *module = JS_VALUE_GET_PTR(compiled);
    JS_FreeValue(context, compiled);
    return module;
}

TVScript *tv_script_create(void *opaque, TVScriptHost host, size_t memory_limit, size_t stack_limit) {
    TVScript *script = calloc(1, sizeof(TVScript));
    if (!script) return NULL;
    script->opaque = opaque;
    script->host = host;
    script->timer_scope = JS_UNDEFINED;
    script->runtime = JS_NewRuntime();
    if (!script->runtime) { free(script); return NULL; }
    if (memory_limit) JS_SetMemoryLimit(script->runtime, memory_limit);
    if (stack_limit) JS_SetMaxStackSize(script->runtime, stack_limit);
    JS_SetInterruptHandler(script->runtime, interrupt, script);
    JS_SetModuleLoaderFunc(script->runtime, normalize, load, script);
    script->context = JS_NewContext(script->runtime);
    if (!script->context) { JS_FreeRuntime(script->runtime); free(script); return NULL; }
    JS_SetContextOpaque(script->context, script);
    JSValue global = JS_GetGlobalObject(script->context);
    JS_SetPropertyStr(script->context, global, "__host", JS_NewCFunction(script->context, host_call, "__host", 2));
    JS_SetPropertyStr(script->context, global, "__tvboxTimerScope", JS_NewCFunction(script->context, current_timer_scope, "__tvboxTimerScope", 0));
    JS_FreeValue(script->context, global);
    return script;
}

void tv_script_free(TVScript *script) {
    if (!script) return;
    JS_FreeValue(script->context, script->timer_scope);
    tv_script_cancellation_free(script->cancellation);
    JS_FreeContext(script->context);
    JS_FreeRuntime(script->runtime);
    free(script);
}

/// Runs jobs and the prelude's timers until `value` (if a promise) settles. Takes ownership of
/// `value`; returns the settled value or JS_EXCEPTION.
static JSValue settle(TVScript *script, JSValue value) {
    JSContext *context = script->context;
    for (;;) {
        if (interrupt(script->runtime, script)) {
            JS_FreeValue(context, value);
            return JS_ThrowInternalError(context, "interrupted: the script operation stopped");
        }
        if (JS_IsException(value)) return value;
        JSPromiseStateEnum state = JS_PromiseState(context, value);
        if (state == JS_PROMISE_FULFILLED || state == JS_PROMISE_REJECTED) {
            JSValue result = JS_PromiseResult(context, value);
            JS_FreeValue(context, value);
            if (state == JS_PROMISE_REJECTED) return JS_Throw(context, result);
            return result;
        }
        if (state != JS_PROMISE_PENDING) return value;
        JSContext *job;
        int ran = JS_ExecutePendingJob(script->runtime, &job);
        if (ran < 0) { JS_FreeValue(context, value); return JS_EXCEPTION; }
        if (ran > 0) continue;
        // No queued jobs: fire due timers through the prelude, or wait for the next one.
        JSValue global = JS_GetGlobalObject(context);
        JSValue tvbox = JS_GetPropertyStr(context, global, "__tvbox");
        JSValue tick = JS_IsObject(tvbox) ? JS_GetPropertyStr(context, tvbox, "tick") : JS_UNDEFINED;
        double wait = -1;
        if (JS_IsFunction(context, tick)) {
            JSValue next = JS_Call(context, tick, tvbox, 0, NULL);
            if (JS_IsException(next)) { JS_FreeValue(context, tick); JS_FreeValue(context, tvbox); JS_FreeValue(context, global); JS_FreeValue(context, value); return JS_EXCEPTION; }
            JS_ToFloat64(context, &wait, next);
            JS_FreeValue(context, next);
        }
        JS_FreeValue(context, tick); JS_FreeValue(context, tvbox); JS_FreeValue(context, global);
        // A timer may settle this promise directly without queuing another job.
        if (JS_IsJobPending(script->runtime) || JS_PromiseState(context, value) != JS_PROMISE_PENDING) continue;
        if (wait < 0) {
            JS_FreeValue(context, value);
            return JS_ThrowInternalError(context, "the script is waiting for something that never happens");
        }
        // Waiting for a timer that falls past the deadline would only hold the VM until then.
        if (script->deadline > 0 && now_seconds() + wait / 1000 > script->deadline) {
            JS_FreeValue(context, value);
            return JS_ThrowInternalError(context, "interrupted: the script did not finish in time");
        }
        if (wait > 0) usleep((useconds_t)(wait > 50 ? 50000 : wait * 1000));
    }
}

static void finish_operation(TVScript *script, bool stopped) {
    if (!JS_IsUndefined(script->timer_scope)) {
        if (stopped) JS_SetPropertyStr(script->context, script->timer_scope, "cancelled", JS_TRUE);
        JS_FreeValue(script->context, script->timer_scope);
        script->timer_scope = JS_UNDEFINED;
    }
    JS_EndJobScope(script->runtime, script->job_scope, stopped);
    script->job_scope = 0;
    tv_script_cancellation_free(script->cancellation);
    script->cancellation = NULL;
}

static bool begin_operation(TVScript *script, double seconds, TVScriptCancellation *cancellation) {
    if (script->job_scope && script->cancellation != cancellation)
        finish_operation(script, tv_script_cancellation_is_cancelled(script->cancellation));
    if (!script->job_scope) {
        script->job_scope = JS_BeginJobScope(script->runtime);
        script->cancellation = cancellation;
        if (cancellation) atomic_fetch_add(&cancellation->owners, 1);
    }
    script->deadline = seconds > 0 ? now_seconds() + seconds : 0;
    return !interrupt(script->runtime, script);
}

void tv_script_operation_finish(TVScript *script, TVScriptCancellation *cancellation) {
    if (script->job_scope && script->cancellation == cancellation)
        finish_operation(script, tv_script_cancellation_is_cancelled(cancellation));
}

static bool end_call(TVScript *script) {
    bool stopped = interrupt(script->runtime, script);
    if (stopped) tv_script_cancellation_cancel(script->cancellation);
    if (stopped || !script->cancellation) finish_operation(script, stopped);
    script->deadline = 0;
    return stopped;
}

static char *call_result(TVScript *script, const char *expression) {
    JSContext *context = script->context;
    JSValue result = settle(script, JS_Eval(context, expression, strlen(expression), "<call>", JS_EVAL_TYPE_GLOBAL));
    JSValue envelope = JS_NewObjectProto(context, JS_NULL);
    if (JS_IsException(result)) {
        char *error = exception_text(script);
        JS_SetPropertyStr(context, envelope, "error", JS_NewString(context, error ? error : "exception"));
        free(error);
    } else {
        JS_SetPropertyStr(context, envelope, "value", result);
    }
    JSValue json = JS_JSONStringify(context, envelope, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(context, envelope);
    if (JS_IsException(json)) {
        JS_FreeValue(context, JS_GetException(context));
        return copy("{\"error\":\"the script returned a value that cannot be converted to JSON\"}");
    }
    const char *text = JS_ToCString(context, json);
    char *answer = copy(text);
    JS_FreeCString(context, text);
    JS_FreeValue(context, json);
    return answer;
}

char *tv_script_call_cancellable(TVScript *script, const char *expression, double seconds, TVScriptCancellation *cancellation) {
    char *answer = begin_operation(script, seconds, cancellation) ? call_result(script, expression) : NULL;
    if (end_call(script)) {
        free(answer);
        return copy("{\"error\":\"interrupted: the script operation stopped\"}");
    }
    return answer;
}

char *tv_script_module_cancellable(TVScript *script, const char *name, const char *source, double seconds, TVScriptCancellation *cancellation) {
    char *error = NULL;
    if (begin_operation(script, seconds, cancellation)) {
        JSContext *context = script->context;
        JSValue result = settle(script, JS_Eval(context, source, strlen(source), name, JS_EVAL_TYPE_MODULE));
        if (JS_IsException(result)) error = exception_text(script);
        JS_FreeValue(context, result);
    }
    if (end_call(script)) {
        free(error);
        return copy("interrupted: the script operation stopped");
    }
    return error;
}

char *tv_script_call(TVScript *script, const char *expression, double seconds) {
    return tv_script_call_cancellable(script, expression, seconds, NULL);
}

char *tv_script_module(TVScript *script, const char *name, const char *source, double seconds) {
    return tv_script_module_cancellable(script, name, source, seconds, NULL);
}

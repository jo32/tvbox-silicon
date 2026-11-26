#include "TVScript.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures;

static void expect(int condition, const char *label) {
    printf("%s: %s\n", condition ? "PASS" : "FAIL", label);
    if (!condition) failures++;
}

static char *checkpoint(void *opaque, const char *operation, const char *argument) {
    (void)argument;
    if (!strcmp(operation, "cancel")) tv_script_cancellation_cancel(opaque);
    if (!strcmp(operation, "pause")) {
        struct timespec pause = { .tv_nsec = 60000000 };
        nanosleep(&pause, NULL);
    }
    return NULL;
}

static int contains(const char *text, const char *fragment) {
    return text && strstr(text, fragment) != NULL;
}

static int value_is(TVScript *script, const char *expression, const char *expected) {
    char *result = tv_script_call(script, expression, 1);
    int matches = result && !strcmp(result, expected);
    free(result);
    return matches;
}

static void formatting(const char *label, const char *source, int module) {
    TVScriptCancellation *token = tv_script_cancellation_create();
    TVScript *script = tv_script_create(token, checkpoint, 0, 0);
    char *error = module ? tv_script_module_cancellable(script, "fixture", source, 1, token)
                         : tv_script_call_cancellable(script, source, 1, token);
    expect(contains(error, "interrupt") && value_is(script, "[entered, completed]", "{\"value\":[1,0]}"), label);
    free(error);
    tv_script_free(script);
    tv_script_cancellation_free(token);
}

static void operation_boundary(int cancel, int explicit_finish, int complete_first) {
    TVScriptCancellation *token = tv_script_cancellation_create();
    TVScript *script = tv_script_create(token, checkpoint, 0, 0);
    char *error = tv_script_module_cancellable(script, "setup", "globalThis.count = 0", 1, token);
    char *answer = tv_script_call_cancellable(script, "Promise.resolve().then(() => count++); 42", 1, token);
    expect(!error && contains(answer, "42"), "module and call share a live operation");
    free(error);
    free(answer);
    if (complete_first) tv_script_operation_finish(script, token);
    if (cancel) tv_script_cancellation_cancel(token);
    if (explicit_finish) tv_script_operation_finish(script, token);
    tv_script_cancellation_free(token);
    const char *expected = cancel && !complete_first ? "{\"value\":0}" : "{\"value\":1}";
    expect(value_is(script, "Promise.resolve().then(() => count)", expected),
           !explicit_finish ? "token release before next ungrouped call is safe" :
           complete_first ? "late cancellation cannot undo a completed operation" :
           "cancellation after C returns discards jobs before the next call");
    tv_script_free(script);
}

int main(void) {
    const char *setup = "globalThis.entered = 0; globalThis.completed = 0; globalThis.format = () => {"
                        "entered++; __host('cancel'); let total = 0; for (let sample = 0; sample < 100000; sample++) total += sample;"
                        "completed++; return String(total); };";
    const char *cases[] = {"throw {toString: format}", "throw {get stack() { return format(); }}",
                           "throw {stack: {toString: format}}"};
    const char *labels[] = {"call: message conversion stops", "module: stack getter stops", "call: stack conversion stops"};
    for (size_t index = 0; index < sizeof(cases) / sizeof(*cases); index++) {
        char source[512];
        snprintf(source, sizeof(source), "%s%s", setup, cases[index]);
        formatting(labels[index], source, index == 1);
    }

    TVScriptCancellation *token = tv_script_cancellation_create();
    TVScript *script = tv_script_create(token, checkpoint, 0, 0);
    char *error = tv_script_call(script, "throw {toString() {return 'fixture message'}, stack: 'fixture trace'}", 1);
    expect(contains(error, "fixture message\\nfixture trace"), "ordinary errors keep message and stack");
    free(error);
    error = tv_script_call(script, "globalThis.formatted = 0; ({toJSON() {throw {toString() {formatted++; return 'unused'}}}})", 1);
    expect(contains(error, "JSON") && value_is(script, "formatted", "{\"value\":0}"), "unused serialization exception is not formatted");
    free(error);
    expect(value_is(script, "globalThis.healthy = 0; globalThis.stale = 0; globalThis.base = 40;"
                            "Promise.resolve().then(() => healthy++); base", "{\"value\":40}"), "successful call leaves state for reuse");
    error = tv_script_call_cancellable(script, "Promise.resolve().then(() => stale++); __host('cancel'); 0", 1, token);
    expect(contains(error, "interrupt"), "operation observes its cancellation");
    free(error);
    expect(value_is(script, "Promise.resolve().then(() => [base + 2, healthy, stale])", "{\"value\":[42,1,0]}"),
           "next Promise runs healthy jobs but not cancelled jobs");
    error = tv_script_call_cancellable(script, "stale = 1", 1, token);
    free(error);
    expect(value_is(script, "stale", "{\"value\":0}"), "pre-cancelled call does not enter the expression");
    error = tv_script_call(script, "throw {toString() {__host('pause'); return 'note'}, get stack() {stale++; return 'trace'}}", 0.02);
    expect(contains(error, "interrupt") && value_is(script, "stale", "{\"value\":0}"), "expired deadline skips remaining formatting");
    free(error);
    error = tv_script_module(script, "deadline", "Promise.resolve().then(() => stale++); __host('pause')", 0.02);
    expect(contains(error, "interrupt") && value_is(script, "Promise.resolve().then(() => stale)", "{\"value\":0}"),
           "module deadline discards its pending job");
    free(error);
    tv_script_free(script);
    tv_script_cancellation_free(token);
    operation_boundary(1, 1, 0);
    operation_boundary(1, 1, 1);
    operation_boundary(1, 0, 0);
    operation_boundary(0, 0, 0);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}

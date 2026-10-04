#include "../Include/dx_log.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

static DxLogCallback g_log_callback = NULL;
static void         *g_log_user_data = NULL;
static DxLogLevel    g_min_level = DX_LOG_TRACE;

static const char *level_names[] = {
    "TRACE", "DEBUG", "INFO", "WARN", "ERROR"
};

void dx_log_init(void) {
    g_log_callback = NULL;
    g_log_user_data = NULL;
    g_min_level = DX_LOG_INFO;  // Default to INFO to avoid per-opcode TRACE/DEBUG flooding
}

void dx_log_set_callback(DxLogCallback callback, void *user_data) {
    g_log_callback = callback;
    g_log_user_data = user_data;
}

void dx_log_set_level(DxLogLevel min_level) {
    g_min_level = min_level;
}

void dx_log(DxLogLevel level, const char *tag, const char *fmt, ...) {
    if (level < g_min_level) return;

    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    if (g_log_callback) {
        g_log_callback(level, tag, buf, g_log_user_data);
    } else {
        fprintf(stderr, "[%s] %s: %s\n", level_names[level], tag ? tag : "DX", buf);
    }
}

const char *dx_result_string(DxResult result) {
    switch (result) {
        case DX_OK:                     return "OK";
        case DX_ERR_NULL_PTR:           return "NULL_PTR";
        case DX_ERR_INVALID_MAGIC:      return "INVALID_MAGIC";
        case DX_ERR_INVALID_FORMAT:     return "INVALID_FORMAT";
        case DX_ERR_OUT_OF_MEMORY:      return "OUT_OF_MEMORY";
        case DX_ERR_NOT_FOUND:          return "NOT_FOUND";
        case DX_ERR_UNSUPPORTED_OPCODE: return "UNSUPPORTED_OPCODE";
        case DX_ERR_CLASS_NOT_FOUND:    return "CLASS_NOT_FOUND";
        case DX_ERR_METHOD_NOT_FOUND:   return "METHOD_NOT_FOUND";
        case DX_ERR_FIELD_NOT_FOUND:    return "FIELD_NOT_FOUND";
        case DX_ERR_STACK_OVERFLOW:     return "STACK_OVERFLOW";
        case DX_ERR_STACK_UNDERFLOW:    return "STACK_UNDERFLOW";
        case DX_ERR_EXCEPTION:          return "EXCEPTION";
        case DX_ERR_VERIFICATION_FAILED:return "VERIFICATION_FAILED";
        case DX_ERR_IO:                 return "IO_ERROR";
        case DX_ERR_ZIP_INVALID:        return "ZIP_INVALID";
        case DX_ERR_AXML_INVALID:       return "AXML_INVALID";
        case DX_ERR_UNSUPPORTED_VERSION:return "UNSUPPORTED_VERSION";
        case DX_ERR_INTERNAL:           return "INTERNAL_ERROR";
        case DX_ERR_SIGNAL:            return "SIGNAL_CRASH";
        case DX_ERR_BUDGET_EXHAUSTED:  return "BUDGET_EXHAUSTED";
        case DX_ERR_CANCELLED:         return "CANCELLED";
    }
    return "UNKNOWN";
}

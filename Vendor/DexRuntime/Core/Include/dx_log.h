#ifndef DX_LOG_H
#define DX_LOG_H

#include "dx_types.h"

// Log callback type - Swift bridge sets this to forward logs to SwiftUI
typedef void (*DxLogCallback)(DxLogLevel level, const char *tag, const char *message, void *user_data);

void dx_log_init(void);
void dx_log_set_callback(DxLogCallback callback, void *user_data);
void dx_log_set_level(DxLogLevel min_level);

void dx_log(DxLogLevel level, const char *tag, const char *fmt, ...) __attribute__((format(printf, 3, 4)));

// Non-variadic wrapper callable from Swift
static inline void dx_log_msg(DxLogLevel level, const char *tag, const char *msg) {
    dx_log(level, tag, "%s", msg);
}

#define DX_TRACE(tag, ...) dx_log(DX_LOG_TRACE, tag, __VA_ARGS__)
#define DX_DEBUG(tag, ...) dx_log(DX_LOG_DEBUG, tag, __VA_ARGS__)
#define DX_INFO(tag, ...)  dx_log(DX_LOG_INFO,  tag, __VA_ARGS__)
#define DX_WARN(tag, ...)  dx_log(DX_LOG_WARN,  tag, __VA_ARGS__)
#define DX_ERROR(tag, ...) dx_log(DX_LOG_ERROR, tag, __VA_ARGS__)

const char *dx_result_string(DxResult result);

#endif // DX_LOG_H

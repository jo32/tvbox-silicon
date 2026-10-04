#ifndef TV_JAR_RUNTIME_H
#define TV_JAR_RUNTIME_H
#include <stddef.h>
#include <stdint.h>
// A narrow bridge to the experimental DEX interpreter. No JIT or subprocesses.
typedef struct {
    int status;
    uint32_t dex_count;
    uint32_t class_count;
    uint32_t native_library_count;
    uint64_t instructions;
    int32_t integer_value;
    char message[1024];
} TVJarResult;
TVJarResult tv_jar_inspect(const uint8_t *data, size_t size);
TVJarResult tv_jar_run_static_int(const uint8_t *data, size_t size, const char *class_name, const char *method_name);
#endif

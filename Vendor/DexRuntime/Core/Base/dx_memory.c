#include "../Include/dx_types.h"
#include "../Include/dx_log.h"
#include <stdlib.h>
#include <string.h>

#define TAG "Memory"

static uint64_t g_alloc_count = 0;
static uint64_t g_free_count = 0;
static uint64_t g_total_bytes = 0;

void *dx_malloc(size_t size) {
    void *ptr = malloc(size);
    if (ptr) {
        g_alloc_count++;
        g_total_bytes += size;
        memset(ptr, 0, size);
    } else {
        DX_ERROR(TAG, "malloc failed for %zu bytes", size);
    }
    return ptr;
}

void *dx_calloc(size_t count, size_t size) {
    return dx_malloc(count * size); // dx_malloc already zeroes memory
}

void *dx_realloc(void *ptr, size_t size) {
    void *new_ptr = realloc(ptr, size);
    if (!new_ptr && size > 0) {
        DX_ERROR(TAG, "realloc failed for %zu bytes", size);
    }
    return new_ptr;
}

void dx_free(void *ptr) {
    if (ptr) {
        g_free_count++;
        free(ptr);
    }
}

char *dx_strdup(const char *s) {
    if (!s) return NULL;
    size_t len = strlen(s) + 1;
    char *copy = (char *)dx_malloc(len);
    if (copy) {
        memcpy(copy, s, len);
    }
    return copy;
}

void dx_memory_stats(uint64_t *allocs, uint64_t *frees, uint64_t *bytes) {
    if (allocs) *allocs = g_alloc_count;
    if (frees) *frees = g_free_count;
    if (bytes) *bytes = g_total_bytes;
}

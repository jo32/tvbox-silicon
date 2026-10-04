#ifndef DX_MEMORY_H
#define DX_MEMORY_H

#include <stddef.h>
#include <stdint.h>

// Memory allocation functions
void *dx_malloc(size_t size);
void *dx_calloc(size_t count, size_t size);
void *dx_realloc(void *ptr, size_t size);
void  dx_free(void *ptr);
char *dx_strdup(const char *s);

// Memory statistics
void dx_memory_stats(uint64_t *allocs, uint64_t *frees, uint64_t *bytes);

#endif // DX_MEMORY_H

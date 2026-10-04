#include "../Include/dx_arena.h"
#include "../Include/dx_memory.h"
#include <string.h>

// Alignment for all arena allocations (8-byte)
#define DX_ARENA_ALIGN 8

static size_t align_up(size_t n, size_t align) {
    return (n + align - 1) & ~(align - 1);
}

// Allocate a new block with at least `min_data_size` usable bytes
static DxArenaBlock *arena_new_block(size_t min_data_size) {
    size_t total = sizeof(DxArenaBlock) + min_data_size;
    DxArenaBlock *block = (DxArenaBlock *)dx_malloc(total);
    if (!block) return NULL;
    block->next = NULL;
    block->size = min_data_size;
    block->used = 0;
    return block;
}

DxArena *dx_arena_create(size_t initial_size) {
    if (initial_size == 0) initial_size = DX_ARENA_DEFAULT_BLOCK_SIZE;

    DxArena *arena = (DxArena *)dx_malloc(sizeof(DxArena));
    if (!arena) return NULL;

    arena->block_size = initial_size;
    arena->total_alloc = 0;

    arena->head = arena_new_block(initial_size);
    if (!arena->head) {
        dx_free(arena);
        return NULL;
    }

    return arena;
}

void *dx_arena_alloc(DxArena *arena, size_t size) {
    if (!arena || size == 0) return NULL;

    size_t aligned = align_up(size, DX_ARENA_ALIGN);

    // Try to fit in the current head block
    DxArenaBlock *block = arena->head;
    if (block && block->used + aligned <= block->size) {
        void *ptr = block->data + block->used;
        block->used += aligned;
        arena->total_alloc += aligned;
        return ptr;
    }

    // Need a new block — at least as large as the request or the default
    size_t new_size = arena->block_size;
    if (aligned > new_size) new_size = aligned;

    DxArenaBlock *new_block = arena_new_block(new_size);
    if (!new_block) return NULL;

    // Prepend to list (new block becomes head)
    new_block->next = arena->head;
    arena->head = new_block;

    void *ptr = new_block->data + new_block->used;
    new_block->used += aligned;
    arena->total_alloc += aligned;
    return ptr;
}

void *dx_arena_calloc(DxArena *arena, size_t count, size_t elem_size) {
    size_t total = count * elem_size;
    void *ptr = dx_arena_alloc(arena, total);
    if (ptr) memset(ptr, 0, total);
    return ptr;
}

char *dx_arena_strdup(DxArena *arena, const char *s) {
    if (!s) return NULL;
    size_t len = strlen(s) + 1;
    char *copy = (char *)dx_arena_alloc(arena, len);
    if (copy) memcpy(copy, s, len);
    return copy;
}

void dx_arena_destroy(DxArena *arena) {
    if (!arena) return;
    DxArenaBlock *block = arena->head;
    while (block) {
        DxArenaBlock *next = block->next;
        dx_free(block);
        block = next;
    }
    dx_free(arena);
}

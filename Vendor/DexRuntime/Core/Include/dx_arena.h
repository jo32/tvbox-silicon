#ifndef DX_ARENA_H
#define DX_ARENA_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// Default arena block size: 64 KB
#define DX_ARENA_DEFAULT_BLOCK_SIZE (64u * 1024u)

// Arena block: a single contiguous allocation
typedef struct DxArenaBlock {
    struct DxArenaBlock *next;   // linked list of blocks
    size_t               size;   // total usable size of this block
    size_t               used;   // current bump pointer offset
    // data follows immediately after this header (flexible array member)
    uint8_t              data[];
} DxArenaBlock;

// Arena: linked list of blocks with bump-pointer allocation
typedef struct DxArena {
    DxArenaBlock *head;          // first block (most recently allocated)
    size_t        block_size;    // default size for new blocks
    size_t        total_alloc;   // total bytes allocated across all blocks
} DxArena;

// Create a new arena with the given default block size.
// Pass 0 for initial_size to use DX_ARENA_DEFAULT_BLOCK_SIZE.
DxArena *dx_arena_create(size_t initial_size);

// Allocate `size` bytes from the arena (8-byte aligned).
// Returns NULL only on malloc failure (when a new block is needed).
void *dx_arena_alloc(DxArena *arena, size_t size);

// Convenience: allocate and zero-fill
void *dx_arena_calloc(DxArena *arena, size_t count, size_t elem_size);

// Duplicate a string into the arena
char *dx_arena_strdup(DxArena *arena, const char *s);

// Free the entire arena and all its blocks.
void dx_arena_destroy(DxArena *arena);

#endif // DX_ARENA_H

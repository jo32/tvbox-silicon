#ifndef DX_APK_H
#define DX_APK_H

#include "dx_types.h"

// ZIP local file header
typedef struct {
    char     *filename;
    uint32_t  compressed_size;
    uint32_t  uncompressed_size;
    uint16_t  compression_method;
    uint32_t  data_offset;      // offset to compressed data in file
    uint32_t  crc32;            // expected CRC-32 of uncompressed data
} DxZipEntry;

typedef struct {
    uint8_t    *data;           // mmap'd or read file data
    size_t      data_size;
    DxZipEntry *entries;
    uint32_t    entry_count;
    bool        is_mmapped;     // true if data is memory-mapped
    size_t      mmap_size;      // size of mmap region (only valid if is_mmapped)
    bool        has_v2_sig;     // APK Signature Scheme V2 detected
    bool        has_v3_sig;     // APK Signature Scheme V3 detected
    bool        is_aab;         // true if archive has AAB directory structure
} DxApkFile;

// Parse an APK (ZIP) file from a buffer
DxResult dx_apk_open(const uint8_t *data, uint32_t size, DxApkFile **out);
void     dx_apk_close(DxApkFile *apk);

// Open a base APK with split APKs merged.
// Parses base_data as the primary APK, then for each split, parses its ZIP
// entries and merges them into the base entry list. Split entries override
// base entries with the same path (last-wins).
DxResult dx_apk_open_split(const uint8_t *base_data, uint32_t base_size,
                            const uint8_t **split_data, const uint32_t *split_sizes,
                            int split_count, DxApkFile **out);

// Open an APK file from disk using mmap for memory-mapped access
DxResult dx_apk_open_file(const char *path, DxApkFile **out);

// Find an entry by path (e.g., "classes.dex", "AndroidManifest.xml")
DxResult dx_apk_find_entry(const DxApkFile *apk, const char *path, const DxZipEntry **out);

// Extract an entry's data (caller must free *out_data)
// Handles STORE (no compression) and DEFLATE
DxResult dx_apk_extract_entry(const DxApkFile *apk, const DxZipEntry *entry,
                               uint8_t **out_data, uint32_t *out_size);

// Check if the parsed archive uses AAB (Android App Bundle) directory layout
bool dx_apk_is_aab(const DxApkFile *apk);

// Detect AAB layout by scanning entries for base/dex/ paths; sets apk->is_aab
void dx_apk_detect_aab(DxApkFile *apk);

// Streaming extraction callback: called with each chunk of uncompressed data
typedef void (*dx_stream_callback)(const uint8_t *chunk, uint32_t chunk_size, void *user_data);

// Extract an entry's data in streaming fashion (64KB chunks) to avoid
// allocating the entire uncompressed entry in memory at once.
// Handles STORE (no compression) and DEFLATE.
DxResult dx_apk_extract_entry_stream(const DxApkFile *apk, const DxZipEntry *entry,
                                      dx_stream_callback cb, void *user_data);

#endif // DX_APK_H

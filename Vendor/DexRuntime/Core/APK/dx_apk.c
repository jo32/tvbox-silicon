#include "../Include/dx_apk.h"
#include "../Include/dx_log.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#define TAG "APK"

#include "../Include/dx_memory.h"

// ZIP format constants
#define ZIP_LOCAL_HEADER_SIG    0x04034b50
#define ZIP_CENTRAL_DIR_SIG     0x02014b50
#define ZIP_END_CENTRAL_DIR_SIG 0x06054b50
#define ZIP_METHOD_STORE        0
#define ZIP_METHOD_DEFLATE      8
#define ZIP_MAX_DECOMPRESSED_SIZE (256U * 1024U * 1024U)  // 256 MB
#define ZIP_FLAG_ENCRYPTED        0x0001  // bit 0 of general purpose bit flag
#define ZIP_BOMB_RATIO          100  // max uncompressed/compressed ratio

// ZIP64 constants
#define ZIP64_EOCD_LOCATOR_SIG  0x07064b50
#define ZIP64_EOCD_SIG          0x06064b50

// APK Signing Block constants
#define APK_SIG_BLOCK_MAGIC     "APK Sig Block 42"
#define APK_SIG_BLOCK_MAGIC_LEN 16
#define APK_SIG_V2_BLOCK_ID     0x7109871a
#define APK_SIG_V3_BLOCK_ID     0xf05368c0

static uint16_t read_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t read_u32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

static uint64_t read_u64(const uint8_t *p) {
    return (uint64_t)read_u32(p) | ((uint64_t)read_u32(p + 4) << 32);
}

// Find End of Central Directory record
static const uint8_t *find_eocd(const uint8_t *data, size_t size) {
    // EOCD is at least 22 bytes; search backwards
    if (size < 22) return NULL;

    size_t max_search = size < 65557 ? size : 65557; // max comment size + EOCD
    for (size_t i = 22; i <= max_search; i++) {
        const uint8_t *p = data + size - i;
        if (read_u32(p) == ZIP_END_CENTRAL_DIR_SIG) {
            // Validate: comment length should match remaining bytes
            uint16_t comment_len = read_u16(p + 20);
            if ((size_t)(22 + comment_len) == i) {
                return p;
            }
            // Also accept if it's close (some tools are sloppy)
            // but keep searching for a better match
        }
    }

    // Fallback: accept any EOCD signature (less strict)
    for (size_t i = 22; i <= max_search; i++) {
        const uint8_t *p = data + size - i;
        if (read_u32(p) == ZIP_END_CENTRAL_DIR_SIG) {
            return p;
        }
    }
    return NULL;
}

// Check for ZIP64 End of Central Directory Locator before EOCD
// Returns true if ZIP64, and fills in entry_count and cd_offset from ZIP64 EOCD
static bool check_zip64(const uint8_t *data, size_t size, const uint8_t *eocd,
                         uint64_t *out_entry_count, uint64_t *out_cd_offset) {
    // ZIP64 EOCD Locator is 20 bytes and sits immediately before EOCD
    size_t eocd_offset = (size_t)(eocd - data);
    if (eocd_offset < 20) return false;

    const uint8_t *locator = eocd - 20;
    if (read_u32(locator) != ZIP64_EOCD_LOCATOR_SIG) return false;

    DX_INFO(TAG, "ZIP64 format detected — large archive support");

    // Locator layout: sig(4) + disk_number(4) + zip64_eocd_offset(8) + total_disks(4)
    uint64_t zip64_eocd_offset = read_u64(locator + 8);

    if (zip64_eocd_offset + 56 > size) {
        DX_WARN(TAG, "ZIP64 EOCD offset out of bounds");
        return false;
    }

    const uint8_t *z64eocd = data + zip64_eocd_offset;
    if (read_u32(z64eocd) != ZIP64_EOCD_SIG) {
        DX_WARN(TAG, "ZIP64 EOCD signature mismatch");
        return false;
    }

    // ZIP64 EOCD layout:
    // sig(4) + size_of_record(8) + version_made(2) + version_needed(2) +
    // disk_number(4) + disk_cd_start(4) + entries_on_disk(8) + total_entries(8) +
    // cd_size(8) + cd_offset(8) + ...
    *out_entry_count = read_u64(z64eocd + 32);
    *out_cd_offset = read_u64(z64eocd + 48);

    DX_INFO(TAG, "ZIP64: %llu entries, central dir at 0x%llx",
            (unsigned long long)*out_entry_count,
            (unsigned long long)*out_cd_offset);

    return true;
}

// Parse the APK Signing Block to detect V2/V3 signatures
static void parse_signing_block(const uint8_t *data, size_t size,
                                 const uint8_t *eocd, DxApkFile *apk) {
    // The central directory starts at cd_offset; the signing block is before it
    // We need to find "APK Sig Block 42" magic
    // The magic is at (block_end - 24) where block_end = cd_offset
    // Block structure:
    //   [8 bytes: block size (excluding this field and magic)]
    //   [id-value pairs...]
    //   [8 bytes: block size (same)]
    //   [16 bytes: "APK Sig Block 42"]

    uint16_t eocd_entry_count = read_u16(eocd + 10);
    uint32_t cd_offset_32 = read_u32(eocd + 16);

    // Use cd_offset as the end of the signing block region
    // For ZIP64 the cd_offset might be different, but the signing block
    // is always right before the central directory
    size_t cd_offset = cd_offset_32;

    // Need at least 32 bytes for the signing block footer (8 size + 16 magic + 8 size)
    if (cd_offset < 32 || cd_offset > size) return;

    // Check for magic "APK Sig Block 42" at cd_offset - 16
    const uint8_t *magic_ptr = data + cd_offset - APK_SIG_BLOCK_MAGIC_LEN;
    if (memcmp(magic_ptr, APK_SIG_BLOCK_MAGIC, APK_SIG_BLOCK_MAGIC_LEN) != 0) {
        return; // No signing block
    }

    // Read the block size (8 bytes before magic)
    if (cd_offset < 24) return;
    uint64_t block_size_footer = read_u64(data + cd_offset - 24);

    // The total block is: 8 (header size) + block_size_footer
    uint64_t total_block = 8 + block_size_footer;
    if (total_block > cd_offset || total_block < 32) {
        DX_WARN(TAG, "APK Signing Block size invalid");
        return;
    }

    const uint8_t *block_start = data + cd_offset - total_block;

    // Verify header block size matches footer
    uint64_t block_size_header = read_u64(block_start);
    if (block_size_header != block_size_footer) {
        DX_WARN(TAG, "APK Signing Block size mismatch (header=%llu, footer=%llu)",
                (unsigned long long)block_size_header,
                (unsigned long long)block_size_footer);
        return;
    }

    DX_INFO(TAG, "APK Signing Block found (%llu bytes)", (unsigned long long)total_block);

    // Parse id-value pairs within the block
    // Pairs start at block_start + 8, end at cd_offset - 24 (before footer size + magic)
    const uint8_t *pairs = block_start + 8;
    const uint8_t *pairs_end = data + cd_offset - 24;

    while (pairs + 12 <= pairs_end) {
        // Each pair: 8-byte length (includes 4-byte ID), 4-byte ID, then value
        uint64_t pair_len = read_u64(pairs);
        if (pair_len < 4 || pairs + 8 + pair_len > pairs_end) break;

        uint32_t pair_id = read_u32(pairs + 8);

        if (pair_id == APK_SIG_V2_BLOCK_ID) {
            apk->has_v2_sig = true;
            DX_INFO(TAG, "APK Signature Scheme V2 detected");
        } else if (pair_id == APK_SIG_V3_BLOCK_ID) {
            apk->has_v3_sig = true;
            DX_INFO(TAG, "APK Signature Scheme V3 detected");
        }

        pairs += 8 + pair_len;
    }

    if (!apk->has_v2_sig && !apk->has_v3_sig) {
        DX_DEBUG(TAG, "APK Signing Block present but no V2/V3 signatures found");
    }
}

DxResult dx_apk_open(const uint8_t *data, uint32_t size, DxApkFile **out) {
    if (!data || !out) return DX_ERR_NULL_PTR;
    if (size < 22) return DX_ERR_ZIP_INVALID;

    // Find End of Central Directory
    const uint8_t *eocd = find_eocd(data, size);
    if (!eocd) {
        DX_ERROR(TAG, "Cannot find End of Central Directory");
        return DX_ERR_ZIP_INVALID;
    }

    uint64_t entry_count;
    uint64_t cd_offset;

    // Check for ZIP64
    uint64_t z64_entry_count = 0;
    uint64_t z64_cd_offset = 0;
    bool is_zip64 = check_zip64(data, size, eocd, &z64_entry_count, &z64_cd_offset);

    if (is_zip64) {
        entry_count = z64_entry_count;
        cd_offset = z64_cd_offset;
    } else {
        entry_count = read_u16(eocd + 10);
        cd_offset = read_u32(eocd + 16);
    }

    DX_INFO(TAG, "ZIP: %llu entries, central dir at 0x%llx%s",
            (unsigned long long)entry_count,
            (unsigned long long)cd_offset,
            is_zip64 ? " (ZIP64)" : "");

    if (cd_offset >= size) {
        DX_ERROR(TAG, "Central directory offset out of bounds");
        return DX_ERR_ZIP_INVALID;
    }

    DxApkFile *apk = (DxApkFile *)dx_malloc(sizeof(DxApkFile));
    if (!apk) return DX_ERR_OUT_OF_MEMORY;
    memset(apk, 0, sizeof(DxApkFile));

    apk->data = (uint8_t *)data;
    apk->data_size = size;
    apk->entry_count = (uint32_t)entry_count;

    // Parse APK Signing Block (V2/V3 detection)
    parse_signing_block(data, size, eocd, apk);

    // Allocate entries — cap at a reasonable limit to avoid huge allocations
    if (entry_count > 0xFFFFFF) {
        DX_ERROR(TAG, "Entry count too large: %llu", (unsigned long long)entry_count);
        dx_free(apk);
        return DX_ERR_ZIP_INVALID;
    }

    apk->entries = (DxZipEntry *)dx_malloc(sizeof(DxZipEntry) * (uint32_t)entry_count);
    if (!apk->entries) {
        dx_free(apk);
        return DX_ERR_OUT_OF_MEMORY;
    }

    // Parse central directory
    const uint8_t *p = data + cd_offset;
    for (uint32_t i = 0; i < (uint32_t)entry_count; i++) {
        if (p + 46 > data + size) {
            DX_ERROR(TAG, "Central directory entry %u truncated", i);
            dx_apk_close(apk);
            return DX_ERR_ZIP_INVALID;
        }

        if (read_u32(p) != ZIP_CENTRAL_DIR_SIG) {
            DX_ERROR(TAG, "Invalid central directory signature at entry %u", i);
            dx_apk_close(apk);
            return DX_ERR_ZIP_INVALID;
        }

        uint16_t flags = read_u16(p + 8);
        uint16_t method = read_u16(p + 10);
        uint32_t compressed = read_u32(p + 20);
        uint32_t uncompressed = read_u32(p + 24);
        uint16_t name_len = read_u16(p + 28);
        uint16_t extra_len = read_u16(p + 30);
        uint16_t comment_len = read_u16(p + 32);
        uint32_t local_offset = read_u32(p + 42);

        // Encrypted entry detection: bit 0 of general purpose bit flag
        if (flags & ZIP_FLAG_ENCRYPTED) {
            // Extract name for logging before skipping
            char tmp_name[128];
            uint16_t copy_len = name_len < 127 ? name_len : 127;
            memcpy(tmp_name, p + 46, copy_len);
            tmp_name[copy_len] = '\0';
            DX_ERROR(TAG, "Encrypted ZIP entries not supported: %s", tmp_name);
            dx_apk_close(apk);
            return DX_ERR_INVALID_FORMAT;
        }

        // Extract filename
        char *name = (char *)dx_malloc(name_len + 1);
        if (!name) {
            dx_apk_close(apk);
            return DX_ERR_OUT_OF_MEMORY;
        }
        memcpy(name, p + 46, name_len);
        name[name_len] = '\0';

        // Path traversal prevention: reject entries with ".." in filename
        if (strstr(name, "..") != NULL) {
            DX_WARN(TAG, "Rejecting ZIP entry with path traversal: %s", name);
            dx_free(name);
            dx_apk_close(apk);
            return DX_ERR_ZIP_INVALID;
        }

        // Reject absolute paths (starting with /)
        if (name_len > 0 && name[0] == '/') {
            DX_WARN(TAG, "Rejecting ZIP entry with absolute path: %s", name);
            dx_free(name);
            dx_apk_close(apk);
            return DX_ERR_ZIP_INVALID;
        }

        // Read CRC32 from central directory (offset 16 in the entry)
        uint32_t crc32_expected = read_u32(p + 16);

        // Calculate data offset from local file header
        uint32_t data_offset = local_offset;
        if (local_offset + 30 <= size) {
            uint16_t local_name_len = read_u16(data + local_offset + 26);
            uint16_t local_extra_len = read_u16(data + local_offset + 28);
            data_offset = local_offset + 30 + local_name_len + local_extra_len;
        }

        apk->entries[i].filename = name;
        apk->entries[i].compression_method = method;
        apk->entries[i].compressed_size = compressed;
        apk->entries[i].uncompressed_size = uncompressed;
        apk->entries[i].data_offset = data_offset;
        apk->entries[i].crc32 = crc32_expected;

        DX_TRACE(TAG, "  [%u] %s (method=%u, size=%u/%u)",
                 i, name, method, compressed, uncompressed);

        p += 46 + name_len + extra_len + comment_len;
    }

    // Validate that we actually parsed all declared entries
    if (p > data + size) {
        DX_WARN(TAG, "Central directory entry count (%u) exceeds actual entries in file",
                (uint32_t)entry_count);
        dx_apk_close(apk);
        return DX_ERR_ZIP_INVALID;
    }

    *out = apk;
    DX_INFO(TAG, "APK opened successfully with %u entries", (uint32_t)entry_count);
    return DX_OK;
}

// --- AAB (Android App Bundle) detection ---

void dx_apk_detect_aab(DxApkFile *apk) {
    if (!apk) return;
    for (uint32_t i = 0; i < apk->entry_count; i++) {
        const char *name = apk->entries[i].filename;
        if (name && strncmp(name, "base/dex/", 9) == 0) {
            apk->is_aab = true;
            DX_INFO(TAG, "AAB format detected (found %s)", name);
            return;
        }
    }
}

bool dx_apk_is_aab(const DxApkFile *apk) {
    return apk && apk->is_aab;
}

// --- Split APK support ---

// Internal: parse ZIP central directory entries from a buffer into a caller-provided array.
// Returns DX_OK on success, fills out_entries and out_count.
// Caller must free each entry's filename and the array itself.
static DxResult parse_zip_entries(const uint8_t *data, uint32_t size,
                                   DxZipEntry **out_entries, uint32_t *out_count) {
    if (!data || size < 22 || !out_entries || !out_count) return DX_ERR_NULL_PTR;

    const uint8_t *eocd = find_eocd(data, size);
    if (!eocd) return DX_ERR_ZIP_INVALID;

    uint64_t entry_count;
    uint64_t cd_offset;
    uint64_t z64_ec = 0, z64_cd = 0;
    bool is_zip64 = check_zip64(data, size, eocd, &z64_ec, &z64_cd);
    if (is_zip64) {
        entry_count = z64_ec;
        cd_offset = z64_cd;
    } else {
        entry_count = read_u16(eocd + 10);
        cd_offset = read_u32(eocd + 16);
    }

    if (cd_offset >= size || entry_count > 0xFFFFFF) return DX_ERR_ZIP_INVALID;

    DxZipEntry *entries = (DxZipEntry *)dx_malloc(sizeof(DxZipEntry) * (uint32_t)entry_count);
    if (!entries) return DX_ERR_OUT_OF_MEMORY;

    const uint8_t *p = data + cd_offset;
    for (uint32_t i = 0; i < (uint32_t)entry_count; i++) {
        if (p + 46 > data + size) { goto fail; }
        if (read_u32(p) != ZIP_CENTRAL_DIR_SIG) { goto fail; }

        uint16_t flags = read_u16(p + 8);
        uint16_t method = read_u16(p + 10);
        uint32_t compressed = read_u32(p + 20);
        uint32_t uncompressed = read_u32(p + 24);
        uint16_t name_len = read_u16(p + 28);
        uint16_t extra_len = read_u16(p + 30);
        uint16_t comment_len = read_u16(p + 32);
        uint32_t local_offset = read_u32(p + 42);
        uint32_t crc32_expected = read_u32(p + 16);

        if (flags & ZIP_FLAG_ENCRYPTED) { goto fail; }

        char *name = (char *)dx_malloc(name_len + 1);
        if (!name) { goto fail; }
        memcpy(name, p + 46, name_len);
        name[name_len] = '\0';

        if (strstr(name, "..") != NULL || (name_len > 0 && name[0] == '/')) {
            dx_free(name);
            goto fail;
        }

        uint32_t data_offset = local_offset;
        if (local_offset + 30 <= size) {
            uint16_t local_name_len = read_u16(data + local_offset + 26);
            uint16_t local_extra_len = read_u16(data + local_offset + 28);
            data_offset = local_offset + 30 + local_name_len + local_extra_len;
        }

        entries[i].filename = name;
        entries[i].compression_method = method;
        entries[i].compressed_size = compressed;
        entries[i].uncompressed_size = uncompressed;
        entries[i].data_offset = data_offset;
        entries[i].crc32 = crc32_expected;

        p += 46 + name_len + extra_len + comment_len;
    }

    *out_entries = entries;
    *out_count = (uint32_t)entry_count;
    return DX_OK;

fail:
    // Free any filenames already allocated
    for (uint32_t j = 0; j < (uint32_t)entry_count; j++) {
        if (entries[j].filename) dx_free(entries[j].filename);
    }
    dx_free(entries);
    return DX_ERR_ZIP_INVALID;
}

DxResult dx_apk_open_split(const uint8_t *base_data, uint32_t base_size,
                            const uint8_t **split_data, const uint32_t *split_sizes,
                            int split_count, DxApkFile **out) {
    if (!base_data || !out) return DX_ERR_NULL_PTR;
    if (split_count > 0 && (!split_data || !split_sizes)) return DX_ERR_NULL_PTR;

    // Open the base APK normally
    DxResult res = dx_apk_open(base_data, base_size, out);
    if (res != DX_OK) return res;

    DxApkFile *apk = *out;

    // For each split, parse its entries and merge into the base
    for (int s = 0; s < split_count; s++) {
        if (!split_data[s] || split_sizes[s] < 22) {
            DX_WARN(TAG, "Split APK %d: invalid data (size=%u), skipping", s, split_sizes[s]);
            continue;
        }

        DxZipEntry *split_entries = NULL;
        uint32_t split_entry_count = 0;

        res = parse_zip_entries(split_data[s], split_sizes[s], &split_entries, &split_entry_count);
        if (res != DX_OK) {
            DX_WARN(TAG, "Split APK %d: failed to parse ZIP entries (error %d), skipping", s, res);
            continue;
        }

        if (split_entry_count == 0) {
            dx_free(split_entries);
            continue;
        }

        DX_INFO(TAG, "Split APK %d: merging %u entries", s, split_entry_count);

        // For each split entry, check if it overrides a base entry (same path).
        // Mark overridden entries and count new entries.
        uint32_t new_count = 0;
        bool *is_override = (bool *)dx_malloc(sizeof(bool) * split_entry_count);
        if (!is_override) {
            for (uint32_t j = 0; j < split_entry_count; j++)
                dx_free(split_entries[j].filename);
            dx_free(split_entries);
            continue;
        }
        memset(is_override, 0, sizeof(bool) * split_entry_count);

        for (uint32_t si = 0; si < split_entry_count; si++) {
            bool found = false;
            for (uint32_t bi = 0; bi < apk->entry_count; bi++) {
                if (strcmp(apk->entries[bi].filename, split_entries[si].filename) == 0) {
                    // Override: replace base entry data with split entry data
                    // But we need to adjust data_offset to point into split_data[s]
                    // Since the APK struct only has one data pointer, we store the
                    // split entry as-is; callers need the split data buffer kept alive.
                    // For now: replace the base entry in-place.
                    dx_free(apk->entries[bi].filename);
                    apk->entries[bi].filename = split_entries[si].filename;
                    apk->entries[bi].compression_method = split_entries[si].compression_method;
                    apk->entries[bi].compressed_size = split_entries[si].compressed_size;
                    apk->entries[bi].uncompressed_size = split_entries[si].uncompressed_size;
                    apk->entries[bi].data_offset = split_entries[si].data_offset;
                    apk->entries[bi].crc32 = split_entries[si].crc32;
                    split_entries[si].filename = NULL; // ownership transferred
                    is_override[si] = true;
                    found = true;
                    DX_DEBUG(TAG, "Split %d: overriding entry '%s'", s, apk->entries[bi].filename);
                    break;
                }
            }
            if (!found) {
                new_count++;
            }
        }

        // Append non-overridden split entries to the base entries array
        if (new_count > 0) {
            uint32_t total = apk->entry_count + new_count;
            DxZipEntry *expanded = (DxZipEntry *)dx_realloc(apk->entries,
                                                             sizeof(DxZipEntry) * total);
            if (expanded) {
                apk->entries = expanded;
                uint32_t idx = apk->entry_count;
                for (uint32_t si = 0; si < split_entry_count; si++) {
                    if (!is_override[si]) {
                        apk->entries[idx] = split_entries[si];
                        split_entries[si].filename = NULL; // ownership transferred
                        idx++;
                    }
                }
                apk->entry_count = total;
                DX_INFO(TAG, "Split %d: added %u new entries (total now %u)", s, new_count, total);
            }
        }

        // Free remaining split entries (filenames that were transferred are NULL)
        for (uint32_t si = 0; si < split_entry_count; si++) {
            if (split_entries[si].filename) {
                dx_free(split_entries[si].filename);
            }
        }
        dx_free(split_entries);
        dx_free(is_override);
    }

    return DX_OK;
}

DxResult dx_apk_open_file(const char *path, DxApkFile **out) {
    if (!path || !out) return DX_ERR_NULL_PTR;

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        DX_ERROR(TAG, "Cannot open file: %s", path);
        return DX_ERR_IO;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        DX_ERROR(TAG, "Cannot stat file: %s", path);
        close(fd);
        return DX_ERR_IO;
    }

    size_t file_size = (size_t)st.st_size;

    void *mapped = mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd); // fd no longer needed after mmap

    if (mapped == MAP_FAILED) {
        DX_ERROR(TAG, "mmap failed for: %s", path);
        return DX_ERR_IO;
    }

    DX_INFO(TAG, "Memory-mapped file: %s (%zu bytes)", path, file_size);

    // Use dx_apk_open to parse; it expects uint32_t size but we store real size on the struct
    // For files > 4GB we need ZIP64 anyway; cap the parse size for the open call
    uint32_t parse_size = file_size > UINT32_MAX ? UINT32_MAX : (uint32_t)file_size;

    DxResult result = dx_apk_open((const uint8_t *)mapped, parse_size, out);
    if (result != DX_OK) {
        munmap(mapped, file_size);
        return result;
    }

    // Mark as memory-mapped so dx_apk_close uses munmap
    (*out)->is_mmapped = true;
    (*out)->mmap_size = file_size;
    (*out)->data_size = file_size;

    return DX_OK;
}

void dx_apk_close(DxApkFile *apk) {
    if (!apk) return;
    for (uint32_t i = 0; i < apk->entry_count; i++) {
        dx_free(apk->entries[i].filename);
    }
    dx_free(apk->entries);

    if (apk->is_mmapped && apk->data) {
        munmap(apk->data, apk->mmap_size);
    }

    dx_free(apk);
}

DxResult dx_apk_find_entry(const DxApkFile *apk, const char *path, const DxZipEntry **out) {
    if (!apk || !path || !out) return DX_ERR_NULL_PTR;

    for (uint32_t i = 0; i < apk->entry_count; i++) {
        if (strcmp(apk->entries[i].filename, path) == 0) {
            *out = &apk->entries[i];
            return DX_OK;
        }
    }

    DX_DEBUG(TAG, "Entry not found: %s", path);
    return DX_ERR_NOT_FOUND;
}

DxResult dx_apk_extract_entry(const DxApkFile *apk, const DxZipEntry *entry,
                               uint8_t **out_data, uint32_t *out_size) {
    if (!apk || !entry || !out_data || !out_size) return DX_ERR_NULL_PTR;

    if (entry->data_offset + entry->compressed_size > apk->data_size) {
        DX_ERROR(TAG, "Entry data out of bounds: %s", entry->filename);
        return DX_ERR_ZIP_INVALID;
    }

    // Integer overflow protection: reject unreasonable uncompressed sizes (256MB limit)
    if (entry->uncompressed_size > ZIP_MAX_DECOMPRESSED_SIZE) {
        DX_WARN(TAG, "Entry %s decompressed size (%u) exceeds 256MB limit",
                entry->filename, entry->uncompressed_size);
        return DX_ERR_INVALID_FORMAT;
    }

    // ZIP bomb detection: check compression ratio (> 100:1)
    if (entry->compression_method == ZIP_METHOD_DEFLATE &&
        entry->compressed_size > 0 &&
        entry->uncompressed_size / entry->compressed_size > ZIP_BOMB_RATIO) {
        DX_WARN(TAG, "ZIP bomb detected for %s: ratio %u/%u = %u",
                entry->filename, entry->uncompressed_size, entry->compressed_size,
                entry->uncompressed_size / entry->compressed_size);
        return DX_ERR_INVALID_FORMAT;
    }

    const uint8_t *compressed_data = apk->data + entry->data_offset;

    if (entry->compression_method == ZIP_METHOD_STORE) {
        // No compression - copy directly
        uint8_t *buf = (uint8_t *)dx_malloc(entry->uncompressed_size);
        if (!buf) return DX_ERR_OUT_OF_MEMORY;
        memcpy(buf, compressed_data, entry->uncompressed_size);

        // CRC32 validation
        uint32_t actual_crc = (uint32_t)crc32(0L, buf, entry->uncompressed_size);
        if (entry->crc32 != 0 && actual_crc != entry->crc32) {
            DX_WARN(TAG, "CRC32 mismatch for %s: expected 0x%08x, got 0x%08x",
                    entry->filename, entry->crc32, actual_crc);
            dx_free(buf);
            return DX_ERR_ZIP_INVALID;
        }

        *out_data = buf;
        *out_size = entry->uncompressed_size;
        return DX_OK;
    }

    if (entry->compression_method == ZIP_METHOD_DEFLATE) {
        // Inflate using zlib
        uint8_t *buf = (uint8_t *)dx_malloc(entry->uncompressed_size);
        if (!buf) return DX_ERR_OUT_OF_MEMORY;

        z_stream strm;
        memset(&strm, 0, sizeof(strm));
        strm.next_in = (Bytef *)compressed_data;
        strm.avail_in = entry->compressed_size;
        strm.next_out = (Bytef *)buf;
        strm.avail_out = entry->uncompressed_size;

        // -MAX_WBITS for raw deflate (no zlib/gzip header)
        if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) {
            dx_free(buf);
            DX_ERROR(TAG, "inflateInit2 failed for %s", entry->filename);
            return DX_ERR_ZIP_INVALID;
        }

        int ret = inflate(&strm, Z_FINISH);
        inflateEnd(&strm);

        if (ret != Z_STREAM_END) {
            dx_free(buf);
            DX_ERROR(TAG, "inflate failed for %s: %d", entry->filename, ret);
            return DX_ERR_ZIP_INVALID;
        }

        // CRC32 validation
        uint32_t actual_crc = (uint32_t)crc32(0L, buf, entry->uncompressed_size);
        if (entry->crc32 != 0 && actual_crc != entry->crc32) {
            DX_WARN(TAG, "CRC32 mismatch for %s: expected 0x%08x, got 0x%08x",
                    entry->filename, entry->crc32, actual_crc);
            dx_free(buf);
            return DX_ERR_ZIP_INVALID;
        }

        *out_data = buf;
        *out_size = entry->uncompressed_size;
        return DX_OK;
    }

    DX_ERROR(TAG, "Unsupported compression method %u for %s",
             entry->compression_method, entry->filename);
    return DX_ERR_ZIP_INVALID;
}

// Streaming chunk size: 64 KB
#define DX_STREAM_CHUNK_SIZE (64U * 1024U)

DxResult dx_apk_extract_entry_stream(const DxApkFile *apk, const DxZipEntry *entry,
                                      dx_stream_callback cb, void *user_data) {
    if (!apk || !entry || !cb) return DX_ERR_NULL_PTR;

    if (entry->data_offset + entry->compressed_size > apk->data_size) {
        DX_ERROR(TAG, "Entry data out of bounds: %s", entry->filename);
        return DX_ERR_ZIP_INVALID;
    }

    // Integer overflow protection: reject unreasonable uncompressed sizes (256MB limit)
    if (entry->uncompressed_size > ZIP_MAX_DECOMPRESSED_SIZE) {
        DX_WARN(TAG, "Entry %s decompressed size (%u) exceeds 256MB limit",
                entry->filename, entry->uncompressed_size);
        return DX_ERR_INVALID_FORMAT;
    }

    // ZIP bomb detection: check compression ratio (> 100:1)
    if (entry->compression_method == ZIP_METHOD_DEFLATE &&
        entry->compressed_size > 0 &&
        entry->uncompressed_size / entry->compressed_size > ZIP_BOMB_RATIO) {
        DX_WARN(TAG, "ZIP bomb detected for %s: ratio %u/%u = %u",
                entry->filename, entry->uncompressed_size, entry->compressed_size,
                entry->uncompressed_size / entry->compressed_size);
        return DX_ERR_INVALID_FORMAT;
    }

    const uint8_t *compressed_data = apk->data + entry->data_offset;

    if (entry->compression_method == ZIP_METHOD_STORE) {
        // No compression - stream raw data in 64KB chunks
        uint32_t remaining = entry->uncompressed_size;
        const uint8_t *ptr = compressed_data;

        while (remaining > 0) {
            uint32_t chunk = remaining > DX_STREAM_CHUNK_SIZE ? DX_STREAM_CHUNK_SIZE : remaining;
            cb(ptr, chunk, user_data);
            ptr += chunk;
            remaining -= chunk;
        }

        return DX_OK;
    }

    if (entry->compression_method == ZIP_METHOD_DEFLATE) {
        // Inflate in streaming fashion using a 64KB output buffer
        uint8_t *out_buf = (uint8_t *)dx_malloc(DX_STREAM_CHUNK_SIZE);
        if (!out_buf) return DX_ERR_OUT_OF_MEMORY;

        z_stream strm;
        memset(&strm, 0, sizeof(strm));
        strm.next_in = (Bytef *)compressed_data;
        strm.avail_in = entry->compressed_size;

        // -MAX_WBITS for raw deflate (no zlib/gzip header)
        if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) {
            dx_free(out_buf);
            DX_ERROR(TAG, "inflateInit2 failed for %s", entry->filename);
            return DX_ERR_ZIP_INVALID;
        }

        int ret;
        do {
            strm.next_out = (Bytef *)out_buf;
            strm.avail_out = DX_STREAM_CHUNK_SIZE;

            ret = inflate(&strm, Z_NO_FLUSH);
            if (ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR) {
                inflateEnd(&strm);
                dx_free(out_buf);
                DX_ERROR(TAG, "inflate failed for %s: %d", entry->filename, ret);
                return DX_ERR_ZIP_INVALID;
            }

            uint32_t produced = DX_STREAM_CHUNK_SIZE - strm.avail_out;
            if (produced > 0) {
                cb(out_buf, produced, user_data);
            }
        } while (ret != Z_STREAM_END);

        inflateEnd(&strm);
        dx_free(out_buf);
        return DX_OK;
    }

    DX_ERROR(TAG, "Unsupported compression method %u for %s",
             entry->compression_method, entry->filename);
    return DX_ERR_ZIP_INVALID;
}

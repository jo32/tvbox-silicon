#include "../Include/dx_dex.h"
#include "../Include/dx_vm.h"
#include "../Include/dx_log.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include <CommonCrypto/CommonDigest.h>

#define TAG "DEX"
#define DX_MAX_DEX_SIZE (100u * 1024u * 1024u)  // 100 MB limit for DEX files

#include "../Include/dx_memory.h"

static uint16_t read_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t read_u32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

// Read ULEB128 (unsigned LEB128)
static uint32_t read_uleb128(const uint8_t **pp) {
    const uint8_t *p = *pp;
    uint32_t result = 0;
    int shift = 0;
    uint8_t byte;
    do {
        byte = *p++;
        result |= (uint32_t)(byte & 0x7F) << shift;
        shift += 7;
    } while (byte & 0x80);
    *pp = p;
    return result;
}

// Decode MUTF-8 string from DEX string_data section
// If arena is non-NULL, allocates from the arena; otherwise uses dx_malloc.
static char *decode_mutf8_ex(const uint8_t *data, uint32_t offset, uint32_t file_size, DxArena *arena) {
    if (offset >= file_size) {
        return arena ? dx_arena_strdup(arena, "") : dx_strdup("");
    }

    const uint8_t *p = data + offset;
    const uint8_t *end = data + file_size;
    // First: ULEB128 utf16_size (number of UTF-16 code units)
    uint32_t utf16_size = read_uleb128(&p);

    // Allocate output buffer (max 3 bytes per UTF-16 code unit + null)
    size_t max_len = (size_t)utf16_size * 3 + 1;
    char *s = arena ? (char *)dx_arena_alloc(arena, max_len)
                    : (char *)dx_malloc(max_len);
    if (!s) return NULL;

    size_t out = 0;
    while (p < end && out < max_len - 1) {
        uint8_t b0 = *p;
        if (b0 == 0) break; // MUTF-8 null terminator

        if ((b0 & 0x80) == 0) {
            // Single byte: 0xxxxxxx
            s[out++] = (char)b0;
            p++;
        } else if ((b0 & 0xE0) == 0xC0) {
            // Two bytes: 110xxxxx 10xxxxxx
            if (p + 1 >= end) break;
            uint8_t b1 = p[1];
            if (b0 == 0xC0 && b1 == 0x80) {
                // MUTF-8 encoded null (U+0000)
                s[out++] = '\0';
            } else {
                s[out++] = (char)b0;
                s[out++] = (char)b1;
            }
            p += 2;
        } else if ((b0 & 0xF0) == 0xE0) {
            // Three bytes: 1110xxxx 10xxxxxx 10xxxxxx
            if (p + 2 >= end) break;
            s[out++] = (char)b0;
            s[out++] = (char)p[1];
            s[out++] = (char)p[2];
            p += 3;
        } else {
            // Skip invalid byte
            s[out++] = '?';
            p++;
        }
    }
    s[out] = '\0';
    return s;
}

// Legacy wrapper for non-arena callers
static char *decode_mutf8(const uint8_t *data, uint32_t offset, uint32_t file_size) {
    return decode_mutf8_ex(data, offset, file_size, NULL);
}

DxResult dx_dex_parse(const uint8_t *data, uint32_t size, DxDexFile **out) {
    if (!data || !out) return DX_ERR_NULL_PTR;
    if (size < sizeof(DxDexHeader)) {
        DX_ERROR(TAG, "File too small: %u bytes", size);
        return DX_ERR_INVALID_FORMAT;
    }
    if (size > DX_MAX_DEX_SIZE) {
        DX_ERROR(TAG, "DEX file too large: %u bytes (limit %u)", size, DX_MAX_DEX_SIZE);
        return DX_ERR_INVALID_FORMAT;
    }

    // Validate magic
    if (memcmp(data, DEX_MAGIC, 4) != 0) {
        DX_ERROR(TAG, "Invalid DEX magic");
        return DX_ERR_INVALID_MAGIC;
    }

    // Check version (035, 037, 038, 039)
    char version[4] = {(char)data[4], (char)data[5], (char)data[6], 0};
    DX_INFO(TAG, "DEX version: %s", version);

    DxDexFile *dex = (DxDexFile *)dx_malloc(sizeof(DxDexFile));
    if (!dex) return DX_ERR_OUT_OF_MEMORY;

    dex->raw_data = data;
    dex->raw_size = size;

    // Create arena for parse-time allocations (string tables)
    dex->arena = dx_arena_create(0);  // default 64 KB blocks
    if (!dex->arena) {
        dx_free(dex);
        return DX_ERR_OUT_OF_MEMORY;
    }

    // Parse header
    memcpy(&dex->header, data, sizeof(DxDexHeader));

    DX_INFO(TAG, "DEX: %u strings, %u types, %u protos, %u fields, %u methods, %u classes",
            dex->header.string_ids_size, dex->header.type_ids_size,
            dex->header.proto_ids_size, dex->header.field_ids_size,
            dex->header.method_ids_size, dex->header.class_defs_size);

    // Validate endian tag
    if (dex->header.endian_tag != 0x12345678) {
        DX_WARN(TAG, "Invalid endian_tag: 0x%08x (expected 0x12345678)", dex->header.endian_tag);
        dx_free(dex);
        return DX_ERR_INVALID_FORMAT;
    }

    // Validate file size
    if (dex->header.file_size != size) {
        DX_WARN(TAG, "Header file_size (%u) != actual size (%u)",
                dex->header.file_size, size);
    }

    // Adler32 checksum validation (over bytes 12..file_size)
    if (size > 12) {
        uLong computed_checksum = adler32(1L, data + 12, size - 12);
        if ((uint32_t)computed_checksum != dex->header.checksum) {
            DX_WARN(TAG, "DEX checksum mismatch: expected 0x%08x, got 0x%08x",
                    dex->header.checksum, (uint32_t)computed_checksum);
        }
    }

    // SHA-1 signature validation (over bytes 32..file_size)
    if (size > 32) {
        uint8_t computed_sha1[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(data + 32, (CC_LONG)(size - 32), computed_sha1);
        if (memcmp(computed_sha1, dex->header.signature, 20) != 0) {
            DX_WARN(TAG, "DEX SHA-1 signature mismatch");
        }
    }

    // Hidden API metadata detection (DEX version 039+)
    if (memcmp(version, "039", 3) >= 0) {
        DX_INFO(TAG, "DEX 039+: hidden API restrictions may apply");
    }

    // Initialize map items
    dex->map_items = NULL;
    dex->map_item_count = 0;

    // Parse map section
    {
        uint32_t map_off = dex->header.map_off;
        if (map_off != 0 && map_off + 4 <= size) {
            uint32_t map_count = read_u32(data + map_off);
            if (map_count > 0 && map_off + 4 + (uint64_t)map_count * 12 <= size) {
                dex->map_items = (DxMapItem *)dx_malloc(sizeof(DxMapItem) * map_count);
                if (dex->map_items) {
                    dex->map_item_count = map_count;
                    const uint8_t *mp = data + map_off + 4;
                    for (uint32_t i = 0; i < map_count; i++) {
                        dex->map_items[i].type = read_u16(mp + i * 12);
                        // mp + i*12 + 2 is unused uint16
                        dex->map_items[i].size = read_u32(mp + i * 12 + 4);
                        dex->map_items[i].offset = read_u32(mp + i * 12 + 8);
                    }
                    DX_INFO(TAG, "Parsed %u map items", map_count);
                }
            }
        }
    }

    // Validate map_off and cross-check map items against header
    if (dex->header.map_off != 0) {
        uint32_t mo = dex->header.map_off;
        if (mo + 4 > size) {
            DX_WARN(TAG, "map_off 0x%x out of file bounds (size=0x%x)", mo, size);
            dx_free(dex->map_items);
            dex->map_items = NULL;
            dex->map_item_count = 0;
        } else {
            uint32_t mc = read_u32(data + mo);
            if (mc > 1000) {
                DX_WARN(TAG, "map_list item count %u unreasonably large (>1000)", mc);
            }
            if (mo + 4 + (uint64_t)mc * 12 > size) {
                DX_WARN(TAG, "map_list extends past file end (off=0x%x, count=%u)", mo, mc);
            }
            // Cross-check key map items against header offsets
            // DEX map_list item type constants
            #define MAP_TYPE_STRING_ID  0x0001
            #define MAP_TYPE_TYPE_ID    0x0002
            #define MAP_TYPE_PROTO_ID   0x0003
            #define MAP_TYPE_FIELD_ID   0x0004
            #define MAP_TYPE_METHOD_ID  0x0005
            #define MAP_TYPE_CLASS_DEF  0x0006
            for (uint32_t mi = 0; mi < dex->map_item_count; mi++) {
                DxMapItem *item = &dex->map_items[mi];
                uint32_t expected_off = 0;
                uint32_t expected_size = 0;
                switch (item->type) {
                    case MAP_TYPE_STRING_ID:
                        expected_off = dex->header.string_ids_off;
                        expected_size = dex->header.string_ids_size;
                        break;
                    case MAP_TYPE_TYPE_ID:
                        expected_off = dex->header.type_ids_off;
                        expected_size = dex->header.type_ids_size;
                        break;
                    case MAP_TYPE_PROTO_ID:
                        expected_off = dex->header.proto_ids_off;
                        expected_size = dex->header.proto_ids_size;
                        break;
                    case MAP_TYPE_FIELD_ID:
                        expected_off = dex->header.field_ids_off;
                        expected_size = dex->header.field_ids_size;
                        break;
                    case MAP_TYPE_METHOD_ID:
                        expected_off = dex->header.method_ids_off;
                        expected_size = dex->header.method_ids_size;
                        break;
                    case MAP_TYPE_CLASS_DEF:
                        expected_off = dex->header.class_defs_off;
                        expected_size = dex->header.class_defs_size;
                        break;
                    default:
                        continue; // skip non-header-referenced types
                }
                if (expected_size > 0) {
                    if (item->offset != expected_off) {
                        DX_WARN(TAG, "map item type 0x%04x offset 0x%x != header offset 0x%x",
                                item->type, item->offset, expected_off);
                    }
                    if (item->size != expected_size) {
                        DX_WARN(TAG, "map item type 0x%04x size %u != header size %u",
                                item->type, item->size, expected_size);
                    }
                }
            }
            #undef MAP_TYPE_STRING_ID
            #undef MAP_TYPE_TYPE_ID
            #undef MAP_TYPE_PROTO_ID
            #undef MAP_TYPE_FIELD_ID
            #undef MAP_TYPE_METHOD_ID
            #undef MAP_TYPE_CLASS_DEF
        }
    }

    // Validate table offsets are within file bounds
    if (dex->header.string_ids_size > 0 &&
        (dex->header.string_ids_off >= size ||
         dex->header.string_ids_off + (uint64_t)dex->header.string_ids_size * 4 > size)) {
        DX_WARN(TAG, "string_ids table (off=0x%x, count=%u) out of bounds",
                dex->header.string_ids_off, dex->header.string_ids_size);
        dx_free(dex);
        return DX_ERR_INVALID_FORMAT;
    }
    if (dex->header.type_ids_size > 0 &&
        (dex->header.type_ids_off >= size ||
         dex->header.type_ids_off + (uint64_t)dex->header.type_ids_size * 4 > size)) {
        DX_WARN(TAG, "type_ids table (off=0x%x, count=%u) out of bounds",
                dex->header.type_ids_off, dex->header.type_ids_size);
        dx_free(dex);
        return DX_ERR_INVALID_FORMAT;
    }
    if (dex->header.proto_ids_size > 0 &&
        (dex->header.proto_ids_off >= size ||
         dex->header.proto_ids_off + (uint64_t)dex->header.proto_ids_size * 12 > size)) {
        DX_WARN(TAG, "proto_ids table (off=0x%x, count=%u) out of bounds",
                dex->header.proto_ids_off, dex->header.proto_ids_size);
        dx_free(dex);
        return DX_ERR_INVALID_FORMAT;
    }
    if (dex->header.field_ids_size > 0 &&
        (dex->header.field_ids_off >= size ||
         dex->header.field_ids_off + (uint64_t)dex->header.field_ids_size * 8 > size)) {
        DX_WARN(TAG, "field_ids table (off=0x%x, count=%u) out of bounds",
                dex->header.field_ids_off, dex->header.field_ids_size);
        dx_free(dex);
        return DX_ERR_INVALID_FORMAT;
    }
    if (dex->header.method_ids_size > 0 &&
        (dex->header.method_ids_off >= size ||
         dex->header.method_ids_off + (uint64_t)dex->header.method_ids_size * 8 > size)) {
        DX_WARN(TAG, "method_ids table (off=0x%x, count=%u) out of bounds",
                dex->header.method_ids_off, dex->header.method_ids_size);
        dx_free(dex);
        return DX_ERR_INVALID_FORMAT;
    }
    if (dex->header.class_defs_size > 0 &&
        (dex->header.class_defs_off >= size ||
         dex->header.class_defs_off + (uint64_t)dex->header.class_defs_size * 32 > size)) {
        DX_WARN(TAG, "class_defs table (off=0x%x, count=%u) out of bounds",
                dex->header.class_defs_off, dex->header.class_defs_size);
        dx_free(dex);
        return DX_ERR_INVALID_FORMAT;
    }

    // Parse string table — lazy: store only raw offsets, decode on first access
    dex->string_count = dex->header.string_ids_size;
    if (dex->string_count > 10000000) {  // 10M strings max
        DX_ERROR(TAG, "String count %u would overflow allocation", dex->string_count);
        dx_free(dex);
        return DX_ERR_INVALID_FORMAT;
    }
    dex->strings = (char **)dx_arena_calloc(dex->arena, dex->string_count, sizeof(char *));
    if (!dex->strings) goto fail;
    // strings[] initialized to NULL (lazy decode on first access)

    dex->string_data_offsets = (uint32_t *)dx_arena_alloc(dex->arena,
                                    sizeof(uint32_t) * dex->string_count);
    if (!dex->string_data_offsets) goto fail;

    for (uint32_t i = 0; i < dex->string_count; i++) {
        uint32_t string_id_off = dex->header.string_ids_off + i * 4;
        if (string_id_off + 4 > size) {
            dex->string_data_offsets[i] = UINT32_MAX; // sentinel: invalid
            continue;
        }
        uint32_t string_data_off = read_u32(data + string_id_off);
        dex->string_data_offsets[i] = string_data_off;
    }

    // Parse type IDs
    dex->type_count = dex->header.type_ids_size;
    if (dex->type_count > 10000000) {  // 10M types max
        DX_ERROR(TAG, "Type count %u would overflow allocation", dex->type_count);
        goto fail;
    }
    dex->type_ids = (DxDexTypeId *)dx_malloc(sizeof(DxDexTypeId) * dex->type_count);
    if (!dex->type_ids) goto fail;
    for (uint32_t i = 0; i < dex->type_count; i++) {
        uint32_t off = dex->header.type_ids_off + i * 4;
        if (off + 4 > size) break;
        dex->type_ids[i].descriptor_idx = read_u32(data + off);
    }

    // Parse proto IDs
    dex->proto_count = dex->header.proto_ids_size;
    if (dex->proto_count > 10000000) {  // 10M protos max
        DX_ERROR(TAG, "Proto count %u would overflow allocation", dex->proto_count);
        goto fail;
    }
    dex->proto_ids = (DxDexProtoId *)dx_malloc(sizeof(DxDexProtoId) * dex->proto_count);
    if (!dex->proto_ids) goto fail;
    for (uint32_t i = 0; i < dex->proto_count; i++) {
        uint32_t off = dex->header.proto_ids_off + i * 12;
        if (off + 12 > size) break;
        dex->proto_ids[i].shorty_idx = read_u32(data + off);
        dex->proto_ids[i].return_type_idx = read_u32(data + off + 4);
        dex->proto_ids[i].parameters_off = read_u32(data + off + 8);
    }

    // Parse field IDs
    dex->field_count = dex->header.field_ids_size;
    if (dex->field_count > 10000000) {  // 10M fields max
        DX_ERROR(TAG, "Field count %u would overflow allocation", dex->field_count);
        goto fail;
    }
    dex->field_ids = (DxDexFieldId *)dx_malloc(sizeof(DxDexFieldId) * dex->field_count);
    if (!dex->field_ids) goto fail;
    for (uint32_t i = 0; i < dex->field_count; i++) {
        uint32_t off = dex->header.field_ids_off + i * 8;
        if (off + 8 > size) break;
        dex->field_ids[i].class_idx = read_u16(data + off);
        dex->field_ids[i].type_idx = read_u16(data + off + 2);
        dex->field_ids[i].name_idx = read_u32(data + off + 4);
    }

    // Parse method IDs
    dex->method_count = dex->header.method_ids_size;
    if (dex->method_count > 10000000) {  // 10M methods max
        DX_ERROR(TAG, "Method count %u would overflow allocation", dex->method_count);
        goto fail;
    }
    dex->method_ids = (DxDexMethodId *)dx_malloc(sizeof(DxDexMethodId) * dex->method_count);
    if (!dex->method_ids) goto fail;
    for (uint32_t i = 0; i < dex->method_count; i++) {
        uint32_t off = dex->header.method_ids_off + i * 8;
        if (off + 8 > size) break;
        dex->method_ids[i].class_idx = read_u16(data + off);
        dex->method_ids[i].proto_idx = read_u16(data + off + 2);
        dex->method_ids[i].name_idx = read_u32(data + off + 4);
    }

    // Parse class definitions
    dex->class_count = dex->header.class_defs_size;
    if (dex->class_count > 100000) {  // 100K classes max per DEX
        DX_ERROR(TAG, "Class count %u exceeds sanity limit (max 100000)", dex->class_count);
        goto fail;
    }
    dex->class_defs = (DxDexClassDef *)dx_malloc(sizeof(DxDexClassDef) * dex->class_count);
    if (!dex->class_defs) goto fail;
    for (uint32_t i = 0; i < dex->class_count; i++) {
        uint32_t off = dex->header.class_defs_off + i * 32;
        if (off + 32 > size) break;
        dex->class_defs[i].class_idx = read_u32(data + off);
        dex->class_defs[i].access_flags = read_u32(data + off + 4);
        dex->class_defs[i].superclass_idx = read_u32(data + off + 8);
        dex->class_defs[i].interfaces_off = read_u32(data + off + 12);
        dex->class_defs[i].source_file_idx = read_u32(data + off + 16);
        dex->class_defs[i].annotations_off = read_u32(data + off + 20);
        dex->class_defs[i].class_data_off = read_u32(data + off + 24);
        dex->class_defs[i].static_values_off = read_u32(data + off + 28);
    }

    // Allocate class_data array (lazy parsing)
    dex->class_data = (DxDexClassData **)dx_malloc(sizeof(DxDexClassData *) * dex->class_count);

    // Initialize method handle / call site tables (parsed from map list)
    dex->method_handles = NULL;
    dex->method_handle_count = 0;
    dex->call_sites = NULL;
    dex->call_site_count = 0;

    // Parse method handles and call sites from the map list
    dx_dex_parse_call_sites(dex);

    DX_INFO(TAG, "DEX parsed successfully");
    *out = dex;
    return DX_OK;

fail:
    dx_dex_free(dex);
    return DX_ERR_OUT_OF_MEMORY;
}

void dx_dex_free(DxDexFile *dex) {
    if (!dex) return;

    // strings[] and string_data_offsets are arena-allocated; destroy arena
    dx_arena_destroy(dex->arena);
    dex->arena = NULL;
    dex->strings = NULL;
    dex->string_data_offsets = NULL;

    dx_free(dex->type_ids);
    dx_free(dex->proto_ids);
    dx_free(dex->field_ids);
    dx_free(dex->method_ids);
    dx_free(dex->class_defs);

    if (dex->class_data) {
        for (uint32_t i = 0; i < dex->class_count; i++) {
            if (dex->class_data[i]) {
                dx_free(dex->class_data[i]->static_fields);
                dx_free(dex->class_data[i]->instance_fields);
                dx_free(dex->class_data[i]->direct_methods);
                dx_free(dex->class_data[i]->virtual_methods);
                dx_free(dex->class_data[i]);
            }
        }
        dx_free(dex->class_data);
    }

    dx_free(dex->map_items);
    dx_free(dex->method_handles);
    dx_free(dex->call_sites);

    dx_free(dex);
}

const char *dx_dex_get_string(const DxDexFile *dex, uint32_t idx) {
    if (!dex || idx >= dex->string_count) return NULL;

    // Lazy decode: if not yet decoded, decode from raw data now
    if (!dex->strings[idx]) {
        // Cast away const for lazy caching (strings[] is a mutable cache)
        DxDexFile *mutable_dex = (DxDexFile *)dex;
        uint32_t off = dex->string_data_offsets ? dex->string_data_offsets[idx] : UINT32_MAX;
        if (off == UINT32_MAX || off >= dex->raw_size) {
            mutable_dex->strings[idx] = dx_arena_strdup(mutable_dex->arena, "");
        } else {
            mutable_dex->strings[idx] = decode_mutf8_ex(dex->raw_data, off, dex->raw_size,
                                                         mutable_dex->arena);
        }
    }
    return dex->strings[idx];
}

const char *dx_dex_get_type(const DxDexFile *dex, uint32_t type_idx) {
    if (!dex || type_idx >= dex->type_count) return NULL;
    return dx_dex_get_string(dex, dex->type_ids[type_idx].descriptor_idx);
}

DxResult dx_dex_parse_class_data(DxDexFile *dex, uint32_t class_def_idx) {
    if (!dex || class_def_idx >= dex->class_count) return DX_ERR_NULL_PTR;
    if (dex->class_data[class_def_idx]) return DX_OK; // already parsed

    uint32_t off = dex->class_defs[class_def_idx].class_data_off;
    if (off == 0) {
        // No class data (interface or annotation-only)
        DxDexClassData *cd = (DxDexClassData *)dx_malloc(sizeof(DxDexClassData));
        if (!cd) return DX_ERR_OUT_OF_MEMORY;
        dex->class_data[class_def_idx] = cd;
        return DX_OK;
    }

    if (off >= dex->raw_size) return DX_ERR_INVALID_FORMAT;

    const uint8_t *p = dex->raw_data + off;
    uint32_t static_fields_count = read_uleb128(&p);
    uint32_t instance_fields_count = read_uleb128(&p);
    uint32_t direct_methods_count = read_uleb128(&p);
    uint32_t virtual_methods_count = read_uleb128(&p);

    DxDexClassData *cd = (DxDexClassData *)dx_malloc(sizeof(DxDexClassData));
    if (!cd) return DX_ERR_OUT_OF_MEMORY;

    cd->static_fields_count = static_fields_count;
    cd->instance_fields_count = instance_fields_count;
    cd->direct_methods_count = direct_methods_count;
    cd->virtual_methods_count = virtual_methods_count;

    // Parse static fields
    if (static_fields_count > 0) {
        if (static_fields_count > 100000) {  // 100K fields per class max
            dx_free(cd); return DX_ERR_INVALID_FORMAT;
        }
        cd->static_fields = (DxDexEncodedField *)dx_malloc(sizeof(DxDexEncodedField) * static_fields_count);
        if (!cd->static_fields) { dx_free(cd); return DX_ERR_OUT_OF_MEMORY; }
        uint32_t field_idx = 0;
        for (uint32_t i = 0; i < static_fields_count; i++) {
            field_idx += read_uleb128(&p);
            cd->static_fields[i].field_idx = field_idx;
            cd->static_fields[i].access_flags = read_uleb128(&p);
        }
    }

    // Parse instance fields
    if (instance_fields_count > 0) {
        if (instance_fields_count > 100000) {  // 100K fields per class max
            dx_free(cd->static_fields); dx_free(cd); return DX_ERR_INVALID_FORMAT;
        }
        cd->instance_fields = (DxDexEncodedField *)dx_malloc(sizeof(DxDexEncodedField) * instance_fields_count);
        if (!cd->instance_fields) { dx_free(cd->static_fields); dx_free(cd); return DX_ERR_OUT_OF_MEMORY; }
        uint32_t field_idx = 0;
        for (uint32_t i = 0; i < instance_fields_count; i++) {
            field_idx += read_uleb128(&p);
            cd->instance_fields[i].field_idx = field_idx;
            cd->instance_fields[i].access_flags = read_uleb128(&p);
        }
    }

    // Parse direct methods
    if (direct_methods_count > 0) {
        if (direct_methods_count > 50000) goto fail_methods;  // 50K direct methods per class max
        cd->direct_methods = (DxDexEncodedMethod *)dx_malloc(sizeof(DxDexEncodedMethod) * direct_methods_count);
        if (!cd->direct_methods) goto fail_methods;
        uint32_t method_idx = 0;
        for (uint32_t i = 0; i < direct_methods_count; i++) {
            method_idx += read_uleb128(&p);
            cd->direct_methods[i].method_idx = method_idx;
            cd->direct_methods[i].access_flags = read_uleb128(&p);
            cd->direct_methods[i].code_off = read_uleb128(&p);
        }
    }

    // Parse virtual methods
    if (virtual_methods_count > 0) {
        if (virtual_methods_count > 50000) goto fail_methods;  // 50K virtual methods per class max
        cd->virtual_methods = (DxDexEncodedMethod *)dx_malloc(sizeof(DxDexEncodedMethod) * virtual_methods_count);
        if (!cd->virtual_methods) goto fail_methods;
        uint32_t method_idx = 0;
        for (uint32_t i = 0; i < virtual_methods_count; i++) {
            method_idx += read_uleb128(&p);
            cd->virtual_methods[i].method_idx = method_idx;
            cd->virtual_methods[i].access_flags = read_uleb128(&p);
            cd->virtual_methods[i].code_off = read_uleb128(&p);
        }
    }

    dex->class_data[class_def_idx] = cd;

    DX_DEBUG(TAG, "Class data[%u]: %u sfields, %u ifields, %u dmethods, %u vmethods",
             class_def_idx, static_fields_count, instance_fields_count,
             direct_methods_count, virtual_methods_count);

    return DX_OK;

fail_methods:
    dx_free(cd->static_fields);
    dx_free(cd->instance_fields);
    dx_free(cd->direct_methods);
    dx_free(cd);
    return DX_ERR_OUT_OF_MEMORY;
}

DxResult dx_dex_parse_code_item(const DxDexFile *dex, uint32_t offset, DxDexCodeItem *out) {
    if (!dex || !out || offset == 0) return DX_ERR_NULL_PTR;
    if (offset + 16 > dex->raw_size) return DX_ERR_INVALID_FORMAT;

    const uint8_t *p = dex->raw_data + offset;
    out->registers_size = read_u16(p);
    out->ins_size = read_u16(p + 2);
    out->outs_size = read_u16(p + 4);
    out->tries_size = read_u16(p + 6);
    out->debug_info_off = read_u32(p + 8);
    out->insns_size = read_u32(p + 12);
    out->insns = (uint16_t *)(p + 16);

    // Validate insns_size doesn't exceed remaining file space
    uint32_t remaining = dex->raw_size - (offset + 16);
    if (out->insns_size > remaining / 2) {
        DX_WARN(TAG, "Code item insns_size (%u) exceeds remaining file (%u bytes at offset 0x%x)",
                out->insns_size, remaining, offset);
        return DX_ERR_INVALID_FORMAT;
    }

    // Validate insns_size doesn't extend past DEX file boundary (absolute check)
    {
        uint64_t insns_abs_end = (uint64_t)offset + 16 + (uint64_t)out->insns_size * 2;
        if (insns_abs_end > dex->raw_size) {
            DX_WARN(TAG, "Code item insns_size (%u) at offset 0x%x extends past DEX file boundary "
                    "(insns end=0x%llx, file size=0x%x)",
                    out->insns_size, offset, (unsigned long long)insns_abs_end, dex->raw_size);
            return DX_ERR_INVALID_FORMAT;
        }
    }

    // Validate tries_size is within file bounds
    // tries array follows insns (with possible padding), each try_item is 8 bytes
    if (out->tries_size > 0) {
        uint32_t insns_end = offset + 16 + (uint32_t)out->insns_size * 2;
        // Align to 4 bytes if tries_size > 0 and insns_size is odd
        if (out->insns_size & 1) insns_end += 2;
        uint64_t tries_end = (uint64_t)insns_end + (uint64_t)out->tries_size * 8;
        if (tries_end > dex->raw_size) {
            DX_WARN(TAG, "Code item tries_size (%u) exceeds file bounds at offset 0x%x",
                    out->tries_size, offset);
            return DX_ERR_INVALID_FORMAT;
        }

        // Validate each try_item: start_addr and insn_count must fall within insns_size
        const uint8_t *try_base = dex->raw_data + insns_end;
        uint32_t valid_tries = 0;
        for (uint16_t t = 0; t < out->tries_size; t++) {
            const uint8_t *entry = try_base + t * 8;
            uint32_t start_addr = (uint32_t)entry[0] | ((uint32_t)entry[1] << 8) | ((uint32_t)entry[2] << 16) | ((uint32_t)entry[3] << 24);
            uint16_t insn_count = (uint16_t)(entry[4] | (entry[5] << 8));
            if (start_addr < out->insns_size &&
                (uint64_t)start_addr + insn_count <= out->insns_size) {
                valid_tries++;
            } else {
                DX_WARN(TAG, "Code item try_item[%u] at offset 0x%x: start_addr=%u insn_count=%u "
                        "exceeds insns_size=%u",
                        t, offset, start_addr, insn_count, out->insns_size);
            }
        }
        if (valid_tries != out->tries_size) {
            DX_WARN(TAG, "Code item at offset 0x%x: tries_size=%u but only %u try_items are valid",
                    offset, out->tries_size, valid_tries);
        }
    }

    // Initialize line table to empty
    out->line_table = NULL;
    out->line_count = 0;

    return DX_OK;
}

// Read signed LEB128
static int32_t read_sleb128(const uint8_t **pp) {
    const uint8_t *p = *pp;
    int32_t result = 0;
    int shift = 0;
    uint8_t byte;
    do {
        byte = *p++;
        result |= (int32_t)(byte & 0x7F) << shift;
        shift += 7;
    } while (byte & 0x80);
    // Sign extend
    if (shift < 32 && (byte & 0x40)) {
        result |= -(1 << shift);
    }
    *pp = p;
    return result;
}

DxResult dx_dex_parse_debug_info(const DxDexFile *dex, DxDexCodeItem *code) {
    if (!dex || !code) return DX_ERR_NULL_PTR;
    if (code->debug_info_off == 0 || code->debug_info_off >= dex->raw_size) return DX_OK;

    const uint8_t *p = dex->raw_data + code->debug_info_off;
    const uint8_t *end = dex->raw_data + dex->raw_size;

    // Read line_start and parameters_size
    uint32_t line_start = read_uleb128(&p);
    if (p >= end) return DX_OK;
    uint32_t parameters_size = read_uleb128(&p);
    if (p >= end) return DX_OK;

    // Skip parameter names (each is ULEB128p1: value+1, where 0 means no name)
    for (uint32_t i = 0; i < parameters_size && p < end; i++) {
        read_uleb128(&p); // name_idx + 1
    }

    // Allocate line table (we'll grow up to DX_MAX_LINE_ENTRIES)
    DxLineEntry *entries = (DxLineEntry *)dx_malloc(sizeof(DxLineEntry) * DX_MAX_LINE_ENTRIES);
    if (!entries) return DX_ERR_OUT_OF_MEMORY;

    uint32_t count = 0;
    uint32_t address = 0;
    int32_t line = (int32_t)line_start;

    // Emit the initial position
    if (count < DX_MAX_LINE_ENTRIES) {
        entries[count].address = address;
        entries[count].line = line;
        count++;
    }

    // Process state machine bytecodes
    while (p < end) {
        uint8_t opcode = *p++;

        switch (opcode) {
            case 0x00: // DBG_END_SEQUENCE
                goto done;

            case 0x01: { // DBG_ADVANCE_PC
                if (p >= end) goto done;
                uint32_t addr_diff = read_uleb128(&p);
                address += addr_diff;
                break;
            }

            case 0x02: { // DBG_ADVANCE_LINE
                if (p >= end) goto done;
                int32_t line_diff = read_sleb128(&p);
                line += line_diff;
                break;
            }

            case 0x03: { // DBG_START_LOCAL
                if (p >= end) goto done;
                read_uleb128(&p); // register_num
                if (p >= end) goto done;
                read_uleb128(&p); // name_idx + 1
                if (p >= end) goto done;
                read_uleb128(&p); // type_idx + 1
                break;
            }

            case 0x04: { // DBG_START_LOCAL_EXTENDED
                if (p >= end) goto done;
                read_uleb128(&p); // register_num
                if (p >= end) goto done;
                read_uleb128(&p); // name_idx + 1
                if (p >= end) goto done;
                read_uleb128(&p); // type_idx + 1
                if (p >= end) goto done;
                read_uleb128(&p); // sig_idx + 1
                break;
            }

            case 0x05: // DBG_END_LOCAL
            case 0x06: // DBG_RESTART_LOCAL
                if (p >= end) goto done;
                read_uleb128(&p); // register_num
                break;

            case 0x07: // DBG_SET_PROLOGUE_END
            case 0x08: // DBG_SET_EPILOGUE_BEGIN
                // No arguments
                break;

            case 0x09: // DBG_SET_FILE
                if (p >= end) goto done;
                read_uleb128(&p); // name_idx + 1
                break;

            default: {
                // Special opcode (0x0A - 0xFF)
                int adjusted = opcode - 0x0A;
                line += -4 + (adjusted % 15);
                address += (uint32_t)(adjusted / 15);

                // Emit a line entry
                if (count < DX_MAX_LINE_ENTRIES) {
                    entries[count].address = address;
                    entries[count].line = line;
                    count++;
                }
                break;
            }
        }
    }

done:
    if (count == 0) {
        dx_free(entries);
        return DX_OK;
    }

    // Shrink allocation to actual size
    if (count < DX_MAX_LINE_ENTRIES) {
        DxLineEntry *shrunk = (DxLineEntry *)dx_malloc(sizeof(DxLineEntry) * count);
        if (shrunk) {
            memcpy(shrunk, entries, sizeof(DxLineEntry) * count);
            dx_free(entries);
            entries = shrunk;
        }
        // If realloc fails, just keep the oversized buffer
    }

    code->line_table = entries;
    code->line_count = count;

    DX_DEBUG(TAG, "Parsed %u line entries (lines %d-%d) from debug_info at 0x%x",
             count, entries[0].line, entries[count - 1].line, code->debug_info_off);

    return DX_OK;
}

int dx_method_get_line(const DxMethod *method, uint32_t pc) {
    if (!method || !method->has_code) return -1;
    const DxDexCodeItem *code = &method->code;
    if (!code->line_table || code->line_count == 0) return -1;

    // Binary search: find the last entry with address <= pc
    int32_t lo = 0;
    int32_t hi = (int32_t)code->line_count - 1;
    int32_t best = -1;

    while (lo <= hi) {
        int32_t mid = lo + (hi - lo) / 2;
        if (code->line_table[mid].address <= pc) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }

    return best >= 0 ? code->line_table[best].line : -1;
}

void dx_dex_free_code_item(DxDexCodeItem *code) {
    if (!code) return;
    if (code->line_table) {
        dx_free(code->line_table);
        code->line_table = NULL;
        code->line_count = 0;
    }
}

const char *dx_dex_get_method_name(const DxDexFile *dex, uint32_t method_idx) {
    if (!dex || method_idx >= dex->method_count) return NULL;
    return dx_dex_get_string(dex, dex->method_ids[method_idx].name_idx);
}

const char *dx_dex_get_method_class(const DxDexFile *dex, uint32_t method_idx) {
    if (!dex || method_idx >= dex->method_count) return NULL;
    return dx_dex_get_type(dex, dex->method_ids[method_idx].class_idx);
}

const char *dx_dex_get_method_shorty(const DxDexFile *dex, uint32_t method_idx) {
    if (!dex || method_idx >= dex->method_count) return NULL;
    uint16_t proto_idx = dex->method_ids[method_idx].proto_idx;
    if (proto_idx >= dex->proto_count) return NULL;
    return dx_dex_get_string(dex, dex->proto_ids[proto_idx].shorty_idx);
}

const char *dx_dex_get_field_name(const DxDexFile *dex, uint32_t field_idx) {
    if (!dex || field_idx >= dex->field_count) return NULL;
    return dx_dex_get_string(dex, dex->field_ids[field_idx].name_idx);
}

const char *dx_dex_get_field_class(const DxDexFile *dex, uint32_t field_idx) {
    if (!dex || field_idx >= dex->field_count) return NULL;
    return dx_dex_get_type(dex, dex->field_ids[field_idx].class_idx);
}

uint32_t dx_dex_get_method_param_count(const DxDexFile *dex, uint32_t method_idx) {
    if (!dex || method_idx >= dex->method_count) return 0;
    uint16_t proto_idx = dex->method_ids[method_idx].proto_idx;
    if (proto_idx >= dex->proto_count) return 0;
    uint32_t params_off = dex->proto_ids[proto_idx].parameters_off;
    if (params_off == 0) return 0;
    if (params_off + 4 > dex->raw_size) return 0;
    return read_u32(dex->raw_data + params_off);
}

const char *dx_dex_get_method_param_type(const DxDexFile *dex, uint32_t method_idx, uint32_t param_idx) {
    if (!dex || method_idx >= dex->method_count) return NULL;
    uint16_t proto_idx = dex->method_ids[method_idx].proto_idx;
    if (proto_idx >= dex->proto_count) return NULL;
    uint32_t params_off = dex->proto_ids[proto_idx].parameters_off;
    if (params_off == 0) return NULL;
    if (params_off + 4 > dex->raw_size) return NULL;
    uint32_t count = read_u32(dex->raw_data + params_off);
    if (param_idx >= count) return NULL;
    if (params_off + 4 + (param_idx + 1) * 2 > dex->raw_size) return NULL;
    uint16_t type_idx = read_u16(dex->raw_data + params_off + 4 + param_idx * 2);
    return dx_dex_get_type(dex, type_idx);
}

const char *dx_dex_get_method_return_type(const DxDexFile *dex, uint32_t method_idx) {
    if (!dex || method_idx >= dex->method_count) return NULL;
    uint16_t proto_idx = dex->method_ids[method_idx].proto_idx;
    if (proto_idx >= dex->proto_count) return NULL;
    return dx_dex_get_type(dex, dex->proto_ids[proto_idx].return_type_idx);
}

// Read a sign-extended integer of (size) bytes from ptr
static int64_t read_signed(const uint8_t *ptr, uint32_t size) {
    int64_t result = 0;
    for (uint32_t i = 0; i < size; i++) {
        result |= (int64_t)ptr[i] << (i * 8);
    }
    // Sign-extend from the top bit of the last byte
    if (ptr[size - 1] & 0x80) {
        for (uint32_t i = size; i < 8; i++) {
            result |= (int64_t)0xFF << (i * 8);
        }
    }
    return result;
}

// Read a zero-extended integer of (size) bytes from ptr
static uint64_t read_unsigned(const uint8_t *ptr, uint32_t size) {
    uint64_t result = 0;
    for (uint32_t i = 0; i < size; i++) {
        result |= (uint64_t)ptr[i] << (i * 8);
    }
    return result;
}

// ── Annotation parsing ──

// Skip an encoded_value (recursive for arrays/annotations)
static void skip_encoded_value(const uint8_t **pp, const uint8_t *end) {
    if (*pp >= end) return;
    uint8_t type_and_arg = *(*pp)++;
    uint8_t value_type = type_and_arg & 0x1F;
    uint8_t value_arg = (type_and_arg >> 5) & 0x07;

    switch (value_type) {
        case 0x00: // BYTE
            *pp += 1;
            break;
        case 0x02: // SHORT
        case 0x03: // CHAR
        case 0x04: // INT
        case 0x06: // LONG
        case 0x10: // FLOAT
        case 0x11: // DOUBLE
        case 0x17: // STRING
        case 0x18: // TYPE
        case 0x19: // FIELD
        case 0x1a: // METHOD_TYPE (DEX 039+)
        case 0x1b: // METHOD
        case 0x1c: // ENUM
            *pp += (value_arg + 1);
            break;
        case 0x1d: { // ARRAY
            uint32_t arr_size = read_uleb128(pp);
            for (uint32_t a = 0; a < arr_size && *pp < end; a++) {
                skip_encoded_value(pp, end);
            }
            break;
        }
        case 0x1e: // NULL - no data
        case 0x1f: // BOOLEAN - no data (value in arg)
            break;
        case 0x20: { // ANNOTATION (sub-annotation)
            read_uleb128(pp); // type_idx
            uint32_t sub_size = read_uleb128(pp);
            for (uint32_t s = 0; s < sub_size && *pp < end; s++) {
                read_uleb128(pp); // name_idx
                skip_encoded_value(pp, end);
            }
            break;
        }
        default:
            // Unknown type, can't skip reliably
            break;
    }
}

// Decode a single encoded_value into an DxAnnotationElement (value part only).
// Returns true on success, false if the value type is unsupported (element left as NONE).
static bool decode_annotation_value(const DxDexFile *dex, const uint8_t **pp, const uint8_t *end,
                                     DxAnnotationElement *elem) {
    if (*pp >= end) return false;
    uint8_t type_and_arg = *(*pp)++;
    uint8_t value_type = type_and_arg & 0x1F;
    uint8_t value_arg = (type_and_arg >> 5) & 0x07;
    uint32_t byte_count = value_arg + 1;

    switch (value_type) {
        case 0x00: { // VALUE_BYTE
            if (*pp >= end) return false;
            elem->val_type = DX_ANNO_VAL_BYTE;
            elem->i_value = (int8_t)*(*pp)++;
            return true;
        }
        case 0x02: { // VALUE_SHORT
            if (*pp + byte_count > end) return false;
            elem->val_type = DX_ANNO_VAL_SHORT;
            elem->i_value = (int32_t)read_signed(*pp, byte_count);
            *pp += byte_count;
            return true;
        }
        case 0x03: { // VALUE_CHAR
            if (*pp + byte_count > end) return false;
            elem->val_type = DX_ANNO_VAL_CHAR;
            elem->i_value = (int32_t)read_unsigned(*pp, byte_count);
            *pp += byte_count;
            return true;
        }
        case 0x04: { // VALUE_INT
            if (*pp + byte_count > end) return false;
            elem->val_type = DX_ANNO_VAL_INT;
            elem->i_value = (int32_t)read_signed(*pp, byte_count);
            *pp += byte_count;
            return true;
        }
        case 0x06: { // VALUE_LONG
            if (*pp + byte_count > end) return false;
            elem->val_type = DX_ANNO_VAL_LONG;
            elem->l_value = read_signed(*pp, byte_count);
            *pp += byte_count;
            return true;
        }
        case 0x10: { // VALUE_FLOAT
            if (*pp + byte_count > end) return false;
            uint32_t raw = 0;
            for (uint32_t b = 0; b < byte_count; b++) {
                raw |= (uint32_t)(*pp)[b] << ((4 - byte_count + b) * 8);
            }
            elem->val_type = DX_ANNO_VAL_FLOAT;
            memcpy(&elem->f_value, &raw, sizeof(float));
            *pp += byte_count;
            return true;
        }
        case 0x11: { // VALUE_DOUBLE
            if (*pp + byte_count > end) return false;
            uint64_t raw = 0;
            for (uint32_t b = 0; b < byte_count; b++) {
                raw |= (uint64_t)(*pp)[b] << ((8 - byte_count + b) * 8);
            }
            elem->val_type = DX_ANNO_VAL_DOUBLE;
            memcpy(&elem->d_value, &raw, sizeof(double));
            *pp += byte_count;
            return true;
        }
        case 0x17: { // VALUE_STRING
            if (*pp + byte_count > end) return false;
            uint32_t str_idx = (uint32_t)read_unsigned(*pp, byte_count);
            elem->val_type = DX_ANNO_VAL_STRING;
            elem->str_value = dx_dex_get_string(dex, str_idx);
            *pp += byte_count;
            return true;
        }
        case 0x18: { // VALUE_TYPE
            if (*pp + byte_count > end) return false;
            uint32_t type_idx = (uint32_t)read_unsigned(*pp, byte_count);
            elem->val_type = DX_ANNO_VAL_TYPE;
            elem->str_value = dx_dex_get_type(dex, type_idx);
            *pp += byte_count;
            return true;
        }
        case 0x1b: { // VALUE_ENUM (field_idx)
            if (*pp + byte_count > end) return false;
            uint32_t field_idx = (uint32_t)read_unsigned(*pp, byte_count);
            elem->val_type = DX_ANNO_VAL_ENUM;
            elem->str_value = dx_dex_get_field_name(dex, field_idx);
            elem->extra_str = dx_dex_get_field_class(dex, field_idx);
            *pp += byte_count;
            return true;
        }
        case 0x1c: { // VALUE_ARRAY
            uint32_t arr_size = read_uleb128(pp);
            for (uint32_t a = 0; a < arr_size && *pp < end; a++) {
                skip_encoded_value(pp, end);
            }
            elem->val_type = DX_ANNO_VAL_ARRAY;
            elem->i_value = (int32_t)arr_size;
            return true;
        }
        case 0x1d: { // VALUE_ANNOTATION (sub-annotation)
            read_uleb128(pp); // type_idx
            uint32_t sub_size = read_uleb128(pp);
            for (uint32_t s = 0; s < sub_size && *pp < end; s++) {
                read_uleb128(pp); // name_idx
                skip_encoded_value(pp, end);
            }
            elem->val_type = DX_ANNO_VAL_ANNOTATION;
            return true;
        }
        case 0x1e: // VALUE_NULL
            elem->val_type = DX_ANNO_VAL_NULL;
            return true;
        case 0x1f: // VALUE_BOOLEAN (value is in value_arg)
            elem->val_type = DX_ANNO_VAL_BOOLEAN;
            elem->i_value = value_arg ? 1 : 0;
            return true;
        default:
            // Unknown/unsupported — try to skip with value_arg+1 heuristic
            if (*pp + byte_count <= end) *pp += byte_count;
            elem->val_type = DX_ANNO_VAL_NONE;
            return false;
    }
}

// Parse an annotation_set_item at the given offset, returning entries with element values
static DxResult parse_annotation_set(const DxDexFile *dex, uint32_t set_off,
                                      DxAnnotationEntry **out_entries, uint32_t *out_count) {
    *out_entries = NULL;
    *out_count = 0;

    if (set_off == 0 || set_off + 4 > dex->raw_size) return DX_OK;

    const uint8_t *base = dex->raw_data;
    uint32_t size = read_u32(base + set_off);
    if (size == 0) return DX_OK;
    if (set_off + 4 + (uint64_t)size * 4 > dex->raw_size) return DX_ERR_INVALID_FORMAT;

    DxAnnotationEntry *entries = (DxAnnotationEntry *)dx_malloc(sizeof(DxAnnotationEntry) * size);
    if (!entries) return DX_ERR_OUT_OF_MEMORY;
    memset(entries, 0, sizeof(DxAnnotationEntry) * size);

    uint32_t count = 0;
    for (uint32_t i = 0; i < size; i++) {
        uint32_t ann_off = read_u32(base + set_off + 4 + i * 4);
        if (ann_off == 0 || ann_off >= dex->raw_size) continue;

        const uint8_t *p = base + ann_off;
        const uint8_t *end = base + dex->raw_size;
        if (p >= end) continue;

        uint8_t visibility = *p++;
        // encoded_annotation: type_idx (uleb128), size (uleb128), then elements
        uint32_t type_idx = read_uleb128(&p);
        uint32_t elem_size = read_uleb128(&p);

        const char *type_desc = dx_dex_get_type(dex, type_idx);
        if (!type_desc) {
            // Skip elements and move on
            for (uint32_t e = 0; e < elem_size && p < end; e++) {
                read_uleb128(&p);
                skip_encoded_value(&p, end);
            }
            continue;
        }

        entries[count].type = type_desc;
        entries[count].visibility = visibility;
        entries[count].elements = NULL;
        entries[count].element_count = 0;

        if (elem_size > 0) {
            DxAnnotationElement *elems = (DxAnnotationElement *)dx_malloc(
                sizeof(DxAnnotationElement) * elem_size);
            if (elems) {
                memset(elems, 0, sizeof(DxAnnotationElement) * elem_size);
                uint32_t valid_elems = 0;
                for (uint32_t e = 0; e < elem_size && p < end; e++) {
                    uint32_t name_idx = read_uleb128(&p);
                    const char *elem_name = dx_dex_get_string(dex, name_idx);
                    elems[valid_elems].name = elem_name;
                    decode_annotation_value(dex, &p, end, &elems[valid_elems]);
                    valid_elems++;
                }
                entries[count].elements = elems;
                entries[count].element_count = valid_elems;
            } else {
                // OOM — skip elements
                for (uint32_t e = 0; e < elem_size && p < end; e++) {
                    read_uleb128(&p);
                    skip_encoded_value(&p, end);
                }
            }
        }
        count++;
    }

    if (count == 0) {
        dx_free(entries);
        return DX_OK;
    }

    *out_entries = entries;
    *out_count = count;
    return DX_OK;
}

DxResult dx_dex_parse_annotations(const DxDexFile *dex, uint32_t annotations_off,
                                   DxAnnotationsDirectory *out) {
    if (!dex || !out) return DX_ERR_NULL_PTR;
    memset(out, 0, sizeof(*out));

    if (annotations_off == 0 || annotations_off + 16 > dex->raw_size)
        return DX_OK; // no annotations

    const uint8_t *base = dex->raw_data;
    const uint8_t *p = base + annotations_off;

    uint32_t class_annotations_off = read_u32(p);
    uint32_t fields_size = read_u32(p + 4);
    uint32_t annotated_methods_size = read_u32(p + 8);
    // uint32_t annotated_parameters_size = read_u32(p + 12); // not used yet

    // Validate the directory doesn't exceed file bounds
    uint32_t dir_data_size = 16 + fields_size * 8 + annotated_methods_size * 8;
    if (annotations_off + (uint64_t)dir_data_size > dex->raw_size) {
        DX_WARN(TAG, "annotations_directory_item at 0x%x exceeds file bounds", annotations_off);
        return DX_ERR_INVALID_FORMAT;
    }

    // Parse class-level annotations
    if (class_annotations_off != 0) {
        DxResult res = parse_annotation_set(dex, class_annotations_off,
                                             &out->class_annotations, &out->class_annotation_count);
        if (res != DX_OK) return res;
        DX_DEBUG(TAG, "Parsed %u class annotations", out->class_annotation_count);
    }

    // Skip field_annotations (fields_size entries of 8 bytes each)
    const uint8_t *method_ann_start = p + 16 + fields_size * 8;

    // Parse method annotations
    if (annotated_methods_size > 0) {
        out->method_idxs = (uint32_t *)dx_malloc(sizeof(uint32_t) * annotated_methods_size);
        out->method_annotations = (DxAnnotationEntry **)dx_malloc(sizeof(DxAnnotationEntry *) * annotated_methods_size);
        out->method_annotation_counts = (uint32_t *)dx_malloc(sizeof(uint32_t) * annotated_methods_size);
        if (!out->method_idxs || !out->method_annotations || !out->method_annotation_counts) {
            dx_dex_free_annotations(out);
            return DX_ERR_OUT_OF_MEMORY;
        }
        memset(out->method_annotations, 0, sizeof(DxAnnotationEntry *) * annotated_methods_size);
        memset(out->method_annotation_counts, 0, sizeof(uint32_t) * annotated_methods_size);

        uint32_t valid_count = 0;
        for (uint32_t i = 0; i < annotated_methods_size; i++) {
            const uint8_t *entry = method_ann_start + i * 8;
            uint32_t method_idx = read_u32(entry);
            uint32_t ann_set_off = read_u32(entry + 4);

            DxAnnotationEntry *entries = NULL;
            uint32_t entry_count = 0;
            DxResult res = parse_annotation_set(dex, ann_set_off, &entries, &entry_count);
            if (res != DX_OK) continue;
            if (entry_count == 0) continue;

            out->method_idxs[valid_count] = method_idx;
            out->method_annotations[valid_count] = entries;
            out->method_annotation_counts[valid_count] = entry_count;
            valid_count++;
        }
        out->annotated_method_count = valid_count;
        DX_DEBUG(TAG, "Parsed annotations for %u methods", valid_count);
    }

    return DX_OK;
}

void dx_annotation_entry_free_elements(DxAnnotationEntry *entry) {
    if (!entry) return;
    dx_free(entry->elements);
    entry->elements = NULL;
    entry->element_count = 0;
}

void dx_dex_free_annotations(DxAnnotationsDirectory *dir) {
    if (!dir) return;
    if (dir->class_annotations) {
        for (uint32_t i = 0; i < dir->class_annotation_count; i++) {
            dx_annotation_entry_free_elements(&dir->class_annotations[i]);
        }
        dx_free(dir->class_annotations);
    }
    if (dir->method_annotations) {
        for (uint32_t i = 0; i < dir->annotated_method_count; i++) {
            if (dir->method_annotations[i]) {
                for (uint32_t j = 0; j < dir->method_annotation_counts[i]; j++) {
                    dx_annotation_entry_free_elements(&dir->method_annotations[i][j]);
                }
                dx_free(dir->method_annotations[i]);
            }
        }
        dx_free(dir->method_annotations);
    }
    dx_free(dir->method_idxs);
    dx_free(dir->method_annotation_counts);
    memset(dir, 0, sizeof(*dir));
}

DxResult dx_dex_parse_static_values(const DxDexFile *dex, uint32_t offset,
                                     DxValue *out_values, uint32_t max_count) {
    if (!dex || !out_values) return DX_ERR_NULL_PTR;
    if (offset == 0 || offset >= dex->raw_size) return DX_ERR_INVALID_FORMAT;

    const uint8_t *p = dex->raw_data + offset;
    const uint8_t *end = dex->raw_data + dex->raw_size;

    uint32_t size = read_uleb128(&p);
    if (size > max_count) size = max_count;

    DX_DEBUG(TAG, "Parsing %u static values at offset 0x%x", size, offset);

    for (uint32_t i = 0; i < size; i++) {
        if (p >= end) break;

        uint8_t type_and_arg = *p++;
        uint8_t value_type = type_and_arg & 0x1F;
        uint8_t value_arg = (type_and_arg >> 5) & 0x07;
        uint32_t byte_count = value_arg + 1;  // number of bytes for most types

        switch (value_type) {
            case 0x00: { // VALUE_BYTE
                if (p >= end) break;
                out_values[i].tag = DX_VAL_INT;
                out_values[i].i = (int8_t)*p++;
                break;
            }
            case 0x02: { // VALUE_SHORT (sign-extended)
                if (p + byte_count > end) break;
                out_values[i].tag = DX_VAL_INT;
                out_values[i].i = (int32_t)read_signed(p, byte_count);
                p += byte_count;
                break;
            }
            case 0x03: { // VALUE_CHAR (zero-extended)
                if (p + byte_count > end) break;
                out_values[i].tag = DX_VAL_INT;
                out_values[i].i = (int32_t)read_unsigned(p, byte_count);
                p += byte_count;
                break;
            }
            case 0x04: { // VALUE_INT (sign-extended)
                if (p + byte_count > end) break;
                out_values[i].tag = DX_VAL_INT;
                out_values[i].i = (int32_t)read_signed(p, byte_count);
                p += byte_count;
                break;
            }
            case 0x06: { // VALUE_LONG (sign-extended)
                if (p + byte_count > end) break;
                out_values[i].tag = DX_VAL_LONG;
                out_values[i].l = read_signed(p, byte_count);
                p += byte_count;
                break;
            }
            case 0x10: { // VALUE_FLOAT (zero-extended right)
                if (p + byte_count > end) break;
                uint32_t raw = 0;
                for (uint32_t b = 0; b < byte_count; b++) {
                    raw |= (uint32_t)p[b] << ((4 - byte_count + b) * 8);
                }
                out_values[i].tag = DX_VAL_FLOAT;
                memcpy(&out_values[i].f, &raw, sizeof(float));
                p += byte_count;
                break;
            }
            case 0x11: { // VALUE_DOUBLE (zero-extended right)
                if (p + byte_count > end) break;
                uint64_t raw = 0;
                for (uint32_t b = 0; b < byte_count; b++) {
                    raw |= (uint64_t)p[b] << ((8 - byte_count + b) * 8);
                }
                out_values[i].tag = DX_VAL_DOUBLE;
                memcpy(&out_values[i].d, &raw, sizeof(double));
                p += byte_count;
                break;
            }
            case 0x17: { // VALUE_STRING (string_idx)
                if (p + byte_count > end) break;
                uint32_t str_idx = (uint32_t)read_unsigned(p, byte_count);
                out_values[i].tag = DX_VAL_INT;  // store string index as int for now
                out_values[i].i = (int32_t)str_idx;
                // Mark as a string index by using a negative tag convention:
                // The caller should interpret this based on field type context.
                // For now, store the string index - the VM will create string objects as needed.
                p += byte_count;
                DX_DEBUG(TAG, "  static[%u] = string_idx %u", i, str_idx);
                break;
            }
            case 0x18: // VALUE_TYPE (type_idx)
            case 0x19: // VALUE_FIELD (field_idx)
            case 0x1a: // VALUE_METHOD (method_idx)
            case 0x1b: // VALUE_ENUM (field_idx)
            {
                // Index types - store as int
                if (p + byte_count > end) break;
                out_values[i].tag = DX_VAL_INT;
                out_values[i].i = (int32_t)read_unsigned(p, byte_count);
                p += byte_count;
                break;
            }
            case 0x1c: { // VALUE_ARRAY — encoded_array
                // Format: ULEB128 size, then 'size' encoded_values
                // We skip the contained values but must advance p correctly
                if (p >= end) break;
                uint32_t arr_size = 0;
                uint32_t shift = 0;
                while (p < end) {
                    uint8_t b = *p++;
                    arr_size |= (uint32_t)(b & 0x7F) << shift;
                    if ((b & 0x80) == 0) break;
                    shift += 7;
                    if (shift >= 35) break;
                }
                // Skip each element by recursively parsing its encoded_value
                for (uint32_t j = 0; j < arr_size && p < end; j++) {
                    uint8_t elem_header = *p++;
                    uint8_t elem_type = elem_header & 0x1F;
                    uint8_t elem_arg = (elem_header >> 5) & 0x07;
                    if (elem_type == 0x1e || elem_type == 0x1f) {
                        // VALUE_NULL / VALUE_BOOLEAN: no data bytes
                        continue;
                    }
                    if (elem_type == 0x1c || elem_type == 0x1d) {
                        // Nested array/annotation - too complex, bail
                        DX_DEBUG(TAG, "  static[%u] nested VALUE_ARRAY/ANNOTATION, skipping rest", i);
                        out_values[i].tag = DX_VAL_VOID;
                        return DX_OK;
                    }
                    uint32_t elem_bytes = (uint32_t)(elem_arg + 1);
                    if (p + elem_bytes > end) break;
                    p += elem_bytes;
                }
                out_values[i].tag = DX_VAL_VOID; // Array values not stored yet
                DX_DEBUG(TAG, "  static[%u] = VALUE_ARRAY (size=%u, skipped)", i, arr_size);
                break;
            }
            case 0x1d: { // VALUE_ANNOTATION — encoded_annotation
                // Format: ULEB128 type_idx, ULEB128 size, then size (name_idx, encoded_value) pairs
                if (p >= end) break;
                // Skip type_idx ULEB128
                while (p < end && (*p & 0x80)) p++;
                if (p < end) p++;
                // Skip size ULEB128
                uint32_t ann_size = 0;
                uint32_t ann_shift = 0;
                while (p < end) {
                    uint8_t b = *p++;
                    ann_size |= (uint32_t)(b & 0x7F) << ann_shift;
                    if ((b & 0x80) == 0) break;
                    ann_shift += 7;
                    if (ann_shift >= 35) break;
                }
                // Skip each name-value pair
                for (uint32_t j = 0; j < ann_size && p < end; j++) {
                    // Skip name_idx ULEB128
                    while (p < end && (*p & 0x80)) p++;
                    if (p < end) p++;
                    // Skip the encoded_value
                    if (p >= end) break;
                    uint8_t elem_header = *p++;
                    uint8_t elem_type = elem_header & 0x1F;
                    uint8_t elem_arg = (elem_header >> 5) & 0x07;
                    if (elem_type == 0x1e || elem_type == 0x1f) continue;
                    if (elem_type == 0x1c || elem_type == 0x1d) {
                        // Nested - bail
                        out_values[i].tag = DX_VAL_VOID;
                        return DX_OK;
                    }
                    uint32_t elem_bytes = (uint32_t)(elem_arg + 1);
                    if (p + elem_bytes > end) break;
                    p += elem_bytes;
                }
                out_values[i].tag = DX_VAL_VOID;
                DX_DEBUG(TAG, "  static[%u] = VALUE_ANNOTATION (size=%u, skipped)", i, ann_size);
                break;
            }
            case 0x1e: { // VALUE_NULL (no data, value_arg must be 0)
                out_values[i].tag = DX_VAL_OBJ;
                out_values[i].obj = NULL;
                // No bytes to consume
                break;
            }
            case 0x1f: { // VALUE_BOOLEAN (value is in arg: 0=false, 1=true)
                out_values[i].tag = DX_VAL_INT;
                out_values[i].i = value_arg;
                // No bytes to consume
                break;
            }
            default: {
                // Unknown type - skip based on byte_count
                DX_WARN(TAG, "Unknown encoded_value type 0x%02x at static[%u]", value_type, i);
                if (p + byte_count <= end) {
                    p += byte_count;
                }
                out_values[i].tag = DX_VAL_VOID;
                break;
            }
        }
    }

    return DX_OK;
}

// ============================================================
// Method handle and call site parsing (from DEX map list)
// ============================================================

// DEX map_list item types
#define MAP_TYPE_METHOD_HANDLE_ITEM 0x0008
#define MAP_TYPE_CALL_SITE_ID_ITEM  0x0007

// Read an encoded_value from an encoded_array_item.
// Returns the value and advances *pp. type_out receives the value type byte.
static uint64_t read_encoded_value_cs(const uint8_t **pp, const uint8_t *end, uint8_t *type_out) {
    if (*pp >= end) { *type_out = 0xFF; return 0; }
    uint8_t header = *(*pp)++;
    uint8_t value_type = header & 0x1F;
    uint8_t value_arg = (header >> 5) & 0x07;
    *type_out = value_type;

    uint32_t byte_count = value_arg + 1;
    uint64_t value = 0;

    switch (value_type) {
        case 0x00: // VALUE_BYTE
        case 0x02: // VALUE_SHORT
        case 0x03: // VALUE_CHAR
        case 0x04: // VALUE_INT
        case 0x06: // VALUE_LONG
        case 0x10: // VALUE_FLOAT
        case 0x11: // VALUE_DOUBLE
        case 0x15: // VALUE_METHOD_HANDLE
        case 0x16: // VALUE_METHOD_TYPE
        case 0x17: // VALUE_STRING
        case 0x18: // VALUE_TYPE
        case 0x19: // VALUE_FIELD
        case 0x1A: // VALUE_METHOD
        case 0x1B: // VALUE_ENUM
            for (uint32_t i = 0; i < byte_count && *pp < end; i++) {
                value |= (uint64_t)(*(*pp)++) << (i * 8);
            }
            break;
        case 0x1C: // VALUE_ARRAY (skip - complex, not needed for call sites)
        case 0x1D: // VALUE_ANNOTATION (skip)
            break;
        case 0x1E: // VALUE_NULL
        case 0x1F: // VALUE_BOOLEAN
            value = value_arg; // boolean value is in value_arg
            break;
        default:
            break;
    }
    return value;
}

DxResult dx_dex_parse_call_sites(DxDexFile *dex) {
    if (!dex || !dex->raw_data) return DX_ERR_NULL_PTR;

    const uint8_t *data = dex->raw_data;
    uint32_t size = dex->raw_size;

    // The map_list is at header.map_off
    uint32_t map_off = dex->header.map_off;
    if (map_off == 0 || map_off + 4 > size) return DX_OK; // no map

    uint32_t map_size = read_u32(data + map_off);
    const uint8_t *map_entries = data + map_off + 4;

    uint32_t mh_offset = 0, mh_count = 0;
    uint32_t cs_offset = 0, cs_count = 0;

    // Scan map list for method_handle_item and call_site_id_item
    for (uint32_t i = 0; i < map_size; i++) {
        const uint8_t *entry = map_entries + i * 12;
        if ((uintptr_t)(entry + 12) > (uintptr_t)(data + size)) break;
        uint16_t type = read_u16(entry);
        uint32_t count = read_u32(entry + 4);
        uint32_t offset = read_u32(entry + 8);

        if (type == MAP_TYPE_METHOD_HANDLE_ITEM) {
            mh_offset = offset;
            mh_count = count;
        } else if (type == MAP_TYPE_CALL_SITE_ID_ITEM) {
            cs_offset = offset;
            cs_count = count;
        }
    }

    // Parse method handles
    if (mh_count > 0 && mh_offset > 0 && mh_offset + mh_count * 8 <= size) {
        dex->method_handles = (DxMethodHandle *)dx_malloc(sizeof(DxMethodHandle) * mh_count);
        if (!dex->method_handles) return DX_ERR_OUT_OF_MEMORY;
        dex->method_handle_count = mh_count;

        for (uint32_t i = 0; i < mh_count; i++) {
            const uint8_t *p = data + mh_offset + i * 8;
            dex->method_handles[i].method_handle_type = read_u16(p);
            // p+2 is unused/padding
            dex->method_handles[i].field_or_method_id = read_u16(p + 4);
            // p+6 is unused/padding
        }
        DX_INFO(TAG, "Parsed %u method handles", mh_count);
    }

    // Parse call site IDs -> call site items
    if (cs_count > 0 && cs_offset > 0 && cs_offset + cs_count * 4 <= size) {
        dex->call_sites = (DxCallSite *)dx_malloc(sizeof(DxCallSite) * cs_count);
        if (!dex->call_sites) return DX_ERR_OUT_OF_MEMORY;
        memset(dex->call_sites, 0, sizeof(DxCallSite) * cs_count);
        dex->call_site_count = cs_count;

        for (uint32_t i = 0; i < cs_count; i++) {
            // call_site_id_item is a uint32_t offset to the encoded_array_item
            uint32_t cs_data_off = read_u32(data + cs_offset + i * 4);
            if (cs_data_off == 0 || cs_data_off >= size) continue;

            // encoded_array_item: size (uleb128), then size encoded_values
            const uint8_t *p = data + cs_data_off;
            const uint8_t *end = data + size;
            uint32_t arr_size = read_uleb128(&p);

            if (arr_size < 3) continue; // Need at least: MethodHandle, String, MethodType

            DxCallSite *cs = &dex->call_sites[i];

            // [0] VALUE_METHOD_HANDLE: bootstrap method handle index
            uint8_t vtype;
            uint64_t val = read_encoded_value_cs(&p, end, &vtype);
            if (vtype != 0x15) continue; // not a method handle
            cs->method_handle_idx = (uint32_t)val;

            // [1] VALUE_STRING: method name the lambda implements
            val = read_encoded_value_cs(&p, end, &vtype);
            if (vtype != 0x17) continue; // not a string
            uint32_t name_str_idx = (uint32_t)val;
            cs->method_name = dx_dex_get_string(dex, name_str_idx);

            // [2] VALUE_METHOD_TYPE: erased method type (proto index)
            val = read_encoded_value_cs(&p, end, &vtype);
            if (vtype != 0x16) continue; // not a method type
            cs->proto_idx = (uint32_t)val;

            // Determine what kind of bootstrap this is
            if (cs->method_handle_idx < dex->method_handle_count) {
                DxMethodHandle *bsm = &dex->method_handles[cs->method_handle_idx];
                if (bsm->field_or_method_id < dex->method_count) {
                    const char *bsm_class = dx_dex_get_method_class(dex, bsm->field_or_method_id);
                    const char *bsm_name = dx_dex_get_method_name(dex, bsm->field_or_method_id);

                    // Check for LambdaMetafactory
                    if (bsm_class && bsm_name &&
                        strstr(bsm_class, "LambdaMetafactory") &&
                        strcmp(bsm_name, "metafactory") == 0) {
                        // Additional args: [3] MethodType, [4] MethodHandle, [5] MethodType
                        if (arr_size >= 6) {
                            // [3] VALUE_METHOD_TYPE: target method type
                            val = read_encoded_value_cs(&p, end, &vtype);
                            if (vtype == 0x16) cs->target_proto_idx = (uint32_t)val;

                            // [4] VALUE_METHOD_HANDLE: implementation method handle
                            val = read_encoded_value_cs(&p, end, &vtype);
                            if (vtype == 0x15) {
                                uint32_t impl_mh_idx = (uint32_t)val;
                                if (impl_mh_idx < dex->method_handle_count) {
                                    DxMethodHandle *impl_mh = &dex->method_handles[impl_mh_idx];
                                    cs->impl_method_idx = impl_mh->field_or_method_id;
                                    cs->impl_kind = impl_mh->method_handle_type;
                                }
                            }

                            // [5] VALUE_METHOD_TYPE: instantiated method type
                            read_encoded_value_cs(&p, end, &vtype);
                        }
                        cs->is_string_concat = false;
                        cs->parsed = true;
                    }
                    // Check for StringConcatFactory
                    else if (bsm_class && bsm_name &&
                             strstr(bsm_class, "StringConcatFactory") &&
                             strcmp(bsm_name, "makeConcatWithConstants") == 0) {
                        if (arr_size >= 4) {
                            val = read_encoded_value_cs(&p, end, &vtype);
                            if (vtype == 0x17) { // VALUE_STRING - recipe
                                cs->concat_recipe = dx_dex_get_string(dex, (uint32_t)val);
                            }
                        }
                        cs->is_string_concat = true;
                        cs->parsed = true;
                    }
                    else {
                        cs->parsed = true;
                        DX_INFO(TAG, "Call site %u: unknown bootstrap %s.%s", i,
                                bsm_class ? bsm_class : "?", bsm_name ? bsm_name : "?");
                    }
                }
            }
        }
        DX_INFO(TAG, "Parsed %u call sites", cs_count);
    }

    return DX_OK;
}

const DxCallSite *dx_dex_get_call_site(const DxDexFile *dex, uint32_t call_site_idx) {
    if (!dex || !dex->call_sites || call_site_idx >= dex->call_site_count) return NULL;
    if (!dex->call_sites[call_site_idx].parsed) return NULL;
    return &dex->call_sites[call_site_idx];
}

// ── Annotation element lookup helpers ──

static const DxAnnotationElement *find_element(const DxAnnotationEntry *ann, const char *name) {
    if (!ann || !ann->elements || !name) return NULL;
    for (uint32_t i = 0; i < ann->element_count; i++) {
        if (ann->elements[i].name && strcmp(ann->elements[i].name, name) == 0) {
            return &ann->elements[i];
        }
    }
    return NULL;
}

const char *dx_annotation_get_string(const DxAnnotationEntry *ann, const char *element_name) {
    const DxAnnotationElement *e = find_element(ann, element_name);
    if (!e || e->val_type != DX_ANNO_VAL_STRING) return NULL;
    return e->str_value;
}

int32_t dx_annotation_get_int(const DxAnnotationEntry *ann, const char *element_name, int32_t default_val) {
    const DxAnnotationElement *e = find_element(ann, element_name);
    if (!e) return default_val;
    switch (e->val_type) {
        case DX_ANNO_VAL_BYTE:
        case DX_ANNO_VAL_SHORT:
        case DX_ANNO_VAL_CHAR:
        case DX_ANNO_VAL_INT:
        case DX_ANNO_VAL_BOOLEAN:
            return e->i_value;
        default:
            return default_val;
    }
}

int64_t dx_annotation_get_long(const DxAnnotationEntry *ann, const char *element_name, int64_t default_val) {
    const DxAnnotationElement *e = find_element(ann, element_name);
    if (!e) return default_val;
    if (e->val_type == DX_ANNO_VAL_LONG) return e->l_value;
    if (e->val_type == DX_ANNO_VAL_INT || e->val_type == DX_ANNO_VAL_SHORT
        || e->val_type == DX_ANNO_VAL_BYTE) return (int64_t)e->i_value;
    return default_val;
}

float dx_annotation_get_float(const DxAnnotationEntry *ann, const char *element_name, float default_val) {
    const DxAnnotationElement *e = find_element(ann, element_name);
    if (!e || e->val_type != DX_ANNO_VAL_FLOAT) return default_val;
    return e->f_value;
}

double dx_annotation_get_double(const DxAnnotationEntry *ann, const char *element_name, double default_val) {
    const DxAnnotationElement *e = find_element(ann, element_name);
    if (!e) return default_val;
    if (e->val_type == DX_ANNO_VAL_DOUBLE) return e->d_value;
    if (e->val_type == DX_ANNO_VAL_FLOAT) return (double)e->f_value;
    return default_val;
}

bool dx_annotation_get_bool(const DxAnnotationEntry *ann, const char *element_name, bool default_val) {
    const DxAnnotationElement *e = find_element(ann, element_name);
    if (!e || e->val_type != DX_ANNO_VAL_BOOLEAN) return default_val;
    return e->i_value != 0;
}

const char *dx_annotation_get_type(const DxAnnotationEntry *ann, const char *element_name) {
    const DxAnnotationElement *e = find_element(ann, element_name);
    if (!e || e->val_type != DX_ANNO_VAL_TYPE) return NULL;
    return e->str_value;
}

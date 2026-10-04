#include "../Include/dx_resources.h"
#include "../Include/dx_log.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define TAG "Resources"
#define DX_MAX_RESOURCES_SIZE  (100u * 1024u * 1024u)  // 100 MB limit for resources.arsc

#include "../Include/dx_memory.h"

// resources.arsc chunk types
#define RES_TABLE_TYPE           0x0002
#define RES_STRING_POOL_TYPE     0x0001
#define RES_TABLE_PACKAGE_TYPE   0x0200
#define RES_TABLE_TYPE_TYPE      0x0201
#define RES_TABLE_TYPE_SPEC_TYPE 0x0202

// Resource value types (Android format)
#define RES_VALUE_TYPE_NULL      0x00
#define RES_VALUE_TYPE_REF       0x01
#define RES_VALUE_TYPE_STRING    0x03
#define RES_VALUE_TYPE_FLOAT     0x04
#define RES_VALUE_TYPE_DIMENSION 0x05
#define RES_VALUE_TYPE_FRACTION  0x06
#define RES_VALUE_TYPE_INT_DEC   0x10
#define RES_VALUE_TYPE_INT_HEX   0x11
#define RES_VALUE_TYPE_INT_BOOL  0x12
#define RES_VALUE_TYPE_INT_COLOR_ARGB8 0x1c
#define RES_VALUE_TYPE_INT_COLOR_RGB8  0x1d
#define RES_VALUE_TYPE_INT_COLOR_ARGB4 0x1e
#define RES_VALUE_TYPE_INT_COLOR_RGB4  0x1f

#define INITIAL_ENTRY_CAPACITY 256
#define INITIAL_STYLE_CAPACITY 64
#define INITIAL_ARRAY_CAPACITY 32
#define INITIAL_PLURAL_CAPACITY 16
#define MAX_STYLE_PARENT_DEPTH 20

// Plural bag key constants (from Android's ResourceTypes.h)
#define PLURAL_KEY_ZERO   0x01000004
#define PLURAL_KEY_ONE    0x01000005
#define PLURAL_KEY_TWO    0x01000006
#define PLURAL_KEY_FEW    0x01000007
#define PLURAL_KEY_MANY   0x01000008
#define PLURAL_KEY_OTHER  0x01000009

// ResTable_config field offsets within the config blob (relative to config start)
// See Android's ResourceTypes.h ResTable_config struct layout:
//   uint32_t size           @ 0
//   uint16_t mcc            @ 4
//   uint16_t mnc            @ 6
//   char     language[2]    @ 8
//   char     country[2]     @ 10
//   uint8_t  orientation    @ 12
//   uint8_t  touchscreen    @ 13
//   uint16_t density        @ 14
//   uint8_t  keyboard       @ 16
//   uint8_t  navigation     @ 17
//   uint8_t  inputFlags     @ 18
//   uint8_t  inputPad0      @ 19
//   uint16_t screenWidth    @ 20
//   uint16_t screenHeight   @ 22
//   uint16_t sdkVersion     @ 24
//   uint16_t minorVersion   @ 26
//   ... (more fields follow in larger configs)
//   uint16_t smallestScreenWidthDp @ 36
//   uint16_t screenWidthDp  @ 38
//   uint16_t screenHeightDp @ 40

// Forward declarations for helpers used by parse_res_config
static uint16_t read_u16(const uint8_t *p);
static uint32_t read_u32(const uint8_t *p);
static bool is_default_config(const DxResConfig *c);
static bool config_contradicts_device(const DxResConfig *cfg, const DxDeviceConfig *dev);
static int32_t config_match_score(const DxResConfig *cfg, const DxDeviceConfig *dev);
static const DxResourceEntry *pick_best_entry(const DxResources *res, uint32_t id,
                                                const DxDeviceConfig *dev);

// Parse a ResTable_config from raw bytes into our DxResConfig struct
static DxResConfig parse_res_config(const uint8_t *cfg_data, uint32_t cfg_size) {
    DxResConfig c;
    memset(&c, 0, sizeof(c));
    if (!cfg_data || cfg_size < 4) return c;

    // Language and country (offset 8,10 from config start)
    if (cfg_size >= 12) {
        c.language[0] = (char)cfg_data[8];
        c.language[1] = (char)cfg_data[9];
        c.country[0]  = (char)cfg_data[10];
        c.country[1]  = (char)cfg_data[11];
    }
    // Orientation (offset 12)
    if (cfg_size >= 13) {
        c.orientation = cfg_data[12];
    }
    // Density (offset 14, uint16 LE)
    if (cfg_size >= 16) {
        c.density = read_u16(cfg_data + 14);
    }
    // SDK version (offset 24, uint16 LE)
    if (cfg_size >= 26) {
        c.sdk_version = read_u16(cfg_data + 24);
    }
    // Screen width/height in pixels (offset 20,22)
    if (cfg_size >= 24) {
        c.screen_width = read_u16(cfg_data + 20);
        c.screen_height = read_u16(cfg_data + 22);
    }
    // screenLayout (offset 32): bits 0-3 = screen size
    if (cfg_size >= 33) {
        uint8_t screen_layout = cfg_data[32];
        c.screen_layout = screen_layout;
        uint8_t sz = screen_layout & 0x0F;
        if (sz >= 1 && sz <= 4) {
            c.screen_size = sz;
        }
    }
    // uiMode (offset 33): bits 4-5 = night mode (mask 0x30, shift 4)
    if (cfg_size >= 34) {
        uint8_t ui_mode = cfg_data[33];
        c.ui_mode = ui_mode;
        uint8_t night = (ui_mode >> 4) & 0x03;
        if (night == 1 || night == 2) {
            c.night_mode = night;
        }
    }
    // smallestScreenWidthDp (offset 36)
    if (cfg_size >= 38) {
        c.smallest_screen_width_dp = read_u16(cfg_data + 36);
    }
    return c;
}

// Initialize device config with typical iPhone defaults
void dx_device_config_init(DxDeviceConfig *cfg) {
    if (!cfg) return;
    memset(cfg, 0, sizeof(*cfg));
    cfg->language[0] = 'e'; cfg->language[1] = 'n'; cfg->language[2] = '\0';
    cfg->country[0] = 'U'; cfg->country[1] = 'S'; cfg->country[2] = '\0';
    cfg->density = 440;       // iPhone ~440 dpi
    cfg->sdk_version = 33;    // emulate Android 13
    cfg->screen_width = 393;  // iPhone 15 Pro logical width
    cfg->screen_height = 852; // iPhone 15 Pro logical height
    cfg->orientation = 1;     // portrait
    cfg->night_mode = DX_NIGHT_MODE_NOTNIGHT;  // default: not night
    cfg->screen_size = DX_SCREEN_SIZE_NORMAL;  // default: normal (iPhone)
}

// Check if a resource config is "default" (all qualifiers zero/empty)
static bool is_default_config(const DxResConfig *c) {
    return c->language[0] == 0 && c->country[0] == 0 &&
           c->density == 0 && c->sdk_version == 0 &&
           c->orientation == 0 && c->screen_width == 0 &&
           c->screen_height == 0 && c->night_mode == 0 &&
           c->screen_size == 0;
}

// Check if a config contradicts the device config (should be eliminated)
static bool config_contradicts_device(const DxResConfig *cfg, const DxDeviceConfig *dev) {
    // Orientation: if specified, must match
    if (cfg->orientation != 0 && dev->orientation != 0 &&
        cfg->orientation != dev->orientation) {
        return true;
    }
    // SDK version: config requires higher SDK than device supports
    if (cfg->sdk_version > dev->sdk_version) {
        return true;
    }
    // Night mode: if specified, must match device
    if (cfg->night_mode != 0 && cfg->night_mode != dev->night_mode) {
        return true;
    }
    // Screen size: if specified, must not exceed device screen size
    if (cfg->screen_size != 0 && dev->screen_size != 0 &&
        cfg->screen_size > dev->screen_size) {
        return true;
    }
    return false;
}

// Compute a match score for a resource config against device config.
// Higher score = better match. Returns -1 if config contradicts device.
static int32_t config_match_score(const DxResConfig *cfg, const DxDeviceConfig *dev) {
    if (config_contradicts_device(cfg, dev)) return -1;

    int32_t score = 0;

    // --- Locale matching (highest priority) ---
    if (cfg->language[0] != 0) {
        bool lang_match = (cfg->language[0] == dev->language[0] &&
                           cfg->language[1] == dev->language[1]);
        if (!lang_match) {
            return -1; // wrong locale, eliminate
        }
        score += 1000; // language matches
        if (cfg->country[0] != 0) {
            bool country_match = (cfg->country[0] == dev->country[0] &&
                                  cfg->country[1] == dev->country[1]);
            if (country_match) {
                score += 500; // exact locale match
            }
            // Non-matching country is still OK, just lower priority
        }
    }

    // --- SDK version: prefer highest version <= device ---
    if (cfg->sdk_version > 0) {
        score += (int32_t)cfg->sdk_version; // higher = better (already filtered > dev)
    }

    // --- Density matching: prefer closest, tie-break toward higher ---
    if (cfg->density > 0 && cfg->density != DX_DENSITY_NODPI) {
        int32_t diff = (int32_t)cfg->density - (int32_t)dev->density;
        int32_t abs_diff = diff < 0 ? -diff : diff;
        // Base density score: closer is better (max 640 dpi range -> invert)
        int32_t density_score = 700 - abs_diff;
        // Prefer higher density over lower when equidistant
        if (diff > 0) density_score += 1;
        if (density_score < 0) density_score = 0;
        score += density_score;
    } else if (cfg->density == DX_DENSITY_NODPI) {
        // NODPI resources are density-independent, modest score
        score += 100;
    }

    // --- Night mode match (score 8 — between SDK and density) ---
    if (cfg->night_mode != 0 && cfg->night_mode == dev->night_mode) {
        score += 8;
    }

    // --- Screen size match (score 4 — prefer largest that fits) ---
    if (cfg->screen_size != 0 && dev->screen_size != 0 &&
        cfg->screen_size <= dev->screen_size) {
        score += 4 + (int32_t)cfg->screen_size; // prefer closer match
    }

    // --- Orientation match bonus ---
    if (cfg->orientation != 0 && cfg->orientation == dev->orientation) {
        score += 50;
    }

    return score;
}

// Pick the best matching entry among all entries with a given resource ID
static const DxResourceEntry *pick_best_entry(const DxResources *res, uint32_t id,
                                                const DxDeviceConfig *dev) {
    if (!res || !dev) return NULL;

    const DxResourceEntry *best = NULL;
    int32_t best_score = -2; // worse than any contradiction

    for (uint32_t i = 0; i < res->entry_count; i++) {
        if (res->entries[i].id != id) continue;

        const DxResourceEntry *e = &res->entries[i];
        int32_t score;

        if (is_default_config(&e->config)) {
            // Default config: always valid, score 0 (lowest non-negative)
            score = 0;
        } else {
            score = config_match_score(&e->config, dev);
        }

        if (score > best_score) {
            best_score = score;
            best = e;
        }
    }

    return best;
}

// ResTable_entry flags
#define FLAG_COMPLEX 0x0001

static uint16_t read_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t read_u32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

// Decode a string from a string pool (UTF-8 or UTF-16)
static char *decode_res_string(const uint8_t *pool_data, uint32_t pool_size,
                                uint32_t offset, bool is_utf8) {
    if (offset >= pool_size) return dx_strdup("");
    const uint8_t *p = pool_data + offset;
    const uint8_t *end = pool_data + pool_size;

    if (is_utf8) {
        if (p + 1 > end) return dx_strdup("");
        uint32_t char_count = *p++;
        if (char_count > 0x7F) {
            if (p + 1 > end) return dx_strdup("");
            char_count = ((char_count & 0x7F) << 8) | *p++;
        }
        if (p + 1 > end) return dx_strdup("");
        uint32_t byte_count = *p++;
        if (byte_count > 0x7F) {
            if (p + 1 > end) return dx_strdup("");
            byte_count = ((byte_count & 0x7F) << 8) | *p++;
        }
        if (p + byte_count > end) byte_count = (uint32_t)(end - p);
        char *s = (char *)dx_malloc(byte_count + 1);
        if (!s) return NULL;
        memcpy(s, p, byte_count);
        s[byte_count] = '\0';
        return s;
    } else {
        if (p + 2 > end) return dx_strdup("");
        uint16_t char_count = read_u16(p);
        p += 2;
        // Clamp to available data
        if (p + (uint32_t)char_count * 2 > end) {
            char_count = (uint16_t)((end - p) / 2);
        }
        char *s = (char *)dx_malloc(char_count + 1);
        if (!s) return NULL;
        for (uint32_t i = 0; i < char_count; i++) {
            uint16_t c = read_u16(p + i * 2);
            s[i] = (c < 128) ? (char)c : '?';
        }
        s[char_count] = '\0';
        return s;
    }
}

// Parse a string pool chunk, returning the decoded strings array
static DxResult parse_string_pool(const uint8_t *data, uint32_t size, uint32_t pos,
                                    char ***out_strings, uint32_t *out_count) {
    if (pos + 28 > size) return DX_ERR_INVALID_FORMAT;

    uint32_t string_count = read_u32(data + pos + 8);
    uint32_t flags = read_u32(data + pos + 16);
    uint32_t strings_start = read_u32(data + pos + 20);
    bool is_utf8 = (flags & (1 << 8)) != 0;

    // Integer overflow protection on string pool allocation
    if (string_count > 2000000) {  // 2M strings max
        DX_ERROR(TAG, "String pool count %u would overflow allocation", string_count);
        return DX_ERR_INVALID_FORMAT;
    }
    char **strings = (char **)dx_malloc(sizeof(char *) * (string_count + 1));
    if (!strings) return DX_ERR_OUT_OF_MEMORY;

    uint32_t offsets_start = pos + 28;
    uint32_t pool_data_start = pos + strings_start;

    // Validate pool_data_start is within bounds
    if (strings_start < 28 || pool_data_start > size) {
        DX_ERROR(TAG, "Resource string pool data start out of bounds: %u", strings_start);
        dx_free(strings);
        return DX_ERR_INVALID_FORMAT;
    }

    // Read the chunk size so we can clamp offsets to the chunk boundary
    uint32_t chunk_size = read_u32(data + pos + 4);
    uint32_t chunk_end = pos + chunk_size;
    if (chunk_end > size) chunk_end = size;  // clamp to file boundary

    for (uint32_t i = 0; i < string_count; i++) {
        if (offsets_start + i * 4 + 4 > size) break;
        uint32_t str_offset = read_u32(data + offsets_start + i * 4);
        // Validate string offset against chunk boundary (not just file size)
        if (pool_data_start + str_offset < chunk_end) {
            strings[i] = decode_res_string(
                data + pool_data_start,
                chunk_end - pool_data_start,
                str_offset,
                is_utf8
            );
        } else {
            DX_WARN(TAG, "String pool offset %u for index %u exceeds chunk boundary %u, substituting empty",
                    str_offset, i, chunk_end - pool_data_start);
            strings[i] = dx_strdup("");
        }
    }

    *out_strings = strings;
    *out_count = string_count;
    return DX_OK;
}

// Decode Android's dimension value format
float dx_resources_decode_dimen(uint32_t raw_data, uint8_t *out_unit) {
    // Low 4 bits = unit, next 4 bits = radix, top 24 bits = mantissa
    uint8_t unit = raw_data & 0x0F;
    uint8_t radix = (raw_data >> 4) & 0x03;
    int32_t mantissa = (int32_t)(raw_data & 0xFFFFFF00);

    // Android uses fixed-point with different radix positions
    static const float radix_mults[] = {
        1.0f / (1 << 0),   // 23p0
        1.0f / (1 << 7),   // 16p7
        1.0f / (1 << 15),  // 8p15
        1.0f / (1 << 23),  // 0p23
    };

    float value = (float)mantissa * radix_mults[radix];

    if (out_unit) *out_unit = unit;
    return value;
}

// Expand color formats to full ARGB8
static uint32_t normalize_color(uint8_t val_type, uint32_t raw) {
    switch (val_type) {
        case RES_VALUE_TYPE_INT_COLOR_ARGB8:
            return raw;
        case RES_VALUE_TYPE_INT_COLOR_RGB8:
            return 0xFF000000 | (raw & 0x00FFFFFF);
        case RES_VALUE_TYPE_INT_COLOR_ARGB4: {
            uint8_t a = (raw >> 12) & 0xF;
            uint8_t r = (raw >>  8) & 0xF;
            uint8_t g = (raw >>  4) & 0xF;
            uint8_t b = (raw >>  0) & 0xF;
            return ((uint32_t)(a | (a << 4)) << 24) |
                   ((uint32_t)(r | (r << 4)) << 16) |
                   ((uint32_t)(g | (g << 4)) <<  8) |
                   ((uint32_t)(b | (b << 4)));
        }
        case RES_VALUE_TYPE_INT_COLOR_RGB4: {
            uint8_t r = (raw >> 8) & 0xF;
            uint8_t g = (raw >> 4) & 0xF;
            uint8_t b = (raw >> 0) & 0xF;
            return 0xFF000000 |
                   ((uint32_t)(r | (r << 4)) << 16) |
                   ((uint32_t)(g | (g << 4)) <<  8) |
                   ((uint32_t)(b | (b << 4)));
        }
        default:
            return raw;
    }
}

// Add a resource entry to the table, growing if needed
static bool add_resource_entry(DxResources *res, const DxResourceEntry *entry) {
    if (res->entry_count >= res->entry_capacity) {
        uint32_t new_cap = res->entry_capacity == 0 ? INITIAL_ENTRY_CAPACITY : res->entry_capacity * 2;
        DxResourceEntry *new_entries = (DxResourceEntry *)dx_realloc(
            res->entries, sizeof(DxResourceEntry) * new_cap);
        if (!new_entries) return false;
        res->entries = new_entries;
        res->entry_capacity = new_cap;
    }
    res->entries[res->entry_count++] = *entry;
    return true;
}

// Add a style record to the table, growing if needed
static bool add_style_record(DxResources *res, uint32_t style_res_id, uint32_t parent_id,
                              DxStyleEntry *entries, uint32_t entry_count) {
    if (res->style_count >= res->style_capacity) {
        uint32_t new_cap = res->style_capacity == 0 ? INITIAL_STYLE_CAPACITY : res->style_capacity * 2;
        DxStyleRecord *new_styles = (DxStyleRecord *)dx_realloc(
            res->styles, sizeof(DxStyleRecord) * new_cap);
        if (!new_styles) { dx_free(entries); return false; }
        res->styles = new_styles;
        res->style_capacity = new_cap;
    }
    DxStyleRecord *rec = &res->styles[res->style_count++];
    rec->style_res_id = style_res_id;
    rec->parent_id = parent_id;
    rec->entries = entries;
    rec->entry_count = entry_count;
    return true;
}

// Find a style record by resource ID
static const DxStyleRecord *find_style_record(const DxResources *res, uint32_t style_res_id) {
    if (!res) return NULL;
    for (uint32_t i = 0; i < res->style_count; i++) {
        if (res->styles[i].style_res_id == style_res_id) {
            return &res->styles[i];
        }
    }
    return NULL;
}

// Add an array resource record, growing if needed
static bool add_array_resource(DxResources *res, const DxArrayResource *arr) {
    if (res->array_count >= res->array_capacity) {
        uint32_t new_cap = res->array_capacity == 0 ? INITIAL_ARRAY_CAPACITY : res->array_capacity * 2;
        DxArrayResource *new_arrays = (DxArrayResource *)dx_realloc(
            res->arrays, sizeof(DxArrayResource) * new_cap);
        if (!new_arrays) return false;
        res->arrays = new_arrays;
        res->array_capacity = new_cap;
    }
    res->arrays[res->array_count++] = *arr;
    return true;
}

// Add a plural resource record, growing if needed
static bool add_plural_resource(DxResources *res, const DxPluralResource *pl) {
    if (res->plural_count >= res->plural_capacity) {
        uint32_t new_cap = res->plural_capacity == 0 ? INITIAL_PLURAL_CAPACITY : res->plural_capacity * 2;
        DxPluralResource *new_plurals = (DxPluralResource *)dx_realloc(
            res->plurals, sizeof(DxPluralResource) * new_cap);
        if (!new_plurals) return false;
        res->plurals = new_plurals;
        res->plural_capacity = new_cap;
    }
    res->plurals[res->plural_count++] = *pl;
    return true;
}

// Decode a float from raw uint32 bits
static float decode_float(uint32_t raw) {
    union { uint32_t u; float f; } conv;
    conv.u = raw;
    return conv.f;
}

DxResult dx_resources_parse(const uint8_t *data, uint32_t size, DxResources **out) {
    if (!data || !out) return DX_ERR_NULL_PTR;
    if (size < 12) return DX_ERR_INVALID_FORMAT;
    if (size > DX_MAX_RESOURCES_SIZE) {
        DX_ERROR(TAG, "resources.arsc too large: %u bytes (limit %u)", size, DX_MAX_RESOURCES_SIZE);
        return DX_ERR_INVALID_FORMAT;
    }

    uint16_t type = read_u16(data);
    if (type != RES_TABLE_TYPE) {
        DX_ERROR(TAG, "Invalid resource table type: 0x%04x", type);
        return DX_ERR_INVALID_FORMAT;
    }

    DxResources *res = (DxResources *)dx_malloc(sizeof(DxResources));
    if (!res) return DX_ERR_OUT_OF_MEMORY;

    // Parse global string pool (first chunk after 12-byte table header)
    uint32_t pos = 12;
    if (pos + 8 > size) goto fail;

    uint16_t sp_type = read_u16(data + pos);
    uint32_t sp_size = read_u32(data + pos + 4);

    if (sp_type == RES_STRING_POOL_TYPE && pos + sp_size <= size) {
        DxResult pr = parse_string_pool(data, size, pos, &res->strings, &res->string_count);
        if (pr != DX_OK) goto fail;
        DX_INFO(TAG, "Global string pool: %u strings", res->string_count);
        pos += sp_size;
    }

    // Parse package chunks to extract resource type entries
    while (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        uint32_t chunk_size = read_u32(data + pos + 4);
        if (chunk_size < 8 || pos + chunk_size > size) break;

        if (chunk_type == RES_TABLE_PACKAGE_TYPE) {
            // Package chunk header: read actual header size
            uint16_t pkg_header_size = read_u16(data + pos + 2);
            if (pkg_header_size < 44 || pos + pkg_header_size > size) {
                pos += chunk_size; continue;
            }

            uint32_t pkg_id = read_u32(data + pos + 8);
            // Package name is at offset 12, 128 UTF-16 chars - skip for now
            uint32_t type_strings_off = read_u32(data + pos + 268);
            uint32_t key_strings_off = read_u32(data + pos + 276);

            // Parse key string pool (contains field/resource names)
            char **key_strings = NULL;
            uint32_t key_count = 0;
            uint32_t key_pool_pos = pos + key_strings_off;
            if (key_pool_pos + 28 <= size &&
                read_u16(data + key_pool_pos) == RES_STRING_POOL_TYPE) {
                parse_string_pool(data, size, key_pool_pos, &key_strings, &key_count);
            }

            // Parse type string pool (contains type names like "string", "layout", etc.)
            char **type_strings = NULL;
            uint32_t type_str_count = 0;
            uint32_t type_pool_pos = pos + type_strings_off;
            if (type_pool_pos + 28 <= size &&
                read_u16(data + type_pool_pos) == RES_STRING_POOL_TYPE) {
                parse_string_pool(data, size, type_pool_pos, &type_strings, &type_str_count);
            }

            DX_DEBUG(TAG, "Package 0x%02x: header=%u, typeStrOff=%u, keyStrOff=%u, typeStrs=%u, keyStrs=%u",
                     pkg_id, pkg_header_size, type_strings_off, key_strings_off,
                     type_str_count, key_count);

            // Walk ALL sub-chunks within the package sequentially.
            // Start right after the package header and iterate through all chunks.
            uint32_t sub_pos = pos + pkg_header_size;
            // Some packages have header_size pointing past the string pools;
            // use the minimum of header_size and type_strings_off as the start.
            if (type_strings_off > 0 && pos + type_strings_off < sub_pos) {
                sub_pos = pos + type_strings_off;
            }

            while (sub_pos + 8 <= pos + chunk_size && sub_pos + 8 <= size) {
                uint16_t sub_type = read_u16(data + sub_pos);
                uint32_t sub_size = read_u32(data + sub_pos + 4);
                if (sub_size < 8 || sub_pos + sub_size > size) break;

                if (sub_type == RES_TABLE_TYPE_TYPE) {
                    // ResTable_type: extract entries
                    if (sub_pos + 76 > size) { sub_pos += sub_size; continue; }

                    uint8_t type_id = data[sub_pos + 8]; // 1-based
                    uint32_t entry_count = read_u32(data + sub_pos + 48);
                    uint32_t entries_start = read_u32(data + sub_pos + 52);

                    // Parse the ResTable_config embedded in this type chunk.
                    // The config sits at offset 20 from chunk start (after
                    // chunk_header(8) + id(1) + flags(1) + reserved(2) +
                    // entryCount(4) + entriesStart(4)).
                    // Config size = headerSize - 20.
                    uint16_t header_size = read_u16(data + sub_pos + 2);
                    DxResConfig type_config;
                    memset(&type_config, 0, sizeof(type_config));
                    if (header_size > 20 && sub_pos + header_size <= size) {
                        uint32_t cfg_size = header_size - 20;
                        type_config = parse_res_config(data + sub_pos + 20, cfg_size);
                    }

                    const char *type_name_str = "";
                    if (type_strings && type_id > 0 && (type_id - 1) < type_str_count) {
                        type_name_str = type_strings[type_id - 1];
                    }

                    bool is_string_type = (strcmp(type_name_str, "string") == 0);
                    bool is_layout_type = (strcmp(type_name_str, "layout") == 0);
                    bool is_array_type = (strcmp(type_name_str, "array") == 0);
                    bool is_plurals_type = (strcmp(type_name_str, "plurals") == 0);
                    uint32_t offsets_base = sub_pos + header_size;
                    uint32_t entries_base = sub_pos + entries_start;

                    for (uint32_t e = 0; e < entry_count; e++) {
                        if (offsets_base + e * 4 + 4 > size) break;
                        uint32_t entry_off = read_u32(data + offsets_base + e * 4);
                        if (entry_off == 0xFFFFFFFF) continue; // NO_ENTRY

                        uint32_t entry_pos = entries_base + entry_off;
                        if (entry_pos + 8 > size) continue;

                        uint16_t entry_size = read_u16(data + entry_pos);
                        uint16_t entry_flags = read_u16(data + entry_pos + 2);
                        uint32_t key_idx = read_u32(data + entry_pos + 4);

                        uint32_t res_id = (pkg_id << 24) | ((uint32_t)type_id << 16) | e;

                        // Get the key name for this entry
                        const char *key_name = (key_strings && key_idx < key_count) ?
                                                key_strings[key_idx] : NULL;

                        // --- Handle complex/bag entries (styles, arrays, plurals) ---
                        if (entry_flags & FLAG_COMPLEX) {
                            // ResTable_map_entry: 16-byte header (entry 8 + parent 4 + count 4)
                            if (entry_pos + 16 > size) continue;
                            uint32_t parent_ref = read_u32(data + entry_pos + 8);
                            uint32_t map_count = read_u32(data + entry_pos + 12);

                            // Allocate style entries
                            DxStyleEntry *style_entries = NULL;
                            uint32_t valid_count = 0;
                            if (map_count > 0 && map_count < 10000) {
                                style_entries = (DxStyleEntry *)dx_malloc(sizeof(DxStyleEntry) * map_count);
                            }

                            // Each map entry: 4 bytes name(attr_id) + 8 bytes Res_value (size,0,type,data)
                            uint32_t map_pos = entry_pos + 16;
                            for (uint32_t m = 0; m < map_count; m++) {
                                if (map_pos + 12 > size) break;
                                uint32_t map_name = read_u32(data + map_pos);
                                // Res_value: uint16 size, uint8 res0, uint8 type, uint32 data
                                uint8_t  map_val_type = data[map_pos + 7];
                                uint32_t map_val_data = read_u32(data + map_pos + 8);

                                if (style_entries) {
                                    style_entries[valid_count].attr_id = map_name;
                                    style_entries[valid_count].value_type = map_val_type;
                                    style_entries[valid_count].value_data = map_val_data;
                                    valid_count++;
                                }

                                map_pos += 12; // 4 + 8 bytes per map entry
                            }

                            // --- Parse array resources (string-array, integer-array) ---
                            if (is_array_type && valid_count > 0 && style_entries) {
                                // Determine if string or integer array by checking first entry's value type
                                bool is_str_arr = false;
                                for (uint32_t a = 0; a < valid_count; a++) {
                                    if (style_entries[a].value_type == RES_VALUE_TYPE_STRING) {
                                        is_str_arr = true; break;
                                    } else if (style_entries[a].value_type == RES_VALUE_TYPE_INT_DEC ||
                                               style_entries[a].value_type == RES_VALUE_TYPE_INT_HEX) {
                                        break;
                                    }
                                }

                                DxArrayResource arr;
                                memset(&arr, 0, sizeof(arr));
                                arr.res_id = res_id;
                                arr.count = valid_count;
                                arr.is_string_array = is_str_arr;

                                if (is_str_arr) {
                                    arr.string_values = (char **)dx_malloc(sizeof(char *) * valid_count);
                                    if (arr.string_values) {
                                        for (uint32_t a = 0; a < valid_count; a++) {
                                            if (style_entries[a].value_type == RES_VALUE_TYPE_STRING &&
                                                style_entries[a].value_data < res->string_count && res->strings) {
                                                arr.string_values[a] = dx_strdup(res->strings[style_entries[a].value_data]);
                                            } else {
                                                arr.string_values[a] = dx_strdup("");
                                            }
                                        }
                                        add_array_resource(res, &arr);
                                        DX_TRACE(TAG, "StringArray 0x%08x (%s): %u elements",
                                                 res_id, key_name ? key_name : "?", valid_count);
                                    }
                                } else {
                                    arr.int_values = (int32_t *)dx_malloc(sizeof(int32_t) * valid_count);
                                    if (arr.int_values) {
                                        for (uint32_t a = 0; a < valid_count; a++) {
                                            arr.int_values[a] = (int32_t)style_entries[a].value_data;
                                        }
                                        add_array_resource(res, &arr);
                                        DX_TRACE(TAG, "IntArray 0x%08x (%s): %u elements",
                                                 res_id, key_name ? key_name : "?", valid_count);
                                    }
                                }
                            }

                            // --- Parse plural resources ---
                            if (is_plurals_type && valid_count > 0 && style_entries) {
                                DxPluralResource pl;
                                memset(&pl, 0, sizeof(pl));
                                pl.res_id = res_id;

                                for (uint32_t a = 0; a < valid_count; a++) {
                                    const char *str_val = NULL;
                                    if (style_entries[a].value_type == RES_VALUE_TYPE_STRING &&
                                        style_entries[a].value_data < res->string_count && res->strings) {
                                        str_val = res->strings[style_entries[a].value_data];
                                    }
                                    if (!str_val) str_val = "";

                                    switch (style_entries[a].attr_id) {
                                        case PLURAL_KEY_ZERO:  pl.zero  = dx_strdup(str_val); break;
                                        case PLURAL_KEY_ONE:   pl.one   = dx_strdup(str_val); break;
                                        case PLURAL_KEY_TWO:   pl.two   = dx_strdup(str_val); break;
                                        case PLURAL_KEY_FEW:   pl.few   = dx_strdup(str_val); break;
                                        case PLURAL_KEY_MANY:  pl.many  = dx_strdup(str_val); break;
                                        case PLURAL_KEY_OTHER: pl.other = dx_strdup(str_val); break;
                                        default: break;
                                    }
                                }

                                add_plural_resource(res, &pl);
                                DX_TRACE(TAG, "Plural 0x%08x (%s): parsed",
                                         res_id, key_name ? key_name : "?");
                            }

                            // Store as style record too (for styles/themes)
                            if (style_entries && valid_count > 0) {
                                add_style_record(res, res_id, parent_ref,
                                                 style_entries, valid_count);
                                DX_TRACE(TAG, "Style 0x%08x (%s): parent=0x%08x, %u attrs",
                                         res_id, key_name ? key_name : "?",
                                         parent_ref, valid_count);
                            } else {
                                dx_free(style_entries);
                            }

                            // Also add a general entry so find_by_id/find_by_name work
                            DxResourceEntry re;
                            memset(&re, 0, sizeof(re));
                            re.id = res_id;
                            re.value_type = RES_VALUE_TYPE_NULL;
                            re.entry_name = key_name ? dx_strdup(key_name) : NULL;
                            re.type_name = dx_strdup(type_name_str);
                            re.config = type_config;
                            add_resource_entry(res, &re);

                            continue; // skip simple-value path
                        }

                        // --- Simple (non-bag) entry ---
                        if (entry_pos + entry_size + 8 > size) continue;

                        // Value is at entry_pos + 8 (after ResTable_entry header)
                        uint32_t val_pos = entry_pos + 8;
                        if (val_pos + 8 > size) continue;

                        uint8_t val_type = data[val_pos + 3];
                        uint32_t val_data = read_u32(data + val_pos + 4);

                        // --- Populate the general resource entry table ---
                        DxResourceEntry re;
                        memset(&re, 0, sizeof(re));
                        re.id = res_id;
                        re.value_type = val_type;
                        re.entry_name = key_name ? dx_strdup(key_name) : NULL;
                        re.type_name = dx_strdup(type_name_str);
                        re.config = type_config;

                        switch (val_type) {
                            case RES_VALUE_TYPE_STRING:
                                if (val_data < res->string_count && res->strings) {
                                    re.str_val = dx_strdup(res->strings[val_data]);
                                } else {
                                    re.str_val = dx_strdup("");
                                }
                                break;

                            case RES_VALUE_TYPE_INT_DEC:
                            case RES_VALUE_TYPE_INT_HEX:
                                re.int_val = (int32_t)val_data;
                                break;

                            case RES_VALUE_TYPE_INT_BOOL:
                                re.bool_val = (val_data != 0);
                                break;

                            case RES_VALUE_TYPE_FLOAT:
                                re.float_val = decode_float(val_data);
                                break;

                            case RES_VALUE_TYPE_DIMENSION: {
                                uint8_t unit = 0;
                                float dim_val = dx_resources_decode_dimen(val_data, &unit);
                                re.dimen.value = dim_val;
                                re.dimen.unit = unit;
                                break;
                            }

                            case RES_VALUE_TYPE_INT_COLOR_ARGB8:
                            case RES_VALUE_TYPE_INT_COLOR_RGB8:
                            case RES_VALUE_TYPE_INT_COLOR_ARGB4:
                            case RES_VALUE_TYPE_INT_COLOR_RGB4:
                                re.color_val = normalize_color(val_type, val_data);
                                break;

                            case RES_VALUE_TYPE_REF:
                                re.ref_id = val_data;
                                break;

                            default:
                                // Store raw int value for unknown types
                                re.int_val = (int32_t)val_data;
                                break;
                        }

                        add_resource_entry(res, &re);

                        // --- Also populate legacy string_entries / layout_entries ---
                        if (is_string_type && val_type == RES_VALUE_TYPE_STRING) {
                            // String resource - val_data is index into global string pool
                            uint32_t idx = res->string_entry_count++;
                            res->string_entries = (typeof(res->string_entries))dx_realloc(
                                res->string_entries,
                                sizeof(*res->string_entries) * res->string_entry_count);
                            if (res->string_entries) {
                                res->string_entries[idx].id = res_id;
                                if (val_data < res->string_count && res->strings) {
                                    res->string_entries[idx].value = dx_strdup(res->strings[val_data]);
                                } else {
                                    res->string_entries[idx].value = dx_strdup("");
                                }
                                DX_TRACE(TAG, "String 0x%08x (%s) = \"%s\"",
                                         res_id, key_name ? key_name : "?",
                                         res->string_entries[idx].value);
                            }
                        } else if (is_layout_type && val_type == RES_VALUE_TYPE_STRING) {
                            // Layout resource - val_data is index into global string pool
                            // Validate the filename looks like a path (contains '/' or '.xml')
                            const char *fn = NULL;
                            if (val_data < res->string_count && res->strings) {
                                fn = res->strings[val_data];
                            }
                            if (fn && (strchr(fn, '/') != NULL || strstr(fn, ".xml") != NULL)) {
                                uint32_t idx = res->layout_entry_count++;
                                res->layout_entries = (typeof(res->layout_entries))dx_realloc(
                                    res->layout_entries,
                                    sizeof(*res->layout_entries) * res->layout_entry_count);
                                if (res->layout_entries) {
                                    res->layout_entries[idx].id = res_id;
                                    res->layout_entries[idx].filename = dx_strdup(fn);
                                    DX_DEBUG(TAG, "Layout 0x%08x = %s",
                                             res_id, res->layout_entries[idx].filename);
                                }
                            }
                        }
                    }
                }

                sub_pos += sub_size;
            }

            // Free local string pools
            if (key_strings) {
                for (uint32_t i = 0; i < key_count; i++) dx_free(key_strings[i]);
                dx_free(key_strings);
            }
            if (type_strings) {
                for (uint32_t i = 0; i < type_str_count; i++) dx_free(type_strings[i]);
                dx_free(type_strings);
            }
        }

        pos += chunk_size;
    }

    DX_INFO(TAG, "Resources parsed: %u strings, %u string entries, %u layout entries, %u total entries, %u styles, %u arrays, %u plurals",
            res->string_count, res->string_entry_count, res->layout_entry_count, res->entry_count,
            res->style_count, res->array_count, res->plural_count);
    *out = res;
    return DX_OK;

fail:
    dx_resources_free(res);
    return DX_ERR_INVALID_FORMAT;
}

void dx_resources_free(DxResources *res) {
    if (!res) return;
    for (uint32_t i = 0; i < res->string_count; i++) {
        dx_free(res->strings[i]);
    }
    dx_free(res->strings);
    for (uint32_t i = 0; i < res->string_entry_count; i++) {
        dx_free(res->string_entries[i].value);
    }
    dx_free(res->string_entries);
    for (uint32_t i = 0; i < res->layout_entry_count; i++) {
        dx_free(res->layout_entries[i].filename);
    }
    dx_free(res->layout_entries);

    // Free style records
    for (uint32_t i = 0; i < res->style_count; i++) {
        dx_free(res->styles[i].entries);
    }
    dx_free(res->styles);

    // Free array resources
    for (uint32_t i = 0; i < res->array_count; i++) {
        DxArrayResource *a = &res->arrays[i];
        if (a->string_values) {
            for (uint32_t j = 0; j < a->count; j++) {
                dx_free(a->string_values[j]);
            }
            dx_free(a->string_values);
        }
        dx_free(a->int_values);
    }
    dx_free(res->arrays);

    // Free plural resources
    for (uint32_t i = 0; i < res->plural_count; i++) {
        DxPluralResource *p = &res->plurals[i];
        dx_free(p->zero);
        dx_free(p->one);
        dx_free(p->two);
        dx_free(p->few);
        dx_free(p->many);
        dx_free(p->other);
    }
    dx_free(res->plurals);

    // Clear resource cache (no heap allocations in cache, just zero it)
    memset(&res->cache, 0, sizeof(res->cache));

    // Free general entry table
    for (uint32_t i = 0; i < res->entry_count; i++) {
        DxResourceEntry *e = &res->entries[i];
        dx_free(e->entry_name);
        dx_free(e->type_name);
        // Free string values
        if (e->value_type == RES_VALUE_TYPE_STRING) {
            dx_free(e->str_val);
        }
    }
    dx_free(res->entries);

    dx_free(res);
}

const char *dx_resources_get_string(const DxResources *res, uint32_t id) {
    if (!res) return NULL;
    // Search indexed entries first (proper resource ID -> value mapping)
    for (uint32_t i = 0; i < res->string_entry_count; i++) {
        if (res->string_entries[i].id == id) {
            return res->string_entries[i].value;
        }
    }
    // Fallback: use entry index into global string pool
    uint32_t entry = id & 0xFFFF;
    if (entry < res->string_count) {
        return res->strings[entry];
    }
    return NULL;
}

const char *dx_resources_get_layout_filename(const DxResources *res, uint32_t id) {
    if (!res) return NULL;
    for (uint32_t i = 0; i < res->layout_entry_count; i++) {
        if (res->layout_entries[i].id == id) {
            return res->layout_entries[i].filename;
        }
    }
    return NULL;
}

// ── Resource cache helpers ──

// Hash a resource ID into a cache slot index
static uint32_t res_cache_hash(uint32_t id) {
    // Simple multiplicative hash
    return (id * 2654435761u) % DX_RES_CACHE_SIZE;
}

// Look up a resource ID in the cache. Returns the cached entry or NULL.
static const DxResourceEntry *res_cache_lookup(const DxResCache *cache, uint32_t id) {
    if (id == 0) return NULL;
    uint32_t slot = res_cache_hash(id);
    // Linear probe
    for (uint32_t i = 0; i < DX_RES_CACHE_SIZE; i++) {
        uint32_t idx = (slot + i) & (DX_RES_CACHE_SIZE - 1);
        if (cache->entries[idx].resource_id == id) {
            return cache->entries[idx].entry;
        }
        if (cache->entries[idx].resource_id == 0) {
            return NULL; // empty slot = not found
        }
    }
    return NULL;
}

// Insert a resolved entry into the cache. Uses FIFO eviction when full.
static void res_cache_insert(DxResCache *cache, uint32_t id, const DxResourceEntry *entry) {
    if (id == 0 || !entry) return;

    // If cache is full, evict the oldest entry (lowest insert_order)
    if (cache->count >= DX_RES_CACHE_SIZE) {
        uint32_t oldest_order = UINT32_MAX;
        uint32_t oldest_slot = 0;
        for (uint32_t i = 0; i < DX_RES_CACHE_SIZE; i++) {
            if (cache->entries[i].resource_id != 0 &&
                cache->entries[i].insert_order < oldest_order) {
                oldest_order = cache->entries[i].insert_order;
                oldest_slot = i;
            }
        }
        cache->entries[oldest_slot].resource_id = 0;
        cache->entries[oldest_slot].entry = NULL;
        cache->count--;
    }

    // Find a free slot using linear probing from the hash position
    uint32_t slot = res_cache_hash(id);
    for (uint32_t i = 0; i < DX_RES_CACHE_SIZE; i++) {
        uint32_t idx = (slot + i) & (DX_RES_CACHE_SIZE - 1);
        if (cache->entries[idx].resource_id == 0 ||
            cache->entries[idx].resource_id == id) {
            cache->entries[idx].resource_id = id;
            cache->entries[idx].entry = entry;
            cache->entries[idx].insert_order = cache->next_order++;
            if (cache->entries[idx].resource_id != id) {
                cache->count++;
            }
            return;
        }
    }
}

const DxResourceEntry *dx_resources_find_by_id(const DxResources *res, uint32_t id) {
    if (!res) return NULL;

    // Check cache first
    const DxResourceEntry *cached = res_cache_lookup(&res->cache, id);
    if (cached) return cached;

    for (uint32_t i = 0; i < res->entry_count; i++) {
        if (res->entries[i].id == id) {
            // Cache the result (cast away const for cache mutation)
            res_cache_insert(&((DxResources *)res)->cache, id, &res->entries[i]);
            return &res->entries[i];
        }
    }
    return NULL;
}

const DxResourceEntry *dx_resources_find_by_id_q(const DxResources *res, uint32_t id,
                                                   const DxDeviceConfig *dev) {
    if (!res) return NULL;
    if (!dev) return dx_resources_find_by_id(res, id); // fallback to first match

    // Check cache first (qualifier-aware lookups are the expensive ones)
    const DxResourceEntry *cached = res_cache_lookup(&res->cache, id);
    if (cached) return cached;

    const DxResourceEntry *best = pick_best_entry(res, id, dev);
    if (best) {
        res_cache_insert(&((DxResources *)res)->cache, id, best);
    }
    return best;
}

const char *dx_resources_find_string(const DxResources *res, uint32_t id,
                                      const DxDeviceConfig *dev) {
    if (!res) return NULL;
    if (!dev) return dx_resources_get_string_by_id(res, id);

    const DxResourceEntry *best = pick_best_entry(res, id, dev);
    if (best && best->value_type == RES_VALUE_TYPE_STRING) {
        return best->str_val;
    }
    // Fallback: try legacy string entries (no config info on those)
    return dx_resources_get_string(res, id);
}

const char *dx_resources_get_string_by_id(const DxResources *res, uint32_t id) {
    if (!res) return NULL;

    // Check legacy string entries first (faster, string-type only)
    const char *s = dx_resources_get_string(res, id);
    if (s) return s;

    // Fall back to general table
    const DxResourceEntry *e = dx_resources_find_by_id(res, id);
    if (e && e->value_type == RES_VALUE_TYPE_STRING) {
        return e->str_val;
    }
    return NULL;
}

const DxResourceEntry *dx_resources_find_by_name(const DxResources *res,
                                                   const char *type_name,
                                                   const char *entry_name) {
    if (!res || !entry_name) return NULL;
    for (uint32_t i = 0; i < res->entry_count; i++) {
        const DxResourceEntry *e = &res->entries[i];
        if (!e->entry_name) continue;
        if (strcmp(e->entry_name, entry_name) != 0) continue;
        if (type_name && e->type_name && strcmp(e->type_name, type_name) != 0) continue;
        return e;
    }
    return NULL;
}

char *dx_resources_format_dimen(float value, uint8_t unit) {
    const char *suffix;
    switch (unit) {
        case DX_DIMEN_UNIT_PX:  suffix = "px"; break;
        case DX_DIMEN_UNIT_DIP: suffix = "dp"; break;
        case DX_DIMEN_UNIT_SP:  suffix = "sp"; break;
        case DX_DIMEN_UNIT_PT:  suffix = "pt"; break;
        case DX_DIMEN_UNIT_IN:  suffix = "in"; break;
        case DX_DIMEN_UNIT_MM:  suffix = "mm"; break;
        default:                suffix = "??"; break;
    }
    char buf[64];
    snprintf(buf, sizeof(buf), "%.1f%s", value, suffix);
    return dx_strdup(buf);
}

char *dx_resources_format_color(uint32_t argb) {
    char buf[16];
    snprintf(buf, sizeof(buf), "#%08X", argb);
    return dx_strdup(buf);
}

// ============================================================
// Array resource lookup
// ============================================================

const DxArrayResource *dx_resources_find_array(const DxResources *res, uint32_t res_id) {
    if (!res) return NULL;
    for (uint32_t i = 0; i < res->array_count; i++) {
        if (res->arrays[i].res_id == res_id) {
            return &res->arrays[i];
        }
    }
    return NULL;
}

const char **dx_resources_get_string_array(const DxResources *res, uint32_t res_id, uint32_t *out_count) {
    if (out_count) *out_count = 0;
    const DxArrayResource *arr = dx_resources_find_array(res, res_id);
    if (!arr || !arr->is_string_array || !arr->string_values) return NULL;
    if (out_count) *out_count = arr->count;
    return (const char **)arr->string_values;
}

const int32_t *dx_resources_get_integer_array(const DxResources *res, uint32_t res_id, uint32_t *out_count) {
    if (out_count) *out_count = 0;
    const DxArrayResource *arr = dx_resources_find_array(res, res_id);
    if (!arr || arr->is_string_array || !arr->int_values) return NULL;
    if (out_count) *out_count = arr->count;
    return arr->int_values;
}

// ============================================================
// Plural resource lookup
// ============================================================

const char *dx_resources_get_plural(const DxResources *res, uint32_t res_id, int quantity) {
    if (!res) return NULL;

    const DxPluralResource *pl = NULL;
    for (uint32_t i = 0; i < res->plural_count; i++) {
        if (res->plurals[i].res_id == res_id) {
            pl = &res->plurals[i];
            break;
        }
    }
    if (!pl) return NULL;

    // CLDR English quantity rules: 1 = "one", everything else = "other"
    // Also check explicit zero, two, few, many forms
    const char *result = NULL;
    if (quantity == 0 && pl->zero) {
        result = pl->zero;
    } else if (quantity == 1 && pl->one) {
        result = pl->one;
    } else if (quantity == 2 && pl->two) {
        result = pl->two;
    }

    // Fallback to "other" if no specific form matched
    if (!result && pl->other) {
        result = pl->other;
    }
    // Last resort: try "many" or "few"
    if (!result) result = pl->many;
    if (!result) result = pl->few;
    if (!result) result = pl->one;

    return result;
}

// ============================================================
// Style resolution
// ============================================================

DxStyleBag *dx_resources_resolve_style(const DxResources *res, uint32_t style_res_id) {
    if (!res || style_res_id == 0) return NULL;

    // Collect all entries from child -> parent chain.
    // Child entries override parent entries for the same attr_id.
    // We use a simple flat array and linear dedup.

    // Temporary buffer: accumulate all entries
    uint32_t tmp_cap = 128;
    uint32_t tmp_count = 0;
    DxStyleEntry *tmp = (DxStyleEntry *)dx_malloc(sizeof(DxStyleEntry) * tmp_cap);
    if (!tmp) return NULL;

    uint32_t current_id = style_res_id;
    uint32_t depth = 0;
    uint32_t first_parent = 0;

    // Track visited style IDs for circular reference detection
    uint32_t visited[MAX_STYLE_PARENT_DEPTH];
    uint32_t visited_count = 0;

    while (current_id != 0 && depth < MAX_STYLE_PARENT_DEPTH) {
        // Check for circular reference
        for (uint32_t v = 0; v < visited_count; v++) {
            if (visited[v] == current_id) {
                DX_WARN(TAG, "Circular style reference detected at 0x%08x", current_id);
                goto done_chain;
            }
        }
        visited[visited_count++] = current_id;

        const DxStyleRecord *rec = find_style_record(res, current_id);
        if (!rec) break;

        if (depth == 0) {
            first_parent = rec->parent_id;
        }

        // Add entries that don't already exist (child takes priority)
        for (uint32_t i = 0; i < rec->entry_count; i++) {
            uint32_t aid = rec->entries[i].attr_id;
            // Check if already present from a more-derived style
            bool exists = false;
            for (uint32_t j = 0; j < tmp_count; j++) {
                if (tmp[j].attr_id == aid) { exists = true; break; }
            }
            if (exists) continue;

            // Grow if needed
            if (tmp_count >= tmp_cap) {
                tmp_cap *= 2;
                DxStyleEntry *new_tmp = (DxStyleEntry *)dx_realloc(tmp, sizeof(DxStyleEntry) * tmp_cap);
                if (!new_tmp) break;
                tmp = new_tmp;
            }
            tmp[tmp_count++] = rec->entries[i];
        }

        current_id = rec->parent_id;
        depth++;
    }
    done_chain:

    if (tmp_count == 0) {
        dx_free(tmp);
        return NULL;
    }

    DxStyleBag *bag = (DxStyleBag *)dx_malloc(sizeof(DxStyleBag));
    if (!bag) { dx_free(tmp); return NULL; }

    // Copy to exact-size array
    bag->entries = (DxStyleEntry *)dx_malloc(sizeof(DxStyleEntry) * tmp_count);
    if (!bag->entries) { dx_free(bag); dx_free(tmp); return NULL; }
    memcpy(bag->entries, tmp, sizeof(DxStyleEntry) * tmp_count);
    bag->entry_count = tmp_count;
    bag->parent_id = first_parent;
    dx_free(tmp);

    DX_DEBUG(TAG, "Resolved style 0x%08x: %u attrs (depth %u)",
             style_res_id, tmp_count, depth);
    return bag;
}

void dx_style_bag_free(DxStyleBag *bag) {
    if (!bag) return;
    dx_free(bag->entries);
    dx_free(bag);
}

const DxStyleEntry *dx_style_bag_find_attr(const DxStyleBag *bag, uint32_t attr_id) {
    if (!bag) return NULL;
    for (uint32_t i = 0; i < bag->entry_count; i++) {
        if (bag->entries[i].attr_id == attr_id) {
            return &bag->entries[i];
        }
    }
    return NULL;
}

// ============================================================
// Theme
// ============================================================

DxTheme *dx_theme_create(const DxResources *res, uint32_t theme_res_id) {
    if (!res || theme_res_id == 0) return NULL;

    DxStyleBag *bag = dx_resources_resolve_style(res, theme_res_id);
    if (!bag) {
        DX_WARN(TAG, "Could not resolve theme style 0x%08x", theme_res_id);
        return NULL;
    }

    DxTheme *theme = (DxTheme *)dx_malloc(sizeof(DxTheme));
    if (!theme) { dx_style_bag_free(bag); return NULL; }

    theme->theme_res_id = theme_res_id;
    theme->bag = bag;

    DX_INFO(TAG, "Theme created: 0x%08x with %u attributes", theme_res_id, bag->entry_count);
    return theme;
}

void dx_theme_free(DxTheme *theme) {
    if (!theme) return;
    dx_style_bag_free(theme->bag);
    dx_free(theme);
}

const DxStyleEntry *dx_theme_resolve_attr(const DxTheme *theme, uint32_t attr_id) {
    if (!theme || !theme->bag) return NULL;
    return dx_style_bag_find_attr(theme->bag, attr_id);
}

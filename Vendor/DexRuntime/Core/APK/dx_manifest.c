#include "../Include/dx_manifest.h"
#include "../Include/dx_log.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define TAG "Manifest"

#include "../Include/dx_memory.h"

// Append a string to a dynamic array
static void append_string(char ***array, uint32_t *count, const char *str) {
    uint32_t n = *count;
    char **new_arr = (char **)dx_realloc(*array, sizeof(char *) * (n + 1));
    if (!new_arr) return;
    new_arr[n] = dx_strdup(str);
    *array = new_arr;
    *count = n + 1;
}

// Android Binary XML chunk types
#define AXML_CHUNK_STRINGPOOL  0x0001
#define AXML_CHUNK_RESOURCEMAP 0x0180
#define AXML_CHUNK_START_NS    0x0100
#define AXML_CHUNK_END_NS      0x0101
#define AXML_CHUNK_START_TAG   0x0102
#define AXML_CHUNK_END_TAG     0x0103
#define AXML_CHUNK_TEXT        0x0104
#define AXML_FILE_MAGIC        0x00080003
#define AXML_MAX_DEPTH         100    // Maximum XML nesting depth
#define AXML_MAX_STRING_POOL   1000000 // Maximum string pool entries (1M)
#define DX_MAX_AXML_SIZE       (50u * 1024u * 1024u)  // 50 MB limit for AXML data

// Well-known Android resource IDs
#define ATTR_NAME       0x01010003
#define ATTR_LABEL      0x01010001
#define ATTR_THEME      0x01010000
#define ATTR_VALUE      0x01010024
#define ATTR_EXPORTED   0x01010010
#define ATTR_MIN_SDK    0x0101020c
#define ATTR_TARGET_SDK 0x01010270
#define ATTR_REQUIRED   0x0101028e
#define ATTR_SCHEME     0x01010027
#define ATTR_HOST       0x01010028
#define ATTR_PATH       0x0101002a
#define ATTR_PATH_PREFIX 0x01010098
#define ATTR_PATH_PATTERN 0x0101002c
#define ATTR_MIME_TYPE  0x01010026
#define ATTR_RESOURCE   0x01010025
#define ATTR_TARGET_PKG 0x01010021

// Attribute value types
#define ATTR_TYPE_STRING    0x03
#define ATTR_TYPE_INT_DEC   0x10
#define ATTR_TYPE_INT_HEX   0x11
#define ATTR_TYPE_INT_BOOL  0x12
#define ATTR_TYPE_REFERENCE 0x01

static uint16_t read_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t read_u32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

// Decode a string from AXML string pool
static char *decode_axml_string(const uint8_t *pool_data, uint32_t pool_size,
                                 uint32_t offset, bool is_utf8) {
    if (offset >= pool_size) return dx_strdup("");

    const uint8_t *p = pool_data + offset;

    if (is_utf8) {
        uint32_t char_count = *p++;
        if (char_count > 0x7F) {
            char_count = ((char_count & 0x7F) << 8) | *p++;
        }
        uint32_t byte_count = *p++;
        if (byte_count > 0x7F) {
            byte_count = ((byte_count & 0x7F) << 8) | *p++;
        }
        // Cap individual string length at 1MB to prevent absurd allocations
        if (byte_count > 1048576) {
            DX_WARN(TAG, "AXML string too large: %u bytes (max 1MB), truncating", byte_count);
            byte_count = 1048576;
        }
        char *s = (char *)dx_malloc(byte_count + 1);
        if (!s) return NULL;
        memcpy(s, p, byte_count);
        s[byte_count] = '\0';
        return s;
    } else {
        uint32_t char_count = read_u16(p);
        p += 2;
        if (char_count >= 0x8000) {
            char_count = ((char_count & 0x7FFF) << 16) | read_u16(p);
            p += 2;
        }
        // Cap individual string length at 1MB to prevent absurd allocations
        if (char_count > 349525) {  // 349525 * 3 + 1 ~ 1MB
            DX_WARN(TAG, "AXML UTF-16 string too large: %u chars (max ~349K), truncating", char_count);
            char_count = 349525;
        }
        // Worst case: each UTF-16 code unit -> 3 bytes UTF-8, surrogate pair -> 4 bytes
        char *s = (char *)dx_malloc(char_count * 3 + 1);
        if (!s) return NULL;
        uint32_t out_pos = 0;
        for (uint32_t i = 0; i < char_count; i++) {
            uint16_t c = read_u16(p + i * 2);
            if (c < 0x80) {
                s[out_pos++] = (char)c;
            } else if (c < 0x800) {
                s[out_pos++] = (char)(0xC0 | (c >> 6));
                s[out_pos++] = (char)(0x80 | (c & 0x3F));
            } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < char_count) {
                // High surrogate - check for low surrogate
                uint16_t lo = read_u16(p + (i + 1) * 2);
                if (lo >= 0xDC00 && lo <= 0xDFFF) {
                    uint32_t cp = 0x10000 + ((uint32_t)(c - 0xD800) << 10) + (lo - 0xDC00);
                    s[out_pos++] = (char)(0xF0 | (cp >> 18));
                    s[out_pos++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                    s[out_pos++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                    s[out_pos++] = (char)(0x80 | (cp & 0x3F));
                    i++; // skip low surrogate
                } else {
                    // Lone high surrogate - emit replacement char U+FFFD
                    s[out_pos++] = (char)0xEF;
                    s[out_pos++] = (char)0xBF;
                    s[out_pos++] = (char)0xBD;
                }
            } else if (c >= 0xDC00 && c <= 0xDFFF) {
                // Lone low surrogate - emit replacement char U+FFFD
                s[out_pos++] = (char)0xEF;
                s[out_pos++] = (char)0xBF;
                s[out_pos++] = (char)0xBD;
            } else {
                s[out_pos++] = (char)(0xE0 | (c >> 12));
                s[out_pos++] = (char)(0x80 | ((c >> 6) & 0x3F));
                s[out_pos++] = (char)(0x80 | (c & 0x3F));
            }
        }
        s[out_pos] = '\0';
        return s;
    }
}

DxResult dx_axml_parse(const uint8_t *data, uint32_t size, DxAxmlParser **out) {
    if (!data || !out) return DX_ERR_NULL_PTR;
    if (size < 8) return DX_ERR_AXML_INVALID;
    if (size > DX_MAX_AXML_SIZE) {
        DX_ERROR(TAG, "AXML data too large: %u bytes (limit %u)", size, DX_MAX_AXML_SIZE);
        return DX_ERR_AXML_INVALID;
    }

    uint32_t magic = read_u32(data);
    if (magic != AXML_FILE_MAGIC) {
        DX_ERROR(TAG, "Invalid AXML magic: 0x%08x (expected 0x%08x)", magic, AXML_FILE_MAGIC);
        return DX_ERR_AXML_INVALID;
    }

    DxAxmlParser *parser = (DxAxmlParser *)dx_malloc(sizeof(DxAxmlParser));
    if (!parser) return DX_ERR_OUT_OF_MEMORY;
    memset(parser, 0, sizeof(DxAxmlParser));

    // Parse string pool (always first chunk after header)
    uint32_t pos = 8;
    if (pos + 28 > size) goto fail;  // need at least 28 bytes for string pool header

    uint16_t chunk_type = read_u16(data + pos);
    uint32_t chunk_size = read_u32(data + pos + 4);

    if (chunk_type != AXML_CHUNK_STRINGPOOL) {
        DX_ERROR(TAG, "Expected string pool chunk, got 0x%04x", chunk_type);
        goto fail;
    }

    if (chunk_size < 28 || pos + chunk_size > size) {
        DX_ERROR(TAG, "String pool chunk size invalid: %u", chunk_size);
        goto fail;
    }

    uint32_t string_count = read_u32(data + pos + 8);
    uint32_t flags = read_u32(data + pos + 16);
    uint32_t strings_start = read_u32(data + pos + 20);
    bool is_utf8 = (flags & (1 << 8)) != 0;

    // Limit string pool size to prevent excessive allocations
    if (string_count > AXML_MAX_STRING_POOL) {
        DX_ERROR(TAG, "AXML string pool too large: %u entries (max %u)",
                 string_count, AXML_MAX_STRING_POOL);
        goto fail;
    }

    parser->string_count = string_count;
    parser->strings = (char **)dx_malloc(sizeof(char *) * string_count);
    if (!parser->strings) goto fail;

    uint32_t offsets_start = pos + 28;
    uint32_t pool_data_start = pos + strings_start;

    // Validate pool_data_start doesn't exceed file bounds
    if (strings_start < 28 || pool_data_start > size) {
        DX_ERROR(TAG, "AXML strings_start out of bounds: %u (chunk at %u, size %u)",
                 strings_start, pos, size);
        goto fail;
    }

    for (uint32_t i = 0; i < string_count; i++) {
        if (offsets_start + i * 4 + 4 > size) break;
        uint32_t str_offset = read_u32(data + offsets_start + i * 4);
        parser->strings[i] = decode_axml_string(
            data + pool_data_start,
            size - pool_data_start,
            str_offset,
            is_utf8
        );
    }

    // Parse resource ID map if present
    pos += chunk_size;
    if (pos + 8 <= size) {
        chunk_type = read_u16(data + pos);
        chunk_size = read_u32(data + pos + 4);
        if (chunk_type == AXML_CHUNK_RESOURCEMAP && chunk_size >= 8 &&
            pos + chunk_size <= size) {
            uint32_t id_count = (chunk_size - 8) / 4;
            parser->res_id_count = id_count;
            parser->res_ids = (uint32_t *)dx_malloc(sizeof(uint32_t) * id_count);
            if (parser->res_ids) {
                for (uint32_t i = 0; i < id_count; i++) {
                    uint32_t id_off = pos + 8 + i * 4;
                    if (id_off + 4 > size) break;
                    parser->res_ids[i] = read_u32(data + id_off);
                }
            }
        }
    }

    DX_INFO(TAG, "AXML parsed: %u strings", parser->string_count);
    *out = parser;
    return DX_OK;

fail:
    dx_axml_free(parser);
    return DX_ERR_AXML_INVALID;
}

void dx_axml_free(DxAxmlParser *parser) {
    if (!parser) return;
    for (uint32_t i = 0; i < parser->string_count; i++) {
        dx_free(parser->strings[i]);
    }
    dx_free(parser->strings);
    dx_free(parser->res_ids);
    // Free namespace bindings
    for (uint32_t i = 0; i < parser->ns_count; i++) {
        dx_free(parser->ns_prefixes[i]);
        dx_free(parser->ns_uris[i]);
    }
    dx_free(parser->ns_prefixes);
    dx_free(parser->ns_uris);
    dx_free(parser);
}

// ---- Namespace tracking helpers ----
static void axml_push_namespace(DxAxmlParser *axml, const char *prefix, const char *uri) {
    if (axml->ns_count >= axml->ns_capacity) {
        uint32_t new_cap = axml->ns_capacity == 0 ? 8 : axml->ns_capacity * 2;
        char **new_prefixes = (char **)dx_realloc(axml->ns_prefixes, sizeof(char *) * new_cap);
        char **new_uris = (char **)dx_realloc(axml->ns_uris, sizeof(char *) * new_cap);
        if (!new_prefixes || !new_uris) {
            dx_free(new_prefixes);
            dx_free(new_uris);
            return;
        }
        axml->ns_prefixes = new_prefixes;
        axml->ns_uris = new_uris;
        axml->ns_capacity = new_cap;
    }
    axml->ns_prefixes[axml->ns_count] = dx_strdup(prefix ? prefix : "");
    axml->ns_uris[axml->ns_count] = dx_strdup(uri ? uri : "");
    axml->ns_count++;
}

static void axml_pop_namespace(DxAxmlParser *axml, const char *prefix) {
    // Remove the most recent binding for this prefix (stack-like)
    for (int i = (int)axml->ns_count - 1; i >= 0; i--) {
        if (strcmp(axml->ns_prefixes[i], prefix ? prefix : "") == 0) {
            dx_free(axml->ns_prefixes[i]);
            dx_free(axml->ns_uris[i]);
            // Shift remaining entries down
            for (uint32_t j = (uint32_t)i; j + 1 < axml->ns_count; j++) {
                axml->ns_prefixes[j] = axml->ns_prefixes[j + 1];
                axml->ns_uris[j] = axml->ns_uris[j + 1];
            }
            axml->ns_count--;
            return;
        }
    }
}

// Resolve a namespace string-pool index to a URI string
static const char *axml_resolve_ns_uri(const DxAxmlParser *axml, uint32_t ns_idx) {
    if (ns_idx == 0xFFFFFFFF || ns_idx >= axml->string_count)
        return NULL;
    return axml->strings[ns_idx];
}

// Well-known namespace URIs
#define NS_ANDROID "http://schemas.android.com/apk/res/android"
#define NS_AUTO    "http://schemas.android.com/apk/res-auto"

// ---- Helper: resolve resource ID from attribute name index ----
static uint32_t resolve_res_id(const DxAxmlParser *axml, uint32_t name_idx) {
    if (axml->res_ids && name_idx < axml->res_id_count)
        return axml->res_ids[name_idx];
    return 0;
}

// ---- Helper: namespace-aware attribute matching ----
// Prefer matching by (namespace_uri, name) pair, then fall back to resource ID, then string name.
static bool attr_is_ns(const DxAxmlParser *axml, uint32_t ns_idx, uint32_t name_idx,
                        const char *expected_ns, uint32_t expected_res_id, const char *fallback_name) {
    // 1. Try namespace + name match
    if (expected_ns && ns_idx != 0xFFFFFFFF && ns_idx < axml->string_count) {
        const char *ns_uri = axml->strings[ns_idx];
        if (strcmp(ns_uri, expected_ns) == 0 &&
            fallback_name && name_idx < axml->string_count &&
            strcmp(axml->strings[name_idx], fallback_name) == 0) {
            return true;
        }
    }

    // 2. Fall back to resource ID matching
    uint32_t rid = resolve_res_id(axml, name_idx);
    if (rid != 0 && rid == expected_res_id) return true;

    // 3. Fall back to name-only matching (for attributes without namespace)
    if (fallback_name && name_idx < axml->string_count &&
        strcmp(axml->strings[name_idx], fallback_name) == 0)
        return true;

    return false;
}

// ---- Legacy helper: check if attribute name matches either by res-id or string name ----
static bool attr_is(const DxAxmlParser *axml, uint32_t name_idx,
                     uint32_t expected_res_id, const char *fallback_name) {
    return attr_is_ns(axml, 0xFFFFFFFF, name_idx, NULL, expected_res_id, fallback_name);
}

// ---- Helper: get string value from attribute data ----
static char *attr_string(const DxAxmlParser *axml, uint32_t attr_type, uint32_t attr_data) {
    if (attr_type == ATTR_TYPE_STRING && attr_data < axml->string_count)
        return dx_strdup(axml->strings[attr_data]);
    return NULL;
}

// ---- Resolve relative class name (prepend package if starts with '.') ----
static char *resolve_class_name(const char *name, const char *package) {
    if (!name) return NULL;
    if (name[0] == '.' && package) {
        size_t pkg_len = strlen(package);
        size_t act_len = strlen(name);
        char *full = (char *)dx_malloc(pkg_len + act_len + 1);
        if (full) {
            memcpy(full, package, pkg_len);
            memcpy(full + pkg_len, name, act_len + 1);
        }
        return full;
    }
    return dx_strdup(name);
}

// ---- Component helpers ----
static DxComponent *append_component(DxComponent **array, uint32_t *count) {
    uint32_t n = *count;
    DxComponent *new_arr = (DxComponent *)dx_realloc(*array, sizeof(DxComponent) * (n + 1));
    if (!new_arr) return NULL;
    memset(&new_arr[n], 0, sizeof(DxComponent));
    *array = new_arr;
    *count = n + 1;
    return &new_arr[n];
}

static void append_intent_filter(DxComponent *comp, DxIntentFilter *filter) {
    uint32_t n = comp->intent_filter_count;
    DxIntentFilter *new_arr = (DxIntentFilter *)dx_realloc(
        comp->intent_filters, sizeof(DxIntentFilter) * (n + 1));
    if (!new_arr) return;
    new_arr[n] = *filter;
    comp->intent_filters = new_arr;
    comp->intent_filter_count = n + 1;
}

static void append_meta_data(DxMetaData **array, uint32_t *count, const char *name, const char *value) {
    uint32_t n = *count;
    DxMetaData *new_arr = (DxMetaData *)dx_realloc(*array, sizeof(DxMetaData) * (n + 1));
    if (!new_arr) return;
    new_arr[n].name = name ? dx_strdup(name) : NULL;
    new_arr[n].value = value ? dx_strdup(value) : NULL;
    *array = new_arr;
    *count = n + 1;
}

static void append_intent_data(DxIntentFilter *filter, DxIntentData *d) {
    uint32_t n = filter->data_count;
    DxIntentData *new_arr = (DxIntentData *)dx_realloc(
        filter->data_entries, sizeof(DxIntentData) * (n + 1));
    if (!new_arr) return;
    new_arr[n] = *d;
    filter->data_entries = new_arr;
    filter->data_count = n + 1;
}

// ---- Component type enum for the parser state machine ----
typedef enum {
    COMP_NONE = 0,
    COMP_ACTIVITY,
    COMP_SERVICE,
    COMP_RECEIVER,
    COMP_PROVIDER,
    COMP_APPLICATION,
} CompType;

DxResult dx_manifest_parse(const uint8_t *data, uint32_t size, DxManifest **out) {
    if (!data || !out) return DX_ERR_NULL_PTR;
    if (size > DX_MAX_AXML_SIZE) {
        DX_ERROR(TAG, "Manifest data too large: %u bytes (limit %u)", size, DX_MAX_AXML_SIZE);
        return DX_ERR_AXML_INVALID;
    }

    DxAxmlParser *axml = NULL;
    DxResult res = dx_axml_parse(data, size, &axml);
    if (res != DX_OK) return res;

    DxManifest *manifest = (DxManifest *)dx_malloc(sizeof(DxManifest));
    if (!manifest) {
        dx_axml_free(axml);
        return DX_ERR_OUT_OF_MEMORY;
    }

    // Walk the XML tree
    uint32_t pos = 8;

    // Skip string pool chunk
    if (pos + 8 <= size) {
        uint32_t chunk_size = read_u32(data + pos + 4);
        pos += chunk_size;
    }
    // Skip resource map chunk if present
    if (pos + 8 <= size && read_u16(data + pos) == AXML_CHUNK_RESOURCEMAP) {
        uint32_t chunk_size = read_u32(data + pos + 4);
        pos += chunk_size;
    }

    // Parser state
    CompType current_comp_type = COMP_NONE;
    DxComponent *current_comp = NULL;
    bool in_intent_filter = false;
    DxIntentFilter current_filter;
    memset(&current_filter, 0, sizeof(current_filter));

    bool found_main = false;
    bool found_launcher = false;
    char *current_activity_name = NULL;

    bool in_application = false;
    uint32_t xml_depth = 0;  // Track XML nesting depth

    while (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        uint32_t chunk_size = read_u32(data + pos + 4);

        if (chunk_size < 8 || pos + chunk_size > size) {
            DX_WARN(TAG, "Malformed AXML chunk at offset %u: size=%u (file size=%u), skipping to next aligned boundary",
                    pos, chunk_size, size);
            // Skip to next 4-byte aligned boundary
            pos += 4;
            pos = (pos + 3) & ~(uint32_t)3;
            continue;
        }

        if (chunk_type == AXML_CHUNK_START_NS) {
            // START_NAMESPACE: prefix(4) + uri(4) at offset +16 and +20
            if (pos + 24 <= size) {
                uint32_t prefix_idx = read_u32(data + pos + 16);
                uint32_t uri_idx = read_u32(data + pos + 20);
                const char *prefix = (prefix_idx < axml->string_count) ? axml->strings[prefix_idx] : "";
                const char *uri = (uri_idx < axml->string_count) ? axml->strings[uri_idx] : "";
                axml_push_namespace(axml, prefix, uri);
                DX_DEBUG(TAG, "NS start: %s -> %s", prefix, uri);
            }
            pos += chunk_size;
            continue;
        } else if (chunk_type == AXML_CHUNK_END_NS) {
            // END_NAMESPACE: prefix(4) at offset +16
            if (pos + 20 <= size) {
                uint32_t prefix_idx = read_u32(data + pos + 16);
                const char *prefix = (prefix_idx < axml->string_count) ? axml->strings[prefix_idx] : "";
                axml_pop_namespace(axml, prefix);
                DX_DEBUG(TAG, "NS end: %s", prefix);
            }
            pos += chunk_size;
            continue;
        } else if (chunk_type == AXML_CHUNK_START_TAG) {
            xml_depth++;
            if (xml_depth > AXML_MAX_DEPTH) {
                DX_ERROR(TAG, "AXML nesting depth exceeds limit (%u), skipping branch", AXML_MAX_DEPTH);
                pos += chunk_size;
                continue;
            }
            if (pos + 28 > size) break;

            uint32_t name_idx = read_u32(data + pos + 20);
            uint16_t attr_count = read_u16(data + pos + 28);

            // Cap attribute count per element to prevent excessive iteration
            if (attr_count > 256) {
                DX_WARN(TAG, "AXML element has %u attributes, capping at 256", attr_count);
                attr_count = 256;
            }

            const char *tag_name;
            if (name_idx < axml->string_count) {
                tag_name = axml->strings[name_idx];
            } else {
                DX_WARN(TAG, "AXML start tag string ref %u out of bounds (pool size %u), substituting <invalid>",
                        name_idx, axml->string_count);
                tag_name = "<invalid>";
            }

            // --- Parse attributes into temp storage ---
            // For each attribute: ns(4) name(4) rawValue(4) typedValue(type:4 data:4) = 20 bytes
            uint32_t attr_start = pos + 36;

            if (strcmp(tag_name, "manifest") == 0) {
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);

                    // "package" attribute has no namespace
                    if (ani < axml->string_count &&
                        strcmp(axml->strings[ani], "package") == 0 &&
                        atype == ATTR_TYPE_STRING &&
                        adata < axml->string_count) {
                        manifest->package_name = dx_strdup(axml->strings[adata]);
                        DX_INFO(TAG, "Package: %s", manifest->package_name);
                    }
                    (void)nsi; // namespace available for future use
                }
            } else if (strcmp(tag_name, "uses-sdk") == 0) {
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_MIN_SDK, "minSdkVersion")) {
                        manifest->min_sdk = (int32_t)adata;
                        DX_INFO(TAG, "minSdkVersion: %d", manifest->min_sdk);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_TARGET_SDK, "targetSdkVersion")) {
                        manifest->target_sdk = (int32_t)adata;
                        DX_INFO(TAG, "targetSdkVersion: %d", manifest->target_sdk);
                    }
                }
            } else if (strcmp(tag_name, "uses-permission") == 0) {
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name") &&
                        atype == ATTR_TYPE_STRING && adata < axml->string_count) {
                        append_string(&manifest->permissions, &manifest->permission_count,
                                      axml->strings[adata]);
                    }
                }
            } else if (strcmp(tag_name, "uses-feature") == 0) {
                // Parse uses-feature
                char *feat_name = NULL;
                bool feat_required = true; // default per Android docs
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name")) {
                        dx_free(feat_name);
                        feat_name = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_REQUIRED, "required")) {
                        if (atype == ATTR_TYPE_INT_BOOL || atype == ATTR_TYPE_INT_DEC)
                            feat_required = (adata != 0);
                    }
                }
                if (feat_name) {
                    uint32_t n = manifest->feature_count;
                    DxUsesFeature *new_arr = (DxUsesFeature *)dx_realloc(
                        manifest->features, sizeof(DxUsesFeature) * (n + 1));
                    if (new_arr) {
                        new_arr[n].name = feat_name;
                        new_arr[n].required = feat_required;
                        manifest->features = new_arr;
                        manifest->feature_count = n + 1;
                        DX_DEBUG(TAG, "uses-feature: %s (required=%d)", feat_name, feat_required);
                    } else {
                        dx_free(feat_name);
                    }
                }
            } else if (strcmp(tag_name, "uses-library") == 0) {
                char *lib_name = NULL;
                bool lib_required = true;
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name")) {
                        dx_free(lib_name);
                        lib_name = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_REQUIRED, "required")) {
                        if (atype == ATTR_TYPE_INT_BOOL || atype == ATTR_TYPE_INT_DEC)
                            lib_required = (adata != 0);
                    }
                }
                if (lib_name) {
                    uint32_t n = manifest->library_count;
                    DxUsesLibrary *new_arr = (DxUsesLibrary *)dx_realloc(
                        manifest->libraries, sizeof(DxUsesLibrary) * (n + 1));
                    if (new_arr) {
                        new_arr[n].name = lib_name;
                        new_arr[n].required = lib_required;
                        manifest->libraries = new_arr;
                        manifest->library_count = n + 1;
                        DX_DEBUG(TAG, "uses-library: %s (required=%d)", lib_name, lib_required);
                    } else {
                        dx_free(lib_name);
                    }
                }
            } else if (strcmp(tag_name, "application") == 0) {
                in_application = true;
                current_comp_type = COMP_APPLICATION;
                // Extract android:label and android:theme
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_LABEL, "label") &&
                        atype == ATTR_TYPE_STRING &&
                        adata < axml->string_count && !manifest->app_label) {
                        manifest->app_label = dx_strdup(axml->strings[adata]);
                        DX_INFO(TAG, "App label: %s", manifest->app_label);
                    }
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_THEME, "theme") &&
                        !manifest->app_theme) {
                        if (atype == ATTR_TYPE_STRING && adata < axml->string_count) {
                            manifest->app_theme = dx_strdup(axml->strings[adata]);
                        } else {
                            char theme_ref[32];
                            snprintf(theme_ref, sizeof(theme_ref), "@0x%08x", adata);
                            manifest->app_theme = dx_strdup(theme_ref);
                        }
                        DX_INFO(TAG, "App theme: %s", manifest->app_theme);
                    }
                }
            } else if (strcmp(tag_name, "activity") == 0 ||
                       strcmp(tag_name, "activity-alias") == 0) {
                // Parse activity component
                char *comp_name = NULL;
                bool exported = false;
                bool exported_set = false;

                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name")) {
                        dx_free(comp_name);
                        comp_name = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_EXPORTED, "exported")) {
                        exported_set = true;
                        if (atype == ATTR_TYPE_INT_BOOL || atype == ATTR_TYPE_INT_DEC)
                            exported = (adata != 0);
                    }
                }

                char *resolved = resolve_class_name(comp_name, manifest->package_name);
                if (resolved) {
                    append_string(&manifest->activities, &manifest->activity_count, resolved);
                }

                current_comp = append_component(&manifest->activity_components,
                                                 &manifest->activity_component_count);
                if (current_comp) {
                    current_comp->name = resolved ? dx_strdup(resolved) : NULL;
                    current_comp->exported = exported;
                    current_comp->exported_set = exported_set;
                }
                current_comp_type = COMP_ACTIVITY;

                // Track for MAIN/LAUNCHER detection
                dx_free(current_activity_name);
                current_activity_name = resolved; // take ownership
                found_main = false;
                found_launcher = false;
                dx_free(comp_name);
            } else if (strcmp(tag_name, "service") == 0) {
                char *comp_name = NULL;
                bool exported = false;
                bool exported_set = false;

                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name")) {
                        dx_free(comp_name);
                        comp_name = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_EXPORTED, "exported")) {
                        exported_set = true;
                        if (atype == ATTR_TYPE_INT_BOOL || atype == ATTR_TYPE_INT_DEC)
                            exported = (adata != 0);
                    }
                }

                char *resolved = resolve_class_name(comp_name, manifest->package_name);
                if (resolved) {
                    append_string(&manifest->services, &manifest->service_count, resolved);
                }

                current_comp = append_component(&manifest->service_components,
                                                 &manifest->service_component_count);
                if (current_comp) {
                    current_comp->name = resolved ? dx_strdup(resolved) : NULL;
                    current_comp->exported = exported;
                    current_comp->exported_set = exported_set;
                }
                current_comp_type = COMP_SERVICE;
                dx_free(resolved);
                dx_free(comp_name);
            } else if (strcmp(tag_name, "receiver") == 0) {
                char *comp_name = NULL;
                bool exported = false;
                bool exported_set = false;

                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name")) {
                        dx_free(comp_name);
                        comp_name = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_EXPORTED, "exported")) {
                        exported_set = true;
                        if (atype == ATTR_TYPE_INT_BOOL || atype == ATTR_TYPE_INT_DEC)
                            exported = (adata != 0);
                    }
                }

                char *resolved = resolve_class_name(comp_name, manifest->package_name);
                if (resolved) {
                    append_string(&manifest->receivers, &manifest->receiver_count, resolved);
                }

                current_comp = append_component(&manifest->receiver_components,
                                                 &manifest->receiver_component_count);
                if (current_comp) {
                    current_comp->name = resolved ? dx_strdup(resolved) : NULL;
                    current_comp->exported = exported;
                    current_comp->exported_set = exported_set;
                }
                current_comp_type = COMP_RECEIVER;
                dx_free(resolved);
                dx_free(comp_name);
            } else if (strcmp(tag_name, "provider") == 0) {
                char *comp_name = NULL;
                bool exported = false;
                bool exported_set = false;

                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name")) {
                        dx_free(comp_name);
                        comp_name = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_EXPORTED, "exported")) {
                        exported_set = true;
                        if (atype == ATTR_TYPE_INT_BOOL || atype == ATTR_TYPE_INT_DEC)
                            exported = (adata != 0);
                    }
                }

                char *resolved = resolve_class_name(comp_name, manifest->package_name);
                if (resolved) {
                    append_string(&manifest->providers, &manifest->provider_count, resolved);
                }

                current_comp = append_component(&manifest->provider_components,
                                                 &manifest->provider_component_count);
                if (current_comp) {
                    current_comp->name = resolved ? dx_strdup(resolved) : NULL;
                    current_comp->exported = exported;
                    current_comp->exported_set = exported_set;
                }
                current_comp_type = COMP_PROVIDER;
                dx_free(resolved);
                dx_free(comp_name);
            } else if (strcmp(tag_name, "instrumentation") == 0) {
                char *inst_name = NULL;
                char *inst_target = NULL;
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);
                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name")) {
                        dx_free(inst_name);
                        inst_name = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_TARGET_PKG, "targetPackage")) {
                        dx_free(inst_target);
                        inst_target = attr_string(axml, atype, adata);
                    }
                }
                if (inst_name) {
                    char *resolved = resolve_class_name(inst_name, manifest->package_name);
                    uint32_t n = manifest->instrumentation_count;
                    DxInstrumentation *new_arr = (DxInstrumentation *)dx_realloc(
                        manifest->instrumentations, sizeof(DxInstrumentation) * (n + 1));
                    if (new_arr) {
                        new_arr[n].name = resolved ? resolved : dx_strdup(inst_name);
                        new_arr[n].target_package = inst_target ? inst_target : NULL;
                        manifest->instrumentations = new_arr;
                        manifest->instrumentation_count = n + 1;
                        DX_INFO(TAG, "Instrumentation: %s -> %s",
                                new_arr[n].name, inst_target ? inst_target : "(none)");
                        inst_target = NULL; // ownership transferred
                        if (resolved != inst_name) {
                            // resolved was a new allocation, inst_name can be freed
                        }
                    } else {
                        dx_free(resolved);
                        dx_free(inst_target);
                    }
                }
                dx_free(inst_name);
                dx_free(inst_target);
            } else if (strcmp(tag_name, "intent-filter") == 0) {
                in_intent_filter = true;
                memset(&current_filter, 0, sizeof(current_filter));
            } else if (strcmp(tag_name, "action") == 0 && in_intent_filter) {
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);

                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name") &&
                        atype == ATTR_TYPE_STRING && adata < axml->string_count) {
                        const char *action = axml->strings[adata];
                        append_string(&current_filter.actions, &current_filter.action_count, action);
                        if (strcmp(action, "android.intent.action.MAIN") == 0)
                            found_main = true;
                    }
                }
            } else if (strcmp(tag_name, "category") == 0 && in_intent_filter) {
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);

                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name") &&
                        atype == ATTR_TYPE_STRING && adata < axml->string_count) {
                        const char *cat = axml->strings[adata];
                        append_string(&current_filter.categories, &current_filter.category_count, cat);
                        if (strcmp(cat, "android.intent.category.LAUNCHER") == 0)
                            found_launcher = true;
                    }
                }
            } else if (strcmp(tag_name, "data") == 0 && in_intent_filter) {
                // Parse <data> element attributes
                DxIntentData d;
                memset(&d, 0, sizeof(d));
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);

                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_SCHEME, "scheme")) {
                        d.scheme = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_HOST, "host")) {
                        d.host = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_PATH, "path")) {
                        d.path = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_PATH_PREFIX, "pathPrefix")) {
                        d.path_prefix = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_PATH_PATTERN, "pathPattern")) {
                        d.path_pattern = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_MIME_TYPE, "mimeType")) {
                        d.mime_type = attr_string(axml, atype, adata);
                    }
                }
                // Only add if at least one field was set
                if (d.scheme || d.host || d.path || d.path_prefix || d.path_pattern || d.mime_type) {
                    append_intent_data(&current_filter, &d);
                } else {
                    // free any partial allocations (all NULL here, but be safe)
                    dx_free(d.scheme); dx_free(d.host); dx_free(d.path);
                    dx_free(d.path_prefix); dx_free(d.path_pattern); dx_free(d.mime_type);
                }
            } else if (strcmp(tag_name, "meta-data") == 0) {
                // Parse <meta-data> android:name and android:value
                char *md_name = NULL;
                char *md_value = NULL;
                for (uint16_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t nsi = read_u32(data + aoff);
                    uint32_t ani = read_u32(data + aoff + 4);
                    uint32_t atype = read_u32(data + aoff + 12) >> 24;
                    uint32_t adata = read_u32(data + aoff + 16);

                    if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_NAME, "name")) {
                        dx_free(md_name);
                        md_name = attr_string(axml, atype, adata);
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_VALUE, "value")) {
                        dx_free(md_value);
                        if (atype == ATTR_TYPE_STRING && adata < axml->string_count) {
                            md_value = dx_strdup(axml->strings[adata]);
                        } else if (atype == ATTR_TYPE_INT_DEC) {
                            char buf[32];
                            snprintf(buf, sizeof(buf), "%d", (int32_t)adata);
                            md_value = dx_strdup(buf);
                        } else if (atype == ATTR_TYPE_INT_HEX || atype == ATTR_TYPE_REFERENCE) {
                            char buf[32];
                            snprintf(buf, sizeof(buf), "@0x%08x", adata);
                            md_value = dx_strdup(buf);
                        } else if (atype == ATTR_TYPE_INT_BOOL) {
                            md_value = dx_strdup(adata ? "true" : "false");
                        }
                    } else if (attr_is_ns(axml, nsi, ani, NS_ANDROID, ATTR_RESOURCE, "resource")) {
                        // android:resource is an alternative to android:value
                        if (!md_value) {
                            char buf[32];
                            snprintf(buf, sizeof(buf), "@0x%08x", adata);
                            md_value = dx_strdup(buf);
                        }
                    }
                }
                if (md_name) {
                    // Attach to current component or application
                    if (current_comp && current_comp_type != COMP_APPLICATION &&
                        current_comp_type != COMP_NONE) {
                        append_meta_data(&current_comp->meta_data, &current_comp->meta_data_count,
                                         md_name, md_value);
                    } else if (in_application) {
                        append_meta_data(&manifest->app_meta_data, &manifest->app_meta_data_count,
                                         md_name, md_value);
                    }
                    DX_DEBUG(TAG, "meta-data: %s = %s", md_name, md_value ? md_value : "(null)");
                }
                dx_free(md_name);
                dx_free(md_value);
            }
        } else if (chunk_type == AXML_CHUNK_END_TAG) {
            if (xml_depth > 0) xml_depth--;
            uint32_t name_idx = read_u32(data + pos + 20);
            const char *tag_name;
            if (name_idx < axml->string_count) {
                tag_name = axml->strings[name_idx];
            } else {
                DX_WARN(TAG, "AXML end tag string ref %u out of bounds (pool size %u), substituting <invalid>",
                        name_idx, axml->string_count);
                tag_name = "<invalid>";
            }

            if (strcmp(tag_name, "intent-filter") == 0) {
                // Check for main/launcher
                if (found_main && found_launcher && current_activity_name &&
                    !manifest->main_activity) {
                    manifest->main_activity = dx_strdup(current_activity_name);
                    DX_INFO(TAG, "Main activity: %s", manifest->main_activity);
                }

                // Store intent filter on current component
                if (current_comp && current_comp_type != COMP_APPLICATION &&
                    current_comp_type != COMP_NONE) {
                    append_intent_filter(current_comp, &current_filter);
                } else {
                    // Free orphan filter data
                    for (uint32_t i = 0; i < current_filter.action_count; i++)
                        dx_free(current_filter.actions[i]);
                    dx_free(current_filter.actions);
                    for (uint32_t i = 0; i < current_filter.category_count; i++)
                        dx_free(current_filter.categories[i]);
                    dx_free(current_filter.categories);
                    for (uint32_t i = 0; i < current_filter.data_count; i++) {
                        dx_free(current_filter.data_entries[i].scheme);
                        dx_free(current_filter.data_entries[i].host);
                        dx_free(current_filter.data_entries[i].path);
                        dx_free(current_filter.data_entries[i].path_prefix);
                        dx_free(current_filter.data_entries[i].path_pattern);
                        dx_free(current_filter.data_entries[i].mime_type);
                    }
                    dx_free(current_filter.data_entries);
                }
                memset(&current_filter, 0, sizeof(current_filter));
                in_intent_filter = false;
            } else if (strcmp(tag_name, "activity") == 0 ||
                       strcmp(tag_name, "activity-alias") == 0) {
                current_comp_type = in_application ? COMP_APPLICATION : COMP_NONE;
                current_comp = NULL;
                found_main = false;
                found_launcher = false;
            } else if (strcmp(tag_name, "service") == 0) {
                current_comp_type = in_application ? COMP_APPLICATION : COMP_NONE;
                current_comp = NULL;
            } else if (strcmp(tag_name, "receiver") == 0) {
                current_comp_type = in_application ? COMP_APPLICATION : COMP_NONE;
                current_comp = NULL;
            } else if (strcmp(tag_name, "provider") == 0) {
                current_comp_type = in_application ? COMP_APPLICATION : COMP_NONE;
                current_comp = NULL;
            } else if (strcmp(tag_name, "instrumentation") == 0) {
                // instrumentation is a leaf-level element, no state to reset
            } else if (strcmp(tag_name, "application") == 0) {
                in_application = false;
                current_comp_type = COMP_NONE;
                current_comp = NULL;
            }
        }

        pos += chunk_size;
    }

    dx_free(current_activity_name);
    dx_axml_free(axml);

    if (!manifest->main_activity) {
        DX_WARN(TAG, "No launcher activity found in manifest");
    }

    DX_INFO(TAG, "Manifest: %u permissions, %u activities, %u services, %u receivers, %u providers",
            manifest->permission_count, manifest->activity_count,
            manifest->service_count, manifest->receiver_count, manifest->provider_count);
    DX_INFO(TAG, "Manifest: %u features, %u libraries, %u app meta-data, %u instrumentations",
            manifest->feature_count, manifest->library_count, manifest->app_meta_data_count,
            manifest->instrumentation_count);

    *out = manifest;
    return DX_OK;
}

// ---- Free helpers ----
static void free_string_array(char **arr, uint32_t count) {
    if (!arr) return;
    for (uint32_t i = 0; i < count; i++) {
        dx_free(arr[i]);
    }
    dx_free(arr);
}

static void free_intent_data(DxIntentData *d) {
    dx_free(d->scheme);
    dx_free(d->host);
    dx_free(d->path);
    dx_free(d->path_prefix);
    dx_free(d->path_pattern);
    dx_free(d->mime_type);
}

static void free_intent_filter(DxIntentFilter *f) {
    free_string_array(f->actions, f->action_count);
    free_string_array(f->categories, f->category_count);
    for (uint32_t i = 0; i < f->data_count; i++)
        free_intent_data(&f->data_entries[i]);
    dx_free(f->data_entries);
}

static void free_meta_data_array(DxMetaData *arr, uint32_t count) {
    if (!arr) return;
    for (uint32_t i = 0; i < count; i++) {
        dx_free(arr[i].name);
        dx_free(arr[i].value);
    }
    dx_free(arr);
}

static void free_component(DxComponent *c) {
    dx_free(c->name);
    for (uint32_t i = 0; i < c->intent_filter_count; i++)
        free_intent_filter(&c->intent_filters[i]);
    dx_free(c->intent_filters);
    free_meta_data_array(c->meta_data, c->meta_data_count);
}

static void free_component_array(DxComponent *arr, uint32_t count) {
    if (!arr) return;
    for (uint32_t i = 0; i < count; i++)
        free_component(&arr[i]);
    dx_free(arr);
}

void dx_manifest_free(DxManifest *manifest) {
    if (!manifest) return;
    dx_free(manifest->package_name);
    dx_free(manifest->main_activity);
    dx_free(manifest->app_label);
    dx_free(manifest->app_theme);
    free_string_array(manifest->permissions, manifest->permission_count);
    free_string_array(manifest->activities, manifest->activity_count);
    free_string_array(manifest->services, manifest->service_count);
    free_string_array(manifest->receivers, manifest->receiver_count);
    free_string_array(manifest->providers, manifest->provider_count);

    free_component_array(manifest->activity_components, manifest->activity_component_count);
    free_component_array(manifest->service_components, manifest->service_component_count);
    free_component_array(manifest->receiver_components, manifest->receiver_component_count);
    free_component_array(manifest->provider_components, manifest->provider_component_count);

    free_meta_data_array(manifest->app_meta_data, manifest->app_meta_data_count);

    for (uint32_t i = 0; i < manifest->feature_count; i++)
        dx_free(manifest->features[i].name);
    dx_free(manifest->features);

    for (uint32_t i = 0; i < manifest->library_count; i++)
        dx_free(manifest->libraries[i].name);
    dx_free(manifest->libraries);

    for (uint32_t i = 0; i < manifest->instrumentation_count; i++) {
        dx_free(manifest->instrumentations[i].name);
        dx_free(manifest->instrumentations[i].target_package);
    }
    dx_free(manifest->instrumentations);

    dx_free(manifest);
}

// ---- Lookup helpers ----
const DxComponent *dx_manifest_find_activity(const DxManifest *m, const char *name) {
    if (!m || !name) return NULL;
    for (uint32_t i = 0; i < m->activity_component_count; i++) {
        if (m->activity_components[i].name &&
            strcmp(m->activity_components[i].name, name) == 0)
            return &m->activity_components[i];
    }
    return NULL;
}

const DxComponent *dx_manifest_find_service(const DxManifest *m, const char *name) {
    if (!m || !name) return NULL;
    for (uint32_t i = 0; i < m->service_component_count; i++) {
        if (m->service_components[i].name &&
            strcmp(m->service_components[i].name, name) == 0)
            return &m->service_components[i];
    }
    return NULL;
}

const DxComponent *dx_manifest_find_receiver(const DxManifest *m, const char *name) {
    if (!m || !name) return NULL;
    for (uint32_t i = 0; i < m->receiver_component_count; i++) {
        if (m->receiver_components[i].name &&
            strcmp(m->receiver_components[i].name, name) == 0)
            return &m->receiver_components[i];
    }
    return NULL;
}

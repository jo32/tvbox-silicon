#include "../Include/dx_fuzz.h"
#include "../Include/dx_apk.h"
#include "../Include/dx_dex.h"
#include "../Include/dx_manifest.h"
#include "../Include/dx_resources.h"
#include "../Include/dx_log.h"

#include <string.h>
#include <stdlib.h>

#define TAG "Fuzz"

// ---------------------------------------------------------------------------
// dx_fuzz_apk — parse a ZIP/APK buffer, iterate entries, extract first 3
// ---------------------------------------------------------------------------
int dx_fuzz_apk(const uint8_t *data, size_t size) {
    if (!data || size == 0) return 0;
    if (size > UINT32_MAX) return 0;  // dx_apk_open takes uint32_t

    DxApkFile *apk = NULL;
    DxResult res = dx_apk_open(data, (uint32_t)size, &apk);
    if (res != DX_OK || !apk) return 0;

    // Iterate entries — touch filenames to exercise string handling
    uint32_t extract_limit = apk->entry_count < 3 ? apk->entry_count : 3;
    for (uint32_t i = 0; i < extract_limit; i++) {
        const DxZipEntry *entry = &apk->entries[i];
        if (!entry->filename) continue;

        // Exercise entry extraction (handles both STORE and DEFLATE)
        uint8_t *out_data = NULL;
        uint32_t out_size = 0;
        DxResult ext = dx_apk_extract_entry(apk, entry, &out_data, &out_size);
        if (ext == DX_OK && out_data) {
            // Touch first byte to ensure data is accessible
            (void)(out_size > 0 ? out_data[0] : 0);
            free(out_data);
        }
    }

    // Also exercise find_entry with a known path
    const DxZipEntry *found = NULL;
    dx_apk_find_entry(apk, "classes.dex", &found);
    dx_apk_find_entry(apk, "AndroidManifest.xml", &found);

    dx_apk_close(apk);
    return 0;
}

// ---------------------------------------------------------------------------
// dx_fuzz_dex — parse a DEX buffer, access strings/types/methods
// ---------------------------------------------------------------------------
int dx_fuzz_dex(const uint8_t *data, size_t size) {
    if (!data || size == 0) return 0;
    if (size > UINT32_MAX) return 0;

    DxDexFile *dex = NULL;
    DxResult res = dx_dex_parse(data, (uint32_t)size, &dex);
    if (res != DX_OK || !dex) return 0;

    // Exercise string table access (first 8 strings, or fewer)
    uint32_t str_limit = dex->string_count < 8 ? dex->string_count : 8;
    for (uint32_t i = 0; i < str_limit; i++) {
        const char *s = dx_dex_get_string(dex, i);
        if (s) (void)strlen(s);  // touch the string
    }

    // Exercise type descriptors
    uint32_t type_limit = dex->type_count < 8 ? dex->type_count : 8;
    for (uint32_t i = 0; i < type_limit; i++) {
        uint32_t desc_idx = dex->type_ids[i].descriptor_idx;
        if (desc_idx < dex->string_count) {
            const char *s = dx_dex_get_string(dex, desc_idx);
            if (s) (void)strlen(s);
        }
    }

    // Exercise method table
    uint32_t meth_limit = dex->method_count < 8 ? dex->method_count : 8;
    for (uint32_t i = 0; i < meth_limit; i++) {
        uint32_t name_idx = dex->method_ids[i].name_idx;
        if (name_idx < dex->string_count) {
            const char *s = dx_dex_get_string(dex, name_idx);
            if (s) (void)strlen(s);
        }
    }

    dx_dex_free(dex);
    return 0;
}

// ---------------------------------------------------------------------------
// dx_fuzz_axml — parse Android Binary XML, access fields
// ---------------------------------------------------------------------------
int dx_fuzz_axml(const uint8_t *data, size_t size) {
    if (!data || size == 0) return 0;
    if (size > UINT32_MAX) return 0;

    // Try as full manifest first
    DxManifest *manifest = NULL;
    DxResult res = dx_manifest_parse(data, (uint32_t)size, &manifest);
    if (res == DX_OK && manifest) {
        // Touch parsed fields
        if (manifest->package_name) (void)strlen(manifest->package_name);
        if (manifest->main_activity) (void)strlen(manifest->main_activity);
        if (manifest->app_label) (void)strlen(manifest->app_label);

        // Touch activity names
        for (uint32_t i = 0; i < manifest->activity_count && i < 8; i++) {
            if (manifest->activities[i]) (void)strlen(manifest->activities[i]);
        }

        // Touch permission names
        for (uint32_t i = 0; i < manifest->permission_count && i < 8; i++) {
            if (manifest->permissions[i]) (void)strlen(manifest->permissions[i]);
        }

        dx_manifest_free(manifest);
    }

    // Also try raw AXML parser
    DxAxmlParser *axml = NULL;
    res = dx_axml_parse(data, (uint32_t)size, &axml);
    if (res == DX_OK && axml) {
        // Touch string pool entries
        uint32_t str_limit = axml->string_count < 16 ? axml->string_count : 16;
        for (uint32_t i = 0; i < str_limit; i++) {
            if (axml->strings[i]) (void)strlen(axml->strings[i]);
        }
        dx_axml_free(axml);
    }

    return 0;
}

// ---------------------------------------------------------------------------
// dx_fuzz_resources — parse resources.arsc, lookup a few IDs
// ---------------------------------------------------------------------------
int dx_fuzz_resources(const uint8_t *data, size_t size) {
    if (!data || size == 0) return 0;
    if (size > UINT32_MAX) return 0;

    DxResources *res = NULL;
    DxResult r = dx_resources_parse(data, (uint32_t)size, &res);
    if (r != DX_OK || !res) return 0;

    // Exercise common lookup patterns with typical Android resource IDs
    // 0x7f0X00YY are typical app resource IDs
    static const uint32_t test_ids[] = {
        0x7f010000, 0x7f020000, 0x7f030000,  // attr, drawable, layout
        0x7f040000, 0x7f050000, 0x7f060000,  // anim, string, style
        0x7f070000, 0x7f080000, 0x7f090000,  // color, dimen, id
        0x7f0a0000, 0x7f0a0001, 0x7f0a0002,  // more ids
    };

    for (size_t i = 0; i < sizeof(test_ids) / sizeof(test_ids[0]); i++) {
        const char *s = dx_resources_get_string(res, test_ids[i]);
        if (s) (void)strlen(s);

        const char *fn = dx_resources_get_layout_filename(res, test_ids[i]);
        if (fn) (void)strlen(fn);

        const char *s2 = dx_resources_get_string_by_id(res, test_ids[i]);
        if (s2) (void)strlen(s2);
    }

    dx_resources_free(res);
    return 0;
}

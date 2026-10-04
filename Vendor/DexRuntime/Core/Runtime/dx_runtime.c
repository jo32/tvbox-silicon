#include "../Include/dx_runtime.h"
#include "../Include/dx_context.h"
#include "../Include/dx_vm.h"
#include "../Include/dx_dex.h"
#include "../Include/dx_apk.h"
#include "../Include/dx_manifest.h"
#include "../Include/dx_resources.h"
#include "../Include/dx_view.h"
#include "../Include/dx_log.h"
#include "../Include/dx_jni.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <setjmp.h>

#define TAG "Runtime"

#include "../Include/dx_memory.h"

DxResult dx_runtime_init(DxContext *ctx) {
    if (!ctx) return DX_ERR_NULL_PTR;
    dx_log_init();
    DX_INFO(TAG, "DexLoom runtime initializing");
    ctx->initialized = true;
    return DX_OK;
}

DxResult dx_runtime_load(DxContext *ctx, const char *apk_path) {
    if (!ctx || !apk_path) return DX_ERR_NULL_PTR;

    DX_INFO(TAG, "Loading APK: %s", apk_path);

    // Read APK file into memory
    FILE *f = fopen(apk_path, "rb");
    if (!f) {
        DX_ERROR(TAG, "Cannot open APK file: %s", apk_path);
        return DX_ERR_IO;
    }

    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (file_size <= 0 || file_size > 100 * 1024 * 1024) {
        DX_ERROR(TAG, "APK file size invalid: %ld", file_size);
        fclose(f);
        return DX_ERR_IO;
    }

    uint8_t *file_data = (uint8_t *)dx_malloc((size_t)file_size);
    if (!file_data) { fclose(f); return DX_ERR_OUT_OF_MEMORY; }

    size_t read_size = fread(file_data, 1, (size_t)file_size, f);
    fclose(f);

    if (read_size != (size_t)file_size) {
        DX_ERROR(TAG, "Short read: %zu of %ld", read_size, file_size);
        dx_free(file_data);
        return DX_ERR_IO;
    }

    // Parse APK (ZIP)
    DxApkFile *apk = NULL;
    DxResult res = dx_apk_open(file_data, (uint32_t)file_size, &apk);
    if (res != DX_OK) {
        dx_free(file_data);
        return res;
    }

    // Detect AAB (Android App Bundle) format
    dx_apk_detect_aab(apk);
    if (dx_apk_is_aab(apk)) {
        DX_INFO(TAG, "Android App Bundle (.aab) detected — using base/ paths");
        // Check for resources.pb (protobuf) which we cannot parse
        const DxZipEntry *pb_entry = NULL;
        if (dx_apk_find_entry(apk, "base/resources.pb", &pb_entry) == DX_OK) {
            DX_WARN(TAG, "AAB uses resources.pb (Protocol Buffers) — resource parsing not supported; "
                    "string resources, themes, and layout IDs will be unavailable");
        }
    }

    // Extract and parse AndroidManifest.xml
    const DxZipEntry *manifest_entry = NULL;
    res = dx_apk_find_entry(apk, "AndroidManifest.xml", &manifest_entry);
    // Fallback: AAB stores manifest at base/manifest/AndroidManifest.xml
    if (res != DX_OK && dx_apk_is_aab(apk)) {
        res = dx_apk_find_entry(apk, "base/manifest/AndroidManifest.xml", &manifest_entry);
        if (res == DX_OK) {
            DX_INFO(TAG, "Found manifest at AAB path: base/manifest/AndroidManifest.xml");
        }
    }
    if (res == DX_OK) {
        uint8_t *manifest_data = NULL;
        uint32_t manifest_size = 0;
        res = dx_apk_extract_entry(apk, manifest_entry, &manifest_data, &manifest_size);
        if (res == DX_OK) {
            DxManifest *manifest = NULL;
            res = dx_manifest_parse(manifest_data, manifest_size, &manifest);
            if (res == DX_OK && manifest) {
                ctx->package_name = manifest->package_name ? dx_strdup(manifest->package_name) : NULL;

                // Convert Java class name to DEX descriptor
                if (manifest->main_activity) {
                    size_t name_len = strlen(manifest->main_activity);
                    char *desc = (char *)dx_malloc(name_len + 3);
                    if (desc) {
                        desc[0] = 'L';
                        for (size_t i = 0; i < name_len; i++) {
                            desc[i + 1] = (manifest->main_activity[i] == '.') ? '/' : manifest->main_activity[i];
                        }
                        desc[name_len + 1] = ';';
                        desc[name_len + 2] = '\0';
                        ctx->main_activity_class = desc;
                    }
                }

                // Extract theme resource ID from manifest
                if (manifest->app_theme) {
                    // If it starts with "@0x", parse the hex resource ID
                    if (manifest->app_theme[0] == '@' && manifest->app_theme[1] == '0' &&
                        manifest->app_theme[2] == 'x') {
                        ctx->theme_res_id = (uint32_t)strtoul(manifest->app_theme + 1, NULL, 16);
                    }
                    DX_INFO(TAG, "App theme: %s (res_id=0x%08x)",
                            manifest->app_theme, ctx->theme_res_id);
                }

                DX_INFO(TAG, "Package: %s", ctx->package_name ? ctx->package_name : "(null)");
                DX_INFO(TAG, "Main activity: %s", ctx->main_activity_class ? ctx->main_activity_class : "(null)");
                dx_manifest_free(manifest);
            }
            dx_free(manifest_data);
        }
    }

    // Extract and parse resources.arsc
    DxResources *resources = NULL;
    const DxZipEntry *res_entry = NULL;
    if (dx_apk_find_entry(apk, "resources.arsc", &res_entry) == DX_OK) {
        uint8_t *res_data = NULL;
        uint32_t res_size = 0;
        if (dx_apk_extract_entry(apk, res_entry, &res_data, &res_size) == DX_OK) {
            dx_resources_parse(res_data, res_size, &resources);
            if (resources) {
                // Persist resources for runtime getString/getColor lookups
                ctx->resources = resources;
                // Copy string resources (legacy path)
                ctx->string_resources = (char **)dx_malloc(sizeof(char *) * resources->string_count);
                ctx->string_resource_count = resources->string_count;
                for (uint32_t i = 0; i < resources->string_count; i++) {
                    ctx->string_resources[i] = resources->strings[i] ?
                        dx_strdup(resources->strings[i]) : NULL;
                }
            }
            dx_free(res_data);
        }
    }

    // Create the application theme from the manifest's android:theme
    if (ctx->theme_res_id != 0 && ctx->resources) {
        ctx->theme = dx_theme_create(ctx->resources, ctx->theme_res_id);
        if (ctx->theme) {
            DX_INFO(TAG, "Application theme resolved: 0x%08x (%u attrs)",
                    ctx->theme_res_id, ctx->theme->bag->entry_count);
        }
    }

    // Log a few resource layout entries for debugging ID matching
    if (resources && resources->layout_entry_count > 0) {
        uint32_t show = resources->layout_entry_count < 5 ? resources->layout_entry_count : 5;
        for (uint32_t r = 0; r < show; r++) {
            DX_INFO(TAG, "resources.arsc layout[%u]: id=0x%08x filename='%s'",
                    r, resources->layout_entries[r].id,
                    resources->layout_entries[r].filename ? resources->layout_entries[r].filename : "(null)");
        }
    }

    // Extract layout XML files (including qualified dirs like res/layout-v26/)
    // For AAB format, layouts are under base/res/layout/
    for (uint32_t i = 0; i < apk->entry_count; i++) {
        const char *name = apk->entries[i].filename;
        // Match res/layout/ or res/layout-*/ (qualified resource directories)
        // Also match base/res/layout/ for AAB format
        const char *res_prefix = name;
        if (dx_apk_is_aab(apk) && strncmp(name, "base/", 5) == 0) {
            res_prefix = name + 5;  // skip "base/" to normalize path matching
        }
        bool is_layout = false;
        if (strncmp(res_prefix, "res/layout", 10) == 0 &&
            (res_prefix[10] == '/' || res_prefix[10] == '-') && strstr(name, ".xml")) {
            // For qualified dirs (res/layout-v26/foo.xml), only take if we don't
            // already have the same basename from res/layout/
            if (res_prefix[10] == '/') {
                is_layout = true;  // unqualified - always take
            } else {
                // qualified - check if we already have this basename
                const char *slash = strrchr(name, '/');
                const char *basename = slash ? slash + 1 : name;
                bool already_have = false;
                for (uint32_t j = 0; j < ctx->layout_count; j++) {
                    if (ctx->layout_names[j]) {
                        const char *s = strrchr(ctx->layout_names[j], '/');
                        const char *b = s ? s + 1 : ctx->layout_names[j];
                        if (strcmp(b, basename) == 0) { already_have = true; break; }
                    }
                }
                if (!already_have) is_layout = true;
            }
        }
        if (is_layout) {
            uint8_t *layout_data = NULL;
            uint32_t layout_size = 0;
            if (dx_apk_extract_entry(apk, &apk->entries[i], &layout_data, &layout_size) == DX_OK) {
                uint32_t idx = ctx->layout_count;
                ctx->layout_count++;
                ctx->layout_buffers = (uint8_t **)dx_realloc(ctx->layout_buffers,
                    sizeof(uint8_t *) * ctx->layout_count);
                ctx->layout_sizes = (uint32_t *)dx_realloc(ctx->layout_sizes,
                    sizeof(uint32_t) * ctx->layout_count);
                ctx->layout_ids = (uint32_t *)dx_realloc(ctx->layout_ids,
                    sizeof(uint32_t) * ctx->layout_count);
                ctx->layout_names = (char **)dx_realloc(ctx->layout_names,
                    sizeof(char *) * ctx->layout_count);

                ctx->layout_buffers[idx] = layout_data;
                ctx->layout_sizes[idx] = layout_size;
                ctx->layout_names[idx] = dx_strdup(name);

                // Cross-reference with resources.arsc layout entries to get real resource ID
                // Try exact match first, then suffix match (resources.arsc may omit path prefix)
                uint32_t layout_id = 0x7f030000 + idx; // fallback synthetic
                if (resources) {
                    // Extract just the filename without res/layout/ prefix for suffix matching
                    const char *basename = name + 11; // skip "res/layout/"

                    for (uint32_t r = 0; r < resources->layout_entry_count; r++) {
                        const char *res_fn = resources->layout_entries[r].filename;
                        if (!res_fn) continue;

                        // Exact match
                        if (strcmp(res_fn, name) == 0) {
                            layout_id = resources->layout_entries[r].id;
                            break;
                        }
                        // Suffix match (resources.arsc might store full path or just basename)
                        size_t res_len = strlen(res_fn);
                        size_t base_len = strlen(basename);
                        if (res_len >= base_len &&
                            strcmp(res_fn + res_len - base_len, basename) == 0) {
                            layout_id = resources->layout_entries[r].id;
                            break;
                        }
                    }
                }

                ctx->layout_ids[idx] = layout_id;

                DX_INFO(TAG, "Extracted layout: %s (id=0x%08x, size=%u)",
                        name, ctx->layout_ids[idx], layout_size);
            }
        }
    }

    // Second pass: use resources.arsc layout entries to find layouts with obfuscated paths
    // (e.g., res/ZF.xml instead of res/layout/activity_main.xml)
    if (resources && ctx->layout_count == 0 && resources->layout_entry_count > 0) {
        DX_INFO(TAG, "No layouts found by path, trying resources.arsc entries (%u layout resources)",
                resources->layout_entry_count);
        uint32_t max_layouts = resources->layout_entry_count < 256 ? resources->layout_entry_count : 256;
        for (uint32_t r = 0; r < max_layouts; r++) {
            const char *fn = resources->layout_entries[r].filename;
            if (!fn || strlen(fn) == 0) continue;
            // Verify it looks like a file path (contains '/' and ends with .xml)
            if (!strchr(fn, '/') || !strstr(fn, ".xml")) continue;

            // Check if we already extracted this file
            bool already_have = false;
            for (uint32_t j = 0; j < ctx->layout_count; j++) {
                if (ctx->layout_names[j] && strcmp(ctx->layout_names[j], fn) == 0) {
                    already_have = true;
                    break;
                }
            }
            if (already_have) continue;

            const DxZipEntry *entry = NULL;
            if (dx_apk_find_entry(apk, fn, &entry) == DX_OK && entry) {
                uint8_t *layout_data = NULL;
                uint32_t layout_size = 0;
                if (dx_apk_extract_entry(apk, entry, &layout_data, &layout_size) == DX_OK) {
                    uint32_t idx = ctx->layout_count++;
                    ctx->layout_buffers = (uint8_t **)dx_realloc(ctx->layout_buffers,
                        sizeof(uint8_t *) * ctx->layout_count);
                    ctx->layout_sizes = (uint32_t *)dx_realloc(ctx->layout_sizes,
                        sizeof(uint32_t) * ctx->layout_count);
                    ctx->layout_ids = (uint32_t *)dx_realloc(ctx->layout_ids,
                        sizeof(uint32_t) * ctx->layout_count);
                    ctx->layout_names = (char **)dx_realloc(ctx->layout_names,
                        sizeof(char *) * ctx->layout_count);

                    ctx->layout_buffers[idx] = layout_data;
                    ctx->layout_sizes[idx] = layout_size;
                    ctx->layout_names[idx] = dx_strdup(fn);
                    ctx->layout_ids[idx] = resources->layout_entries[r].id;

                    DX_INFO(TAG, "Extracted layout (via resources.arsc): %s (id=0x%08x, size=%u)",
                            fn, ctx->layout_ids[idx], layout_size);
                }
            }
        }
    }

    // Third pass: if still no layouts, scan for any AXML files under res/ that could be layouts
    // This handles APKs where resources.arsc layout entries have bogus filenames
    if (ctx->layout_count == 0) {
        DX_INFO(TAG, "No layouts found, scanning all res/*.xml entries for AXML layout files");
        for (uint32_t i = 0; i < apk->entry_count; i++) {
            const char *name = apk->entries[i].filename;
            if (!name) continue;
            // Must be under res/ (or base/res/ for AAB), end with .xml
            const char *rp = name;
            if (dx_apk_is_aab(apk) && strncmp(name, "base/", 5) == 0) {
                rp = name + 5;
            }
            if (strncmp(rp, "res/", 4) != 0) continue;
            size_t nlen = strlen(name);
            if (nlen < 8 || strcmp(name + nlen - 4, ".xml") != 0) continue;
            // Skip known non-layout resource dirs
            if (strncmp(rp, "res/values", 10) == 0) continue;
            if (strncmp(rp, "res/color", 9) == 0) continue;
            if (strncmp(rp, "res/anim", 8) == 0) continue;
            if (strncmp(rp, "res/menu", 8) == 0) continue;
            if (strncmp(rp, "res/xml", 7) == 0) continue;
            if (strncmp(rp, "res/drawable", 12) == 0) continue;
            if (strncmp(rp, "res/mipmap", 10) == 0) continue;
            if (strncmp(rp, "res/navigation", 14) == 0) continue;
            if (strncmp(rp, "res/font", 8) == 0) continue;
            if (strncmp(rp, "res/raw", 7) == 0) continue;
            if (strncmp(rp, "res/interpolator", 16) == 0) continue;
            if (strncmp(rp, "res/transition", 14) == 0) continue;

            uint8_t *layout_data = NULL;
            uint32_t layout_size = 0;
            if (dx_apk_extract_entry(apk, &apk->entries[i], &layout_data, &layout_size) != DX_OK)
                continue;

            // Verify AXML magic (0x00080003 little-endian)
            if (layout_size < 8 ||
                layout_data[0] != 0x03 || layout_data[1] != 0x00 ||
                layout_data[2] != 0x08 || layout_data[3] != 0x00) {
                dx_free(layout_data);
                continue;
            }

            uint32_t idx = ctx->layout_count++;
            ctx->layout_buffers = (uint8_t **)dx_realloc(ctx->layout_buffers,
                sizeof(uint8_t *) * ctx->layout_count);
            ctx->layout_sizes = (uint32_t *)dx_realloc(ctx->layout_sizes,
                sizeof(uint32_t) * ctx->layout_count);
            ctx->layout_ids = (uint32_t *)dx_realloc(ctx->layout_ids,
                sizeof(uint32_t) * ctx->layout_count);
            ctx->layout_names = (char **)dx_realloc(ctx->layout_names,
                sizeof(char *) * ctx->layout_count);

            ctx->layout_buffers[idx] = layout_data;
            ctx->layout_sizes[idx] = layout_size;
            ctx->layout_names[idx] = dx_strdup(name);
            ctx->layout_ids[idx] = 0x7f030000 + idx; // synthetic ID

            DX_INFO(TAG, "Extracted layout (AXML scan): %s (id=0x%08x, size=%u)",
                    name, ctx->layout_ids[idx], layout_size);

            if (ctx->layout_count >= 256) break; // reasonable cap
        }
    }

    DX_INFO(TAG, "Extracted %u layout(s) from APK (%u total entries)",
            ctx->layout_count, apk->entry_count);

    // Resources are now persisted in ctx->resources for runtime getString/getColor lookups
    // They will be freed in dx_context_destroy()

    // Collect all DEX file entries from APK
    // For AAB format, DEX files are under base/dex/ (e.g. base/dex/classes.dex)
    const DxZipEntry *dex_entries[8];
    uint32_t dex_entry_count = 0;

    for (uint32_t i = 0; i < apk->entry_count && dex_entry_count < 8; i++) {
        const char *name = apk->entries[i].filename;
        if (name) {
            size_t len = strlen(name);
            if (len >= 4 && strcmp(name + len - 4, ".dex") == 0) {
                dex_entries[dex_entry_count++] = &apk->entries[i];
                DX_INFO(TAG, "Found DEX file: %s", name);
            }
        }
    }

    // AAB fallback: look under base/dex/ if no top-level DEX files found
    if (dex_entry_count == 0 && dx_apk_is_aab(apk)) {
        DX_INFO(TAG, "No top-level DEX files, scanning AAB base/dex/ directory");
        for (uint32_t i = 0; i < apk->entry_count && dex_entry_count < 8; i++) {
            const char *name = apk->entries[i].filename;
            if (name && strncmp(name, "base/dex/", 9) == 0) {
                size_t len = strlen(name);
                if (len >= 4 && strcmp(name + len - 4, ".dex") == 0) {
                    dex_entries[dex_entry_count++] = &apk->entries[i];
                    DX_INFO(TAG, "Found AAB DEX file: %s", name);
                }
            }
        }
    }

    if (dex_entry_count == 0) {
        bool has_native_libs = false;
        for (uint32_t i = 0; i < apk->entry_count; i++) {
            if (apk->entries[i].filename &&
                strncmp(apk->entries[i].filename, "lib/", 4) == 0) {
                has_native_libs = true;
                break;
            }
        }
        if (has_native_libs) {
            DX_ERROR(TAG, "APK contains native libraries but no DEX bytecode — this is a native-only app and cannot be interpreted");
        } else {
            DX_ERROR(TAG, "No DEX file found in APK (%u entries scanned):", apk->entry_count);
            for (uint32_t i = 0; i < apk->entry_count && i < 50; i++) {
                DX_ERROR(TAG, "  [%u] %s", i, apk->entries[i].filename ? apk->entries[i].filename : "(null)");
            }
        }
        dx_apk_close(apk);
        dx_free(file_data);
        return DX_ERR_NOT_FOUND;
    }

    // Create VM before loading DEX files
    ctx->vm = dx_vm_create(ctx);
    if (!ctx->vm) {
        dx_apk_close(apk);
        dx_free(file_data);
        return DX_ERR_OUT_OF_MEMORY;
    }

    // Register framework classes
    res = dx_vm_register_framework_classes(ctx->vm);
    if (res != DX_OK) {
        dx_apk_close(apk);
        dx_free(file_data);
        return res;
    }

    // Initialize JNI environment
    dx_jni_init(ctx->vm);

    // Parse and load each DEX file
    DX_INFO(TAG, "Loading %u DEX file(s)...", dex_entry_count);
    for (uint32_t d = 0; d < dex_entry_count; d++) {
        uint8_t *dex_data = NULL;
        uint32_t dex_size = 0;
        res = dx_apk_extract_entry(apk, dex_entries[d], &dex_data, &dex_size);
        if (res != DX_OK) {
            DX_WARN(TAG, "Failed to extract DEX file %s, skipping", dex_entries[d]->filename);
            continue;
        }

        DxDexFile *dex = NULL;
        res = dx_dex_parse(dex_data, dex_size, &dex);
        if (res != DX_OK) {
            DX_WARN(TAG, "Failed to parse DEX file %s, skipping", dex_entries[d]->filename);
            dx_free(dex_data);
            continue;
        }

        if (!ctx->dex) ctx->dex = dex;  // first DEX becomes primary for context

        res = dx_vm_load_dex(ctx->vm, dex);
        if (res != DX_OK) {
            DX_WARN(TAG, "Failed to load DEX file %s into VM", dex_entries[d]->filename);
        }
    }

    if (ctx->vm->dex_count == 0) {
        DX_ERROR(TAG, "No DEX files could be loaded");
        dx_apk_close(apk);
        dx_free(file_data);
        return DX_ERR_NOT_FOUND;
    }

    // Note: we keep dex_data alive since DxDexFile references it
    // Persist APK handle for runtime drawable extraction (ImageView src)
    ctx->apk = apk;
    ctx->apk_raw_data = file_data;

    DX_INFO(TAG, "APK loaded successfully");
    return DX_OK;
}

DxResult dx_runtime_run(DxContext *ctx) {
    if (!ctx) return DX_ERR_NULL_PTR;
    if (!ctx->vm) {
        DX_ERROR(TAG, "VM not initialized (APK may not contain executable code)");
        return DX_ERR_NULL_PTR;
    }
    if (!ctx->main_activity_class) {
        DX_ERROR(TAG, "No main activity class set");
        return DX_ERR_NOT_FOUND;
    }

    DX_INFO(TAG, "Starting main activity: %s", ctx->main_activity_class);
    ctx->running = true;

    // Install crash isolation handlers around interpreter execution
    dx_crash_install_handlers(ctx->vm);

    int sig = sigsetjmp(*dx_crash_get_jmpbuf(), 1);
    if (sig != 0) {
        // Recovered from a signal — clean up and report
        DX_ERROR(TAG, "Recovered from signal %d (%s) during execution",
                 sig, sig == 11 ? "SIGSEGV" : sig == 10 ? "SIGBUS" : "unknown");
        dx_crash_uninstall_handlers();
        ctx->running = false;
        return DX_ERR_SIGNAL;
    }

    DxResult res = dx_vm_run_main_activity(ctx->vm, ctx->main_activity_class);

    dx_crash_uninstall_handlers();
    return res;
}

DxResult dx_vm_run_main_activity(DxVM *vm, const char *activity_class) {
    if (!vm || !activity_class) return DX_ERR_NULL_PTR;

    // Load the activity class
    DxClass *cls = NULL;
    DxResult res = dx_vm_load_class(vm, activity_class, &cls);
    if (res != DX_OK) {
        DX_ERROR("Activity", "Cannot load activity class: %s", activity_class);
        return res;
    }

    res = dx_vm_init_class(vm, cls);
    if (res != DX_OK) return res;

    // Create activity instance
    DxObject *activity = dx_vm_alloc_object(vm, cls);
    if (!activity) return DX_ERR_OUT_OF_MEMORY;
    vm->activity_instance = activity;

    // Call <init> — minor errors are non-fatal, stack overflow is fatal
    DxMethod *init = dx_vm_find_method(cls, "<init>", NULL);
    if (init) {
        vm->insn_count = 0;  // Reset per-call instruction budget
        vm->pending_exception = NULL;
        DxValue init_args[1] = { DX_OBJ_VALUE(activity) };
        res = dx_vm_execute_method(vm, init, init_args, 1, NULL);
        if (res == DX_ERR_EXCEPTION) {
            const char *exc_desc = vm->pending_exception && vm->pending_exception->klass
                ? vm->pending_exception->klass->descriptor : "unknown";
            DX_WARN("Activity", "Activity.<init> threw uncaught %s (absorbed)", exc_desc);
            vm->pending_exception = NULL;
            res = DX_OK;
        } else if (res == DX_ERR_STACK_OVERFLOW || res == DX_ERR_INTERNAL || res == DX_ERR_BUDGET_EXHAUSTED || res == DX_ERR_SIGNAL) {
            DX_ERROR("Activity", "Activity.<init> failed fatally: %s", dx_result_string(res));
            return res;
        } else if (res != DX_OK) {
            DX_WARN("Activity", "Activity.<init> completed with errors: %s (continuing)",
                    dx_result_string(res));
        }
    }

    // Call onCreate(null) — minor errors are non-fatal, stack overflow/limit is fatal
    DxMethod *on_create = dx_vm_find_method(cls, "onCreate", NULL);
    if (on_create) {
        vm->insn_count = 0;  // Reset per-call instruction budget
        vm->pending_exception = NULL;
        DxValue args[2] = { DX_OBJ_VALUE(activity), DX_NULL_VALUE };
        res = dx_vm_execute_method(vm, on_create, args, 2, NULL);
        if (res == DX_ERR_EXCEPTION) {
            const char *exc_desc = vm->pending_exception && vm->pending_exception->klass
                ? vm->pending_exception->klass->descriptor : "unknown";
            DX_WARN("Activity", "onCreate threw uncaught %s (absorbed)", exc_desc);
            vm->pending_exception = NULL;
            res = DX_OK;
        } else if (res == DX_ERR_STACK_OVERFLOW || res == DX_ERR_INTERNAL || res == DX_ERR_BUDGET_EXHAUSTED || res == DX_ERR_SIGNAL) {
            DX_ERROR("Activity", "onCreate failed fatally: %s", dx_result_string(res));
            return res;
        } else if (res != DX_OK) {
            DX_WARN("Activity", "onCreate completed with errors: %s (continuing)",
                    dx_result_string(res));
        }
    } else {
        DX_WARN("Activity", "No onCreate method found in %s", activity_class);
    }

    // --- Activity lifecycle: onPostCreate(Bundle) ---
    DxMethod *on_post_create = dx_vm_find_method(cls, "onPostCreate", NULL);
    if (on_post_create) {
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue pc_args[2] = { DX_OBJ_VALUE(activity), DX_NULL_VALUE };
        res = dx_vm_execute_method(vm, on_post_create, pc_args, 2, NULL);
        if (res == DX_ERR_EXCEPTION) {
            DX_WARN("Activity", "onPostCreate threw %s (absorbed)",
                    vm->pending_exception && vm->pending_exception->klass
                    ? vm->pending_exception->klass->descriptor : "unknown");
            vm->pending_exception = NULL;
            res = DX_OK;
        } else if (res == DX_ERR_STACK_OVERFLOW || res == DX_ERR_INTERNAL || res == DX_ERR_BUDGET_EXHAUSTED || res == DX_ERR_SIGNAL) {
            DX_ERROR("Activity", "onPostCreate failed fatally: %s", dx_result_string(res));
            return res;
        }
    }

    // --- Activity lifecycle: onStart() ---
    DxMethod *on_start = dx_vm_find_method(cls, "onStart", "V");
    if (on_start) {
        DX_INFO("Activity", "Calling onStart()");
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue start_args[1] = { DX_OBJ_VALUE(activity) };
        res = dx_vm_execute_method(vm, on_start, start_args, 1, NULL);
        if (res == DX_ERR_EXCEPTION) {
            DX_WARN("Activity", "onStart threw %s (absorbed)",
                    vm->pending_exception && vm->pending_exception->klass
                    ? vm->pending_exception->klass->descriptor : "unknown");
            vm->pending_exception = NULL;
            res = DX_OK;
        } else if (res == DX_ERR_STACK_OVERFLOW || res == DX_ERR_INTERNAL || res == DX_ERR_BUDGET_EXHAUSTED || res == DX_ERR_SIGNAL) {
            DX_ERROR("Activity", "onStart failed fatally: %s", dx_result_string(res));
            return res;
        }
    }

    // --- Activity lifecycle: onResume() ---
    DxMethod *on_resume = dx_vm_find_method(cls, "onResume", "V");
    if (on_resume) {
        DX_INFO("Activity", "Calling onResume()");
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue resume_args[1] = { DX_OBJ_VALUE(activity) };
        res = dx_vm_execute_method(vm, on_resume, resume_args, 1, NULL);
        if (res == DX_ERR_EXCEPTION) {
            DX_WARN("Activity", "onResume threw %s (absorbed)",
                    vm->pending_exception && vm->pending_exception->klass
                    ? vm->pending_exception->klass->descriptor : "unknown");
            vm->pending_exception = NULL;
            res = DX_OK;
        } else if (res == DX_ERR_STACK_OVERFLOW || res == DX_ERR_INTERNAL || res == DX_ERR_BUDGET_EXHAUSTED || res == DX_ERR_SIGNAL) {
            DX_ERROR("Activity", "onResume failed fatally: %s", dx_result_string(res));
            return res;
        }
    }

    // --- Activity lifecycle: onPostResume() ---
    DxMethod *on_post_resume = dx_vm_find_method(cls, "onPostResume", "V");
    if (on_post_resume) {
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue pr_args[1] = { DX_OBJ_VALUE(activity) };
        res = dx_vm_execute_method(vm, on_post_resume, pr_args, 1, NULL);
        if (res == DX_ERR_EXCEPTION) {
            DX_WARN("Activity", "onPostResume threw %s (absorbed)",
                    vm->pending_exception && vm->pending_exception->klass
                    ? vm->pending_exception->klass->descriptor : "unknown");
            vm->pending_exception = NULL;
            res = DX_OK;
        } else if (res == DX_ERR_STACK_OVERFLOW || res == DX_ERR_INTERNAL || res == DX_ERR_BUDGET_EXHAUSTED || res == DX_ERR_SIGNAL) {
            DX_ERROR("Activity", "onPostResume failed fatally: %s", dx_result_string(res));
            return res;
        }
    }

    DX_INFO("Activity", "Main activity started (lifecycle: onCreate -> onStart -> onResume)");

    // === Fragment lifecycle: if fragments were loaded during onCreate, drive their lifecycle ===
    // Many modern apps use fragments for their main UI. After the activity's onCreate
    // creates and adds fragments via FragmentManager, we need to call the fragment's
    // onCreateView() to get the actual layout.
    //
    // R8/ProGuard deobfuscation: method names may be obfuscated (e.g., "a", "b", "c") but
    // the parameter signature is preserved. onCreateView takes (LayoutInflater, ViewGroup, Bundle)
    // and returns View. We match by parameter types when the name doesn't match.
    DxContext *ctx = vm->ctx;
    if (ctx && !ctx->content_view_set) {
        // Scan loaded classes for Fragment subclasses that were instantiated during onCreate
        for (uint32_t ci = 0; ci < vm->class_count && !ctx->content_view_set; ci++) {
            DxClass *fcls = vm->classes[ci];
            if (!fcls || fcls->is_framework) continue;

            // Check if this class extends a Fragment class
            bool is_fragment = false;
            // First check the class's own descriptor
            if (fcls->descriptor && strstr(fcls->descriptor, "Fragment;") != NULL) {
                is_fragment = true;
            }
            // Then walk the super chain
            if (!is_fragment) {
                DxClass *walk = fcls->super_class;
                while (walk) {
                    if (walk->descriptor &&
                        (strcmp(walk->descriptor, "Landroidx/fragment/app/Fragment;") == 0 ||
                         strcmp(walk->descriptor, "Landroid/app/Fragment;") == 0 ||
                         strstr(walk->descriptor, "Fragment;") != NULL)) {
                        is_fragment = true;
                        break;
                    }
                    walk = walk->super_class;
                }
            }
            if (!is_fragment) continue;

            // Look for onCreateView method - first by name, then by signature (R8 deobfuscation)
            DxMethod *ocv = dx_vm_find_method(fcls, "onCreateView", NULL);

            // Signature-based deobfuscation: scan all virtual methods for the
            // onCreateView signature: (LayoutInflater, ViewGroup, Bundle) -> View
            if (!ocv || !ocv->has_code) {
                DxDexFile *frag_dex = fcls->dex_file ? fcls->dex_file : vm->dex;
                for (uint32_t mi = 0; mi < fcls->virtual_method_count; mi++) {
                    DxMethod *m = &fcls->virtual_methods[mi];
                    if (!m->has_code) continue;

                    // Check parameter signature via DEX proto
                    uint32_t midx = m->dex_method_idx;
                    if (!frag_dex || midx >= frag_dex->method_count) continue;

                    uint32_t param_count = dx_dex_get_method_param_count(frag_dex, midx);
                    if (param_count != 3) continue;

                    const char *p0 = dx_dex_get_method_param_type(frag_dex, midx, 0);
                    const char *p1 = dx_dex_get_method_param_type(frag_dex, midx, 1);
                    const char *p2 = dx_dex_get_method_param_type(frag_dex, midx, 2);
                    const char *ret = dx_dex_get_method_return_type(frag_dex, midx);

                    // Match: (LayoutInflater, ViewGroup, Bundle) -> View
                    if (p0 && strstr(p0, "LayoutInflater;") &&
                        p1 && strstr(p1, "ViewGroup;") &&
                        p2 && strstr(p2, "Bundle;") &&
                        ret && strstr(ret, "View;")) {
                        DX_INFO("Activity", "R8 deobfuscation: %s.%s matches onCreateView signature",
                                fcls->descriptor, m->name);
                        ocv = m;
                        break;
                    }
                }
            }

            if (!ocv || !ocv->has_code) continue;

            DX_INFO("Activity", "Driving fragment lifecycle: %s.%s", fcls->descriptor, ocv->name);

            // Create fragment instance
            DxObject *frag_obj = dx_vm_alloc_object(vm, fcls);
            if (!frag_obj) continue;

            // Call <init>
            DxMethod *frag_init = dx_vm_find_method(fcls, "<init>", NULL);
            if (frag_init) {
                vm->insn_count = 0;
                vm->pending_exception = NULL;
                DxValue init_args[1] = { DX_OBJ_VALUE(frag_obj) };
                res = dx_vm_execute_method(vm, frag_init, init_args, 1, NULL);
                if (res == DX_ERR_EXCEPTION) { vm->pending_exception = NULL; }
            }

            // Create a LayoutInflater argument
            DxObject *inflater_obj = NULL;
            if (vm->class_inflater) {
                inflater_obj = dx_vm_alloc_object(vm, vm->class_inflater);
            }

            // Call onCreateView(inflater, null, null)
            DxValue ocv_args[4] = {
                DX_OBJ_VALUE(frag_obj),
                inflater_obj ? DX_OBJ_VALUE(inflater_obj) : DX_NULL_VALUE,
                DX_NULL_VALUE,
                DX_NULL_VALUE
            };
            DxValue ocv_result = {0};
            vm->insn_count = 0;
            vm->pending_exception = NULL;
            res = dx_vm_execute_method(vm, ocv, ocv_args, 4, &ocv_result);
            if (res == DX_ERR_EXCEPTION) { vm->pending_exception = NULL; res = DX_OK; }

            if (res == DX_OK && ocv_result.tag == DX_VAL_OBJ && ocv_result.obj &&
                ocv_result.obj->ui_node) {
                // The fragment returned a View with a UI tree - use it as content
                DX_INFO("Activity", "Fragment returned UI tree, using as content view");
                if (ctx->ui_root) dx_ui_node_destroy(ctx->ui_root);
                ctx->ui_root = ocv_result.obj->ui_node;
                ctx->content_view_set = true;
                if (ctx->render_model) dx_render_model_destroy(ctx->render_model);
                ctx->render_model = dx_render_model_create(ctx->ui_root);
                if (ctx->on_ui_update && ctx->render_model) {
                    ctx->on_ui_update(ctx->render_model, ctx->ui_callback_data);
                }

                // Call onViewCreated(view, savedInstanceState)
                DxMethod *ovc = dx_vm_find_method(fcls, "onViewCreated", NULL);
                if (ovc && ovc->has_code) {
                    DxValue ovc_args[3] = {
                        DX_OBJ_VALUE(frag_obj),
                        ocv_result,
                        DX_NULL_VALUE
                    };
                    vm->insn_count = 0;
                    vm->pending_exception = NULL;
                    DxResult ovc_res = dx_vm_execute_method(vm, ovc, ovc_args, 3, NULL);
                    if (ovc_res == DX_ERR_EXCEPTION) { vm->pending_exception = NULL; }
                    DX_INFO("Activity", "Fragment.onViewCreated called");
                }

                // Call onStart()
                DxMethod *fon_start = dx_vm_find_method(fcls, "onStart", NULL);
                if (fon_start && fon_start->has_code) {
                    DxValue start_args[1] = { DX_OBJ_VALUE(frag_obj) };
                    vm->insn_count = 0;
                    vm->pending_exception = NULL;
                    dx_vm_execute_method(vm, fon_start, start_args, 1, NULL);
                    if (vm->pending_exception) { vm->pending_exception = NULL; }
                }

                // Call onResume()
                DxMethod *fon_resume = dx_vm_find_method(fcls, "onResume", NULL);
                if (fon_resume && fon_resume->has_code) {
                    DxValue resume_args[1] = { DX_OBJ_VALUE(frag_obj) };
                    vm->insn_count = 0;
                    vm->pending_exception = NULL;
                    dx_vm_execute_method(vm, fon_resume, resume_args, 1, NULL);
                    if (vm->pending_exception) { vm->pending_exception = NULL; }
                    DX_INFO("Activity", "Fragment.onResume called");
                }
            } else if (res != DX_OK) {
                DX_WARN("Activity", "Fragment.onCreateView failed: %s", dx_result_string(res));
            }
        }
    }

    // Fallback: if setContentView was never called (or failed),
    // try to find the layout resource ID from bytecode analysis, then fall back to heuristics
    if (ctx && !ctx->content_view_set && ctx->layout_count > 0) {
        DX_WARN("Activity", "No setContentView after onCreate - scanning bytecode for layout ID");

        // Determine the layout type byte for matching
        // During execution, inflate may have recorded the actual type byte (e.g., 0x0d)
        uint8_t layout_type = ctx->layout_type_byte;
        if (layout_type == 0) layout_type = 0x03; // default fallback
        DX_INFO("Activity", "Layout type byte for scanning: 0x%02x", layout_type);

        int32_t best_idx = -1;

        // === Strategy 1: Static bytecode scan ===
        // Scan the main activity's onCreate (and superclasses) for const instructions
        // that load values matching known layout resource IDs from ctx->layout_ids[].
        // This directly finds the layout the app intended to display.
        if (cls && ctx->layout_ids) {
            // Walk the class hierarchy to find onCreate with bytecode
            DxClass *scan_cls = cls;
            while (scan_cls && best_idx < 0) {
                DxMethod *scan_method = dx_vm_find_method(scan_cls, "onCreate", NULL);
                if (scan_method && scan_method->has_code && scan_method->code.insns) {
                    uint16_t *insns = scan_method->code.insns;
                    uint32_t insns_size = scan_method->code.insns_size;

                    DX_INFO("Activity", "Scanning %s.onCreate bytecode (%u code units)",
                            scan_cls->descriptor, insns_size);

                    for (uint32_t pc = 0; pc < insns_size && best_idx < 0; ) {
                        uint8_t opcode = insns[pc] & 0xFF;

                        switch (opcode) {
                            case 0x14: { // const vAA, #+BBBBBBBB (format 31i, 3 units)
                                if (pc + 2 < insns_size) {
                                    uint32_t value = (uint32_t)insns[pc + 1] |
                                                     ((uint32_t)insns[pc + 2] << 16);
                                    // Check if this value matches any layout resource ID
                                    for (uint32_t li = 0; li < ctx->layout_count; li++) {
                                        if (ctx->layout_ids[li] == value) {
                                            DX_INFO("Activity",
                                                "Bytecode scan: found layout ID 0x%08x at PC=%u -> %s",
                                                value, pc, ctx->layout_names[li]);
                                            best_idx = (int32_t)li;
                                            break;
                                        }
                                    }
                                    // Also check entry-index fallback (lower 16 bits) for layout type
                                    if (best_idx < 0 && (value >> 24) == 0x7f) {
                                        uint8_t type_byte = (value >> 16) & 0xFF;
                                        if (type_byte == layout_type || type_byte == 0x03) {
                                            uint32_t entry = value & 0xFFFF;
                                            if (entry < ctx->layout_count) {
                                                DX_INFO("Activity",
                                                    "Bytecode scan: layout ID 0x%08x entry-index %u -> %s",
                                                    value, entry, ctx->layout_names[entry]);
                                                best_idx = (int32_t)entry;
                                            }
                                        }
                                    }
                                }
                                pc += 3;
                                break;
                            }
                            case 0x15: { // const/high16 vAA, #+BBBB0000 (format 21h, 2 units)
                                if (pc + 1 < insns_size) {
                                    uint32_t value = (uint32_t)insns[pc + 1] << 16;
                                    for (uint32_t li = 0; li < ctx->layout_count; li++) {
                                        if (ctx->layout_ids[li] == value) {
                                            DX_INFO("Activity",
                                                "Bytecode scan: found layout ID 0x%08x (high16) -> %s",
                                                value, ctx->layout_names[li]);
                                            best_idx = (int32_t)li;
                                            break;
                                        }
                                    }
                                }
                                pc += 2;
                                break;
                            }
                            // Skip other instructions by their format sizes
                            case 0x00: pc += 1; break; // nop
                            case 0x01: pc += 1; break; // move
                            case 0x02: pc += 2; break; // move/from16
                            case 0x03: pc += 3; break; // move/16
                            case 0x04: pc += 1; break; // move-wide
                            case 0x05: pc += 2; break; // move-wide/from16
                            case 0x06: pc += 3; break; // move-wide/16
                            case 0x07: pc += 1; break; // move-object
                            case 0x08: pc += 2; break; // move-object/from16
                            case 0x09: pc += 3; break; // move-object/16
                            case 0x0a: pc += 1; break; // move-result
                            case 0x0b: pc += 1; break; // move-result-wide
                            case 0x0c: pc += 1; break; // move-result-object
                            case 0x0d: pc += 1; break; // move-exception
                            case 0x0e: pc += 1; break; // return-void
                            case 0x0f: pc += 1; break; // return
                            case 0x10: pc += 1; break; // return-wide
                            case 0x11: pc += 1; break; // return-object
                            case 0x12: pc += 1; break; // const/4
                            case 0x13: pc += 2; break; // const/16
                            // 0x14 handled above
                            // 0x15 handled above
                            case 0x16: pc += 2; break; // const-wide/16
                            case 0x17: pc += 3; break; // const-wide/32
                            case 0x18: pc += 5; break; // const-wide
                            case 0x19: pc += 2; break; // const-wide/high16
                            case 0x1a: pc += 2; break; // const-string
                            case 0x1b: pc += 3; break; // const-string/jumbo
                            case 0x1c: pc += 2; break; // const-class
                            case 0x1d: pc += 1; break; // monitor-enter
                            case 0x1e: pc += 1; break; // monitor-exit
                            case 0x1f: pc += 2; break; // check-cast
                            case 0x20: pc += 2; break; // instance-of
                            case 0x21: pc += 1; break; // array-length
                            case 0x22: pc += 2; break; // new-instance
                            case 0x23: pc += 2; break; // new-array
                            case 0x24: pc += 3; break; // filled-new-array
                            case 0x25: pc += 3; break; // filled-new-array/range
                            case 0x26: pc += 3; break; // fill-array-data
                            case 0x27: pc += 1; break; // throw
                            case 0x28: pc += 1; break; // goto
                            case 0x29: pc += 2; break; // goto/16
                            case 0x2a: pc += 3; break; // goto/32
                            case 0x2b: pc += 3; break; // packed-switch
                            case 0x2c: pc += 3; break; // sparse-switch
                            default:
                                // 0x2d-0x31: cmpkind (2 units)
                                if (opcode >= 0x2d && opcode <= 0x31) { pc += 2; break; }
                                // 0x32-0x37: if-test (2 units)
                                if (opcode >= 0x32 && opcode <= 0x37) { pc += 2; break; }
                                // 0x38-0x3d: if-testz (2 units)
                                if (opcode >= 0x38 && opcode <= 0x3d) { pc += 2; break; }
                                // 0x44-0x51: arrayop (2 units)
                                if (opcode >= 0x44 && opcode <= 0x51) { pc += 2; break; }
                                // 0x52-0x5f: iinstanceop (2 units)
                                if (opcode >= 0x52 && opcode <= 0x5f) { pc += 2; break; }
                                // 0x60-0x6d: sstaticop (2 units)
                                if (opcode >= 0x60 && opcode <= 0x6d) { pc += 2; break; }
                                // 0x6e-0x72: invoke-kind (3 units)
                                if (opcode >= 0x6e && opcode <= 0x72) { pc += 3; break; }
                                // 0x73: unused
                                if (opcode == 0x73) { pc += 1; break; }
                                // 0x74-0x78: invoke-kind/range (3 units)
                                if (opcode >= 0x74 && opcode <= 0x78) { pc += 3; break; }
                                // 0x7b-0xCF: unop/binop (1-2 units)
                                if (opcode >= 0x7b && opcode <= 0x8f) { pc += 1; break; }
                                if (opcode >= 0x90 && opcode <= 0xaf) { pc += 2; break; }
                                // 0xb0-0xcf: binop/2addr (1 unit)
                                if (opcode >= 0xb0 && opcode <= 0xcf) { pc += 1; break; }
                                // 0xd0-0xd7: binop/lit16 (2 units)
                                if (opcode >= 0xd0 && opcode <= 0xd7) { pc += 2; break; }
                                // 0xd8-0xe2: binop/lit8 (2 units)
                                if (opcode >= 0xd8 && opcode <= 0xe2) { pc += 2; break; }
                                // Unknown - advance by 1 to avoid infinite loop
                                pc += 1;
                                break;
                        }
                    }
                }
                // Walk up to superclass (skip framework classes)
                scan_cls = scan_cls->super_class;
                if (scan_cls && scan_cls->is_framework) break;
            }

            if (best_idx < 0) {
                DX_INFO("Activity", "Bytecode scan: no layout ID found in onCreate chain");
            }
        }

        // === Strategy 1b: Scan ALL methods of Fragment-like classes for layout IDs ===
        // Method names may be obfuscated (e.g., R8 renames onCreateView to "a", "b", etc.)
        // so we scan every method with bytecode in Fragment subclasses.
        if (best_idx < 0 && ctx->layout_ids) {
            for (uint32_t ci = 0; ci < vm->class_count && best_idx < 0; ci++) {
                DxClass *fcls = vm->classes[ci];
                if (!fcls || fcls->is_framework) continue;
                // Quick check: does class name or super chain contain "Fragment"?
                bool maybe_fragment = false;
                if (fcls->descriptor && strstr(fcls->descriptor, "Fragment") != NULL)
                    maybe_fragment = true;
                if (!maybe_fragment) {
                    DxClass *w = fcls->super_class;
                    while (w) {
                        if (w->descriptor && strstr(w->descriptor, "Fragment") != NULL) {
                            maybe_fragment = true; break;
                        }
                        w = w->super_class;
                    }
                }
                if (!maybe_fragment) continue;

                DX_INFO("Activity", "Fragment scan: checking %s (%u direct + %u virtual methods)",
                        fcls->descriptor, fcls->direct_method_count, fcls->virtual_method_count);

                // Scan all methods of this Fragment class
                uint32_t total_methods = fcls->direct_method_count + fcls->virtual_method_count;
                for (uint32_t mi = 0; mi < total_methods && best_idx < 0; mi++) {
                    DxMethod *m = (mi < fcls->direct_method_count) ?
                        &fcls->direct_methods[mi] : &fcls->virtual_methods[mi - fcls->direct_method_count];
                    if (!m->has_code || !m->code.insns) continue;

                    uint16_t *insns = m->code.insns;
                    uint32_t insns_size = m->code.insns_size;

                    for (uint32_t pc = 0; pc < insns_size && best_idx < 0; ) {
                        uint8_t opcode = insns[pc] & 0xFF;
                        if (opcode == 0x14 && pc + 2 < insns_size) {
                            uint32_t value = (uint32_t)insns[pc + 1] |
                                             ((uint32_t)insns[pc + 2] << 16);
                            // Check if this matches a layout resource ID
                            for (uint32_t li = 0; li < ctx->layout_count; li++) {
                                if (ctx->layout_ids[li] == value) {
                                    DX_INFO("Activity",
                                        "Fragment scan: found layout ID 0x%08x in %s.%s -> %s",
                                        value, fcls->descriptor, m->name, ctx->layout_names[li]);
                                    best_idx = (int32_t)li;
                                    break;
                                }
                            }
                            if (best_idx < 0 && (value >> 24) == 0x7f) {
                                uint8_t type_byte = (value >> 16) & 0xFF;
                                if (type_byte == layout_type || type_byte == 0x03) {
                                    uint32_t entry = value & 0xFFFF;
                                    if (entry < ctx->layout_count) {
                                        DX_INFO("Activity",
                                            "Fragment scan: layout ID 0x%08x entry-index %u in %s.%s -> %s",
                                            value, entry, fcls->descriptor, m->name, ctx->layout_names[entry]);
                                        best_idx = (int32_t)entry;
                                    }
                                }
                            }
                            pc += 3;
                        } else if (opcode == 0x15 && pc + 1 < insns_size) {
                            uint32_t value = (uint32_t)insns[pc + 1] << 16;
                            for (uint32_t li = 0; li < ctx->layout_count; li++) {
                                if (ctx->layout_ids[li] == value) {
                                    DX_INFO("Activity",
                                        "Fragment scan: found layout ID 0x%08x (high16) in %s.%s -> %s",
                                        value, fcls->descriptor, m->name, ctx->layout_names[li]);
                                    best_idx = (int32_t)li;
                                    break;
                                }
                            }
                            pc += 2;
                        } else if (opcode == 0x60 && pc + 1 < insns_size) {
                            // sget vAA, field@BBBB - resolve field to get layout ID
                            uint16_t field_idx = insns[pc + 1];
                            DxDexFile *dex = fcls->dex_file ? fcls->dex_file : vm->dex;
                            if (dex && field_idx < dex->field_count) {
                                const char *fclass = dx_dex_get_field_class(dex, field_idx);
                                // Check if this field is from an R$layout class
                                if (fclass && (strstr(fclass, "R$layout") || strstr(fclass, "$layout;"))) {
                                    const char *fname = dx_dex_get_field_name(dex, field_idx);
                                    // Load the class and get the static field value
                                    DxClass *rcls = dx_vm_find_class(vm, fclass);
                                    if (!rcls) dx_vm_load_class(vm, fclass, &rcls);
                                    if (rcls && rcls->static_fields && rcls->static_field_count > 0) {
                                        // Find field by name
                                        DxDexClassData *cd = NULL;
                                        DxDexFile *rdex = rcls->dex_file ? rcls->dex_file : vm->dex;
                                        if (rdex && rcls->dex_class_def_idx < rdex->class_count)
                                            cd = rdex->class_data[rcls->dex_class_def_idx];
                                        if (cd) {
                                            for (uint32_t fi = 0; fi < cd->static_fields_count && fi < rcls->static_field_count; fi++) {
                                                const char *sfn = dx_dex_get_field_name(rdex, cd->static_fields[fi].field_idx);
                                                if (sfn && fname && strcmp(sfn, fname) == 0) {
                                                    uint32_t value = (uint32_t)rcls->static_fields[fi].i;
                                                    if ((value >> 24) == 0x7f) {
                                                        uint8_t tb = (value >> 16) & 0xFF;
                                                        if (tb == layout_type || tb == 0x03) {
                                                            uint32_t entry = value & 0xFFFF;
                                                            if (entry < ctx->layout_count) {
                                                                DX_INFO("Activity",
                                                                    "Fragment sget: R$layout.%s = 0x%08x -> entry %u -> %s (in %s.%s)",
                                                                    fname, value, entry, ctx->layout_names[entry],
                                                                    fcls->descriptor, m->name);
                                                                best_idx = (int32_t)entry;
                                                            }
                                                        }
                                                    }
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            pc += 2;
                        } else {
                            // Skip instruction by size
                            if (opcode <= 0x12 || opcode == 0x1d || opcode == 0x1e ||
                                opcode == 0x21 || opcode == 0x27 || opcode == 0x28 ||
                                (opcode >= 0x7b && opcode <= 0x8f) ||
                                (opcode >= 0xb0 && opcode <= 0xcf) ||
                                opcode == 0x0e || opcode == 0x0f || opcode == 0x10 || opcode == 0x11)
                                pc += 1;
                            else if (opcode == 0x02 || opcode == 0x05 || opcode == 0x08 ||
                                     opcode == 0x13 || opcode == 0x16 || opcode == 0x19 ||
                                     opcode == 0x1a || opcode == 0x1c || opcode == 0x1f ||
                                     opcode == 0x20 || opcode == 0x22 || opcode == 0x23 ||
                                     opcode == 0x29 ||
                                     (opcode >= 0x2d && opcode <= 0x3d) ||
                                     (opcode >= 0x44 && opcode <= 0x6d) ||
                                     (opcode >= 0x90 && opcode <= 0xaf) ||
                                     (opcode >= 0xd0 && opcode <= 0xe2))
                                pc += 2;
                            else if (opcode == 0x03 || opcode == 0x06 || opcode == 0x09 ||
                                     opcode == 0x17 || opcode == 0x1b ||
                                     opcode == 0x24 || opcode == 0x25 || opcode == 0x26 ||
                                     opcode == 0x2a || opcode == 0x2b || opcode == 0x2c ||
                                     (opcode >= 0x6e && opcode <= 0x78))
                                pc += 3;
                            else if (opcode == 0x18)
                                pc += 5;
                            else
                                pc += 1;
                        }
                    }
                }
            }
            if (best_idx >= 0) {
                DX_INFO("Activity", "Fragment bytecode scan found layout at index %d", best_idx);
            }
        }

        // === Strategy 2: Heuristic fallback ===
        if (best_idx < 0) {
            DX_INFO("Activity", "Falling back to heuristic layout selection");

            // Skip known library layout prefixes
            static const char *lib_prefixes[] = {
                "res/layout/abc_", "res/layout/design_", "res/layout/mtrl_",
                "res/layout/material_", "res/layout/browser_actions_",
                "res/layout/notification_template_", "res/layout/select_dialog_",
                "res/layout/support_", "res/layout/ime_", "res/layout/m3_",
                "res/layout/fragment_backstack", NULL
            };

            // Check if layout names are obfuscated
            bool names_obfuscated = true;
            for (uint32_t i = 0; i < ctx->layout_count && i < 10; i++) {
                if (ctx->layout_names[i] && strncmp(ctx->layout_names[i], "res/layout/", 11) == 0) {
                    names_obfuscated = false;
                    break;
                }
            }

            if (names_obfuscated) {
                // Obfuscated: score by node count
                uint32_t best_score = 0;
                for (uint32_t i = 0; i < ctx->layout_count; i++) {
                    DxUINode *test_root = NULL;
                    if (dx_layout_parse(ctx, ctx->layout_buffers[i],
                                         ctx->layout_sizes[i], &test_root) == DX_OK && test_root) {
                        uint32_t score = dx_ui_node_score_layout(test_root);
                        if (score > best_score) {
                            best_score = score;
                            best_idx = (int32_t)i;
                        }
                        dx_ui_node_destroy(test_root);
                    }
                }
            } else {
                // Named: priority heuristic
                int best_priority = 99;
                for (uint32_t i = 0; i < ctx->layout_count; i++) {
                    const char *name = ctx->layout_names[i];
                    if (!name) continue;

                    bool is_lib = false;
                    for (int p = 0; lib_prefixes[p]; p++) {
                        if (strncmp(name, lib_prefixes[p], strlen(lib_prefixes[p])) == 0) {
                            is_lib = true;
                            break;
                        }
                    }

                    bool is_dialog = (strstr(name, "dialog") != NULL);
                    bool is_content = (strstr(name, "content") != NULL ||
                                      strstr(name, "shell") != NULL);

                    int priority;
                    if (strstr(name, "activity_main")) priority = 0;
                    else if (!is_lib && (strstr(name, "activity") || strstr(name, "main"))) priority = 1;
                    else if (!is_lib && is_content) priority = 2;
                    else if (!is_lib && !is_dialog) priority = 3;
                    else if (!is_lib && is_dialog) priority = 4;
                    else priority = 5;

                    if (priority < best_priority) {
                        best_priority = priority;
                        best_idx = (int32_t)i;
                        if (priority == 0) break;
                    }
                }
            }
        }

        // Inflate the selected layout
        uint32_t layout_idx = (best_idx >= 0) ? (uint32_t)best_idx : 0;
        DxUINode *root = NULL;
        DxResult parse_res = dx_layout_parse(ctx, ctx->layout_buffers[layout_idx],
                                              ctx->layout_sizes[layout_idx], &root);
        if (parse_res == DX_OK && root) {
            if (ctx->ui_root) dx_ui_node_destroy(ctx->ui_root);
            ctx->ui_root = root;
            if (ctx->render_model) dx_render_model_destroy(ctx->render_model);
            ctx->render_model = dx_render_model_create(ctx->ui_root);
            if (ctx->on_ui_update && ctx->render_model) {
                ctx->on_ui_update(ctx->render_model, ctx->ui_callback_data);
            }
            DX_INFO("Activity", "Fallback layout inflated: %s (%u bytes)",
                    ctx->layout_names[layout_idx], ctx->layout_sizes[layout_idx]);
        }
    }

    return DX_OK;
}

DxResult dx_runtime_dispatch_click(DxContext *ctx, uint32_t view_id) {
    if (!ctx || !ctx->vm || !ctx->ui_root) return DX_ERR_NULL_PTR;

    DxUINode *node = dx_ui_node_find_by_id(ctx->ui_root, view_id);
    if (!node) {
        DX_WARN(TAG, "Click target not found: 0x%x", view_id);
        return DX_ERR_NOT_FOUND;
    }

    if (!node->click_listener) {
        DX_DEBUG(TAG, "No click listener on view 0x%x", view_id);
        return DX_OK;
    }

    DX_INFO(TAG, "Dispatching click on view 0x%x", view_id);

    // Find onClick method on the listener object
    DxObject *listener = node->click_listener;
    DxMethod *on_click = dx_vm_find_method(listener->klass, "onClick", NULL);
    if (!on_click) {
        DX_WARN(TAG, "onClick method not found on listener class %s",
                listener->klass->descriptor);
        return DX_ERR_METHOD_NOT_FOUND;
    }

    // Call onClick(view)
    ctx->vm->insn_count = 0;
    ctx->vm->pending_exception = NULL;
    DxObject *view_obj = node->runtime_obj;
    DxValue args[2] = { DX_OBJ_VALUE(listener), DX_OBJ_VALUE(view_obj) };
    DxResult click_res = dx_vm_execute_method(ctx->vm, on_click, args, 2, NULL);
    if (click_res == DX_ERR_EXCEPTION) {
        const char *exc_desc = ctx->vm->pending_exception && ctx->vm->pending_exception->klass
            ? ctx->vm->pending_exception->klass->descriptor : "unknown";
        DX_WARN(TAG, "onClick threw uncaught %s (absorbed)", exc_desc);
        ctx->vm->pending_exception = NULL;
        click_res = DX_OK;
    }
    return click_res;
}

DxResult dx_runtime_dispatch_long_click(DxContext *ctx, uint32_t view_id) {
    if (!ctx || !ctx->vm || !ctx->ui_root) return DX_ERR_NULL_PTR;

    DxUINode *node = dx_ui_node_find_by_id(ctx->ui_root, view_id);
    if (!node) {
        DX_WARN(TAG, "Long-click target not found: 0x%x", view_id);
        return DX_ERR_NOT_FOUND;
    }

    if (!node->long_click_listener) {
        DX_DEBUG(TAG, "No long-click listener on view 0x%x", view_id);
        return DX_OK;
    }

    DX_INFO(TAG, "Dispatching long-click on view 0x%x", view_id);

    DxObject *listener = node->long_click_listener;
    DxMethod *on_long_click = dx_vm_find_method(listener->klass, "onLongClick", NULL);
    if (!on_long_click) {
        DX_WARN(TAG, "onLongClick method not found on listener class %s",
                listener->klass->descriptor);
        return DX_ERR_METHOD_NOT_FOUND;
    }

    ctx->vm->insn_count = 0;
    ctx->vm->pending_exception = NULL;
    DxObject *view_obj = node->runtime_obj;
    DxValue args[2] = { DX_OBJ_VALUE(listener), DX_OBJ_VALUE(view_obj) };
    DxResult res = dx_vm_execute_method(ctx->vm, on_long_click, args, 2, NULL);
    if (res == DX_ERR_EXCEPTION) {
        const char *exc_desc = ctx->vm->pending_exception && ctx->vm->pending_exception->klass
            ? ctx->vm->pending_exception->klass->descriptor : "unknown";
        DX_WARN(TAG, "onLongClick threw uncaught %s (absorbed)", exc_desc);
        ctx->vm->pending_exception = NULL;
        res = DX_OK;
    }
    return res;
}

DxResult dx_runtime_dispatch_refresh(DxContext *ctx, uint32_t view_id) {
    if (!ctx || !ctx->vm || !ctx->ui_root) return DX_ERR_NULL_PTR;

    DxUINode *node = dx_ui_node_find_by_id(ctx->ui_root, view_id);
    if (!node) {
        DX_WARN(TAG, "Refresh target not found: 0x%x", view_id);
        return DX_ERR_NOT_FOUND;
    }

    if (!node->refresh_listener) {
        DX_DEBUG(TAG, "No refresh listener on view 0x%x", view_id);
        return DX_OK;
    }

    DX_INFO(TAG, "Dispatching refresh on view 0x%x", view_id);

    DxObject *listener = node->refresh_listener;
    DxMethod *on_refresh = dx_vm_find_method(listener->klass, "onRefresh", NULL);
    if (!on_refresh) {
        DX_WARN(TAG, "onRefresh method not found on listener class %s",
                listener->klass->descriptor);
        return DX_ERR_METHOD_NOT_FOUND;
    }

    ctx->vm->insn_count = 0;
    ctx->vm->pending_exception = NULL;
    DxValue args[1] = { DX_OBJ_VALUE(listener) };
    DxResult res = dx_vm_execute_method(ctx->vm, on_refresh, args, 1, NULL);
    if (res == DX_ERR_EXCEPTION) {
        const char *exc_desc = ctx->vm->pending_exception && ctx->vm->pending_exception->klass
            ? ctx->vm->pending_exception->klass->descriptor : "unknown";
        DX_WARN(TAG, "onRefresh threw uncaught %s (absorbed)", exc_desc);
        ctx->vm->pending_exception = NULL;
        res = DX_OK;
    }
    return res;
}

DxResult dx_runtime_update_edit_text(DxContext *ctx, uint32_t view_id, const char *text) {
    if (!ctx || !ctx->vm || !ctx->ui_root) return DX_ERR_NULL_PTR;

    DxUINode *node = dx_ui_node_find_by_id(ctx->ui_root, view_id);
    if (!node) return DX_ERR_NOT_FOUND;

    // Update the UI node text
    dx_ui_node_set_text(node, text);

    // Update the backing DxObject's string field if it exists
    if (node->runtime_obj) {
        DxObject *obj = node->runtime_obj;
        // Set the "text" field on the EditText object
        DxObject *str_obj = dx_vm_create_string(ctx->vm, text ? text : "");
        if (str_obj) {
            dx_vm_set_field(obj, "text", DX_OBJ_VALUE(str_obj));
        }
    }

    return DX_OK;
}

DxResult dx_runtime_dispatch_back(DxContext *ctx) {
    if (!ctx || !ctx->vm) return DX_ERR_NULL_PTR;

    DxVM *vm = ctx->vm;

    // Find the current activity object and call onBackPressed
    DxObject *activity = vm->activity_instance;
    if (activity && activity->klass) {
        DxMethod *on_back = dx_vm_find_method(activity->klass, "onBackPressed", NULL);
        if (on_back && on_back->has_code) {
            DX_INFO(TAG, "Dispatching onBackPressed to %s", activity->klass->descriptor);
            vm->insn_count = 0;
            vm->pending_exception = NULL;
            DxValue args[1] = { DX_OBJ_VALUE(activity) };
            DxResult res = dx_vm_execute_method(vm, on_back, args, 1, NULL);
            if (res == DX_ERR_EXCEPTION) {
                vm->pending_exception = NULL;
            }
            return DX_OK;
        }
    }

    DX_DEBUG(TAG, "No onBackPressed handler found");
    return DX_OK;
}

DxRenderModel *dx_runtime_get_render_model(DxContext *ctx) {
    if (!ctx) return NULL;
    return ctx->render_model;
}

void dx_runtime_set_night_mode(DxContext *ctx, bool is_night) {
    if (!ctx) return;
    ctx->device_config.night_mode = is_night ? DX_NIGHT_MODE_NIGHT : DX_NIGHT_MODE_NOTNIGHT;
    DX_INFO(TAG, "Night mode set to %s", is_night ? "night" : "notnight");
}

void dx_runtime_shutdown(DxContext *ctx) {
    if (!ctx) return;
    DX_INFO(TAG, "Runtime shutting down");
    ctx->running = false;
    dx_context_destroy(ctx);
}

// ============================================================
// Network bridge — global callback for C -> Swift networking
// ============================================================

static DxNetworkCallback g_network_callback = NULL;

void dx_runtime_set_network_callback(DxNetworkCallback callback) {
    g_network_callback = callback;
    DX_INFO(TAG, "Network callback %s", callback ? "registered" : "cleared");
}

bool dx_runtime_perform_network_request(const DxNetworkRequest *request, DxNetworkResponse *response) {
    if (!g_network_callback || !request || !response) {
        return false;
    }
    memset(response, 0, sizeof(*response));
    *response = g_network_callback(request);
    return true;
}

void dx_network_response_free(DxNetworkResponse *response) {
    if (!response) return;
    if (response->body) {
        free(response->body);
        response->body = NULL;
    }
    for (int i = 0; i < response->header_count; i++) {
        if (response->header_names && response->header_names[i]) free(response->header_names[i]);
        if (response->header_values && response->header_values[i]) free(response->header_values[i]);
    }
    if (response->header_names) { free(response->header_names); response->header_names = NULL; }
    if (response->header_values) { free(response->header_values); response->header_values = NULL; }
    response->header_count = 0;
}

// ============================================================
// File system sandboxing
// ============================================================

static char *g_sandbox_root = NULL;

void dx_runtime_set_sandbox_root(const char *root) {
    if (g_sandbox_root) {
        free(g_sandbox_root);
        g_sandbox_root = NULL;
    }
    if (root) {
        g_sandbox_root = strdup(root);
        DX_INFO(TAG, "Sandbox root set to: %s", root);
    } else {
        DX_INFO(TAG, "Sandbox disabled");
    }
}

bool dx_runtime_check_file_path(const char *path) {
    if (!path) return false;

    // Reject ".." traversal anywhere in the path
    if (strstr(path, "..")) {
        DX_WARN(TAG, "Sandbox: rejected path with traversal: %s", path);
        return false;
    }

    // Reject dangerous system paths
    static const char *blocked[] = { "/proc/", "/sys/", "/dev/" };
    for (int i = 0; i < 3; i++) {
        if (strstr(path, blocked[i])) {
            DX_WARN(TAG, "Sandbox: rejected system path: %s", path);
            return false;
        }
    }

    // If a sandbox root is set, absolute paths must be under it
    if (g_sandbox_root && path[0] == '/') {
        size_t root_len = strlen(g_sandbox_root);
        if (strncmp(path, g_sandbox_root, root_len) != 0) {
            DX_WARN(TAG, "Sandbox: rejected path outside root: %s", path);
            return false;
        }
        // Ensure the next char is '/' or end-of-string to prevent prefix tricks
        if (path[root_len] != '\0' && path[root_len] != '/') {
            DX_WARN(TAG, "Sandbox: rejected path outside root: %s", path);
            return false;
        }
    }

    return true;
}

#include "include/TVJarRuntime.h"
#include "Core/Include/dx_apk.h"
#include "Core/Include/dx_dex.h"
#include "Core/Include/dx_vm.h"
#include "Core/Include/dx_log.h"
#include "Core/Include/dx_memory.h"
#include "Core/Include/dx_context.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The upstream runtime has global logging/accounting state. All bridge calls
// are serialized, including inspection, so separate Swift actors remain safe.
static pthread_mutex_t runtime_lock = PTHREAD_MUTEX_INITIALIZER;

static TVJarResult process(const uint8_t *data, size_t size, const char *class_name, const char *method_name) {
    TVJarResult out = {0};
    DxApkFile *archive = NULL;
    DxVM *vm = NULL;
    DxDexFile *dex_files[DX_MAX_DEX_FILES] = {0};
    uint8_t *dex_buffers[DX_MAX_DEX_FILES] = {0};
    unsigned loaded = 0;
    DxResult status = DX_OK;
    if (!data || size == 0 || size > 20000000) {
        out.status = 1000; snprintf(out.message, sizeof(out.message), "Invalid JAR size (limit: 20 MB)"); return out;
    }
    dx_log_init(); dx_log_set_level(DX_LOG_ERROR);
    status = dx_apk_open(data, (uint32_t)size, &archive);
    if (status != DX_OK) goto done;
    // Inspect before execution: Android ELF binaries need an Android ABI/JNI
    // layer, not dlopen on Darwin. Never absorb their load failure as success.
    for (uint32_t i = 0; i < archive->entry_count; i++) {
        const char *name = archive->entries[i].filename;
        size_t n = strlen(name);
        if (n >= 3 && strcmp(name + n - 3, ".so") == 0) out.native_library_count++;
    }
    for (uint32_t i = 0; i < archive->entry_count; i++) {
        const DxZipEntry *entry = &archive->entries[i];
        const char *name = entry->filename;
        size_t n = strlen(name);
        if (n < 4 || strcmp(name + n - 4, ".dex") != 0) continue;
        out.dex_count++;
        if (loaded >= DX_MAX_DEX_FILES || entry->uncompressed_size > 20000000) { status = DX_ERR_INVALID_FORMAT; goto done; }
        uint32_t size = 0;
        unsigned slot = loaded++;
        status = dx_apk_extract_entry(archive, entry, &dex_buffers[slot], &size);
        if (status != DX_OK) goto done;
        status = dx_dex_parse(dex_buffers[slot], size, &dex_files[slot]);
        if (status != DX_OK) goto done;
        out.class_count += dex_files[slot]->class_count;
    }
    if (out.dex_count == 0) {
        out.status = 1002;
        snprintf(out.message, sizeof(out.message), "No DEX found; JVM .class JAR requires a separate JVM engine");
        goto cleanup;
    }
    if (!class_name) {
        snprintf(out.message, sizeof(out.message), "Inspected %u DEX files, %u classes, %u Android native libraries", out.dex_count, out.class_count, out.native_library_count);
        goto cleanup;
    }
    if (out.native_library_count) {
        out.status = 1001;
        snprintf(out.message, sizeof(out.message), "Blocked: %u Android .so libraries require Android ELF/JNI compatibility; DEX execution alone is insufficient", out.native_library_count);
        goto cleanup;
    }
    vm = dx_vm_create(NULL);
    if (!vm) { status = DX_ERR_OUT_OF_MEMORY; goto done; }
    vm->insn_limit = 1000000;
    vm->watchdog_timeout_ms = 2000;
    status = dx_register_java_lang(vm);
    if (status != DX_OK) goto done;
    for (unsigned i = 0; i < loaded; i++) {
        status = dx_vm_load_dex(vm, dex_files[i]);
        if (status != DX_OK) goto done;
    }
    DxClass *cls = NULL;
    status = dx_vm_load_class(vm, class_name, &cls);
    if (status != DX_OK) goto done;
    status = dx_vm_init_class(vm, cls);
    if (status != DX_OK) goto done;
    DxMethod *method = dx_vm_find_method(cls, method_name, "I");
    if (!method || !(method->access_flags & DX_ACC_STATIC)) { status = DX_ERR_METHOD_NOT_FOUND; goto done; }
    DxValue value = {0};
    status = dx_vm_execute_method(vm, method, NULL, 0, &value);
    out.instructions = vm->insn_count;
    if (status != DX_OK) goto done;
    if (value.tag != DX_VAL_INT) { status = DX_ERR_INVALID_FORMAT; goto done; }
    const char *missing = dx_vm_get_missing_features(vm);
    if (vm->missing_features.count > 0) {
        out.status = 1003; snprintf(out.message, sizeof(out.message), "Missing runtime features: %.950s", missing); goto cleanup;
    }
    out.integer_value = value.i;
    snprintf(out.message, sizeof(out.message), "Executed DEX bytecode: returned %d after %llu instructions", value.i, (unsigned long long)out.instructions);
    goto cleanup;
done:
    out.status = status;
    snprintf(out.message, sizeof(out.message), "DEX runtime: %s", dx_result_string(status));
cleanup:
    if (vm) dx_vm_destroy(vm);
    for (unsigned i = 0; i < loaded; i++) {
        if (dex_files[i]) dx_dex_free(dex_files[i]);
        dx_free(dex_buffers[i]);
    }
    if (archive) dx_apk_close(archive);
    return out;
}
TVJarResult tv_jar_inspect(const uint8_t *data, size_t size) {
    pthread_mutex_lock(&runtime_lock);
    TVJarResult result = process(data, size, NULL, NULL);
    pthread_mutex_unlock(&runtime_lock);
    return result;
}
TVJarResult tv_jar_run_static_int(const uint8_t *data, size_t size, const char *class_name, const char *method_name) {
    pthread_mutex_lock(&runtime_lock);
    TVJarResult result = process(data, size, class_name, method_name);
    pthread_mutex_unlock(&runtime_lock);
    return result;
}

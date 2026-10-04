#include "../Include/dx_context.h"
#include "../Include/dx_log.h"
#include "../Include/dx_vm.h"
#include "../Include/dx_apk.h"
#include "../Include/dx_manifest.h"
#include "../Include/dx_resources.h"
#include "../Include/dx_dex.h"
#include "../Include/dx_view.h"
#include "../Include/dx_runtime.h"
#include <stdlib.h>
#include <string.h>

#define TAG "Context"

#include "../Include/dx_memory.h"

DxContext *dx_context_create(void) {
    DxContext *ctx = (DxContext *)dx_malloc(sizeof(DxContext));
    if (!ctx) return NULL;

    dx_log_init();

    // Initialize device configuration with iPhone defaults
    dx_device_config_init(&ctx->device_config);

    DX_INFO(TAG, "DexLoom runtime context created");
    return ctx;
}

void dx_context_destroy(DxContext *ctx) {
    if (!ctx) return;

    DX_INFO(TAG, "Destroying runtime context");

    if (ctx->vm) dx_vm_destroy(ctx->vm);
    if (ctx->dex) dx_dex_free(ctx->dex);
    if (ctx->ui_root) dx_ui_node_destroy(ctx->ui_root);
    if (ctx->render_model) dx_render_model_destroy(ctx->render_model);

    if (ctx->theme) dx_theme_free(ctx->theme);
    if (ctx->resources) dx_resources_free(ctx->resources);

    if (ctx->apk) dx_apk_close(ctx->apk);
    dx_free(ctx->apk_raw_data);

    dx_free(ctx->apk_path);
    dx_free(ctx->package_name);
    dx_free(ctx->main_activity_class);

    for (uint32_t i = 0; i < ctx->string_resource_count; i++) {
        dx_free(ctx->string_resources[i]);
    }
    dx_free(ctx->string_resources);

    for (uint32_t i = 0; i < ctx->layout_count; i++) {
        dx_free(ctx->layout_buffers[i]);
        dx_free(ctx->layout_names[i]);
    }
    dx_free(ctx->layout_buffers);
    dx_free(ctx->layout_sizes);
    dx_free(ctx->layout_ids);
    dx_free(ctx->layout_names);

    dx_free(ctx);
}

DxResult dx_context_load_apk(DxContext *ctx, const char *apk_path) {
    if (!ctx || !apk_path) return DX_ERR_NULL_PTR;

    DX_INFO(TAG, "Loading APK: %s", apk_path);
    ctx->apk_path = dx_strdup(apk_path);

    return dx_runtime_load(ctx, apk_path);
}

DxResult dx_context_run(DxContext *ctx) {
    if (!ctx) return DX_ERR_NULL_PTR;
    return dx_runtime_run(ctx);
}

DxResult dx_context_dispatch_click(DxContext *ctx, uint32_t view_id) {
    if (!ctx) return DX_ERR_NULL_PTR;
    return dx_runtime_dispatch_click(ctx, view_id);
}

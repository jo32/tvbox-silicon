#ifndef DX_CONTEXT_H
#define DX_CONTEXT_H

#include "dx_types.h"
#include "dx_apk.h"
#include "dx_resources.h"

// DxContext is the top-level runtime context.
// It owns the VM, loaded DEX files, UI state, and configuration.

struct DxContext {
    DxVM        *vm;
    DxDexFile   *dex;
    DxUINode    *ui_root;
    DxRenderModel *render_model;

    // APK data (persisted for runtime drawable extraction)
    DxApkFile *apk;                // parsed APK ZIP handle
    uint8_t     *apk_raw_data;     // raw APK file bytes (owned, apk references this)
    char        *apk_path;
    char        *package_name;
    char        *main_activity_class;

    // Parsed resources.arsc (persisted for runtime lookups)
    DxResources *resources;

    // Resolved application theme (from android:theme in manifest)
    uint32_t     theme_res_id;    // style resource ID (0 = none)
    DxTheme     *theme;           // resolved theme bag (NULL = none)

    // Device configuration for resource qualifier matching
    DxDeviceConfig device_config;

    // Resource tables
    char        **string_resources;   // indexed by resource ID offset
    uint32_t    string_resource_count;

    // Layout data (binary XML buffers)
    uint8_t     **layout_buffers;
    uint32_t    *layout_sizes;
    uint32_t    *layout_ids;
    char        **layout_names;     // original filenames from APK
    uint32_t    layout_count;

    // Callbacks to host (iOS)
    void        (*on_ui_update)(DxRenderModel *model, void *user_data);
    void        *ui_callback_data;

    // State
    bool        initialized;
    bool        running;
    bool        content_view_set;  // true if setContentView was explicitly called
    uint8_t     layout_type_byte;  // observed layout type byte from inflate (e.g., 0x0d)
    DxResult    last_error;
};

DxContext *dx_context_create(void);
void      dx_context_destroy(DxContext *ctx);
DxResult  dx_context_load_apk(DxContext *ctx, const char *apk_path);
DxResult  dx_context_run(DxContext *ctx);
DxResult  dx_context_dispatch_click(DxContext *ctx, uint32_t view_id);

#endif // DX_CONTEXT_H

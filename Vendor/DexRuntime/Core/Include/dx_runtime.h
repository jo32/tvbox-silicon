#ifndef DX_RUNTIME_H
#define DX_RUNTIME_H

#include "dx_types.h"
#include "dx_context.h"

// High-level runtime API for the Swift bridge

// Initialize the entire runtime
DxResult dx_runtime_init(DxContext *ctx);

// Load an APK file and prepare for execution
DxResult dx_runtime_load(DxContext *ctx, const char *apk_path);

// Execute the main activity
DxResult dx_runtime_run(DxContext *ctx);

// Dispatch a UI event (button click)
DxResult dx_runtime_dispatch_click(DxContext *ctx, uint32_t view_id);

// Dispatch a long-click event
DxResult dx_runtime_dispatch_long_click(DxContext *ctx, uint32_t view_id);

// Dispatch a pull-to-refresh event (SwipeRefreshLayout)
DxResult dx_runtime_dispatch_refresh(DxContext *ctx, uint32_t view_id);

// Update EditText content from Swift UI input
DxResult dx_runtime_update_edit_text(DxContext *ctx, uint32_t view_id, const char *text);

// Dispatch back button press (calls Activity.onBackPressed)
DxResult dx_runtime_dispatch_back(DxContext *ctx);

// Get current render model (for SwiftUI to consume)
DxRenderModel *dx_runtime_get_render_model(DxContext *ctx);

// Set night mode on the device config (true=night, false=notnight)
void dx_runtime_set_night_mode(DxContext *ctx, bool is_night);

// Shutdown
void dx_runtime_shutdown(DxContext *ctx);

// Opcode names and widths for tracing/verification
const char *dx_opcode_name(uint8_t opcode);
uint32_t dx_opcode_width(uint8_t opcode);

// ============================================================
// Network bridge — C-to-Swift callback for real HTTP requests
// ============================================================

#define DX_NET_MAX_HEADERS 64

typedef struct {
    const char *url;
    const char *method;           // GET, POST, PUT, DELETE, PATCH, HEAD
    const char **header_names;
    const char **header_values;
    int header_count;
    const uint8_t *body;
    size_t body_size;
} DxNetworkRequest;

typedef struct {
    int status_code;
    uint8_t *body;                // malloc'd by Swift, freed by C after copying
    size_t body_size;
    char **header_names;          // malloc'd arrays
    char **header_values;
    int header_count;
} DxNetworkResponse;

// Callback type — Swift implements this via @convention(c)
typedef DxNetworkResponse (*DxNetworkCallback)(const DxNetworkRequest *request);

// Set the network callback (called from Swift during setup)
void dx_runtime_set_network_callback(DxNetworkCallback callback);

// Perform a network request (called from C native methods)
// Returns true if callback was available and executed; false if no callback set
bool dx_runtime_perform_network_request(const DxNetworkRequest *request, DxNetworkResponse *response);

// Free a network response (frees body and header arrays)
void dx_network_response_free(DxNetworkResponse *response);

// ============================================================
// File system sandboxing
// ============================================================

// Set the sandbox root directory. Only paths under this root (and relative
// paths without traversal) are permitted.  Pass NULL to disable sandboxing.
void dx_runtime_set_sandbox_root(const char *root);

// Check whether *path* is allowed under the current sandbox policy.
// Returns true if the path is permitted, false (and logs a warning) if denied.
bool dx_runtime_check_file_path(const char *path);

#endif // DX_RUNTIME_H

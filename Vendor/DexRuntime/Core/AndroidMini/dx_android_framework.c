#include "../Include/dx_vm.h"
#include "../Include/dx_view.h"
#include "../Include/dx_context.h"
#include "../Include/dx_apk.h"
#include "../Include/dx_log.h"
#include "../Include/dx_resources.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include "../Include/dx_runtime.h"

#define TAG "Android"

#include "../Include/dx_memory.h"

// Forward declarations
static void rebuild_render_model(DxVM *vm);
static DxObject *create_file_object(DxVM *vm, const char *path);
static DxObject *call_on_save_instance_state(DxVM *vm, DxObject *activity);

// Reflection native method forward declarations
static DxResult native_class_forName(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_class_new_instance(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_class_is_assignable_from(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_class_get_declared_field(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_class_get_declared_method(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_class_get_declared_methods_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_class_get_declared_fields_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_class_get_annotation_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_class_is_annotation_present_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_class_get_annotations_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_method_invoke(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_method_get_annotation_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_method_is_annotation_present_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_method_get_annotations_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_method_get_name_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_field_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_field_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_field_get_name_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_annotation_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);
static DxResult native_annotation_annotation_type(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);

// ============================================================
// Activity native methods
// ============================================================

static DxResult native_activity_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) return DX_ERR_NULL_PTR;
    vm->activity_instance = self;
    DX_INFO(TAG, "Activity.<init> called");
    return DX_OK;
}

static DxResult native_activity_set_content_view(DxVM *vm, DxFrame *frame,
                                                   DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    int32_t layout_id = args[1].i;
    DX_INFO(TAG, "setContentView(0x%08x)", layout_id);

    DxContext *ctx = vm->ctx;
    if (!ctx) return DX_ERR_NULL_PTR;

    // Find layout buffer by ID
    for (uint32_t i = 0; i < ctx->layout_count; i++) {
        if (ctx->layout_ids[i] == (uint32_t)layout_id) {
            DxUINode *root = NULL;
            DxResult res = dx_layout_parse(ctx, ctx->layout_buffers[i],
                                            ctx->layout_sizes[i], &root);
            if (res == DX_OK && root) {
                if (ctx->ui_root) dx_ui_node_destroy(ctx->ui_root);
                ctx->ui_root = root;
                ctx->content_view_set = true;
                rebuild_render_model(vm);
                DX_INFO(TAG, "Content view set successfully");
            }
            return res;
        }
    }

    // Layout ID not found by exact match - try entry-index mapping
    // For obfuscated APKs with synthetic IDs, use entry index from resource ID
    if (ctx->layout_count > 0) {
        uint32_t entry_idx = (uint32_t)layout_id & 0xFFFF;
        uint32_t use_idx = 0;
        if (entry_idx < ctx->layout_count) {
            use_idx = entry_idx;
            DX_WARN(TAG, "Layout 0x%08x not found by ID, using entry index %u -> %s",
                    layout_id, entry_idx,
                    ctx->layout_names ? ctx->layout_names[use_idx] : "?");
        } else {
            DX_WARN(TAG, "Layout 0x%08x not found by ID, using first layout", layout_id);
        }
        DxUINode *root = NULL;
        DxResult res = dx_layout_parse(ctx, ctx->layout_buffers[use_idx],
                                        ctx->layout_sizes[use_idx], &root);
        if (res == DX_OK && root) {
            if (ctx->ui_root) dx_ui_node_destroy(ctx->ui_root);
            ctx->ui_root = root;
            ctx->content_view_set = true;
            rebuild_render_model(vm);
            DX_INFO(TAG, "Content view set from entry-index layout");
            return DX_OK;
        }
    }

    // No layouts at all - create a default placeholder
    DX_WARN(TAG, "No layouts available, creating default");
    DxUINode *root = dx_ui_node_create(DX_VIEW_LINEAR_LAYOUT, 0);
    root->orientation = DX_ORIENTATION_VERTICAL;
    if (ctx->ui_root) dx_ui_node_destroy(ctx->ui_root);
    ctx->ui_root = root;
    rebuild_render_model(vm);
    return DX_OK;
}

static DxResult native_activity_find_view_by_id(DxVM *vm, DxFrame *frame,
                                                  DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    int32_t view_id = args[1].i;
    DX_DEBUG(TAG, "findViewById(0x%08x)", view_id);

    DxContext *ctx = vm->ctx;
    if (!ctx || !ctx->ui_root) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxUINode *node = dx_ui_node_find_by_id(ctx->ui_root, (uint32_t)view_id);
    if (!node) {
        DX_WARN(TAG, "View 0x%08x not found", view_id);
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Return the runtime object linked to this node
    if (node->runtime_obj) {
        frame->result = DX_OBJ_VALUE(node->runtime_obj);
        frame->has_result = true;
        return DX_OK;
    }

    // Create a wrapper object for this view node
    DxClass *view_cls = NULL;
    switch (node->type) {
        case DX_VIEW_TEXT_VIEW: view_cls = vm->class_textview; break;
        case DX_VIEW_BUTTON:    view_cls = vm->class_button; break;
        default:                view_cls = vm->class_view; break;
    }

    DxObject *obj = dx_vm_alloc_object(vm, view_cls);
    if (!obj) return DX_ERR_OUT_OF_MEMORY;
    obj->ui_node = node;
    node->runtime_obj = obj;

    frame->result = DX_OBJ_VALUE(obj);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context native methods
// ============================================================

static DxResult native_get_system_service(DxVM *vm, DxFrame *frame,
                                           DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *svc_name = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        svc_name = dx_vm_get_string_value(args[1].obj);
    }
    DX_DEBUG(TAG, "getSystemService(\"%s\")", svc_name ? svc_name : "?");

    if (!svc_name) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Return a LayoutInflater for "layout_inflater" / "window"
    if (strcmp(svc_name, "layout_inflater") == 0 || strcmp(svc_name, "window") == 0) {
        if (vm->class_inflater) {
            DxObject *inflater = dx_vm_alloc_object(vm, vm->class_inflater);
            if (inflater) {
                frame->result = DX_OBJ_VALUE(inflater);
                frame->has_result = true;
                return DX_OK;
            }
        }
    }

    // Return stub objects for commonly requested services
    const char *stub_class = NULL;
    if (strcmp(svc_name, "window") == 0)
        stub_class = "Landroid/view/WindowManager;";
    else if (strcmp(svc_name, "input_method") == 0)
        stub_class = "Landroid/view/inputmethod/InputMethodManager;";
    else if (strcmp(svc_name, "clipboard") == 0)
        stub_class = "Landroid/content/ClipboardManager;";
    else if (strcmp(svc_name, "alarm") == 0)
        stub_class = "Landroid/app/AlarmManager;";
    else if (strcmp(svc_name, "notification") == 0)
        stub_class = "Landroid/app/NotificationManager;";
    else if (strcmp(svc_name, "connectivity") == 0)
        stub_class = "Landroid/net/ConnectivityManager;";
    else if (strcmp(svc_name, "vibrator") == 0)
        stub_class = "Landroid/os/Vibrator;";
    else if (strcmp(svc_name, "power") == 0)
        stub_class = "Landroid/os/PowerManager;";
    else if (strcmp(svc_name, "activity") == 0)
        stub_class = "Landroid/app/ActivityManager;";
    else if (strcmp(svc_name, "audio") == 0)
        stub_class = "Landroid/media/AudioManager;";
    else if (strcmp(svc_name, "location") == 0)
        stub_class = "Landroid/location/LocationManager;";
    else if (strcmp(svc_name, "jobscheduler") == 0)
        stub_class = "Landroid/app/job/JobScheduler;";
    else if (strcmp(svc_name, "account") == 0)
        stub_class = "Landroid/accounts/AccountManager;";

    if (stub_class) {
        DxClass *cls = dx_vm_find_class(vm, stub_class);
        if (!cls) cls = vm->class_object; // fallback to generic Object
        DxObject *svc_obj = dx_vm_alloc_object(vm, cls);
        frame->result = svc_obj ? DX_OBJ_VALUE(svc_obj) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Return generic non-null object for any other service to avoid NPE
    DxObject *generic_svc = dx_vm_alloc_object(vm, vm->class_object);
    frame->result = generic_svc ? DX_OBJ_VALUE(generic_svc) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_get_package_manager(DxVM *vm, DxFrame *frame,
                                            DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *pm_cls = dx_vm_find_class(vm, "Landroid/content/pm/PackageManager;");
    if (pm_cls) {
        DxObject *pm = dx_vm_alloc_object(vm, pm_cls);
        frame->result = pm ? DX_OBJ_VALUE(pm) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_get_window(DxVM *vm, DxFrame *frame,
                                   DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *win_cls = dx_vm_find_class(vm, "Landroid/view/Window;");
    if (win_cls) {
        DxObject *win = dx_vm_alloc_object(vm, win_cls);
        frame->result = win ? DX_OBJ_VALUE(win) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// LayoutInflater native methods
// ============================================================

static DxResult native_inflater_inflate(DxVM *vm, DxFrame *frame,
                                         DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    int32_t layout_id = (arg_count > 1) ? args[1].i : 0;
    DX_INFO(TAG, "LayoutInflater.inflate(0x%08x)", layout_id);

    DxContext *ctx = vm->ctx;
    if (!ctx) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Record the observed layout type byte for use in bytecode scanning
    if (layout_id != 0 && (layout_id >> 24) == 0x7f) {
        uint8_t type_byte = (layout_id >> 16) & 0xFF;
        if (ctx->layout_type_byte == 0) {
            ctx->layout_type_byte = type_byte;
            DX_DEBUG(TAG, "Observed layout type byte: 0x%02x", type_byte);
        }
    }

    // Try to find and inflate the layout
    int32_t found_idx = -1;

    // 1. Exact ID match
    for (uint32_t i = 0; i < ctx->layout_count; i++) {
        if (ctx->layout_ids[i] == (uint32_t)layout_id) {
            found_idx = (int32_t)i;
            break;
        }
    }

    // 2. Entry-index fallback: for AXML-scanned layouts with synthetic IDs,
    //    use the entry index from the resource ID as layout index
    if (found_idx < 0 && ctx->layout_count > 0) {
        uint32_t entry_idx = (uint32_t)layout_id & 0xFFFF;
        if (entry_idx < ctx->layout_count) {
            found_idx = (int32_t)entry_idx;
            DX_INFO(TAG, "Layout 0x%08x: using entry index %u -> %s",
                    layout_id, entry_idx,
                    ctx->layout_names ? ctx->layout_names[found_idx] : "?");
        }
    }

    // 3. If only one layout, use it
    if (found_idx < 0 && ctx->layout_count == 1) {
        found_idx = 0;
    }

    // 4. Fallback: find best layout by name heuristic (activity/main preferred)
    if (found_idx < 0 && ctx->layout_count > 0 && !ctx->ui_root) {
        static const char *lib_prefixes[] = {
            "res/layout/abc_", "res/layout/design_", "res/layout/mtrl_",
            "res/layout/material_", "res/layout/notification_",
            "res/layout/select_dialog_", "res/layout/support_", NULL
        };
        int best_priority = 99;
        for (uint32_t i = 0; i < ctx->layout_count; i++) {
            const char *name = ctx->layout_names ? ctx->layout_names[i] : NULL;
            if (!name) continue;
            bool is_lib = false;
            for (int p = 0; lib_prefixes[p]; p++) {
                if (strncmp(name, lib_prefixes[p], strlen(lib_prefixes[p])) == 0) {
                    is_lib = true; break;
                }
            }
            int priority;
            if (strstr(name, "activity_main")) priority = 0;
            else if (!is_lib && (strstr(name, "activity") || strstr(name, "calculator"))) priority = 1;
            else if (!is_lib && strstr(name, "main")) priority = 2;
            else if (!is_lib && !strstr(name, "dialog")) priority = 3;
            else priority = 5;
            if (priority < best_priority) {
                best_priority = priority;
                found_idx = (int32_t)i;
                if (priority == 0) break;
            }
        }
        if (found_idx >= 0) {
            DX_WARN(TAG, "Layout 0x%08x not found by ID, using fallback: %s",
                    layout_id, ctx->layout_names[found_idx]);
        }
    }

    if (found_idx >= 0) {
        DxUINode *root = NULL;
        DxResult res = dx_layout_parse(ctx, ctx->layout_buffers[found_idx],
                                        ctx->layout_sizes[found_idx], &root);
        if (res == DX_OK && root) {
            // LayoutInflater.inflate does NOT set the activity's content view.
            // Only setContentView should do that. The inflated tree is returned
            // as a standalone View object (used for dialogs, fragments, etc.)
            // Return a View object for the root
            DxObject *view_obj = dx_vm_alloc_object(vm, vm->class_view);
            if (view_obj) {
                view_obj->ui_node = root;
                root->runtime_obj = view_obj;
                frame->result = DX_OBJ_VALUE(view_obj);
                frame->has_result = true;
                return DX_OK;
            }
        }
    }

    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// View native methods
// ============================================================

static DxResult native_view_find_view_by_id(DxVM *vm, DxFrame *frame,
                                              DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t view_id = (arg_count > 1) ? args[1].i : 0;

    DxContext *ctx = vm->ctx;
    if (!ctx || !ctx->ui_root) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Search from the node associated with this view, or from root
    DxUINode *search_root = (self && self->ui_node) ? self->ui_node : ctx->ui_root;
    DxUINode *node = dx_ui_node_find_by_id(search_root, (uint32_t)view_id);
    if (!node) {
        node = dx_ui_node_find_by_id(ctx->ui_root, (uint32_t)view_id);
    }
    if (!node) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    if (node->runtime_obj) {
        frame->result = DX_OBJ_VALUE(node->runtime_obj);
        frame->has_result = true;
        return DX_OK;
    }

    DxClass *view_cls = NULL;
    switch (node->type) {
        case DX_VIEW_TEXT_VIEW: view_cls = vm->class_textview; break;
        case DX_VIEW_BUTTON:    view_cls = vm->class_button; break;
        default:                view_cls = vm->class_view; break;
    }
    DxObject *obj = dx_vm_alloc_object(vm, view_cls);
    if (obj) {
        obj->ui_node = node;
        node->runtime_obj = obj;
        frame->result = DX_OBJ_VALUE(obj);
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_view_invalidate(DxVM *vm, DxFrame *frame,
                                        DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->ui_node) {
        dx_ui_node_invalidate(self->ui_node);
        DX_DEBUG(TAG, "View invalidated: id=0x%x", self->ui_node->view_id);
    }
    return DX_OK;
}

static DxResult native_view_set_on_click_listener(DxVM *vm, DxFrame *frame,
                                                     DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *listener = (arg_count > 1) ? args[1].obj : NULL;

    if (!self || !self->ui_node) {
        DX_WARN(TAG, "setOnClickListener on object without UI node");
        return DX_OK;
    }

    self->ui_node->click_listener = listener;
    DX_DEBUG(TAG, "OnClickListener set for view 0x%x", self->ui_node->view_id);
    return DX_OK;
}

static DxResult native_view_set_on_long_click_listener(DxVM *vm, DxFrame *frame,
                                                        DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *listener = (arg_count > 1) ? args[1].obj : NULL;

    if (!self || !self->ui_node) {
        DX_WARN(TAG, "setOnLongClickListener on object without UI node");
        return DX_OK;
    }

    self->ui_node->long_click_listener = listener;
    DX_DEBUG(TAG, "OnLongClickListener set for view 0x%x", self->ui_node->view_id);
    return DX_OK;
}

static DxResult native_view_set_on_touch_listener(DxVM *vm, DxFrame *frame,
                                                    DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *listener = (arg_count > 1) ? args[1].obj : NULL;

    if (!self || !self->ui_node) {
        DX_WARN(TAG, "setOnTouchListener on object without UI node");
        return DX_OK;
    }

    self->ui_node->touch_listener = listener;
    DX_DEBUG(TAG, "OnTouchListener set for view 0x%x", self->ui_node->view_id);
    return DX_OK;
}

static DxResult native_swipe_refresh_set_on_refresh_listener(DxVM *vm, DxFrame *frame,
                                                              DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *listener = (arg_count > 1) ? args[1].obj : NULL;

    if (!self || !self->ui_node) {
        DX_WARN(TAG, "setOnRefreshListener on object without UI node");
        return DX_OK;
    }

    self->ui_node->refresh_listener = listener;
    DX_DEBUG(TAG, "OnRefreshListener set for view 0x%x", self->ui_node->view_id);
    return DX_OK;
}

// ============================================================
// ViewGroup native methods
// ============================================================

static DxResult native_viewgroup_get_child_at(DxVM *vm, DxFrame *frame,
                                               DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t index = (arg_count > 1) ? args[1].i : 0;

    if (!self || !self->ui_node || index < 0 || (uint32_t)index >= self->ui_node->child_count) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxUINode *child = self->ui_node->children[index];
    if (!child) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    if (child->runtime_obj) {
        frame->result = DX_OBJ_VALUE(child->runtime_obj);
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *obj = dx_vm_alloc_object(vm, vm->class_view);
    if (obj) {
        obj->ui_node = child;
        child->runtime_obj = obj;
        frame->result = DX_OBJ_VALUE(obj);
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_viewgroup_get_child_count(DxVM *vm, DxFrame *frame,
                                                   DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t count = 0;
    if (self && self->ui_node) count = (int32_t)self->ui_node->child_count;
    frame->result = DX_INT_VALUE(count);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// RecyclerView native methods
// ============================================================

#define DX_RECYCLERVIEW_MAX_ITEMS 50

static DxResult native_recyclerview_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) return DX_OK;

    // Create a UI node for the RecyclerView (it's a ViewGroup)
    if (!self->ui_node) {
        DxUINode *node = dx_ui_node_create(DX_VIEW_RECYCLER_VIEW, 0);
        if (node) {
            self->ui_node = node;
            node->runtime_obj = self;
        }
    }
    return DX_OK;
}

static DxResult native_recyclerview_set_adapter(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count < 2) return DX_OK;

    DxObject *self = args[0].obj;      // RecyclerView (this)
    DxObject *adapter = (args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self || !adapter) {
        DX_WARN(TAG, "RecyclerView.setAdapter: null self or adapter");
        return DX_OK;
    }

    // Store adapter in RecyclerView's field[0]
    if (self->fields && self->klass && self->klass->instance_field_count > 0) {
        self->fields[0] = DX_OBJ_VALUE(adapter);
    }

    // Ensure RecyclerView has a UI node
    if (!self->ui_node) {
        DxUINode *node = dx_ui_node_create(DX_VIEW_RECYCLER_VIEW, 0);
        if (node) {
            self->ui_node = node;
            node->runtime_obj = self;
        }
    }
    if (!self->ui_node) {
        DX_WARN(TAG, "RecyclerView.setAdapter: failed to create UI node");
        return DX_OK;
    }

    DX_INFO(TAG, "RecyclerView.setAdapter: dispatching adapter pattern");

    // --- Step 1: Call adapter.getItemCount() ---
    DxMethod *get_count = dx_vm_find_method(adapter->klass, "getItemCount", NULL);
    if (!get_count) {
        DX_WARN(TAG, "RecyclerView: adapter has no getItemCount()");
        return DX_OK;
    }

    DxValue count_args[1] = { DX_OBJ_VALUE(adapter) };
    DxValue count_result = {0};
    DxResult res = dx_vm_execute_method(vm, get_count, count_args, 1, &count_result);
    if (res != DX_OK) {
        DX_WARN(TAG, "RecyclerView: getItemCount() failed (err=%d)", res);
        return DX_OK;  // non-fatal
    }

    int32_t item_count = (count_result.tag == DX_VAL_INT) ? count_result.i : 0;
    if (item_count <= 0) {
        DX_INFO(TAG, "RecyclerView: adapter has 0 items");
        return DX_OK;
    }
    if (item_count > DX_RECYCLERVIEW_MAX_ITEMS) {
        DX_INFO(TAG, "RecyclerView: clamping item count from %d to %d", item_count, DX_RECYCLERVIEW_MAX_ITEMS);
        item_count = DX_RECYCLERVIEW_MAX_ITEMS;
    }

    DX_INFO(TAG, "RecyclerView: adapter has %d items", item_count);

    // --- Find adapter methods ---
    DxMethod *on_create_vh = dx_vm_find_method(adapter->klass, "onCreateViewHolder", NULL);
    DxMethod *on_bind_vh = dx_vm_find_method(adapter->klass, "onBindViewHolder", NULL);

    if (!on_create_vh) {
        DX_WARN(TAG, "RecyclerView: adapter has no onCreateViewHolder()");
        return DX_OK;
    }
    if (!on_bind_vh) {
        DX_WARN(TAG, "RecyclerView: adapter has no onBindViewHolder()");
        return DX_OK;
    }

    // --- Step 2 & 3: For each item, create and bind ViewHolder ---
    for (int32_t i = 0; i < item_count; i++) {
        // onCreateViewHolder(parent, viewType) -> ViewHolder
        // args: adapter(this), parent(RecyclerView), viewType(0)
        DxValue create_args[3] = {
            DX_OBJ_VALUE(adapter),
            DX_OBJ_VALUE(self),
            DX_INT_VALUE(0)
        };
        DxValue vh_result = {0};
        res = dx_vm_execute_method(vm, on_create_vh, create_args, 3, &vh_result);
        if (res != DX_OK || vh_result.tag != DX_VAL_OBJ || !vh_result.obj) {
            DX_WARN(TAG, "RecyclerView: onCreateViewHolder failed for item %d", i);
            continue;
        }

        DxObject *view_holder = vh_result.obj;

        // onBindViewHolder(viewHolder, position)
        // args: adapter(this), viewHolder, position
        DxValue bind_args[3] = {
            DX_OBJ_VALUE(adapter),
            DX_OBJ_VALUE(view_holder),
            DX_INT_VALUE(i)
        };
        res = dx_vm_execute_method(vm, on_bind_vh, bind_args, 3, NULL);
        if (res != DX_OK) {
            DX_WARN(TAG, "RecyclerView: onBindViewHolder failed for item %d", i);
            // Continue anyway — the ViewHolder may still have useful content
        }

        // Extract itemView from ViewHolder's field[0]
        DxObject *item_view = NULL;
        if (view_holder->fields && view_holder->klass &&
            view_holder->klass->instance_field_count > 0 &&
            view_holder->fields[0].tag == DX_VAL_OBJ) {
            item_view = view_holder->fields[0].obj;
        }

        if (item_view && item_view->ui_node) {
            dx_ui_node_add_child(self->ui_node, item_view->ui_node);
            DX_DEBUG(TAG, "RecyclerView: added item %d view to UI tree", i);
        } else if (item_view) {
            // itemView exists but has no ui_node — create one
            DxUINode *child_node = dx_ui_node_create(DX_VIEW_LINEAR_LAYOUT, 0);
            if (child_node) {
                item_view->ui_node = child_node;
                child_node->runtime_obj = item_view;
                dx_ui_node_add_child(self->ui_node, child_node);
                DX_DEBUG(TAG, "RecyclerView: created ui_node for item %d", i);
            }
        } else {
            DX_DEBUG(TAG, "RecyclerView: item %d has no itemView", i);
        }
    }

    // Rebuild the render model so SwiftUI picks up the new children
    rebuild_render_model(vm);
    DX_INFO(TAG, "RecyclerView: adapter pattern complete, %d items rendered", item_count);

    return DX_OK;
}

static DxResult native_recyclerview_get_adapter(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 &&
        self->fields[0].tag == DX_VAL_OBJ) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_viewholder_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *item_view = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self) return DX_OK;

    // Store itemView in ViewHolder's field[0]
    if (self->fields && self->klass && self->klass->instance_field_count > 0 && item_view) {
        self->fields[0] = DX_OBJ_VALUE(item_view);

        // Ensure itemView has a ui_node
        if (!item_view->ui_node) {
            DxViewType vtype = DX_VIEW_VIEW;
            if (item_view->klass) {
                if (item_view->klass == vm->class_textview) vtype = DX_VIEW_TEXT_VIEW;
                else if (item_view->klass == vm->class_button) vtype = DX_VIEW_BUTTON;
                else if (item_view->klass == vm->class_edittext) vtype = DX_VIEW_EDIT_TEXT;
                else if (item_view->klass == vm->class_imageview) vtype = DX_VIEW_IMAGE_VIEW;
                else if (item_view->klass == vm->class_linearlayout) vtype = DX_VIEW_LINEAR_LAYOUT;
            }
            DxUINode *node = dx_ui_node_create(vtype, 0);
            if (node) {
                item_view->ui_node = node;
                node->runtime_obj = item_view;
            }
        }
    }

    DX_DEBUG(TAG, "ViewHolder.<init> with itemView=%p", (void *)item_view);
    return DX_OK;
}

// ============================================================
// ListView / GridView / ArrayAdapter / BaseAdapter native methods
// ============================================================

#define DX_LISTVIEW_MAX_ITEMS 50

static DxResult native_listview_set_adapter(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count < 2) return DX_OK;

    DxObject *self = args[0].obj;      // ListView (this)
    DxObject *adapter = (args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self || !adapter) {
        DX_WARN(TAG, "ListView.setAdapter: null self or adapter");
        return DX_OK;
    }

    // Store adapter in field[0]
    if (self->fields && self->klass && self->klass->instance_field_count > 0) {
        self->fields[0] = DX_OBJ_VALUE(adapter);
    }

    // Ensure ListView has a UI node
    if (!self->ui_node) {
        DxUINode *node = dx_ui_node_create(DX_VIEW_LIST_VIEW, 0);
        if (node) {
            self->ui_node = node;
            node->runtime_obj = self;
        }
    }
    if (!self->ui_node) {
        DX_WARN(TAG, "ListView.setAdapter: failed to create UI node");
        return DX_OK;
    }

    DX_INFO(TAG, "ListView.setAdapter: dispatching adapter pattern");

    // --- Step 1: Call adapter.getCount() ---
    DxMethod *get_count = dx_vm_find_method(adapter->klass, "getCount", NULL);
    if (!get_count) {
        DX_WARN(TAG, "ListView: adapter has no getCount()");
        return DX_OK;
    }

    DxValue count_args[1] = { DX_OBJ_VALUE(adapter) };
    DxValue count_result = {0};
    DxResult res = dx_vm_execute_method(vm, get_count, count_args, 1, &count_result);
    if (res != DX_OK) {
        DX_WARN(TAG, "ListView: getCount() failed (err=%d)", res);
        return DX_OK;
    }

    int32_t item_count = (count_result.tag == DX_VAL_INT) ? count_result.i : 0;
    if (item_count <= 0) {
        DX_INFO(TAG, "ListView: adapter has 0 items");
        return DX_OK;
    }
    if (item_count > DX_LISTVIEW_MAX_ITEMS) {
        DX_INFO(TAG, "ListView: clamping item count from %d to %d", item_count, DX_LISTVIEW_MAX_ITEMS);
        item_count = DX_LISTVIEW_MAX_ITEMS;
    }

    DX_INFO(TAG, "ListView: adapter has %d items", item_count);

    // --- Step 2: Call adapter.getView(position, null, parent) for each item ---
    DxMethod *get_view = dx_vm_find_method(adapter->klass, "getView", NULL);
    if (!get_view) {
        DX_WARN(TAG, "ListView: adapter has no getView()");
        return DX_OK;
    }

    for (int32_t i = 0; i < item_count; i++) {
        DxValue view_args[4] = {
            DX_OBJ_VALUE(adapter),    // this
            DX_INT_VALUE(i),          // position
            DX_NULL_VALUE,            // convertView (null)
            DX_OBJ_VALUE(self)        // parent (ListView)
        };
        DxValue view_result = {0};
        res = dx_vm_execute_method(vm, get_view, view_args, 4, &view_result);
        if (res != DX_OK || view_result.tag != DX_VAL_OBJ || !view_result.obj) {
            DX_WARN(TAG, "ListView: getView failed for item %d", i);
            continue;
        }

        DxObject *item_view = view_result.obj;
        if (item_view->ui_node) {
            dx_ui_node_add_child(self->ui_node, item_view->ui_node);
            DX_DEBUG(TAG, "ListView: added item %d view to UI tree", i);
        } else {
            // Create a fallback ui_node for the item view
            DxViewType vtype = DX_VIEW_VIEW;
            if (item_view->klass == vm->class_textview) vtype = DX_VIEW_TEXT_VIEW;
            else if (item_view->klass == vm->class_viewgroup) vtype = DX_VIEW_LINEAR_LAYOUT;
            DxUINode *child_node = dx_ui_node_create(vtype, 0);
            if (child_node) {
                item_view->ui_node = child_node;
                child_node->runtime_obj = item_view;
                dx_ui_node_add_child(self->ui_node, child_node);
                DX_DEBUG(TAG, "ListView: created ui_node for item %d", i);
            }
        }
    }

    rebuild_render_model(vm);
    DX_INFO(TAG, "ListView: adapter pattern complete, %d items rendered", item_count);
    return DX_OK;
}

static DxResult native_listview_get_adapter(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 &&
        self->fields[0].tag == DX_VAL_OBJ) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_gridview_set_adapter(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count < 2) return DX_OK;

    DxObject *self = args[0].obj;
    DxObject *adapter = (args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self || !adapter) {
        DX_WARN(TAG, "GridView.setAdapter: null self or adapter");
        return DX_OK;
    }

    // Store adapter in field[0]
    if (self->fields && self->klass && self->klass->instance_field_count > 0) {
        self->fields[0] = DX_OBJ_VALUE(adapter);
    }

    // Ensure GridView has a UI node
    if (!self->ui_node) {
        DxUINode *node = dx_ui_node_create(DX_VIEW_GRID_VIEW, 0);
        if (node) {
            self->ui_node = node;
            node->runtime_obj = self;
        }
    }
    if (!self->ui_node) {
        DX_WARN(TAG, "GridView.setAdapter: failed to create UI node");
        return DX_OK;
    }

    DX_INFO(TAG, "GridView.setAdapter: dispatching adapter pattern");

    // Same adapter dispatch as ListView
    DxMethod *get_count = dx_vm_find_method(adapter->klass, "getCount", NULL);
    if (!get_count) {
        DX_WARN(TAG, "GridView: adapter has no getCount()");
        return DX_OK;
    }

    DxValue count_args[1] = { DX_OBJ_VALUE(adapter) };
    DxValue count_result = {0};
    DxResult res = dx_vm_execute_method(vm, get_count, count_args, 1, &count_result);
    if (res != DX_OK) {
        DX_WARN(TAG, "GridView: getCount() failed (err=%d)", res);
        return DX_OK;
    }

    int32_t item_count = (count_result.tag == DX_VAL_INT) ? count_result.i : 0;
    if (item_count <= 0) {
        DX_INFO(TAG, "GridView: adapter has 0 items");
        return DX_OK;
    }
    if (item_count > DX_LISTVIEW_MAX_ITEMS) {
        DX_INFO(TAG, "GridView: clamping item count from %d to %d", item_count, DX_LISTVIEW_MAX_ITEMS);
        item_count = DX_LISTVIEW_MAX_ITEMS;
    }

    DxMethod *get_view = dx_vm_find_method(adapter->klass, "getView", NULL);
    if (!get_view) {
        DX_WARN(TAG, "GridView: adapter has no getView()");
        return DX_OK;
    }

    for (int32_t i = 0; i < item_count; i++) {
        DxValue view_args[4] = {
            DX_OBJ_VALUE(adapter),
            DX_INT_VALUE(i),
            DX_NULL_VALUE,
            DX_OBJ_VALUE(self)
        };
        DxValue view_result = {0};
        res = dx_vm_execute_method(vm, get_view, view_args, 4, &view_result);
        if (res != DX_OK || view_result.tag != DX_VAL_OBJ || !view_result.obj) {
            DX_WARN(TAG, "GridView: getView failed for item %d", i);
            continue;
        }

        DxObject *item_view = view_result.obj;
        if (item_view->ui_node) {
            dx_ui_node_add_child(self->ui_node, item_view->ui_node);
        } else {
            DxViewType vtype = DX_VIEW_VIEW;
            if (item_view->klass == vm->class_textview) vtype = DX_VIEW_TEXT_VIEW;
            else if (item_view->klass == vm->class_viewgroup) vtype = DX_VIEW_LINEAR_LAYOUT;
            DxUINode *child_node = dx_ui_node_create(vtype, 0);
            if (child_node) {
                item_view->ui_node = child_node;
                child_node->runtime_obj = item_view;
                dx_ui_node_add_child(self->ui_node, child_node);
            }
        }
    }

    rebuild_render_model(vm);
    DX_INFO(TAG, "GridView: adapter pattern complete, %d items rendered", item_count);
    return DX_OK;
}

static DxResult native_gridview_get_adapter(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 &&
        self->fields[0].tag == DX_VAL_OBJ) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ArrayAdapter.getView: return a basic TextView
static DxResult native_arrayadapter_getview(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    // Create a simple TextView object as the item view
    DxObject *tv = dx_vm_alloc_object(vm, vm->class_textview);
    if (tv) {
        DxUINode *node = dx_ui_node_create(DX_VIEW_TEXT_VIEW, 0);
        if (node) {
            tv->ui_node = node;
            node->runtime_obj = tv;
        }
        frame->result = DX_OBJ_VALUE(tv);
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Intent native methods — extras storage and target class
// ============================================================
// Intent field layout:
//   field[0] = action string (DxObject* string or null)
//   field[1] = target class descriptor string (DxObject* string or null)
//   fields[2..33] = extras: even indices are keys, odd indices are values (up to 16 pairs)
// So instance_field_count = 2 + 32 = 34

#define DX_INTENT_FIELD_ACTION       0
#define DX_INTENT_FIELD_TARGET_CLASS 1
#define DX_INTENT_EXTRAS_START       2
#define DX_INTENT_MAX_EXTRAS         16
#define DX_INTENT_FIELD_COUNT        (2 + DX_INTENT_MAX_EXTRAS * 2)  // 34

// Intent.<init>(Context, Class) — two-arg constructor
static DxResult native_intent_init_ctx_class(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    // args[0] = this (Intent), args[1] = context, args[2] = Class object
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields) return DX_OK;

    // Extract the target class descriptor from the Class object
    // The Class object stores DxClass* in field[0] as int (pointer-as-int trick)
    if (arg_count > 2 && args[2].tag == DX_VAL_OBJ && args[2].obj) {
        DxObject *class_obj = args[2].obj;
        DxClass *target_cls = NULL;

        // Check if it's a java.lang.Class object with the DxClass* pointer
        if (class_obj->fields && class_obj->klass &&
            class_obj->klass->instance_field_count > 0 &&
            class_obj->fields[0].tag == DX_VAL_INT) {
            target_cls = (DxClass *)(uintptr_t)class_obj->fields[0].i;
        }

        if (target_cls && target_cls->descriptor) {
            DxObject *desc_str = dx_vm_create_string(vm, target_cls->descriptor);
            if (desc_str && self->klass->instance_field_count > DX_INTENT_FIELD_TARGET_CLASS) {
                self->fields[DX_INTENT_FIELD_TARGET_CLASS] = DX_OBJ_VALUE(desc_str);
                DX_INFO(TAG, "Intent.<init>(ctx, %s)", target_cls->descriptor);
            }
        } else {
            // Maybe args[2] is a string directly (class name)
            const char *name = dx_vm_get_string_value(class_obj);
            if (name) {
                DxObject *desc_str = dx_vm_create_string(vm, name);
                if (desc_str && self->klass->instance_field_count > DX_INTENT_FIELD_TARGET_CLASS) {
                    self->fields[DX_INTENT_FIELD_TARGET_CLASS] = DX_OBJ_VALUE(desc_str);
                    DX_INFO(TAG, "Intent.<init>(ctx, \"%s\")", name);
                }
            }
        }
    }
    return DX_OK;
}

// Intent.putExtra(String key, String/Object value) -> Intent
static DxResult native_intent_put_extra(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0] = this, args[1] = key, args[2] = value
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields || !self->klass ||
        self->klass->instance_field_count < DX_INTENT_FIELD_COUNT) {
        // Return self even if we can't store
        if (self) { frame->result = DX_OBJ_VALUE(self); frame->has_result = true; }
        return DX_OK;
    }

    if (arg_count < 3) {
        frame->result = DX_OBJ_VALUE(self);
        frame->has_result = true;
        return DX_OK;
    }

    // Find next free extras slot or overwrite existing key
    for (int i = 0; i < DX_INTENT_MAX_EXTRAS; i++) {
        int key_idx = DX_INTENT_EXTRAS_START + i * 2;
        int val_idx = key_idx + 1;
        // Empty slot: key is null/zero
        if (self->fields[key_idx].tag == DX_VAL_OBJ && self->fields[key_idx].obj == NULL) {
            self->fields[key_idx] = args[1];
            self->fields[val_idx] = args[2];
            if (args[1].tag == DX_VAL_OBJ && args[1].obj) {
                const char *k = dx_vm_get_string_value(args[1].obj);
                DX_DEBUG(TAG, "Intent.putExtra(\"%s\", ...)", k ? k : "?");
            }
            break;
        }
        // If same key exists, overwrite
        if (self->fields[key_idx].tag == DX_VAL_OBJ && self->fields[key_idx].obj &&
            args[1].tag == DX_VAL_OBJ && args[1].obj) {
            const char *existing = dx_vm_get_string_value(self->fields[key_idx].obj);
            const char *new_key = dx_vm_get_string_value(args[1].obj);
            if (existing && new_key && strcmp(existing, new_key) == 0) {
                self->fields[val_idx] = args[2];
                break;
            }
        }
    }

    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

// Intent.putExtra(String key, int value) -> Intent  (shorty "LLI")
static DxResult native_intent_put_extra_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields || !self->klass ||
        self->klass->instance_field_count < DX_INTENT_FIELD_COUNT ||
        arg_count < 3) {
        if (self) { frame->result = DX_OBJ_VALUE(self); frame->has_result = true; }
        return DX_OK;
    }

    for (int i = 0; i < DX_INTENT_MAX_EXTRAS; i++) {
        int key_idx = DX_INTENT_EXTRAS_START + i * 2;
        int val_idx = key_idx + 1;
        if (self->fields[key_idx].tag == DX_VAL_OBJ && self->fields[key_idx].obj == NULL) {
            self->fields[key_idx] = args[1];
            self->fields[val_idx] = args[2]; // int value stored directly
            break;
        }
        if (self->fields[key_idx].tag == DX_VAL_OBJ && self->fields[key_idx].obj &&
            args[1].tag == DX_VAL_OBJ && args[1].obj) {
            const char *existing = dx_vm_get_string_value(self->fields[key_idx].obj);
            const char *new_key = dx_vm_get_string_value(args[1].obj);
            if (existing && new_key && strcmp(existing, new_key) == 0) {
                self->fields[val_idx] = args[2];
                break;
            }
        }
    }

    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

// Intent.putExtra(String key, boolean value) -> Intent  (shorty "LLZ")
static DxResult native_intent_put_extra_bool(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Same approach as int — booleans are stored as int in DxValue
    return native_intent_put_extra_int(vm, frame, args, arg_count);
}

// Helper: find an extra by key string in an Intent object
static DxValue *intent_find_extra(DxObject *intent, const char *key) {
    if (!intent || !intent->fields || !intent->klass ||
        intent->klass->instance_field_count < DX_INTENT_FIELD_COUNT || !key) {
        return NULL;
    }
    for (int i = 0; i < DX_INTENT_MAX_EXTRAS; i++) {
        int key_idx = DX_INTENT_EXTRAS_START + i * 2;
        int val_idx = key_idx + 1;
        if (intent->fields[key_idx].tag == DX_VAL_OBJ && intent->fields[key_idx].obj) {
            const char *k = dx_vm_get_string_value(intent->fields[key_idx].obj);
            if (k && strcmp(k, key) == 0) {
                return &intent->fields[val_idx];
            }
        }
    }
    return NULL;
}

// Intent.getStringExtra(String key) -> String
static DxResult native_intent_get_string_extra(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = intent_find_extra(self, key);
    if (val && val->tag == DX_VAL_OBJ && val->obj) {
        frame->result = *val;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Intent.getIntExtra(String key, int defaultValue) -> int
static DxResult native_intent_get_int_extra(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t default_val = (arg_count > 2) ? args[2].i : 0;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = intent_find_extra(self, key);
    if (val && val->tag == DX_VAL_INT) {
        frame->result = *val;
    } else {
        frame->result = DX_INT_VALUE(default_val);
    }
    frame->has_result = true;
    return DX_OK;
}

// Intent.getBooleanExtra(String key, boolean defaultValue) -> boolean
static DxResult native_intent_get_boolean_extra(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t default_val = (arg_count > 2) ? args[2].i : 0;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = intent_find_extra(self, key);
    if (val && val->tag == DX_VAL_INT) {
        frame->result = *val;
    } else {
        frame->result = DX_INT_VALUE(default_val);
    }
    frame->has_result = true;
    return DX_OK;
}

// Intent.hasExtra(String key) -> boolean
static DxResult native_intent_has_extra(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = intent_find_extra(self, key);
    frame->result = DX_INT_VALUE(val ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// Intent.getExtras() -> Bundle (return null; extras are accessible via getXxxExtra)
static DxResult native_intent_get_extras(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Intent.getAction() -> String
static DxResult native_intent_get_action(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass &&
        self->klass->instance_field_count > DX_INTENT_FIELD_ACTION &&
        self->fields[DX_INTENT_FIELD_ACTION].tag == DX_VAL_OBJ &&
        self->fields[DX_INTENT_FIELD_ACTION].obj) {
        frame->result = self->fields[DX_INTENT_FIELD_ACTION];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Intent.setAction(String) -> Intent
static DxResult native_intent_set_action(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass &&
        self->klass->instance_field_count > DX_INTENT_FIELD_ACTION &&
        arg_count > 1) {
        self->fields[DX_INTENT_FIELD_ACTION] = args[1];
    }
    if (self) { frame->result = DX_OBJ_VALUE(self); } else { frame->result = DX_NULL_VALUE; }
    frame->has_result = true;
    return DX_OK;
}

// Intent.setClass(Context, Class) -> Intent
static DxResult native_intent_set_class(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this, args[1] = context, args[2] = Class object
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass &&
        self->klass->instance_field_count > DX_INTENT_FIELD_TARGET_CLASS &&
        arg_count > 2 && args[2].tag == DX_VAL_OBJ && args[2].obj) {
        DxObject *class_obj = args[2].obj;
        DxClass *target_cls = NULL;
        if (class_obj->fields && class_obj->klass &&
            class_obj->klass->instance_field_count > 0 &&
            class_obj->fields[0].tag == DX_VAL_INT) {
            target_cls = (DxClass *)(uintptr_t)class_obj->fields[0].i;
        }
        if (target_cls && target_cls->descriptor) {
            DxObject *desc_str = dx_vm_create_string(vm, target_cls->descriptor);
            if (desc_str) {
                self->fields[DX_INTENT_FIELD_TARGET_CLASS] = DX_OBJ_VALUE(desc_str);
            }
        }
    }
    if (self) { frame->result = DX_OBJ_VALUE(self); } else { frame->result = DX_NULL_VALUE; }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Parcel native methods — field-backed data container
// ============================================================
// Parcel field layout:
//   fields[0..DX_PARCEL_MAX_SLOTS-1] = written values (any DxValue)
//   field[DX_PARCEL_MAX_SLOTS]   = write position (int)
//   field[DX_PARCEL_MAX_SLOTS+1] = read position (int)

#define DX_PARCEL_MAX_SLOTS     32
#define DX_PARCEL_FIELD_WPOS    DX_PARCEL_MAX_SLOTS
#define DX_PARCEL_FIELD_RPOS    (DX_PARCEL_MAX_SLOTS + 1)
#define DX_PARCEL_FIELD_COUNT   (DX_PARCEL_MAX_SLOTS + 2)

// Parcel.obtain() -> Parcel (static)
static DxResult native_parcel_obtain(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *parcel_cls = dx_vm_find_class(vm, "Landroid/os/Parcel;");
    if (!parcel_cls) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *parcel = dx_vm_alloc_object(vm, parcel_cls);
    if (parcel && parcel->fields) {
        parcel->fields[DX_PARCEL_FIELD_WPOS] = DX_INT_VALUE(0);
        parcel->fields[DX_PARCEL_FIELD_RPOS] = DX_INT_VALUE(0);
    }
    frame->result = parcel ? DX_OBJ_VALUE(parcel) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Helper: write a value into parcel at current write position
static void parcel_write_value(DxObject *parcel, DxValue val) {
    if (!parcel || !parcel->fields) return;
    int wpos = parcel->fields[DX_PARCEL_FIELD_WPOS].i;
    if (wpos < 0 || wpos >= DX_PARCEL_MAX_SLOTS) return;
    parcel->fields[wpos] = val;
    parcel->fields[DX_PARCEL_FIELD_WPOS] = DX_INT_VALUE(wpos + 1);
}

// Helper: read a value from parcel at current read position
static DxValue parcel_read_value(DxObject *parcel) {
    if (!parcel || !parcel->fields) return DX_NULL_VALUE;
    int rpos = parcel->fields[DX_PARCEL_FIELD_RPOS].i;
    if (rpos < 0 || rpos >= DX_PARCEL_MAX_SLOTS) return DX_NULL_VALUE;
    DxValue val = parcel->fields[rpos];
    parcel->fields[DX_PARCEL_FIELD_RPOS] = DX_INT_VALUE(rpos + 1);
    return val;
}

// Parcel.writeString(String)
static DxResult native_parcel_write_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = (arg_count > 1) ? args[1] : DX_NULL_VALUE;
    parcel_write_value(self, val);
    return DX_OK;
}

// Parcel.readString() -> String
static DxResult native_parcel_read_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    frame->result = parcel_read_value(self);
    frame->has_result = true;
    return DX_OK;
}

// Parcel.writeInt(int)
static DxResult native_parcel_write_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = (arg_count > 1) ? args[1] : DX_INT_VALUE(0);
    parcel_write_value(self, val);
    return DX_OK;
}

// Parcel.readInt() -> int
static DxResult native_parcel_read_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = parcel_read_value(self);
    if (val.tag == DX_VAL_INT) {
        frame->result = val;
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

// Parcel.writeLong(long)
static DxResult native_parcel_write_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = (arg_count > 1) ? args[1] : (DxValue){.tag = DX_VAL_LONG, .l = 0};
    parcel_write_value(self, val);
    return DX_OK;
}

// Parcel.readLong() -> long
static DxResult native_parcel_read_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = parcel_read_value(self);
    if (val.tag == DX_VAL_LONG) {
        frame->result = val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_LONG, .l = 0};
    }
    frame->has_result = true;
    return DX_OK;
}

// Parcel.writeFloat(float)
static DxResult native_parcel_write_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = (arg_count > 1) ? args[1] : (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
    parcel_write_value(self, val);
    return DX_OK;
}

// Parcel.readFloat() -> float
static DxResult native_parcel_read_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = parcel_read_value(self);
    if (val.tag == DX_VAL_FLOAT) {
        frame->result = val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
    }
    frame->has_result = true;
    return DX_OK;
}

// Parcel.writeDouble(double)
static DxResult native_parcel_write_double(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = (arg_count > 1) ? args[1] : (DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0};
    parcel_write_value(self, val);
    return DX_OK;
}

// Parcel.readDouble() -> double
static DxResult native_parcel_read_double(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = parcel_read_value(self);
    if (val.tag == DX_VAL_DOUBLE) {
        frame->result = val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0};
    }
    frame->has_result = true;
    return DX_OK;
}

// Parcel.writeByte(byte) - stored as int
static DxResult native_parcel_write_byte(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = (arg_count > 1) ? args[1] : DX_INT_VALUE(0);
    parcel_write_value(self, val);
    return DX_OK;
}

// Parcel.readByte() -> byte (as int)
static DxResult native_parcel_read_byte(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val = parcel_read_value(self);
    if (val.tag == DX_VAL_INT) {
        frame->result = DX_INT_VALUE((int8_t)(val.i & 0xFF));
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

// Parcel.dataSize() -> int (stub: returns write position)
static DxResult native_parcel_data_size(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int size = 0;
    if (self && self->fields) {
        size = self->fields[DX_PARCEL_FIELD_WPOS].i;
    }
    frame->result = DX_INT_VALUE(size);
    frame->has_result = true;
    return DX_OK;
}

// Parcel.dataPosition() -> int (returns read position)
static DxResult native_parcel_data_position(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int pos = 0;
    if (self && self->fields) {
        pos = self->fields[DX_PARCEL_FIELD_RPOS].i;
    }
    frame->result = DX_INT_VALUE(pos);
    frame->has_result = true;
    return DX_OK;
}

// Parcel.setDataPosition(int) - sets read position
static DxResult native_parcel_set_data_position(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && arg_count > 1 && args[1].tag == DX_VAL_INT) {
        int pos = args[1].i;
        if (pos < 0) pos = 0;
        if (pos > DX_PARCEL_MAX_SLOTS) pos = DX_PARCEL_MAX_SLOTS;
        self->fields[DX_PARCEL_FIELD_RPOS] = DX_INT_VALUE(pos);
    }
    return DX_OK;
}

// ============================================================
// Bundle native methods — key-value pair storage
// ============================================================
// Bundle field layout:
//   fields[0..DX_BUNDLE_MAX_ENTRIES*2-1] = key-value pairs (even=key, odd=value)
//   field[DX_BUNDLE_MAX_ENTRIES*2] = count of entries (int)

#define DX_BUNDLE_MAX_ENTRIES    16
#define DX_BUNDLE_FIELD_COUNT    (DX_BUNDLE_MAX_ENTRIES * 2 + 1)

// Helper: find a bundle entry by key, returns pointer to value slot or NULL
static DxValue *bundle_find_value(DxObject *bundle, const char *key) {
    if (!bundle || !bundle->fields || !key) return NULL;
    for (int i = 0; i < DX_BUNDLE_MAX_ENTRIES; i++) {
        int key_idx = i * 2;
        int val_idx = key_idx + 1;
        if (bundle->fields[key_idx].tag == DX_VAL_OBJ && bundle->fields[key_idx].obj) {
            const char *k = dx_vm_get_string_value(bundle->fields[key_idx].obj);
            if (k && strcmp(k, key) == 0) {
                return &bundle->fields[val_idx];
            }
        }
    }
    return NULL;
}

// Helper: put a key-value pair into a bundle
static void bundle_put_value(DxObject *bundle, DxValue key, DxValue val) {
    if (!bundle || !bundle->fields) return;
    const char *key_str = NULL;
    if (key.tag == DX_VAL_OBJ && key.obj) {
        key_str = dx_vm_get_string_value(key.obj);
    }
    if (key_str) {
        // Check if key already exists - overwrite
        for (int i = 0; i < DX_BUNDLE_MAX_ENTRIES; i++) {
            int key_idx = i * 2;
            int val_idx = key_idx + 1;
            if (bundle->fields[key_idx].tag == DX_VAL_OBJ && bundle->fields[key_idx].obj) {
                const char *k = dx_vm_get_string_value(bundle->fields[key_idx].obj);
                if (k && strcmp(k, key_str) == 0) {
                    bundle->fields[val_idx] = val;
                    return;
                }
            }
        }
    }
    // Find empty slot
    for (int i = 0; i < DX_BUNDLE_MAX_ENTRIES; i++) {
        int key_idx = i * 2;
        int val_idx = key_idx + 1;
        if (bundle->fields[key_idx].tag == DX_VAL_OBJ && bundle->fields[key_idx].obj == NULL) {
            bundle->fields[key_idx] = key;
            bundle->fields[val_idx] = val;
            int count_idx = DX_BUNDLE_MAX_ENTRIES * 2;
            bundle->fields[count_idx] = DX_INT_VALUE(bundle->fields[count_idx].i + 1);
            return;
        }
    }
}

// Bundle.putString(String key, String value)
static DxResult native_bundle_put_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) {
        bundle_put_value(self, args[1], args[2]);
    }
    return DX_OK;
}

// Bundle.getString(String key) -> String
static DxResult native_bundle_get_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = bundle_find_value(self, key);
    frame->result = (val && val->tag == DX_VAL_OBJ) ? *val : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Bundle.getString(String key, String defaultValue) -> String
static DxResult native_bundle_get_string_default(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = bundle_find_value(self, key);
    if (val && val->tag == DX_VAL_OBJ && val->obj) {
        frame->result = *val;
    } else {
        frame->result = (arg_count > 2) ? args[2] : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Bundle.putInt(String key, int value)
static DxResult native_bundle_put_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) {
        bundle_put_value(self, args[1], args[2]);
    }
    return DX_OK;
}

// Bundle.getInt(String key) -> int  /  getInt(String key, int default) -> int
static DxResult native_bundle_get_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = bundle_find_value(self, key);
    if (val && val->tag == DX_VAL_INT) {
        frame->result = *val;
    } else {
        int32_t def = (arg_count > 2 && args[2].tag == DX_VAL_INT) ? args[2].i : 0;
        frame->result = DX_INT_VALUE(def);
    }
    frame->has_result = true;
    return DX_OK;
}

// Bundle.putLong(String key, long value)
static DxResult native_bundle_put_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) {
        bundle_put_value(self, args[1], args[2]);
    }
    return DX_OK;
}

// Bundle.getLong(String key) -> long
static DxResult native_bundle_get_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = bundle_find_value(self, key);
    if (val && val->tag == DX_VAL_LONG) {
        frame->result = *val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_LONG, .l = 0};
    }
    frame->has_result = true;
    return DX_OK;
}

// Bundle.putFloat(String key, float value)
static DxResult native_bundle_put_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) {
        bundle_put_value(self, args[1], args[2]);
    }
    return DX_OK;
}

// Bundle.getFloat(String key) -> float
static DxResult native_bundle_get_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = bundle_find_value(self, key);
    if (val && val->tag == DX_VAL_FLOAT) {
        frame->result = *val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
    }
    frame->has_result = true;
    return DX_OK;
}

// Bundle.putDouble(String key, double value)
static DxResult native_bundle_put_double(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) {
        bundle_put_value(self, args[1], args[2]);
    }
    return DX_OK;
}

// Bundle.getDouble(String key) -> double
static DxResult native_bundle_get_double(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = bundle_find_value(self, key);
    if (val && val->tag == DX_VAL_DOUBLE) {
        frame->result = *val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0};
    }
    frame->has_result = true;
    return DX_OK;
}

// Bundle.putBoolean(String key, boolean value)
static DxResult native_bundle_put_boolean(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) {
        bundle_put_value(self, args[1], args[2]);
    }
    return DX_OK;
}

// Bundle.getBoolean(String key) -> boolean
static DxResult native_bundle_get_boolean(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = bundle_find_value(self, key);
    if (val && val->tag == DX_VAL_INT) {
        frame->result = *val;
    } else {
        int32_t def = (arg_count > 2 && args[2].tag == DX_VAL_INT) ? args[2].i : 0;
        frame->result = DX_INT_VALUE(def);
    }
    frame->has_result = true;
    return DX_OK;
}

// Bundle.putParcelable / putSerializable / putBundle / putStringArrayList / putIntegerArrayList
static DxResult native_bundle_put_object(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) {
        bundle_put_value(self, args[1], args[2]);
    }
    return DX_OK;
}

// Bundle.getParcelable / getSerializable / getBundle / getStringArrayList / getIntegerArrayList
static DxResult native_bundle_get_object(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = bundle_find_value(self, key);
    frame->result = (val) ? *val : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Bundle.containsKey(String) -> boolean
static DxResult native_bundle_contains_key(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    DxValue *val = bundle_find_value(self, key);
    frame->result = DX_INT_VALUE(val ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// Bundle.size() -> int
static DxResult native_bundle_size(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int count = 0;
    if (self && self->fields) {
        count = self->fields[DX_BUNDLE_MAX_ENTRIES * 2].i;
    }
    frame->result = DX_INT_VALUE(count);
    frame->has_result = true;
    return DX_OK;
}

// Bundle.isEmpty() -> boolean
static DxResult native_bundle_is_empty(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int count = 0;
    if (self && self->fields) {
        count = self->fields[DX_BUNDLE_MAX_ENTRIES * 2].i;
    }
    frame->result = DX_INT_VALUE(count == 0 ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// Bundle.remove(String key)
static DxResult native_bundle_remove(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        key = dx_vm_get_string_value(args[1].obj);
    }
    if (!self || !self->fields || !key) return DX_OK;
    for (int i = 0; i < DX_BUNDLE_MAX_ENTRIES; i++) {
        int key_idx = i * 2;
        int val_idx = key_idx + 1;
        if (self->fields[key_idx].tag == DX_VAL_OBJ && self->fields[key_idx].obj) {
            const char *k = dx_vm_get_string_value(self->fields[key_idx].obj);
            if (k && strcmp(k, key) == 0) {
                self->fields[key_idx] = DX_NULL_VALUE;
                self->fields[val_idx] = DX_NULL_VALUE;
                int count_idx = DX_BUNDLE_MAX_ENTRIES * 2;
                if (self->fields[count_idx].i > 0) {
                    self->fields[count_idx] = DX_INT_VALUE(self->fields[count_idx].i - 1);
                }
                break;
            }
        }
    }
    return DX_OK;
}

// Bundle.clear()
static DxResult native_bundle_clear(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields) return DX_OK;
    for (int i = 0; i < DX_BUNDLE_MAX_ENTRIES * 2; i++) {
        self->fields[i] = DX_NULL_VALUE;
    }
    self->fields[DX_BUNDLE_MAX_ENTRIES * 2] = DX_INT_VALUE(0);
    return DX_OK;
}

// Bundle.keySet() -> Set<String> (returns ArrayList of keys as stand-in)
static DxResult native_bundle_key_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *list_cls = dx_vm_find_class(vm, "Ljava/util/ArrayList;");
    if (!list_cls || !self || !self->fields) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *list = dx_vm_alloc_object(vm, list_cls);
    if (!list) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxMethod *add_m = dx_vm_find_method(list_cls, "add", "ZL");
    if (add_m) {
        for (int i = 0; i < DX_BUNDLE_MAX_ENTRIES; i++) {
            int key_idx = i * 2;
            if (self->fields[key_idx].tag == DX_VAL_OBJ && self->fields[key_idx].obj) {
                DxValue add_args[2] = { DX_OBJ_VALUE(list), self->fields[key_idx] };
                dx_vm_execute_method(vm, add_m, add_args, 2, NULL);
            }
        }
    }
    frame->result = DX_OBJ_VALUE(list);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// ContentValues native methods — field-backed key-value storage (like Bundle)
// ============================================================
// ContentValues field layout:
//   fields[0..DX_CV_MAX_ENTRIES*2-1] = key-value pairs (even=key, odd=value)
//   field[DX_CV_MAX_ENTRIES*2] = count of entries (int)

#define DX_CV_MAX_ENTRIES    16
#define DX_CV_FIELD_COUNT    (DX_CV_MAX_ENTRIES * 2 + 1)

static DxValue *cv_find_value(DxObject *cv, const char *key) {
    if (!cv || !cv->fields || !key) return NULL;
    for (int i = 0; i < DX_CV_MAX_ENTRIES; i++) {
        int key_idx = i * 2;
        int val_idx = key_idx + 1;
        if (cv->fields[key_idx].tag == DX_VAL_OBJ && cv->fields[key_idx].obj) {
            const char *k = dx_vm_get_string_value(cv->fields[key_idx].obj);
            if (k && strcmp(k, key) == 0) {
                return &cv->fields[val_idx];
            }
        }
    }
    return NULL;
}

static void cv_put_value(DxObject *cv, DxValue key, DxValue val) {
    if (!cv || !cv->fields) return;
    const char *key_str = NULL;
    if (key.tag == DX_VAL_OBJ && key.obj) {
        key_str = dx_vm_get_string_value(key.obj);
    }
    if (key_str) {
        // Overwrite existing key
        for (int i = 0; i < DX_CV_MAX_ENTRIES; i++) {
            int key_idx = i * 2;
            int val_idx = key_idx + 1;
            if (cv->fields[key_idx].tag == DX_VAL_OBJ && cv->fields[key_idx].obj) {
                const char *k = dx_vm_get_string_value(cv->fields[key_idx].obj);
                if (k && strcmp(k, key_str) == 0) {
                    cv->fields[val_idx] = val;
                    return;
                }
            }
        }
    }
    // Find empty slot
    for (int i = 0; i < DX_CV_MAX_ENTRIES; i++) {
        int key_idx = i * 2;
        int val_idx = key_idx + 1;
        if (cv->fields[key_idx].tag == DX_VAL_OBJ && cv->fields[key_idx].obj == NULL) {
            cv->fields[key_idx] = key;
            cv->fields[val_idx] = val;
            int count_idx = DX_CV_MAX_ENTRIES * 2;
            cv->fields[count_idx] = DX_INT_VALUE(cv->fields[count_idx].i + 1);
            return;
        }
    }
}

static DxResult native_cv_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields) {
        for (int i = 0; i < DX_CV_MAX_ENTRIES * 2; i++) {
            self->fields[i] = DX_NULL_VALUE;
        }
        self->fields[DX_CV_MAX_ENTRIES * 2] = DX_INT_VALUE(0);
    }
    return DX_OK;
}

static DxResult native_cv_put_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) cv_put_value(self, args[1], args[2]);
    return DX_OK;
}

static DxResult native_cv_put_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) {
        // Box the integer as an Integer object-like value stored directly
        cv_put_value(self, args[1], args[2]);
    }
    return DX_OK;
}

static DxResult native_cv_put_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) cv_put_value(self, args[1], args[2]);
    return DX_OK;
}

static DxResult native_cv_put_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) cv_put_value(self, args[1], args[2]);
    return DX_OK;
}

static DxResult native_cv_put_double(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) cv_put_value(self, args[1], args[2]);
    return DX_OK;
}

static DxResult native_cv_put_boolean(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count >= 3) cv_put_value(self, args[1], args[2]);
    return DX_OK;
}

static DxResult native_cv_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    DxValue *val = cv_find_value(self, key);
    frame->result = val ? *val : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cv_get_as_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    DxValue *val = cv_find_value(self, key);
    if (val) {
        if (val->tag == DX_VAL_OBJ) {
            frame->result = *val;
        } else if (val->tag == DX_VAL_INT) {
            char buf[32]; snprintf(buf, sizeof(buf), "%d", val->i);
            DxObject *s = dx_vm_create_string(vm, buf);
            frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
        } else if (val->tag == DX_VAL_LONG) {
            char buf[32]; snprintf(buf, sizeof(buf), "%lld", (long long)val->l);
            DxObject *s = dx_vm_create_string(vm, buf);
            frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
        } else if (val->tag == DX_VAL_FLOAT) {
            char buf[32]; snprintf(buf, sizeof(buf), "%g", (double)val->f);
            DxObject *s = dx_vm_create_string(vm, buf);
            frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
        } else if (val->tag == DX_VAL_DOUBLE) {
            char buf[32]; snprintf(buf, sizeof(buf), "%g", val->d);
            DxObject *s = dx_vm_create_string(vm, buf);
            frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
        } else {
            frame->result = DX_NULL_VALUE;
        }
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cv_get_as_integer(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    DxValue *val = cv_find_value(self, key);
    if (val && val->tag == DX_VAL_INT) {
        frame->result = *val;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cv_get_as_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    DxValue *val = cv_find_value(self, key);
    if (val && val->tag == DX_VAL_LONG) {
        frame->result = *val;
    } else if (val && val->tag == DX_VAL_INT) {
        frame->result = (DxValue){.tag = DX_VAL_LONG, .l = val->i};
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cv_get_as_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    DxValue *val = cv_find_value(self, key);
    if (val && val->tag == DX_VAL_FLOAT) {
        frame->result = *val;
    } else if (val && val->tag == DX_VAL_INT) {
        frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = (float)val->i};
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cv_contains_key(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    DxValue *val = cv_find_value(self, key);
    frame->result = DX_INT_VALUE(val ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cv_remove(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields) return DX_OK;
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (!key) return DX_OK;
    for (int i = 0; i < DX_CV_MAX_ENTRIES; i++) {
        int key_idx = i * 2;
        if (self->fields[key_idx].tag == DX_VAL_OBJ && self->fields[key_idx].obj) {
            const char *k = dx_vm_get_string_value(self->fields[key_idx].obj);
            if (k && strcmp(k, key) == 0) {
                self->fields[key_idx] = DX_NULL_VALUE;
                self->fields[key_idx + 1] = DX_NULL_VALUE;
                int count_idx = DX_CV_MAX_ENTRIES * 2;
                if (self->fields[count_idx].i > 0)
                    self->fields[count_idx] = DX_INT_VALUE(self->fields[count_idx].i - 1);
                break;
            }
        }
    }
    return DX_OK;
}

static DxResult native_cv_clear(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields) return DX_OK;
    for (int i = 0; i < DX_CV_MAX_ENTRIES * 2; i++) {
        self->fields[i] = DX_NULL_VALUE;
    }
    self->fields[DX_CV_MAX_ENTRIES * 2] = DX_INT_VALUE(0);
    return DX_OK;
}

static DxResult native_cv_size(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int count = 0;
    if (self && self->fields)
        count = self->fields[DX_CV_MAX_ENTRIES * 2].i;
    frame->result = DX_INT_VALUE(count);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cv_key_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *list_cls = dx_vm_find_class(vm, "Ljava/util/ArrayList;");
    if (!list_cls || !self || !self->fields) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *list = dx_vm_alloc_object(vm, list_cls);
    if (!list) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxMethod *add_m = dx_vm_find_method(list_cls, "add", "ZL");
    if (add_m) {
        for (int i = 0; i < DX_CV_MAX_ENTRIES; i++) {
            int key_idx = i * 2;
            if (self->fields[key_idx].tag == DX_VAL_OBJ && self->fields[key_idx].obj) {
                DxValue add_args[2] = { DX_OBJ_VALUE(list), self->fields[key_idx] };
                dx_vm_execute_method(vm, add_m, add_args, 2, NULL);
            }
        }
    }
    frame->result = DX_OBJ_VALUE(list);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Enhanced SQLiteDatabase native methods
// ============================================================
// SQLiteDatabase field layout:
//   field[0] = version (int)
//   field[1] = next_row_id (long, incrementing counter)
//   field[2] = is_open (int, boolean)

#define DX_SQLITE_FIELD_COUNT 3

static DxResult native_sqlite_db_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields) {
        self->fields[0] = DX_INT_VALUE(0);   // version
        self->fields[1] = (DxValue){.tag = DX_VAL_LONG, .l = 1}; // next_row_id
        self->fields[2] = DX_INT_VALUE(1);   // is_open
    }
    return DX_OK;
}

static DxResult native_sqlite_insert(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *table = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        table = dx_vm_get_string_value(args[1].obj);
    int64_t row_id = 1;
    if (self && self->fields) {
        row_id = self->fields[1].l;
        self->fields[1] = (DxValue){.tag = DX_VAL_LONG, .l = row_id + 1};
    }
    DX_INFO(TAG, "SQLiteDatabase.insert(table=%s) -> rowId=%lld",
            table ? table : "?", (long long)row_id);
    frame->result = (DxValue){.tag = DX_VAL_LONG, .l = row_id};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_sqlite_update(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *table = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        table = dx_vm_get_string_value(args[1].obj);
    DX_INFO(TAG, "SQLiteDatabase.update(table=%s) -> 0 rows", table ? table : "?");
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_sqlite_delete(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *table = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        table = dx_vm_get_string_value(args[1].obj);
    DX_INFO(TAG, "SQLiteDatabase.delete(table=%s) -> 0 rows", table ? table : "?");
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_sqlite_exec_sql(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    const char *sql = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        sql = dx_vm_get_string_value(args[1].obj);
    DX_INFO(TAG, "SQLiteDatabase.execSQL: %s", sql ? sql : "(null)");
    return DX_OK;
}

static DxResult native_sqlite_get_version(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int ver = 0;
    if (self && self->fields) ver = self->fields[0].i;
    frame->result = DX_INT_VALUE(ver);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_sqlite_set_version(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && arg_count >= 2) {
        self->fields[0] = args[1];
        DX_INFO(TAG, "SQLiteDatabase.setVersion(%d)", args[1].i);
    }
    return DX_OK;
}

static DxResult native_sqlite_is_open(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int open = 1;
    if (self && self->fields) open = self->fields[2].i;
    frame->result = DX_INT_VALUE(open);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_sqlite_close(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields) self->fields[2] = DX_INT_VALUE(0);
    DX_INFO(TAG, "SQLiteDatabase.close()");
    return DX_OK;
}

// Enhanced Cursor with position tracking
// Cursor field layout: field[0] = position (int, starts at -1)
#define DX_CURSOR_FIELD_COUNT 1

static DxResult native_cursor_init_fields(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields) {
        self->fields[0] = DX_INT_VALUE(-1); // position before first
    }
    return DX_OK;
}

// Enhanced sqlite_return_empty_cursor: returns Cursor with initialized fields
static DxResult native_sqlite_return_empty_cursor_v2(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *cursor_cls = dx_vm_find_class(vm, "Landroid/database/Cursor;");
    if (cursor_cls) {
        DxObject *obj = dx_vm_alloc_object(vm, cursor_cls);
        if (obj && obj->fields) {
            obj->fields[0] = DX_INT_VALUE(-1);
        }
        frame->result = obj ? DX_OBJ_VALUE(obj) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Enhanced sqlite_return_stub_db: returns SQLiteDatabase with initialized fields
static DxResult native_sqlite_return_stub_db_v2(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *db_cls = dx_vm_find_class(vm, "Landroid/database/sqlite/SQLiteDatabase;");
    if (db_cls) {
        DxObject *obj = dx_vm_alloc_object(vm, db_cls);
        if (obj && obj->fields) {
            obj->fields[0] = DX_INT_VALUE(0);   // version
            obj->fields[1] = (DxValue){.tag = DX_VAL_LONG, .l = 1}; // next_row_id
            obj->fields[2] = DX_INT_VALUE(1);   // is_open
        }
        frame->result = obj ? DX_OBJ_VALUE(obj) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Cursor getString returns empty string instead of null for robustness
static DxResult native_cursor_get_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *s = dx_vm_create_string(vm, "");
    frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Room database builder native methods
// ============================================================
// RoomDatabase$Builder field layout:
//   field[0] = context object
//   field[1] = database class name (string)
//   field[2] = database name (string)

#define DX_ROOM_BUILDER_FIELD_COUNT 3

static DxResult native_room_database_builder(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxClass *builder_cls = dx_vm_find_class(vm, "Landroidx/room/RoomDatabase$Builder;");
    if (!builder_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *builder = dx_vm_alloc_object(vm, builder_cls);
    if (builder && builder->fields) {
        if (arg_count > 1) builder->fields[0] = args[1]; // context
        if (arg_count > 2) builder->fields[1] = args[2]; // class
        if (arg_count > 3) builder->fields[2] = args[3]; // db name
    }
    DX_INFO(TAG, "Room.databaseBuilder() called");
    frame->result = builder ? DX_OBJ_VALUE(builder) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_room_builder_build(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    // Try to find the database class from field[1] and instantiate it
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *room_db_cls = dx_vm_find_class(vm, "Landroidx/room/RoomDatabase;");
    if (room_db_cls) {
        DxObject *db = dx_vm_alloc_object(vm, room_db_cls);
        DX_INFO(TAG, "RoomDatabase$Builder.build() -> RoomDatabase instance");
        frame->result = db ? DX_OBJ_VALUE(db) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    (void)self;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Internal helper: launch a target activity from an Intent.
// request_code: -1 for plain startActivity, >= 0 for startActivityForResult.
// ============================================================
static DxResult start_activity_internal(DxVM *vm, DxObject *caller, DxObject *intent, int32_t request_code) {
    (void)caller;
    // Extract target class descriptor from intent field[1]
    const char *target_desc = NULL;
    if (intent->fields && intent->klass &&
        intent->klass->instance_field_count > DX_INTENT_FIELD_TARGET_CLASS &&
        intent->fields[DX_INTENT_FIELD_TARGET_CLASS].tag == DX_VAL_OBJ &&
        intent->fields[DX_INTENT_FIELD_TARGET_CLASS].obj) {
        target_desc = dx_vm_get_string_value(intent->fields[DX_INTENT_FIELD_TARGET_CLASS].obj);
    }

    if (!target_desc || strlen(target_desc) == 0) {
        DX_INFO(TAG, "startActivity: Intent has no target class, ignoring");
        return DX_OK;
    }

    const char *fn_name = (request_code >= 0) ? "startActivityForResult" : "startActivity";
    DX_INFO(TAG, "%s: navigating to %s (requestCode=%d)", fn_name, target_desc, request_code);

    // Find or load the target class
    DxClass *target_cls = dx_vm_find_class(vm, target_desc);
    if (!target_cls) {
        DxResult res = dx_vm_load_class(vm, target_desc, &target_cls);
        if (res != DX_OK || !target_cls) {
            DX_INFO(TAG, "%s: cannot find/load class %s", fn_name, target_desc);
            return DX_OK;
        }
    }

    // Initialize the class if needed
    DxResult res = dx_vm_init_class(vm, target_cls);
    if (res != DX_OK) {
        DX_INFO(TAG, "%s: class init failed for %s", fn_name, target_desc);
        return DX_OK;
    }

    // Allocate new Activity instance
    DxObject *new_activity = dx_vm_alloc_object(vm, target_cls);
    if (!new_activity) {
        DX_INFO(TAG, "%s: alloc failed for %s", fn_name, target_desc);
        return DX_OK;
    }

    // --- Push the current activity onto the back-stack ---
    DxObject *prev_activity = vm->activity_instance;
    if (prev_activity && vm->activity_stack_depth < DX_MAX_ACTIVITY_STACK) {
        // Call onSaveInstanceState before pausing
        DxObject *saved = call_on_save_instance_state(vm, prev_activity);

        vm->activity_stack[vm->activity_stack_depth].activity     = prev_activity;
        vm->activity_stack[vm->activity_stack_depth].class_name   =
            prev_activity->klass ? prev_activity->klass->descriptor : "?";
        vm->activity_stack[vm->activity_stack_depth].intent       = intent;
        vm->activity_stack[vm->activity_stack_depth].request_code = request_code;
        vm->activity_stack[vm->activity_stack_depth].saved_state  = saved;
        vm->activity_stack_depth++;

        // Call onPause() on the previous activity
        DxMethod *on_pause = dx_vm_find_method(prev_activity->klass, "onPause", "V");
        if (on_pause) {
            DX_INFO(TAG, "%s: calling onPause() on previous activity", fn_name);
            vm->insn_count = 0;
            vm->pending_exception = NULL;
            DxValue pause_args[1] = { DX_OBJ_VALUE(prev_activity) };
            dx_vm_execute_method(vm, on_pause, pause_args, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }

        // Call onStop() on the previous activity (it stays alive on the stack)
        DxMethod *on_stop = dx_vm_find_method(prev_activity->klass, "onStop", "V");
        if (on_stop) {
            DX_INFO(TAG, "%s: calling onStop() on previous activity", fn_name);
            vm->insn_count = 0;
            vm->pending_exception = NULL;
            DxValue stop_args[1] = { DX_OBJ_VALUE(prev_activity) };
            dx_vm_execute_method(vm, on_stop, stop_args, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    } else if (prev_activity && prev_activity->klass) {
        // Stack full -- fall back to destroying the previous activity
        DxMethod *on_pause = dx_vm_find_method(prev_activity->klass, "onPause", "V");
        if (on_pause) {
            vm->insn_count = 0; vm->pending_exception = NULL;
            DxValue a[1] = { DX_OBJ_VALUE(prev_activity) };
            dx_vm_execute_method(vm, on_pause, a, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
        DxMethod *on_stop = dx_vm_find_method(prev_activity->klass, "onStop", "V");
        if (on_stop) {
            vm->insn_count = 0; vm->pending_exception = NULL;
            DxValue a[1] = { DX_OBJ_VALUE(prev_activity) };
            dx_vm_execute_method(vm, on_stop, a, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
        DxMethod *on_destroy = dx_vm_find_method(prev_activity->klass, "onDestroy", "V");
        if (on_destroy) {
            vm->insn_count = 0; vm->pending_exception = NULL;
            DxValue a[1] = { DX_OBJ_VALUE(prev_activity) };
            dx_vm_execute_method(vm, on_destroy, a, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    }

    // Reset result state for the new activity
    vm->activity_result_code = 0;  // RESULT_CANCELED
    vm->activity_result_data = NULL;

    // Update the VM's current activity
    vm->activity_instance = new_activity;

    // Call <init> on the new activity
    DxMethod *init = dx_vm_find_method(target_cls, "<init>", NULL);
    if (init) {
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue init_args[1] = { DX_OBJ_VALUE(new_activity) };
        res = dx_vm_execute_method(vm, init, init_args, 1, NULL);
        if (res == DX_ERR_EXCEPTION) {
            const char *exc_desc = vm->pending_exception && vm->pending_exception->klass
                ? vm->pending_exception->klass->descriptor : "unknown";
            DX_INFO(TAG, "%s: %s.<init> threw %s (absorbed)", fn_name, target_desc, exc_desc);
            vm->pending_exception = NULL;
        } else if (res == DX_ERR_STACK_OVERFLOW || res == DX_ERR_INTERNAL) {
            DX_INFO(TAG, "%s: %s.<init> failed fatally", fn_name, target_desc);
            vm->activity_instance = prev_activity;
            if (vm->activity_stack_depth > 0) vm->activity_stack_depth--;
            return DX_OK;
        }
    }

    // Call onCreate(null) on the new activity
    DxMethod *on_create = dx_vm_find_method(target_cls, "onCreate", NULL);
    if (on_create) {
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue oc_args[2] = { DX_OBJ_VALUE(new_activity), DX_NULL_VALUE };
        res = dx_vm_execute_method(vm, on_create, oc_args, 2, NULL);
        if (res == DX_ERR_EXCEPTION) {
            const char *exc_desc = vm->pending_exception && vm->pending_exception->klass
                ? vm->pending_exception->klass->descriptor : "unknown";
            DX_INFO(TAG, "%s: %s.onCreate threw %s (absorbed)", fn_name, target_desc, exc_desc);
            vm->pending_exception = NULL;
        } else if (res == DX_ERR_STACK_OVERFLOW || res == DX_ERR_INTERNAL) {
            DX_INFO(TAG, "%s: %s.onCreate failed fatally", fn_name, target_desc);
        } else if (res == DX_OK) {
            DX_INFO(TAG, "%s: %s.onCreate completed", fn_name, target_desc);
        }
    }

    // --- Lifecycle: onStart() ---
    DxMethod *on_start = dx_vm_find_method(target_cls, "onStart", "V");
    if (on_start) {
        DX_INFO(TAG, "%s: calling onStart() on %s", fn_name, target_desc);
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue start_args[1] = { DX_OBJ_VALUE(new_activity) };
        dx_vm_execute_method(vm, on_start, start_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    // --- Lifecycle: onResume() ---
    DxMethod *on_resume = dx_vm_find_method(target_cls, "onResume", "V");
    if (on_resume) {
        DX_INFO(TAG, "%s: calling onResume() on %s", fn_name, target_desc);
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue resume_args[1] = { DX_OBJ_VALUE(new_activity) };
        dx_vm_execute_method(vm, on_resume, resume_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    // --- Lifecycle: onPostResume() ---
    DxMethod *on_post_resume = dx_vm_find_method(target_cls, "onPostResume", "V");
    if (on_post_resume) {
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue pr_args[1] = { DX_OBJ_VALUE(new_activity) };
        dx_vm_execute_method(vm, on_post_resume, pr_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    DX_INFO(TAG, "%s: %s launched (lifecycle: onCreate -> onStart -> onResume)", fn_name, target_desc);

    // Rebuild render model to reflect the new activity's UI
    rebuild_render_model(vm);

    return DX_OK;
}

// ============================================================
// Activity.startActivity(Intent)
// ============================================================
static DxResult native_start_activity(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count < 2 || args[1].tag != DX_VAL_OBJ || !args[1].obj) {
        DX_INFO(TAG, "startActivity: null Intent, ignoring");
        return DX_OK;
    }
    return start_activity_internal(vm, args[0].obj, args[1].obj, -1);
}

// ============================================================
// Activity.startActivityForResult(Intent, int requestCode)
// ============================================================
static DxResult native_start_activity_for_result(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count < 3 || args[1].tag != DX_VAL_OBJ || !args[1].obj) {
        DX_INFO(TAG, "startActivityForResult: null Intent, ignoring");
        return DX_OK;
    }
    int32_t request_code = (arg_count >= 3 && args[2].tag == DX_VAL_INT) ? args[2].i : 0;
    return start_activity_internal(vm, args[0].obj, args[1].obj, request_code);
}

// ============================================================
// Activity.setResult(int resultCode) / setResult(int, Intent)
// ============================================================
static DxResult native_activity_set_result(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count >= 2 && args[1].tag == DX_VAL_INT) {
        vm->activity_result_code = args[1].i;
        DX_INFO(TAG, "setResult: resultCode=%d", args[1].i);
    }
    if (arg_count >= 3 && args[2].tag == DX_VAL_OBJ) {
        vm->activity_result_data = args[2].obj;
    }
    return DX_OK;
}

// ============================================================
// Activity.finish() -- pop back-stack and deliver onActivityResult
// ============================================================
static DxResult native_activity_finish(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)args; (void)arg_count;

    DxObject *finishing = vm->activity_instance;
    if (!finishing) return DX_OK;

    const char *fin_desc = finishing->klass ? finishing->klass->descriptor : "?";
    DX_INFO(TAG, "finish: finishing %s", fin_desc);

    // Lifecycle teardown on the finishing activity: onPause -> onStop -> onDestroy
    if (finishing->klass) {
        DxMethod *on_pause = dx_vm_find_method(finishing->klass, "onPause", "V");
        if (on_pause) {
            vm->insn_count = 0; vm->pending_exception = NULL;
            DxValue a[1] = { DX_OBJ_VALUE(finishing) };
            dx_vm_execute_method(vm, on_pause, a, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
        DxMethod *on_stop = dx_vm_find_method(finishing->klass, "onStop", "V");
        if (on_stop) {
            vm->insn_count = 0; vm->pending_exception = NULL;
            DxValue a[1] = { DX_OBJ_VALUE(finishing) };
            dx_vm_execute_method(vm, on_stop, a, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
        DxMethod *on_destroy = dx_vm_find_method(finishing->klass, "onDestroy", "V");
        if (on_destroy) {
            vm->insn_count = 0; vm->pending_exception = NULL;
            DxValue a[1] = { DX_OBJ_VALUE(finishing) };
            dx_vm_execute_method(vm, on_destroy, a, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    }

    // Capture result before popping
    int32_t  result_code = vm->activity_result_code;
    DxObject *result_data = vm->activity_result_data;

    // Pop back-stack
    if (vm->activity_stack_depth > 0) {
        vm->activity_stack_depth--;
        DxObject *prev   = vm->activity_stack[vm->activity_stack_depth].activity;
        int32_t req_code = vm->activity_stack[vm->activity_stack_depth].request_code;
        vm->activity_instance = prev;

        // Reset result state for the resumed activity
        vm->activity_result_code = 0;
        vm->activity_result_data = NULL;

        if (prev && prev->klass) {
            // If the caller used startActivityForResult, deliver onActivityResult
            if (req_code >= 0) {
                DxMethod *on_result = dx_vm_find_method(prev->klass, "onActivityResult", NULL);
                if (on_result) {
                    DX_INFO(TAG, "finish: delivering onActivityResult(requestCode=%d, resultCode=%d) to %s",
                            req_code, result_code, prev->klass->descriptor);
                    vm->insn_count = 0;
                    vm->pending_exception = NULL;
                    DxValue ra[4] = {
                        DX_OBJ_VALUE(prev),
                        DX_INT_VALUE(req_code),
                        DX_INT_VALUE(result_code),
                        result_data ? DX_OBJ_VALUE(result_data) : DX_NULL_VALUE
                    };
                    dx_vm_execute_method(vm, on_result, ra, 4, NULL);
                    if (vm->pending_exception) vm->pending_exception = NULL;
                }
            }

            // Resume the previous activity: onRestart -> onStart -> onResume
            DxMethod *on_restart = dx_vm_find_method(prev->klass, "onRestart", "V");
            if (on_restart) {
                vm->insn_count = 0; vm->pending_exception = NULL;
                DxValue a[1] = { DX_OBJ_VALUE(prev) };
                dx_vm_execute_method(vm, on_restart, a, 1, NULL);
                if (vm->pending_exception) vm->pending_exception = NULL;
            }
            DxMethod *on_start = dx_vm_find_method(prev->klass, "onStart", "V");
            if (on_start) {
                vm->insn_count = 0; vm->pending_exception = NULL;
                DxValue a[1] = { DX_OBJ_VALUE(prev) };
                dx_vm_execute_method(vm, on_start, a, 1, NULL);
                if (vm->pending_exception) vm->pending_exception = NULL;
            }
            DxMethod *on_resume = dx_vm_find_method(prev->klass, "onResume", "V");
            if (on_resume) {
                vm->insn_count = 0; vm->pending_exception = NULL;
                DxValue a[1] = { DX_OBJ_VALUE(prev) };
                dx_vm_execute_method(vm, on_resume, a, 1, NULL);
                if (vm->pending_exception) vm->pending_exception = NULL;
            }

            DX_INFO(TAG, "finish: resumed %s (onRestart -> onStart -> onResume)", prev->klass->descriptor);
        }
    } else {
        // No back-stack -- the last activity is finishing
        vm->activity_instance = NULL;
        DX_INFO(TAG, "finish: back-stack empty, no activity to resume");
    }

    rebuild_render_model(vm);
    return DX_OK;
}

// ============================================================
// Activity.onBackPressed() -- behaves like finish()
// ============================================================
static DxResult native_activity_on_back_pressed(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DX_INFO(TAG, "onBackPressed: delegating to finish()");
    return native_activity_finish(vm, frame, args, arg_count);
}

// ============================================================
// Activity.onSaveInstanceState(Bundle) -- base impl is a no-op
// ============================================================
static DxResult native_activity_on_save_instance_state(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)args; (void)arg_count;
    // Base Activity.onSaveInstanceState does nothing.
    // App subclass overrides this and the interpreter dispatches to the override.
    return DX_OK;
}

// ============================================================
// Activity.onRestoreInstanceState(Bundle) -- base impl is a no-op
// ============================================================
static DxResult native_activity_on_restore_instance_state(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)args; (void)arg_count;
    return DX_OK;
}

// ============================================================
// Activity.onConfigurationChanged(Configuration) -- base impl is a no-op
// ============================================================
static DxResult native_activity_on_config_changed(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)args; (void)arg_count;
    return DX_OK;
}

// ============================================================
// Helper: call onSaveInstanceState on an activity, return the saved Bundle
// ============================================================
static DxObject *call_on_save_instance_state(DxVM *vm, DxObject *activity) {
    if (!activity || !activity->klass) return NULL;

    DxMethod *save = dx_vm_find_method(activity->klass, "onSaveInstanceState", NULL);
    if (!save) return NULL;

    // Create a fresh Bundle for the activity to save into
    DxObject *bundle = dx_vm_alloc_object(vm, vm->class_bundle);
    if (!bundle) return NULL;

    DX_INFO(TAG, "Calling onSaveInstanceState on %s", activity->klass->descriptor);
    vm->insn_count = 0;
    vm->pending_exception = NULL;
    DxValue save_args[2] = { DX_OBJ_VALUE(activity), DX_OBJ_VALUE(bundle) };
    DxResult res = dx_vm_execute_method(vm, save, save_args, 2, NULL);
    if (res == DX_ERR_EXCEPTION) {
        DX_WARN(TAG, "onSaveInstanceState threw %s (absorbed)",
                vm->pending_exception && vm->pending_exception->klass
                ? vm->pending_exception->klass->descriptor : "unknown");
        vm->pending_exception = NULL;
    }
    return bundle;
}

// ============================================================
// Helper: call onRestoreInstanceState on an activity with a saved Bundle
// ============================================================
static void call_on_restore_instance_state(DxVM *vm, DxObject *activity, DxObject *bundle) {
    if (!activity || !activity->klass || !bundle) return;

    DxMethod *restore = dx_vm_find_method(activity->klass, "onRestoreInstanceState", NULL);
    if (!restore) return;

    DX_INFO(TAG, "Calling onRestoreInstanceState on %s", activity->klass->descriptor);
    vm->insn_count = 0;
    vm->pending_exception = NULL;
    DxValue args[2] = { DX_OBJ_VALUE(activity), DX_OBJ_VALUE(bundle) };
    DxResult res = dx_vm_execute_method(vm, restore, args, 2, NULL);
    if (res == DX_ERR_EXCEPTION) {
        DX_WARN(TAG, "onRestoreInstanceState threw %s (absorbed)",
                vm->pending_exception && vm->pending_exception->klass
                ? vm->pending_exception->klass->descriptor : "unknown");
        vm->pending_exception = NULL;
    }
}

// ============================================================
// Activity.recreate() -- save state, destroy, recreate with saved Bundle
// ============================================================
static DxResult native_activity_recreate(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *activity = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!activity || !activity->klass) return DX_OK;

    const char *desc = activity->klass->descriptor;
    DxClass *cls = activity->klass;
    DX_INFO(TAG, "recreate: recreating %s", desc);

    // 1. onSaveInstanceState
    DxObject *saved_bundle = call_on_save_instance_state(vm, activity);

    // 2. Lifecycle teardown: onPause -> onStop -> onDestroy
    DxMethod *on_pause = dx_vm_find_method(cls, "onPause", "V");
    if (on_pause) {
        vm->insn_count = 0; vm->pending_exception = NULL;
        DxValue a[1] = { DX_OBJ_VALUE(activity) };
        dx_vm_execute_method(vm, on_pause, a, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }
    DxMethod *on_stop = dx_vm_find_method(cls, "onStop", "V");
    if (on_stop) {
        vm->insn_count = 0; vm->pending_exception = NULL;
        DxValue a[1] = { DX_OBJ_VALUE(activity) };
        dx_vm_execute_method(vm, on_stop, a, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }
    DxMethod *on_destroy = dx_vm_find_method(cls, "onDestroy", "V");
    if (on_destroy) {
        vm->insn_count = 0; vm->pending_exception = NULL;
        DxValue a[1] = { DX_OBJ_VALUE(activity) };
        dx_vm_execute_method(vm, on_destroy, a, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    // 3. Create new instance
    DxObject *new_activity = dx_vm_alloc_object(vm, cls);
    if (!new_activity) return DX_OK;
    vm->activity_instance = new_activity;

    // 4. Call <init>
    DxMethod *init = dx_vm_find_method(cls, "<init>", NULL);
    if (init) {
        vm->insn_count = 0; vm->pending_exception = NULL;
        DxValue init_args[1] = { DX_OBJ_VALUE(new_activity) };
        DxResult res = dx_vm_execute_method(vm, init, init_args, 1, NULL);
        if (res == DX_ERR_EXCEPTION) { vm->pending_exception = NULL; }
        else if (res == DX_ERR_STACK_OVERFLOW || res == DX_ERR_INTERNAL) {
            return DX_OK;
        }
    }

    // 5. onCreate(savedBundle)
    DxMethod *on_create = dx_vm_find_method(cls, "onCreate", NULL);
    if (on_create) {
        vm->insn_count = 0; vm->pending_exception = NULL;
        DxValue oc_args[2] = {
            DX_OBJ_VALUE(new_activity),
            saved_bundle ? DX_OBJ_VALUE(saved_bundle) : DX_NULL_VALUE
        };
        DxResult res = dx_vm_execute_method(vm, on_create, oc_args, 2, NULL);
        if (res == DX_ERR_EXCEPTION) { vm->pending_exception = NULL; }
    }

    // 6. onRestoreInstanceState(savedBundle)
    if (saved_bundle) {
        call_on_restore_instance_state(vm, new_activity, saved_bundle);
    }

    // 7. onStart -> onResume
    DxMethod *on_start = dx_vm_find_method(cls, "onStart", "V");
    if (on_start) {
        vm->insn_count = 0; vm->pending_exception = NULL;
        DxValue a[1] = { DX_OBJ_VALUE(new_activity) };
        dx_vm_execute_method(vm, on_start, a, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }
    DxMethod *on_resume = dx_vm_find_method(cls, "onResume", "V");
    if (on_resume) {
        vm->insn_count = 0; vm->pending_exception = NULL;
        DxValue a[1] = { DX_OBJ_VALUE(new_activity) };
        dx_vm_execute_method(vm, on_resume, a, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    DX_INFO(TAG, "recreate: %s recreated (lifecycle: onSaveInstanceState -> onDestroy -> onCreate -> onRestoreInstanceState -> onStart -> onResume)", desc);
    rebuild_render_model(vm);
    return DX_OK;
}

// ============================================================
// Activity.getIntent() -- return the Intent that launched this activity
// ============================================================
static DxResult native_activity_get_intent(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;

    // If self is the current activity, the launching intent is at stack[depth-1]
    if (self && self == vm->activity_instance && vm->activity_stack_depth > 0) {
        DxObject *launching_intent = vm->activity_stack[vm->activity_stack_depth - 1].intent;
        if (launching_intent) {
            frame->result = DX_OBJ_VALUE(launching_intent);
            frame->has_result = true;
            return DX_OK;
        }
    }

    // Fallback: return a fresh empty Intent
    DxClass *intent_cls = vm->class_intent;
    if (intent_cls) {
        DxObject *intent = dx_vm_alloc_object(vm, intent_cls);
        if (intent) {
            frame->result = DX_OBJ_VALUE(intent);
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Activity.setIntent(Intent)
// ============================================================
static DxResult native_activity_set_intent(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    // Store the intent in the top of the back-stack for getIntent() to find
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && vm->activity_stack_depth > 0) {
        vm->activity_stack[vm->activity_stack_depth - 1].intent = args[1].obj;
    }
    return DX_OK;
}

// ============================================================
// Activity.onActivityResult(int, int, Intent) -- no-op base impl
// ============================================================
static DxResult native_activity_on_activity_result(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)args; (void)arg_count;
    // Base Activity.onActivityResult is a no-op; DEX subclasses override this
    return DX_OK;
}

// ============================================================
// Generic no-op / return-self / return-null helpers
// ============================================================

static DxResult native_noop(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)args; (void)arg_count;
    return DX_OK;
}

static DxResult native_system_loadlibrary_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    const char *lib_name = "(unknown)";
    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        const char *s = dx_vm_get_string_value(args[0].obj);
        if (s) lib_name = s;
    }
    char feat_buf[160];
    snprintf(feat_buf, sizeof(feat_buf), "System.loadLibrary(\"%s\") — native .so loading unsupported", lib_name);
    dx_vm_report_missing_feature(vm, feat_buf);
    return DX_OK;
}

static DxResult native_return_null(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_self(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    frame->result = DX_OBJ_VALUE(args[0].obj);
    frame->has_result = true;
    return DX_OK;
}

// For static methods that return their first argument (pass-through wrappers)
static DxResult native_return_arg0(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    frame->result = args[0];
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_false(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_true(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(1);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_int_zero(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

// Run Runnable arg[1] synchronously, return self (arg[0]) – for withStartAction/withEndAction
static DxResult native_run_runnable_return_self(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxObject *runnable = args[1].obj;
        DxMethod *run_method = dx_vm_find_method(runnable->klass, "run", NULL);
        if (run_method) {
            DxValue run_args[1] = { DX_OBJ_VALUE(runnable) };
            dx_vm_execute_method(vm, run_method, run_args, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    }
    frame->result = DX_OBJ_VALUE(args[0].obj);
    frame->has_result = true;
    return DX_OK;
}

// --- Real Iterator implementation for ArrayList iteration ---
// Iterator stores _list (ref to ArrayList) and _index (current position)

static DxResult native_iterator_hasnext(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }
    // Get the backing ArrayList
    DxValue list_val;
    if (dx_vm_get_field(self, "_list", &list_val) != DX_OK || list_val.tag != DX_VAL_OBJ || !list_val.obj) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }
    // Get the ArrayList's _size
    DxValue size_val;
    int32_t size = 0;
    if (dx_vm_get_field(list_val.obj, "_size", &size_val) == DX_OK && size_val.tag == DX_VAL_INT) {
        size = size_val.i;
    }
    // Get iterator's current _index
    DxValue idx_val;
    int32_t idx = 0;
    if (dx_vm_get_field(self, "_index", &idx_val) == DX_OK && idx_val.tag == DX_VAL_INT) {
        idx = idx_val.i;
    }
    frame->result = DX_INT_VALUE(idx < size ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_iterator_next(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    // Get the backing ArrayList
    DxValue list_val;
    if (dx_vm_get_field(self, "_list", &list_val) != DX_OK || list_val.tag != DX_VAL_OBJ || !list_val.obj) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *list = list_val.obj;
    // Get the ArrayList's _items array
    DxValue items_val;
    if (dx_vm_get_field(list, "_items", &items_val) != DX_OK || items_val.tag != DX_VAL_OBJ || !items_val.obj || !items_val.obj->is_array) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *items = items_val.obj;
    // Get iterator's current _index
    DxValue idx_val;
    int32_t idx = 0;
    if (dx_vm_get_field(self, "_index", &idx_val) == DX_OK && idx_val.tag == DX_VAL_INT) {
        idx = idx_val.i;
    }
    // Bounds check
    if (idx < 0 || (uint32_t)idx >= items->array_length || !items->array_elements) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    // Read the element at current index
    frame->result = items->array_elements[idx];
    frame->has_result = true;
    // Increment the index
    dx_vm_set_field(self, "_index", DX_INT_VALUE(idx + 1));
    return DX_OK;
}

// --- Boxed type valueOf: Integer.valueOf(int), Long.valueOf(long), etc. ---
// Creates an object of the boxed type with field[0] = the value
static DxResult native_box_helper(DxVM *vm, DxFrame *frame, const char *desc, DxValue val) {
    DxClass *cls = dx_vm_find_class(vm, desc);
    if (!cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *obj = dx_vm_alloc_object(vm, cls);
    if (!obj) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    if (obj->fields && cls->instance_field_count > 0) {
        obj->fields[0] = val;
    }
    frame->result = DX_OBJ_VALUE(obj);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_integer_valueOf(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    int32_t val = (arg_count >= 1) ? args[0].i : 0;
    return native_box_helper(vm, frame, "Ljava/lang/Integer;", DX_INT_VALUE(val));
}

static DxResult native_long_valueOf(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    int32_t val = (arg_count >= 1) ? args[0].i : 0;
    return native_box_helper(vm, frame, "Ljava/lang/Long;", DX_INT_VALUE(val));
}

static DxResult native_float_valueOf(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    float val = (arg_count >= 1) ? args[0].f : 0.0f;
    DxValue v; v.tag = DX_VAL_FLOAT; v.f = val;
    return native_box_helper(vm, frame, "Ljava/lang/Float;", v);
}

static DxResult native_double_valueOf(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    double val = (arg_count >= 1) ? args[0].d : 0.0;
    DxValue v; v.tag = DX_VAL_DOUBLE; v.d = val;
    return native_box_helper(vm, frame, "Ljava/lang/Double;", v);
}

static DxResult native_boolean_valueOf(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    int32_t val = (arg_count >= 1) ? args[0].i : 0;
    return native_box_helper(vm, frame, "Ljava/lang/Boolean;", DX_INT_VALUE(val));
}

static DxResult native_byte_valueOf(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    int32_t val = (arg_count >= 1) ? args[0].i : 0;
    return native_box_helper(vm, frame, "Ljava/lang/Byte;", DX_INT_VALUE(val));
}

static DxResult native_short_valueOf(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    int32_t val = (arg_count >= 1) ? args[0].i : 0;
    return native_box_helper(vm, frame, "Ljava/lang/Short;", DX_INT_VALUE(val));
}

static DxResult native_char_valueOf(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    int32_t val = (arg_count >= 1) ? args[0].i : 0;
    return native_box_helper(vm, frame, "Ljava/lang/Character;", DX_INT_VALUE(val));
}

// Unboxing: intValue/longValue/floatValue/doubleValue/booleanValue return field[0]
static DxResult native_unbox_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_unbox_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        DxValue z; z.tag = DX_VAL_FLOAT; z.f = 0.0f;
        frame->result = z;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_unbox_double(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        DxValue z; z.tag = DX_VAL_DOUBLE; z.d = 0.0;
        frame->result = z;
    }
    frame->has_result = true;
    return DX_OK;
}

// --- Parsing methods: parseInt, parseLong, parseFloat, parseDouble ---
static DxResult native_parse_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *s = NULL;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        s = dx_vm_get_string_value(args[0].obj);
    }
    int32_t val = s ? (int32_t)strtol(s, NULL, 10) : 0;
    frame->result = DX_INT_VALUE(val);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_parse_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *s = NULL;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        s = dx_vm_get_string_value(args[0].obj);
    }
    int64_t val = s ? strtoll(s, NULL, 10) : 0;
    frame->result.tag = DX_VAL_LONG;
    frame->result.l = val;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_parse_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *s = NULL;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        s = dx_vm_get_string_value(args[0].obj);
    }
    float val = s ? strtof(s, NULL) : 0.0f;
    frame->result.tag = DX_VAL_FLOAT;
    frame->result.f = val;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_parse_double(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *s = NULL;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        s = dx_vm_get_string_value(args[0].obj);
    }
    double val = s ? strtod(s, NULL) : 0.0;
    frame->result.tag = DX_VAL_DOUBLE;
    frame->result.d = val;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_parse_boolean(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *s = NULL;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        s = dx_vm_get_string_value(args[0].obj);
    }
    int32_t val = (s && strcasecmp(s, "true") == 0) ? 1 : 0;
    frame->result = DX_INT_VALUE(val);
    frame->has_result = true;
    return DX_OK;
}

// Instance toString for boxed types: reads field[0] and converts to string
static DxResult native_boxed_tostring(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    char buf[64];
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        DxValue v = self->fields[0];
        if (v.tag == DX_VAL_FLOAT) {
            snprintf(buf, sizeof(buf), "%g", (double)v.f);
        } else if (v.tag == DX_VAL_DOUBLE) {
            snprintf(buf, sizeof(buf), "%g", v.d);
        } else {
            snprintf(buf, sizeof(buf), "%d", v.i);
        }
    } else {
        snprintf(buf, sizeof(buf), "0");
    }
    DxObject *result = dx_vm_create_string(vm, buf);
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_new_object(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *obj = dx_vm_alloc_object(vm, vm->class_object);
    frame->result = obj ? DX_OBJ_VALUE(obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_int_neg_one(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(-1);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_int_100(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(100);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_int_one(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(1);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_int_1000(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(1000);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_int_10000(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(10000);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_int_200(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(200);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_int_10(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(10);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_int_15(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(15);
    frame->has_result = true;
    return DX_OK;
}

// MediaPlayer.create(Context, int) → allocate MediaPlayer and return it
static DxResult native_mediaplayer_create(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *mp_cls = dx_vm_find_class(vm, "Landroid/media/MediaPlayer;");
    if (!mp_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *mp = dx_vm_alloc_object(vm, mp_cls);
    frame->result = mp ? DX_OBJ_VALUE(mp) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// SoundPool.load() → return sound ID 1
static DxResult native_soundpool_load(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(1);
    frame->has_result = true;
    return DX_OK;
}

// SoundPool.play() → return stream ID 1
static DxResult native_soundpool_play(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(1);
    frame->has_result = true;
    return DX_OK;
}

// SoundPool.Builder.build() → allocate SoundPool and return it
static DxResult native_soundpool_builder_build(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *sp_cls = dx_vm_find_class(vm, "Landroid/media/SoundPool;");
    if (!sp_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *sp = dx_vm_alloc_object(vm, sp_cls);
    frame->result = sp ? DX_OBJ_VALUE(sp) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// AudioAttributes.Builder.build() → allocate AudioAttributes and return it
static DxResult native_audio_attr_builder_build(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *aa_cls = dx_vm_find_class(vm, "Landroid/media/AudioAttributes;");
    if (!aa_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *aa = dx_vm_alloc_object(vm, aa_cls);
    frame->result = aa ? DX_OBJ_VALUE(aa) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// RingtoneManager.getRingtone(Context, Uri) → allocate Ringtone and return it
static DxResult native_ringtone_manager_get_ringtone(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *rt_cls = dx_vm_find_class(vm, "Landroid/media/Ringtone;");
    if (!rt_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *rt = dx_vm_alloc_object(vm, rt_cls);
    frame->result = rt ? DX_OBJ_VALUE(rt) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// RingtoneManager.getDefaultUri(int) → return a Uri object
static DxResult native_ringtone_manager_get_default_uri(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *uri_cls = dx_vm_find_class(vm, "Landroid/net/Uri;");
    if (!uri_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *uri = dx_vm_alloc_object(vm, uri_cls);
    frame->result = uri ? DX_OBJ_VALUE(uri) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// AudioManager.requestAudioFocus → return AUDIOFOCUS_REQUEST_GRANTED (1)
static DxResult native_audio_focus_granted(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(1); // AUDIOFOCUS_REQUEST_GRANTED
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_empty_json_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *s = dx_vm_create_string(vm, "{}");
    frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_long_zero(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = (DxValue){.tag = DX_VAL_LONG, .l = 0};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_last_int_arg(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    if (arg_count > 0) {
        frame->result = args[arg_count - 1];
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

// native_sqlite_return_empty_cursor and native_sqlite_return_stub_db removed
// (superseded by native_sqlite_return_empty_cursor_v2 and native_sqlite_return_stub_db_v2)

// native_paint_get_text_size and native_paint_measure_text removed
// (superseded by native_paint_getTextSize_fb and native_paint_measureText_fb)

// ============================================================
// android.graphics — Color, Rect, RectF, Point, PointF, Paint
// ============================================================

// --- android.graphics.Color ---

static DxResult native_color_parse(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    int32_t color = (int32_t)0xFF000000u; // default opaque black
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        const char *str = dx_vm_get_string_value(args[0].obj);
        if (str && str[0] == '#') {
            size_t len = strlen(str + 1);
            uint32_t val = (uint32_t)strtoul(str + 1, NULL, 16);
            if (len == 6) {
                color = (int32_t)(0xFF000000u | val);
            } else if (len == 8) {
                color = (int32_t)val;
            }
        }
    }
    frame->result = DX_INT_VALUE(color);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_color_rgb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    int r = (arg_count > 0) ? args[0].i & 0xFF : 0;
    int g = (arg_count > 1) ? args[1].i & 0xFF : 0;
    int b = (arg_count > 2) ? args[2].i & 0xFF : 0;
    int32_t color = (int32_t)(0xFF000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b);
    frame->result = DX_INT_VALUE(color);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_color_argb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    int a = (arg_count > 0) ? args[0].i & 0xFF : 0xFF;
    int r = (arg_count > 1) ? args[1].i & 0xFF : 0;
    int g = (arg_count > 2) ? args[2].i & 0xFF : 0;
    int b = (arg_count > 3) ? args[3].i & 0xFF : 0;
    int32_t color = (int32_t)(((uint32_t)a << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b);
    frame->result = DX_INT_VALUE(color);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_color_red(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    int32_t c = (arg_count > 0) ? args[0].i : 0;
    frame->result = DX_INT_VALUE((c >> 16) & 0xFF);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_color_green(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    int32_t c = (arg_count > 0) ? args[0].i : 0;
    frame->result = DX_INT_VALUE((c >> 8) & 0xFF);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_color_blue(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    int32_t c = (arg_count > 0) ? args[0].i : 0;
    frame->result = DX_INT_VALUE(c & 0xFF);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_color_alpha_extract(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    int32_t c = (arg_count > 0) ? args[0].i : 0;
    frame->result = DX_INT_VALUE((c >> 24) & 0xFF);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_color_valueof_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxClass *cls = dx_vm_find_class(vm, "Landroid/graphics/Color;");
    DxObject *obj = cls ? dx_vm_alloc_object(vm, cls) : NULL;
    if (obj && obj->fields && cls->instance_field_count > 0) {
        obj->fields[0] = (arg_count > 0) ? args[0] : DX_INT_VALUE(0);
    }
    frame->result = obj ? DX_OBJ_VALUE(obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_color_valueof_floats(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    float r = (arg_count > 0) ? args[0].f : 0.0f;
    float g = (arg_count > 1) ? args[1].f : 0.0f;
    float b = (arg_count > 2) ? args[2].f : 0.0f;
    float a = (arg_count > 3) ? args[3].f : 1.0f;
    int ai = (int)(a * 255) & 0xFF;
    int ri = (int)(r * 255) & 0xFF;
    int gi = (int)(g * 255) & 0xFF;
    int bi = (int)(b * 255) & 0xFF;
    int32_t color = (int32_t)(((uint32_t)ai << 24) | ((uint32_t)ri << 16) | ((uint32_t)gi << 8) | (uint32_t)bi);
    DxClass *cls = dx_vm_find_class(vm, "Landroid/graphics/Color;");
    DxObject *obj = cls ? dx_vm_alloc_object(vm, cls) : NULL;
    if (obj && obj->fields && cls->instance_field_count > 0) {
        obj->fields[0] = DX_INT_VALUE(color);
    }
    frame->result = obj ? DX_OBJ_VALUE(obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- android.graphics.Rect (field-backed: left=0, top=1, right=2, bottom=3) ---

#define RECT_FIELD_LEFT   0
#define RECT_FIELD_TOP    1
#define RECT_FIELD_RIGHT  2
#define RECT_FIELD_BOTTOM 3
#define RECT_FIELD_COUNT  4

static DxResult native_rect_init4(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        self->fields[RECT_FIELD_LEFT]   = (arg_count > 1) ? args[1] : DX_INT_VALUE(0);
        self->fields[RECT_FIELD_TOP]    = (arg_count > 2) ? args[2] : DX_INT_VALUE(0);
        self->fields[RECT_FIELD_RIGHT]  = (arg_count > 3) ? args[3] : DX_INT_VALUE(0);
        self->fields[RECT_FIELD_BOTTOM] = (arg_count > 4) ? args[4] : DX_INT_VALUE(0);
    }
    return DX_OK;
}

static DxResult native_rect_width(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int w = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        w = self->fields[RECT_FIELD_RIGHT].i - self->fields[RECT_FIELD_LEFT].i;
    }
    frame->result = DX_INT_VALUE(w);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rect_height(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int h = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        h = self->fields[RECT_FIELD_BOTTOM].i - self->fields[RECT_FIELD_TOP].i;
    }
    frame->result = DX_INT_VALUE(h);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rect_centerX(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int cx = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        cx = (self->fields[RECT_FIELD_LEFT].i + self->fields[RECT_FIELD_RIGHT].i) / 2;
    }
    frame->result = DX_INT_VALUE(cx);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rect_centerY(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int cy = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        cy = (self->fields[RECT_FIELD_TOP].i + self->fields[RECT_FIELD_BOTTOM].i) / 2;
    }
    frame->result = DX_INT_VALUE(cy);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rect_contains_xy(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    int contained = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT && arg_count >= 3) {
        int x = args[1].i, y = args[2].i;
        int l = self->fields[RECT_FIELD_LEFT].i;
        int t = self->fields[RECT_FIELD_TOP].i;
        int r = self->fields[RECT_FIELD_RIGHT].i;
        int b = self->fields[RECT_FIELD_BOTTOM].i;
        contained = (x >= l && x < r && y >= t && y < b) ? 1 : 0;
    }
    frame->result = DX_INT_VALUE(contained);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rect_set4(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        self->fields[RECT_FIELD_LEFT]   = (arg_count > 1) ? args[1] : DX_INT_VALUE(0);
        self->fields[RECT_FIELD_TOP]    = (arg_count > 2) ? args[2] : DX_INT_VALUE(0);
        self->fields[RECT_FIELD_RIGHT]  = (arg_count > 3) ? args[3] : DX_INT_VALUE(0);
        self->fields[RECT_FIELD_BOTTOM] = (arg_count > 4) ? args[4] : DX_INT_VALUE(0);
    }
    return DX_OK;
}

static DxResult native_rect_isEmpty(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int empty = 1;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        int w = self->fields[RECT_FIELD_RIGHT].i - self->fields[RECT_FIELD_LEFT].i;
        int h = self->fields[RECT_FIELD_BOTTOM].i - self->fields[RECT_FIELD_TOP].i;
        empty = (w <= 0 || h <= 0) ? 1 : 0;
    }
    frame->result = DX_INT_VALUE(empty);
    frame->has_result = true;
    return DX_OK;
}

// --- android.graphics.RectF (field-backed: left=0, top=1, right=2, bottom=3, float) ---

static DxResult native_rectf_init4(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        self->fields[RECT_FIELD_LEFT]   = (arg_count > 1) ? args[1] : (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
        self->fields[RECT_FIELD_TOP]    = (arg_count > 2) ? args[2] : (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
        self->fields[RECT_FIELD_RIGHT]  = (arg_count > 3) ? args[3] : (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
        self->fields[RECT_FIELD_BOTTOM] = (arg_count > 4) ? args[4] : (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
    }
    return DX_OK;
}

static DxResult native_rectf_width(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    float w = 0.0f;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        w = self->fields[RECT_FIELD_RIGHT].f - self->fields[RECT_FIELD_LEFT].f;
    }
    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = w};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rectf_height(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    float h = 0.0f;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        h = self->fields[RECT_FIELD_BOTTOM].f - self->fields[RECT_FIELD_TOP].f;
    }
    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = h};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rectf_centerX(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    float cx = 0.0f;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        cx = (self->fields[RECT_FIELD_LEFT].f + self->fields[RECT_FIELD_RIGHT].f) / 2.0f;
    }
    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = cx};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rectf_centerY(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    float cy = 0.0f;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        cy = (self->fields[RECT_FIELD_TOP].f + self->fields[RECT_FIELD_BOTTOM].f) / 2.0f;
    }
    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = cy};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rectf_contains_xy(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    int contained = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT && arg_count >= 3) {
        float x = args[1].f, y = args[2].f;
        float l = self->fields[RECT_FIELD_LEFT].f;
        float t = self->fields[RECT_FIELD_TOP].f;
        float r = self->fields[RECT_FIELD_RIGHT].f;
        float b = self->fields[RECT_FIELD_BOTTOM].f;
        contained = (x >= l && x < r && y >= t && y < b) ? 1 : 0;
    }
    frame->result = DX_INT_VALUE(contained);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_rectf_isEmpty(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int empty = 1;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= RECT_FIELD_COUNT) {
        float w = self->fields[RECT_FIELD_RIGHT].f - self->fields[RECT_FIELD_LEFT].f;
        float h = self->fields[RECT_FIELD_BOTTOM].f - self->fields[RECT_FIELD_TOP].f;
        empty = (w <= 0.0f || h <= 0.0f) ? 1 : 0;
    }
    frame->result = DX_INT_VALUE(empty);
    frame->has_result = true;
    return DX_OK;
}

// --- android.graphics.Point / PointF (field-backed: x=0, y=1) ---

#define POINT_FIELD_X 0
#define POINT_FIELD_Y 1
#define POINT_FIELD_COUNT 2

static DxResult native_point_init2(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= POINT_FIELD_COUNT) {
        self->fields[POINT_FIELD_X] = (arg_count > 1) ? args[1] : DX_INT_VALUE(0);
        self->fields[POINT_FIELD_Y] = (arg_count > 2) ? args[2] : DX_INT_VALUE(0);
    }
    return DX_OK;
}

static DxResult native_point_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= POINT_FIELD_COUNT) {
        self->fields[POINT_FIELD_X] = (arg_count > 1) ? args[1] : DX_INT_VALUE(0);
        self->fields[POINT_FIELD_Y] = (arg_count > 2) ? args[2] : DX_INT_VALUE(0);
    }
    return DX_OK;
}

static DxResult native_point_equals(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    DxObject *other = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    int eq = 0;
    if (self && other && self->fields && other->fields &&
        self->klass && self->klass->instance_field_count >= POINT_FIELD_COUNT &&
        other->klass && other->klass->instance_field_count >= POINT_FIELD_COUNT) {
        eq = (self->fields[0].i == other->fields[0].i &&
              self->fields[1].i == other->fields[1].i) ? 1 : 0;
    }
    frame->result = DX_INT_VALUE(eq);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_point_toString(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    char buf[64];
    if (self && self->fields && self->klass && self->klass->instance_field_count >= POINT_FIELD_COUNT) {
        snprintf(buf, sizeof(buf), "Point(%d, %d)", self->fields[0].i, self->fields[1].i);
    } else {
        snprintf(buf, sizeof(buf), "Point(0, 0)");
    }
    DxObject *str = dx_vm_create_string(vm, buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_pointf_init2(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= POINT_FIELD_COUNT) {
        self->fields[POINT_FIELD_X] = (arg_count > 1) ? args[1] : (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
        self->fields[POINT_FIELD_Y] = (arg_count > 2) ? args[2] : (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
    }
    return DX_OK;
}

static DxResult native_pointf_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= POINT_FIELD_COUNT) {
        self->fields[POINT_FIELD_X] = (arg_count > 1) ? args[1] : (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
        self->fields[POINT_FIELD_Y] = (arg_count > 2) ? args[2] : (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
    }
    return DX_OK;
}

static DxResult native_pointf_toString(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    char buf[64];
    if (self && self->fields && self->klass && self->klass->instance_field_count >= POINT_FIELD_COUNT) {
        snprintf(buf, sizeof(buf), "PointF(%.1f, %.1f)", (double)self->fields[0].f, (double)self->fields[1].f);
    } else {
        snprintf(buf, sizeof(buf), "PointF(0.0, 0.0)");
    }
    DxObject *str = dx_vm_create_string(vm, buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- android.graphics.Paint (field-backed) ---
// field layout: color=0, textSize=1, strokeWidth=2, alpha=3, antiAlias=4,
//               style=5, typeface=6
#define PAINT_FIELD_COLOR        0
#define PAINT_FIELD_TEXT_SIZE    1
#define PAINT_FIELD_STROKE_WIDTH 2
#define PAINT_FIELD_ALPHA        3
#define PAINT_FIELD_ANTI_ALIAS   4
#define PAINT_FIELD_STYLE        5
#define PAINT_FIELD_TYPEFACE     6
#define PAINT_FIELD_COUNT        7

static DxResult native_paint_init_fields(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT) {
        self->fields[PAINT_FIELD_COLOR] = DX_INT_VALUE((int32_t)0xFF000000);
        self->fields[PAINT_FIELD_TEXT_SIZE] = (DxValue){.tag = DX_VAL_FLOAT, .f = 14.0f};
        self->fields[PAINT_FIELD_STROKE_WIDTH] = (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
        self->fields[PAINT_FIELD_ALPHA] = DX_INT_VALUE(255);
        self->fields[PAINT_FIELD_ANTI_ALIAS] = DX_INT_VALUE((arg_count > 1 && (args[1].i & 1)) ? 1 : 0);
        self->fields[PAINT_FIELD_STYLE] = DX_NULL_VALUE;
        self->fields[PAINT_FIELD_TYPEFACE] = DX_NULL_VALUE;
    }
    return DX_OK;
}

static DxResult native_paint_setColor_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT && arg_count > 1) {
        self->fields[PAINT_FIELD_COLOR] = args[1];
    }
    return DX_OK;
}

static DxResult native_paint_getColor_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t c = (int32_t)0xFF000000;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT) {
        c = self->fields[PAINT_FIELD_COLOR].i;
    }
    frame->result = DX_INT_VALUE(c);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_paint_setTextSize_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT && arg_count > 1) {
        self->fields[PAINT_FIELD_TEXT_SIZE] = args[1];
    }
    return DX_OK;
}

static DxResult native_paint_getTextSize_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    float sz = 14.0f;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT) {
        sz = self->fields[PAINT_FIELD_TEXT_SIZE].f;
    }
    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = sz};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_paint_setStrokeWidth_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT && arg_count > 1) {
        self->fields[PAINT_FIELD_STROKE_WIDTH] = args[1];
    }
    return DX_OK;
}

static DxResult native_paint_getStrokeWidth_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    float sw = 0.0f;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT) {
        sw = self->fields[PAINT_FIELD_STROKE_WIDTH].f;
    }
    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = sw};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_paint_setAntiAlias_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT && arg_count > 1) {
        self->fields[PAINT_FIELD_ANTI_ALIAS] = DX_INT_VALUE(args[1].i ? 1 : 0);
    }
    return DX_OK;
}

static DxResult native_paint_isAntiAlias_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int aa = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT) {
        aa = self->fields[PAINT_FIELD_ANTI_ALIAS].i;
    }
    frame->result = DX_INT_VALUE(aa);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_paint_setStyle_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT && arg_count > 1) {
        self->fields[PAINT_FIELD_STYLE] = args[1];
    }
    return DX_OK;
}

static DxResult native_paint_getStyle_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT) {
        frame->result = self->fields[PAINT_FIELD_STYLE];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_paint_setTypeface_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT && arg_count > 1) {
        self->fields[PAINT_FIELD_TYPEFACE] = args[1];
    }
    frame->result = (arg_count > 1) ? args[1] : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_paint_getTypeface_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT) {
        frame->result = self->fields[PAINT_FIELD_TYPEFACE];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_paint_measureText_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    float text_size = 14.0f;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT) {
        text_size = self->fields[PAINT_FIELD_TEXT_SIZE].f;
        if (text_size <= 0.0f) text_size = 14.0f;
    }
    float result = 0.0f;
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        const char *str = dx_vm_get_string_value(args[1].obj);
        if (str) {
            result = (float)strlen(str) * text_size * 0.6f;
        }
    }
    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = result};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_paint_setAlpha_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT && arg_count > 1) {
        self->fields[PAINT_FIELD_ALPHA] = args[1];
    }
    return DX_OK;
}

static DxResult native_paint_getAlpha_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int alpha = 255;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= PAINT_FIELD_COUNT) {
        alpha = self->fields[PAINT_FIELD_ALPHA].i;
    }
    frame->result = DX_INT_VALUE(alpha);
    frame->has_result = true;
    return DX_OK;
}

// --- android.graphics.Canvas (draw command recording) ---

// Helper: extract Paint properties from a Paint DxObject into a DxDrawCommand
static void canvas_extract_paint(DxObject *paint, DxDrawCommand *cmd) {
    cmd->color = 0xFF000000;       // default black
    cmd->stroke_width = 0.0f;
    cmd->paint_style = 0;          // FILL
    cmd->text_size = 14.0f;
    if (!paint || !paint->fields || !paint->klass ||
        paint->klass->instance_field_count < PAINT_FIELD_COUNT) return;
    cmd->color = (uint32_t)paint->fields[PAINT_FIELD_COLOR].i;
    cmd->stroke_width = paint->fields[PAINT_FIELD_STROKE_WIDTH].f;
    cmd->text_size = paint->fields[PAINT_FIELD_TEXT_SIZE].f;
    // Style field may be an enum object or int; treat int values directly
    DxValue sv = paint->fields[PAINT_FIELD_STYLE];
    if (sv.tag == DX_VAL_INT) {
        cmd->paint_style = sv.i;
    } else if (sv.tag == DX_VAL_OBJ && sv.obj && sv.obj->fields) {
        // Paint$Style enum — ordinal stored in field[0]
        cmd->paint_style = sv.obj->fields[0].i;
    }
}

// Helper: append a draw command to the Canvas object's linked DxUINode
static DxDrawCommand *canvas_append_cmd(DxObject *canvas_obj) {
    if (!canvas_obj || !canvas_obj->ui_node) return NULL;
    DxUINode *node = canvas_obj->ui_node;
    if (node->draw_cmd_count >= DX_MAX_DRAW_COMMANDS) return NULL;
    if (node->draw_cmd_count >= node->draw_cmd_capacity) {
        uint32_t new_cap = node->draw_cmd_capacity == 0 ? 16 : node->draw_cmd_capacity * 2;
        if (new_cap > DX_MAX_DRAW_COMMANDS) new_cap = DX_MAX_DRAW_COMMANDS;
        DxDrawCommand *new_cmds = (DxDrawCommand *)dx_realloc(
            node->draw_commands, sizeof(DxDrawCommand) * new_cap);
        if (!new_cmds) return NULL;
        node->draw_commands = new_cmds;
        node->draw_cmd_capacity = new_cap;
    }
    DxDrawCommand *cmd = &node->draw_commands[node->draw_cmd_count];
    memset(cmd, 0, sizeof(DxDrawCommand));
    node->draw_cmd_count++;
    return cmd;
}

// Canvas.<init>() — no-op (Canvas without a target view; draw commands are lost)
// Canvas.<init>(Bitmap) — also no-op stub for now

// Canvas.drawRect(float left, float top, float right, float bottom, Paint paint)
// args: [0]=this, [1]=left(f), [2]=top(f), [3]=right(f), [4]=bottom(f), [5]=paint(obj)
static DxResult native_canvas_drawRect(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count < 6) return DX_OK;
    DxObject *self = args[0].obj;
    DxDrawCommand *cmd = canvas_append_cmd(self);
    if (!cmd) return DX_OK;
    cmd->type = DX_DRAW_RECT;
    cmd->params[0] = args[1].f; // left
    cmd->params[1] = args[2].f; // top
    cmd->params[2] = args[3].f; // right
    cmd->params[3] = args[4].f; // bottom
    canvas_extract_paint(args[5].obj, cmd);
    return DX_OK;
}

// Canvas.drawCircle(float cx, float cy, float radius, Paint paint)
// args: [0]=this, [1]=cx(f), [2]=cy(f), [3]=radius(f), [4]=paint(obj)
static DxResult native_canvas_drawCircle(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count < 5) return DX_OK;
    DxObject *self = args[0].obj;
    DxDrawCommand *cmd = canvas_append_cmd(self);
    if (!cmd) return DX_OK;
    cmd->type = DX_DRAW_CIRCLE;
    cmd->params[0] = args[1].f; // cx
    cmd->params[1] = args[2].f; // cy
    cmd->params[2] = args[3].f; // radius
    canvas_extract_paint(args[4].obj, cmd);
    return DX_OK;
}

// Canvas.drawLine(float startX, float startY, float stopX, float stopY, Paint paint)
// args: [0]=this, [1]=x1(f), [2]=y1(f), [3]=x2(f), [4]=y2(f), [5]=paint(obj)
static DxResult native_canvas_drawLine(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count < 6) return DX_OK;
    DxObject *self = args[0].obj;
    DxDrawCommand *cmd = canvas_append_cmd(self);
    if (!cmd) return DX_OK;
    cmd->type = DX_DRAW_LINE;
    cmd->params[0] = args[1].f; // x1
    cmd->params[1] = args[2].f; // y1
    cmd->params[2] = args[3].f; // x2
    cmd->params[3] = args[4].f; // y2
    canvas_extract_paint(args[5].obj, cmd);
    return DX_OK;
}

// Canvas.drawText(String text, float x, float y, Paint paint)
// args: [0]=this, [1]=text(obj), [2]=x(f), [3]=y(f), [4]=paint(obj)
static DxResult native_canvas_drawText(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count < 5) return DX_OK;
    DxObject *self = args[0].obj;
    DxDrawCommand *cmd = canvas_append_cmd(self);
    if (!cmd) return DX_OK;
    cmd->type = DX_DRAW_TEXT;
    cmd->params[0] = args[2].f; // x
    cmd->params[1] = args[3].f; // y
    const char *str = (args[1].tag == DX_VAL_OBJ && args[1].obj) ?
                       dx_vm_get_string_value(args[1].obj) : NULL;
    cmd->text = str ? dx_strdup(str) : NULL;
    canvas_extract_paint(args[4].obj, cmd);
    return DX_OK;
}

// Canvas.drawRoundRect(RectF rect, float rx, float ry, Paint paint)
// RectF fields: left=0, top=1, right=2, bottom=3
// args: [0]=this, [1]=rectf(obj), [2]=rx(f), [3]=ry(f), [4]=paint(obj)
static DxResult native_canvas_drawRoundRect(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count < 5) return DX_OK;
    DxObject *self = args[0].obj;
    DxDrawCommand *cmd = canvas_append_cmd(self);
    if (!cmd) return DX_OK;
    cmd->type = DX_DRAW_ROUND_RECT;
    // Extract RectF fields
    DxObject *rectf = (args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    if (rectf && rectf->fields && rectf->klass && rectf->klass->instance_field_count >= 4) {
        cmd->params[0] = rectf->fields[0].f; // left
        cmd->params[1] = rectf->fields[1].f; // top
        cmd->params[2] = rectf->fields[2].f; // right
        cmd->params[3] = rectf->fields[3].f; // bottom
    }
    cmd->params[4] = args[2].f; // rx
    cmd->params[5] = args[3].f; // ry
    canvas_extract_paint(args[4].obj, cmd);
    return DX_OK;
}

// Canvas.drawColor(int color)
// args: [0]=this, [1]=color(i)
static DxResult native_canvas_drawColor(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count < 2) return DX_OK;
    DxObject *self = args[0].obj;
    DxDrawCommand *cmd = canvas_append_cmd(self);
    if (!cmd) return DX_OK;
    cmd->type = DX_DRAW_COLOR;
    cmd->color = (uint32_t)args[1].i;
    return DX_OK;
}

// Canvas.drawOval(RectF oval, Paint paint)
// args: [0]=this, [1]=rectf(obj), [2]=paint(obj)
static DxResult native_canvas_drawOval(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count < 3) return DX_OK;
    DxObject *self = args[0].obj;
    DxDrawCommand *cmd = canvas_append_cmd(self);
    if (!cmd) return DX_OK;
    cmd->type = DX_DRAW_OVAL;
    DxObject *rectf = (args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    if (rectf && rectf->fields && rectf->klass && rectf->klass->instance_field_count >= 4) {
        cmd->params[0] = rectf->fields[0].f; // left
        cmd->params[1] = rectf->fields[1].f; // top
        cmd->params[2] = rectf->fields[2].f; // right
        cmd->params[3] = rectf->fields[3].f; // bottom
    }
    canvas_extract_paint(args[2].obj, cmd);
    return DX_OK;
}

// Canvas.save() -> returns int (save count)
static DxResult native_canvas_save(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // Record save command for transform stack fidelity
    if (arg_count >= 1 && args[0].obj) {
        DxDrawCommand *cmd = canvas_append_cmd(args[0].obj);
        if (cmd) cmd->type = DX_DRAW_SAVE;
    }
    frame->result = DX_INT_VALUE(1);
    frame->has_result = true;
    return DX_OK;
}

// Canvas.restore()
static DxResult native_canvas_restore(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 1 && args[0].obj) {
        DxDrawCommand *cmd = canvas_append_cmd(args[0].obj);
        if (cmd) cmd->type = DX_DRAW_RESTORE;
    }
    return DX_OK;
}

// Canvas.translate(float dx, float dy)
static DxResult native_canvas_translate(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 3 && args[0].obj) {
        DxDrawCommand *cmd = canvas_append_cmd(args[0].obj);
        if (cmd) {
            cmd->type = DX_DRAW_TRANSLATE;
            cmd->params[0] = args[1].f;
            cmd->params[1] = args[2].f;
        }
    }
    return DX_OK;
}

// Canvas.rotate(float degrees)
static DxResult native_canvas_rotate(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].obj) {
        DxDrawCommand *cmd = canvas_append_cmd(args[0].obj);
        if (cmd) {
            cmd->type = DX_DRAW_ROTATE;
            cmd->params[0] = args[1].f;
        }
    }
    return DX_OK;
}

// Canvas.scale(float sx, float sy)
static DxResult native_canvas_scale(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 3 && args[0].obj) {
        DxDrawCommand *cmd = canvas_append_cmd(args[0].obj);
        if (cmd) {
            cmd->type = DX_DRAW_SCALE;
            cmd->params[0] = args[1].f;
            cmd->params[1] = args[2].f;
        }
    }
    return DX_OK;
}

// Canvas.getWidth() / Canvas.getHeight() — return view dimensions
static DxResult native_canvas_getWidth(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    int w = 0;
    DxObject *self = args[0].obj;
    if (self && self->ui_node) {
        w = self->ui_node->width > 0 ? self->ui_node->width : 320;
    }
    frame->result = DX_INT_VALUE(w);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_canvas_getHeight(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    int h = 0;
    DxObject *self = args[0].obj;
    if (self && self->ui_node) {
        h = self->ui_node->height > 0 ? self->ui_node->height : 480;
    }
    frame->result = DX_INT_VALUE(h);
    frame->has_result = true;
    return DX_OK;
}

// --- android.graphics.Typeface ---

static DxResult native_typeface_create_fb(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxClass *cls = dx_vm_find_class(vm, "Landroid/graphics/Typeface;");
    DxObject *obj = cls ? dx_vm_alloc_object(vm, cls) : NULL;
    if (obj && obj->fields && cls->instance_field_count > 0 && arg_count > 1) {
        obj->fields[0] = args[1]; // style int
    }
    frame->result = obj ? DX_OBJ_VALUE(obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Helper to set up instance field definitions for a class
static void setup_instance_fields(DxClass *cls, const char **names, const char **types, uint32_t count) {
    if (!cls || count == 0) return;
    cls->instance_field_count = count;
    cls->field_defs = dx_malloc(sizeof(*cls->field_defs) * count);
    if (!cls->field_defs) return;
    for (uint32_t i = 0; i < count; i++) {
        cls->field_defs[i].name = names[i];
        cls->field_defs[i].type = types[i];
        cls->field_defs[i].flags = DX_ACC_PUBLIC;
    }
}

// ============================================================
// androidx.lifecycle — LiveData / MutableLiveData / ViewModelProvider
// ============================================================

// LiveData.getValue - return field[0]
static DxResult native_livedata_get_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// LiveData.observe - store observer in field[1]
static DxResult native_livedata_observe(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 2) return DX_OK;
    // args[1] = LifecycleOwner, args[2] = Observer
    if (arg_count > 2 && args[2].tag == DX_VAL_OBJ) {
        self->fields[1] = args[2];  // store observer
    }
    return DX_OK;
}

// LiveData.observeForever - store observer in field[1]
static DxResult native_livedata_observe_forever(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 2) return DX_OK;
    // args[1] = Observer
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ) {
        self->fields[1] = args[1];  // store observer
    }
    return DX_OK;
}

// MutableLiveData.setValue - stores value and notifies observer
static DxResult native_livedata_set_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = args[0].obj;
    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 2) return DX_OK;
    DxValue new_val = (arg_count > 1) ? args[1] : DX_NULL_VALUE;
    self->fields[0] = new_val;  // store value

    // Notify observer if set
    if (self->fields[1].tag == DX_VAL_OBJ && self->fields[1].obj) {
        DxObject *observer = self->fields[1].obj;
        DxMethod *on_changed = dx_vm_find_method(observer->klass, "onChanged", NULL);
        if (on_changed) {
            DxValue obs_args[2] = { DX_OBJ_VALUE(observer), new_val };
            vm->insn_count = 0;
            dx_vm_execute_method(vm, on_changed, obs_args, 2, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    }
    return DX_OK;
}

// MutableLiveData.<init>(T) - store initial value in field[0]
static DxResult native_mutable_livedata_init_val(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2 && arg_count > 1) {
        self->fields[0] = args[1];  // store initial value
    }
    return DX_OK;
}

// ViewModelProvider.get(Class) - instantiate ViewModel
static DxResult native_viewmodelprovider_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this, args[1] = Class object
    DxClass *cls = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj
        && args[1].obj->fields && args[1].obj->klass->instance_field_count > 0
        && args[1].obj->fields[0].tag == DX_VAL_INT) {
        cls = (DxClass *)(uintptr_t)args[1].obj->fields[0].i;
    }
    if (!cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    DxObject *obj = dx_vm_alloc_object(vm, cls);
    if (obj) {
        DxMethod *init = dx_vm_find_method(cls, "<init>", "V");
        if (init) {
            DxValue init_args[1] = { DX_OBJ_VALUE(obj) };
            vm->insn_count = 0;
            dx_vm_execute_method(vm, init, init_args, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    }
    frame->result = obj ? DX_OBJ_VALUE(obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Toast.makeText — log message + return Toast object
// ============================================================

static DxResult native_toast_make_text(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // static makeText(Context, CharSequence, int) -> Toast
    // args[0] = Context, args[1] = text, args[2] = duration
    const char *text = "";
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        const char *s = dx_vm_get_string_value(args[1].obj);
        if (s) text = s;
    }
    int duration = (arg_count > 2) ? args[2].i : 0;
    DX_INFO("Toast", "%s (duration=%s)", text, duration == 0 ? "SHORT" : "LONG");

    // Allocate a Toast object so show() can be called on it
    DxObject *toast_obj = dx_vm_alloc_object(vm, vm->class_toast);
    frame->result = toast_obj ? DX_OBJ_VALUE(toast_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_toast_show(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    DX_DEBUG("Toast", "show() called");
    return DX_OK;
}

// ============================================================
// Activity.runOnUiThread — execute Runnable synchronously
// ============================================================

static DxResult native_activity_run_on_ui_thread(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (Activity), args[1] = Runnable
    (void)frame;
    if (arg_count < 2 || args[1].tag != DX_VAL_OBJ || !args[1].obj) {
        return DX_OK;
    }

    DxObject *runnable = args[1].obj;
    DxMethod *run_method = dx_vm_find_method(runnable->klass, "run", NULL);
    if (run_method) {
        DX_DEBUG("Activity", "runOnUiThread() executing Runnable.run() synchronously");
        DxValue run_args[1] = { DX_OBJ_VALUE(runnable) };
        dx_vm_execute_method(vm, run_method, run_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL; // absorb
    }
    return DX_OK;
}

// ============================================================
// ViewGroup.addView — attach child UI node to parent
// ============================================================

static DxResult native_viewgroup_add_view(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = args[0].obj;
    DxObject *child_obj = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self || !child_obj) return DX_OK;

    // If parent has a UI node, create one for child if needed and attach
    if (self->ui_node) {
        if (!child_obj->ui_node) {
            // Determine view type from class
            DxViewType vtype = DX_VIEW_VIEW;
            if (child_obj->klass) {
                if (child_obj->klass == vm->class_textview) vtype = DX_VIEW_TEXT_VIEW;
                else if (child_obj->klass == vm->class_button) vtype = DX_VIEW_BUTTON;
                else if (child_obj->klass == vm->class_edittext) vtype = DX_VIEW_EDIT_TEXT;
                else if (child_obj->klass == vm->class_imageview) vtype = DX_VIEW_IMAGE_VIEW;
                else if (child_obj->klass == vm->class_linearlayout) vtype = DX_VIEW_LINEAR_LAYOUT;
            }
            DxUINode *child_node = dx_ui_node_create(vtype, 0);
            if (child_node) {
                child_obj->ui_node = child_node;
                child_node->runtime_obj = child_obj;
            }
        }
        if (child_obj->ui_node) {
            dx_ui_node_add_child(self->ui_node, child_obj->ui_node);
            rebuild_render_model(vm);
            DX_DEBUG("ViewGroup", "addView: child added (now %u children)", self->ui_node->child_count);
        }
    }
    return DX_OK;
}

// ============================================================
// ViewGroup.removeAllViews — detach all children
// ============================================================

static DxResult native_viewgroup_remove_all_views(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->ui_node) {
        // Detach children (don't destroy them — they may still be referenced)
        self->ui_node->child_count = 0;
        rebuild_render_model(vm);
        DX_DEBUG("ViewGroup", "removeAllViews called");
    }
    return DX_OK;
}

// ============================================================
// Looper stubs — prepare/loop/myLooper/getMainLooper
// ============================================================

static DxResult native_looper_get_main_looper(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    // Return a Looper object (not null, so callers can chain)
    DxClass *looper_cls = dx_vm_find_class(vm, "Landroid/os/Looper;");
    DxObject *looper_obj = looper_cls ? dx_vm_alloc_object(vm, looper_cls) : NULL;
    frame->result = looper_obj ? DX_OBJ_VALUE(looper_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_looper_my_looper(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    return native_looper_get_main_looper(vm, frame, args, arg_count);
}

// ============================================================
// Uri.parse — store URI string on object field
// ============================================================

static DxResult native_uri_parse(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // static Uri.parse(String) -> Uri
    DxClass *uri_cls = dx_vm_find_class(vm, "Landroid/net/Uri;");
    DxObject *uri_obj = uri_cls ? dx_vm_alloc_object(vm, uri_cls) : NULL;
    if (uri_obj && arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        const char *uri_str = dx_vm_get_string_value(args[0].obj);
        if (uri_str) DX_DEBUG("Uri", "parse(\"%s\")", uri_str);
        // Store the string as field[0] for later retrieval by toString/getScheme etc.
        if (uri_obj->fields && uri_obj->klass->instance_field_count > 0) {
            uri_obj->fields[0] = args[0];
        }
    }
    frame->result = uri_obj ? DX_OBJ_VALUE(uri_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_uri_to_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && self->fields[0].tag == DX_VAL_OBJ && self->fields[0].obj) {
        frame->result = self->fields[0];
    } else {
        DxObject *str_obj = dx_vm_create_string(vm, "");
        frame->result = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// java.io.File — basic file operations
// ============================================================

static DxResult native_file_init_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    // args[0] = this, args[1] = path string
    DxObject *self = args[0].obj;
    if (self && arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        const char *path = dx_vm_get_string_value(args[1].obj);
        DX_DEBUG("File", "<init>(\"%s\")", path ? path : "null");
        // Store path as field[0]
        if (self->fields && self->klass && self->klass->instance_field_count > 0) {
            self->fields[0] = args[1];
        }
    }
    return DX_OK;
}

static DxResult native_file_init_parent_child(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    // args[0] = this, args[1] = parent File, args[2] = child name
    DxObject *self = args[0].obj;
    if (!self) return DX_OK;

    const char *parent_path = "";
    const char *child_name = "";
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        if (args[1].obj->fields && args[1].obj->klass && args[1].obj->klass->instance_field_count > 0
            && args[1].obj->fields[0].tag == DX_VAL_OBJ && args[1].obj->fields[0].obj) {
            parent_path = dx_vm_get_string_value(args[1].obj->fields[0].obj);
            if (!parent_path) parent_path = "";
        }
    }
    if (arg_count > 2 && args[2].tag == DX_VAL_OBJ && args[2].obj) {
        child_name = dx_vm_get_string_value(args[2].obj);
        if (!child_name) child_name = "";
    }

    char buf[512];
    snprintf(buf, sizeof(buf), "%s/%s", parent_path, child_name);
    DxObject *path_str = dx_vm_create_string(vm, buf);
    if (self->fields && self->klass && self->klass->instance_field_count > 0 && path_str) {
        self->fields[0] = DX_OBJ_VALUE(path_str);
    }
    DX_DEBUG("File", "<init>(\"%s\", \"%s\")", parent_path, child_name);
    return DX_OK;
}

static DxResult native_file_exists(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    // Simulated: all files "don't exist" in our sandbox
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_file_mkdir(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    // Simulated: mkdir "succeeds"
    DX_DEBUG("File", "mkdir() - simulated success");
    frame->result = DX_INT_VALUE(1);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_file_is_directory(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_file_get_absolute_path(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && self->fields[0].tag == DX_VAL_OBJ && self->fields[0].obj) {
        frame->result = self->fields[0];
    } else {
        DxObject *str = dx_vm_create_string(vm, "/");
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_file_get_name(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && self->fields[0].tag == DX_VAL_OBJ && self->fields[0].obj) {
        const char *path = dx_vm_get_string_value(self->fields[0].obj);
        if (path) {
            const char *last_slash = strrchr(path, '/');
            const char *name = last_slash ? last_slash + 1 : path;
            DxObject *str = dx_vm_create_string(vm, name);
            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
            frame->has_result = true;
            return DX_OK;
        }
    }
    DxObject *str = dx_vm_create_string(vm, "");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_file_delete(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    DX_DEBUG("File", "delete() - simulated success");
    frame->result = DX_INT_VALUE(1);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_file_length(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result.tag = DX_VAL_LONG;
    frame->result.l = 0;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// AssetManager.open — extract asset from APK and return InputStream
// ============================================================

// Helper: create a field-backed InputStream with data buffer
static DxObject *create_input_stream_from_data(DxVM *vm, uint8_t *data, uint32_t size) {
    DxClass *is_cls = dx_vm_find_class(vm, "Ljava/io/InputStream;");
    if (!is_cls) return NULL;
    DxObject *is_obj = dx_vm_alloc_object(vm, is_cls);
    if (!is_obj) { free(data); return NULL; }
    // Store pointer as long, size and position as int
    dx_vm_set_field(is_obj, "_data", (DxValue){.tag = DX_VAL_LONG, .l = (int64_t)(uintptr_t)data});
    dx_vm_set_field(is_obj, "_size", DX_INT_VALUE((int32_t)size));
    dx_vm_set_field(is_obj, "_position", DX_INT_VALUE(0));
    return is_obj;
}

static DxResult native_asset_manager_open(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (AssetManager), args[1] = filename string
    const char *filename = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        filename = dx_vm_get_string_value(args[1].obj);
    }
    if (!filename) {
        DX_WARN("AssetManager", "open() called with null filename");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DX_INFO("AssetManager", "open(\"%s\")", filename);

    DxContext *ctx = vm->ctx;
    if (!ctx || !ctx->apk) {
        DX_WARN("AssetManager", "No APK loaded");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Build "assets/{filename}" path
    char asset_path[512];
    snprintf(asset_path, sizeof(asset_path), "assets/%s", filename);

    const DxZipEntry *entry = NULL;
    DxResult res = dx_apk_find_entry(ctx->apk, asset_path, &entry);
    if (res != DX_OK || !entry) {
        DX_WARN("AssetManager", "Asset not found: %s", asset_path);
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    uint8_t *data = NULL;
    uint32_t data_size = 0;
    res = dx_apk_extract_entry(ctx->apk, entry, &data, &data_size);
    if (res != DX_OK || !data) {
        DX_WARN("AssetManager", "Failed to extract asset: %s", asset_path);
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *is_obj = create_input_stream_from_data(vm, data, data_size);
    frame->result = is_obj ? DX_OBJ_VALUE(is_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// AssetManager.list — return empty String[] for now
static DxResult native_asset_manager_list(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *arr = dx_vm_alloc_array(vm, 0);
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// InputStream — field-backed read/available/close
// ============================================================

// InputStream.read() -> int  (next byte or -1 at EOF)
static DxResult native_inputstream_read(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    DxValue data_val, size_val, pos_val;
    if (dx_vm_get_field(self, "_data", &data_val) != DX_OK || data_val.tag != DX_VAL_LONG) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    dx_vm_get_field(self, "_size", &size_val);
    dx_vm_get_field(self, "_position", &pos_val);

    uint8_t *data = (uint8_t *)(uintptr_t)data_val.l;
    int32_t size = size_val.i;
    int32_t pos = pos_val.i;

    if (!data || pos >= size) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    int32_t byte_val = (int32_t)(data[pos] & 0xFF);
    dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + 1));
    frame->result = DX_INT_VALUE(byte_val);
    frame->has_result = true;
    return DX_OK;
}

// InputStream.read(byte[]) -> int  (fills array, returns count or -1)
static DxResult native_inputstream_read_array(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *buf_arr = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self || !buf_arr || !buf_arr->is_array) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    DxValue data_val, size_val, pos_val;
    if (dx_vm_get_field(self, "_data", &data_val) != DX_OK || data_val.tag != DX_VAL_LONG) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    dx_vm_get_field(self, "_size", &size_val);
    dx_vm_get_field(self, "_position", &pos_val);

    uint8_t *data = (uint8_t *)(uintptr_t)data_val.l;
    int32_t size = size_val.i;
    int32_t pos = pos_val.i;

    if (!data || pos >= size) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    int32_t remaining = size - pos;
    int32_t to_read = (int32_t)buf_arr->array_length;
    if (to_read > remaining) to_read = remaining;

    for (int32_t i = 0; i < to_read; i++) {
        buf_arr->array_elements[i] = DX_INT_VALUE((int32_t)(data[pos + i] & 0xFF));
    }

    dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + to_read));
    frame->result = DX_INT_VALUE(to_read);
    frame->has_result = true;
    return DX_OK;
}

// InputStream.available() -> int (remaining bytes)
static DxResult native_inputstream_available(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }

    DxValue data_val, size_val, pos_val;
    if (dx_vm_get_field(self, "_data", &data_val) != DX_OK || data_val.tag != DX_VAL_LONG) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }

    dx_vm_get_field(self, "_size", &size_val);
    dx_vm_get_field(self, "_position", &pos_val);

    int32_t remaining = size_val.i - pos_val.i;
    if (remaining < 0) remaining = 0;

    frame->result = DX_INT_VALUE(remaining);
    frame->has_result = true;
    return DX_OK;
}

// InputStream.close() — free the data buffer
static DxResult native_inputstream_close(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self) {
        DxValue data_val;
        if (dx_vm_get_field(self, "_data", &data_val) == DX_OK && data_val.tag == DX_VAL_LONG && data_val.l != 0) {
            free((void *)(uintptr_t)data_val.l);
            dx_vm_set_field(self, "_data", (DxValue){.tag = DX_VAL_LONG, .l = 0});
            dx_vm_set_field(self, "_size", DX_INT_VALUE(0));
            dx_vm_set_field(self, "_position", DX_INT_VALUE(0));
        }
    }
    return DX_OK;
}

// ============================================================
// Context.getAssets — return AssetManager instance
// ============================================================

static DxResult native_context_get_assets(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *am_cls = dx_vm_find_class(vm, "Landroid/content/res/AssetManager;");
    if (!am_cls) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *am = dx_vm_alloc_object(vm, am_cls);
    frame->result = am ? DX_OBJ_VALUE(am) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context.openFileInput / openFileOutput
// ============================================================

static DxResult native_context_open_file_input(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *name = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        name = dx_vm_get_string_value(args[1].obj);
    }
    DX_INFO("Context", "openFileInput(\"%s\")", name ? name : "null");

    // Return an empty InputStream (no data, immediate EOF)
    DxClass *is_cls = dx_vm_find_class(vm, "Ljava/io/FileInputStream;");
    if (!is_cls) is_cls = dx_vm_find_class(vm, "Ljava/io/InputStream;");
    DxObject *is_obj = is_cls ? dx_vm_alloc_object(vm, is_cls) : NULL;
    if (is_obj) {
        // No data buffer — reads will return -1 (file not found / empty)
        dx_vm_set_field(is_obj, "_data", (DxValue){.tag = DX_VAL_LONG, .l = 0});
        dx_vm_set_field(is_obj, "_size", DX_INT_VALUE(0));
        dx_vm_set_field(is_obj, "_position", DX_INT_VALUE(0));
    }
    frame->result = is_obj ? DX_OBJ_VALUE(is_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_context_open_file_output(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *name = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        name = dx_vm_get_string_value(args[1].obj);
    }
    DX_INFO("Context", "openFileOutput(\"%s\")", name ? name : "null");

    // Return a stub OutputStream
    DxClass *os_cls = dx_vm_find_class(vm, "Ljava/io/FileOutputStream;");
    if (!os_cls) os_cls = dx_vm_find_class(vm, "Ljava/io/OutputStream;");
    DxObject *os_obj = os_cls ? dx_vm_alloc_object(vm, os_cls) : NULL;
    frame->result = os_obj ? DX_OBJ_VALUE(os_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// File.createTempFile — static method returning File with temp path
// ============================================================

static DxResult native_file_create_temp_file(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *prefix = "tmp";
    const char *suffix = ".tmp";

    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        const char *p = dx_vm_get_string_value(args[0].obj);
        if (p) prefix = p;
    }
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        const char *s = dx_vm_get_string_value(args[1].obj);
        if (s) suffix = s;
    }

    // Generate a unique temp path
    static uint32_t temp_counter = 0;
    char path[512];
    snprintf(path, sizeof(path), "/data/data/app/cache/%s%u%s", prefix, temp_counter++, suffix);

    DX_DEBUG("File", "createTempFile(\"%s\", \"%s\") -> %s", prefix, suffix, path);

    DxObject *file_obj = create_file_object(vm, path);
    frame->result = file_obj ? DX_OBJ_VALUE(file_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// File.toString — returns the path string
// ============================================================

static DxResult native_file_to_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && self->fields[0].tag == DX_VAL_OBJ && self->fields[0].obj) {
        frame->result = self->fields[0];
    } else {
        DxObject *str = dx_vm_create_string(vm, "");
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// AlertDialog.Builder — builder pattern
// ============================================================

static DxResult native_alertdialog_builder_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DX_DEBUG("AlertDialog", "Builder.<init>");
    (void)vm; (void)args;
    return DX_OK;
}

static DxResult native_alertdialog_builder_set_return_self(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    // All setXxx methods return 'this' for chaining
    frame->result = DX_OBJ_VALUE(args[0].obj);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_alertdialog_builder_create(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DX_INFO("AlertDialog", "Builder.create() - dialog created (not displayed)");
    DxClass *dialog_cls = dx_vm_find_class(vm, "Landroid/app/AlertDialog;");
    if (!dialog_cls) dialog_cls = dx_vm_find_class(vm, "Landroid/app/Dialog;");
    DxObject *dialog = dialog_cls ? dx_vm_alloc_object(vm, dialog_cls) : NULL;
    frame->result = dialog ? DX_OBJ_VALUE(dialog) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_alertdialog_builder_show(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DX_INFO("AlertDialog", "Builder.show() - dialog shown (simulated)");
    return native_alertdialog_builder_create(vm, frame, args, arg_count);
}

// ============================================================
// Collections.emptyList / emptyMap — return empty collection objects
// ============================================================

static DxResult native_empty_list(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *list = vm->class_arraylist ? dx_vm_alloc_object(vm, vm->class_arraylist) : NULL;
    if (list) {
        // Properly initialize with _size=0 and empty backing array
        DxValue sz; sz.tag = DX_VAL_INT; sz.i = 0;
        dx_vm_set_field(list, "_size", sz);
        DxObject *arr = dx_vm_alloc_array(vm, 0);
        if (arr) {
            DxValue av; av.tag = DX_VAL_OBJ; av.obj = arr;
            dx_vm_set_field(list, "_items", av);
        }
    }
    frame->result = list ? DX_OBJ_VALUE(list) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_empty_map(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *map = vm->class_hashmap ? dx_vm_alloc_object(vm, vm->class_hashmap) : NULL;
    if (map) {
        // Properly initialize with _size=0 and empty backing arrays
        DxValue sz; sz.tag = DX_VAL_INT; sz.i = 0;
        dx_vm_set_field(map, "_size", sz);
        DxObject *keys_arr = dx_vm_alloc_array(vm, 16);
        DxObject *vals_arr = dx_vm_alloc_array(vm, 16);
        if (keys_arr) {
            DxValue kv; kv.tag = DX_VAL_OBJ; kv.obj = keys_arr;
            dx_vm_set_field(map, "_keys", kv);
        }
        if (vals_arr) {
            DxValue vv; vv.tag = DX_VAL_OBJ; vv.obj = vals_arr;
            dx_vm_set_field(map, "_vals", vv);
        }
    }
    frame->result = map ? DX_OBJ_VALUE(map) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_singleton_list(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Collections.singletonList(element) — create an ArrayList with one element
    DxObject *list = vm->class_arraylist ? dx_vm_alloc_object(vm, vm->class_arraylist) : NULL;
    if (list && arg_count >= 1) {
        // Use the ArrayList native add to add the element
        DxMethod *add = dx_vm_find_method(vm->class_arraylist, "add", NULL);
        if (add) {
            DxValue add_args[2] = { DX_OBJ_VALUE(list), args[0] };
            DxFrame tmp = {0};
            add->native_fn(vm, &tmp, add_args, 2);
        }
    }
    frame->result = list ? DX_OBJ_VALUE(list) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Arrays utility methods
// ============================================================

static DxResult native_arrays_asList(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Arrays.asList(Object...) — create ArrayList from array argument
    // The argument is typically an Object[] array
    DxObject *list = vm->class_arraylist ? dx_vm_alloc_object(vm, vm->class_arraylist) : NULL;
    if (list && arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj && args[0].obj->is_array) {
        DxObject *arr = args[0].obj;
        DxMethod *add = dx_vm_find_method(vm->class_arraylist, "add", NULL);
        if (add) {
            for (uint32_t i = 0; i < arr->array_length; i++) {
                DxValue add_args[2] = { DX_OBJ_VALUE(list), arr->array_elements[i] };
                DxFrame tmp = {0};
                add->native_fn(vm, &tmp, add_args, 2);
            }
        }
    } else if (list && arg_count >= 1) {
        // Single non-array argument: treat as singleton list
        DxMethod *add = dx_vm_find_method(vm->class_arraylist, "add", NULL);
        if (add) {
            DxValue add_args[2] = { DX_OBJ_VALUE(list), args[0] };
            DxFrame tmp = {0};
            add->native_fn(vm, &tmp, add_args, 2);
        }
    }
    frame->result = list ? DX_OBJ_VALUE(list) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arrays_copyOf(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Arrays.copyOf(Object[], int) — return copy of array with new length
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj && args[0].obj->is_array) {
        DxObject *src = args[0].obj;
        uint32_t new_len = (uint32_t)(args[1].i > 0 ? args[1].i : 0);
        DxObject *dst = dx_vm_alloc_array(vm, new_len);
        if (dst) {
            uint32_t copy_len = src->array_length < new_len ? src->array_length : new_len;
            for (uint32_t i = 0; i < copy_len; i++) {
                dst->array_elements[i] = src->array_elements[i];
            }
            frame->result = DX_OBJ_VALUE(dst);
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arrays_fill(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Arrays.fill(Object[], Object) — fill array with value
    (void)vm;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj && args[0].obj->is_array) {
        DxObject *arr = args[0].obj;
        for (uint32_t i = 0; i < arr->array_length; i++) {
            arr->array_elements[i] = args[1];
        }
    }
    frame->has_result = false;
    return DX_OK;
}

static DxResult native_arrays_equals(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Arrays.equals(Object[], Object[]) — compare arrays element-by-element
    (void)vm;
    if (arg_count >= 2) {
        DxObject *a = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
        DxObject *b = (args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
        if (a == b) { frame->result = DX_INT_VALUE(1); frame->has_result = true; return DX_OK; }
        if (!a || !b) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
        if (!a->is_array || !b->is_array || a->array_length != b->array_length) {
            frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK;
        }
        for (uint32_t i = 0; i < a->array_length; i++) {
            DxValue va = a->array_elements[i];
            DxValue vb = b->array_elements[i];
            if (va.tag != vb.tag) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
            if (va.tag == DX_VAL_INT && va.i != vb.i) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
            if (va.tag == DX_VAL_OBJ && va.obj != vb.obj) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
        }
        frame->result = DX_INT_VALUE(1);
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arrays_toString(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Arrays.toString(Object[]) — "[elem1, elem2, ...]"
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj && args[0].obj->is_array) {
        DxObject *arr = args[0].obj;
        // Build a string representation
        char buf[2048];
        int pos = 0;
        buf[pos++] = '[';
        for (uint32_t i = 0; i < arr->array_length && pos < 2000; i++) {
            if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
            DxValue v = arr->array_elements[i];
            if (v.tag == DX_VAL_INT) {
                pos += snprintf(buf + pos, (size_t)(2040 - pos), "%d", v.i);
            } else if (v.tag == DX_VAL_LONG) {
                pos += snprintf(buf + pos, (size_t)(2040 - pos), "%lld", v.l);
            } else if (v.tag == DX_VAL_OBJ && v.obj) {
                const char *s = dx_vm_get_string_value(v.obj);
                if (s) {
                    pos += snprintf(buf + pos, (size_t)(2040 - pos), "%s", s);
                } else {
                    pos += snprintf(buf + pos, (size_t)(2040 - pos), "<obj>");
                }
            } else {
                pos += snprintf(buf + pos, (size_t)(2040 - pos), "null");
            }
        }
        if (pos < 2046) buf[pos++] = ']';
        buf[pos] = '\0';
        DxObject *str = dx_vm_create_string(vm, buf);
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    } else if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && !args[0].obj) {
        DxObject *str = dx_vm_create_string(vm, "null");
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Collections utility methods (additional)
// ============================================================

static DxResult native_collections_addAll(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Collections.addAll(Collection, Object...) — add elements from array to collection
    // args[0] = collection, args[1] = array of elements
    (void)frame;
    bool added = false;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        DxObject *coll = args[0].obj;
        DxMethod *add = coll->klass ? dx_vm_find_method(coll->klass, "add", NULL) : NULL;
        if (add) {
            if (args[1].tag == DX_VAL_OBJ && args[1].obj && args[1].obj->is_array) {
                DxObject *arr = args[1].obj;
                for (uint32_t i = 0; i < arr->array_length; i++) {
                    DxValue add_args[2] = { DX_OBJ_VALUE(coll), arr->array_elements[i] };
                    DxFrame tmp = {0};
                    add->native_fn(vm, &tmp, add_args, 2);
                    added = true;
                }
            } else {
                // Single element
                DxValue add_args[2] = { DX_OBJ_VALUE(coll), args[1] };
                DxFrame tmp = {0};
                add->native_fn(vm, &tmp, add_args, 2);
                added = true;
            }
        }
    }
    frame->result = DX_INT_VALUE(added ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_collections_frequency(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Collections.frequency(Collection, Object) — count occurrences
    // For simplicity, return 0 (exact counting would require iterating internal structure)
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_collections_singleton(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Collections.singleton(Object) — single-element set (we use an ArrayList as backing)
    DxObject *set = vm->class_arraylist ? dx_vm_alloc_object(vm, vm->class_arraylist) : NULL;
    if (set && arg_count >= 1) {
        DxMethod *add = dx_vm_find_method(vm->class_arraylist, "add", NULL);
        if (add) {
            DxValue add_args[2] = { DX_OBJ_VALUE(set), args[0] };
            DxFrame tmp = {0};
            add->native_fn(vm, &tmp, add_args, 2);
        }
    }
    frame->result = set ? DX_OBJ_VALUE(set) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_collections_singletonMap(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Collections.singletonMap(Object, Object) — single-entry map
    DxObject *map = vm->class_hashmap ? dx_vm_alloc_object(vm, vm->class_hashmap) : NULL;
    if (map && arg_count >= 2) {
        DxMethod *put = vm->class_hashmap ? dx_vm_find_method(vm->class_hashmap, "put", NULL) : NULL;
        if (put) {
            DxValue put_args[3] = { DX_OBJ_VALUE(map), args[0], args[1] };
            DxFrame tmp = {0};
            put->native_fn(vm, &tmp, put_args, 3);
        }
    }
    frame->result = map ? DX_OBJ_VALUE(map) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Objects utility methods
// ============================================================

static DxResult native_objects_equals(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Objects.equals(Object, Object) — null-safe equals
    (void)vm;
    if (arg_count < 2) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    DxObject *a = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *b = (args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    if (a == b) {
        frame->result = DX_INT_VALUE(1);
    } else if (!a || !b) {
        frame->result = DX_INT_VALUE(0);
    } else {
        // Try calling a.equals(b)
        DxMethod *eq = a->klass ? dx_vm_find_method(a->klass, "equals", NULL) : NULL;
        if (eq && eq->native_fn) {
            DxValue eq_args[2] = { DX_OBJ_VALUE(a), DX_OBJ_VALUE(b) };
            DxFrame tmp = {0};
            eq->native_fn(vm, &tmp, eq_args, 2);
            frame->result = tmp.result;
        } else {
            frame->result = DX_INT_VALUE(0);
        }
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_objects_hashCode(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Objects.hashCode(Object) — null-safe hashCode, returns 0 for null
    (void)vm;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        // Use pointer value as hash
        frame->result = DX_INT_VALUE((int32_t)(uintptr_t)args[0].obj);
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_objects_requireNonNull(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Objects.requireNonNull(Object) — return arg or throw NPE
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        frame->result = args[0];
        frame->has_result = true;
        return DX_OK;
    }
    // Throw NullPointerException
    DxClass *npe = dx_vm_find_class(vm, "Ljava/lang/NullPointerException;");
    if (npe) {
        DxObject *exc = dx_vm_alloc_object(vm, npe);
        if (exc) {
            vm->pending_exception = exc;
            return DX_ERR_EXCEPTION;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_objects_toString(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Objects.toString(Object, String) — null-safe toString with default
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        // Try to get string value of the object
        const char *s = dx_vm_get_string_value(args[0].obj);
        if (s) {
            frame->result = args[0]; // Already a string
        } else {
            // Return class name or generic string
            DxObject *str = dx_vm_create_string(vm, args[0].obj->klass ? args[0].obj->klass->descriptor : "<object>");
            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
        }
    } else if (arg_count >= 2) {
        // Object is null, return the default string
        frame->result = args[1];
    } else {
        DxObject *str = dx_vm_create_string(vm, "null");
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// AtomicInteger — field[0] stores the int value
// ============================================================

static DxResult native_atomic_int_init_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass
        && args[0].obj->klass->instance_field_count > 0) {
        args[0].obj->fields[0] = DX_INT_VALUE(args[1].i);
    }
    return DX_OK;
}

static DxResult native_atomic_int_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_atomic_int_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 && arg_count >= 2) {
        self->fields[0] = DX_INT_VALUE(args[1].i);
    }
    return DX_OK;
}

static DxResult native_atomic_int_get_and_increment(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t old_val = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        old_val = self->fields[0].i;
        self->fields[0] = DX_INT_VALUE(old_val + 1);
    }
    frame->result = DX_INT_VALUE(old_val);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_atomic_int_increment_and_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t new_val = 1;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        new_val = self->fields[0].i + 1;
        self->fields[0] = DX_INT_VALUE(new_val);
    }
    frame->result = DX_INT_VALUE(new_val);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_atomic_int_compare_and_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 && arg_count >= 3) {
        int32_t expected = args[1].i;
        int32_t update = args[2].i;
        if (self->fields[0].i == expected) {
            self->fields[0] = DX_INT_VALUE(update);
            frame->result = DX_INT_VALUE(1); // true
        } else {
            frame->result = DX_INT_VALUE(0); // false
        }
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// AtomicBoolean — field[0] stores the boolean as int
// ============================================================

static DxResult native_atomic_bool_init_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass
        && args[0].obj->klass->instance_field_count > 0) {
        args[0].obj->fields[0] = DX_INT_VALUE(args[1].i ? 1 : 0);
    }
    return DX_OK;
}

static DxResult native_atomic_bool_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = DX_INT_VALUE(self->fields[0].i ? 1 : 0);
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_atomic_bool_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 && arg_count >= 2) {
        self->fields[0] = DX_INT_VALUE(args[1].i ? 1 : 0);
    }
    return DX_OK;
}

static DxResult native_atomic_bool_compare_and_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 && arg_count >= 3) {
        int32_t expected = args[1].i ? 1 : 0;
        int32_t update = args[2].i ? 1 : 0;
        if (self->fields[0].i == expected) {
            self->fields[0] = DX_INT_VALUE(update);
            frame->result = DX_INT_VALUE(1);
        } else {
            frame->result = DX_INT_VALUE(0);
        }
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// AtomicInteger — addAndGet, getAndAdd
// ============================================================

static DxResult native_atomic_int_add_and_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t delta = (arg_count >= 2) ? args[1].i : 0;
    int32_t new_val = delta;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        new_val = self->fields[0].i + delta;
        self->fields[0] = DX_INT_VALUE(new_val);
    }
    frame->result = DX_INT_VALUE(new_val);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_atomic_int_get_and_add(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t delta = (arg_count >= 2) ? args[1].i : 0;
    int32_t old_val = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        old_val = self->fields[0].i;
        self->fields[0] = DX_INT_VALUE(old_val + delta);
    }
    frame->result = DX_INT_VALUE(old_val);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// AtomicBoolean — getAndSet
// ============================================================

static DxResult native_atomic_bool_get_and_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t old_val = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        old_val = self->fields[0].i ? 1 : 0;
        if (arg_count >= 2) {
            self->fields[0] = DX_INT_VALUE(args[1].i ? 1 : 0);
        }
    }
    frame->result = DX_INT_VALUE(old_val);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// AtomicReference — real field[0] storage
// ============================================================

static DxResult native_atomic_ref_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass
        && args[0].obj->klass->instance_field_count > 0) {
        // default: null
        args[0].obj->fields[0] = DX_NULL_VALUE;
    }
    return DX_OK;
}

static DxResult native_atomic_ref_init_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass
        && args[0].obj->klass->instance_field_count > 0) {
        args[0].obj->fields[0] = args[1];
    }
    return DX_OK;
}

static DxResult native_atomic_ref_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_atomic_ref_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 && arg_count >= 2) {
        self->fields[0] = args[1];
    }
    return DX_OK;
}

static DxResult native_atomic_ref_compare_and_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 && arg_count >= 3) {
        // Compare by object identity (pointer equality)
        DxObject *expected = (args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
        DxObject *current = (self->fields[0].tag == DX_VAL_OBJ) ? self->fields[0].obj : NULL;
        if (current == expected) {
            self->fields[0] = args[2];
            frame->result = DX_INT_VALUE(1);
        } else {
            frame->result = DX_INT_VALUE(0);
        }
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_atomic_ref_get_and_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue old_val = DX_NULL_VALUE;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        old_val = self->fields[0];
        if (arg_count >= 2) {
            self->fields[0] = args[1];
        }
    }
    frame->result = old_val;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// AtomicLong — field[0] stores long as int (single-threaded)
// ============================================================

static DxResult native_atomic_long_init_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass
        && args[0].obj->klass->instance_field_count > 0) {
        args[0].obj->fields[0] = DX_INT_VALUE((int32_t)args[1].i);
    }
    return DX_OK;
}

static DxResult native_atomic_long_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_atomic_long_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0 && arg_count >= 2) {
        self->fields[0] = DX_INT_VALUE((int32_t)args[1].i);
    }
    return DX_OK;
}

static DxResult native_atomic_long_increment_and_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t new_val = 1;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        new_val = self->fields[0].i + 1;
        self->fields[0] = DX_INT_VALUE(new_val);
    }
    frame->result = DX_INT_VALUE(new_val);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_atomic_long_get_and_increment(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t old_val = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        old_val = self->fields[0].i;
        self->fields[0] = DX_INT_VALUE(old_val + 1);
    }
    frame->result = DX_INT_VALUE(old_val);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// CountDownLatch — field[0] stores count
// ============================================================

static DxResult native_countdown_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass
        && args[0].obj->klass->instance_field_count > 0) {
        args[0].obj->fields[0] = DX_INT_VALUE(args[1].i);
    }
    return DX_OK;
}

static DxResult native_countdown_count_down(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        int32_t count = self->fields[0].i;
        if (count > 0) {
            self->fields[0] = DX_INT_VALUE(count - 1);
        }
    }
    return DX_OK;
}

static DxResult native_countdown_get_count(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Semaphore — field[0] stores permits
// ============================================================

static DxResult native_semaphore_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass
        && args[0].obj->klass->instance_field_count > 0) {
        args[0].obj->fields[0] = DX_INT_VALUE(args[1].i);
    }
    return DX_OK;
}

static DxResult native_semaphore_acquire(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        int32_t permits = self->fields[0].i;
        if (permits > 0) {
            self->fields[0] = DX_INT_VALUE(permits - 1);
        }
    }
    return DX_OK;
}

static DxResult native_semaphore_release(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        self->fields[0] = DX_INT_VALUE(self->fields[0].i + 1);
    }
    return DX_OK;
}

static DxResult native_semaphore_available_permits(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// ExecutorService.submit — runs Runnable synchronously, returns Future stub
// ============================================================

static DxResult native_executor_submit(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (ExecutorService), args[1] = Runnable/Callable
    DxValue call_result = DX_NULL_VALUE;
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxObject *runnable = args[1].obj;
        // Try call() first (Callable), then run() (Runnable)
        DxMethod *call_method = dx_vm_find_method(runnable->klass, "call", NULL);
        DxMethod *run_method = call_method ? NULL : dx_vm_find_method(runnable->klass, "run", NULL);
        DxMethod *method = call_method ? call_method : run_method;
        if (method) {
            DxValue run_args[1] = { DX_OBJ_VALUE(runnable) };
            DxValue result_val = DX_NULL_VALUE;
            dx_vm_execute_method(vm, method, run_args, 1, &result_val);
            if (vm->pending_exception) vm->pending_exception = NULL;
            if (call_method) call_result = result_val; // store Callable result
        }
    }
    // Return a Future with stored result
    DxClass *future_cls = dx_vm_find_class(vm, "Ljava/util/concurrent/Future;");
    if (future_cls) {
        DxObject *future = dx_vm_alloc_object(vm, future_cls);
        if (future && future->fields && future_cls->instance_field_count > 0) {
            future->fields[0] = call_result; // store result in field[0]
        }
        frame->result = future ? DX_OBJ_VALUE(future) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Executors factory — returns ExecutorService instance
// ============================================================

static DxResult native_executors_new_pool(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *svc_cls = dx_vm_find_class(vm, "Ljava/util/concurrent/ExecutorService;");
    if (svc_cls) {
        DxObject *svc = dx_vm_alloc_object(vm, svc_cls);
        frame->result = svc ? DX_OBJ_VALUE(svc) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Future.get() — return stored value from field[0]
// ============================================================

static DxResult native_future_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// CompletableFuture — field[0] stores value
// ============================================================

static DxResult native_cf_completed_future(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // static: args[0] = value
    DxClass *cf_cls = dx_vm_find_class(vm, "Ljava/util/concurrent/CompletableFuture;");
    if (cf_cls) {
        DxObject *cf = dx_vm_alloc_object(vm, cf_cls);
        if (cf && cf->fields && cf_cls->instance_field_count > 0) {
            cf->fields[0] = (arg_count >= 1) ? args[0] : DX_NULL_VALUE;
        }
        frame->result = cf ? DX_OBJ_VALUE(cf) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cf_then_apply(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (CompletableFuture), args[1] = Function
    DxValue current_val = DX_NULL_VALUE;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        current_val = self->fields[0];
    }

    DxValue new_val = DX_NULL_VALUE;
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxObject *func = args[1].obj;
        DxMethod *apply = dx_vm_find_method(func->klass, "apply", NULL);
        if (apply) {
            DxValue apply_args[2] = { DX_OBJ_VALUE(func), current_val };
            dx_vm_execute_method(vm, apply, apply_args, 2, &new_val);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    }

    // Return new CompletableFuture with transformed value
    DxClass *cf_cls = dx_vm_find_class(vm, "Ljava/util/concurrent/CompletableFuture;");
    if (cf_cls) {
        DxObject *cf = dx_vm_alloc_object(vm, cf_cls);
        if (cf && cf->fields && cf_cls->instance_field_count > 0) {
            cf->fields[0] = new_val;
        }
        frame->result = cf ? DX_OBJ_VALUE(cf) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cf_then_accept(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (CompletableFuture), args[1] = Consumer
    DxValue current_val = DX_NULL_VALUE;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        current_val = self->fields[0];
    }

    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxObject *consumer = args[1].obj;
        DxMethod *accept = dx_vm_find_method(consumer->klass, "accept", NULL);
        if (accept) {
            DxValue accept_args[2] = { DX_OBJ_VALUE(consumer), current_val };
            dx_vm_execute_method(vm, accept, accept_args, 2, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    }

    // Return new CompletableFuture with same value
    DxClass *cf_cls = dx_vm_find_class(vm, "Ljava/util/concurrent/CompletableFuture;");
    if (cf_cls) {
        DxObject *cf = dx_vm_alloc_object(vm, cf_cls);
        if (cf && cf->fields && cf_cls->instance_field_count > 0) {
            cf->fields[0] = current_val;
        }
        frame->result = cf ? DX_OBJ_VALUE(cf) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cf_then_run(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (CompletableFuture), args[1] = Runnable
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxObject *runnable = args[1].obj;
        DxMethod *run = dx_vm_find_method(runnable->klass, "run", NULL);
        if (run) {
            DxValue run_args[1] = { DX_OBJ_VALUE(runnable) };
            dx_vm_execute_method(vm, run, run_args, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    }

    // Return new CompletableFuture with null value
    DxClass *cf_cls = dx_vm_find_class(vm, "Ljava/util/concurrent/CompletableFuture;");
    if (cf_cls) {
        DxObject *cf = dx_vm_alloc_object(vm, cf_cls);
        frame->result = cf ? DX_OBJ_VALUE(cf) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_cf_complete(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0] = this, args[1] = value
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && arg_count >= 2) {
        self->fields[0] = args[1];
    }
    frame->result = DX_INT_VALUE(1); // return true
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// WeakReference / SoftReference — field[0] stores referent
// ============================================================

static DxResult native_weakref_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass
        && args[0].obj->klass->instance_field_count > 0) {
        args[0].obj->fields[0] = args[1]; // store referent
    }
    return DX_OK;
}

static DxResult native_weakref_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_weakref_clear(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0) {
        self->fields[0] = DX_NULL_VALUE;
    }
    return DX_OK;
}

// ============================================================
// kotlin.Lazy — call Function0.invoke() and return result
// ============================================================

static DxResult native_kotlin_lazy(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // lazy(initializer: () -> T) -> Lazy<T>
    // We call the function immediately and wrap result
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        DxObject *func = args[0].obj;
        DxMethod *invoke = dx_vm_find_method(func->klass, "invoke", NULL);
        if (invoke) {
            DxValue invoke_args[1] = { DX_OBJ_VALUE(func) };
            DxValue result = DX_NULL_VALUE;
            dx_vm_execute_method(vm, invoke, invoke_args, 1, &result);
            if (vm->pending_exception) vm->pending_exception = NULL;
            frame->result = result;
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Kotlin coroutines — launch/async execute lambda synchronously
// ============================================================

// launch(scope, context, start, block) -> Job
// Executes the block synchronously and returns a completed Job stub
static DxResult native_coroutine_launch(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args: scope, context, start, block  (or just scope + block in simplified form)
    // Find the last object arg that has an invoke method — that's the lambda
    for (int i = (int)arg_count - 1; i >= 0; i--) {
        if (args[i].tag == DX_VAL_OBJ && args[i].obj) {
            DxMethod *invoke = dx_vm_find_method(args[i].obj->klass, "invoke", NULL);
            if (invoke) {
                DxValue invoke_args[2] = { DX_OBJ_VALUE(args[i].obj), DX_NULL_VALUE };
                DxValue result = DX_NULL_VALUE;
                dx_vm_execute_method(vm, invoke, invoke_args, 2, &result);
                if (vm->pending_exception) vm->pending_exception = NULL;
                break;
            }
        }
    }
    // Return a Job stub object
    DxClass *job_cls = dx_vm_find_class(vm, "Lkotlinx/coroutines/Job;");
    if (job_cls) {
        DxObject *job = dx_vm_alloc_object(vm, job_cls);
        frame->result = DX_OBJ_VALUE(job);
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// async(scope, context, start, block) -> Deferred
static DxResult native_coroutine_async(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxValue lambda_result = DX_NULL_VALUE;
    for (int i = (int)arg_count - 1; i >= 0; i--) {
        if (args[i].tag == DX_VAL_OBJ && args[i].obj) {
            DxMethod *invoke = dx_vm_find_method(args[i].obj->klass, "invoke", NULL);
            if (invoke) {
                DxValue invoke_args[2] = { DX_OBJ_VALUE(args[i].obj), DX_NULL_VALUE };
                dx_vm_execute_method(vm, invoke, invoke_args, 2, &lambda_result);
                if (vm->pending_exception) vm->pending_exception = NULL;
                break;
            }
        }
    }
    // Return a Deferred stub with the result stored
    DxClass *deferred_cls = dx_vm_find_class(vm, "Lkotlinx/coroutines/Deferred;");
    if (deferred_cls) {
        DxObject *deferred = dx_vm_alloc_object(vm, deferred_cls);
        if (deferred) {
            dx_vm_set_field(deferred, "_result", lambda_result);
        }
        frame->result = DX_OBJ_VALUE(deferred);
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Deferred.await() / getCompleted() — return stored _result
static DxResult native_deferred_await(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        DxValue stored;
        if (dx_vm_get_field(args[0].obj, "_result", &stored) == DX_OK) {
            frame->result = stored;
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// StateFlow.getValue() — return stored _value
static DxResult native_stateflow_get_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        DxValue stored;
        if (dx_vm_get_field(args[0].obj, "_value", &stored) == DX_OK) {
            frame->result = stored;
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// MutableStateFlow.setValue(T) — store _value
static DxResult native_stateflow_set_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        dx_vm_set_field(args[0].obj, "_value", args[1]);
    }
    return DX_OK;
}

// MutableStateFlow constructor — <init>(initialValue)
static DxResult native_mutable_stateflow_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        dx_vm_set_field(args[0].obj, "_value", args[1]);
    }
    return DX_OK;
}

// CoroutineContext.plus() — return self
static DxResult native_coroutine_context_plus(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    frame->result = (arg_count >= 1) ? args[0] : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// CoroutineScope.getCoroutineContext() — return stub context
static DxResult native_scope_get_context(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *ctx_cls = dx_vm_find_class(vm, "Lkotlin/coroutines/CoroutineContext;");
    if (ctx_cls) {
        frame->result = DX_OBJ_VALUE(dx_vm_alloc_object(vm, ctx_cls));
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Dispatchers.getMain/getIO/getDefault/getUnconfined — return stub dispatcher
static DxResult native_dispatchers_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *disp_cls = dx_vm_find_class(vm, "Lkotlinx/coroutines/CoroutineDispatcher;");
    if (disp_cls) {
        frame->result = DX_OBJ_VALUE(dx_vm_alloc_object(vm, disp_cls));
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Thread.<init>(Runnable) — store Runnable target in field[0]
// ============================================================

static DxResult native_thread_init_runnable(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count >= 2 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass
        && args[0].obj->klass->instance_field_count > 0) {
        args[0].obj->fields[0] = args[1]; // store Runnable target
    }
    return DX_OK;
}

// ============================================================
// Thread.start() — invoke Runnable.run() or this.run() synchronously
// ============================================================

static DxResult native_thread_start(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count < 1 || args[0].tag != DX_VAL_OBJ || !args[0].obj) return DX_OK;

    DxObject *thread_obj = args[0].obj;

    // First, check if a Runnable target was stored in field[0]
    if (thread_obj->fields && thread_obj->klass
        && thread_obj->klass->instance_field_count > 0
        && thread_obj->fields[0].tag == DX_VAL_OBJ
        && thread_obj->fields[0].obj) {
        DxObject *runnable = thread_obj->fields[0].obj;
        DxMethod *run_method = dx_vm_find_method(runnable->klass, "run", NULL);
        if (run_method) {
            DX_DEBUG("Thread", "start() executing Runnable.run() synchronously on %s",
                    runnable->klass ? runnable->klass->descriptor : "?");
            DxValue run_args[1] = { DX_OBJ_VALUE(runnable) };
            dx_vm_execute_method(vm, run_method, run_args, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
            return DX_OK;
        }
    }

    // Fallback: call this.run() (for Thread subclasses that override run())
    DxMethod *run_method = dx_vm_find_method(thread_obj->klass, "run", NULL);
    if (run_method) {
        DX_DEBUG("Thread", "start() executing run() synchronously on %s",
                thread_obj->klass ? thread_obj->klass->descriptor : "?");
        DxValue run_args[1] = { DX_OBJ_VALUE(thread_obj) };
        dx_vm_execute_method(vm, run_method, run_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }
    return DX_OK;
}

static DxResult native_thread_current(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    // Return a singleton "main" thread object
    DxClass *cls = dx_vm_find_class(vm, "Ljava/lang/Thread;");
    if (!cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *t = dx_vm_alloc_object(vm, cls);
    frame->result = t ? DX_OBJ_VALUE(t) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// System.currentTimeMillis / nanoTime
// ============================================================

static DxResult native_system_current_time_millis(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    int64_t millis = (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    frame->result.tag = DX_VAL_LONG;
    frame->result.l = millis;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_system_nano_time(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    int64_t nanos = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
    frame->result.tag = DX_VAL_LONG;
    frame->result.l = nanos;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Log.d/i/w/e/v — forward to DexLoom logging system
// ============================================================

static DxResult native_log_debug(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    const char *tag_str = (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj)
        ? dx_vm_get_string_value(args[0].obj) : "App";
    const char *msg_str = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : "";
    DX_DEBUG(tag_str ? tag_str : "App", "%s", msg_str ? msg_str : "");
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    (void)vm;
    return DX_OK;
}

static DxResult native_log_info(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *tag_str = (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj)
        ? dx_vm_get_string_value(args[0].obj) : "App";
    const char *msg_str = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : "";
    DX_INFO(tag_str ? tag_str : "App", "%s", msg_str ? msg_str : "");
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_log_warn(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *tag_str = (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj)
        ? dx_vm_get_string_value(args[0].obj) : "App";
    const char *msg_str = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : "";
    DX_WARN(tag_str ? tag_str : "App", "%s", msg_str ? msg_str : "");
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_log_error(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *tag_str = (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj)
        ? dx_vm_get_string_value(args[0].obj) : "App";
    const char *msg_str = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : "";
    DX_ERROR(tag_str ? tag_str : "App", "%s", msg_str ? msg_str : "");
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Handler.post / postDelayed — execute Runnable synchronously
// ============================================================

static DxResult native_handler_post(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (Handler), args[1] = Runnable
    if (arg_count < 2 || args[1].tag != DX_VAL_OBJ || !args[1].obj) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *runnable = args[1].obj;
    DxMethod *run_method = dx_vm_find_method(runnable->klass, "run", NULL);
    if (run_method) {
        DX_DEBUG("Handler", "post() executing Runnable.run() synchronously");
        DxValue run_args[1] = { DX_OBJ_VALUE(runnable) };
        dx_vm_execute_method(vm, run_method, run_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL; // absorb
    } else {
        DX_DEBUG("Handler", "post() - no run() method on %s",
                runnable->klass ? runnable->klass->descriptor : "?");
    }

    frame->result = DX_INT_VALUE(1); // return true
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_handler_post_delayed(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (Handler), args[1] = Runnable, args[2-3] = delay (long, ignored)
    if (arg_count < 2 || args[1].tag != DX_VAL_OBJ || !args[1].obj) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *runnable = args[1].obj;
    DxMethod *run_method = dx_vm_find_method(runnable->klass, "run", NULL);
    if (run_method) {
        DX_DEBUG("Handler", "postDelayed() executing Runnable.run() synchronously (delay ignored)");
        DxValue run_args[1] = { DX_OBJ_VALUE(runnable) };
        dx_vm_execute_method(vm, run_method, run_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    frame->result = DX_INT_VALUE(1);
    frame->has_result = true;
    return DX_OK;
}

// Same for View.post / View.postDelayed
static DxResult native_view_post(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (View), args[1] = Runnable
    if (arg_count < 2 || args[1].tag != DX_VAL_OBJ || !args[1].obj) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *runnable = args[1].obj;
    DxMethod *run_method = dx_vm_find_method(runnable->klass, "run", NULL);
    if (run_method) {
        DX_DEBUG("View", "post() executing Runnable.run() synchronously");
        DxValue run_args[1] = { DX_OBJ_VALUE(runnable) };
        dx_vm_execute_method(vm, run_method, run_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    frame->result = DX_INT_VALUE(1);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_view_post_delayed(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    return native_view_post(vm, frame, args, arg_count > 2 ? 2 : arg_count);
}

// ============================================================
// Resources.getString — look up string from resources.arsc
// ============================================================

static DxResult native_resources_get_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (Resources), args[1] = int resId
    if (arg_count < 2) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    uint32_t res_id = (uint32_t)args[1].i;
    const char *str_val = NULL;

    // Look up via DxResources in context
    if (vm->ctx && vm->ctx->resources) {
        str_val = dx_resources_get_string_by_id(vm->ctx->resources, res_id);
    }

    if (str_val) {
        DxObject *str_obj = dx_vm_create_string(vm, str_val);
        frame->result = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
    } else {
        // Fallback: return resource ID as string for debugging
        char buf[32];
        snprintf(buf, sizeof(buf), "res:0x%08x", res_id);
        DxObject *str_obj = dx_vm_create_string(vm, buf);
        frame->result = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Resources.getStringArray — look up string-array resource
// ============================================================

static DxResult native_resources_get_string_array(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (Resources), args[1] = int resId
    if (arg_count < 2 || !vm->ctx || !vm->ctx->resources) {
        DxObject *arr = dx_vm_alloc_array(vm, 0);
        frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    uint32_t res_id = (uint32_t)args[1].i;
    uint32_t count = 0;
    const char **strings = dx_resources_get_string_array(vm->ctx->resources, res_id, &count);

    DxObject *arr = dx_vm_alloc_array(vm, count);
    if (arr && strings) {
        for (uint32_t i = 0; i < count; i++) {
            DxObject *str_obj = dx_vm_create_string(vm, strings[i] ? strings[i] : "");
            arr->array_elements[i] = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
        }
    }
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Resources.getIntArray — look up integer-array resource
// ============================================================

static DxResult native_resources_get_int_array(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (Resources), args[1] = int resId
    if (arg_count < 2 || !vm->ctx || !vm->ctx->resources) {
        DxObject *arr = dx_vm_alloc_array(vm, 0);
        frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    uint32_t res_id = (uint32_t)args[1].i;
    uint32_t count = 0;
    const int32_t *ints = dx_resources_get_integer_array(vm->ctx->resources, res_id, &count);

    DxObject *arr = dx_vm_alloc_array(vm, count);
    if (arr && ints) {
        for (uint32_t i = 0; i < count; i++) {
            arr->array_elements[i] = DX_INT_VALUE(ints[i]);
        }
    }
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Resources.getQuantityString — look up plural resource
// ============================================================

static DxResult native_resources_get_quantity_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (Resources), args[1] = int resId, args[2] = int quantity
    if (arg_count < 3) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    uint32_t res_id = (uint32_t)args[1].i;
    int quantity = (int)args[2].i;
    const char *str_val = NULL;

    if (vm->ctx && vm->ctx->resources) {
        str_val = dx_resources_get_plural(vm->ctx->resources, res_id, quantity);
    }

    if (str_val) {
        DxObject *str_obj = dx_vm_create_string(vm, str_val);
        frame->result = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
    } else {
        char buf[32];
        snprintf(buf, sizeof(buf), "plural:0x%08x", res_id);
        DxObject *str_obj = dx_vm_create_string(vm, buf);
        frame->result = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Resources.obtainTypedArray — return TypedArray wrapping array resource
// ============================================================

static DxResult native_resources_obtain_typed_array(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (Resources), args[1] = int resId
    DxClass *ta_cls = dx_vm_find_class(vm, "Landroid/content/res/TypedArray;");
    if (!ta_cls) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *ta_obj = dx_vm_alloc_object(vm, ta_cls);
    if (!ta_obj) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Store the resource ID in field[0] so TypedArray methods can look up values
    if (ta_obj->fields && ta_cls->instance_field_count > 0 && arg_count >= 2) {
        ta_obj->fields[0] = DX_INT_VALUE(args[1].i);
    }

    frame->result = DX_OBJ_VALUE(ta_obj);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// TypedArray.getString(index) — look up string from backing array
// ============================================================

static DxResult native_typed_array_get_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (TypedArray), args[1] = int index
    if (arg_count < 2 || !args[0].obj || !vm->ctx || !vm->ctx->resources) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *ta = args[0].obj;
    uint32_t index = (uint32_t)args[1].i;

    // Get resource ID from field[0]
    uint32_t res_id = 0;
    if (ta->fields && ta->klass && ta->klass->instance_field_count > 0) {
        res_id = (uint32_t)ta->fields[0].i;
    }

    if (res_id != 0) {
        uint32_t count = 0;
        const char **strings = dx_resources_get_string_array(vm->ctx->resources, res_id, &count);
        if (strings && index < count && strings[index]) {
            DxObject *str_obj = dx_vm_create_string(vm, strings[index]);
            frame->result = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
            frame->has_result = true;
            return DX_OK;
        }
    }

    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// TypedArray.getInt(index, defValue) — look up int from backing array
// ============================================================

static DxResult native_typed_array_get_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this, args[1] = int index, args[2] = int defValue
    if (arg_count < 3 || !args[0].obj || !vm->ctx || !vm->ctx->resources) {
        frame->result = DX_INT_VALUE(arg_count >= 3 ? args[2].i : 0);
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *ta = args[0].obj;
    uint32_t index = (uint32_t)args[1].i;
    int32_t def_val = args[2].i;

    uint32_t res_id = 0;
    if (ta->fields && ta->klass && ta->klass->instance_field_count > 0) {
        res_id = (uint32_t)ta->fields[0].i;
    }

    if (res_id != 0) {
        uint32_t count = 0;
        const int32_t *ints = dx_resources_get_integer_array(vm->ctx->resources, res_id, &count);
        if (ints && index < count) {
            frame->result = DX_INT_VALUE(ints[index]);
            frame->has_result = true;
            return DX_OK;
        }
    }

    frame->result = DX_INT_VALUE(def_val);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// TypedArray.getColor(index, defValue) — look up color from backing array
// ============================================================

static DxResult native_typed_array_get_color(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Same as getInt for now (colors are stored as ints in integer-array)
    return native_typed_array_get_int(vm, frame, args, arg_count);
}

// ============================================================
// TypedArray.length() — return count of elements in backing array
// ============================================================

static DxResult native_typed_array_length(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (TypedArray)
    if (arg_count < 1 || !args[0].obj || !vm->ctx || !vm->ctx->resources) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *ta = args[0].obj;
    uint32_t res_id = 0;
    if (ta->fields && ta->klass && ta->klass->instance_field_count > 0) {
        res_id = (uint32_t)ta->fields[0].i;
    }

    if (res_id != 0) {
        const DxArrayResource *arr_res = dx_resources_find_array(vm->ctx->resources, res_id);
        if (arr_res) {
            frame->result = DX_INT_VALUE((int32_t)arr_res->count);
            frame->has_result = true;
            return DX_OK;
        }
    }

    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

// Context.getString delegates to Resources.getString
static DxResult native_context_get_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    return native_resources_get_string(vm, frame, args, arg_count);
}

// ============================================================
// Context.getResources — return a Resources object
// ============================================================

static DxResult native_context_get_resources(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    if (vm->class_resources) {
        DxObject *res_obj = dx_vm_alloc_object(vm, vm->class_resources);
        frame->result = res_obj ? DX_OBJ_VALUE(res_obj) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context.getPackageName — return manifest package name
// ============================================================

static DxResult native_context_get_package_name(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    const char *pkg = (vm->ctx && vm->ctx->package_name) ? vm->ctx->package_name : "com.unknown";
    DxObject *str_obj = dx_vm_create_string(vm, pkg);
    frame->result = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Helper: create a java.io.File object with a given path
static DxObject *create_file_object(DxVM *vm, const char *path) {
    DxClass *file_cls = dx_vm_find_class(vm, "Ljava/io/File;");
    if (!file_cls) return NULL;
    DxObject *file_obj = dx_vm_alloc_object(vm, file_cls);
    if (file_obj && file_obj->fields && file_cls->instance_field_count > 0) {
        DxObject *path_str = dx_vm_create_string(vm, path);
        if (path_str) file_obj->fields[0] = DX_OBJ_VALUE(path_str);
    }
    return file_obj;
}

// Context.getFilesDir — return File object with sandbox path
static DxResult native_context_get_files_dir(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *file_obj = create_file_object(vm, "/data/data/app/files");
    frame->result = file_obj ? DX_OBJ_VALUE(file_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Context.getCacheDir — return File object with cache path
static DxResult native_context_get_cache_dir(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *file_obj = create_file_object(vm, "/data/data/app/cache");
    frame->result = file_obj ? DX_OBJ_VALUE(file_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Context.getExternalFilesDir(type) — return File with iOS-mapped path
static DxResult native_context_get_external_files_dir(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    // args[0] = this (Context), args[1] = type (String or null)
    const char *type = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        type = dx_vm_get_string_value(args[1].obj);
    }
    char path[256];
    if (type && type[0]) {
        snprintf(path, sizeof(path), "/sdcard/Android/data/app/files/%s", type);
    } else {
        snprintf(path, sizeof(path), "/sdcard/Android/data/app/files");
    }
    DxObject *file_obj = create_file_object(vm, path);
    frame->result = file_obj ? DX_OBJ_VALUE(file_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Permission helpers
// ============================================================

// Check if a permission is "safe" (auto-granted)
static bool is_safe_permission(const char *perm) {
    if (!perm) return false;
    if (strcmp(perm, "android.permission.INTERNET") == 0) return true;
    if (strcmp(perm, "android.permission.ACCESS_NETWORK_STATE") == 0) return true;
    if (strcmp(perm, "android.permission.ACCESS_WIFI_STATE") == 0) return true;
    if (strcmp(perm, "android.permission.VIBRATE") == 0) return true;
    if (strcmp(perm, "android.permission.WAKE_LOCK") == 0) return true;
    if (strcmp(perm, "android.permission.RECEIVE_BOOT_COMPLETED") == 0) return true;
    if (strcmp(perm, "android.permission.FOREGROUND_SERVICE") == 0) return true;
    if (strcmp(perm, "android.permission.SET_ALARM") == 0) return true;
    if (strcmp(perm, "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS") == 0) return true;
    if (strcmp(perm, "android.permission.NFC") == 0) return true;
    if (strcmp(perm, "android.permission.BLUETOOTH") == 0) return true;
    if (strcmp(perm, "android.permission.BLUETOOTH_ADMIN") == 0) return true;
    return false;
}

// Context.checkSelfPermission(permission) — GRANTED for safe, DENIED for dangerous
static DxResult native_check_self_permission(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0] = this, args[1] = permission string
    const char *perm = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        perm = dx_vm_get_string_value(args[1].obj);
    }
    int result = is_safe_permission(perm) ? 0 : -1; // 0=GRANTED, -1=DENIED
    frame->result = DX_INT_VALUE(result);
    frame->has_result = true;
    return DX_OK;
}

// ContextCompat.checkSelfPermission(context, permission) — static version
static DxResult native_compat_check_permission(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0] = context, args[1] = permission string
    const char *perm = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        perm = dx_vm_get_string_value(args[1].obj);
    }
    int result = is_safe_permission(perm) ? 0 : -1;
    frame->result = DX_INT_VALUE(result);
    frame->has_result = true;
    return DX_OK;
}

// Activity.requestPermissions(String[], int) — call onRequestPermissionsResult with all GRANTED
static DxResult native_activity_request_permissions(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    // args[0] = this (Activity), args[1] = String[] permissions, args[2] = requestCode
    DxObject *activity = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *perms_arr = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    int32_t request_code = (arg_count > 2 && args[2].tag == DX_VAL_INT) ? args[2].i : 0;

    if (!activity || !activity->klass) return DX_OK;

    // Build grantResults array — all PERMISSION_GRANTED (0)
    uint32_t perm_count = (perms_arr && perms_arr->is_array) ? perms_arr->array_length : 0;
    DxObject *grant_arr = dx_vm_alloc_array(vm, perm_count);
    if (grant_arr) {
        for (uint32_t i = 0; i < perm_count; i++) {
            grant_arr->array_elements[i] = DX_INT_VALUE(0); // PERMISSION_GRANTED
        }
    }

    // Call onRequestPermissionsResult(requestCode, permissions, grantResults)
    DxMethod *callback = dx_vm_find_method(activity->klass, "onRequestPermissionsResult", NULL);
    if (callback) {
        DX_INFO(TAG, "requestPermissions: delivering onRequestPermissionsResult(requestCode=%d, count=%u)",
                request_code, perm_count);
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue cb_args[4] = {
            DX_OBJ_VALUE(activity),
            DX_INT_VALUE(request_code),
            perms_arr ? DX_OBJ_VALUE(perms_arr) : DX_NULL_VALUE,
            grant_arr ? DX_OBJ_VALUE(grant_arr) : DX_NULL_VALUE
        };
        dx_vm_execute_method(vm, callback, cb_args, 4, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }
    return DX_OK;
}

// ActivityCompat.requestPermissions(activity, permissions, requestCode) — static version
static DxResult native_compat_request_permissions(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    return native_activity_request_permissions(vm, frame, args, arg_count);
}

// Context.getSharedPreferences — return SharedPreferences object
static DxResult native_context_get_shared_prefs(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    if (vm->class_shared_prefs) {
        DxObject *prefs = dx_vm_alloc_object(vm, vm->class_shared_prefs);
        frame->result = prefs ? DX_OBJ_VALUE(prefs) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// TextUtils static methods
// ============================================================

static DxResult native_textutils_isempty(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    if (args[0].tag != DX_VAL_OBJ || !args[0].obj) {
        frame->result = DX_INT_VALUE(1); // null is empty
        frame->has_result = true;
        return DX_OK;
    }
    const char *s = dx_vm_get_string_value(args[0].obj);
    frame->result = DX_INT_VALUE(!s || s[0] == '\0' ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_textutils_equals(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    if (args[0].obj == args[1].obj) {
        frame->result = DX_INT_VALUE(1);
        frame->has_result = true;
        return DX_OK;
    }
    const char *a = args[0].obj ? dx_vm_get_string_value(args[0].obj) : NULL;
    const char *b = args[1].obj ? dx_vm_get_string_value(args[1].obj) : NULL;
    if (!a && !b) { frame->result = DX_INT_VALUE(1); }
    else if (!a || !b) { frame->result = DX_INT_VALUE(0); }
    else { frame->result = DX_INT_VALUE(strcmp(a, b) == 0 ? 1 : 0); }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_textutils_trimmed_length(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    if (args[0].tag != DX_VAL_OBJ || !args[0].obj) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }
    const char *s = dx_vm_get_string_value(args[0].obj);
    if (!s) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    size_t len = strlen(s);
    // Trim leading/trailing whitespace
    size_t start = 0, end = len;
    while (start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r')) start++;
    while (end > start && (s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\n' || s[end-1] == '\r')) end--;
    frame->result = DX_INT_VALUE((int32_t)(end - start));
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_textutils_concat(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Concatenate all CharSequence arguments
    char buf[1024] = {0};
    size_t off = 0;
    for (uint32_t i = 0; i < arg_count && off < sizeof(buf) - 1; i++) {
        if (args[i].tag == DX_VAL_OBJ && args[i].obj) {
            const char *s = dx_vm_get_string_value(args[i].obj);
            if (s) {
                size_t slen = strlen(s);
                if (off + slen >= sizeof(buf)) slen = sizeof(buf) - 1 - off;
                memcpy(buf + off, s, slen);
                off += slen;
            }
        }
    }
    buf[off] = '\0';
    DxObject *result = dx_vm_create_string(vm, buf);
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Math native methods
// ============================================================

static DxResult native_math_min_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    int32_t a = args[0].i, b = args[1].i;
    frame->result = DX_INT_VALUE(a < b ? a : b);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_math_max_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    int32_t a = args[0].i, b = args[1].i;
    frame->result = DX_INT_VALUE(a > b ? a : b);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_math_abs_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    int32_t a = args[0].i;
    frame->result = DX_INT_VALUE(a < 0 ? -a : a);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Dialog native methods
// ============================================================

static DxResult native_dialog_get_context(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    // Return the activity instance as context
    frame->result = vm->activity_instance ? DX_OBJ_VALUE(vm->activity_instance) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_dialog_get_window(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *win_cls = dx_vm_find_class(vm, "Landroid/view/Window;");
    if (win_cls) {
        DxObject *win = dx_vm_alloc_object(vm, win_cls);
        frame->result = win ? DX_OBJ_VALUE(win) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_dialog_get_layout_inflater(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    if (vm->class_inflater) {
        DxObject *inflater = dx_vm_alloc_object(vm, vm->class_inflater);
        if (inflater) {
            frame->result = DX_OBJ_VALUE(inflater);
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// LayoutInflater.from() - return inflater object
// ============================================================

static DxResult native_inflater_from(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    if (vm->class_inflater) {
        DxObject *inflater = dx_vm_alloc_object(vm, vm->class_inflater);
        if (inflater) {
            frame->result = DX_OBJ_VALUE(inflater);
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// SharedPreferences native methods
// ============================================================

// Helper: find pref by key
static int prefs_find(DxVM *vm, const char *key) {
    if (!key) return -1;
    for (uint32_t i = 0; i < vm->prefs_count; i++) {
        if (vm->prefs[i].key && strcmp(vm->prefs[i].key, key) == 0) return (int)i;
    }
    return -1;
}

static DxResult native_prefs_get_boolean(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0]=this, args[1]=key (String), args[2]=defValue (boolean)
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    int idx = prefs_find(vm, key);
    if (idx >= 0) {
        frame->result = DX_INT_VALUE(vm->prefs[idx].value.i);
    } else {
        frame->result = (arg_count > 2) ? DX_INT_VALUE(args[2].i) : DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_prefs_get_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    int idx = prefs_find(vm, key);
    if (idx >= 0) {
        frame->result = vm->prefs[idx].value;
    } else {
        frame->result = (arg_count > 2) ? args[2] : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_prefs_get_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    int idx = prefs_find(vm, key);
    if (idx >= 0) {
        frame->result = DX_INT_VALUE(vm->prefs[idx].value.i);
    } else {
        frame->result = (arg_count > 2) ? DX_INT_VALUE(args[2].i) : DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_prefs_get_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    int idx = prefs_find(vm, key);
    if (idx >= 0) {
        frame->result = vm->prefs[idx].value;
    } else {
        frame->result.tag = DX_VAL_LONG;
        frame->result.l = (arg_count > 2) ? args[2].l : 0;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_prefs_get_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    int idx = prefs_find(vm, key);
    if (idx >= 0) {
        frame->result = vm->prefs[idx].value;
    } else {
        frame->result.tag = DX_VAL_FLOAT;
        frame->result.f = (arg_count > 2) ? args[2].f : 0.0f;
    }
    frame->has_result = true;
    return DX_OK;
}

// SharedPreferences.Editor.put* — store in VM prefs table
static DxResult native_prefs_editor_put_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0]=this (Editor), args[1]=key, args[2]=value
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    if (key) {
        int idx = prefs_find(vm, key);
        if (idx < 0 && vm->prefs_count < DX_MAX_PREFS_ENTRIES) {
            idx = (int)vm->prefs_count++;
            vm->prefs[idx].key = dx_strdup(key);
        }
        if (idx >= 0) {
            vm->prefs[idx].value = (arg_count > 2) ? args[2] : DX_NULL_VALUE;
        }
    }
    // Return self (Editor) for chaining
    frame->result = args[0];
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_prefs_editor_put_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    if (key) {
        int idx = prefs_find(vm, key);
        if (idx < 0 && vm->prefs_count < DX_MAX_PREFS_ENTRIES) {
            idx = (int)vm->prefs_count++;
            vm->prefs[idx].key = dx_strdup(key);
        }
        if (idx >= 0) {
            vm->prefs[idx].value = (arg_count > 2) ? DX_INT_VALUE(args[2].i) : DX_INT_VALUE(0);
        }
    }
    frame->result = args[0];
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_prefs_editor_put_boolean(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    return native_prefs_editor_put_int(vm, frame, args, arg_count);
}

static DxResult native_prefs_editor_put_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    if (key) {
        int idx = prefs_find(vm, key);
        if (idx < 0 && vm->prefs_count < DX_MAX_PREFS_ENTRIES) {
            idx = (int)vm->prefs_count++;
            vm->prefs[idx].key = dx_strdup(key);
        }
        if (idx >= 0) {
            vm->prefs[idx].value.tag = DX_VAL_LONG;
            vm->prefs[idx].value.l = (arg_count > 2) ? args[2].l : 0;
        }
    }
    frame->result = args[0];
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_prefs_editor_put_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    if (key) {
        int idx = prefs_find(vm, key);
        if (idx < 0 && vm->prefs_count < DX_MAX_PREFS_ENTRIES) {
            idx = (int)vm->prefs_count++;
            vm->prefs[idx].key = dx_strdup(key);
        }
        if (idx >= 0) {
            vm->prefs[idx].value.tag = DX_VAL_FLOAT;
            vm->prefs[idx].value.f = (arg_count > 2) ? args[2].f : 0.0f;
        }
    }
    frame->result = args[0];
    frame->has_result = true;
    return DX_OK;
}

// Editor.commit/apply — just return true (data already stored)
static DxResult native_prefs_editor_commit(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(1); // true
    frame->has_result = true;
    return DX_OK;
}

// SharedPreferences.contains
static DxResult native_prefs_contains(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *key = (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        ? dx_vm_get_string_value(args[1].obj) : NULL;
    int idx = prefs_find(vm, key);
    frame->result = DX_INT_VALUE(idx >= 0 ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// SharedPreferences.edit — return an Editor object
static DxResult native_prefs_edit(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *editor_cls = dx_vm_find_class(vm, "Landroid/content/SharedPreferences$Editor;");
    if (editor_cls) {
        DxObject *editor = dx_vm_alloc_object(vm, editor_cls);
        frame->result = editor ? DX_OBJ_VALUE(editor) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// TextView native methods
// ============================================================

static DxResult native_textview_set_text(DxVM *vm, DxFrame *frame,
                                          DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *text_obj = (arg_count > 1) ? args[1].obj : NULL;

    if (!self || !self->ui_node) {
        DX_WARN(TAG, "setText on object without UI node");
        return DX_OK;
    }

    const char *text = "";
    if (text_obj) {
        text = dx_vm_get_string_value(text_obj);
        if (!text) text = "";
    }

    dx_ui_node_set_text(self->ui_node, text);
    DX_INFO(TAG, "setText(\"%s\") on view 0x%x", text, self->ui_node->view_id);

    // Trigger UI update
    rebuild_render_model(vm);
    return DX_OK;
}

static DxResult native_textview_get_text(DxVM *vm, DxFrame *frame,
                                          DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;

    if (!self || !self->ui_node || !self->ui_node->text) {
        DxObject *empty = dx_vm_create_string(vm, "");
        frame->result = DX_OBJ_VALUE(empty);
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *str = dx_vm_create_string(vm, self->ui_node->text);
    frame->result = DX_OBJ_VALUE(str);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Helper: Rebuild render model and notify host
// ============================================================

static void rebuild_render_model(DxVM *vm) {
    DxContext *ctx = vm->ctx;
    if (!ctx || !ctx->ui_root) return;

    if (ctx->render_model) {
        dx_render_model_destroy(ctx->render_model);
    }
    ctx->render_model = dx_render_model_create(ctx->ui_root);

    if (ctx->on_ui_update && ctx->render_model) {
        ctx->on_ui_update(ctx->render_model, ctx->ui_callback_data);
    }
}

// ============================================================
// Menu / MenuItem / MenuInflater / SubMenu native methods
// ============================================================

// MenuItem instance field layout:
// field[0] = itemId (int)
// field[1] = title (DxObject* string)
// field[2] = icon (int resource id)
// field[3] = showAsAction (int)
#define DX_MENUITEM_FIELD_ID        0
#define DX_MENUITEM_FIELD_TITLE     1
#define DX_MENUITEM_FIELD_ICON      2
#define DX_MENUITEM_FIELD_SHOWASACT 3
#define DX_MENUITEM_FIELD_COUNT     4

// Menu instance field layout:
// field[0] = items array object (DxObject* array of MenuItem)
// field[1] = item count (int)
#define DX_MENU_FIELD_ITEMS   0
#define DX_MENU_FIELD_COUNT   1
#define DX_MENU_FIELD_TOTAL   2
#define DX_MENU_MAX_ITEMS     32

// Menu.add(int groupId, int itemId, int order, CharSequence title) -> MenuItem
static DxResult native_menu_add_full(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self || !self->fields) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    int32_t item_id = (arg_count > 2) ? args[2].i : 0;
    DxObject *title_obj = (arg_count > 4) ? args[4].obj : NULL;

    DxClass *menu_item_cls = dx_vm_find_class(vm, "Landroid/view/MenuItem;");
    if (!menu_item_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    DxObject *item = dx_vm_alloc_object(vm, menu_item_cls);
    if (!item) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    item->fields[DX_MENUITEM_FIELD_ID] = DX_INT_VALUE(item_id);
    item->fields[DX_MENUITEM_FIELD_TITLE] = title_obj ? DX_OBJ_VALUE(title_obj) : DX_NULL_VALUE;
    item->fields[DX_MENUITEM_FIELD_ICON] = DX_INT_VALUE(0);
    item->fields[DX_MENUITEM_FIELD_SHOWASACT] = DX_INT_VALUE(0);

    // Store in Menu's internal list
    DxObject *items_arr = self->fields[DX_MENU_FIELD_ITEMS].obj;
    int32_t count = self->fields[DX_MENU_FIELD_COUNT].i;
    if (items_arr && items_arr->is_array && count < DX_MENU_MAX_ITEMS) {
        items_arr->array_elements[count] = DX_OBJ_VALUE(item);
        self->fields[DX_MENU_FIELD_COUNT] = DX_INT_VALUE(count + 1);
    }

    DX_DEBUG(TAG, "Menu.add(group=%d, id=%d) -> MenuItem", (arg_count > 1) ? args[1].i : 0, item_id);
    frame->result = DX_OBJ_VALUE(item);
    frame->has_result = true;
    return DX_OK;
}

// Menu.add(CharSequence title) -> MenuItem (simplified)
static DxResult native_menu_add_simple(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *title_obj = (arg_count > 1) ? args[1].obj : NULL;

    if (!self || !self->fields) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    DxClass *menu_item_cls = dx_vm_find_class(vm, "Landroid/view/MenuItem;");
    if (!menu_item_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    DxObject *item = dx_vm_alloc_object(vm, menu_item_cls);
    if (!item) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    int32_t count = self->fields[DX_MENU_FIELD_COUNT].i;
    item->fields[DX_MENUITEM_FIELD_ID] = DX_INT_VALUE(count); // auto-assign ID
    item->fields[DX_MENUITEM_FIELD_TITLE] = title_obj ? DX_OBJ_VALUE(title_obj) : DX_NULL_VALUE;
    item->fields[DX_MENUITEM_FIELD_ICON] = DX_INT_VALUE(0);
    item->fields[DX_MENUITEM_FIELD_SHOWASACT] = DX_INT_VALUE(0);

    DxObject *items_arr = self->fields[DX_MENU_FIELD_ITEMS].obj;
    if (items_arr && items_arr->is_array && count < DX_MENU_MAX_ITEMS) {
        items_arr->array_elements[count] = DX_OBJ_VALUE(item);
        self->fields[DX_MENU_FIELD_COUNT] = DX_INT_VALUE(count + 1);
    }

    DX_DEBUG(TAG, "Menu.add(title) -> MenuItem");
    frame->result = DX_OBJ_VALUE(item);
    frame->has_result = true;
    return DX_OK;
}

// Menu.findItem(int id) -> MenuItem
static DxResult native_menu_find_item(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    int32_t target_id = (arg_count > 1) ? args[1].i : 0;

    if (!self || !self->fields) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    DxObject *items_arr = self->fields[DX_MENU_FIELD_ITEMS].obj;
    int32_t count = self->fields[DX_MENU_FIELD_COUNT].i;

    if (items_arr && items_arr->is_array) {
        for (int32_t i = 0; i < count; i++) {
            DxObject *item = items_arr->array_elements[i].obj;
            if (item && item->fields && item->fields[DX_MENUITEM_FIELD_ID].i == target_id) {
                frame->result = DX_OBJ_VALUE(item);
                frame->has_result = true;
                return DX_OK;
            }
        }
    }

    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Menu.size() -> int
static DxResult native_menu_size(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t count = (self && self->fields) ? self->fields[DX_MENU_FIELD_COUNT].i : 0;
    frame->result = DX_INT_VALUE(count);
    frame->has_result = true;
    return DX_OK;
}

// Menu.getItem(int index) -> MenuItem
static DxResult native_menu_get_item(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    int32_t index = (arg_count > 1) ? args[1].i : 0;

    if (!self || !self->fields) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    DxObject *items_arr = self->fields[DX_MENU_FIELD_ITEMS].obj;
    int32_t count = self->fields[DX_MENU_FIELD_COUNT].i;

    if (items_arr && items_arr->is_array && index >= 0 && index < count) {
        frame->result = items_arr->array_elements[index];
        frame->has_result = true;
        return DX_OK;
    }

    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// MenuItem.getItemId() -> int
static DxResult native_menuitem_get_item_id(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t id = (self && self->fields) ? self->fields[DX_MENUITEM_FIELD_ID].i : 0;
    frame->result = DX_INT_VALUE(id);
    frame->has_result = true;
    return DX_OK;
}

// MenuItem.getTitle() -> CharSequence
static DxResult native_menuitem_get_title(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields) {
        frame->result = self->fields[DX_MENUITEM_FIELD_TITLE];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// MenuItem.setTitle(CharSequence) -> MenuItem (return self for chaining)
static DxResult native_menuitem_set_title(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    DxObject *title = (arg_count > 1) ? args[1].obj : NULL;
    if (self && self->fields) {
        self->fields[DX_MENUITEM_FIELD_TITLE] = title ? DX_OBJ_VALUE(title) : DX_NULL_VALUE;
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

// MenuItem.setShowAsAction(int) -> void
static DxResult native_menuitem_set_show_as_action(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    int32_t flags = (arg_count > 1) ? args[1].i : 0;
    if (self && self->fields) {
        self->fields[DX_MENUITEM_FIELD_SHOWASACT] = DX_INT_VALUE(flags);
    }
    return DX_OK;
}

// MenuItem.setIcon(int) -> MenuItem (return self)
static DxResult native_menuitem_set_icon_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    int32_t icon_res = (arg_count > 1) ? args[1].i : 0;
    if (self && self->fields) {
        self->fields[DX_MENUITEM_FIELD_ICON] = DX_INT_VALUE(icon_res);
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

// Activity.onCreateOptionsMenu(Menu) -> boolean (base returns true)
static DxResult native_activity_on_create_options_menu(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(1); // true
    frame->has_result = true;
    return DX_OK;
}

// Activity.onOptionsItemSelected(MenuItem) -> boolean (base returns false)
static DxResult native_activity_on_options_item_selected(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(0); // false
    frame->has_result = true;
    return DX_OK;
}

// Activity.getMenuInflater() -> MenuInflater
static DxResult native_activity_get_menu_inflater(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *inflater_cls = dx_vm_find_class(vm, "Landroid/view/MenuInflater;");
    if (!inflater_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    DxObject *inflater = dx_vm_alloc_object(vm, inflater_cls);
    frame->result = inflater ? DX_OBJ_VALUE(inflater) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// SubMenu.addSubMenu(int groupId, int itemId, int order, CharSequence title) -> SubMenu
static DxResult native_menu_add_sub_menu(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    // First add the item to the parent menu
    native_menu_add_full(vm, frame, args, arg_count);

    // Then allocate a SubMenu and return it
    DxClass *submenu_cls = dx_vm_find_class(vm, "Landroid/view/SubMenu;");
    if (!submenu_cls) return DX_OK; // frame->result already set from add_full

    DxObject *sub = dx_vm_alloc_object(vm, submenu_cls);
    if (sub) {
        // Init sub menu's items array
        DxObject *arr = dx_vm_alloc_object(vm, vm->class_object);
        if (arr) {
            arr->is_array = true;
            arr->array_length = DX_MENU_MAX_ITEMS;
            arr->array_elements = (DxValue *)dx_malloc(DX_MENU_MAX_ITEMS * sizeof(DxValue));
            if (arr->array_elements) memset(arr->array_elements, 0, DX_MENU_MAX_ITEMS * sizeof(DxValue));
        }
        sub->fields[DX_MENU_FIELD_ITEMS] = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
        sub->fields[DX_MENU_FIELD_COUNT] = DX_INT_VALUE(0);
        frame->result = DX_OBJ_VALUE(sub);
        frame->has_result = true;
    }
    return DX_OK;
}

// SubMenu.setHeaderTitle(CharSequence) -> SubMenu (return self)
static DxResult native_submenu_set_header_title(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    frame->result = DX_OBJ_VALUE(args[0].obj);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Timber logging native methods
// ============================================================

static DxResult native_timber_log_debug(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    const char *msg = "";
    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj)
        msg = dx_vm_get_string_value(args[0].obj);
    if (!msg) msg = "(null)";
    dx_log_msg(DX_LOG_DEBUG, "Timber", msg);
    return DX_OK;
}

static DxResult native_timber_log_info(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    const char *msg = "";
    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj)
        msg = dx_vm_get_string_value(args[0].obj);
    if (!msg) msg = "(null)";
    dx_log_msg(DX_LOG_INFO, "Timber", msg);
    return DX_OK;
}

static DxResult native_timber_log_warn(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    const char *msg = "";
    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj)
        msg = dx_vm_get_string_value(args[0].obj);
    if (!msg) msg = "(null)";
    dx_log_msg(DX_LOG_WARN, "Timber", msg);
    return DX_OK;
}

static DxResult native_timber_log_error(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    const char *msg = "";
    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj)
        msg = dx_vm_get_string_value(args[0].obj);
    if (!msg) msg = "(null)";
    dx_log_msg(DX_LOG_ERROR, "Timber", msg);
    return DX_OK;
}

static DxResult native_timber_log_verbose(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    const char *msg = "";
    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj)
        msg = dx_vm_get_string_value(args[0].obj);
    if (!msg) msg = "(null)";
    dx_log_msg(DX_LOG_DEBUG, "Timber", msg);
    return DX_OK;
}

// ============================================================
// Gson native methods
// ============================================================

static DxResult native_gson_to_json(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "{}");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// JSONObject native methods
// ============================================================

static DxResult native_json_object_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) return DX_OK;
    dx_vm_set_field(self, "_json_size", DX_INT_VALUE(0));
    return DX_OK;
}

static DxResult native_json_object_put(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key && arg_count > 2) {
        dx_vm_set_field(self, key, args[2]);
        DxValue sz = {0};
        dx_vm_get_field(self, "_json_size", &sz);
        int32_t count = (sz.tag == DX_VAL_INT) ? sz.i + 1 : 1;
        dx_vm_set_field(self, "_json_size", DX_INT_VALUE(count));
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_put_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key && arg_count > 2) {
        dx_vm_set_field(self, key, args[2]);
        DxValue sz = {0};
        dx_vm_get_field(self, "_json_size", &sz);
        dx_vm_set_field(self, "_json_size", DX_INT_VALUE((sz.tag == DX_VAL_INT) ? sz.i + 1 : 1));
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        dx_vm_get_field(self, key, &val);
        frame->result = (val.tag != 0) ? val : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_get_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        dx_vm_get_field(self, key, &val);
        if (val.tag == DX_VAL_OBJ && val.obj) {
            frame->result = val;
            frame->has_result = true;
            return DX_OK;
        }
    }
    DxObject *empty = dx_vm_create_string(vm, "");
    frame->result = empty ? DX_OBJ_VALUE(empty) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_get_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        dx_vm_get_field(self, key, &val);
        if (val.tag == DX_VAL_INT) { frame->result = val; frame->has_result = true; return DX_OK; }
    }
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_get_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = ((DxValue){.tag = DX_VAL_LONG, .l = 0}); frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        dx_vm_get_field(self, key, &val);
        if (val.tag == DX_VAL_LONG) { frame->result = val; frame->has_result = true; return DX_OK; }
        if (val.tag == DX_VAL_INT) { frame->result = ((DxValue){.tag = DX_VAL_LONG, .l = (int64_t)val.i}); frame->has_result = true; return DX_OK; }
    }
    frame->result = ((DxValue){.tag = DX_VAL_LONG, .l = 0});
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_get_double(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = ((DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0}); frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        dx_vm_get_field(self, key, &val);
        if (val.tag == DX_VAL_DOUBLE) { frame->result = val; frame->has_result = true; return DX_OK; }
        if (val.tag == DX_VAL_FLOAT) { frame->result = ((DxValue){.tag = DX_VAL_DOUBLE, .d = (double)val.f}); frame->has_result = true; return DX_OK; }
    }
    frame->result = ((DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0});
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_get_boolean(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        dx_vm_get_field(self, key, &val);
        if (val.tag == DX_VAL_INT) { frame->result = val; frame->has_result = true; return DX_OK; }
    }
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_has(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        DxResult r = dx_vm_get_field(self, key, &val);
        if (r == DX_OK && val.tag != 0) {
            frame->result = DX_INT_VALUE(1);
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_opt_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        dx_vm_get_field(self, key, &val);
        if (val.tag == DX_VAL_OBJ && val.obj) {
            frame->result = val;
            frame->has_result = true;
            return DX_OK;
        }
    }
    if (arg_count > 2 && args[2].tag == DX_VAL_OBJ && args[2].obj) {
        frame->result = args[2];
    } else {
        DxObject *empty = dx_vm_create_string(vm, "");
        frame->result = empty ? DX_OBJ_VALUE(empty) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_opt_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        dx_vm_get_field(self, key, &val);
        if (val.tag == DX_VAL_INT) { frame->result = val; frame->has_result = true; return DX_OK; }
    }
    frame->result = (arg_count > 2 && args[2].tag == DX_VAL_INT) ? args[2] : DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_opt_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = ((DxValue){.tag = DX_VAL_LONG, .l = 0}); frame->has_result = true; return DX_OK; }
    const char *key = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        key = dx_vm_get_string_value(args[1].obj);
    if (key) {
        DxValue val = {0};
        dx_vm_get_field(self, key, &val);
        if (val.tag == DX_VAL_LONG) { frame->result = val; frame->has_result = true; return DX_OK; }
    }
    frame->result = (arg_count > 2 && args[2].tag == DX_VAL_LONG) ? args[2] : ((DxValue){.tag = DX_VAL_LONG, .l = 0});
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_length(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    DxValue sz = {0};
    dx_vm_get_field(self, "_json_size", &sz);
    frame->result = (sz.tag == DX_VAL_INT) ? sz : DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_object_to_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "{}");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// JSONArray native methods
// ============================================================

static DxResult native_json_array_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) return DX_OK;
    dx_vm_set_field(self, "_jarr_size", DX_INT_VALUE(0));
    return DX_OK;
}

static DxResult native_json_array_put(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxValue sz = {0};
    dx_vm_get_field(self, "_jarr_size", &sz);
    int32_t idx = (sz.tag == DX_VAL_INT) ? sz.i : 0;
    if (arg_count > 1) {
        char key[32];
        snprintf(key, sizeof(key), "_jarr_%d", idx);
        dx_vm_set_field(self, key, args[1]);
        dx_vm_set_field(self, "_jarr_size", DX_INT_VALUE(idx + 1));
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_array_put_at(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    if (arg_count > 2) {
        int32_t idx = args[1].i;
        char key[32];
        snprintf(key, sizeof(key), "_jarr_%d", idx);
        dx_vm_set_field(self, key, args[2]);
        DxValue sz = {0};
        dx_vm_get_field(self, "_jarr_size", &sz);
        int32_t cur = (sz.tag == DX_VAL_INT) ? sz.i : 0;
        if (idx >= cur) dx_vm_set_field(self, "_jarr_size", DX_INT_VALUE(idx + 1));
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_array_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self || arg_count < 2) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    int32_t idx = args[1].i;
    char key[32];
    snprintf(key, sizeof(key), "_jarr_%d", idx);
    DxValue val = {0};
    dx_vm_get_field(self, key, &val);
    frame->result = (val.tag != 0) ? val : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_array_get_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self || arg_count < 2) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    int32_t idx = args[1].i;
    char key[32];
    snprintf(key, sizeof(key), "_jarr_%d", idx);
    DxValue val = {0};
    dx_vm_get_field(self, key, &val);
    frame->result = (val.tag == DX_VAL_OBJ) ? val : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_array_get_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self || arg_count < 2) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    int32_t idx = args[1].i;
    char key[32];
    snprintf(key, sizeof(key), "_jarr_%d", idx);
    DxValue val = {0};
    dx_vm_get_field(self, key, &val);
    frame->result = (val.tag == DX_VAL_INT) ? val : DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_array_get_json_object(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = args[0].obj;
    if (!self || arg_count < 2) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    int32_t idx = args[1].i;
    char key[32];
    snprintf(key, sizeof(key), "_jarr_%d", idx);
    DxValue val = {0};
    dx_vm_get_field(self, key, &val);
    frame->result = (val.tag == DX_VAL_OBJ) ? val : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_array_length(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    DxValue sz = {0};
    dx_vm_get_field(self, "_jarr_size", &sz);
    frame->result = (sz.tag == DX_VAL_INT) ? sz : DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_json_array_to_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "[]");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Register all Android framework classes
// ============================================================

static void add_method(DxClass *cls, const char *name, const char *shorty,
                        uint32_t flags, DxNativeMethodFn fn, bool is_direct) {
    DxMethod **methods_ptr;
    uint32_t *count;

    if (is_direct) {
        methods_ptr = &cls->direct_methods;
        count = &cls->direct_method_count;
    } else {
        methods_ptr = &cls->virtual_methods;
        count = &cls->virtual_method_count;
    }

    uint32_t idx = *count;
    uint32_t new_count = idx + 1;
    DxMethod *new_methods = (DxMethod *)dx_realloc(*methods_ptr, sizeof(DxMethod) * new_count);
    if (!new_methods) return;

    memset(&new_methods[idx], 0, sizeof(DxMethod));
    new_methods[idx].name = name;
    new_methods[idx].shorty = shorty;
    new_methods[idx].declaring_class = cls;
    new_methods[idx].access_flags = flags;
    new_methods[idx].native_fn = fn;
    new_methods[idx].is_native = true;
    new_methods[idx].vtable_idx = is_direct ? -1 : (int32_t)idx;

    *methods_ptr = new_methods;
    *count = new_count;
}

static DxClass *reg_class(DxVM *vm, const char *desc, DxClass *super) {
    if (vm->class_count >= DX_MAX_CLASSES) return NULL;
    DxClass *cls = (DxClass *)dx_malloc(sizeof(DxClass));
    if (!cls) return NULL;
    cls->descriptor = desc;
    cls->super_class = super ? super : vm->class_object;
    cls->status = DX_CLASS_INITIALIZED;
    cls->is_framework = true;
    vm->classes[vm->class_count++] = cls;
    dx_vm_class_hash_insert(vm, cls);
    return cls;
}

static void add_static_fields(DxClass *cls, const char **field_names, DxValue *values, uint32_t count) {
    if (!cls || count == 0) return;
    cls->static_field_count = count;
    cls->static_fields = (DxValue *)dx_malloc(sizeof(DxValue) * count);
    cls->field_defs = dx_malloc(sizeof(*cls->field_defs) * count);
    if (!cls->static_fields || !cls->field_defs) return;
    for (uint32_t i = 0; i < count; i++) {
        cls->field_defs[i].name = field_names[i];
        cls->field_defs[i].type = "I";
        cls->field_defs[i].flags = DX_ACC_PUBLIC | DX_ACC_STATIC;
        cls->static_fields[i] = values[i];
    }
}

// ============================================================
// TypedValue.applyDimension — return value as-is (1:1 approx)
// ============================================================
static DxResult native_typed_value_apply_dimension(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    // static applyDimension(int unit, float value, DisplayMetrics dm) -> float
    float val = (arg_count > 1) ? args[1].f : 0.0f;
    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = val};
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_typed_value_complex_to_dimension(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    // static complexToDimensionPixelSize(int data, DisplayMetrics dm) -> int
    int32_t val = (arg_count > 0) ? args[0].i : 0;
    frame->result = DX_INT_VALUE(val);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Bitmap.createBitmap — alloc Bitmap with w/h in fields
// ============================================================
static DxResult native_bitmap_create(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    int32_t w = (arg_count > 0) ? args[0].i : 100;
    int32_t h = (arg_count > 1) ? args[1].i : 100;
    DxClass *bitmap_cls = dx_vm_find_class(vm, "Landroid/graphics/Bitmap;");
    DxObject *bmp = bitmap_cls ? dx_vm_alloc_object(vm, bitmap_cls) : NULL;
    if (bmp && bmp->fields && bitmap_cls->instance_field_count >= 2) {
        bmp->fields[0] = DX_INT_VALUE(w);
        bmp->fields[1] = DX_INT_VALUE(h);
    }
    frame->result = bmp ? DX_OBJ_VALUE(bmp) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_bitmap_get_width(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t w = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2) {
        w = self->fields[0].i;
    }
    frame->result = DX_INT_VALUE(w);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_bitmap_get_height(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t h = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2) {
        h = self->fields[1].i;
    }
    frame->result = DX_INT_VALUE(h);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_bitmap_copy(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    // copy(Config, boolean) -> Bitmap — return self
    frame->result = DX_OBJ_VALUE(args[0].obj);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// BitmapFactory.decode* — return a stub 100x100 Bitmap
// ============================================================
static DxResult native_bitmap_factory_decode(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *bitmap_cls = dx_vm_find_class(vm, "Landroid/graphics/Bitmap;");
    DxObject *bmp = bitmap_cls ? dx_vm_alloc_object(vm, bitmap_cls) : NULL;
    if (bmp && bmp->fields && bitmap_cls->instance_field_count >= 2) {
        bmp->fields[0] = DX_INT_VALUE(100);
        bmp->fields[1] = DX_INT_VALUE(100);
    }
    frame->result = bmp ? DX_OBJ_VALUE(bmp) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Drawable — getIntrinsicWidth/Height returning 48
// ============================================================
static DxResult native_drawable_get_intrinsic_size(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(48);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// java.net.URL — init stores URL string, toString returns it
// ============================================================
static DxResult native_url_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    // <init>(String) — args[0]=this, args[1]=url string
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && arg_count > 1) {
        self->fields[0] = args[1];
    }
    return DX_OK;
}

static DxResult native_url_to_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && self->fields[0].tag == DX_VAL_OBJ && self->fields[0].obj) {
        frame->result = self->fields[0];
    } else {
        DxObject *str_obj = dx_vm_create_string(vm, "");
        frame->result = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_url_open_connection(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = URL object (this)
    DxObject *url_obj = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;

    // Determine if HTTPS — check URL string for "https://"
    const char *url_str = NULL;
    if (url_obj && url_obj->fields && url_obj->klass && url_obj->klass->instance_field_count > 0
        && url_obj->fields[0].tag == DX_VAL_OBJ) {
        url_str = dx_vm_get_string_value(url_obj->fields[0].obj);
    }

    bool is_https = url_str && (strncmp(url_str, "https://", 8) == 0 ||
                                strncmp(url_str, "HTTPS://", 8) == 0);
    const char *cls_name = is_https ? "Ljavax/net/ssl/HttpsURLConnection;"
                                    : "Ljava/net/HttpURLConnection;";
    DxClass *conn_cls = dx_vm_find_class(vm, cls_name);
    if (!conn_cls) conn_cls = dx_vm_find_class(vm, "Ljava/net/HttpURLConnection;");
    DxObject *conn = conn_cls ? dx_vm_alloc_object(vm, conn_cls) : NULL;

    // Copy URL string into connection field[0]
    if (conn && conn->fields && conn_cls->instance_field_count >= 1 && url_obj
        && url_obj->fields && url_obj->klass && url_obj->klass->instance_field_count > 0) {
        conn->fields[0] = url_obj->fields[0]; // URL string
    }
    // Set default method to "GET" in field[1]
    if (conn && conn->fields && conn_cls->instance_field_count >= 2) {
        DxObject *get_str = dx_vm_create_string(vm, "GET");
        conn->fields[1] = get_str ? DX_OBJ_VALUE(get_str) : DX_NULL_VALUE;
    }
    // Initialize remaining fields (response code=0, connected=0, others=NULL/0)
    if (conn && conn->fields && conn_cls->instance_field_count >= 4) {
        conn->fields[2] = DX_INT_VALUE(0);  // response code (set after connect)
        conn->fields[3] = DX_INT_VALUE(0);  // not connected
    }

    frame->result = conn ? DX_OBJ_VALUE(conn) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// HttpURLConnection — real networking via C-to-Swift callback
// ============================================================
// Field layout (instance_field_count = 10):
//   field[0] = URL string, field[1] = method string, field[2] = response code (int),
//   field[3] = connected flag (int), field[4] = request headers (flat array),
//   field[5] = response body ptr (long), field[6] = response body size (int),
//   field[7] = response header names (array), field[8] = response header values (array),
//   field[9] = output stream (ByteArrayOutputStream)

#include "../Include/dx_runtime.h"

static void http_conn_do_request(DxVM *vm, DxObject *self) {
    if (!self || !self->fields || !self->klass) return;
    if (self->klass->instance_field_count >= 4 &&
        self->fields[3].tag == DX_VAL_INT && self->fields[3].i != 0) return;

    const char *url = NULL;
    if (self->fields[0].tag == DX_VAL_OBJ && self->fields[0].obj)
        url = dx_vm_get_string_value(self->fields[0].obj);
    if (!url) {
        dx_log(DX_LOG_ERROR, "HTTP", "connect: no URL set");
        self->fields[2] = DX_INT_VALUE(-1);
        self->fields[3] = DX_INT_VALUE(1);
        return;
    }

    const char *method = "GET";
    if (self->fields[1].tag == DX_VAL_OBJ && self->fields[1].obj) {
        const char *m = dx_vm_get_string_value(self->fields[1].obj);
        if (m) method = m;
    }

    const char *h_names[DX_NET_MAX_HEADERS];
    const char *h_values[DX_NET_MAX_HEADERS];
    int h_count = 0;
    if (self->klass->instance_field_count > 4 &&
        self->fields[4].tag == DX_VAL_OBJ && self->fields[4].obj) {
        DxObject *hdr_arr = self->fields[4].obj;
        if (hdr_arr->is_array && hdr_arr->array_length > 0 && hdr_arr->array_elements) {
            int n = (int)hdr_arr->array_length;
            for (int i = 0; i + 1 < n && h_count < DX_NET_MAX_HEADERS; i += 2) {
                DxValue kv = hdr_arr->array_elements[i];
                DxValue vv = hdr_arr->array_elements[i + 1];
                if (kv.tag == DX_VAL_OBJ && kv.obj && vv.tag == DX_VAL_OBJ && vv.obj) {
                    const char *k = dx_vm_get_string_value(kv.obj);
                    const char *v = dx_vm_get_string_value(vv.obj);
                    if (k && v) { h_names[h_count] = k; h_values[h_count] = v; h_count++; }
                }
            }
        }
    }

    const uint8_t *req_body = NULL;
    size_t req_body_size = 0;
    if (self->klass->instance_field_count > 9 &&
        self->fields[9].tag == DX_VAL_OBJ && self->fields[9].obj) {
        DxObject *os_obj = self->fields[9].obj;
        DxValue data_val, size_val;
        if (dx_vm_get_field(os_obj, "_data", &data_val) == DX_OK &&
            data_val.tag == DX_VAL_LONG && data_val.l != 0) {
            dx_vm_get_field(os_obj, "_size", &size_val);
            req_body = (const uint8_t *)(uintptr_t)data_val.l;
            req_body_size = (size_t)(size_val.tag == DX_VAL_INT ? size_val.i : 0);
        }
    }

    DxNetworkRequest req = {
        .url = url, .method = method,
        .header_names = h_names, .header_values = h_values, .header_count = h_count,
        .body = req_body, .body_size = req_body_size,
    };
    DxNetworkResponse resp;
    dx_log(DX_LOG_INFO, "HTTP", "%s %s (headers=%d, body=%zu bytes)", method, url, h_count, req_body_size);

    if (!dx_runtime_perform_network_request(&req, &resp)) {
        dx_log(DX_LOG_WARN, "HTTP", "No network callback — returning simulated 200");
        self->fields[2] = DX_INT_VALUE(200);
        self->fields[3] = DX_INT_VALUE(1);
        return;
    }

    dx_log(DX_LOG_INFO, "HTTP", "Response: %d (%zu bytes)", resp.status_code, resp.body_size);
    self->fields[2] = DX_INT_VALUE(resp.status_code);
    self->fields[3] = DX_INT_VALUE(1);

    if (resp.body && resp.body_size > 0) {
        uint8_t *body_copy = (uint8_t *)dx_malloc(resp.body_size);
        if (body_copy) {
            memcpy(body_copy, resp.body, resp.body_size);
            self->fields[5] = (DxValue){.tag = DX_VAL_LONG, .l = (int64_t)(uintptr_t)body_copy};
            self->fields[6] = DX_INT_VALUE((int32_t)resp.body_size);
        }
    }

    if (resp.header_count > 0 && resp.header_names && resp.header_values) {
        DxObject *names_arr = dx_vm_alloc_array(vm, (uint32_t)resp.header_count);
        DxObject *values_arr = dx_vm_alloc_array(vm, (uint32_t)resp.header_count);
        if (names_arr && values_arr) {
            for (int i = 0; i < resp.header_count; i++) {
                DxObject *nstr = dx_vm_create_string(vm, resp.header_names[i] ? resp.header_names[i] : "");
                DxObject *vstr = dx_vm_create_string(vm, resp.header_values[i] ? resp.header_values[i] : "");
                names_arr->array_elements[i] = nstr ? DX_OBJ_VALUE(nstr) : DX_NULL_VALUE;
                values_arr->array_elements[i] = vstr ? DX_OBJ_VALUE(vstr) : DX_NULL_VALUE;
            }
            self->fields[7] = DX_OBJ_VALUE(names_arr);
            self->fields[8] = DX_OBJ_VALUE(values_arr);
        }
    }
    dx_network_response_free(&resp);
}

static DxResult native_http_set_request_method(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    // args[0]=this, args[1]=method string
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2
        && arg_count > 1) {
        self->fields[1] = args[1]; // store method string
    }
    return DX_OK;
}

static DxResult native_http_connect(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self) http_conn_do_request(vm, self);
    return DX_OK;
}

static DxResult native_http_get_response_code(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass) {
        if (self->klass->instance_field_count >= 4 &&
            (self->fields[3].tag != DX_VAL_INT || self->fields[3].i == 0))
            http_conn_do_request(vm, self);
        if (self->klass->instance_field_count >= 3 && self->fields[2].tag == DX_VAL_INT)
            frame->result = self->fields[2];
        else
            frame->result = DX_INT_VALUE(-1);
    } else {
        frame->result = DX_INT_VALUE(-1);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_http_get_response_message(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 4 &&
        (self->fields[3].tag != DX_VAL_INT || self->fields[3].i == 0))
        http_conn_do_request(vm, self);
    int code = 200;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 3
        && self->fields[2].tag == DX_VAL_INT)
        code = self->fields[2].i;
    const char *msg = "OK";
    if (code == 201) msg = "Created";
    else if (code == 204) msg = "No Content";
    else if (code == 400) msg = "Bad Request";
    else if (code == 401) msg = "Unauthorized";
    else if (code == 403) msg = "Forbidden";
    else if (code == 404) msg = "Not Found";
    else if (code == 500) msg = "Internal Server Error";
    else if (code == 503) msg = "Service Unavailable";
    DxObject *str = dx_vm_create_string(vm, msg);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_http_get_input_stream(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 4 &&
        (self->fields[3].tag != DX_VAL_INT || self->fields[3].i == 0))
        http_conn_do_request(vm, self);

    DxClass *is_cls = dx_vm_find_class(vm, "Ljava/io/InputStream;");
    DxObject *is_obj = is_cls ? dx_vm_alloc_object(vm, is_cls) : NULL;
    if (is_obj && self && self->fields && self->klass &&
        self->klass->instance_field_count > 6) {
        dx_vm_set_field(is_obj, "_data", self->fields[5]);
        dx_vm_set_field(is_obj, "_size", self->fields[6]);
        dx_vm_set_field(is_obj, "_position", DX_INT_VALUE(0));
    }
    frame->result = is_obj ? DX_OBJ_VALUE(is_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_http_get_output_stream(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 9 &&
        self->fields[9].tag == DX_VAL_OBJ && self->fields[9].obj) {
        frame->result = self->fields[9];
        frame->has_result = true;
        return DX_OK;
    }
    DxClass *baos_cls = dx_vm_find_class(vm, "Ljava/io/ByteArrayOutputStream;");
    if (!baos_cls) baos_cls = dx_vm_find_class(vm, "Ljava/io/OutputStream;");
    DxObject *os_obj = baos_cls ? dx_vm_alloc_object(vm, baos_cls) : NULL;
    if (os_obj && self && self->fields && self->klass && self->klass->instance_field_count > 9)
        self->fields[9] = DX_OBJ_VALUE(os_obj);
    frame->result = os_obj ? DX_OBJ_VALUE(os_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_http_get_url(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *url_cls = dx_vm_find_class(vm, "Ljava/net/URL;");
    DxObject *url_obj = url_cls ? dx_vm_alloc_object(vm, url_cls) : NULL;
    if (url_obj && url_obj->fields && url_cls->instance_field_count > 0
        && self && self->fields && self->klass && self->klass->instance_field_count >= 1)
        url_obj->fields[0] = self->fields[0];
    frame->result = url_obj ? DX_OBJ_VALUE(url_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_http_set_request_property(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 5)
        return DX_OK;
    if (arg_count < 3 || args[1].tag != DX_VAL_OBJ || args[2].tag != DX_VAL_OBJ)
        return DX_OK;
    const char *key = dx_vm_get_string_value(args[1].obj);
    const char *val = dx_vm_get_string_value(args[2].obj);
    if (key && val)
        dx_log(DX_LOG_DEBUG, "HTTP", "setRequestProperty: %s = %s", key, val);

    DxObject *hdr_arr = NULL;
    if (self->fields[4].tag == DX_VAL_OBJ && self->fields[4].obj &&
        self->fields[4].obj->is_array)
        hdr_arr = self->fields[4].obj;
    if (!hdr_arr) {
        hdr_arr = dx_vm_alloc_array(vm, 0);
        if (!hdr_arr) return DX_OK;
        self->fields[4] = DX_OBJ_VALUE(hdr_arr);
    }
    uint32_t old_len = hdr_arr->array_length;
    uint32_t new_len = old_len + 2;
    DxValue *new_data = (DxValue *)dx_realloc(hdr_arr->array_elements, sizeof(DxValue) * new_len);
    if (!new_data) return DX_OK;
    hdr_arr->array_elements = new_data;
    hdr_arr->array_length = new_len;
    hdr_arr->array_elements[old_len] = args[1];
    hdr_arr->array_elements[old_len + 1] = args[2];
    return DX_OK;
}

static DxResult native_http_get_header_field(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 4 &&
        (self->fields[3].tag != DX_VAL_INT || self->fields[3].i == 0))
        http_conn_do_request(vm, self);
    const char *name = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        name = dx_vm_get_string_value(args[1].obj);
    if (!name || !self || !self->fields || !self->klass ||
        self->klass->instance_field_count < 9) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    if (self->fields[7].tag == DX_VAL_OBJ && self->fields[7].obj &&
        self->fields[8].tag == DX_VAL_OBJ && self->fields[8].obj) {
        DxObject *names_arr = self->fields[7].obj;
        DxObject *values_arr = self->fields[8].obj;
        if (names_arr->is_array && values_arr->is_array) {
            for (uint32_t i = 0; i < names_arr->array_length && i < values_arr->array_length; i++) {
                if (names_arr->array_elements[i].tag == DX_VAL_OBJ && names_arr->array_elements[i].obj) {
                    const char *hname = dx_vm_get_string_value(names_arr->array_elements[i].obj);
                    if (hname && strcasecmp(hname, name) == 0) {
                        frame->result = values_arr->array_elements[i];
                        frame->has_result = true;
                        return DX_OK;
                    }
                }
            }
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_http_disconnect(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 4) {
        self->fields[3] = DX_INT_VALUE(0);
        dx_log(DX_LOG_DEBUG, "HTTP", "disconnect");
    }
    return DX_OK;
}

// ============================================================
// OkHttp3 — real networking native methods
// ============================================================
// Request$Builder fields (instance_field_count=5):
//   [0]=URL string, [1]=method string, [2]=headers (flat array), [3]=body data ptr(long), [4]=body size(int)
// Request fields (instance_field_count=5): same layout copied from builder
// Call fields: [0]=Request object
// Response fields (instance_field_count=4): [0]=status code(int), [1]=body obj, [2]=request obj, [3]=resp headers array
// ResponseBody fields (instance_field_count=2): [0]=body string, [1]=body bytes (raw ptr)

static DxResult native_okhttp_req_builder_url(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0]=this (Builder), args[1]=URL string or HttpUrl
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 && arg_count > 1) {
        // If arg is a String, store directly; if HttpUrl, try toString
        if (args[1].tag == DX_VAL_OBJ && args[1].obj) {
            const char *s = dx_vm_get_string_value(args[1].obj);
            if (s) {
                self->fields[0] = args[1]; // store URL string object
            } else {
                self->fields[0] = args[1]; // store whatever object (HttpUrl)
            }
        }
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_req_builder_method(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0]=this, args[1]=method string, args[2]=RequestBody (nullable)
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2 && arg_count > 1) {
        self->fields[1] = args[1]; // method string
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_req_builder_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2) {
        DxObject *get_str = dx_vm_create_string(vm, "GET");
        self->fields[1] = get_str ? DX_OBJ_VALUE(get_str) : DX_NULL_VALUE;
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_req_builder_post(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2) {
        DxObject *str = dx_vm_create_string(vm, "POST");
        self->fields[1] = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
        // TODO: store RequestBody from args[1] for body extraction
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_req_builder_put(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2) {
        DxObject *str = dx_vm_create_string(vm, "PUT");
        self->fields[1] = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_req_builder_delete(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2) {
        DxObject *str = dx_vm_create_string(vm, "DELETE");
        self->fields[1] = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_req_builder_patch(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2) {
        DxObject *str = dx_vm_create_string(vm, "PATCH");
        self->fields[1] = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_req_builder_add_header(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0]=this, args[1]=name, args[2]=value
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 3 &&
        arg_count > 2) {
        DxObject *hdr_arr = NULL;
        if (self->fields[2].tag == DX_VAL_OBJ && self->fields[2].obj &&
            self->fields[2].obj->is_array)
            hdr_arr = self->fields[2].obj;
        if (!hdr_arr) {
            hdr_arr = dx_vm_alloc_array(vm, 0);
            if (!hdr_arr) goto done;
            self->fields[2] = DX_OBJ_VALUE(hdr_arr);
        }
        uint32_t old_len = hdr_arr->array_length;
        uint32_t new_len = old_len + 2;
        DxValue *new_d = (DxValue *)dx_realloc(hdr_arr->array_elements, sizeof(DxValue) * new_len);
        if (!new_d) goto done;
        hdr_arr->array_elements = new_d;
        hdr_arr->array_length = new_len;
        hdr_arr->array_elements[old_len] = args[1];
        hdr_arr->array_elements[old_len + 1] = args[2];
    }
done:
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_req_builder_build(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Build a Request object from builder state
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *req_cls = dx_vm_find_class(vm, "Lokhttp3/Request;");
    DxObject *req = req_cls ? dx_vm_alloc_object(vm, req_cls) : NULL;
    if (req && self && self->fields && self->klass && req->fields && req->klass) {
        int n = self->klass->instance_field_count;
        if (n > (int)req->klass->instance_field_count) n = req->klass->instance_field_count;
        for (int i = 0; i < n; i++)
            req->fields[i] = self->fields[i];
    }
    frame->result = req ? DX_OBJ_VALUE(req) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_request_url(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1) {
        // Return HttpUrl wrapping the URL string
        DxClass *hurl_cls = dx_vm_find_class(vm, "Lokhttp3/HttpUrl;");
        DxObject *hurl = hurl_cls ? dx_vm_alloc_object(vm, hurl_cls) : NULL;
        if (hurl && hurl->fields && hurl->klass && hurl->klass->instance_field_count >= 1)
            hurl->fields[0] = self->fields[0];
        frame->result = hurl ? DX_OBJ_VALUE(hurl) : self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_request_method(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2 &&
        self->fields[1].tag == DX_VAL_OBJ)
        frame->result = self->fields[1];
    else {
        DxObject *s = dx_vm_create_string(vm, "GET");
        frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_client_new_call(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0]=OkHttpClient (this), args[1]=Request
    DxClass *call_cls = dx_vm_find_class(vm, "Lokhttp3/Call;");
    DxObject *call = call_cls ? dx_vm_alloc_object(vm, call_cls) : NULL;
    if (call && call->fields && call->klass && call->klass->instance_field_count >= 1 && arg_count > 1)
        call->fields[0] = args[1]; // store Request in field[0]
    frame->result = call ? DX_OBJ_VALUE(call) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_call_execute(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0]=Call (this), field[0]=Request
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *request = NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 &&
        self->fields[0].tag == DX_VAL_OBJ)
        request = self->fields[0].obj;

    // Extract URL and method from Request
    const char *url = NULL;
    const char *method = "GET";
    if (request && request->fields && request->klass) {
        if (request->klass->instance_field_count >= 1 &&
            request->fields[0].tag == DX_VAL_OBJ && request->fields[0].obj)
            url = dx_vm_get_string_value(request->fields[0].obj);
        if (request->klass->instance_field_count >= 2 &&
            request->fields[1].tag == DX_VAL_OBJ && request->fields[1].obj) {
            const char *m = dx_vm_get_string_value(request->fields[1].obj);
            if (m) method = m;
        }
    }

    // Collect headers from Request field[2]
    const char *h_names[DX_NET_MAX_HEADERS];
    const char *h_values[DX_NET_MAX_HEADERS];
    int h_count = 0;
    if (request && request->fields && request->klass &&
        request->klass->instance_field_count > 2 &&
        request->fields[2].tag == DX_VAL_OBJ && request->fields[2].obj) {
        DxObject *hdr_arr = request->fields[2].obj;
        if (hdr_arr->is_array && hdr_arr->array_length > 0 && hdr_arr->array_elements) {
            int n = (int)hdr_arr->array_length;
            for (int i = 0; i + 1 < n && h_count < DX_NET_MAX_HEADERS; i += 2) {
                DxValue kv = hdr_arr->array_elements[i];
                DxValue vv = hdr_arr->array_elements[i + 1];
                if (kv.tag == DX_VAL_OBJ && kv.obj && vv.tag == DX_VAL_OBJ && vv.obj) {
                    const char *k = dx_vm_get_string_value(kv.obj);
                    const char *v = dx_vm_get_string_value(vv.obj);
                    if (k && v) { h_names[h_count] = k; h_values[h_count] = v; h_count++; }
                }
            }
        }
    }

    // Build response
    DxClass *resp_cls = dx_vm_find_class(vm, "Lokhttp3/Response;");
    DxObject *resp = resp_cls ? dx_vm_alloc_object(vm, resp_cls) : NULL;
    if (!resp) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    if (!url) {
        dx_log(DX_LOG_WARN, "OkHttp", "Call.execute: no URL in request");
        if (resp->fields && resp->klass && resp->klass->instance_field_count >= 1)
            resp->fields[0] = DX_INT_VALUE(-1);
        frame->result = DX_OBJ_VALUE(resp);
        frame->has_result = true;
        return DX_OK;
    }

    DxNetworkRequest req = {
        .url = url, .method = method,
        .header_names = h_names, .header_values = h_values, .header_count = h_count,
        .body = NULL, .body_size = 0,
    };
    DxNetworkResponse net_resp;
    dx_log(DX_LOG_INFO, "OkHttp", "execute: %s %s (headers=%d)", method, url, h_count);

    bool ok = dx_runtime_perform_network_request(&req, &net_resp);
    int status = ok ? net_resp.status_code : 200;

    // Fill Response object
    if (resp->fields && resp->klass && resp->klass->instance_field_count >= 3) {
        resp->fields[0] = DX_INT_VALUE(status);
        resp->fields[2] = request ? DX_OBJ_VALUE(request) : DX_NULL_VALUE;

        // Create ResponseBody
        DxClass *body_cls = dx_vm_find_class(vm, "Lokhttp3/ResponseBody;");
        DxObject *body_obj = body_cls ? dx_vm_alloc_object(vm, body_cls) : NULL;
        if (body_obj && body_obj->fields && body_obj->klass) {
            if (ok && net_resp.body && net_resp.body_size > 0) {
                // Store as string in field[0]
                char *body_str = (char *)dx_malloc(net_resp.body_size + 1);
                if (body_str) {
                    memcpy(body_str, net_resp.body, net_resp.body_size);
                    body_str[net_resp.body_size] = '\0';
                    DxObject *s = dx_vm_create_string(vm, body_str);
                    if (body_obj->klass->instance_field_count >= 1)
                        body_obj->fields[0] = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
                    dx_free(body_str);
                }
            } else {
                if (body_obj->klass->instance_field_count >= 1) {
                    DxObject *s = dx_vm_create_string(vm, "{}");
                    body_obj->fields[0] = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
                }
            }
            resp->fields[1] = DX_OBJ_VALUE(body_obj);
        }
    }

    if (ok) {
        dx_log(DX_LOG_INFO, "OkHttp", "Response: %d (%zu bytes)", net_resp.status_code, net_resp.body_size);
        dx_network_response_free(&net_resp);
    }

    frame->result = DX_OBJ_VALUE(resp);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_call_enqueue(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // Synchronous execution for enqueue too (cooperative threading)
    // args[0]=Call, args[1]=Callback
    // Execute the request, then call onResponse(call, response)
    DxObject *call_self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *callback = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    // Temporarily create a frame to get the response
    DxValue exec_args[1] = { args[0] };
    DxFrame temp_frame;
    memset(&temp_frame, 0, sizeof(temp_frame));
    native_okhttp_call_execute(vm, &temp_frame, exec_args, 1);

    if (callback && callback->klass && temp_frame.has_result) {
        // Call callback.onResponse(call, response)
        DxMethod *on_resp = dx_vm_find_method(callback->klass, "onResponse", "VLL");
        if (on_resp) {
            DxValue cb_args[3] = { DX_OBJ_VALUE(callback), DX_OBJ_VALUE(call_self), temp_frame.result };
            DxValue cb_result; dx_vm_execute_method(vm, on_resp, cb_args, 3, &cb_result);
        }
    }
    return DX_OK;
}

static DxResult native_okhttp_response_code(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 &&
        self->fields[0].tag == DX_VAL_INT)
        frame->result = self->fields[0];
    else
        frame->result = DX_INT_VALUE(200);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_response_is_successful(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int code = 200;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 &&
        self->fields[0].tag == DX_VAL_INT)
        code = self->fields[0].i;
    frame->result = DX_INT_VALUE(code >= 200 && code < 300 ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_response_body(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2 &&
        self->fields[1].tag == DX_VAL_OBJ)
        frame->result = self->fields[1];
    else
        frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_response_request(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 3 &&
        self->fields[2].tag == DX_VAL_OBJ)
        frame->result = self->fields[2];
    else
        frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_resp_body_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 &&
        self->fields[0].tag == DX_VAL_OBJ && self->fields[0].obj)
        frame->result = self->fields[0];
    else {
        DxObject *s = dx_vm_create_string(vm, "{}");
        frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_client_builder_build(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxClass *cls = dx_vm_find_class(vm, "Lokhttp3/OkHttpClient;");
    DxObject *obj = cls ? dx_vm_alloc_object(vm, cls) : NULL;
    frame->result = obj ? DX_OBJ_VALUE(obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_okhttp_httpurl_tostring(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 &&
        self->fields[0].tag == DX_VAL_OBJ)
        frame->result = self->fields[0];
    else {
        DxObject *s = dx_vm_create_string(vm, "");
        frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// java.net.URI — create stores string, toString returns it
// ============================================================
static DxResult native_juri_create(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // static create(String) -> URI
    DxClass *uri_cls = dx_vm_find_class(vm, "Ljava/net/URI;");
    DxObject *uri_obj = uri_cls ? dx_vm_alloc_object(vm, uri_cls) : NULL;
    if (uri_obj && uri_obj->fields && uri_cls->instance_field_count > 0
        && arg_count > 0) {
        uri_obj->fields[0] = args[0];
    }
    frame->result = uri_obj ? DX_OBJ_VALUE(uri_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_juri_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    // <init>(String) — args[0]=this, args[1]=string
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && arg_count > 1) {
        self->fields[0] = args[1];
    }
    return DX_OK;
}

static DxResult native_juri_to_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && self->fields[0].tag == DX_VAL_OBJ && self->fields[0].obj) {
        frame->result = self->fields[0];
    } else {
        DxObject *str_obj = dx_vm_create_string(vm, "");
        frame->result = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context.startService(Intent) — find Service class, instantiate, call lifecycle
// ============================================================
static DxResult native_context_start_service(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = this (Context), args[1] = Intent
    if (arg_count < 2 || args[1].tag != DX_VAL_OBJ || !args[1].obj) {
        DX_INFO(TAG, "startService: null Intent, ignoring");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *intent = args[1].obj;

    // Extract target class descriptor from intent field[1] (DX_INTENT_FIELD_TARGET_CLASS)
    const char *target_desc = NULL;
    if (intent->fields && intent->klass &&
        intent->klass->instance_field_count > DX_INTENT_FIELD_TARGET_CLASS &&
        intent->fields[DX_INTENT_FIELD_TARGET_CLASS].tag == DX_VAL_OBJ &&
        intent->fields[DX_INTENT_FIELD_TARGET_CLASS].obj) {
        target_desc = dx_vm_get_string_value(intent->fields[DX_INTENT_FIELD_TARGET_CLASS].obj);
    }

    if (!target_desc || strlen(target_desc) == 0) {
        DX_INFO(TAG, "startService: Intent has no target class");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DX_INFO(TAG, "startService: starting %s", target_desc);

    // Find or load the target Service class
    DxClass *target_cls = dx_vm_find_class(vm, target_desc);
    if (!target_cls) {
        DxResult res = dx_vm_load_class(vm, target_desc, &target_cls);
        if (res != DX_OK || !target_cls) {
            DX_INFO(TAG, "startService: cannot find/load class %s", target_desc);
            frame->result = DX_NULL_VALUE;
            frame->has_result = true;
            return DX_OK;
        }
    }

    // Initialize the class if needed
    DxResult res = dx_vm_init_class(vm, target_cls);
    if (res != DX_OK) {
        DX_INFO(TAG, "startService: class init failed for %s", target_desc);
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Allocate Service instance
    DxObject *service = dx_vm_alloc_object(vm, target_cls);
    if (!service) {
        DX_INFO(TAG, "startService: alloc failed for %s", target_desc);
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Call <init>
    DxMethod *init_m = dx_vm_find_method(target_cls, "<init>", "V");
    if (init_m) {
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue init_args[1] = { DX_OBJ_VALUE(service) };
        dx_vm_execute_method(vm, init_m, init_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    // Call onCreate()
    DxMethod *on_create = dx_vm_find_method(target_cls, "onCreate", "V");
    if (on_create) {
        DX_INFO(TAG, "startService: calling onCreate() on %s", target_desc);
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue create_args[1] = { DX_OBJ_VALUE(service) };
        dx_vm_execute_method(vm, on_create, create_args, 1, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    // Call onStartCommand(Intent, flags=0, startId=1)
    DxMethod *on_start_cmd = dx_vm_find_method(target_cls, "onStartCommand", "ILII");
    if (on_start_cmd) {
        DX_INFO(TAG, "startService: calling onStartCommand() on %s", target_desc);
        vm->insn_count = 0;
        vm->pending_exception = NULL;
        DxValue cmd_args[4] = {
            DX_OBJ_VALUE(service),
            args[1],           // the Intent
            DX_INT_VALUE(0),   // flags
            DX_INT_VALUE(1)    // startId
        };
        dx_vm_execute_method(vm, on_start_cmd, cmd_args, 4, NULL);
        if (vm->pending_exception) vm->pending_exception = NULL;
    }

    // Return a ComponentName (null is acceptable for stubs)
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context.stopService(Intent) — log the stop, return true
// ============================================================
static DxResult native_context_stop_service(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *target_desc = NULL;
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxObject *intent = args[1].obj;
        if (intent->fields && intent->klass &&
            intent->klass->instance_field_count > DX_INTENT_FIELD_TARGET_CLASS &&
            intent->fields[DX_INTENT_FIELD_TARGET_CLASS].tag == DX_VAL_OBJ &&
            intent->fields[DX_INTENT_FIELD_TARGET_CLASS].obj) {
            target_desc = dx_vm_get_string_value(intent->fields[DX_INTENT_FIELD_TARGET_CLASS].obj);
        }
    }
    if (target_desc) {
        DX_INFO(TAG, "stopService: stopping %s", target_desc);
    } else {
        DX_INFO(TAG, "stopService: called (no target class)");
    }
    frame->result = DX_INT_VALUE(1); // true
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context.bindService(Intent, ServiceConnection, int) — stub returning true
// ============================================================
static DxResult native_context_bind_service(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    DX_INFO(TAG, "bindService: stub (returning true)");
    frame->result = DX_INT_VALUE(1); // true
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context.sendBroadcast(Intent) — log the broadcast action
// ============================================================
static DxResult native_context_send_broadcast(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    const char *action = NULL;
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxObject *intent = args[1].obj;
        if (intent->fields && intent->klass &&
            intent->klass->instance_field_count > DX_INTENT_FIELD_ACTION &&
            intent->fields[DX_INTENT_FIELD_ACTION].tag == DX_VAL_OBJ &&
            intent->fields[DX_INTENT_FIELD_ACTION].obj) {
            action = dx_vm_get_string_value(intent->fields[DX_INTENT_FIELD_ACTION].obj);
        }
    }
    if (action) {
        DX_INFO(TAG, "sendBroadcast: action=%s", action);
    } else {
        DX_INFO(TAG, "sendBroadcast: called (no action)");
    }
    return DX_OK;
}

// ============================================================
// Context.registerReceiver(BroadcastReceiver, IntentFilter) — store and log
// ============================================================
static DxResult native_context_register_receiver(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0]=this, args[1]=receiver, args[2]=filter
    const char *receiver_class = NULL;
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj && args[1].obj->klass) {
        receiver_class = args[1].obj->klass->descriptor;
    }
    if (receiver_class) {
        DX_INFO(TAG, "registerReceiver: registered %s", receiver_class);
    } else {
        DX_INFO(TAG, "registerReceiver: registered (unknown receiver)");
    }
    // Return the Intent (null is acceptable)
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context.getContentResolver() — return a ContentResolver object
// ============================================================
static DxResult native_context_get_content_resolver(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *resolver_cls = dx_vm_find_class(vm, "Landroid/content/ContentResolver;");
    if (resolver_cls) {
        DxObject *resolver = dx_vm_alloc_object(vm, resolver_cls);
        frame->result = resolver ? DX_OBJ_VALUE(resolver) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context.getApplicationInfo() — return a stub ApplicationInfo object
// ============================================================
static DxResult native_context_get_app_info(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *app_info_cls = dx_vm_find_class(vm, "Landroid/content/pm/ApplicationInfo;");
    if (app_info_cls) {
        DxObject *info = dx_vm_alloc_object(vm, app_info_cls);
        frame->result = info ? DX_OBJ_VALUE(info) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// ClassLoader.loadClass(String name) — delegate to dx_vm_find_class
// ============================================================
static DxResult native_classloader_load_class(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    // args[0] = this (ClassLoader), args[1] = String class name
    const char *name = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        name = dx_vm_get_string_value(args[1].obj);
    }
    if (name) {
        // Convert dotted name (e.g., "com.example.Foo") to descriptor ("Lcom/example/Foo;")
        size_t len = strlen(name);
        char *desc = (char *)dx_malloc(len + 3); // L + name + ; + \0
        if (desc) {
            desc[0] = 'L';
            for (size_t i = 0; i < len; i++) {
                desc[i + 1] = (name[i] == '.') ? '/' : name[i];
            }
            desc[len + 1] = ';';
            desc[len + 2] = '\0';

            DxClass *cls = dx_vm_find_class(vm, desc);
            dx_free(desc);

            if (cls) {
                // Return a Class object wrapping this DxClass
                DxClass *class_cls = dx_vm_find_class(vm, "Ljava/lang/Class;");
                if (class_cls) {
                    DxObject *class_obj = dx_vm_alloc_object(vm, class_cls);
                    if (class_obj) {
                        class_obj->fields[0] = (DxValue){.tag = DX_VAL_INT, .i = (int32_t)(uintptr_t)cls};
                        frame->result = DX_OBJ_VALUE(class_obj);
                        frame->has_result = true;
                        return DX_OK;
                    }
                }
            }
        }
    }
    // Class not found: return null (apps typically catch ClassNotFoundException)
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// ClassLoader.getParent() — return parent ClassLoader from field[0]
// ============================================================
static DxResult native_classloader_get_parent(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    // field[0] stores the parent ClassLoader (or null)
    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj &&
        args[0].obj->fields && args[0].obj->klass &&
        args[0].obj->klass->instance_field_count > 0 &&
        args[0].obj->fields[0].tag == DX_VAL_OBJ) {
        frame->result = args[0].obj->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Class.getClassLoader() — return singleton ClassLoader object
// ============================================================
static DxResult native_class_get_class_loader(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    // Return the singleton PathClassLoader
    if (vm->singleton_classloader) {
        frame->result = DX_OBJ_VALUE(vm->singleton_classloader);
    } else {
        // Lazily create one
        DxClass *pcl_cls = dx_vm_find_class(vm, "Ldalvik/system/PathClassLoader;");
        if (!pcl_cls) pcl_cls = dx_vm_find_class(vm, "Ljava/lang/ClassLoader;");
        if (pcl_cls) {
            DxObject *cl = dx_vm_alloc_object(vm, pcl_cls);
            if (cl) {
                vm->singleton_classloader = cl;
                frame->result = DX_OBJ_VALUE(cl);
            } else {
                frame->result = DX_NULL_VALUE;
            }
        } else {
            frame->result = DX_NULL_VALUE;
        }
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Context.getClassLoader() — return a stub ClassLoader object
// ============================================================
static DxResult native_context_get_class_loader(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    // Delegate to the singleton ClassLoader
    return native_class_get_class_loader(vm, frame, args, arg_count);
}

// ============================================================
// ContentResolver.insert — stub returning null Uri
// ============================================================
static DxResult native_content_resolver_insert(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    DX_INFO(TAG, "ContentResolver.insert: stub (returning null)");
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// ContentResolver.update/delete — stub returning 0
// ============================================================
static DxResult native_content_resolver_update(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    DX_INFO(TAG, "ContentResolver.update/delete: stub (returning 0)");
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Configuration field layout:
//   field 0: orientation (int)       ORIENTATION_PORTRAIT=1, ORIENTATION_LANDSCAPE=2
//   field 1: screenWidthDp (int)
//   field 2: screenHeightDp (int)
//   field 3: locale (String)         e.g. "en_US"
//   field 4: densityDpi (int)
// ============================================================
#define DX_CONFIG_FIELD_ORIENTATION    0
#define DX_CONFIG_FIELD_SCREEN_W_DP   1
#define DX_CONFIG_FIELD_SCREEN_H_DP   2
#define DX_CONFIG_FIELD_LOCALE        3
#define DX_CONFIG_FIELD_DENSITY_DPI   4
#define DX_CONFIG_FIELD_COUNT         5

// Configuration.<init>() -- set sensible defaults
static DxResult native_config_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields) return DX_OK;

    // Defaults: portrait, 393x852 dp (iPhone-ish), en_US, 440 dpi
    if (self->klass && self->klass->instance_field_count >= DX_CONFIG_FIELD_COUNT) {
        self->fields[DX_CONFIG_FIELD_ORIENTATION]  = DX_INT_VALUE(1); // PORTRAIT
        self->fields[DX_CONFIG_FIELD_SCREEN_W_DP]  = DX_INT_VALUE(393);
        self->fields[DX_CONFIG_FIELD_SCREEN_H_DP]  = DX_INT_VALUE(852);
        self->fields[DX_CONFIG_FIELD_LOCALE]       = DX_OBJ_VALUE(dx_vm_create_string(vm, "en_US"));
        self->fields[DX_CONFIG_FIELD_DENSITY_DPI]  = DX_INT_VALUE(440);
    }
    return DX_OK;
}

// Resources.getConfiguration() -> Configuration
static DxResult native_resources_get_configuration(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *config_cls = dx_vm_find_class(vm, "Landroid/content/res/Configuration;");
    if (!config_cls) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *config = dx_vm_alloc_object(vm, config_cls);
    if (config && config->fields && config_cls->instance_field_count >= DX_CONFIG_FIELD_COUNT) {
        config->fields[DX_CONFIG_FIELD_ORIENTATION]  = DX_INT_VALUE(1);
        config->fields[DX_CONFIG_FIELD_SCREEN_W_DP]  = DX_INT_VALUE(393);
        config->fields[DX_CONFIG_FIELD_SCREEN_H_DP]  = DX_INT_VALUE(852);
        config->fields[DX_CONFIG_FIELD_LOCALE]       = DX_OBJ_VALUE(dx_vm_create_string(vm, "en_US"));
        config->fields[DX_CONFIG_FIELD_DENSITY_DPI]  = DX_INT_VALUE(440);
    }
    frame->result = config ? DX_OBJ_VALUE(config) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// java.nio.ByteBuffer native methods
// ============================================================

// Helper: create a ByteBuffer object with fields _data, _position, _limit, _capacity
static DxObject *create_bytebuffer(DxVM *vm, DxObject *data_arr, int32_t capacity) {
    DxClass *bb_cls = dx_vm_find_class(vm, "Ljava/nio/ByteBuffer;");
    if (!bb_cls) return NULL;
    DxObject *bb = dx_vm_alloc_object(vm, bb_cls);
    if (!bb) return NULL;
    dx_vm_set_field(bb, "_data", DX_OBJ_VALUE(data_arr));
    dx_vm_set_field(bb, "_position", DX_INT_VALUE(0));
    dx_vm_set_field(bb, "_limit", DX_INT_VALUE(capacity));
    dx_vm_set_field(bb, "_capacity", DX_INT_VALUE(capacity));
    dx_vm_set_field(bb, "_order", DX_INT_VALUE(0)); // 0=BIG_ENDIAN, 1=LITTLE_ENDIAN
    return bb;
}

// ByteBuffer.allocate(int capacity) -> ByteBuffer
static DxResult native_bb_allocate(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    int32_t cap = (arg_count > 0) ? args[0].i : 0;
    if (cap < 0) cap = 0;
    DxObject *arr = dx_vm_alloc_array(vm, (uint32_t)cap);
    if (!arr) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    for (int32_t i = 0; i < cap; i++) arr->array_elements[i] = DX_INT_VALUE(0);
    DxObject *bb = create_bytebuffer(vm, arr, cap);
    frame->result = bb ? DX_OBJ_VALUE(bb) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.wrap(byte[]) -> ByteBuffer
static DxResult native_bb_wrap(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *arr = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!arr || !arr->is_array) {
        frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK;
    }
    DxObject *bb = create_bytebuffer(vm, arr, (int32_t)arr->array_length);
    frame->result = bb ? DX_OBJ_VALUE(bb) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.put(byte) -> ByteBuffer  (instance: args[0]=this, args[1]=byte)
static DxResult native_bb_put_byte(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxValue pos_val, data_val;
    if (dx_vm_get_field(self, "_data", &data_val) != DX_OK || !data_val.obj || !data_val.obj->is_array) {
        frame->result = DX_OBJ_VALUE(self); frame->has_result = true; return DX_OK;
    }
    if (dx_vm_get_field(self, "_position", &pos_val) != DX_OK) pos_val = DX_INT_VALUE(0);
    int32_t pos = pos_val.i;
    DxObject *arr = data_val.obj;
    if (pos >= 0 && pos < (int32_t)arr->array_length && arg_count > 1) {
        arr->array_elements[pos] = DX_INT_VALUE(args[1].i & 0xFF);
        dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + 1));
    }
    frame->result = DX_OBJ_VALUE(self); frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.put(byte[]) -> ByteBuffer  (instance: args[0]=this, args[1]=byte[])
static DxResult native_bb_put_array(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxValue pos_val, data_val;
    dx_vm_get_field(self, "_data", &data_val);
    dx_vm_get_field(self, "_position", &pos_val);
    DxObject *dst = (data_val.tag == DX_VAL_OBJ) ? data_val.obj : NULL;
    DxObject *src = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    int32_t pos = (pos_val.tag == DX_VAL_INT) ? pos_val.i : 0;
    if (dst && dst->is_array && src && src->is_array) {
        for (uint32_t i = 0; i < src->array_length && pos < (int32_t)dst->array_length; i++, pos++) {
            dst->array_elements[pos] = src->array_elements[i];
        }
        dx_vm_set_field(self, "_position", DX_INT_VALUE(pos));
    }
    frame->result = DX_OBJ_VALUE(self); frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.get() -> byte (at current position)
static DxResult native_bb_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    DxValue pos_val, data_val;
    dx_vm_get_field(self, "_data", &data_val);
    dx_vm_get_field(self, "_position", &pos_val);
    DxObject *arr = (data_val.tag == DX_VAL_OBJ) ? data_val.obj : NULL;
    int32_t pos = (pos_val.tag == DX_VAL_INT) ? pos_val.i : 0;
    int32_t val = 0;
    if (arr && arr->is_array && pos >= 0 && pos < (int32_t)arr->array_length) {
        val = arr->array_elements[pos].i & 0xFF;
        dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + 1));
    }
    frame->result = DX_INT_VALUE(val);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.get(int index) -> byte
static DxResult native_bb_get_index(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t idx = (arg_count > 1) ? args[1].i : 0;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    DxValue data_val;
    dx_vm_get_field(self, "_data", &data_val);
    DxObject *arr = (data_val.tag == DX_VAL_OBJ) ? data_val.obj : NULL;
    int32_t val = 0;
    if (arr && arr->is_array && idx >= 0 && idx < (int32_t)arr->array_length) {
        val = arr->array_elements[idx].i & 0xFF;
    }
    frame->result = DX_INT_VALUE(val);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.position() -> int
static DxResult native_bb_get_position(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue v = DX_INT_VALUE(0);
    if (self) dx_vm_get_field(self, "_position", &v);
    frame->result = (v.tag == DX_VAL_INT) ? v : DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.position(int) -> ByteBuffer
static DxResult native_bb_set_position(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1) dx_vm_set_field(self, "_position", DX_INT_VALUE(args[1].i));
    frame->result = self ? DX_OBJ_VALUE(self) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.limit() -> int
static DxResult native_bb_get_limit(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue v = DX_INT_VALUE(0);
    if (self) dx_vm_get_field(self, "_limit", &v);
    frame->result = (v.tag == DX_VAL_INT) ? v : DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.limit(int) -> ByteBuffer
static DxResult native_bb_set_limit(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1) dx_vm_set_field(self, "_limit", DX_INT_VALUE(args[1].i));
    frame->result = self ? DX_OBJ_VALUE(self) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.capacity() -> int
static DxResult native_bb_capacity(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue v = DX_INT_VALUE(0);
    if (self) dx_vm_get_field(self, "_capacity", &v);
    frame->result = (v.tag == DX_VAL_INT) ? v : DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.remaining() -> int (limit - position)
static DxResult native_bb_remaining(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue pos = DX_INT_VALUE(0), lim = DX_INT_VALUE(0);
    if (self) {
        dx_vm_get_field(self, "_position", &pos);
        dx_vm_get_field(self, "_limit", &lim);
    }
    frame->result = DX_INT_VALUE(lim.i - pos.i);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.hasRemaining() -> boolean (position < limit)
static DxResult native_bb_hasRemaining(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue pos = DX_INT_VALUE(0), lim = DX_INT_VALUE(0);
    if (self) {
        dx_vm_get_field(self, "_position", &pos);
        dx_vm_get_field(self, "_limit", &lim);
    }
    frame->result = DX_INT_VALUE(pos.i < lim.i ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.flip() -> ByteBuffer (limit=position, position=0)
static DxResult native_bb_flip(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self) {
        DxValue pos = DX_INT_VALUE(0);
        dx_vm_get_field(self, "_position", &pos);
        dx_vm_set_field(self, "_limit", pos);
        dx_vm_set_field(self, "_position", DX_INT_VALUE(0));
    }
    frame->result = self ? DX_OBJ_VALUE(self) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.clear() -> ByteBuffer (position=0, limit=capacity)
static DxResult native_bb_clear(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self) {
        DxValue cap = DX_INT_VALUE(0);
        dx_vm_get_field(self, "_capacity", &cap);
        dx_vm_set_field(self, "_position", DX_INT_VALUE(0));
        dx_vm_set_field(self, "_limit", cap);
    }
    frame->result = self ? DX_OBJ_VALUE(self) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.rewind() -> ByteBuffer (position=0)
static DxResult native_bb_rewind(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self) dx_vm_set_field(self, "_position", DX_INT_VALUE(0));
    frame->result = self ? DX_OBJ_VALUE(self) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.array() -> byte[]
static DxResult native_bb_array(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue data = DX_NULL_VALUE;
    if (self) dx_vm_get_field(self, "_data", &data);
    frame->result = data;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.order() -> ByteOrder
static DxResult native_bb_get_order(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue ord = DX_INT_VALUE(0);
    if (self) dx_vm_get_field(self, "_order", &ord);
    DxClass *bo_cls = dx_vm_find_class(vm, "Ljava/nio/ByteOrder;");
    if (bo_cls && bo_cls->static_field_count >= 2 && bo_cls->static_fields) {
        int idx = (ord.tag == DX_VAL_INT && ord.i == 1) ? 1 : 0;
        frame->result = bo_cls->static_fields[idx];
        frame->has_result = true;
        return DX_OK;
    }
    frame->result = DX_NULL_VALUE; frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.order(ByteOrder) -> ByteBuffer
static DxResult native_bb_set_order(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxValue v = DX_INT_VALUE(0);
        dx_vm_get_field(args[1].obj, "_val", &v);
        dx_vm_set_field(self, "_order", v);
    }
    frame->result = self ? DX_OBJ_VALUE(self) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.getInt() -> int (read 4 bytes at position)
static DxResult native_bb_getInt(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    DxValue pos_val, data_val, ord_val;
    dx_vm_get_field(self, "_data", &data_val);
    dx_vm_get_field(self, "_position", &pos_val);
    dx_vm_get_field(self, "_order", &ord_val);
    DxObject *arr = (data_val.tag == DX_VAL_OBJ) ? data_val.obj : NULL;
    int32_t pos = (pos_val.tag == DX_VAL_INT) ? pos_val.i : 0;
    int32_t is_le = (ord_val.tag == DX_VAL_INT) ? ord_val.i : 0;
    int32_t val = 0;
    if (arr && arr->is_array && pos + 4 <= (int32_t)arr->array_length) {
        uint8_t b0 = (uint8_t)(arr->array_elements[pos].i & 0xFF);
        uint8_t b1 = (uint8_t)(arr->array_elements[pos+1].i & 0xFF);
        uint8_t b2 = (uint8_t)(arr->array_elements[pos+2].i & 0xFF);
        uint8_t b3 = (uint8_t)(arr->array_elements[pos+3].i & 0xFF);
        if (is_le) {
            val = (int32_t)((uint32_t)b0 | ((uint32_t)b1 << 8) | ((uint32_t)b2 << 16) | ((uint32_t)b3 << 24));
        } else {
            val = (int32_t)(((uint32_t)b0 << 24) | ((uint32_t)b1 << 16) | ((uint32_t)b2 << 8) | (uint32_t)b3);
        }
        dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + 4));
    }
    frame->result = DX_INT_VALUE(val);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.putInt(int) -> ByteBuffer (write 4 bytes at position)
static DxResult native_bb_putInt(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t val = (arg_count > 1) ? args[1].i : 0;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxValue pos_val, data_val, ord_val;
    dx_vm_get_field(self, "_data", &data_val);
    dx_vm_get_field(self, "_position", &pos_val);
    dx_vm_get_field(self, "_order", &ord_val);
    DxObject *arr = (data_val.tag == DX_VAL_OBJ) ? data_val.obj : NULL;
    int32_t pos = (pos_val.tag == DX_VAL_INT) ? pos_val.i : 0;
    int32_t is_le = (ord_val.tag == DX_VAL_INT) ? ord_val.i : 0;
    if (arr && arr->is_array && pos + 4 <= (int32_t)arr->array_length) {
        uint32_t u = (uint32_t)val;
        if (is_le) {
            arr->array_elements[pos]   = DX_INT_VALUE((int32_t)(u & 0xFF));
            arr->array_elements[pos+1] = DX_INT_VALUE((int32_t)((u >> 8) & 0xFF));
            arr->array_elements[pos+2] = DX_INT_VALUE((int32_t)((u >> 16) & 0xFF));
            arr->array_elements[pos+3] = DX_INT_VALUE((int32_t)((u >> 24) & 0xFF));
        } else {
            arr->array_elements[pos]   = DX_INT_VALUE((int32_t)((u >> 24) & 0xFF));
            arr->array_elements[pos+1] = DX_INT_VALUE((int32_t)((u >> 16) & 0xFF));
            arr->array_elements[pos+2] = DX_INT_VALUE((int32_t)((u >> 8) & 0xFF));
            arr->array_elements[pos+3] = DX_INT_VALUE((int32_t)(u & 0xFF));
        }
        dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + 4));
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.getShort() -> short (read 2 bytes at position)
static DxResult native_bb_getShort(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    DxValue pos_val, data_val, ord_val;
    dx_vm_get_field(self, "_data", &data_val);
    dx_vm_get_field(self, "_position", &pos_val);
    dx_vm_get_field(self, "_order", &ord_val);
    DxObject *arr = (data_val.tag == DX_VAL_OBJ) ? data_val.obj : NULL;
    int32_t pos = (pos_val.tag == DX_VAL_INT) ? pos_val.i : 0;
    int32_t is_le = (ord_val.tag == DX_VAL_INT) ? ord_val.i : 0;
    int16_t val = 0;
    if (arr && arr->is_array && pos + 2 <= (int32_t)arr->array_length) {
        uint8_t b0 = (uint8_t)(arr->array_elements[pos].i & 0xFF);
        uint8_t b1 = (uint8_t)(arr->array_elements[pos+1].i & 0xFF);
        if (is_le) {
            val = (int16_t)((uint16_t)b0 | ((uint16_t)b1 << 8));
        } else {
            val = (int16_t)(((uint16_t)b0 << 8) | (uint16_t)b1);
        }
        dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + 2));
    }
    frame->result = DX_INT_VALUE((int32_t)val);
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.putShort(short) -> ByteBuffer
static DxResult native_bb_putShort(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t val = (arg_count > 1) ? args[1].i : 0;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxValue pos_val, data_val, ord_val;
    dx_vm_get_field(self, "_data", &data_val);
    dx_vm_get_field(self, "_position", &pos_val);
    dx_vm_get_field(self, "_order", &ord_val);
    DxObject *arr = (data_val.tag == DX_VAL_OBJ) ? data_val.obj : NULL;
    int32_t pos = (pos_val.tag == DX_VAL_INT) ? pos_val.i : 0;
    int32_t is_le = (ord_val.tag == DX_VAL_INT) ? ord_val.i : 0;
    if (arr && arr->is_array && pos + 2 <= (int32_t)arr->array_length) {
        uint16_t u = (uint16_t)(val & 0xFFFF);
        if (is_le) {
            arr->array_elements[pos]   = DX_INT_VALUE((int32_t)(u & 0xFF));
            arr->array_elements[pos+1] = DX_INT_VALUE((int32_t)((u >> 8) & 0xFF));
        } else {
            arr->array_elements[pos]   = DX_INT_VALUE((int32_t)((u >> 8) & 0xFF));
            arr->array_elements[pos+1] = DX_INT_VALUE((int32_t)(u & 0xFF));
        }
        dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + 2));
    }
    frame->result = self ? DX_OBJ_VALUE(self) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.getLong() -> long (read 8 bytes at position)
static DxResult native_bb_getLong(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self) { frame->result = (DxValue){.tag = DX_VAL_LONG, .l = 0}; frame->has_result = true; return DX_OK; }
    DxValue pos_val, data_val, ord_val;
    dx_vm_get_field(self, "_data", &data_val);
    dx_vm_get_field(self, "_position", &pos_val);
    dx_vm_get_field(self, "_order", &ord_val);
    DxObject *arr = (data_val.tag == DX_VAL_OBJ) ? data_val.obj : NULL;
    int32_t pos = (pos_val.tag == DX_VAL_INT) ? pos_val.i : 0;
    int32_t is_le = (ord_val.tag == DX_VAL_INT) ? ord_val.i : 0;
    int64_t val = 0;
    if (arr && arr->is_array && pos + 8 <= (int32_t)arr->array_length) {
        uint64_t result = 0;
        if (is_le) {
            for (int b = 7; b >= 0; b--) {
                result = (result << 8) | (uint8_t)(arr->array_elements[pos+b].i & 0xFF);
            }
        } else {
            for (int b = 0; b < 8; b++) {
                result = (result << 8) | (uint8_t)(arr->array_elements[pos+b].i & 0xFF);
            }
        }
        val = (int64_t)result;
        dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + 8));
    }
    frame->result = (DxValue){.tag = DX_VAL_LONG, .l = val};
    frame->has_result = true;
    return DX_OK;
}

// ByteBuffer.putLong(long) -> ByteBuffer
static DxResult native_bb_putLong(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int64_t val = (arg_count > 1) ? args[1].l : 0;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxValue pos_val, data_val, ord_val;
    dx_vm_get_field(self, "_data", &data_val);
    dx_vm_get_field(self, "_position", &pos_val);
    dx_vm_get_field(self, "_order", &ord_val);
    DxObject *arr = (data_val.tag == DX_VAL_OBJ) ? data_val.obj : NULL;
    int32_t pos = (pos_val.tag == DX_VAL_INT) ? pos_val.i : 0;
    int32_t is_le = (ord_val.tag == DX_VAL_INT) ? ord_val.i : 0;
    if (arr && arr->is_array && pos + 8 <= (int32_t)arr->array_length) {
        uint64_t u = (uint64_t)val;
        for (int b = 0; b < 8; b++) {
            int idx = is_le ? (pos + b) : (pos + 7 - b);
            arr->array_elements[idx] = DX_INT_VALUE((int32_t)(u & 0xFF));
            u >>= 8;
        }
        dx_vm_set_field(self, "_position", DX_INT_VALUE(pos + 8));
    }
    frame->result = self ? DX_OBJ_VALUE(self) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ByteOrder.nativeOrder() -> ByteOrder (LITTLE_ENDIAN on ARM)
static DxResult native_byteorder_nativeOrder(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *bo_cls = dx_vm_find_class(vm, "Ljava/nio/ByteOrder;");
    if (bo_cls && bo_cls->static_field_count >= 2 && bo_cls->static_fields) {
        frame->result = bo_cls->static_fields[1]; // LITTLE_ENDIAN is index 1
        frame->has_result = true;
        return DX_OK;
    }
    frame->result = DX_NULL_VALUE; frame->has_result = true;
    return DX_OK;
}

// Charset.forName(String) -> Charset
static DxResult native_charset_forName(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *name = "UTF-8";
    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        const char *s = dx_vm_get_string_value(args[0].obj);
        if (s) name = s;
    }
    DxClass *cs_cls = dx_vm_find_class(vm, "Ljava/nio/charset/Charset;");
    if (cs_cls) {
        DxObject *cs = dx_vm_alloc_object(vm, cs_cls);
        if (cs) {
            DxObject *name_str = dx_vm_create_string(vm, name);
            dx_vm_set_field(cs, "_name", name_str ? DX_OBJ_VALUE(name_str) : DX_NULL_VALUE);
            frame->result = DX_OBJ_VALUE(cs);
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE; frame->has_result = true;
    return DX_OK;
}

// Charset.defaultCharset() -> Charset (UTF-8)
static DxResult native_charset_defaultCharset(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxValue utf8_arg;
    DxObject *s = dx_vm_create_string(vm, "UTF-8");
    utf8_arg = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
    return native_charset_forName(vm, frame, &utf8_arg, 1);
}

// Charset.name() -> String
static DxResult native_charset_name(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue name = DX_NULL_VALUE;
    if (self) dx_vm_get_field(self, "_name", &name);
    frame->result = name;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Pair constructor: store first/second fields
// ============================================================
static DxResult native_pair_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self) {
        DxValue first = (arg_count > 1) ? args[1] : DX_NULL_VALUE;
        DxValue second = (arg_count > 2) ? args[2] : DX_NULL_VALUE;
        dx_vm_set_field(self, "first", first);
        dx_vm_set_field(self, "second", second);
    }
    return DX_OK;
}

// Pair.create(A, B) -> Pair
static DxResult native_pair_create(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxClass *pair_cls = dx_vm_find_class(vm, "Landroid/util/Pair;");
    if (!pair_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *pair = dx_vm_alloc_object(vm, pair_cls);
    if (pair) {
        DxValue first = (arg_count > 0) ? args[0] : DX_NULL_VALUE;
        DxValue second = (arg_count > 1) ? args[1] : DX_NULL_VALUE;
        dx_vm_set_field(pair, "first", first);
        dx_vm_set_field(pair, "second", second);
    }
    frame->result = pair ? DX_OBJ_VALUE(pair) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Pair.toString() -> "(first, second)"
static DxResult native_pair_toString(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "Pair{first, second}");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Location native methods (field-backed)
// ============================================================

static DxResult native_location_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self) {
        DxValue provider = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1] : DX_NULL_VALUE;
        dx_vm_set_field(self, "provider", provider);
        dx_vm_set_field(self, "latitude", (DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0});
        dx_vm_set_field(self, "longitude", (DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0});
        dx_vm_set_field(self, "altitude", (DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0});
        dx_vm_set_field(self, "accuracy", (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f});
        dx_vm_set_field(self, "time", (DxValue){.tag = DX_VAL_LONG, .l = 0});
    }
    return DX_OK;
}

static DxResult native_location_get_latitude(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val;
    if (self && dx_vm_get_field(self, "latitude", &val) == DX_OK && val.tag == DX_VAL_DOUBLE) {
        frame->result = val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0};
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_location_get_longitude(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val;
    if (self && dx_vm_get_field(self, "longitude", &val) == DX_OK && val.tag == DX_VAL_DOUBLE) {
        frame->result = val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0};
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_location_get_altitude(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val;
    if (self && dx_vm_get_field(self, "altitude", &val) == DX_OK && val.tag == DX_VAL_DOUBLE) {
        frame->result = val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_DOUBLE, .d = 0.0};
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_location_get_accuracy(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val;
    if (self && dx_vm_get_field(self, "accuracy", &val) == DX_OK && val.tag == DX_VAL_FLOAT) {
        frame->result = val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_location_get_time(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val;
    if (self && dx_vm_get_field(self, "time", &val) == DX_OK && val.tag == DX_VAL_LONG) {
        frame->result = val;
    } else {
        frame->result = (DxValue){.tag = DX_VAL_LONG, .l = 0};
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_location_get_provider(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val;
    if (self && dx_vm_get_field(self, "provider", &val) == DX_OK) {
        frame->result = val;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_location_set_latitude(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1) {
        dx_vm_set_field(self, "latitude", args[1]);
    }
    return DX_OK;
}

static DxResult native_location_set_longitude(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1) {
        dx_vm_set_field(self, "longitude", args[1]);
    }
    return DX_OK;
}

static DxResult native_location_set_altitude(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1) {
        dx_vm_set_field(self, "altitude", args[1]);
    }
    return DX_OK;
}

static DxResult native_location_set_accuracy(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1) {
        dx_vm_set_field(self, "accuracy", args[1]);
    }
    return DX_OK;
}

static DxResult native_location_set_time(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1) {
        dx_vm_set_field(self, "time", args[1]);
    }
    return DX_OK;
}

static DxResult native_location_set_provider(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1) {
        dx_vm_set_field(self, "provider", args[1]);
    }
    return DX_OK;
}

static DxResult native_location_distance_to(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = 0.0f};
    frame->has_result = true;
    return DX_OK;
}

// LocationManager.getBestProvider(Criteria, boolean) -> "gps"
static DxResult native_locmgr_get_best_provider(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "gps");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// NotificationChannel native methods (field-backed)
// ============================================================

static DxResult native_notif_channel_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self) {
        DxValue id   = (arg_count > 1) ? args[1] : DX_NULL_VALUE;
        DxValue name = (arg_count > 2) ? args[2] : DX_NULL_VALUE;
        DxValue imp  = (arg_count > 3) ? args[3] : DX_INT_VALUE(0);
        dx_vm_set_field(self, "id", id);
        dx_vm_set_field(self, "name", name);
        dx_vm_set_field(self, "importance", imp);
        DX_INFO(TAG, "NotificationChannel created: id=%s",
                (id.tag == DX_VAL_OBJ && id.obj) ? dx_vm_get_string_value(id.obj) : "?");
    }
    return DX_OK;
}

static DxResult native_notif_channel_get_id(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val;
    if (self && dx_vm_get_field(self, "id", &val) == DX_OK) {
        frame->result = val;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_notif_channel_get_name(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val;
    if (self && dx_vm_get_field(self, "name", &val) == DX_OK) {
        frame->result = val;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_notif_channel_get_importance(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue val;
    if (self && dx_vm_get_field(self, "importance", &val) == DX_OK && val.tag == DX_VAL_INT) {
        frame->result = val;
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

// NotificationManager.createNotificationChannel - log and no-op
static DxResult native_notifmgr_create_channel(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxValue id_val;
        if (dx_vm_get_field(args[1].obj, "id", &id_val) == DX_OK && id_val.tag == DX_VAL_OBJ && id_val.obj) {
            DX_INFO(TAG, "createNotificationChannel: %s", dx_vm_get_string_value(id_val.obj));
        } else {
            DX_INFO(TAG, "createNotificationChannel called");
        }
    }
    return DX_OK;
}

// NotificationManager.notify(id, notification) - log and no-op
static DxResult native_notifmgr_notify(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    int32_t id = (arg_count > 1 && args[1].tag == DX_VAL_INT) ? args[1].i : 0;
    DX_INFO(TAG, "NotificationManager.notify(id=%d) - stubbed", id);
    return DX_OK;
}

// PendingIntent factory methods - return a stub PendingIntent object
static DxResult native_pending_intent_factory(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *pi_cls = dx_vm_find_class(vm, "Landroid/app/PendingIntent;");
    if (pi_cls) {
        DxObject *pi = dx_vm_alloc_object(vm, pi_cls);
        frame->result = pi ? DX_OBJ_VALUE(pi) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Environment.getExternalStorageDirectory() -> File("/sdcard")
static DxResult native_env_get_ext_storage(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *file_cls = dx_vm_find_class(vm, "Ljava/io/File;");
    if (!file_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *file = dx_vm_alloc_object(vm, file_cls);
    if (file) dx_vm_set_field(file, "_path", DX_OBJ_VALUE(dx_vm_create_string(vm, "/sdcard")));
    frame->result = file ? DX_OBJ_VALUE(file) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Environment.getDataDirectory() -> File("/data")
static DxResult native_env_get_data_dir(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *file_cls = dx_vm_find_class(vm, "Ljava/io/File;");
    if (!file_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *file = dx_vm_alloc_object(vm, file_cls);
    if (file) dx_vm_set_field(file, "_path", DX_OBJ_VALUE(dx_vm_create_string(vm, "/data")));
    frame->result = file ? DX_OBJ_VALUE(file) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Environment.getExternalStorageState() -> "mounted"
static DxResult native_env_get_storage_state(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "mounted");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// DateFormat.format(CharSequence, Date) -> "2026-01-01"
static DxResult native_dateformat_format(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "2026-01-01 00:00:00");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// SimpleDateFormat.format(Date) -> pattern string stub
static DxResult native_sdf_format(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    // Try to return the pattern stored on the object, else a default
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxValue pattern = DX_NULL_VALUE;
    if (self) dx_vm_get_field(self, "_pattern", &pattern);
    if (pattern.tag == DX_VAL_OBJ && pattern.obj) {
        frame->result = pattern;
    } else {
        DxObject *str = dx_vm_create_string(vm, "2026-01-01");
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// SimpleDateFormat.<init>(String) - store pattern
static DxResult native_sdf_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && arg_count > 1) {
        dx_vm_set_field(self, "_pattern", args[1]);
    }
    return DX_OK;
}

// Base64.encodeToString(byte[], int) -> ""
static DxResult native_base64_encode_to_string(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Base64.encode(byte[], int) -> empty byte[]
static DxResult native_base64_encode(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *obj_cls = vm->class_object;
    DxObject *arr = dx_vm_alloc_object(vm, obj_cls);
    if (arr) {
        arr->is_array = true;
        arr->array_length = 0;
        arr->array_elements = NULL;
    }
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Base64.decode(String, int) -> empty byte[]
static DxResult native_base64_decode(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    return native_base64_encode(vm, frame, args, arg_count);
}

// Looper.getThread() -> Thread.currentThread()
static DxResult native_looper_get_thread(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *thread_cls = dx_vm_find_class(vm, "Ljava/lang/Thread;");
    if (!thread_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *t = dx_vm_alloc_object(vm, thread_cls);
    frame->result = t ? DX_OBJ_VALUE(t) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// WebView native methods
// ============================================================

static DxResult native_webview_load_url(DxVM *vm, DxFrame *frame,
                                         DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *url_obj = (arg_count > 1) ? args[1].obj : NULL;

    if (!self || !self->ui_node) {
        DX_WARN(TAG, "loadUrl on WebView without UI node");
        return DX_OK;
    }

    const char *url = "";
    if (url_obj) {
        url = dx_vm_get_string_value(url_obj);
        if (!url) url = "";
    }

    dx_free(self->ui_node->web_url);
    self->ui_node->web_url = dx_strdup(url);
    // Clear any previous HTML content since we're loading a URL
    dx_free(self->ui_node->web_html);
    self->ui_node->web_html = NULL;
    DX_INFO(TAG, "WebView.loadUrl(\"%s\") on view 0x%x", url, self->ui_node->view_id);

    rebuild_render_model(vm);
    return DX_OK;
}

static DxResult native_webview_load_data(DxVM *vm, DxFrame *frame,
                                          DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *data_obj = (arg_count > 1) ? args[1].obj : NULL;

    if (!self || !self->ui_node) {
        DX_WARN(TAG, "loadData on WebView without UI node");
        return DX_OK;
    }

    const char *data = "";
    if (data_obj) {
        data = dx_vm_get_string_value(data_obj);
        if (!data) data = "";
    }

    dx_free(self->ui_node->web_html);
    self->ui_node->web_html = dx_strdup(data);
    // Clear any previous URL since we're loading HTML directly
    dx_free(self->ui_node->web_url);
    self->ui_node->web_url = NULL;
    DX_INFO(TAG, "WebView.loadData() on view 0x%x (%zu bytes)", self->ui_node->view_id, strlen(data));

    rebuild_render_model(vm);
    return DX_OK;
}

static DxResult native_webview_load_data_with_base(DxVM *vm, DxFrame *frame,
                                                     DxValue *args, uint32_t arg_count) {
    // loadDataWithBaseURL(baseUrl, data, mimeType, encoding, historyUrl)
    // We only care about the data (arg 2)
    (void)frame;
    DxObject *self = args[0].obj;
    DxObject *data_obj = (arg_count > 2) ? args[2].obj : NULL;

    if (!self || !self->ui_node) {
        DX_WARN(TAG, "loadDataWithBaseURL on WebView without UI node");
        return DX_OK;
    }

    const char *data = "";
    if (data_obj) {
        data = dx_vm_get_string_value(data_obj);
        if (!data) data = "";
    }

    dx_free(self->ui_node->web_html);
    self->ui_node->web_html = dx_strdup(data);
    dx_free(self->ui_node->web_url);
    self->ui_node->web_url = NULL;
    DX_INFO(TAG, "WebView.loadDataWithBaseURL() on view 0x%x", self->ui_node->view_id);

    rebuild_render_model(vm);
    return DX_OK;
}

static DxResult native_webview_get_settings(DxVM *vm, DxFrame *frame,
                                              DxValue *args, uint32_t arg_count) {
    (void)arg_count; (void)args;
    DxClass *settings_cls = dx_vm_find_class(vm, "Landroid/webkit/WebSettings;");
    if (settings_cls) {
        DxObject *settings = dx_vm_alloc_object(vm, settings_cls);
        frame->result = settings ? DX_OBJ_VALUE(settings) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// System service native methods — Clipboard, Display, Connectivity, etc.
// ============================================================

// --- ClipboardManager: field[0] = stored ClipData ---
#define CLIPBOARD_FIELD_CLIP 0
#define CLIPBOARD_FIELD_COUNT 1

static DxResult native_clipboard_set_primary_clip(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass &&
        self->klass->instance_field_count >= CLIPBOARD_FIELD_COUNT && arg_count > 1) {
        self->fields[CLIPBOARD_FIELD_CLIP] = args[1]; // store ClipData
    }
    return DX_OK;
}

static DxResult native_clipboard_get_primary_clip(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass &&
        self->klass->instance_field_count >= CLIPBOARD_FIELD_COUNT) {
        frame->result = self->fields[CLIPBOARD_FIELD_CLIP];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_clipboard_has_primary_clip(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    bool has = false;
    if (self && self->fields && self->klass &&
        self->klass->instance_field_count >= CLIPBOARD_FIELD_COUNT) {
        has = (self->fields[CLIPBOARD_FIELD_CLIP].tag == DX_VAL_OBJ &&
               self->fields[CLIPBOARD_FIELD_CLIP].obj != NULL);
    }
    frame->result = DX_INT_VALUE(has ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// --- ClipData: field[0] = label, field[1] = text ---
#define CLIPDATA_FIELD_LABEL 0
#define CLIPDATA_FIELD_TEXT  1
#define CLIPDATA_FIELD_COUNT 2

// ClipData.newPlainText(label, text) — static factory
static DxResult native_clipdata_new_plain_text(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxClass *cd_cls = dx_vm_find_class(vm, "Landroid/content/ClipData;");
    if (!cd_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *cd = dx_vm_alloc_object(vm, cd_cls);
    if (cd && cd->fields && cd->klass->instance_field_count >= CLIPDATA_FIELD_COUNT) {
        cd->fields[CLIPDATA_FIELD_LABEL] = (arg_count > 0) ? args[0] : DX_NULL_VALUE;
        cd->fields[CLIPDATA_FIELD_TEXT]  = (arg_count > 1) ? args[1] : DX_NULL_VALUE;
    }
    frame->result = cd ? DX_OBJ_VALUE(cd) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ClipData.getItemAt(int) — return ClipData.Item stub with same text
static DxResult native_clipdata_get_item_at(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    DxClass *item_cls = dx_vm_find_class(vm, "Landroid/content/ClipData$Item;");
    if (!item_cls || !self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *item = dx_vm_alloc_object(vm, item_cls);
    if (item && item->fields && item->klass->instance_field_count >= 1 &&
        self->fields && self->klass->instance_field_count >= CLIPDATA_FIELD_COUNT) {
        item->fields[0] = self->fields[CLIPDATA_FIELD_TEXT]; // copy text
    }
    frame->result = item ? DX_OBJ_VALUE(item) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ClipData.Item.getText() — return stored text
static DxResult native_clipdata_item_get_text(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// --- Display: getSize(Point) — set 393x852, getMetrics(DisplayMetrics) ---
static DxResult native_display_get_size(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxObject *point = args[1].obj;
        if (point->fields && point->klass && point->klass->instance_field_count >= 2) {
            point->fields[0] = DX_INT_VALUE(393);  // x = width
            point->fields[1] = DX_INT_VALUE(852);  // y = height
        }
    }
    return DX_OK;
}

// DisplayMetrics field layout
#define DM_FIELD_DENSITY     0  // float density
#define DM_FIELD_DENSITY_DPI 1  // int densityDpi
#define DM_FIELD_WIDTH       2  // int widthPixels
#define DM_FIELD_HEIGHT      3  // int heightPixels
#define DM_FIELD_SCALED_DENSITY 4 // float scaledDensity
#define DM_FIELD_COUNT       5

static DxResult native_display_get_metrics(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxObject *dm = args[1].obj;
        if (dm->fields && dm->klass && dm->klass->instance_field_count >= DM_FIELD_COUNT) {
            dm->fields[DM_FIELD_DENSITY]     = (DxValue){.tag = DX_VAL_FLOAT, .f = 2.75f};
            dm->fields[DM_FIELD_DENSITY_DPI] = DX_INT_VALUE(440);
            dm->fields[DM_FIELD_WIDTH]       = DX_INT_VALUE(1080); // 393 * 2.75
            dm->fields[DM_FIELD_HEIGHT]      = DX_INT_VALUE(2343); // 852 * 2.75
            dm->fields[DM_FIELD_SCALED_DENSITY] = (DxValue){.tag = DX_VAL_FLOAT, .f = 2.75f};
        }
    }
    return DX_OK;
}

// WindowManager.getDefaultDisplay() — return Display object
static DxResult native_winmgr_get_default_display(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *display_cls = dx_vm_find_class(vm, "Landroid/view/Display;");
    if (!display_cls) display_cls = vm->class_object;
    DxObject *display = dx_vm_alloc_object(vm, display_cls);
    frame->result = display ? DX_OBJ_VALUE(display) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- ConnectivityManager: return proper NetworkInfo/Network ---
static DxResult native_connectivity_get_active_network_info(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *ni_cls = dx_vm_find_class(vm, "Landroid/net/NetworkInfo;");
    if (!ni_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *ni = dx_vm_alloc_object(vm, ni_cls);
    frame->result = ni ? DX_OBJ_VALUE(ni) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_connectivity_get_active_network(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *net_cls = dx_vm_find_class(vm, "Landroid/net/Network;");
    if (!net_cls) net_cls = vm->class_object;
    DxObject *net = dx_vm_alloc_object(vm, net_cls);
    frame->result = net ? DX_OBJ_VALUE(net) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// NetworkInfo.getTypeName() — "WIFI"
static DxResult native_network_info_get_type_name(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "WIFI");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- PowerManager: newWakeLock returns WakeLock stub ---
static DxResult native_power_new_wakelock(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *wl_cls = dx_vm_find_class(vm, "Landroid/os/PowerManager$WakeLock;");
    if (!wl_cls) wl_cls = vm->class_object;
    DxObject *wl = dx_vm_alloc_object(vm, wl_cls);
    frame->result = wl ? DX_OBJ_VALUE(wl) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- VibrationEffect.createOneShot — return stub ---
static DxResult native_vibration_effect_create_one_shot(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *ve_cls = dx_vm_find_class(vm, "Landroid/os/VibrationEffect;");
    if (!ve_cls) ve_cls = vm->class_object;
    DxObject *ve = dx_vm_alloc_object(vm, ve_cls);
    frame->result = ve ? DX_OBJ_VALUE(ve) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- AccountManager.get(Context) — return instance ---
static DxResult native_account_manager_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *am_cls = dx_vm_find_class(vm, "Landroid/accounts/AccountManager;");
    if (!am_cls) am_cls = vm->class_object;
    DxObject *am = dx_vm_alloc_object(vm, am_cls);
    frame->result = am ? DX_OBJ_VALUE(am) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// AccountManager.getAccounts() — return empty Account[]
static DxResult native_account_manager_get_accounts(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *arr = dx_vm_alloc_array(vm, 0);
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- JobScheduler.schedule — return RESULT_SUCCESS (1) ---
static DxResult native_job_scheduler_schedule(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(1); // RESULT_SUCCESS
    frame->has_result = true;
    return DX_OK;
}

// --- JobInfo.Builder — build() returns JobInfo ---
static DxResult native_jobinfo_builder_build(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxClass *ji_cls = dx_vm_find_class(vm, "Landroid/app/job/JobInfo;");
    if (!ji_cls) ji_cls = vm->class_object;
    DxObject *ji = dx_vm_alloc_object(vm, ji_cls);
    frame->result = ji ? DX_OBJ_VALUE(ji) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Retrofit2: Real annotation-driven HTTP dispatch
// ============================================================
// Retrofit object fields (instance_field_count=2):
//   [0] = base URL string object
//   [1] = OkHttpClient object (optional)
// Retrofit$Builder fields (instance_field_count=3):
//   [0] = base URL string object
//   [1] = OkHttpClient object
//   [2] = converter factories (unused for now)

// Retrofit$Builder.baseUrl(String) -> Builder
static DxResult native_retrofit_builder_baseurl(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 && arg_count > 1) {
        if (args[1].tag == DX_VAL_OBJ && args[1].obj) {
            self->fields[0] = args[1]; // store base URL string
        }
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

// Retrofit$Builder.client(OkHttpClient) -> Builder
static DxResult native_retrofit_builder_client(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2 && arg_count > 1) {
        self->fields[1] = args[1]; // store OkHttpClient
    }
    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

// Retrofit$Builder.build() -> Retrofit
static DxResult native_retrofit_builder_build(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *retrofit_cls = dx_vm_find_class(vm, "Lretrofit2/Retrofit;");
    if (!retrofit_cls) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *retrofit = dx_vm_alloc_object(vm, retrofit_cls);
    if (retrofit && retrofit->fields && retrofit->klass && self && self->fields && self->klass) {
        // Copy base URL from builder field[0] to retrofit field[0]
        if (self->klass->instance_field_count >= 1)
            retrofit->fields[0] = self->fields[0];
        // Copy OkHttpClient from builder field[1] to retrofit field[1]
        if (self->klass->instance_field_count >= 2 && retrofit->klass->instance_field_count >= 2)
            retrofit->fields[1] = self->fields[1];
    }
    dx_log_msg(DX_LOG_INFO, "Retrofit", "Retrofit.Builder.build() created Retrofit instance");
    frame->result = retrofit ? DX_OBJ_VALUE(retrofit) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Helper: Check if a method has one of the Retrofit HTTP annotations and extract info
// Returns the HTTP method string ("GET", "POST", etc.) or NULL if no annotation found
// Sets *out_path to the annotation path value
static const char *retrofit_get_http_annotation(DxMethod *method, const char **out_path) {
    if (!method || !method->annotations || method->annotation_count == 0) return NULL;
    static const struct {
        const char *anno_type;
        const char *http_method;
    } http_annos[] = {
        { "Lretrofit2/http/GET;",    "GET" },
        { "Lretrofit2/http/POST;",   "POST" },
        { "Lretrofit2/http/PUT;",    "PUT" },
        { "Lretrofit2/http/DELETE;", "DELETE" },
        { "Lretrofit2/http/PATCH;",  "PATCH" },
        { "Lretrofit2/http/HEAD;",   "HEAD" },
        { "Lretrofit2/http/OPTIONS;","OPTIONS" },
        { "Lretrofit2/http/HTTP;",   NULL }, // uses method element
    };
    for (int i = 0; i < 8; i++) {
        const DxAnnotationEntry *ann = dx_method_get_annotation(method, http_annos[i].anno_type);
        if (ann) {
            if (out_path) *out_path = dx_annotation_get_string(ann, "value");
            if (http_annos[i].http_method) {
                return http_annos[i].http_method;
            }
            // For @HTTP, read the "method" element
            const char *m = dx_annotation_get_string(ann, "method");
            return m ? m : "GET";
        }
    }
    return NULL;
}

// Helper: perform URL path substitution for @Path parameters
// E.g., "/users/{id}/repos" with param "id"="42" -> "/users/42/repos"
static void retrofit_substitute_path(char *url, size_t url_size, const char *param_name, const char *param_value) {
    if (!url || !param_name || !param_value) return;
    char placeholder[128];
    snprintf(placeholder, sizeof(placeholder), "{%s}", param_name);
    char *pos = strstr(url, placeholder);
    if (!pos) return;
    size_t ph_len = strlen(placeholder);
    size_t val_len = strlen(param_value);
    size_t tail_len = strlen(pos + ph_len);
    if ((pos - url) + val_len + tail_len >= url_size - 1) return; // overflow check
    memmove(pos + val_len, pos + ph_len, tail_len + 1);
    memcpy(pos, param_value, val_len);
}

// Helper: append a query parameter to URL
static void retrofit_append_query(char *url, size_t url_size, const char *key, const char *value) {
    if (!url || !key || !value) return;
    size_t cur_len = strlen(url);
    char sep = strchr(url, '?') ? '&' : '?';
    size_t needed = cur_len + 1 + strlen(key) + 1 + strlen(value) + 1;
    if (needed >= url_size) return;
    char buf[512];
    snprintf(buf, sizeof(buf), "%c%s=%s", sep, key, value);
    strncat(url, buf, url_size - cur_len - 1);
}

// Helper: get string representation of a DxValue for request body/params
static const char *retrofit_value_to_string(DxVM *vm, DxValue val) {
    (void)vm;
    if (val.tag == DX_VAL_OBJ && val.obj) {
        const char *s = dx_vm_get_string_value(val.obj);
        if (s) return s;
        // Try toString
        DxMethod *ts = dx_vm_find_method(val.obj->klass, "toString", NULL);
        if (ts) {
            DxValue ts_args[1] = { val };
            DxValue ts_result = {0};
            if (dx_vm_execute_method(vm, ts, ts_args, 1, &ts_result) == DX_OK &&
                ts_result.tag == DX_VAL_OBJ && ts_result.obj) {
                return dx_vm_get_string_value(ts_result.obj);
            }
        }
        return "{}"; // fallback for body objects
    }
    return NULL;
}

// Retrofit proxy dispatch: called when a method is invoked on the retrofit proxy
// The proxy stores: field[0] = base URL string, field[1] = interface DxClass*
// frame->method = the DxMethod that was called (has annotations from the interface)
static DxResult native_retrofit_proxy_dispatch(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *proxy = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!proxy || !proxy->fields || !proxy->klass) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Get base URL from proxy field[0]
    const char *base_url = "";
    if (proxy->fields[0].tag == DX_VAL_OBJ && proxy->fields[0].obj) {
        const char *s = dx_vm_get_string_value(proxy->fields[0].obj);
        if (s) base_url = s;
    }

    // Get the called method (stored in frame->method by the dispatch mechanism)
    DxMethod *called_method = frame->method;
    if (!called_method) {
        dx_log_msg(DX_LOG_WARN, "Retrofit", "Proxy dispatch: no method info");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Check for HTTP annotation
    const char *path = NULL;
    const char *http_method = retrofit_get_http_annotation(called_method, &path);
    if (!http_method) {
        // No HTTP annotation — could be toString, hashCode, etc.
        // Return null for unknown methods
        dx_log_msg(DX_LOG_DEBUG, "Retrofit", "No HTTP annotation on method, returning null");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Build full URL: base_url + path
    char full_url[2048];
    // Remove trailing slash from base URL if path starts with /
    size_t base_len = strlen(base_url);
    if (base_len > 0 && base_url[base_len - 1] == '/' && path && path[0] == '/') {
        snprintf(full_url, sizeof(full_url), "%.*s%s", (int)(base_len - 1), base_url, path);
    } else if (path && path[0] != '/' && base_len > 0 && base_url[base_len - 1] != '/') {
        snprintf(full_url, sizeof(full_url), "%s/%s", base_url, path);
    } else {
        snprintf(full_url, sizeof(full_url), "%s%s", base_url, path ? path : "");
    }

    // Process parameter annotations: @Path, @Query, @Body, @Header
    const char *body_str = NULL;
    const char *h_names[DX_NET_MAX_HEADERS];
    const char *h_values[DX_NET_MAX_HEADERS];
    int h_count = 0;

    // Parameters start at args[1] (args[0] is 'this' proxy)
    for (uint32_t pi = 1; pi < arg_count && called_method->annotations; pi++) {
        uint32_t param_idx = pi - 1; // 0-based parameter index
        // Check each annotation on the method for parameter annotations
        // Parameter annotations are stored differently — scan all annotations
        for (uint32_t ai = 0; ai < called_method->annotation_count; ai++) {
            DxAnnotationEntry *ann = &called_method->annotations[ai];
            if (!ann->type) continue;

            // @Path("name") — check if this annotation targets this parameter
            // In DEX, parameter annotations are separate, but for framework methods
            // we check by naming convention. For real DEX methods, parameter annotations
            // are indexed. We use a heuristic: annotation order maps to param order.
            if (strcmp(ann->type, "Lretrofit2/http/Path;") == 0) {
                // Match annotation to parameter by index within Path annotations
                static uint32_t path_idx_counter;
                if (pi == 1) path_idx_counter = 0;
                const char *param_name = dx_annotation_get_string(ann, "value");
                if (param_name && path_idx_counter == param_idx) {
                    const char *val = retrofit_value_to_string(vm, args[pi]);
                    if (val) retrofit_substitute_path(full_url, sizeof(full_url), param_name, val);
                }
                path_idx_counter++;
            }
            if (strcmp(ann->type, "Lretrofit2/http/Query;") == 0) {
                static uint32_t query_idx_counter;
                if (pi == 1) query_idx_counter = 0;
                const char *key = dx_annotation_get_string(ann, "value");
                if (key && query_idx_counter == param_idx) {
                    const char *val = retrofit_value_to_string(vm, args[pi]);
                    if (val) retrofit_append_query(full_url, sizeof(full_url), key, val);
                }
                query_idx_counter++;
            }
            if (strcmp(ann->type, "Lretrofit2/http/Body;") == 0) {
                body_str = retrofit_value_to_string(vm, args[pi]);
            }
            if (strcmp(ann->type, "Lretrofit2/http/Header;") == 0) {
                static uint32_t header_idx_counter;
                if (pi == 1) header_idx_counter = 0;
                const char *hdr_name = dx_annotation_get_string(ann, "value");
                if (hdr_name && header_idx_counter == param_idx && h_count < DX_NET_MAX_HEADERS) {
                    const char *val = retrofit_value_to_string(vm, args[pi]);
                    if (val) {
                        h_names[h_count] = hdr_name;
                        h_values[h_count] = val;
                        h_count++;
                    }
                }
                header_idx_counter++;
            }
        }
    }

    dx_log(DX_LOG_INFO, "Retrofit", "HTTP %s %s", http_method, full_url);

    // Build network request
    DxNetworkRequest req = {
        .url = full_url,
        .method = http_method,
        .header_names = h_names,
        .header_values = h_values,
        .header_count = h_count,
        .body = body_str ? (const uint8_t *)body_str : NULL,
        .body_size = body_str ? strlen(body_str) : 0,
    };
    DxNetworkResponse net_resp;
    memset(&net_resp, 0, sizeof(net_resp));

    bool ok = dx_runtime_perform_network_request(&req, &net_resp);
    int status = ok ? net_resp.status_code : 0;

    // Create response body string
    DxObject *body_string = NULL;
    if (ok && net_resp.body && net_resp.body_size > 0) {
        char *body_buf = (char *)dx_malloc(net_resp.body_size + 1);
        if (body_buf) {
            memcpy(body_buf, net_resp.body, net_resp.body_size);
            body_buf[net_resp.body_size] = '\0';
            body_string = dx_vm_create_string(vm, body_buf);
            dx_free(body_buf);
        }
    } else {
        body_string = dx_vm_create_string(vm, "{}");
    }

    dx_log(DX_LOG_INFO, "Retrofit", "Response: %d (%zu bytes)", status, ok ? net_resp.body_size : 0);

    // Create retrofit2/Response object
    DxClass *resp_cls = dx_vm_find_class(vm, "Lretrofit2/Response;");
    DxObject *response = resp_cls ? dx_vm_alloc_object(vm, resp_cls) : NULL;
    if (response && response->fields && response->klass) {
        // Response fields: [0]=status code, [1]=body object (the deserialized body), [2]=raw body string
        if (response->klass->instance_field_count >= 1)
            response->fields[0] = DX_INT_VALUE(status);
        if (response->klass->instance_field_count >= 2)
            response->fields[1] = body_string ? DX_OBJ_VALUE(body_string) : DX_NULL_VALUE;
        if (response->klass->instance_field_count >= 3)
            response->fields[2] = body_string ? DX_OBJ_VALUE(body_string) : DX_NULL_VALUE;
    }

    if (ok) dx_network_response_free(&net_resp);

    // Determine return type: if method returns Call<T>, wrap in Call; otherwise return Response
    // Check shorty — 'L' return means object. We wrap in Call by default.
    DxClass *call_cls = dx_vm_find_class(vm, "Lretrofit2/Call;");
    DxObject *call = call_cls ? dx_vm_alloc_object(vm, call_cls) : NULL;
    if (call && call->fields && call->klass) {
        // Call fields: [0]=Response (pre-executed), [1]=Request info
        if (call->klass->instance_field_count >= 1)
            call->fields[0] = response ? DX_OBJ_VALUE(response) : DX_NULL_VALUE;
    }

    // Return Call object (wrapping the already-executed response)
    frame->result = call ? DX_OBJ_VALUE(call) : (response ? DX_OBJ_VALUE(response) : DX_NULL_VALUE);
    frame->has_result = true;
    return DX_OK;
}

// Retrofit Call.execute() for retrofit-created calls (returns pre-fetched Response)
static DxResult native_retrofit_call_execute(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1) {
        // field[0] = pre-fetched Response
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Retrofit Call.enqueue(Callback) for retrofit-created calls
static DxResult native_retrofit_call_enqueue(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *callback = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 && callback) {
        // Get pre-fetched response from field[0]
        DxValue resp_val = self->fields[0];
        if (callback->klass) {
            DxMethod *on_resp = dx_vm_find_method(callback->klass, "onResponse", "VLL");
            if (on_resp) {
                DxValue cb_args[3] = { DX_OBJ_VALUE(callback), DX_OBJ_VALUE(self), resp_val };
                DxValue cb_result = {0};
                dx_vm_execute_method(vm, on_resp, cb_args, 3, &cb_result);
            }
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Retrofit Response.body() -> returns deserialized body (stored in field[1])
static DxResult native_retrofit_response_body(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2) {
        frame->result = self->fields[1];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Retrofit Response.code() -> returns status code (stored in field[0])
static DxResult native_retrofit_response_code(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 &&
        self->fields[0].tag == DX_VAL_INT) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_INT_VALUE(200);
    }
    frame->has_result = true;
    return DX_OK;
}

// Retrofit Response.isSuccessful() -> status code in 200-299 range
static DxResult native_retrofit_response_is_successful(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int code = 200;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 &&
        self->fields[0].tag == DX_VAL_INT) {
        code = self->fields[0].i;
    }
    frame->result = DX_INT_VALUE((code >= 200 && code < 300) ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// Retrofit Response.errorBody() -> returns raw body string on error, null on success
static DxResult native_retrofit_response_errorbody(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int code = 200;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1 &&
        self->fields[0].tag == DX_VAL_INT) {
        code = self->fields[0].i;
    }
    if (code < 200 || code >= 300) {
        // Error — return body string as ResponseBody
        if (self && self->fields && self->klass && self->klass->instance_field_count >= 3) {
            frame->result = self->fields[2]; // raw body string
        } else {
            frame->result = DX_NULL_VALUE;
        }
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Retrofit Response.raw() -> return an OkHttp Response-like wrapper
static DxResult native_retrofit_response_raw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *okhttp_resp_cls = dx_vm_find_class(vm, "Lokhttp3/Response;");
    DxObject *raw = okhttp_resp_cls ? dx_vm_alloc_object(vm, okhttp_resp_cls) : NULL;
    if (raw && raw->fields && raw->klass && self && self->fields && self->klass) {
        if (raw->klass->instance_field_count >= 1 && self->klass->instance_field_count >= 1)
            raw->fields[0] = self->fields[0]; // status code
    }
    frame->result = raw ? DX_OBJ_VALUE(raw) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Retrofit.create(Class) -> creates a dynamic proxy that dispatches HTTP calls
static DxResult native_retrofit_create(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *iface_class_obj = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self || !self->fields || !self->klass) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Get base URL from Retrofit field[0]
    const char *base_url = "";
    if (self->klass->instance_field_count >= 1 &&
        self->fields[0].tag == DX_VAL_OBJ && self->fields[0].obj) {
        const char *s = dx_vm_get_string_value(self->fields[0].obj);
        if (s) base_url = s;
    }

    // Extract the interface DxClass from the Class object
    DxClass *iface = NULL;
    if (iface_class_obj) {
        // Try field[0] as pointer (Class object pattern)
        if (iface_class_obj->fields && iface_class_obj->klass &&
            iface_class_obj->klass->instance_field_count > 0 &&
            iface_class_obj->fields[0].tag == DX_VAL_INT && iface_class_obj->fields[0].i != 0) {
            iface = (DxClass *)(uintptr_t)iface_class_obj->fields[0].i;
        }
        if (!iface) {
            // Maybe the object itself is the class wrapper
            iface = iface_class_obj->klass;
        }
    }

    if (!iface) {
        dx_log_msg(DX_LOG_WARN, "Retrofit", "create(): could not resolve interface class");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    dx_log(DX_LOG_INFO, "Retrofit", "create() for interface: %s, baseUrl: %s",
           iface->descriptor ? iface->descriptor : "?", base_url);

    // Create a dynamic proxy class for this interface
    char proxy_desc[128];
    static int retrofit_proxy_counter = 0;
    snprintf(proxy_desc, sizeof(proxy_desc), "L$RetrofitProxy%d;", retrofit_proxy_counter++);

    DxClass *proxy_cls = (DxClass *)dx_malloc(sizeof(DxClass));
    if (!proxy_cls) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    memset(proxy_cls, 0, sizeof(DxClass));
    proxy_cls->descriptor = dx_strdup(proxy_desc);
    proxy_cls->super_class = vm->class_object;
    proxy_cls->status = DX_CLASS_INITIALIZED;
    proxy_cls->is_framework = true;
    proxy_cls->instance_field_count = 2; // [0]=base URL, [1]=interface class ptr

    // Set interface
    proxy_cls->interface_count = 1;
    proxy_cls->interfaces = (const char **)dx_malloc(sizeof(char *));
    if (proxy_cls->interfaces)
        proxy_cls->interfaces[0] = iface->descriptor;

    // Copy all virtual methods from the interface, wiring them to our dispatch
    for (uint32_t mi = 0; mi < iface->virtual_method_count; mi++) {
        DxMethod *im = &iface->virtual_methods[mi];
        uint32_t idx = proxy_cls->virtual_method_count;
        DxMethod *new_methods = (DxMethod *)dx_realloc(proxy_cls->virtual_methods,
            sizeof(DxMethod) * (idx + 1));
        if (!new_methods) continue;
        memset(&new_methods[idx], 0, sizeof(DxMethod));
        new_methods[idx].name = im->name;
        new_methods[idx].shorty = im->shorty;
        new_methods[idx].declaring_class = proxy_cls;
        new_methods[idx].access_flags = DX_ACC_PUBLIC;
        new_methods[idx].native_fn = native_retrofit_proxy_dispatch;
        new_methods[idx].is_native = true;
        new_methods[idx].vtable_idx = (int32_t)idx;
        // Copy annotations from the interface method so we can read @GET/@POST etc.
        new_methods[idx].annotations = im->annotations;
        new_methods[idx].annotation_count = im->annotation_count;
        proxy_cls->virtual_methods = new_methods;
        proxy_cls->virtual_method_count = idx + 1;
    }

    // Also copy direct methods (static methods on the interface)
    for (uint32_t mi = 0; mi < iface->direct_method_count; mi++) {
        DxMethod *im = &iface->direct_methods[mi];
        // Skip <init> and <clinit>
        if (im->name && (strcmp(im->name, "<init>") == 0 || strcmp(im->name, "<clinit>") == 0))
            continue;
        uint32_t idx = proxy_cls->virtual_method_count;
        DxMethod *new_methods = (DxMethod *)dx_realloc(proxy_cls->virtual_methods,
            sizeof(DxMethod) * (idx + 1));
        if (!new_methods) continue;
        memset(&new_methods[idx], 0, sizeof(DxMethod));
        new_methods[idx].name = im->name;
        new_methods[idx].shorty = im->shorty;
        new_methods[idx].declaring_class = proxy_cls;
        new_methods[idx].access_flags = DX_ACC_PUBLIC;
        new_methods[idx].native_fn = native_retrofit_proxy_dispatch;
        new_methods[idx].is_native = true;
        new_methods[idx].vtable_idx = (int32_t)idx;
        new_methods[idx].annotations = im->annotations;
        new_methods[idx].annotation_count = im->annotation_count;
        proxy_cls->virtual_methods = new_methods;
        proxy_cls->virtual_method_count = idx + 1;
    }

    // Register proxy class in VM
    if (vm->class_count < DX_MAX_CLASSES) {
        vm->classes[vm->class_count++] = proxy_cls;
        dx_vm_class_hash_insert(vm, proxy_cls);
    }

    // Allocate the proxy object
    DxObject *proxy = dx_vm_alloc_object(vm, proxy_cls);
    if (proxy && proxy->fields) {
        // Store base URL in field[0]
        DxObject *url_str = dx_vm_create_string(vm, base_url);
        proxy->fields[0] = url_str ? DX_OBJ_VALUE(url_str) : DX_NULL_VALUE;
        // Store interface class pointer in field[1] for debugging
        proxy->fields[1].tag = DX_VAL_INT;
        proxy->fields[1].i = (int32_t)(uintptr_t)iface;
    }

    frame->result = proxy ? DX_OBJ_VALUE(proxy) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Retrofit.baseUrl() -> returns base URL string
static DxResult native_retrofit_baseurl(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 1) {
        frame->result = self->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Retrofit Response.success(T body) -> creates a successful Response wrapping body
static DxResult native_retrofit_response_success(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxClass *resp_cls = dx_vm_find_class(vm, "Lretrofit2/Response;");
    DxObject *response = resp_cls ? dx_vm_alloc_object(vm, resp_cls) : NULL;
    if (response && response->fields && response->klass) {
        if (response->klass->instance_field_count >= 1)
            response->fields[0] = DX_INT_VALUE(200);
        if (response->klass->instance_field_count >= 2 && arg_count > 0)
            response->fields[1] = args[0]; // body
    }
    frame->result = response ? DX_OBJ_VALUE(response) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Retrofit Response.error(int code, ResponseBody body) -> error response
static DxResult native_retrofit_response_error(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxClass *resp_cls = dx_vm_find_class(vm, "Lretrofit2/Response;");
    DxObject *response = resp_cls ? dx_vm_alloc_object(vm, resp_cls) : NULL;
    if (response && response->fields && response->klass) {
        if (response->klass->instance_field_count >= 1 && arg_count > 0)
            response->fields[0] = args[0]; // code
        if (response->klass->instance_field_count >= 2 && arg_count > 1)
            response->fields[1] = args[1]; // error body
    }
    frame->result = response ? DX_OBJ_VALUE(response) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// java.net.Socket — POSIX TCP socket support
// ============================================================
// Socket field layout:
//   field[0].i = socket fd (or -1 if invalid)
//   field[1].i = connected flag (0/1)
//   field[2].i = closed flag (0/1)

// Socket(String host, int port)
static DxResult native_socket_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 3) {
        return DX_OK;
    }

    // Default to invalid state
    self->fields[0] = DX_INT_VALUE(-1);
    self->fields[1] = DX_INT_VALUE(0);
    self->fields[2] = DX_INT_VALUE(0);

    if (arg_count < 3) return DX_OK;

    const char *host = NULL;
    if (args[1].tag == DX_VAL_OBJ && args[1].obj) {
        host = dx_vm_get_string_value(args[1].obj);
    }
    int port = (args[2].tag == DX_VAL_INT) ? args[2].i : 0;

    if (!host || port <= 0 || port > 65535) {
        DX_WARN("Socket", "Invalid host/port: %s:%d", host ? host : "null", port);
        return DX_OK;
    }

    DX_INFO("Socket", "Connecting to %s:%d", host, port);

    // Resolve host
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%d", port);

    int gai = getaddrinfo(host, port_str, &hints, &res);
    if (gai != 0 || !res) {
        DX_WARN("Socket", "DNS resolution failed for %s: %s", host, gai_strerror(gai));
        if (res) freeaddrinfo(res);
        return DX_OK;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        DX_WARN("Socket", "socket() failed: %s", strerror(errno));
        freeaddrinfo(res);
        return DX_OK;
    }

    if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        DX_WARN("Socket", "connect() failed: %s", strerror(errno));
        close(fd);
        freeaddrinfo(res);
        return DX_OK;
    }

    freeaddrinfo(res);

    DX_INFO("Socket", "Connected to %s:%d (fd=%d)", host, port, fd);
    self->fields[0] = DX_INT_VALUE(fd);
    self->fields[1] = DX_INT_VALUE(1); // connected
    self->fields[2] = DX_INT_VALUE(0); // not closed
    return DX_OK;
}

// Socket.close()
static DxResult native_socket_close(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 3) return DX_OK;

    int fd = self->fields[0].i;
    if (fd >= 0) {
        close(fd);
        DX_DEBUG("Socket", "Closed fd=%d", fd);
    }
    self->fields[0] = DX_INT_VALUE(-1);
    self->fields[1] = DX_INT_VALUE(0);
    self->fields[2] = DX_INT_VALUE(1); // closed
    return DX_OK;
}

// Socket.isConnected()
static DxResult native_socket_is_connected(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int connected = 0;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 2) {
        connected = self->fields[1].i;
    }
    frame->result = DX_INT_VALUE(connected);
    frame->has_result = true;
    return DX_OK;
}

// Socket.isClosed()
static DxResult native_socket_is_closed(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int closed = 1;
    if (self && self->fields && self->klass && self->klass->instance_field_count >= 3) {
        closed = self->fields[2].i;
    }
    frame->result = DX_INT_VALUE(closed);
    frame->has_result = true;
    return DX_OK;
}

// Socket.getInputStream() -> SocketInputStream (stores socket obj in field[0])
static DxResult native_socket_get_input_stream(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *sis_cls = dx_vm_find_class(vm, "Ljava/net/SocketInputStream;");
    if (!sis_cls || !self) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *sis = dx_vm_alloc_object(vm, sis_cls);
    if (sis && sis->fields && sis->klass && sis->klass->instance_field_count >= 1) {
        sis->fields[0] = DX_OBJ_VALUE(self); // reference to the socket
    }
    frame->result = sis ? DX_OBJ_VALUE(sis) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Socket.getOutputStream() -> SocketOutputStream (stores socket obj in field[0])
static DxResult native_socket_get_output_stream(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *sos_cls = dx_vm_find_class(vm, "Ljava/net/SocketOutputStream;");
    if (!sos_cls || !self) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *sos = dx_vm_alloc_object(vm, sos_cls);
    if (sos && sos->fields && sos->klass && sos->klass->instance_field_count >= 1) {
        sos->fields[0] = DX_OBJ_VALUE(self); // reference to the socket
    }
    frame->result = sos ? DX_OBJ_VALUE(sos) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// SocketInputStream.read(byte[] b) -> int (bytes read, or -1 on EOF/error)
static DxResult native_socket_input_read(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0] = this (SocketInputStream), args[1] = byte[] buffer
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *buf = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 1) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    // Get the Socket object from field[0]
    DxObject *sock = (self->fields[0].tag == DX_VAL_OBJ) ? self->fields[0].obj : NULL;
    if (!sock || !sock->fields || !sock->klass || sock->klass->instance_field_count < 1) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    int fd = sock->fields[0].i;
    if (fd < 0) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    if (!buf || !buf->is_array || buf->array_length == 0 || !buf->array_elements) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    // Read into a temp buffer, then copy to the DxValue array
    uint32_t len = buf->array_length;
    if (len > 65536) len = 65536; // cap per-read
    uint8_t *tmp = (uint8_t *)malloc(len);
    if (!tmp) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    ssize_t n = read(fd, tmp, len);
    if (n <= 0) {
        free(tmp);
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }

    for (ssize_t i = 0; i < n; i++) {
        buf->array_elements[i] = DX_INT_VALUE((int32_t)(tmp[i] & 0xFF));
    }
    free(tmp);

    DX_DEBUG("Socket", "read %zd bytes from fd=%d", n, fd);
    frame->result = DX_INT_VALUE((int32_t)n);
    frame->has_result = true;
    return DX_OK;
}

// SocketOutputStream.write(byte[] b) -> void
static DxResult native_socket_output_write(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    // args[0] = this (SocketOutputStream), args[1] = byte[] buffer
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *buf = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 1) return DX_OK;

    DxObject *sock = (self->fields[0].tag == DX_VAL_OBJ) ? self->fields[0].obj : NULL;
    if (!sock || !sock->fields || !sock->klass || sock->klass->instance_field_count < 1) return DX_OK;

    int fd = sock->fields[0].i;
    if (fd < 0) return DX_OK;

    if (!buf || !buf->is_array || buf->array_length == 0 || !buf->array_elements) return DX_OK;

    uint32_t len = buf->array_length;
    if (len > 65536) len = 65536;
    uint8_t *tmp = (uint8_t *)malloc(len);
    if (!tmp) return DX_OK;

    for (uint32_t i = 0; i < len; i++) {
        tmp[i] = (uint8_t)(buf->array_elements[i].i & 0xFF);
    }

    ssize_t n = write(fd, tmp, len);
    free(tmp);

    DX_DEBUG("Socket", "wrote %zd bytes to fd=%d", n, fd);
    return DX_OK;
}

// ============================================================
// java.net.ServerSocket — POSIX TCP server socket support
// ============================================================
// ServerSocket field layout:
//   field[0].i = server socket fd (or -1)
//   field[1].i = closed flag (0/1)

// ServerSocket(int port)
static DxResult native_server_socket_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 2) return DX_OK;

    self->fields[0] = DX_INT_VALUE(-1);
    self->fields[1] = DX_INT_VALUE(0);

    int port = (arg_count > 1 && args[1].tag == DX_VAL_INT) ? args[1].i : 0;
    if (port <= 0 || port > 65535) {
        DX_WARN("ServerSocket", "Invalid port: %d", port);
        return DX_OK;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        DX_WARN("ServerSocket", "socket() failed: %s", strerror(errno));
        return DX_OK;
    }

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        DX_WARN("ServerSocket", "bind() failed on port %d: %s", port, strerror(errno));
        close(fd);
        return DX_OK;
    }

    if (listen(fd, 16) < 0) {
        DX_WARN("ServerSocket", "listen() failed: %s", strerror(errno));
        close(fd);
        return DX_OK;
    }

    DX_INFO("ServerSocket", "Listening on port %d (fd=%d)", port, fd);
    self->fields[0] = DX_INT_VALUE(fd);
    self->fields[1] = DX_INT_VALUE(0);
    return DX_OK;
}

// ServerSocket.accept() -> Socket
static DxResult native_server_socket_accept(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 1) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    int server_fd = self->fields[0].i;
    if (server_fd < 0) {
        DX_WARN("ServerSocket", "accept() on invalid fd");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    struct sockaddr_in client_addr;
    socklen_t addr_len = sizeof(client_addr);
    int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &addr_len);
    if (client_fd < 0) {
        DX_WARN("ServerSocket", "accept() failed: %s", strerror(errno));
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DX_INFO("ServerSocket", "Accepted client (fd=%d)", client_fd);

    // Create a new Socket wrapping the client fd
    DxClass *sock_cls = dx_vm_find_class(vm, "Ljava/net/Socket;");
    if (!sock_cls) {
        close(client_fd);
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *client_sock = dx_vm_alloc_object(vm, sock_cls);
    if (client_sock && client_sock->fields && client_sock->klass
        && client_sock->klass->instance_field_count >= 3) {
        client_sock->fields[0] = DX_INT_VALUE(client_fd);
        client_sock->fields[1] = DX_INT_VALUE(1); // connected
        client_sock->fields[2] = DX_INT_VALUE(0); // not closed
    } else {
        close(client_fd);
    }

    frame->result = client_sock ? DX_OBJ_VALUE(client_sock) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ServerSocket.close()
static DxResult native_server_socket_close(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields || !self->klass || self->klass->instance_field_count < 2) return DX_OK;

    int fd = self->fields[0].i;
    if (fd >= 0) {
        close(fd);
        DX_DEBUG("ServerSocket", "Closed fd=%d", fd);
    }
    self->fields[0] = DX_INT_VALUE(-1);
    self->fields[1] = DX_INT_VALUE(1); // closed
    return DX_OK;
}

// ============================================================
// File sandboxing wrappers for java.io.File
// ============================================================

// Sandboxed File.<init>(String) — rejects disallowed paths
static DxResult native_file_init_string_sandboxed(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self) return DX_OK;

    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        const char *path = dx_vm_get_string_value(args[1].obj);
        if (path && !dx_runtime_check_file_path(path)) {
            DX_WARN("File", "Sandbox blocked path: %s", path);
            // Store empty path instead
            DxObject *empty = dx_vm_create_string(vm, "");
            if (self->fields && self->klass && self->klass->instance_field_count > 0 && empty) {
                self->fields[0] = DX_OBJ_VALUE(empty);
            }
            return DX_OK;
        }
        DX_DEBUG("File", "<init>(\"%s\")", path ? path : "null");
        if (self->fields && self->klass && self->klass->instance_field_count > 0) {
            self->fields[0] = args[1];
        }
    }
    return DX_OK;
}

DxResult dx_register_android_framework(DxVM *vm) {
    if (!vm) return DX_ERR_NULL_PTR;

    DxClass *obj = vm->class_object;

    // android.content.Context
    DxClass *context_cls = reg_class(vm, "Landroid/content/Context;", obj);
    vm->class_context = context_cls;
    add_method(context_cls, "getSystemService", "LL", DX_ACC_PUBLIC,
               native_get_system_service, false);
    add_method(context_cls, "getPackageManager", "L", DX_ACC_PUBLIC,
               native_get_package_manager, false);
    add_method(context_cls, "getApplicationContext", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(context_cls, "getResources", "L", DX_ACC_PUBLIC,
               native_context_get_resources, false);
    add_method(context_cls, "getPackageName", "L", DX_ACC_PUBLIC,
               native_context_get_package_name, false);
    add_method(context_cls, "getString", "LI", DX_ACC_PUBLIC,
               native_context_get_string, false);
    add_method(context_cls, "getFilesDir", "L", DX_ACC_PUBLIC,
               native_context_get_files_dir, false);
    add_method(context_cls, "getCacheDir", "L", DX_ACC_PUBLIC,
               native_context_get_cache_dir, false);
    add_method(context_cls, "getSharedPreferences", "LLI", DX_ACC_PUBLIC,
               native_context_get_shared_prefs, false);
    add_method(context_cls, "startActivity", "VL", DX_ACC_PUBLIC,
               native_start_activity, false);
    add_method(context_cls, "startService", "LL", DX_ACC_PUBLIC,
               native_context_start_service, false);
    add_method(context_cls, "stopService", "ZL", DX_ACC_PUBLIC,
               native_context_stop_service, false);
    add_method(context_cls, "sendBroadcast", "VL", DX_ACC_PUBLIC,
               native_context_send_broadcast, false);
    add_method(context_cls, "registerReceiver", "LLL", DX_ACC_PUBLIC,
               native_context_register_receiver, false);
    add_method(context_cls, "unregisterReceiver", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(context_cls, "getContentResolver", "L", DX_ACC_PUBLIC,
               native_context_get_content_resolver, false);
    add_method(context_cls, "getAssets", "L", DX_ACC_PUBLIC,
               native_context_get_assets, false);
    add_method(context_cls, "openFileInput", "LL", DX_ACC_PUBLIC,
               native_context_open_file_input, false);
    add_method(context_cls, "openFileOutput", "LLI", DX_ACC_PUBLIC,
               native_context_open_file_output, false);
    add_method(context_cls, "getTheme", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(context_cls, "obtainStyledAttributes", "LLI", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(context_cls, "getClassLoader", "L", DX_ACC_PUBLIC,
               native_context_get_class_loader, false);
    add_method(context_cls, "getExternalFilesDir", "LL", DX_ACC_PUBLIC,
               native_context_get_external_files_dir, false);
    add_method(context_cls, "getApplicationInfo", "L", DX_ACC_PUBLIC,
               native_context_get_app_info, false);
    add_method(context_cls, "bindService", "ZLLI", DX_ACC_PUBLIC,
               native_context_bind_service, false);
    add_method(context_cls, "checkSelfPermission", "IL", DX_ACC_PUBLIC,
               native_check_self_permission, false);

    // android.app.Activity (extends Context)
    DxClass *activity_cls = reg_class(vm, "Landroid/app/Activity;", context_cls);
    vm->class_activity = activity_cls;
    add_method(activity_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_activity_init, true);
    add_method(activity_cls, "setContentView", "VI", DX_ACC_PUBLIC,
               native_activity_set_content_view, false);
    add_method(activity_cls, "findViewById", "LI", DX_ACC_PUBLIC,
               native_activity_find_view_by_id, false);
    add_method(activity_cls, "onCreate", "VL", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(activity_cls, "getWindow", "L", DX_ACC_PUBLIC,
               native_get_window, false);
    add_method(activity_cls, "getIntent", "L", DX_ACC_PUBLIC,
               native_activity_get_intent, false);
    add_method(activity_cls, "finish", "V", DX_ACC_PUBLIC,
               native_activity_finish, false);
    add_method(activity_cls, "runOnUiThread", "VL", DX_ACC_PUBLIC,
               native_activity_run_on_ui_thread, false);
    add_method(activity_cls, "setTitle", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "setIntent", "VL", DX_ACC_PUBLIC,
               native_activity_set_intent, false);
    add_method(activity_cls, "registerForActivityResult", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(activity_cls, "getLifecycle", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(activity_cls, "onDestroy", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(activity_cls, "onResume", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(activity_cls, "onPause", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(activity_cls, "onStop", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(activity_cls, "onStart", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(activity_cls, "onRestart", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(activity_cls, "onActivityResult", "VIIL", DX_ACC_PROTECTED,
               native_activity_on_activity_result, false);
    add_method(activity_cls, "getSupportActionBar", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(activity_cls, "isTaskRoot", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(activity_cls, "getApplication", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(activity_cls, "isFinishing", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(activity_cls, "isDestroyed", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(activity_cls, "onPostResume", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(activity_cls, "onPostCreate", "VL", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(activity_cls, "onPanelClosed", "VIL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "onKeyDown", "ZIL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(activity_cls, "onKeyUp", "ZIL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(activity_cls, "onRequestPermissionsResult", "VILL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "requestPermissions", "VLI", DX_ACC_PUBLIC,
               native_activity_request_permissions, false);
    add_method(activity_cls, "onSaveInstanceState", "VL", DX_ACC_PROTECTED,
               native_activity_on_save_instance_state, false);
    add_method(activity_cls, "onRestoreInstanceState", "VL", DX_ACC_PROTECTED,
               native_activity_on_restore_instance_state, false);
    add_method(activity_cls, "onConfigurationChanged", "VL", DX_ACC_PUBLIC,
               native_activity_on_config_changed, false);
    add_method(activity_cls, "recreate", "V", DX_ACC_PUBLIC,
               native_activity_recreate, false);

    // android.view.View
    DxClass *view_cls = reg_class(vm, "Landroid/view/View;", obj);
    vm->class_view = view_cls;
    add_method(view_cls, "setOnClickListener", "VL", DX_ACC_PUBLIC,
               native_view_set_on_click_listener, false);
    add_method(view_cls, "findViewById", "LI", DX_ACC_PUBLIC,
               native_view_find_view_by_id, false);
    add_method(view_cls, "setVisibility", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setEnabled", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setClickable", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setClipChildren", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setClipToPadding", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "getContext", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(view_cls, "getParent", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(view_cls, "setLayoutParams", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setPadding", "VIIII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setBackgroundColor", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setTag", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "getTag", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(view_cls, "invalidate", "V", DX_ACC_PUBLIC,
               native_view_invalidate, false);
    add_method(view_cls, "requestLayout", "V", DX_ACC_PUBLIC,
               native_view_invalidate, false);

    // android.widget.TextView (extends View)
    DxClass *textview_cls = reg_class(vm, "Landroid/widget/TextView;", view_cls);
    vm->class_textview = textview_cls;
    add_method(textview_cls, "setText", "VL", DX_ACC_PUBLIC,
               native_textview_set_text, false);
    add_method(textview_cls, "getText", "L", DX_ACC_PUBLIC,
               native_textview_get_text, false);
    add_method(textview_cls, "setTextColor", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setTextSize", "VF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setGravity", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setHint", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // android.widget.Button (extends TextView)
    DxClass *button_cls = reg_class(vm, "Landroid/widget/Button;", textview_cls);
    vm->class_button = button_cls;

    // android.view.ViewGroup (extends View)
    DxClass *viewgroup_cls = reg_class(vm, "Landroid/view/ViewGroup;", view_cls);
    vm->class_viewgroup = viewgroup_cls;
    add_method(viewgroup_cls, "getChildAt", "LI", DX_ACC_PUBLIC,
               native_viewgroup_get_child_at, false);
    add_method(viewgroup_cls, "getChildCount", "I", DX_ACC_PUBLIC,
               native_viewgroup_get_child_count, false);
    add_method(viewgroup_cls, "addView", "VL", DX_ACC_PUBLIC,
               native_viewgroup_add_view, false);
    add_method(viewgroup_cls, "removeAllViews", "V", DX_ACC_PUBLIC,
               native_viewgroup_remove_all_views, false);

    // android.widget.LinearLayout (extends ViewGroup)
    DxClass *linearlayout_cls = reg_class(vm, "Landroid/widget/LinearLayout;", viewgroup_cls);
    vm->class_linearlayout = linearlayout_cls;

    // android.os.Bundle — field-backed key-value store
    DxClass *bundle_cls = reg_class(vm, "Landroid/os/Bundle;", obj);
    vm->class_bundle = bundle_cls;
    bundle_cls->instance_field_count = DX_BUNDLE_FIELD_COUNT;
    add_method(bundle_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    // String get/put
    add_method(bundle_cls, "getString", "LL", DX_ACC_PUBLIC,
               native_bundle_get_string, false);
    add_method(bundle_cls, "getString", "LLL", DX_ACC_PUBLIC,
               native_bundle_get_string_default, false);
    add_method(bundle_cls, "putString", "VLL", DX_ACC_PUBLIC,
               native_bundle_put_string, false);
    // Int get/put
    add_method(bundle_cls, "getInt", "IL", DX_ACC_PUBLIC,
               native_bundle_get_int, false);
    add_method(bundle_cls, "getInt", "ILI", DX_ACC_PUBLIC,
               native_bundle_get_int, false);
    add_method(bundle_cls, "putInt", "VLI", DX_ACC_PUBLIC,
               native_bundle_put_int, false);
    // Long get/put
    add_method(bundle_cls, "getLong", "JL", DX_ACC_PUBLIC,
               native_bundle_get_long, false);
    add_method(bundle_cls, "putLong", "VLJ", DX_ACC_PUBLIC,
               native_bundle_put_long, false);
    // Float get/put
    add_method(bundle_cls, "getFloat", "FL", DX_ACC_PUBLIC,
               native_bundle_get_float, false);
    add_method(bundle_cls, "putFloat", "VLF", DX_ACC_PUBLIC,
               native_bundle_put_float, false);
    // Double get/put
    add_method(bundle_cls, "getDouble", "DL", DX_ACC_PUBLIC,
               native_bundle_get_double, false);
    add_method(bundle_cls, "putDouble", "VLD", DX_ACC_PUBLIC,
               native_bundle_put_double, false);
    // Boolean get/put
    add_method(bundle_cls, "getBoolean", "ZL", DX_ACC_PUBLIC,
               native_bundle_get_boolean, false);
    add_method(bundle_cls, "getBoolean", "ZLZ", DX_ACC_PUBLIC,
               native_bundle_get_boolean, false);
    add_method(bundle_cls, "putBoolean", "VLZ", DX_ACC_PUBLIC,
               native_bundle_put_boolean, false);
    // Parcelable/Serializable/Bundle get/put
    add_method(bundle_cls, "putParcelable", "VLL", DX_ACC_PUBLIC,
               native_bundle_put_object, false);
    add_method(bundle_cls, "getParcelable", "LL", DX_ACC_PUBLIC,
               native_bundle_get_object, false);
    add_method(bundle_cls, "putSerializable", "VLL", DX_ACC_PUBLIC,
               native_bundle_put_object, false);
    add_method(bundle_cls, "getSerializable", "LL", DX_ACC_PUBLIC,
               native_bundle_get_object, false);
    add_method(bundle_cls, "putBundle", "VLL", DX_ACC_PUBLIC,
               native_bundle_put_object, false);
    add_method(bundle_cls, "getBundle", "LL", DX_ACC_PUBLIC,
               native_bundle_get_object, false);
    // ArrayList get/put
    add_method(bundle_cls, "putStringArrayList", "VLL", DX_ACC_PUBLIC,
               native_bundle_put_object, false);
    add_method(bundle_cls, "getStringArrayList", "LL", DX_ACC_PUBLIC,
               native_bundle_get_object, false);
    add_method(bundle_cls, "putIntegerArrayList", "VLL", DX_ACC_PUBLIC,
               native_bundle_put_object, false);
    add_method(bundle_cls, "getIntegerArrayList", "LL", DX_ACC_PUBLIC,
               native_bundle_get_object, false);
    // Utility methods
    add_method(bundle_cls, "containsKey", "ZL", DX_ACC_PUBLIC,
               native_bundle_contains_key, false);
    add_method(bundle_cls, "keySet", "L", DX_ACC_PUBLIC,
               native_bundle_key_set, false);
    add_method(bundle_cls, "size", "I", DX_ACC_PUBLIC,
               native_bundle_size, false);
    add_method(bundle_cls, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_bundle_is_empty, false);
    add_method(bundle_cls, "remove", "VL", DX_ACC_PUBLIC,
               native_bundle_remove, false);
    add_method(bundle_cls, "clear", "V", DX_ACC_PUBLIC,
               native_bundle_clear, false);

    // android.content.res.Resources
    DxClass *res_cls = reg_class(vm, "Landroid/content/res/Resources;", obj);
    vm->class_resources = res_cls;

    // android.view.View$OnClickListener (interface)
    DxClass *onclick_cls = reg_class(vm, "Landroid/view/View$OnClickListener;", obj);
    onclick_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    vm->class_onclick = onclick_cls;

    // android.view.View$OnLongClickListener (interface)
    DxClass *onlongclick_cls = reg_class(vm, "Landroid/view/View$OnLongClickListener;", obj);
    onlongclick_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    // android.view.View$OnTouchListener (interface)
    DxClass *ontouch_cls = reg_class(vm, "Landroid/view/View$OnTouchListener;", obj);
    ontouch_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    // android.widget.EditText (extends TextView)
    DxClass *edittext_cls = reg_class(vm, "Landroid/widget/EditText;", textview_cls);
    vm->class_edittext = edittext_cls;
    add_method(edittext_cls, "addTextChangedListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(edittext_cls, "removeTextChangedListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(edittext_cls, "setInputType", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(edittext_cls, "setHint", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(edittext_cls, "getEditableText", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // android.widget.ImageView (extends View)
    DxClass *imageview_cls = reg_class(vm, "Landroid/widget/ImageView;", view_cls);
    vm->class_imageview = imageview_cls;

    // android.widget.Toast
    DxClass *toast_cls = reg_class(vm, "Landroid/widget/Toast;", obj);
    vm->class_toast = toast_cls;
    add_method(toast_cls, "makeText", "LLLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_toast_make_text, true);
    add_method(toast_cls, "show", "V", DX_ACC_PUBLIC,
               native_toast_show, false);

    // android.util.Log — forward to DexLoom logging system
    DxClass *log_cls = reg_class(vm, "Landroid/util/Log;", obj);
    vm->class_log = log_cls;
    add_method(log_cls, "d", "ILL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_log_debug, true);
    add_method(log_cls, "i", "ILL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_log_info, true);
    add_method(log_cls, "w", "ILL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_log_warn, true);
    add_method(log_cls, "e", "ILL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_log_error, true);
    add_method(log_cls, "v", "ILL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);

    // android.content.Intent
    DxClass *intent_cls = reg_class(vm, "Landroid/content/Intent;", obj);
    vm->class_intent = intent_cls;
    intent_cls->instance_field_count = DX_INTENT_FIELD_COUNT; // action + target + 16 extras (key-value pairs)
    add_method(intent_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(intent_cls, "getStringExtra", "LL", DX_ACC_PUBLIC,
               native_intent_get_string_extra, false);
    add_method(intent_cls, "putExtra", "LLL", DX_ACC_PUBLIC,
               native_intent_put_extra, false);
    add_method(intent_cls, "putExtra", "LLI", DX_ACC_PUBLIC,
               native_intent_put_extra_int, false);
    add_method(intent_cls, "putExtra", "LLZ", DX_ACC_PUBLIC,
               native_intent_put_extra_bool, false);
    add_method(intent_cls, "getAction", "L", DX_ACC_PUBLIC,
               native_intent_get_action, false);
    add_method(intent_cls, "getIntExtra", "ILI", DX_ACC_PUBLIC,
               native_intent_get_int_extra, false);
    add_method(intent_cls, "getBooleanExtra", "ZLZ", DX_ACC_PUBLIC,
               native_intent_get_boolean_extra, false);
    add_method(intent_cls, "getData", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(intent_cls, "getExtras", "L", DX_ACC_PUBLIC,
               native_intent_get_extras, false);
    add_method(intent_cls, "hasExtra", "ZL", DX_ACC_PUBLIC,
               native_intent_has_extra, false);

    // android.content.SharedPreferences (interface)
    DxClass *prefs_cls = reg_class(vm, "Landroid/content/SharedPreferences;", obj);
    prefs_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    vm->class_shared_prefs = prefs_cls;

    // android.view.LayoutInflater
    DxClass *inflater_cls = reg_class(vm, "Landroid/view/LayoutInflater;", obj);
    vm->class_inflater = inflater_cls;
    add_method(inflater_cls, "inflate", "LIL", DX_ACC_PUBLIC,
               native_inflater_inflate, false);
    add_method(inflater_cls, "inflate", "LILZ", DX_ACC_PUBLIC,
               native_inflater_inflate, false);
    add_method(inflater_cls, "from", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_inflater_from, true);

    // android.view.Window
    DxClass *window_cls = reg_class(vm, "Landroid/view/Window;", obj);
    add_method(window_cls, "getDecorView", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(window_cls, "setStatusBarColor", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "setNavigationBarColor", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "setFlags", "VII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "addFlags", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "clearFlags", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "findViewById", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(window_cls, "getAttributes", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(window_cls, "setAttributes", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "setSoftInputMode", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "setCallback", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "getCallback", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(window_cls, "requestFeature", "ZI", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(window_cls, "setContentView", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "setLayout", "VII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "setGravity", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(window_cls, "setBackgroundDrawableResource", "VI", DX_ACC_PUBLIC,
               native_noop, false);

    // android.content.pm.PackageManager
    DxClass *pm_cls = reg_class(vm, "Landroid/content/pm/PackageManager;", obj);
    add_method(pm_cls, "hasSystemFeature", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(pm_cls, "getPackageInfo", "LLI", DX_ACC_PUBLIC,
               native_return_null, false);
    {
        const char *pm_names[] = { "PERMISSION_GRANTED", "PERMISSION_DENIED" };
        DxValue pm_vals[] = { DX_INT_VALUE(0), DX_INT_VALUE(-1) };
        add_static_fields(pm_cls, pm_names, pm_vals, 2);
    }

    // android.net.Uri
    DxClass *uri_cls = reg_class(vm, "Landroid/net/Uri;", obj);
    uri_cls->instance_field_count = 1; // field[0] = stored URI string
    add_method(uri_cls, "parse", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_uri_parse, true);
    add_method(uri_cls, "toString", "L", DX_ACC_PUBLIC,
               native_uri_to_string, false);
    add_method(uri_cls, "getScheme", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(uri_cls, "getHost", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(uri_cls, "getPath", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(uri_cls, "getLastPathSegment", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(uri_cls, "getQuery", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(uri_cls, "getQueryParameter", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(uri_cls, "getFragment", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // android.media.RingtoneManager
    DxClass *rm_cls = reg_class(vm, "Landroid/media/RingtoneManager;", obj);
    add_method(rm_cls, "getDefaultUri", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_ringtone_manager_get_default_uri, true);

    // android.os.Handler
    DxClass *handler_cls = reg_class(vm, "Landroid/os/Handler;", obj);
    add_method(handler_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(handler_cls, "post", "ZL", DX_ACC_PUBLIC,
               native_handler_post, false);
    add_method(handler_cls, "postDelayed", "ZLJ", DX_ACC_PUBLIC,
               native_handler_post_delayed, false);

    // android.os.Looper
    DxClass *looper_cls = reg_class(vm, "Landroid/os/Looper;", obj);
    add_method(looper_cls, "getMainLooper", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_looper_get_main_looper, true);
    add_method(looper_cls, "myLooper", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_looper_my_looper, true);
    add_method(looper_cls, "prepare", "V", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(looper_cls, "loop", "V", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(looper_cls, "quit", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(looper_cls, "quitSafely", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(looper_cls, "isCurrentThread", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(looper_cls, "getThread", "L", DX_ACC_PUBLIC,
               native_looper_get_thread, false);

    // android.os.MessageQueue
    DxClass *msgqueue_cls = reg_class(vm, "Landroid/os/MessageQueue;", obj);
    add_method(msgqueue_cls, "addIdleHandler", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(msgqueue_cls, "removeIdleHandler", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // android.os.HandlerThread (extends Thread, provides Looper)
    DxClass *handler_thread_cls = reg_class(vm, "Landroid/os/HandlerThread;", obj);
    add_method(handler_thread_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(handler_thread_cls, "<init>", "VLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(handler_thread_cls, "start", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(handler_thread_cls, "getLooper", "L", DX_ACC_PUBLIC,
               native_looper_get_main_looper, false);
    add_method(handler_thread_cls, "quit", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(handler_thread_cls, "quitSafely", "Z", DX_ACC_PUBLIC, native_return_true, false);

    // --- AndroidX / AppCompat stubs ---

    // androidx.appcompat.app.AppCompatActivity (extends Activity)
    DxClass *appcompat_cls = reg_class(vm, "Landroidx/appcompat/app/AppCompatActivity;", activity_cls);
    vm->class_appcompat = appcompat_cls;
    add_method(appcompat_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_activity_init, true);
    add_method(appcompat_cls, "onCreate", "VL", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(appcompat_cls, "setContentView", "VI", DX_ACC_PUBLIC,
               native_activity_set_content_view, false);
    add_method(appcompat_cls, "findViewById", "LI", DX_ACC_PUBLIC,
               native_activity_find_view_by_id, false);

    // androidx.fragment.app.FragmentActivity (between AppCompat and Activity)
    DxClass *frag_act = reg_class(vm, "Landroidx/fragment/app/FragmentActivity;", activity_cls);
    add_method(frag_act, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_activity_init, true);

    // androidx.core.app.ComponentActivity
    DxClass *comp_act = reg_class(vm, "Landroidx/activity/ComponentActivity;", activity_cls);
    add_method(comp_act, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_activity_init, true);
    add_method(comp_act, "getWindow", "L", DX_ACC_PUBLIC,
               native_get_window, false);
    add_method(comp_act, "onDestroy", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(comp_act, "onResume", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(comp_act, "onPause", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(comp_act, "onStop", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(comp_act, "onStart", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(comp_act, "getSavedStateRegistry", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(comp_act, "addOnContextAvailableListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(comp_act, "getViewModelStore", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(comp_act, "getOnBackPressedDispatcher", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // androidx.fragment.app.Fragment
    DxClass *fragment_cls = reg_class(vm, "Landroidx/fragment/app/Fragment;", obj);
    add_method(fragment_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(fragment_cls, "getActivity", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(fragment_cls, "getContext", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(fragment_cls, "getView", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(fragment_cls, "getResources", "L", DX_ACC_PUBLIC,
               native_context_get_resources, false);
    add_method(fragment_cls, "getString", "LI", DX_ACC_PUBLIC,
               native_context_get_string, false);
    add_method(fragment_cls, "getArguments", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(fragment_cls, "setArguments", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(fragment_cls, "requireContext", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(fragment_cls, "requireActivity", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(fragment_cls, "getLayoutInflater", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(fragment_cls, "isAdded", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(fragment_cls, "onAttach", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(fragment_cls, "onCreate", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(fragment_cls, "onViewCreated", "VLL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(fragment_cls, "onDestroyView", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(fragment_cls, "onDestroy", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(fragment_cls, "onDetach", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(fragment_cls, "onResume", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(fragment_cls, "onPause", "V", DX_ACC_PUBLIC,
               native_noop, false);

    // android.app.Fragment (legacy)
    DxClass *legacy_frag = reg_class(vm, "Landroid/app/Fragment;", obj);
    add_method(legacy_frag, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(legacy_frag, "getActivity", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(legacy_frag, "getContext", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // androidx.fragment.app.FragmentManager
    DxClass *frag_mgr = reg_class(vm, "Landroidx/fragment/app/FragmentManager;", obj);
    add_method(frag_mgr, "beginTransaction", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(frag_mgr, "findFragmentById", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(frag_mgr, "findFragmentByTag", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(frag_mgr, "getFragments", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(frag_mgr, "executePendingTransactions", "Z", DX_ACC_PUBLIC,
               native_return_false, false);

    // android.app.FragmentManager (legacy)
    reg_class(vm, "Landroid/app/FragmentManager;", obj);

    // androidx.fragment.app.FragmentTransaction
    DxClass *frag_tx = reg_class(vm, "Landroidx/fragment/app/FragmentTransaction;", obj);
    add_method(frag_tx, "add", "LIL", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(frag_tx, "replace", "LIL", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(frag_tx, "remove", "LL", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(frag_tx, "commit", "I", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(frag_tx, "commitNow", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(frag_tx, "commitAllowingStateLoss", "I", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(frag_tx, "addToBackStack", "LL", DX_ACC_PUBLIC,
               native_return_new_object, false);

    // androidx.appcompat.widget.AppCompatTextView
    reg_class(vm, "Landroidx/appcompat/widget/AppCompatTextView;", textview_cls);

    // androidx.appcompat.widget.AppCompatButton
    reg_class(vm, "Landroidx/appcompat/widget/AppCompatButton;", button_cls);

    // android.widget.RelativeLayout (extends ViewGroup)
    reg_class(vm, "Landroid/widget/RelativeLayout;", viewgroup_cls);

    // android.widget.FrameLayout (extends ViewGroup)
    reg_class(vm, "Landroid/widget/FrameLayout;", viewgroup_cls);

    // androidx.constraintlayout.widget.ConstraintLayout (extends ViewGroup)
    reg_class(vm, "Landroidx/constraintlayout/widget/ConstraintLayout;", viewgroup_cls);

    // androidx.coordinatorlayout.widget.CoordinatorLayout
    reg_class(vm, "Landroidx/coordinatorlayout/widget/CoordinatorLayout;", viewgroup_cls);

    // android.widget.ScrollView (extends FrameLayout -> ViewGroup)
    reg_class(vm, "Landroid/widget/ScrollView;", viewgroup_cls);

    // androidx.lifecycle classes
    reg_class(vm, "Landroidx/lifecycle/Lifecycle;", obj);
    reg_class(vm, "Landroidx/lifecycle/LifecycleOwner;", obj);
    reg_class(vm, "Landroidx/lifecycle/ViewModel;", obj);
    DxClass *early_livedata = reg_class(vm, "Landroidx/lifecycle/LiveData;", obj);
    early_livedata->instance_field_count = 2; // field[0] = value, field[1] = observer
    DxClass *early_mutable_livedata = reg_class(vm, "Landroidx/lifecycle/MutableLiveData;", early_livedata);
    early_mutable_livedata->instance_field_count = 2; // inherit from LiveData
    reg_class(vm, "Landroidx/lifecycle/ViewModelStoreOwner;", obj);
    reg_class(vm, "Landroidx/lifecycle/ViewModelStore;", obj);

    // androidx.activity.result
    reg_class(vm, "Landroidx/activity/result/ActivityResultLauncher;", obj);
    reg_class(vm, "Landroidx/activity/result/contract/ActivityResultContracts;", obj);

    // androidx.compose.ui stubs (Jetpack Compose apps will hit these)
    DxClass *compose_view = reg_class(vm, "Landroidx/compose/ui/platform/AbstractComposeView;", view_cls);
    add_method(compose_view, "setClipChildren", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(compose_view, "setClipToPadding", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    reg_class(vm, "Landroidx/compose/ui/platform/ComposeView;", compose_view);
    DxClass *vcs_cls = reg_class(vm, "Landroidx/compose/ui/platform/ViewCompositionStrategy;", obj);
    add_method(vcs_cls, "installFor", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // androidx.compose.runtime
    DxClass *compose_state = reg_class(vm, "Landroidx/compose/runtime/State;", obj);
    add_method(compose_state, "getValue", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // java.util.concurrent.atomic.AtomicReference
    DxClass *atomic_ref = reg_class(vm, "Ljava/util/concurrent/atomic/AtomicReference;", obj);
    atomic_ref->instance_field_count = 1; // field[0] = referent object
    add_method(atomic_ref, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_atomic_ref_init, true);
    add_method(atomic_ref, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_atomic_ref_init_value, true);
    add_method(atomic_ref, "get", "L", DX_ACC_PUBLIC,
               native_atomic_ref_get, false);
    add_method(atomic_ref, "set", "VL", DX_ACC_PUBLIC,
               native_atomic_ref_set, false);
    add_method(atomic_ref, "compareAndSet", "ZLL", DX_ACC_PUBLIC,
               native_atomic_ref_compare_and_set, false);
    add_method(atomic_ref, "getAndSet", "LL", DX_ACC_PUBLIC,
               native_atomic_ref_get_and_set, false);

    // java.util.concurrent.atomic.AtomicInteger
    DxClass *atomic_int = reg_class(vm, "Ljava/util/concurrent/atomic/AtomicInteger;", obj);
    atomic_int->instance_field_count = 1; // field[0] = value
    add_method(atomic_int, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(atomic_int, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_atomic_int_init_value, true);
    add_method(atomic_int, "get", "I", DX_ACC_PUBLIC,
               native_atomic_int_get, false);
    add_method(atomic_int, "set", "VI", DX_ACC_PUBLIC,
               native_atomic_int_set, false);
    add_method(atomic_int, "getAndIncrement", "I", DX_ACC_PUBLIC,
               native_atomic_int_get_and_increment, false);
    add_method(atomic_int, "incrementAndGet", "I", DX_ACC_PUBLIC,
               native_atomic_int_increment_and_get, false);
    add_method(atomic_int, "compareAndSet", "ZII", DX_ACC_PUBLIC,
               native_atomic_int_compare_and_set, false);
    add_method(atomic_int, "addAndGet", "II", DX_ACC_PUBLIC,
               native_atomic_int_add_and_get, false);
    add_method(atomic_int, "getAndAdd", "II", DX_ACC_PUBLIC,
               native_atomic_int_get_and_add, false);

    // java.util.concurrent.CopyOnWriteArrayList (behaves like ArrayList)
    DxClass *cow_list = reg_class(vm, "Ljava/util/concurrent/CopyOnWriteArrayList;", vm->class_arraylist);
    add_method(cow_list, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(cow_list, "add", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(cow_list, "add", "VIL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(cow_list, "get", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(cow_list, "set", "LIL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(cow_list, "remove", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(cow_list, "remove", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(cow_list, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(cow_list, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(cow_list, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(cow_list, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(cow_list, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(cow_list, "indexOf", "IL", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(cow_list, "addIfAbsent", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    // CopyOnWriteArrayList implements List, Collection, Iterable
    cow_list->interface_count = 3;
    cow_list->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (cow_list->interfaces) {
        cow_list->interfaces[0] = "Ljava/util/List;";
        cow_list->interfaces[1] = "Ljava/util/Collection;";
        cow_list->interfaces[2] = "Ljava/lang/Iterable;";
    }

    // java.util.concurrent.ConcurrentHashMap (same methods as HashMap)
    DxClass *conc_map = reg_class(vm, "Ljava/util/concurrent/ConcurrentHashMap;", vm->class_hashmap);
    add_method(conc_map, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(conc_map, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(conc_map, "put", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "get", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "remove", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "containsKey", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(conc_map, "containsValue", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(conc_map, "size", "I", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(conc_map, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(conc_map, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(conc_map, "keySet", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "values", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "entrySet", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "putIfAbsent", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "getOrDefault", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "computeIfAbsent", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "replace", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_map, "forEach", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    // ConcurrentHashMap implements Map
    conc_map->interface_count = 1;
    conc_map->interfaces = (const char **)dx_malloc(sizeof(const char *) * 1);
    if (conc_map->interfaces) {
        conc_map->interfaces[0] = "Ljava/util/Map;";
    }

    // java.util.concurrent.ConcurrentLinkedQueue
    DxClass *conc_queue = reg_class(vm, "Ljava/util/concurrent/ConcurrentLinkedQueue;", obj);
    add_method(conc_queue, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(conc_queue, "offer", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(conc_queue, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_queue, "peek", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_queue, "add", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(conc_queue, "remove", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_queue, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(conc_queue, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(conc_queue, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(conc_queue, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(conc_queue, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    conc_queue->interface_count = 3;
    conc_queue->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (conc_queue->interfaces) {
        conc_queue->interfaces[0] = "Ljava/util/Queue;";
        conc_queue->interfaces[1] = "Ljava/util/Collection;";
        conc_queue->interfaces[2] = "Ljava/lang/Iterable;";
    }

    // java.util.concurrent.ConcurrentLinkedDeque
    DxClass *conc_deque = reg_class(vm, "Ljava/util/concurrent/ConcurrentLinkedDeque;", obj);
    add_method(conc_deque, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(conc_deque, "offer", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(conc_deque, "offerFirst", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(conc_deque, "offerLast", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(conc_deque, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_deque, "pollFirst", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_deque, "pollLast", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_deque, "peek", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_deque, "peekFirst", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_deque, "peekLast", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_deque, "add", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(conc_deque, "addFirst", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(conc_deque, "addLast", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(conc_deque, "remove", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_deque, "removeFirst", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_deque, "removeLast", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(conc_deque, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(conc_deque, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(conc_deque, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(conc_deque, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    conc_deque->interface_count = 3;
    conc_deque->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (conc_deque->interfaces) {
        conc_deque->interfaces[0] = "Ljava/util/Deque;";
        conc_deque->interfaces[1] = "Ljava/util/Collection;";
        conc_deque->interfaces[2] = "Ljava/lang/Iterable;";
    }

    // java.util.concurrent.LinkedBlockingQueue
    DxClass *lbq = reg_class(vm, "Ljava/util/concurrent/LinkedBlockingQueue;", obj);
    add_method(lbq, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(lbq, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(lbq, "offer", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(lbq, "offer", "ZLJL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(lbq, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(lbq, "poll", "LJL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(lbq, "peek", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(lbq, "put", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(lbq, "take", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(lbq, "add", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(lbq, "remove", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(lbq, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(lbq, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(lbq, "remainingCapacity", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(lbq, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(lbq, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(lbq, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(lbq, "drainTo", "IL", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    lbq->interface_count = 3;
    lbq->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (lbq->interfaces) {
        lbq->interfaces[0] = "Ljava/util/concurrent/BlockingQueue;";
        lbq->interfaces[1] = "Ljava/util/Collection;";
        lbq->interfaces[2] = "Ljava/lang/Iterable;";
    }

    // java.util.concurrent.ArrayBlockingQueue
    DxClass *abq = reg_class(vm, "Ljava/util/concurrent/ArrayBlockingQueue;", obj);
    add_method(abq, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(abq, "<init>", "VIZ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(abq, "offer", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(abq, "offer", "ZLJL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(abq, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(abq, "poll", "LJL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(abq, "peek", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(abq, "put", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(abq, "take", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(abq, "add", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(abq, "remove", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(abq, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(abq, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(abq, "remainingCapacity", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(abq, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(abq, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(abq, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(abq, "drainTo", "IL", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    abq->interface_count = 3;
    abq->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (abq->interfaces) {
        abq->interfaces[0] = "Ljava/util/concurrent/BlockingQueue;";
        abq->interfaces[1] = "Ljava/util/Collection;";
        abq->interfaces[2] = "Ljava/lang/Iterable;";
    }

    // java.util.concurrent.PriorityBlockingQueue
    DxClass *pbq = reg_class(vm, "Ljava/util/concurrent/PriorityBlockingQueue;", obj);
    add_method(pbq, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(pbq, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(pbq, "offer", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(pbq, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pbq, "poll", "LJL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pbq, "peek", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pbq, "put", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(pbq, "take", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pbq, "add", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(pbq, "remove", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pbq, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(pbq, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(pbq, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(pbq, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(pbq, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pbq, "drainTo", "IL", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    pbq->interface_count = 3;
    pbq->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (pbq->interfaces) {
        pbq->interfaces[0] = "Ljava/util/concurrent/BlockingQueue;";
        pbq->interfaces[1] = "Ljava/util/Collection;";
        pbq->interfaces[2] = "Ljava/lang/Iterable;";
    }

    // java.util.concurrent.BlockingQueue (interface)
    DxClass *blocking_queue_cls = reg_class(vm, "Ljava/util/concurrent/BlockingQueue;", obj);
    blocking_queue_cls->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(blocking_queue_cls, "offer", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(blocking_queue_cls, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(blocking_queue_cls, "put", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(blocking_queue_cls, "take", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // java.util.concurrent.CopyOnWriteArraySet
    DxClass *cow_set = reg_class(vm, "Ljava/util/concurrent/CopyOnWriteArraySet;", obj);
    add_method(cow_set, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(cow_set, "add", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(cow_set, "remove", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(cow_set, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(cow_set, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(cow_set, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(cow_set, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(cow_set, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    cow_set->interface_count = 3;
    cow_set->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (cow_set->interfaces) {
        cow_set->interfaces[0] = "Ljava/util/Set;";
        cow_set->interfaces[1] = "Ljava/util/Collection;";
        cow_set->interfaces[2] = "Ljava/lang/Iterable;";
    }

    // java.util.ArrayDeque
    DxClass *array_deque = reg_class(vm, "Ljava/util/ArrayDeque;", obj);
    add_method(array_deque, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(array_deque, "add", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(array_deque, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(array_deque, "peek", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(array_deque, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(array_deque, "size", "I", DX_ACC_PUBLIC,
               native_return_false, false);
    // ArrayDeque implements Collection, Iterable
    array_deque->interface_count = 2;
    array_deque->interfaces = (const char **)dx_malloc(sizeof(const char *) * 2);
    if (array_deque->interfaces) {
        array_deque->interfaces[0] = "Ljava/util/Collection;";
        array_deque->interfaces[1] = "Ljava/lang/Iterable;";
    }

    // java.util.WeakHashMap (behaves like HashMap, implements Map)
    DxClass *weak_map = reg_class(vm, "Ljava/util/WeakHashMap;", vm->class_hashmap);
    add_method(weak_map, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    weak_map->interface_count = 1;
    weak_map->interfaces = (const char **)dx_malloc(sizeof(const char *) * 1);
    if (weak_map->interfaces) {
        weak_map->interfaces[0] = "Ljava/util/Map;";
    }

    // java.lang.ref.Reference (abstract parent of WeakReference, SoftReference)
    DxClass *ref_cls = reg_class(vm, "Ljava/lang/ref/Reference;", obj);
    ref_cls->instance_field_count = 1; // field[0] = _referent
    ref_cls->access_flags = DX_ACC_PUBLIC | DX_ACC_ABSTRACT;
    add_method(ref_cls, "get", "L", DX_ACC_PUBLIC,
               native_weakref_get, false);
    add_method(ref_cls, "clear", "V", DX_ACC_PUBLIC,
               native_weakref_clear, false);
    add_method(ref_cls, "enqueue", "Z", DX_ACC_PUBLIC,
               native_return_false, false);  // always returns false
    add_method(ref_cls, "isEnqueued", "Z", DX_ACC_PUBLIC,
               native_return_false, false);  // always returns false

    // java.lang.ref.ReferenceQueue
    DxClass *ref_queue = reg_class(vm, "Ljava/lang/ref/ReferenceQueue;", obj);
    add_method(ref_queue, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(ref_queue, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);   // always returns null
    add_method(ref_queue, "remove", "L", DX_ACC_PUBLIC,
               native_return_null, false);   // always returns null
    add_method(ref_queue, "remove", "LJ", DX_ACC_PUBLIC,
               native_return_null, false);   // remove(long timeout) variant

    // java.lang.ref.WeakReference extends Reference
    DxClass *weak_ref = reg_class(vm, "Ljava/lang/ref/WeakReference;", ref_cls);
    weak_ref->instance_field_count = 1; // field[0] = _referent
    add_method(weak_ref, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_weakref_init, true);
    add_method(weak_ref, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_weakref_init, true);  // WeakReference(referent, queue) variant
    add_method(weak_ref, "get", "L", DX_ACC_PUBLIC,
               native_weakref_get, false);
    add_method(weak_ref, "clear", "V", DX_ACC_PUBLIC,
               native_weakref_clear, false);

    // java.lang.ref.SoftReference extends Reference (same semantics as WeakReference for us)
    DxClass *soft_ref = reg_class(vm, "Ljava/lang/ref/SoftReference;", ref_cls);
    soft_ref->instance_field_count = 1; // field[0] = _referent
    add_method(soft_ref, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_weakref_init, true);
    add_method(soft_ref, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_weakref_init, true);  // SoftReference(referent, queue) variant
    add_method(soft_ref, "get", "L", DX_ACC_PUBLIC,
               native_weakref_get, false);
    add_method(soft_ref, "clear", "V", DX_ACC_PUBLIC,
               native_weakref_clear, false);

    // java.util.Collections (utility methods)
    DxClass *collections_cls = reg_class(vm, "Ljava/util/Collections;", obj);
    add_method(collections_cls, "synchronizedMap", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_arg0, true);
    add_method(collections_cls, "synchronizedList", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_arg0, true);
    add_method(collections_cls, "unmodifiableList", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_arg0, true);
    add_method(collections_cls, "unmodifiableMap", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_arg0, true);
    add_method(collections_cls, "emptyList", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_empty_list, true);
    add_method(collections_cls, "emptyMap", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_empty_map, true);
    add_method(collections_cls, "singletonList", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_singleton_list, true);
    add_method(collections_cls, "sort", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(collections_cls, "sort", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(collections_cls, "reverse", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(collections_cls, "addAll", "ZLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_collections_addAll, true);
    add_method(collections_cls, "frequency", "ILL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_collections_frequency, true);
    add_method(collections_cls, "singleton", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_collections_singleton, true);
    add_method(collections_cls, "singletonMap", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_collections_singletonMap, true);

    // android.os.SystemClock — use real monotonic time
    DxClass *sysclock = reg_class(vm, "Landroid/os/SystemClock;", obj);
    add_method(sysclock, "elapsedRealtimeNanos", "J", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_system_nano_time, true);
    add_method(sysclock, "elapsedRealtime", "J", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_system_current_time_millis, true);
    add_method(sysclock, "uptimeMillis", "J", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_system_current_time_millis, true);
    add_method(sysclock, "currentThreadTimeMillis", "J", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_system_current_time_millis, true);

    // android.os.Build / Build.VERSION
    DxClass *build_cls = reg_class(vm, "Landroid/os/Build;", obj);
    {
        DxObject *mfr_str = dx_vm_create_string(vm, "DexLoom");
        DxObject *model_str = dx_vm_create_string(vm, "iOS Simulator");
        DxObject *brand_str = dx_vm_create_string(vm, "DexLoom");
        DxObject *device_str = dx_vm_create_string(vm, "ios");
        const char *bnames[] = { "MANUFACTURER", "MODEL", "BRAND", "DEVICE" };
        DxValue bvals[] = {
            mfr_str ? DX_OBJ_VALUE(mfr_str) : DX_NULL_VALUE,
            model_str ? DX_OBJ_VALUE(model_str) : DX_NULL_VALUE,
            brand_str ? DX_OBJ_VALUE(brand_str) : DX_NULL_VALUE,
            device_str ? DX_OBJ_VALUE(device_str) : DX_NULL_VALUE
        };
        add_static_fields(build_cls, bnames, bvals, 4);
    }
    DxClass *build_ver = reg_class(vm, "Landroid/os/Build$VERSION;", obj);
    {
        DxObject *rel_str = dx_vm_create_string(vm, "13");
        DxObject *codename_str = dx_vm_create_string(vm, "REL");
        const char *vnames[] = { "SDK_INT", "RELEASE", "CODENAME" };
        DxValue vvals[] = {
            DX_INT_VALUE(33),
            rel_str ? DX_OBJ_VALUE(rel_str) : DX_NULL_VALUE,
            codename_str ? DX_OBJ_VALUE(codename_str) : DX_NULL_VALUE
        };
        add_static_fields(build_ver, vnames, vvals, 3);
    }

    // android.content.res.Resources - additional methods (class registered earlier as res_cls)
    DxClass *resources_cls = vm->class_resources;
    add_method(resources_cls, "getString", "LI", DX_ACC_PUBLIC,
               native_resources_get_string, false);
    add_method(resources_cls, "getColor", "II", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(resources_cls, "getDimension", "FI", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(resources_cls, "getDrawable", "LI", DX_ACC_PUBLIC,
               native_return_null, false);

    // android.util.TypedValue
    DxClass *typed_value_cls = reg_class(vm, "Landroid/util/TypedValue;", obj);
    add_method(typed_value_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(typed_value_cls, "applyDimension", "FIFL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_typed_value_apply_dimension, true);
    add_method(typed_value_cls, "complexToDimensionPixelSize", "IIL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_typed_value_complex_to_dimension, true);

    // android.util.DisplayMetrics (field-backed: density, densityDpi, widthPixels, heightPixels, scaledDensity)
    DxClass *display_metrics_cls = reg_class(vm, "Landroid/util/DisplayMetrics;", obj);
    {
        const char *dm_names[] = { "density", "densityDpi", "widthPixels", "heightPixels", "scaledDensity" };
        const char *dm_types[] = { "F", "I", "I", "I", "F" };
        setup_instance_fields(display_metrics_cls, dm_names, dm_types, DM_FIELD_COUNT);
    }
    add_method(display_metrics_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    {
        const char *dm_snames[] = { "DENSITY_DEFAULT" };
        DxValue dm_svals[] = { DX_INT_VALUE(160) };
        add_static_fields(display_metrics_cls, dm_snames, dm_svals, 1);
    }

    // android.util.SparseArray
    DxClass *sparse_cls = reg_class(vm, "Landroid/util/SparseArray;", obj);
    add_method(sparse_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(sparse_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(sparse_cls, "get", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(sparse_cls, "put", "VIL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(sparse_cls, "size", "I", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(sparse_cls, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);

    // java.util.LinkedHashMap (extends HashMap, implements Map)
    DxClass *linked_map = reg_class(vm, "Ljava/util/LinkedHashMap;", vm->class_hashmap);
    add_method(linked_map, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(linked_map, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(linked_map, "<init>", "VIF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(linked_map, "<init>", "VIFZ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true); // (capacity, loadFactor, accessOrder)
    add_method(linked_map, "put", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_map, "get", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_map, "remove", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_map, "containsKey", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(linked_map, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(linked_map, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(linked_map, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(linked_map, "keySet", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_map, "values", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_map, "entrySet", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_map, "getOrDefault", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_map, "putIfAbsent", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    linked_map->interface_count = 1;
    linked_map->interfaces = (const char **)dx_malloc(sizeof(const char *) * 1);
    if (linked_map->interfaces) {
        linked_map->interfaces[0] = "Ljava/util/Map;";
    }

    // java.util.LinkedList (same methods as ArrayList, implements List/Collection/Iterable)
    DxClass *linked_list = reg_class(vm, "Ljava/util/LinkedList;", vm->class_arraylist);
    add_method(linked_list, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(linked_list, "add", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(linked_list, "add", "VIL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(linked_list, "get", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "set", "LIL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "remove", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "remove", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(linked_list, "size", "I", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(linked_list, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(linked_list, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(linked_list, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(linked_list, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "addFirst", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(linked_list, "addLast", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(linked_list, "getFirst", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "getLast", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "removeFirst", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "removeLast", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "peek", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "offer", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(linked_list, "pollFirst", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "pollLast", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "peekFirst", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "peekLast", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(linked_list, "toArray", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    // LinkedList implements List, Collection, Iterable, Deque, Queue
    linked_list->interface_count = 5;
    linked_list->interfaces = (const char **)dx_malloc(sizeof(const char *) * 5);
    if (linked_list->interfaces) {
        linked_list->interfaces[0] = "Ljava/util/List;";
        linked_list->interfaces[1] = "Ljava/util/Collection;";
        linked_list->interfaces[2] = "Ljava/lang/Iterable;";
        linked_list->interfaces[3] = "Ljava/util/Deque;";
        linked_list->interfaces[4] = "Ljava/util/Queue;";
    }

    // java.util.HashSet
    DxClass *hashset = reg_class(vm, "Ljava/util/HashSet;", obj);
    add_method(hashset, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(hashset, "add", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashset, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashset, "remove", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashset, "size", "I", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashset, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(hashset, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(hashset, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    // HashSet implements Set, Collection, Iterable
    hashset->interface_count = 3;
    hashset->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (hashset->interfaces) {
        hashset->interfaces[0] = "Ljava/util/Set;";
        hashset->interfaces[1] = "Ljava/util/Collection;";
        hashset->interfaces[2] = "Ljava/lang/Iterable;";
    }
    add_method(hashset, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true); // HashSet(Collection)
    add_method(hashset, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true); // HashSet(int initialCapacity)
    add_method(hashset, "addAll", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashset, "toArray", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(hashset, "containsAll", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashset, "removeAll", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashset, "retainAll", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);

    // java.util.TreeSet (sorted set backed by TreeMap, same API as HashSet)
    DxClass *treeset = reg_class(vm, "Ljava/util/TreeSet;", obj);
    add_method(treeset, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(treeset, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true); // TreeSet(Comparator) or TreeSet(Collection)
    add_method(treeset, "add", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(treeset, "remove", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(treeset, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(treeset, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(treeset, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(treeset, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(treeset, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treeset, "first", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treeset, "last", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treeset, "lower", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treeset, "higher", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treeset, "floor", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treeset, "ceiling", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treeset, "addAll", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(treeset, "toArray", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    treeset->interface_count = 4;
    treeset->interfaces = (const char **)dx_malloc(sizeof(const char *) * 4);
    if (treeset->interfaces) {
        treeset->interfaces[0] = "Ljava/util/Set;";
        treeset->interfaces[1] = "Ljava/util/SortedSet;";
        treeset->interfaces[2] = "Ljava/util/NavigableSet;";
        treeset->interfaces[3] = "Ljava/lang/Iterable;";
    }

    // java.util.LinkedHashSet (insertion-ordered set, same API as HashSet)
    DxClass *linked_hashset = reg_class(vm, "Ljava/util/LinkedHashSet;", hashset);
    add_method(linked_hashset, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(linked_hashset, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(linked_hashset, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    // Inherits all methods from HashSet
    linked_hashset->interface_count = 3;
    linked_hashset->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (linked_hashset->interfaces) {
        linked_hashset->interfaces[0] = "Ljava/util/Set;";
        linked_hashset->interfaces[1] = "Ljava/util/Collection;";
        linked_hashset->interfaces[2] = "Ljava/lang/Iterable;";
    }

    // java.util.Hashtable (synchronized HashMap, same API)
    DxClass *hashtable = reg_class(vm, "Ljava/util/Hashtable;", vm->class_hashmap);
    add_method(hashtable, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(hashtable, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(hashtable, "put", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(hashtable, "get", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(hashtable, "remove", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(hashtable, "containsKey", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashtable, "containsValue", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashtable, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(hashtable, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(hashtable, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(hashtable, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(hashtable, "keySet", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(hashtable, "values", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(hashtable, "entrySet", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(hashtable, "keys", "L", DX_ACC_PUBLIC,
               native_return_null, false); // Enumeration
    add_method(hashtable, "elements", "L", DX_ACC_PUBLIC,
               native_return_null, false); // Enumeration
    add_method(hashtable, "putIfAbsent", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(hashtable, "getOrDefault", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    hashtable->interface_count = 1;
    hashtable->interfaces = (const char **)dx_malloc(sizeof(const char *) * 1);
    if (hashtable->interfaces) {
        hashtable->interfaces[0] = "Ljava/util/Map;";
    }

    // java.util.PriorityQueue
    DxClass *pqueue = reg_class(vm, "Ljava/util/PriorityQueue;", obj);
    add_method(pqueue, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(pqueue, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(pqueue, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true); // PriorityQueue(Comparator)
    add_method(pqueue, "offer", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(pqueue, "poll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pqueue, "peek", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pqueue, "add", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(pqueue, "remove", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pqueue, "remove", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(pqueue, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(pqueue, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(pqueue, "contains", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(pqueue, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(pqueue, "iterator", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pqueue, "toArray", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    pqueue->interface_count = 3;
    pqueue->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (pqueue->interfaces) {
        pqueue->interfaces[0] = "Ljava/util/Queue;";
        pqueue->interfaces[1] = "Ljava/util/Collection;";
        pqueue->interfaces[2] = "Ljava/lang/Iterable;";
    }

    // java.util.TreeMap (same methods as HashMap)
    DxClass *treemap = reg_class(vm, "Ljava/util/TreeMap;", vm->class_hashmap);
    add_method(treemap, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(treemap, "put", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "get", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "remove", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "containsKey", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(treemap, "containsValue", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(treemap, "size", "I", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(treemap, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(treemap, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(treemap, "keySet", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "values", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "entrySet", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "firstKey", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "lastKey", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "firstEntry", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "lastEntry", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "lowerKey", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "higherKey", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "floorKey", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "ceilingKey", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "putIfAbsent", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(treemap, "getOrDefault", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);
    // TreeMap implements Map, SortedMap, NavigableMap
    treemap->interface_count = 3;
    treemap->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (treemap->interfaces) {
        treemap->interfaces[0] = "Ljava/util/Map;";
        treemap->interfaces[1] = "Ljava/util/SortedMap;";
        treemap->interfaces[2] = "Ljava/util/NavigableMap;";
    }

    // ============================================================
    // Additional missing framework classes
    // ============================================================

    // android.app.Dialog
    DxClass *dialog_cls = reg_class(vm, "Landroid/app/Dialog;", context_cls);
    add_method(dialog_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(dialog_cls, "<init>", "VLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(dialog_cls, "getContext", "L", DX_ACC_PUBLIC,
               native_dialog_get_context, false);
    add_method(dialog_cls, "getWindow", "L", DX_ACC_PUBLIC,
               native_dialog_get_window, false);
    add_method(dialog_cls, "show", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "dismiss", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "cancel", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "setCancelable", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "setCanceledOnTouchOutside", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "setTitle", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "setContentView", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "setContentView", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "setOnDismissListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "setOnCancelListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "setOnKeyListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "setOnShowListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(dialog_cls, "getLayoutInflater", "L", DX_ACC_PUBLIC,
               native_dialog_get_layout_inflater, false);
    add_method(dialog_cls, "findViewById", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(dialog_cls, "isShowing", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(dialog_cls, "dispatchKeyEvent", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(dialog_cls, "onCreate", "VL", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(dialog_cls, "onStart", "V", DX_ACC_PROTECTED,
               native_noop, false);
    add_method(dialog_cls, "onStop", "V", DX_ACC_PROTECTED,
               native_noop, false);

    // android.content.res.TypedArray — backed by array resource via field[0] = res_id
    DxClass *typed_arr = reg_class(vm, "Landroid/content/res/TypedArray;", obj);
    typed_arr->instance_field_count = 1; // field[0] = backing array resource ID
    add_method(typed_arr, "hasValue", "ZI", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(typed_arr, "getValue", "ZIL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(typed_arr, "getResourceId", "III", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(typed_arr, "getBoolean", "ZIZ", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(typed_arr, "getInt", "III", DX_ACC_PUBLIC,
               native_typed_array_get_int, false);
    add_method(typed_arr, "getInteger", "III", DX_ACC_PUBLIC,
               native_typed_array_get_int, false);
    add_method(typed_arr, "getString", "LI", DX_ACC_PUBLIC,
               native_typed_array_get_string, false);
    add_method(typed_arr, "getText", "LI", DX_ACC_PUBLIC,
               native_typed_array_get_string, false);
    add_method(typed_arr, "getFloat", "FIF", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(typed_arr, "getColor", "III", DX_ACC_PUBLIC,
               native_typed_array_get_color, false);
    add_method(typed_arr, "getDimension", "FIF", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(typed_arr, "getDimensionPixelSize", "III", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(typed_arr, "getDrawable", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(typed_arr, "getColorStateList", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(typed_arr, "getLayoutDimension", "III", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(typed_arr, "length", "I", DX_ACC_PUBLIC,
               native_typed_array_length, false);
    add_method(typed_arr, "getIndexCount", "I", DX_ACC_PUBLIC,
               native_typed_array_length, false);
    add_method(typed_arr, "recycle", "V", DX_ACC_PUBLIC,
               native_noop, false);

    // android.content.res.Resources$Theme
    DxClass *theme_cls = reg_class(vm, "Landroid/content/res/Resources$Theme;", obj);
    add_method(theme_cls, "resolveAttribute", "ZIL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(theme_cls, "obtainStyledAttributes", "LLI", DX_ACC_PUBLIC,
               native_return_new_object, false);

    // android.text.TextUtils
    DxClass *textutils_cls = reg_class(vm, "Landroid/text/TextUtils;", obj);
    add_method(textutils_cls, "isEmpty", "ZL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_textutils_isempty, true);
    add_method(textutils_cls, "equals", "ZLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_textutils_equals, true);
    add_method(textutils_cls, "join", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(textutils_cls, "isDigitsOnly", "ZL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);
    add_method(textutils_cls, "htmlEncode", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_arg0, true);
    add_method(textutils_cls, "getTrimmedLength", "IL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_textutils_trimmed_length, true);
    add_method(textutils_cls, "concat", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_textutils_concat, true);

    // android.content.IntentFilter
    DxClass *intentfilter_cls = reg_class(vm, "Landroid/content/IntentFilter;", obj);
    add_method(intentfilter_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(intentfilter_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(intentfilter_cls, "addAction", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(intentfilter_cls, "countActions", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(intentfilter_cls, "hasAction", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);

    // android.graphics.Point (field-backed: x, y)
    DxClass *point_cls = reg_class(vm, "Landroid/graphics/Point;", obj);
    {
        const char *pnames[] = { "x", "y" };
        const char *ptypes[] = { "I", "I" };
        setup_instance_fields(point_cls, pnames, ptypes, POINT_FIELD_COUNT);
    }
    add_method(point_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(point_cls, "<init>", "VII", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_point_init2, true);
    add_method(point_cls, "set", "VII", DX_ACC_PUBLIC,
               native_point_set, false);
    add_method(point_cls, "equals", "ZL", DX_ACC_PUBLIC,
               native_point_equals, false);
    add_method(point_cls, "toString", "L", DX_ACC_PUBLIC,
               native_point_toString, false);

    // android.graphics.PointF (field-backed: x, y as float)
    DxClass *pointf_cls = reg_class(vm, "Landroid/graphics/PointF;", obj);
    {
        const char *pfnames[] = { "x", "y" };
        const char *pftypes[] = { "F", "F" };
        setup_instance_fields(pointf_cls, pfnames, pftypes, POINT_FIELD_COUNT);
    }
    add_method(pointf_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(pointf_cls, "<init>", "VFF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_pointf_init2, true);
    add_method(pointf_cls, "set", "VFF", DX_ACC_PUBLIC,
               native_pointf_set, false);
    add_method(pointf_cls, "equals", "ZL", DX_ACC_PUBLIC,
               native_point_equals, false);
    add_method(pointf_cls, "toString", "L", DX_ACC_PUBLIC,
               native_pointf_toString, false);

    // android.graphics.Rect (field-backed: left, top, right, bottom)
    DxClass *rect_cls = reg_class(vm, "Landroid/graphics/Rect;", obj);
    {
        const char *rnames[] = { "left", "top", "right", "bottom" };
        const char *rtypes[] = { "I", "I", "I", "I" };
        setup_instance_fields(rect_cls, rnames, rtypes, RECT_FIELD_COUNT);
    }
    add_method(rect_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(rect_cls, "<init>", "VIIII", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_rect_init4, true);
    add_method(rect_cls, "set", "VIIII", DX_ACC_PUBLIC,
               native_rect_set4, false);
    add_method(rect_cls, "width", "I", DX_ACC_PUBLIC,
               native_rect_width, false);
    add_method(rect_cls, "height", "I", DX_ACC_PUBLIC,
               native_rect_height, false);
    add_method(rect_cls, "centerX", "I", DX_ACC_PUBLIC,
               native_rect_centerX, false);
    add_method(rect_cls, "centerY", "I", DX_ACC_PUBLIC,
               native_rect_centerY, false);
    add_method(rect_cls, "contains", "ZII", DX_ACC_PUBLIC,
               native_rect_contains_xy, false);
    add_method(rect_cls, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_rect_isEmpty, false);

    // android.view.Window$Callback (interface)
    DxClass *wincb_cls = reg_class(vm, "Landroid/view/Window$Callback;", obj);
    wincb_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(wincb_cls, "onContentChanged", "V", DX_ACC_PUBLIC,
               native_noop, false);

    // android.view.Display
    DxClass *display_cls = reg_class(vm, "Landroid/view/Display;", obj);
    add_method(display_cls, "getSize", "VL", DX_ACC_PUBLIC,
               native_display_get_size, false);
    add_method(display_cls, "getMetrics", "VL", DX_ACC_PUBLIC,
               native_display_get_metrics, false);
    add_method(display_cls, "getRealSize", "VL", DX_ACC_PUBLIC,
               native_display_get_size, false);
    add_method(display_cls, "getRealMetrics", "VL", DX_ACC_PUBLIC,
               native_display_get_metrics, false);
    add_method(display_cls, "getRotation", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(display_cls, "getDisplayId", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    // android.view.WindowManager (proper with methods)
    DxClass *winmgr_cls = reg_class(vm, "Landroid/view/WindowManager;", obj);
    add_method(winmgr_cls, "getDefaultDisplay", "L", DX_ACC_PUBLIC,
               native_winmgr_get_default_display, false);

    // android.text.Html
    DxClass *html_cls = reg_class(vm, "Landroid/text/Html;", obj);
    add_method(html_cls, "fromHtml", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(html_cls, "fromHtml", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // android.text.Spanned (interface)
    DxClass *spanned_cls = reg_class(vm, "Landroid/text/Spanned;", obj);
    spanned_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(spanned_cls, "getSpans", "LIIL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(spanned_cls, "length", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    // android.text.SpannableString (implements Spanned)
    DxClass *spannable_str = reg_class(vm, "Landroid/text/SpannableString;", obj);
    add_method(spannable_str, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(spannable_str, "toString", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(spannable_str, "length", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(spannable_str, "setSpan", "VLII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(spannable_str, "getSpans", "LIIL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(spannable_str, "valueOf", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_arg0, true);

    // android.text.SpannableStringBuilder
    DxClass *spannable_sb = reg_class(vm, "Landroid/text/SpannableStringBuilder;", obj);
    add_method(spannable_sb, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(spannable_sb, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(spannable_sb, "append", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(spannable_sb, "toString", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(spannable_sb, "length", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(spannable_sb, "setSpan", "VLII", DX_ACC_PUBLIC,
               native_noop, false);

    // android.text.TextWatcher (interface)
    DxClass *textwatcher_cls = reg_class(vm, "Landroid/text/TextWatcher;", obj);
    textwatcher_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(textwatcher_cls, "beforeTextChanged", "VLIII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textwatcher_cls, "onTextChanged", "VLIII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textwatcher_cls, "afterTextChanged", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // android.text.Editable (interface with default stubs)
    DxClass *editable_cls = reg_class(vm, "Landroid/text/Editable;", obj);
    add_method(editable_cls, "toString", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(editable_cls, "length", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(editable_cls, "charAt", "CI", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(editable_cls, "subSequence", "LII", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(editable_cls, "append", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(editable_cls, "insert", "LIL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(editable_cls, "delete", "LII", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(editable_cls, "replace", "LIIL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(editable_cls, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(editable_cls, "getFilters", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(editable_cls, "setFilters", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // android.hardware.display.DisplayManager
    DxClass *dispmgr_cls = reg_class(vm, "Landroid/hardware/display/DisplayManager;", obj);
    add_method(dispmgr_cls, "getDisplay", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(dispmgr_cls, "getDisplays", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // android.app.UiModeManager
    DxClass *uimode_cls = reg_class(vm, "Landroid/app/UiModeManager;", obj);
    add_method(uimode_cls, "getNightMode", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    // android.provider.Settings$Secure
    DxClass *settings_cls = reg_class(vm, "Landroid/provider/Settings$Secure;", obj);
    add_method(settings_cls, "getInt", "ILLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_last_int_arg, true);
    add_method(settings_cls, "getString", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // android.provider.Settings$System
    DxClass *settings_sys_cls = reg_class(vm, "Landroid/provider/Settings$System;", obj);
    add_method(settings_sys_cls, "getInt", "ILLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_last_int_arg, true);
    add_method(settings_sys_cls, "getString", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(settings_sys_cls, "putInt", "ZLLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_true, true);
    add_method(settings_sys_cls, "putString", "ZLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_true, true);

    // android.provider.Settings$Global
    DxClass *settings_global_cls = reg_class(vm, "Landroid/provider/Settings$Global;", obj);
    add_method(settings_global_cls, "getInt", "ILLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_last_int_arg, true);
    add_method(settings_global_cls, "getString", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // android.util.AndroidRuntimeException
    DxClass *android_re = reg_class(vm, "Landroid/util/AndroidRuntimeException;", obj);
    add_method(android_re, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);

    // android.content.ContentResolver
    DxClass *resolver_cls = reg_class(vm, "Landroid/content/ContentResolver;", obj);
    add_method(resolver_cls, "query", "LLLLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(resolver_cls, "query", "LLLLLL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(resolver_cls, "insert", "LLL", DX_ACC_PUBLIC,
               native_content_resolver_insert, false);
    add_method(resolver_cls, "update", "ILLLL", DX_ACC_PUBLIC,
               native_content_resolver_update, false);
    add_method(resolver_cls, "delete", "ILLL", DX_ACC_PUBLIC,
               native_content_resolver_update, false);
    add_method(resolver_cls, "getType", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(resolver_cls, "openInputStream", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(resolver_cls, "registerContentObserver", "VLZL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(resolver_cls, "unregisterContentObserver", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(resolver_cls, "notifyChange", "VLZ", DX_ACC_PUBLIC,
               native_noop, false);

    // android.content.res.Configuration — field-backed with static constants
    DxClass *config_cls = reg_class(vm, "Landroid/content/res/Configuration;", obj);
    config_cls->instance_field_count = DX_CONFIG_FIELD_COUNT;
    add_method(config_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_config_init, true);
    // Static constants + instance field_defs
    {
        config_cls->static_field_count = 2;
        config_cls->static_fields = (DxValue *)dx_malloc(sizeof(DxValue) * 2);
        if (config_cls->static_fields) {
            config_cls->static_fields[0] = DX_INT_VALUE(1); // ORIENTATION_PORTRAIT
            config_cls->static_fields[1] = DX_INT_VALUE(2); // ORIENTATION_LANDSCAPE
        }
        // field_defs: [0..4] = instance fields, [5..6] not needed since add_static_fields
        // uses separate indexing, but dx_vm_set/get_field only looks at [0..own_count-1]
        config_cls->field_defs = dx_malloc(sizeof(*config_cls->field_defs) * (DX_CONFIG_FIELD_COUNT + 2));
        if (config_cls->field_defs) {
            memset(config_cls->field_defs, 0, sizeof(*config_cls->field_defs) * (DX_CONFIG_FIELD_COUNT + 2));
            config_cls->field_defs[0].name = "orientation";
            config_cls->field_defs[0].type = "I";
            config_cls->field_defs[0].flags = DX_ACC_PUBLIC;
            config_cls->field_defs[1].name = "screenWidthDp";
            config_cls->field_defs[1].type = "I";
            config_cls->field_defs[1].flags = DX_ACC_PUBLIC;
            config_cls->field_defs[2].name = "screenHeightDp";
            config_cls->field_defs[2].type = "I";
            config_cls->field_defs[2].flags = DX_ACC_PUBLIC;
            config_cls->field_defs[3].name = "locale";
            config_cls->field_defs[3].type = "Ljava/util/Locale;";
            config_cls->field_defs[3].flags = DX_ACC_PUBLIC;
            config_cls->field_defs[4].name = "densityDpi";
            config_cls->field_defs[4].type = "I";
            config_cls->field_defs[4].flags = DX_ACC_PUBLIC;
        }
    }

    // android.content.res.ColorStateList
    DxClass *csl_cls = reg_class(vm, "Landroid/content/res/ColorStateList;", obj);
    add_method(csl_cls, "getDefaultColor", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    // android.graphics.drawable.Drawable
    DxClass *drawable_cls = reg_class(vm, "Landroid/graphics/drawable/Drawable;", obj);
    add_method(drawable_cls, "setBounds", "VIIII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(drawable_cls, "setAlpha", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(drawable_cls, "draw", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(drawable_cls, "getIntrinsicWidth", "I", DX_ACC_PUBLIC,
               native_drawable_get_intrinsic_size, false);
    add_method(drawable_cls, "getIntrinsicHeight", "I", DX_ACC_PUBLIC,
               native_drawable_get_intrinsic_size, false);

    // android.content.BroadcastReceiver
    DxClass *receiver_cls = reg_class(vm, "Landroid/content/BroadcastReceiver;", obj);
    receiver_cls->access_flags = DX_ACC_ABSTRACT;
    add_method(receiver_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(receiver_cls, "onReceive", "VLL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_noop, false);
    add_method(receiver_cls, "abortBroadcast", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(receiver_cls, "getResultCode", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(receiver_cls, "setResultCode", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(receiver_cls, "getResultData", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(receiver_cls, "setResultData", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(receiver_cls, "isOrderedBroadcast", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(receiver_cls, "goAsync", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // android.animation.Animator (base class)
    DxClass *animator_cls = reg_class(vm, "Landroid/animation/Animator;", obj);
    add_method(animator_cls, "start", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(animator_cls, "cancel", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(animator_cls, "end", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(animator_cls, "addListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(animator_cls, "removeListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(animator_cls, "removeAllListeners", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(animator_cls, "setDuration", "LJ", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(animator_cls, "getDuration", "J", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(animator_cls, "setStartDelay", "VJ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(animator_cls, "getStartDelay", "J", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(animator_cls, "isRunning", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(animator_cls, "isStarted", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(animator_cls, "setTarget", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(animator_cls, "clone", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(animator_cls, "setInterpolator", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // android.animation.Animator$AnimatorListener (interface)
    DxClass *anim_listener_cls = reg_class(vm, "Landroid/animation/Animator$AnimatorListener;", obj);
    add_method(anim_listener_cls, "onAnimationStart", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_listener_cls, "onAnimationEnd", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_listener_cls, "onAnimationCancel", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_listener_cls, "onAnimationRepeat", "VL", DX_ACC_PUBLIC, native_noop, false);

    // android.animation.AnimatorListenerAdapter (abstract, implements AnimatorListener)
    DxClass *anim_listener_adapter_cls = reg_class(vm, "Landroid/animation/AnimatorListenerAdapter;", anim_listener_cls);
    add_method(anim_listener_adapter_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(anim_listener_adapter_cls, "onAnimationStart", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_listener_adapter_cls, "onAnimationEnd", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_listener_adapter_cls, "onAnimationCancel", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_listener_adapter_cls, "onAnimationRepeat", "VL", DX_ACC_PUBLIC, native_noop, false);

    // android.animation.ValueAnimator (extends Animator)
    DxClass *vanim_cls = reg_class(vm, "Landroid/animation/ValueAnimator;", animator_cls);
    add_method(vanim_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(vanim_cls, "ofFloat", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(vanim_cls, "ofInt", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(vanim_cls, "ofArgb", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(vanim_cls, "ofPropertyValuesHolder", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(vanim_cls, "addUpdateListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(vanim_cls, "removeUpdateListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(vanim_cls, "removeAllUpdateListeners", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(vanim_cls, "setRepeatCount", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(vanim_cls, "getRepeatCount", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(vanim_cls, "setRepeatMode", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(vanim_cls, "getRepeatMode", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(vanim_cls, "getAnimatedValue", "L", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(vanim_cls, "getAnimatedFraction", "F", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(vanim_cls, "setFloatValues", "V", DX_ACC_PUBLIC,
               native_noop, true);
    add_method(vanim_cls, "setIntValues", "V", DX_ACC_PUBLIC,
               native_noop, true);
    add_method(vanim_cls, "setEvaluator", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(vanim_cls, "setCurrentPlayTime", "VJ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(vanim_cls, "getCurrentPlayTime", "J", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(vanim_cls, "reverse", "V", DX_ACC_PUBLIC,
               native_noop, false);

    // android.animation.ValueAnimator$AnimatorUpdateListener (interface)
    DxClass *update_listener_cls = reg_class(vm, "Landroid/animation/ValueAnimator$AnimatorUpdateListener;", obj);
    add_method(update_listener_cls, "onAnimationUpdate", "VL", DX_ACC_PUBLIC, native_noop, false);

    // android.animation.ObjectAnimator (extends ValueAnimator)
    DxClass *oanim_cls = reg_class(vm, "Landroid/animation/ObjectAnimator;", vanim_cls);
    add_method(oanim_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(oanim_cls, "ofFloat", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(oanim_cls, "ofInt", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(oanim_cls, "ofArgb", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(oanim_cls, "ofPropertyValuesHolder", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(oanim_cls, "setAutoCancel", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(oanim_cls, "setPropertyName", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(oanim_cls, "getPropertyName", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // android.animation.AnimatorSet (extends Animator)
    DxClass *anim_set_animator_cls = reg_class(vm, "Landroid/animation/AnimatorSet;", animator_cls);
    add_method(anim_set_animator_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(anim_set_animator_cls, "playTogether", "VL", DX_ACC_PUBLIC, native_noop, true);
    add_method(anim_set_animator_cls, "playSequentially", "VL", DX_ACC_PUBLIC, native_noop, true);
    add_method(anim_set_animator_cls, "play", "LL", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(anim_set_animator_cls, "start", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_set_animator_cls, "cancel", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_set_animator_cls, "end", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_set_animator_cls, "clone", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);

    // android.animation.AnimatorSet$Builder
    DxClass *anim_set_builder_cls = reg_class(vm, "Landroid/animation/AnimatorSet$Builder;", obj);
    add_method(anim_set_builder_cls, "with", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(anim_set_builder_cls, "before", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(anim_set_builder_cls, "after", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(anim_set_builder_cls, "after", "LJ", DX_ACC_PUBLIC,
               native_return_self, false);

    // android.animation.PropertyValuesHolder
    DxClass *pvh_cls = reg_class(vm, "Landroid/animation/PropertyValuesHolder;", obj);
    add_method(pvh_cls, "ofFloat", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(pvh_cls, "ofInt", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(pvh_cls, "ofKeyframe", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(pvh_cls, "setEvaluator", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // android.animation.Keyframe
    DxClass *keyframe_cls = reg_class(vm, "Landroid/animation/Keyframe;", obj);
    add_method(keyframe_cls, "ofFloat", "LFF", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, false);
    add_method(keyframe_cls, "ofInt", "LFI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, false);
    add_method(keyframe_cls, "setInterpolator", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // android.animation.TimeInterpolator (interface)
    DxClass *time_interpolator_cls = reg_class(vm, "Landroid/animation/TimeInterpolator;", obj);
    add_method(time_interpolator_cls, "getInterpolation", "FF", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    (void)time_interpolator_cls;

    // android.animation.TypeEvaluator (interface)
    DxClass *type_evaluator_cls = reg_class(vm, "Landroid/animation/TypeEvaluator;", obj);
    add_method(type_evaluator_cls, "evaluate", "LFLL", DX_ACC_PUBLIC,
               native_return_null, false);
    (void)type_evaluator_cls;

    // android.animation.ArgbEvaluator
    DxClass *argb_eval_cls = reg_class(vm, "Landroid/animation/ArgbEvaluator;", obj);
    add_method(argb_eval_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    (void)argb_eval_cls;

    // android.animation.LayoutTransition
    DxClass *layout_transition_cls = reg_class(vm, "Landroid/animation/LayoutTransition;", obj);
    add_method(layout_transition_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(layout_transition_cls, "setDuration", "VJ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(layout_transition_cls, "setAnimator", "VIL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(layout_transition_cls, "enableTransitionType", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(layout_transition_cls, "disableTransitionType", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(layout_transition_cls, "setStartDelay", "VIJ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(layout_transition_cls, "addTransitionListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // android.view.ViewPropertyAnimator
    DxClass *vpa_cls = reg_class(vm, "Landroid/view/ViewPropertyAnimator;", obj);
    add_method(vpa_cls, "alpha", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "alphaBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "translationX", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "translationXBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "translationY", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "translationYBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "translationZ", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "translationZBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "scaleX", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "scaleXBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "scaleY", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "scaleYBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "rotation", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "rotationBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "rotationX", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "rotationXBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "rotationY", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "rotationYBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "x", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "xBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "y", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "yBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "z", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "zBy", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "setDuration", "LJ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "setStartDelay", "LJ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "setInterpolator", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "withStartAction", "LL", DX_ACC_PUBLIC, native_run_runnable_return_self, false);
    add_method(vpa_cls, "withEndAction", "LL", DX_ACC_PUBLIC, native_run_runnable_return_self, false);
    add_method(vpa_cls, "withLayer", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "setListener", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "setUpdateListener", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(vpa_cls, "start", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(vpa_cls, "cancel", "V", DX_ACC_PUBLIC, native_noop, false);

    // ============================================================
    // Additional methods on existing classes
    // ============================================================

    // Context: getTheme, obtainStyledAttributes, getContentResolver, registerReceiver
    add_method(context_cls, "getTheme", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(context_cls, "obtainStyledAttributes", "LLI", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(context_cls, "obtainStyledAttributes", "LL", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(context_cls, "obtainStyledAttributes", "LILI", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(context_cls, "getContentResolver", "L", DX_ACC_PUBLIC,
               native_context_get_content_resolver, false);
    add_method(context_cls, "registerReceiver", "LLL", DX_ACC_PUBLIC,
               native_context_register_receiver, false);
    add_method(context_cls, "unregisterReceiver", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(context_cls, "startActivity", "VL", DX_ACC_PUBLIC,
               native_start_activity, false);
    add_method(context_cls, "startService", "LL", DX_ACC_PUBLIC,
               native_context_start_service, false);
    add_method(context_cls, "getSharedPreferences", "LLI", DX_ACC_PUBLIC,
               native_context_get_shared_prefs, false);
    add_method(context_cls, "getClassLoader", "L", DX_ACC_PUBLIC,
               native_context_get_class_loader, false);
    add_method(context_cls, "getFilesDir", "L", DX_ACC_PUBLIC,
               native_context_get_files_dir, false);
    add_method(context_cls, "getCacheDir", "L", DX_ACC_PUBLIC,
               native_context_get_cache_dir, false);

    // View: padding getters, background, postOnAnimation, isLaidOut
    add_method(view_cls, "getPaddingLeft", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getPaddingTop", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getPaddingRight", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getPaddingBottom", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getPaddingStart", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getPaddingEnd", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "setBackgroundResource", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setBackground", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "postOnAnimation", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "isLaidOut", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(view_cls, "post", "ZL", DX_ACC_PUBLIC,
               native_view_post, false);
    add_method(view_cls, "postDelayed", "ZLJ", DX_ACC_PUBLIC,
               native_view_post_delayed, false);
    add_method(view_cls, "getWidth", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getHeight", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getMeasuredWidth", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getMeasuredHeight", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getLeft", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getTop", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getRight", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getBottom", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "setAlpha", "VF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "getAlpha", "F", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(view_cls, "setTranslationX", "VF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setTranslationY", "VF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setScaleX", "VF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setScaleY", "VF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setRotation", "VF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "animate", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(view_cls, "setFocusable", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setFocusableInTouchMode", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setContentDescription", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "setId", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(view_cls, "getId", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(view_cls, "getLayoutParams", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(view_cls, "getRootView", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(view_cls, "getResources", "L", DX_ACC_PUBLIC,
               native_context_get_resources, false);
    add_method(view_cls, "setOnTouchListener", "VL", DX_ACC_PUBLIC,
               native_view_set_on_touch_listener, false);
    add_method(view_cls, "setOnLongClickListener", "VL", DX_ACC_PUBLIC,
               native_view_set_on_long_click_listener, false);
    add_method(view_cls, "isEnabled", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(view_cls, "requestFocus", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(view_cls, "clearFocus", "V", DX_ACC_PUBLIC,
               native_noop, false);

    // ViewGroup: additional methods
    add_method(viewgroup_cls, "setOnHierarchyChangeListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(viewgroup_cls, "addView", "VLI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(viewgroup_cls, "addView", "VLL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(viewgroup_cls, "removeView", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(viewgroup_cls, "removeViewAt", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(viewgroup_cls, "indexOfChild", "IL", DX_ACC_PUBLIC,
               native_return_false, false);

    // Resources: additional methods
    add_method(resources_cls, "getConfiguration", "L", DX_ACC_PUBLIC,
               native_resources_get_configuration, false);
    add_method(resources_cls, "getInteger", "II", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(resources_cls, "getDimensionPixelSize", "II", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(resources_cls, "getBoolean", "ZI", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(resources_cls, "getDisplayMetrics", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(resources_cls, "getIdentifier", "ILLL", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(resources_cls, "obtainTypedArray", "LI", DX_ACC_PUBLIC,
               native_resources_obtain_typed_array, false);
    add_method(resources_cls, "getColorStateList", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(resources_cls, "getTextArray", "LI", DX_ACC_PUBLIC,
               native_resources_get_string_array, false);
    add_method(resources_cls, "getStringArray", "LI", DX_ACC_PUBLIC,
               native_resources_get_string_array, false);
    add_method(resources_cls, "getIntArray", "LI", DX_ACC_PUBLIC,
               native_resources_get_int_array, false);
    add_method(resources_cls, "getQuantityString", "LII", DX_ACC_PUBLIC,
               native_resources_get_quantity_string, false);
    add_method(resources_cls, "getQuantityString", "LIII", DX_ACC_PUBLIC,
               native_resources_get_quantity_string, false);

    // Handler: additional methods
    add_method(handler_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(handler_cls, "obtainMessage", "LII", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(handler_cls, "obtainMessage", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(handler_cls, "sendMessage", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(handler_cls, "removeCallbacksAndMessages", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(handler_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true); // Handler(Looper, Callback)
    add_method(handler_cls, "sendEmptyMessage", "ZI", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(handler_cls, "sendEmptyMessageDelayed", "ZIJ", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(handler_cls, "removeMessages", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(handler_cls, "removeCallbacks", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(handler_cls, "hasMessages", "ZI", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(handler_cls, "getLooper", "L", DX_ACC_PUBLIC,
               native_looper_get_main_looper, false);

    // Log: isLoggable
    add_method(log_cls, "isLoggable", "ZLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);
    add_method(log_cls, "wtf", "ILL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);

    // Intent: additional methods
    add_method(intent_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_intent_init_ctx_class, true);
    add_method(intent_cls, "setAction", "LL", DX_ACC_PUBLIC,
               native_intent_set_action, false);
    add_method(intent_cls, "setPackage", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(intent_cls, "setClass", "LLL", DX_ACC_PUBLIC,
               native_intent_set_class, false);
    add_method(intent_cls, "setFlags", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(intent_cls, "addFlags", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(intent_cls, "setData", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(intent_cls, "setType", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(intent_cls, "setComponent", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(intent_cls, "getParcelableExtra", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(intent_cls, "getSerializableExtra", "LL", DX_ACC_PUBLIC,
               native_return_null, false);

    // PackageManager: additional methods
    add_method(pm_cls, "queryIntentActivities", "LLI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pm_cls, "resolveActivity", "LLI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(pm_cls, "getApplicationInfo", "LLI", DX_ACC_PUBLIC,
               native_return_null, false);

    // SharedPreferences: methods for the interface (with real persistence)
    add_method(prefs_cls, "getBoolean", "ZLZ", DX_ACC_PUBLIC,
               native_prefs_get_boolean, false);
    add_method(prefs_cls, "getString", "LLL", DX_ACC_PUBLIC,
               native_prefs_get_string, false);
    add_method(prefs_cls, "getInt", "ILI", DX_ACC_PUBLIC,
               native_prefs_get_int, false);
    add_method(prefs_cls, "getLong", "JLJ", DX_ACC_PUBLIC,
               native_prefs_get_long, false);
    add_method(prefs_cls, "getFloat", "FLF", DX_ACC_PUBLIC,
               native_prefs_get_float, false);
    add_method(prefs_cls, "contains", "ZL", DX_ACC_PUBLIC,
               native_prefs_contains, false);
    add_method(prefs_cls, "edit", "L", DX_ACC_PUBLIC,
               native_prefs_edit, false);
    add_method(prefs_cls, "getAll", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(prefs_cls, "registerOnSharedPreferenceChangeListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // SharedPreferences$Editor (with real put/commit)
    DxClass *prefs_editor = reg_class(vm, "Landroid/content/SharedPreferences$Editor;", obj);
    prefs_editor->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(prefs_editor, "putBoolean", "LLZ", DX_ACC_PUBLIC,
               native_prefs_editor_put_boolean, false);
    add_method(prefs_editor, "putString", "LLL", DX_ACC_PUBLIC,
               native_prefs_editor_put_string, false);
    add_method(prefs_editor, "putInt", "LLI", DX_ACC_PUBLIC,
               native_prefs_editor_put_int, false);
    add_method(prefs_editor, "putLong", "LLJ", DX_ACC_PUBLIC,
               native_prefs_editor_put_long, false);
    add_method(prefs_editor, "putFloat", "LLF", DX_ACC_PUBLIC,
               native_prefs_editor_put_float, false);
    add_method(prefs_editor, "remove", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(prefs_editor, "clear", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(prefs_editor, "apply", "V", DX_ACC_PUBLIC,
               native_prefs_editor_commit, false);
    add_method(prefs_editor, "commit", "Z", DX_ACC_PUBLIC,
               native_prefs_editor_commit, false);

    // TextView: additional methods
    add_method(textview_cls, "setMovementMethod", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setTypeface", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setTypeface", "VLI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setTextSize", "VIF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setMaxLines", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setLines", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setEllipsize", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setSingleLine", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setInputType", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setCompoundDrawablesWithIntrinsicBounds", "VILLLL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setCompoundDrawablePadding", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "setPaintFlags", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(textview_cls, "getPaint", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(textview_cls, "getLineCount", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    // Activity: additional methods
    add_method(activity_cls, "getBaseContext", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(activity_cls, "startActivityForResult", "VLI", DX_ACC_PUBLIC,
               native_start_activity_for_result, false);
    add_method(activity_cls, "setResult", "VI", DX_ACC_PUBLIC,
               native_activity_set_result, false);
    add_method(activity_cls, "setResult", "VIL", DX_ACC_PUBLIC,
               native_activity_set_result, false);
    add_method(activity_cls, "invalidateOptionsMenu", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "setRequestedOrientation", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "getSupportFragmentManager", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(activity_cls, "getFragmentManager", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // Activity: menu support
    add_method(activity_cls, "onCreateOptionsMenu", "ZL", DX_ACC_PUBLIC,
               native_activity_on_create_options_menu, false);
    add_method(activity_cls, "onOptionsItemSelected", "ZL", DX_ACC_PUBLIC,
               native_activity_on_options_item_selected, false);
    add_method(activity_cls, "getMenuInflater", "L", DX_ACC_PUBLIC,
               native_activity_get_menu_inflater, false);
    add_method(activity_cls, "onPrepareOptionsMenu", "ZL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(activity_cls, "openOptionsMenu", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "closeOptionsMenu", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "onContextItemSelected", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(activity_cls, "registerForContextMenu", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "unregisterForContextMenu", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "onCreateContextMenu", "VLLL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(activity_cls, "onBackPressed", "V", DX_ACC_PUBLIC,
               native_activity_on_back_pressed, false);

    // String: contentEquals, format
    DxClass *str_cls_fw = dx_vm_find_class(vm, "Ljava/lang/String;");
    if (str_cls_fw) {
        add_method(str_cls_fw, "contentEquals", "ZL", DX_ACC_PUBLIC,
                   native_return_false, false);
        add_method(str_cls_fw, "format", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_null, true);
        add_method(str_cls_fw, "format", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_null, true);
    }

    // Math: min, max, abs
    DxClass *math_cls_fw = dx_vm_find_class(vm, "Ljava/lang/Math;");
    if (math_cls_fw) {
        add_method(math_cls_fw, "min", "III", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_math_min_int, true);
        add_method(math_cls_fw, "max", "III", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_math_max_int, true);
        add_method(math_cls_fw, "abs", "II", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_math_abs_int, true);
        add_method(math_cls_fw, "round", "IF", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_int_zero, true);
        add_method(math_cls_fw, "ceil", "DD", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_false, true);
        add_method(math_cls_fw, "floor", "DD", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_false, true);
        add_method(math_cls_fw, "sqrt", "DD", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_false, true);
        add_method(math_cls_fw, "pow", "DDD", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_false, true);
    }

    // Class: forName, getDeclaredField, reflection
    DxClass *class_cls_fw = dx_vm_find_class(vm, "Ljava/lang/Class;");
    if (class_cls_fw) {
        class_cls_fw->instance_field_count = 1;  // field[0] = DxClass* (as int)
        add_method(class_cls_fw, "forName", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_class_forName, true);
        add_method(class_cls_fw, "forName", "LLZL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_class_forName, true);  // 3-arg variant with initialize flag
        add_method(class_cls_fw, "getDeclaredField", "LL", DX_ACC_PUBLIC,
                   native_class_get_declared_field, false);
        add_method(class_cls_fw, "getDeclaredMethod", "LLL", DX_ACC_PUBLIC,
                   native_class_get_declared_method, false);
        add_method(class_cls_fw, "getDeclaredFields", "L", DX_ACC_PUBLIC,
                   native_class_get_declared_fields_fw, false);
        add_method(class_cls_fw, "getDeclaredMethods", "L", DX_ACC_PUBLIC,
                   native_class_get_declared_methods_fw, false);
        add_method(class_cls_fw, "isAssignableFrom", "ZL", DX_ACC_PUBLIC,
                   native_class_is_assignable_from, false);
        add_method(class_cls_fw, "newInstance", "L", DX_ACC_PUBLIC,
                   native_class_new_instance, false);
        // Annotation support (real implementations)
        add_method(class_cls_fw, "getAnnotation", "LL", DX_ACC_PUBLIC,
                   native_class_get_annotation_fw, false);
        add_method(class_cls_fw, "getAnnotations", "L", DX_ACC_PUBLIC,
                   native_class_get_annotations_fw, false);
        add_method(class_cls_fw, "getDeclaredAnnotations", "L", DX_ACC_PUBLIC,
                   native_class_get_annotations_fw, false);
        add_method(class_cls_fw, "isAnnotationPresent", "ZL", DX_ACC_PUBLIC,
                   native_class_is_annotation_present_fw, false);
        add_method(class_cls_fw, "getClassLoader", "L", DX_ACC_PUBLIC,
                   native_class_get_class_loader, false);
    }

    // List interface methods (commonly called via interface invoke)
    DxClass *list_cls_fw = dx_vm_find_class(vm, "Ljava/util/List;");
    if (list_cls_fw) {
        add_method(list_cls_fw, "size", "I", DX_ACC_PUBLIC,
                   native_return_int_zero, false);
        add_method(list_cls_fw, "get", "LI", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(list_cls_fw, "isEmpty", "Z", DX_ACC_PUBLIC,
                   native_return_true, false);
        add_method(list_cls_fw, "add", "ZL", DX_ACC_PUBLIC,
                   native_return_false, false);
        add_method(list_cls_fw, "iterator", "L", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(list_cls_fw, "contains", "ZL", DX_ACC_PUBLIC,
                   native_return_false, false);
    }

    // Map interface methods
    DxClass *map_cls_fw = dx_vm_find_class(vm, "Ljava/util/Map;");
    if (map_cls_fw) {
        add_method(map_cls_fw, "get", "LL", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(map_cls_fw, "put", "LLL", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(map_cls_fw, "containsKey", "ZL", DX_ACC_PUBLIC,
                   native_return_false, false);
        add_method(map_cls_fw, "size", "I", DX_ACC_PUBLIC,
                   native_return_int_zero, false);
        add_method(map_cls_fw, "isEmpty", "Z", DX_ACC_PUBLIC,
                   native_return_true, false);
        add_method(map_cls_fw, "keySet", "L", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(map_cls_fw, "values", "L", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(map_cls_fw, "entrySet", "L", DX_ACC_PUBLIC,
                   native_return_null, false);
    }

    // CharSequence interface methods
    DxClass *charseq_fw = dx_vm_find_class(vm, "Ljava/lang/CharSequence;");
    if (charseq_fw) {
        add_method(charseq_fw, "length", "I", DX_ACC_PUBLIC,
                   native_return_int_zero, false);
        add_method(charseq_fw, "toString", "L", DX_ACC_PUBLIC,
                   native_return_null, false);
    }

    // java.lang.reflect.Field
    DxClass *field_cls = reg_class(vm, "Ljava/lang/reflect/Field;", obj);
    field_cls->instance_field_count = 1;  // field[0] = field name string
    add_method(field_cls, "get", "LL", DX_ACC_PUBLIC,
               native_field_get, false);
    add_method(field_cls, "set", "VLL", DX_ACC_PUBLIC,
               native_field_set, false);
    add_method(field_cls, "setAccessible", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(field_cls, "getInt", "IL", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(field_cls, "getName", "L", DX_ACC_PUBLIC,
               native_field_get_name_fw, false);
    add_method(field_cls, "getType", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(field_cls, "getModifiers", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    // java.lang.reflect.Method
    DxClass *method_cls = reg_class(vm, "Ljava/lang/reflect/Method;", obj);
    method_cls->instance_field_count = 1;  // field[0] = DxMethod* (as int)
    add_method(method_cls, "invoke", "LLL", DX_ACC_PUBLIC,
               native_method_invoke, false);
    add_method(method_cls, "setAccessible", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    // Real annotation support
    add_method(method_cls, "getAnnotation", "LL", DX_ACC_PUBLIC,
               native_method_get_annotation_fw, false);
    add_method(method_cls, "isAnnotationPresent", "ZL", DX_ACC_PUBLIC,
               native_method_is_annotation_present_fw, false);
    add_method(method_cls, "getAnnotations", "L", DX_ACC_PUBLIC,
               native_method_get_annotations_fw, false);
    add_method(method_cls, "getDeclaredAnnotations", "L", DX_ACC_PUBLIC,
               native_method_get_annotations_fw, false);
    add_method(method_cls, "getParameterTypes", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(method_cls, "getReturnType", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(method_cls, "getName", "L", DX_ACC_PUBLIC,
               native_method_get_name_fw, false);
    add_method(method_cls, "getDeclaringClass", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(method_cls, "getModifiers", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    // android.text.method.LinkMovementMethod
    DxClass *linkmm_cls = reg_class(vm, "Landroid/text/method/LinkMovementMethod;", obj);
    add_method(linkmm_cls, "getInstance", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // ================================================================
    // PRODUCTION-GRADE FRAMEWORK EXPANSION
    // ================================================================

    // --- android.graphics.Color (field-backed with real implementations) ---
    DxClass *color_cls = reg_class(vm, "Landroid/graphics/Color;", obj);
    color_cls->instance_field_count = 1; // field[0] = packed color int
    add_method(color_cls, "parseColor", "IL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_color_parse, true);
    add_method(color_cls, "rgb", "IIII", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_color_rgb, true);
    add_method(color_cls, "argb", "IIIII", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_color_argb, true);
    add_method(color_cls, "alpha", "II", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_color_alpha_extract, true);
    add_method(color_cls, "red", "II", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_color_red, true);
    add_method(color_cls, "green", "II", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_color_green, true);
    add_method(color_cls, "blue", "II", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_color_blue, true);
    add_method(color_cls, "valueOf", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_color_valueof_int, true);
    add_method(color_cls, "valueOf", "LFFFF", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_color_valueof_floats, true);
    // Static color constant fields
    {
        const char *cnames[] = {
            "BLACK", "DKGRAY", "GRAY", "LTGRAY", "WHITE",
            "RED", "GREEN", "BLUE", "YELLOW", "CYAN", "MAGENTA", "TRANSPARENT"
        };
        DxValue cvals[] = {
            DX_INT_VALUE((int32_t)0xFF000000u), // BLACK
            DX_INT_VALUE((int32_t)0xFF444444u), // DKGRAY
            DX_INT_VALUE((int32_t)0xFF888888u), // GRAY
            DX_INT_VALUE((int32_t)0xFFCCCCCCu), // LTGRAY
            DX_INT_VALUE((int32_t)0xFFFFFFFFu), // WHITE
            DX_INT_VALUE((int32_t)0xFFFF0000u), // RED
            DX_INT_VALUE((int32_t)0xFF00FF00u), // GREEN
            DX_INT_VALUE((int32_t)0xFF0000FFu), // BLUE
            DX_INT_VALUE((int32_t)0xFFFFFF00u), // YELLOW
            DX_INT_VALUE((int32_t)0xFF00FFFFu), // CYAN
            DX_INT_VALUE((int32_t)0xFFFF00FFu), // MAGENTA
            DX_INT_VALUE(0)                      // TRANSPARENT
        };
        add_static_fields(color_cls, cnames, cvals, 12);
    }

    // --- android.graphics.Paint (field-backed with 7 fields) ---
    DxClass *paint_cls = reg_class(vm, "Landroid/graphics/Paint;", obj);
    {
        const char *paintfn[] = { "color", "textSize", "strokeWidth", "alpha", "antiAlias", "style", "typeface" };
        const char *paintft[] = { "I", "F", "F", "I", "Z", "Landroid/graphics/Paint$Style;", "Landroid/graphics/Typeface;" };
        setup_instance_fields(paint_cls, paintfn, paintft, PAINT_FIELD_COUNT);
    }
    add_method(paint_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_paint_init_fields, false);
    add_method(paint_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_paint_init_fields, false);
    add_method(paint_cls, "setColor", "VI", DX_ACC_PUBLIC, native_paint_setColor_fb, false);
    add_method(paint_cls, "getColor", "I", DX_ACC_PUBLIC, native_paint_getColor_fb, false);
    add_method(paint_cls, "setTextSize", "VF", DX_ACC_PUBLIC, native_paint_setTextSize_fb, false);
    add_method(paint_cls, "getTextSize", "F", DX_ACC_PUBLIC, native_paint_getTextSize_fb, false);
    add_method(paint_cls, "setStyle", "VL", DX_ACC_PUBLIC, native_paint_setStyle_fb, false);
    add_method(paint_cls, "getStyle", "L", DX_ACC_PUBLIC, native_paint_getStyle_fb, false);
    add_method(paint_cls, "setStrokeWidth", "VF", DX_ACC_PUBLIC, native_paint_setStrokeWidth_fb, false);
    add_method(paint_cls, "getStrokeWidth", "F", DX_ACC_PUBLIC, native_paint_getStrokeWidth_fb, false);
    add_method(paint_cls, "setAntiAlias", "VZ", DX_ACC_PUBLIC, native_paint_setAntiAlias_fb, false);
    add_method(paint_cls, "isAntiAlias", "Z", DX_ACC_PUBLIC, native_paint_isAntiAlias_fb, false);
    add_method(paint_cls, "setTypeface", "LL", DX_ACC_PUBLIC, native_paint_setTypeface_fb, false);
    add_method(paint_cls, "getTypeface", "L", DX_ACC_PUBLIC, native_paint_getTypeface_fb, false);
    add_method(paint_cls, "measureText", "FL", DX_ACC_PUBLIC, native_paint_measureText_fb, false);
    add_method(paint_cls, "setAlpha", "VI", DX_ACC_PUBLIC, native_paint_setAlpha_fb, false);
    add_method(paint_cls, "getAlpha", "I", DX_ACC_PUBLIC, native_paint_getAlpha_fb, false);
    add_method(paint_cls, "setXfermode", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(paint_cls, "setColorFilter", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(paint_cls, "setShader", "LL", DX_ACC_PUBLIC, native_return_null, false);

    // --- android.graphics.Paint$Style enum ---
    DxClass *paint_style_cls = reg_class(vm, "Landroid/graphics/Paint$Style;", obj);
    {
        const char *snames[] = { "FILL", "STROKE", "FILL_AND_STROKE" };
        DxValue svals[] = { DX_INT_VALUE(0), DX_INT_VALUE(1), DX_INT_VALUE(2) };
        add_static_fields(paint_style_cls, snames, svals, 3);
    }

    DxClass *canvas_cls = reg_class(vm, "Landroid/graphics/Canvas;", obj);
    add_method(canvas_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(canvas_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(canvas_cls, "drawRect", "VFFFFL", DX_ACC_PUBLIC, native_canvas_drawRect, false);
    add_method(canvas_cls, "drawCircle", "VFFFL", DX_ACC_PUBLIC, native_canvas_drawCircle, false);
    add_method(canvas_cls, "drawText", "VLFFL", DX_ACC_PUBLIC, native_canvas_drawText, false);
    add_method(canvas_cls, "drawLine", "VFFFFL", DX_ACC_PUBLIC, native_canvas_drawLine, false);
    add_method(canvas_cls, "drawRoundRect", "VLFFL", DX_ACC_PUBLIC, native_canvas_drawRoundRect, false);
    add_method(canvas_cls, "drawOval", "VLL", DX_ACC_PUBLIC, native_canvas_drawOval, false);
    add_method(canvas_cls, "drawBitmap", "VLFFL", DX_ACC_PUBLIC, native_noop, false);
    add_method(canvas_cls, "drawPath", "VLL", DX_ACC_PUBLIC, native_noop, false);
    add_method(canvas_cls, "drawColor", "VI", DX_ACC_PUBLIC, native_canvas_drawColor, false);
    add_method(canvas_cls, "save", "I", DX_ACC_PUBLIC, native_canvas_save, false);
    add_method(canvas_cls, "restore", "V", DX_ACC_PUBLIC, native_canvas_restore, false);
    add_method(canvas_cls, "translate", "VFF", DX_ACC_PUBLIC, native_canvas_translate, false);
    add_method(canvas_cls, "scale", "VFF", DX_ACC_PUBLIC, native_canvas_scale, false);
    add_method(canvas_cls, "rotate", "VF", DX_ACC_PUBLIC, native_canvas_rotate, false);
    add_method(canvas_cls, "clipRect", "ZFFFF", DX_ACC_PUBLIC, native_return_true, false);
    add_method(canvas_cls, "getWidth", "I", DX_ACC_PUBLIC, native_canvas_getWidth, false);
    add_method(canvas_cls, "getHeight", "I", DX_ACC_PUBLIC, native_canvas_getHeight, false);

    DxClass *bitmap_cls = reg_class(vm, "Landroid/graphics/Bitmap;", obj);
    bitmap_cls->instance_field_count = 2; // field[0] = width, field[1] = height
    add_method(bitmap_cls, "createBitmap", "LIII", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_bitmap_create, true);
    add_method(bitmap_cls, "getWidth", "I", DX_ACC_PUBLIC, native_bitmap_get_width, false);
    add_method(bitmap_cls, "getHeight", "I", DX_ACC_PUBLIC, native_bitmap_get_height, false);
    add_method(bitmap_cls, "recycle", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(bitmap_cls, "isRecycled", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(bitmap_cls, "getConfig", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(bitmap_cls, "compress", "ZLIF", DX_ACC_PUBLIC, native_return_true, false);
    add_method(bitmap_cls, "copy", "LLZ", DX_ACC_PUBLIC, native_bitmap_copy, false);

    DxClass *bitmap_factory_cls = reg_class(vm, "Landroid/graphics/BitmapFactory;", obj);
    add_method(bitmap_factory_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(bitmap_factory_cls, "decodeResource", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_bitmap_factory_decode, true);
    add_method(bitmap_factory_cls, "decodeStream", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_bitmap_factory_decode, true);
    add_method(bitmap_factory_cls, "decodeFile", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_bitmap_factory_decode, true);
    add_method(bitmap_factory_cls, "decodeByteArray", "LLII", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_bitmap_factory_decode, true);

    DxClass *bitmap_factory_options_cls = reg_class(vm, "Landroid/graphics/BitmapFactory$Options;", obj);
    bitmap_factory_options_cls->instance_field_count = 2; // inSampleSize, inJustDecodeBounds
    add_method(bitmap_factory_options_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);

    DxClass *bitmap_config_cls = reg_class(vm, "Landroid/graphics/Bitmap$Config;", obj);
    (void)bitmap_config_cls;

    // --- android.graphics.RectF (field-backed: left, top, right, bottom as float) ---
    DxClass *rectf_cls = reg_class(vm, "Landroid/graphics/RectF;", obj);
    {
        const char *rfnames[] = { "left", "top", "right", "bottom" };
        const char *rftypes[] = { "F", "F", "F", "F" };
        setup_instance_fields(rectf_cls, rfnames, rftypes, RECT_FIELD_COUNT);
    }
    add_method(rectf_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(rectf_cls, "<init>", "VFFFF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_rectf_init4, false);
    add_method(rectf_cls, "set", "VFFFF", DX_ACC_PUBLIC, native_rectf_init4, false);
    add_method(rectf_cls, "width", "F", DX_ACC_PUBLIC, native_rectf_width, false);
    add_method(rectf_cls, "height", "F", DX_ACC_PUBLIC, native_rectf_height, false);
    add_method(rectf_cls, "centerX", "F", DX_ACC_PUBLIC, native_rectf_centerX, false);
    add_method(rectf_cls, "centerY", "F", DX_ACC_PUBLIC, native_rectf_centerY, false);
    add_method(rectf_cls, "contains", "ZFF", DX_ACC_PUBLIC, native_rectf_contains_xy, false);
    add_method(rectf_cls, "isEmpty", "Z", DX_ACC_PUBLIC, native_rectf_isEmpty, false);

    DxClass *matrix_cls = reg_class(vm, "Landroid/graphics/Matrix;", obj);
    add_method(matrix_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(matrix_cls, "setTranslate", "VFF", DX_ACC_PUBLIC, native_noop, false);
    add_method(matrix_cls, "setScale", "VFF", DX_ACC_PUBLIC, native_noop, false);
    add_method(matrix_cls, "setRotate", "VF", DX_ACC_PUBLIC, native_noop, false);
    add_method(matrix_cls, "postTranslate", "ZFF", DX_ACC_PUBLIC, native_return_true, false);
    add_method(matrix_cls, "reset", "V", DX_ACC_PUBLIC, native_noop, false);

    DxClass *path_cls = reg_class(vm, "Landroid/graphics/Path;", obj);
    add_method(path_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(path_cls, "moveTo", "VFF", DX_ACC_PUBLIC, native_noop, false);
    add_method(path_cls, "lineTo", "VFF", DX_ACC_PUBLIC, native_noop, false);
    add_method(path_cls, "quadTo", "VFFFF", DX_ACC_PUBLIC, native_noop, false);
    add_method(path_cls, "cubicTo", "VFFFFFF", DX_ACC_PUBLIC, native_noop, false);
    add_method(path_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(path_cls, "reset", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(path_cls, "addRect", "VFFFFL", DX_ACC_PUBLIC, native_noop, false);
    add_method(path_cls, "addCircle", "VFFFL", DX_ACC_PUBLIC, native_noop, false);
    add_method(path_cls, "addRoundRect", "VFFFFL", DX_ACC_PUBLIC, native_noop, false);

    // --- android.graphics.Typeface (with static fields and create) ---
    DxClass *typeface_cls = reg_class(vm, "Landroid/graphics/Typeface;", obj);
    typeface_cls->instance_field_count = 1; // field[0] = style
    add_method(typeface_cls, "create", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_typeface_create_fb, true);
    add_method(typeface_cls, "create", "LII", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_typeface_create_fb, true);
    add_method(typeface_cls, "createFromAsset", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_typeface_create_fb, true);
    add_method(typeface_cls, "defaultFromStyle", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_typeface_create_fb, true);
    {
        // Static Typeface fields (alloc stub objects)
        DxObject *tf_default = dx_vm_alloc_object(vm, typeface_cls);
        DxObject *tf_default_bold = dx_vm_alloc_object(vm, typeface_cls);
        DxObject *tf_sans = dx_vm_alloc_object(vm, typeface_cls);
        DxObject *tf_serif = dx_vm_alloc_object(vm, typeface_cls);
        DxObject *tf_mono = dx_vm_alloc_object(vm, typeface_cls);
        const char *tfnames[] = { "DEFAULT", "DEFAULT_BOLD", "SANS_SERIF", "SERIF", "MONOSPACE" };
        DxValue tfvals[] = {
            tf_default ? DX_OBJ_VALUE(tf_default) : DX_NULL_VALUE,
            tf_default_bold ? DX_OBJ_VALUE(tf_default_bold) : DX_NULL_VALUE,
            tf_sans ? DX_OBJ_VALUE(tf_sans) : DX_NULL_VALUE,
            tf_serif ? DX_OBJ_VALUE(tf_serif) : DX_NULL_VALUE,
            tf_mono ? DX_OBJ_VALUE(tf_mono) : DX_NULL_VALUE
        };
        add_static_fields(typeface_cls, tfnames, tfvals, 5);
    }

    // --- android.graphics.PorterDuff / PorterDuff.Mode enum stubs ---
    DxClass *porterduff_cls = reg_class(vm, "Landroid/graphics/PorterDuff;", obj);
    (void)porterduff_cls;
    DxClass *porterduff_mode_cls = reg_class(vm, "Landroid/graphics/PorterDuff$Mode;", obj);
    {
        const char *pdnames[] = {
            "CLEAR", "SRC", "DST", "SRC_OVER", "DST_OVER",
            "SRC_IN", "DST_IN", "SRC_OUT", "DST_OUT",
            "SRC_ATOP", "DST_ATOP", "XOR", "ADD", "MULTIPLY", "SCREEN", "OVERLAY"
        };
        DxValue pdvals[] = {
            DX_INT_VALUE(0), DX_INT_VALUE(1), DX_INT_VALUE(2), DX_INT_VALUE(3),
            DX_INT_VALUE(4), DX_INT_VALUE(5), DX_INT_VALUE(6), DX_INT_VALUE(7),
            DX_INT_VALUE(8), DX_INT_VALUE(9), DX_INT_VALUE(10), DX_INT_VALUE(11),
            DX_INT_VALUE(12), DX_INT_VALUE(13), DX_INT_VALUE(14), DX_INT_VALUE(15)
        };
        add_static_fields(porterduff_mode_cls, pdnames, pdvals, 16);
    }

    DxClass *color_drawable_cls = reg_class(vm, "Landroid/graphics/drawable/ColorDrawable;", drawable_cls);
    add_method(color_drawable_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(color_drawable_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(color_drawable_cls, "setColor", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(color_drawable_cls, "getColor", "I", DX_ACC_PUBLIC, native_return_int_zero, false);

    DxClass *bitmap_drawable_cls = reg_class(vm, "Landroid/graphics/drawable/BitmapDrawable;", drawable_cls);
    add_method(bitmap_drawable_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(bitmap_drawable_cls, "getBitmap", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *gradient_drawable_cls = reg_class(vm, "Landroid/graphics/drawable/GradientDrawable;", drawable_cls);
    add_method(gradient_drawable_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(gradient_drawable_cls, "setColor", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(gradient_drawable_cls, "setCornerRadius", "VF", DX_ACC_PUBLIC, native_noop, false);
    add_method(gradient_drawable_cls, "setStroke", "VII", DX_ACC_PUBLIC, native_noop, false);
    add_method(gradient_drawable_cls, "setShape", "VI", DX_ACC_PUBLIC, native_noop, false);

    DxClass *shape_drawable_cls = reg_class(vm, "Landroid/graphics/drawable/ShapeDrawable;", drawable_cls);
    add_method(shape_drawable_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *layer_drawable_cls = reg_class(vm, "Landroid/graphics/drawable/LayerDrawable;", drawable_cls);
    add_method(layer_drawable_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *state_list_drawable_cls = reg_class(vm, "Landroid/graphics/drawable/StateListDrawable;", drawable_cls);
    add_method(state_list_drawable_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(state_list_drawable_cls, "addState", "VLL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *ripple_drawable_cls = reg_class(vm, "Landroid/graphics/drawable/RippleDrawable;", drawable_cls);
    add_method(ripple_drawable_cls, "<init>", "VLLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    // --- android.view.* (input events) ---
    DxClass *motion_event_cls = reg_class(vm, "Landroid/view/MotionEvent;", obj);
    add_method(motion_event_cls, "getAction", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(motion_event_cls, "getX", "F", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(motion_event_cls, "getY", "F", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(motion_event_cls, "getRawX", "F", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(motion_event_cls, "getRawY", "F", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(motion_event_cls, "getPointerCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(motion_event_cls, "getPointerId", "II", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(motion_event_cls, "getActionMasked", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(motion_event_cls, "getEventTime", "J", DX_ACC_PUBLIC, native_return_int_zero, false);
    {
        // MotionEvent action constants: ACTION_DOWN=0, ACTION_UP=1, ACTION_MOVE=2, ACTION_CANCEL=3
        const char *me_names[] = { "ACTION_DOWN", "ACTION_UP", "ACTION_MOVE", "ACTION_CANCEL" };
        DxValue me_vals[] = { DX_INT_VALUE(0), DX_INT_VALUE(1), DX_INT_VALUE(2), DX_INT_VALUE(3) };
        add_static_fields(motion_event_cls, me_names, me_vals, 4);
    }

    DxClass *key_event_cls = reg_class(vm, "Landroid/view/KeyEvent;", obj);
    add_method(key_event_cls, "getKeyCode", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(key_event_cls, "getAction", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(key_event_cls, "isCtrlPressed", "Z", DX_ACC_PUBLIC, native_return_false, false);

    DxClass *gesture_detector_cls = reg_class(vm, "Landroid/view/GestureDetector;", obj);
    add_method(gesture_detector_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(gesture_detector_cls, "onTouchEvent", "ZL", DX_ACC_PUBLIC, native_return_false, false);

    // --- android.view.Menu (interface, modeled as class) ---
    DxClass *menu_cls = reg_class(vm, "Landroid/view/Menu;", obj);
    menu_cls->instance_field_count = DX_MENU_FIELD_TOTAL;
    add_method(menu_cls, "add", "LIIIL", DX_ACC_PUBLIC, native_menu_add_full, false);
    add_method(menu_cls, "add", "LL", DX_ACC_PUBLIC, native_menu_add_simple, false);
    add_method(menu_cls, "findItem", "LI", DX_ACC_PUBLIC, native_menu_find_item, false);
    add_method(menu_cls, "size", "I", DX_ACC_PUBLIC, native_menu_size, false);
    add_method(menu_cls, "getItem", "LI", DX_ACC_PUBLIC, native_menu_get_item, false);
    add_method(menu_cls, "clear", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(menu_cls, "removeItem", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(menu_cls, "addSubMenu", "LIIIL", DX_ACC_PUBLIC, native_menu_add_sub_menu, false);
    add_method(menu_cls, "addSubMenu", "LL", DX_ACC_PUBLIC, native_menu_add_simple, false);
    add_method(menu_cls, "removeGroup", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(menu_cls, "setGroupVisible", "VIZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(menu_cls, "setGroupEnabled", "VIZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(menu_cls, "hasVisibleItems", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(menu_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    // --- android.view.SubMenu (extends Menu) ---
    DxClass *submenu_cls = reg_class(vm, "Landroid/view/SubMenu;", menu_cls);
    submenu_cls->instance_field_count = DX_MENU_FIELD_TOTAL;
    add_method(submenu_cls, "setHeaderTitle", "LL", DX_ACC_PUBLIC, native_submenu_set_header_title, false);
    add_method(submenu_cls, "setHeaderIcon", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(submenu_cls, "setIcon", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(submenu_cls, "getItem", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(submenu_cls, "clearHeader", "V", DX_ACC_PUBLIC, native_noop, false);

    // --- android.view.MenuItem ---
    DxClass *menu_item_cls = reg_class(vm, "Landroid/view/MenuItem;", obj);
    menu_item_cls->instance_field_count = DX_MENUITEM_FIELD_COUNT;
    add_method(menu_item_cls, "getItemId", "I", DX_ACC_PUBLIC, native_menuitem_get_item_id, false);
    add_method(menu_item_cls, "getTitle", "L", DX_ACC_PUBLIC, native_menuitem_get_title, false);
    add_method(menu_item_cls, "setTitle", "LL", DX_ACC_PUBLIC, native_menuitem_set_title, false);
    add_method(menu_item_cls, "setIcon", "LI", DX_ACC_PUBLIC, native_menuitem_set_icon_int, false);
    add_method(menu_item_cls, "setIcon", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(menu_item_cls, "setShowAsAction", "VI", DX_ACC_PUBLIC, native_menuitem_set_show_as_action, false);
    add_method(menu_item_cls, "setEnabled", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(menu_item_cls, "setVisible", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(menu_item_cls, "isEnabled", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(menu_item_cls, "isVisible", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(menu_item_cls, "setOnMenuItemClickListener", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(menu_item_cls, "getOrder", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(menu_item_cls, "getGroupId", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(menu_item_cls, "setActionView", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(menu_item_cls, "setActionView", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(menu_item_cls, "getActionView", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(menu_item_cls, "setChecked", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(menu_item_cls, "isChecked", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(menu_item_cls, "setCheckable", "LZ", DX_ACC_PUBLIC, native_return_self, false);

    // --- android.view.MenuInflater ---
    DxClass *menu_inflater_cls = reg_class(vm, "Landroid/view/MenuInflater;", obj);
    add_method(menu_inflater_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(menu_inflater_cls, "inflate", "VIL", DX_ACC_PUBLIC, native_noop, false);

    // --- android.view.animation ---
    DxClass *animation_cls = reg_class(vm, "Landroid/view/animation/Animation;", obj);
    add_method(animation_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(animation_cls, "setDuration", "VJ", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "getDuration", "J", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(animation_cls, "setFillAfter", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "setFillBefore", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "setFillEnabled", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "setInterpolator", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "setRepeatCount", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "setRepeatMode", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "setAnimationListener", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "setStartOffset", "VJ", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "start", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "startNow", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "cancel", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "reset", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(animation_cls, "hasStarted", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(animation_cls, "hasEnded", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(animation_cls, "setZAdjustment", "VI", DX_ACC_PUBLIC, native_noop, false);

    // android.view.animation.Animation$AnimationListener (interface)
    DxClass *anim_anim_listener_cls = reg_class(vm, "Landroid/view/animation/Animation$AnimationListener;", obj);
    add_method(anim_anim_listener_cls, "onAnimationStart", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_anim_listener_cls, "onAnimationEnd", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(anim_anim_listener_cls, "onAnimationRepeat", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *alpha_anim_cls = reg_class(vm, "Landroid/view/animation/AlphaAnimation;", animation_cls);
    add_method(alpha_anim_cls, "<init>", "VFF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *translate_anim_cls = reg_class(vm, "Landroid/view/animation/TranslateAnimation;", animation_cls);
    add_method(translate_anim_cls, "<init>", "VFFFF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(translate_anim_cls, "<init>", "VIFIFIFIF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *scale_anim_cls = reg_class(vm, "Landroid/view/animation/ScaleAnimation;", animation_cls);
    add_method(scale_anim_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(scale_anim_cls, "<init>", "VFFFF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(scale_anim_cls, "<init>", "VFFFFFFII", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *rotate_anim_cls = reg_class(vm, "Landroid/view/animation/RotateAnimation;", animation_cls);
    add_method(rotate_anim_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(rotate_anim_cls, "<init>", "VFF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(rotate_anim_cls, "<init>", "VFFFFIFIF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *anim_set_cls = reg_class(vm, "Landroid/view/animation/AnimationSet;", animation_cls);
    add_method(anim_set_cls, "<init>", "VZ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(anim_set_cls, "addAnimation", "VL", DX_ACC_PUBLIC, native_noop, false);

    // android.view.animation.LayoutAnimationController
    DxClass *layout_anim_ctrl_cls = reg_class(vm, "Landroid/view/animation/LayoutAnimationController;", obj);
    add_method(layout_anim_ctrl_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(layout_anim_ctrl_cls, "<init>", "VLF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(layout_anim_ctrl_cls, "setDelay", "VF", DX_ACC_PUBLIC, native_noop, false);
    add_method(layout_anim_ctrl_cls, "setOrder", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(layout_anim_ctrl_cls, "setInterpolator", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *anim_utils_cls = reg_class(vm, "Landroid/view/animation/AnimationUtils;", obj);
    add_method(anim_utils_cls, "loadAnimation", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(anim_utils_cls, "loadInterpolator", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_new_object, true);
    add_method(anim_utils_cls, "currentAnimationTimeMillis", "J", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_int_zero, true);

    // android.view.animation.Interpolator (interface) and implementations
    DxClass *interpolator_cls = reg_class(vm, "Landroid/view/animation/Interpolator;", obj);
    add_method(interpolator_cls, "getInterpolation", "FF", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    DxClass *accel_decel_cls = reg_class(vm, "Landroid/view/animation/AccelerateDecelerateInterpolator;", interpolator_cls);
    add_method(accel_decel_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    DxClass *linear_interp_cls = reg_class(vm, "Landroid/view/animation/LinearInterpolator;", interpolator_cls);
    add_method(linear_interp_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    DxClass *accel_interp_cls = reg_class(vm, "Landroid/view/animation/AccelerateInterpolator;", interpolator_cls);
    add_method(accel_interp_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(accel_interp_cls, "<init>", "VF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    DxClass *decel_interp_cls = reg_class(vm, "Landroid/view/animation/DecelerateInterpolator;", interpolator_cls);
    add_method(decel_interp_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(decel_interp_cls, "<init>", "VF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    DxClass *overshoot_interp_cls = reg_class(vm, "Landroid/view/animation/OvershootInterpolator;", interpolator_cls);
    add_method(overshoot_interp_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(overshoot_interp_cls, "<init>", "VF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    DxClass *bounce_interp_cls = reg_class(vm, "Landroid/view/animation/BounceInterpolator;", interpolator_cls);
    add_method(bounce_interp_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    DxClass *anticipate_interp_cls = reg_class(vm, "Landroid/view/animation/AnticipateInterpolator;", interpolator_cls);
    add_method(anticipate_interp_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(anticipate_interp_cls, "<init>", "VF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    DxClass *anticipate_overshoot_cls = reg_class(vm, "Landroid/view/animation/AnticipateOvershootInterpolator;", interpolator_cls);
    add_method(anticipate_overshoot_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    DxClass *cycle_interp_cls = reg_class(vm, "Landroid/view/animation/CycleInterpolator;", interpolator_cls);
    add_method(cycle_interp_cls, "<init>", "VF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    DxClass *path_interp_cls = reg_class(vm, "Landroid/view/animation/PathInterpolator;", interpolator_cls);
    add_method(path_interp_cls, "<init>", "VFF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(path_interp_cls, "<init>", "VFFFF", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(path_interp_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    // --- android.widget.AbsListView (extends ViewGroup) ---
    DxClass *abslistview_cls = reg_class(vm, "Landroid/widget/AbsListView;", viewgroup_cls);
    add_method(abslistview_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(abslistview_cls, "setSelector", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(abslistview_cls, "setFastScrollEnabled", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(abslistview_cls, "setChoiceMode", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(abslistview_cls, "setOnScrollListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    // --- android.widget.ListView (extends AbsListView) ---
    DxClass *listview_cls = reg_class(vm, "Landroid/widget/ListView;", abslistview_cls);
    listview_cls->instance_field_count = 1;  // field[0] = adapter
    add_method(listview_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(listview_cls, "setAdapter", "VL", DX_ACC_PUBLIC,
               native_listview_set_adapter, false);
    add_method(listview_cls, "getAdapter", "L", DX_ACC_PUBLIC,
               native_listview_get_adapter, false);
    add_method(listview_cls, "setOnItemClickListener", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(listview_cls, "setDivider", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(listview_cls, "setDividerHeight", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(listview_cls, "addHeaderView", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(listview_cls, "addFooterView", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(listview_cls, "setSelection", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(listview_cls, "smoothScrollToPosition", "VI", DX_ACC_PUBLIC, native_noop, false);

    // --- android.widget.GridView (extends AbsListView) ---
    DxClass *gridview_cls = reg_class(vm, "Landroid/widget/GridView;", abslistview_cls);
    gridview_cls->instance_field_count = 1;  // field[0] = adapter
    add_method(gridview_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(gridview_cls, "setAdapter", "VL", DX_ACC_PUBLIC,
               native_gridview_set_adapter, false);
    add_method(gridview_cls, "getAdapter", "L", DX_ACC_PUBLIC,
               native_gridview_get_adapter, false);
    add_method(gridview_cls, "setNumColumns", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(gridview_cls, "setColumnWidth", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(gridview_cls, "setHorizontalSpacing", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(gridview_cls, "setVerticalSpacing", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(gridview_cls, "setOnItemClickListener", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(gridview_cls, "setSelection", "VI", DX_ACC_PUBLIC, native_noop, false);

    // --- android.widget.BaseAdapter ---
    DxClass *baseadapter_cls = reg_class(vm, "Landroid/widget/BaseAdapter;", obj);
    add_method(baseadapter_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(baseadapter_cls, "getCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(baseadapter_cls, "getItem", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(baseadapter_cls, "getItemId", "JI", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(baseadapter_cls, "getView", "LILL", DX_ACC_PUBLIC, native_arrayadapter_getview, false);
    add_method(baseadapter_cls, "getItemViewType", "II", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(baseadapter_cls, "getViewTypeCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(baseadapter_cls, "notifyDataSetChanged", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(baseadapter_cls, "isEmpty", "Z", DX_ACC_PUBLIC, native_return_int_zero, false);

    // --- android.widget.ArrayAdapter (extends BaseAdapter) ---
    DxClass *arrayadapter_cls = reg_class(vm, "Landroid/widget/ArrayAdapter;", baseadapter_cls);
    add_method(arrayadapter_cls, "<init>", "VLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(arrayadapter_cls, "<init>", "VLIL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(arrayadapter_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(arrayadapter_cls, "getCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(arrayadapter_cls, "getItem", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(arrayadapter_cls, "getView", "LILL", DX_ACC_PUBLIC, native_arrayadapter_getview, false);
    add_method(arrayadapter_cls, "add", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(arrayadapter_cls, "clear", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(arrayadapter_cls, "remove", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(arrayadapter_cls, "insert", "VLI", DX_ACC_PUBLIC, native_noop, false);
    add_method(arrayadapter_cls, "notifyDataSetChanged", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(arrayadapter_cls, "getPosition", "IL", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(arrayadapter_cls, "setDropDownViewResource", "VI", DX_ACC_PUBLIC, native_noop, false);

    // android.widget.AdapterView (abstract, parent of Spinner/ListView/GridView)
    DxClass *adapterview_cls = reg_class(vm, "Landroid/widget/AdapterView;", viewgroup_cls);
    add_method(adapterview_cls, "setOnItemSelectedListener", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(adapterview_cls, "setOnItemClickListener", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(adapterview_cls, "getSelectedItem", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(adapterview_cls, "getSelectedItemPosition", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(adapterview_cls, "setSelection", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(adapterview_cls, "getAdapter", "L", DX_ACC_PUBLIC, native_return_null, false);

    // android.widget.AdapterView$OnItemSelectedListener (interface)
    DxClass *on_item_selected_cls = reg_class(vm, "Landroid/widget/AdapterView$OnItemSelectedListener;", obj);
    on_item_selected_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(on_item_selected_cls, "onItemSelected", "VLII", DX_ACC_PUBLIC, native_noop, false);
    add_method(on_item_selected_cls, "onNothingSelected", "VL", DX_ACC_PUBLIC, native_noop, false);

    // android.widget.AdapterView$OnItemClickListener (interface)
    DxClass *on_item_click_cls = reg_class(vm, "Landroid/widget/AdapterView$OnItemClickListener;", obj);
    on_item_click_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(on_item_click_cls, "onItemClick", "VLLII", DX_ACC_PUBLIC, native_noop, false);

    DxClass *spinner_cls = reg_class(vm, "Landroid/widget/Spinner;", adapterview_cls);
    spinner_cls->instance_field_count = 2; // adapter, listener
    add_method(spinner_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(spinner_cls, "setAdapter", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(spinner_cls, "setSelection", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(spinner_cls, "getSelectedItem", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(spinner_cls, "getSelectedItemPosition", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(spinner_cls, "setOnItemSelectedListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *seekbar_cls = reg_class(vm, "Landroid/widget/SeekBar;", view_cls);
    add_method(seekbar_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(seekbar_cls, "setMax", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(seekbar_cls, "setProgress", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(seekbar_cls, "getProgress", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(seekbar_cls, "getMax", "I", DX_ACC_PUBLIC, native_return_int_100, false);
    add_method(seekbar_cls, "setOnSeekBarChangeListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    // android.widget.CompoundButton (extends Button/TextView, parent of CheckBox/Switch/RadioButton)
    DxClass *compoundbutton_cls = reg_class(vm, "Landroid/widget/CompoundButton;", textview_cls);
    add_method(compoundbutton_cls, "isChecked", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(compoundbutton_cls, "setChecked", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(compoundbutton_cls, "toggle", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(compoundbutton_cls, "setOnCheckedChangeListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    // android.widget.CompoundButton$OnCheckedChangeListener (interface)
    DxClass *on_checked_change_cls = reg_class(vm, "Landroid/widget/CompoundButton$OnCheckedChangeListener;", obj);
    on_checked_change_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(on_checked_change_cls, "onCheckedChanged", "VLZ", DX_ACC_PUBLIC, native_noop, false);

    // android.widget.CheckBox (extends CompoundButton)
    DxClass *checkbox_cls = reg_class(vm, "Landroid/widget/CheckBox;", compoundbutton_cls);
    add_method(checkbox_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    // android.widget.Switch (extends CompoundButton)
    DxClass *switch_cls = reg_class(vm, "Landroid/widget/Switch;", compoundbutton_cls);
    add_method(switch_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(switch_cls, "setTextOn", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(switch_cls, "setTextOff", "VL", DX_ACC_PUBLIC, native_noop, false);

    // android.widget.ToggleButton (extends CompoundButton)
    DxClass *togglebutton_cls = reg_class(vm, "Landroid/widget/ToggleButton;", compoundbutton_cls);
    add_method(togglebutton_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(togglebutton_cls, "setTextOn", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(togglebutton_cls, "setTextOff", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *radiobutton_cls = reg_class(vm, "Landroid/widget/RadioButton;", compoundbutton_cls);
    add_method(radiobutton_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(radiobutton_cls, "setText", "VL", DX_ACC_PUBLIC, native_textview_set_text, false);

    DxClass *radiogroup_cls = reg_class(vm, "Landroid/widget/RadioGroup;", linearlayout_cls);
    add_method(radiogroup_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(radiogroup_cls, "check", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(radiogroup_cls, "getCheckedRadioButtonId", "I", DX_ACC_PUBLIC, native_return_int_neg_one, false);
    add_method(radiogroup_cls, "clearCheck", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(radiogroup_cls, "setOnCheckedChangeListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *numberpicker_cls = reg_class(vm, "Landroid/widget/NumberPicker;", view_cls);
    add_method(numberpicker_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(numberpicker_cls, "setMinValue", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(numberpicker_cls, "setMaxValue", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(numberpicker_cls, "setValue", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(numberpicker_cls, "getValue", "I", DX_ACC_PUBLIC, native_return_int_zero, false);

    DxClass *webview_cls = reg_class(vm, "Landroid/webkit/WebView;", viewgroup_cls);
    add_method(webview_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(webview_cls, "loadUrl", "VL", DX_ACC_PUBLIC, native_webview_load_url, false);
    add_method(webview_cls, "loadData", "VLLL", DX_ACC_PUBLIC, native_webview_load_data, false);
    add_method(webview_cls, "loadDataWithBaseURL", "VLLLLL", DX_ACC_PUBLIC, native_webview_load_data_with_base, false);
    add_method(webview_cls, "getSettings", "L", DX_ACC_PUBLIC, native_webview_get_settings, false);
    add_method(webview_cls, "setWebViewClient", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_cls, "setWebChromeClient", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_cls, "canGoBack", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(webview_cls, "canGoForward", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(webview_cls, "goBack", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_cls, "goForward", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_cls, "reload", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_cls, "stopLoading", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_cls, "addJavascriptInterface", "VLL", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_cls, "evaluateJavascript", "VLL", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_cls, "setOnClickListener", "VL", DX_ACC_PUBLIC, native_view_set_on_click_listener, false);

    DxClass *webview_client_cls = reg_class(vm, "Landroid/webkit/WebViewClient;", obj);
    add_method(webview_client_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(webview_client_cls, "onPageStarted", "VLLL", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_client_cls, "onPageFinished", "VLL", DX_ACC_PUBLIC, native_noop, false);
    add_method(webview_client_cls, "shouldOverrideUrlLoading", "ZLL", DX_ACC_PUBLIC, native_return_false, false);
    add_method(webview_client_cls, "onReceivedError", "VLILL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *web_chrome_client_cls = reg_class(vm, "Landroid/webkit/WebChromeClient;", obj);
    add_method(web_chrome_client_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(web_chrome_client_cls, "onProgressChanged", "VLI", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_chrome_client_cls, "onReceivedTitle", "VLL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *web_settings_cls = reg_class(vm, "Landroid/webkit/WebSettings;", obj);
    add_method(web_settings_cls, "setJavaScriptEnabled", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setDomStorageEnabled", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setUserAgentString", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setLoadWithOverviewMode", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setUseWideViewPort", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setBuiltInZoomControls", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setDisplayZoomControls", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setSupportZoom", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setMediaPlaybackRequiresUserGesture", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setCacheMode", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setMixedContentMode", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setAllowFileAccess", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "setJavaScriptCanOpenWindowsAutomatically", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(web_settings_cls, "getUserAgentString", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(web_settings_cls, "getCacheMode", "I", DX_ACC_PUBLIC, native_return_int_zero, false);

    DxClass *tablayout_cls = reg_class(vm, "Lcom/google/android/material/tabs/TabLayout;", viewgroup_cls);
    add_method(tablayout_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(tablayout_cls, "addTab", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(tablayout_cls, "newTab", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(tablayout_cls, "setOnTabSelectedListener", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(tablayout_cls, "setupWithViewPager", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *fab_cls = reg_class(vm, "Lcom/google/android/material/floatingactionbutton/FloatingActionButton;", view_cls);
    add_method(fab_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(fab_cls, "setOnClickListener", "VL", DX_ACC_PUBLIC, native_view_set_on_click_listener, false);
    add_method(fab_cls, "show", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(fab_cls, "hide", "V", DX_ACC_PUBLIC, native_noop, false);

    DxClass *bottom_nav_cls = reg_class(vm, "Lcom/google/android/material/bottomnavigation/BottomNavigationView;", viewgroup_cls);
    add_method(bottom_nav_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(bottom_nav_cls, "setOnNavigationItemSelectedListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *snackbar_cls = reg_class(vm, "Lcom/google/android/material/snackbar/Snackbar;", obj);
    add_method(snackbar_cls, "make", "LLII", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(snackbar_cls, "show", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(snackbar_cls, "setAction", "LLL", DX_ACC_PUBLIC, native_return_self, false);

    // --- SwipeRefreshLayout ---
    DxClass *swipe_refresh_cls = reg_class(vm, "Landroidx/swiperefreshlayout/widget/SwipeRefreshLayout;", viewgroup_cls);
    add_method(swipe_refresh_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(swipe_refresh_cls, "setOnRefreshListener", "VL", DX_ACC_PUBLIC,
               native_swipe_refresh_set_on_refresh_listener, false);
    add_method(swipe_refresh_cls, "setRefreshing", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(swipe_refresh_cls, "isRefreshing", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(swipe_refresh_cls, "setColorSchemeResources", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(swipe_refresh_cls, "setColorSchemeColors", "VI", DX_ACC_PUBLIC, native_noop, false);

    // SwipeRefreshLayout$OnRefreshListener (interface)
    DxClass *on_refresh_cls = reg_class(vm, "Landroidx/swiperefreshlayout/widget/SwipeRefreshLayout$OnRefreshListener;", obj);
    on_refresh_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    // Also register the legacy support library path
    DxClass *swipe_refresh_support_cls = reg_class(vm, "Landroid/support/v4/widget/SwipeRefreshLayout;", viewgroup_cls);
    add_method(swipe_refresh_support_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(swipe_refresh_support_cls, "setOnRefreshListener", "VL", DX_ACC_PUBLIC,
               native_swipe_refresh_set_on_refresh_listener, false);
    add_method(swipe_refresh_support_cls, "setRefreshing", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(swipe_refresh_support_cls, "isRefreshing", "Z", DX_ACC_PUBLIC, native_return_false, false);

    // --- android.app.* (services, dialogs, notifications) ---
    DxClass *application_cls = reg_class(vm, "Landroid/app/Application;", context_cls);
    add_method(application_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(application_cls, "onCreate", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(application_cls, "getApplicationContext", "L", DX_ACC_PUBLIC,
               native_return_self, false);

    DxClass *service_cls = reg_class(vm, "Landroid/app/Service;", context_cls);
    add_method(service_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(service_cls, "onCreate", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(service_cls, "onStartCommand", "ILII", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(service_cls, "onBind", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(service_cls, "onUnbind", "ZL", DX_ACC_PUBLIC, native_return_false, false);
    add_method(service_cls, "onRebind", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(service_cls, "onDestroy", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(service_cls, "stopSelf", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(service_cls, "stopSelf", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(service_cls, "startForeground", "VIL", DX_ACC_PUBLIC, native_noop, false);
    add_method(service_cls, "stopForeground", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(service_cls, "getApplication", "L", DX_ACC_PUBLIC, native_return_null, false);

    // android.app.IntentService (extends Service)
    DxClass *intent_svc_cls = reg_class(vm, "Landroid/app/IntentService;", service_cls);
    add_method(intent_svc_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(intent_svc_cls, "onHandleIntent", "VL", DX_ACC_PROTECTED | DX_ACC_ABSTRACT,
               native_noop, false);

    DxClass *alert_dialog_cls = reg_class(vm, "Landroid/app/AlertDialog;", dialog_cls);
    add_method(alert_dialog_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *alert_builder_cls = reg_class(vm, "Landroid/app/AlertDialog$Builder;", obj);
    add_method(alert_builder_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(alert_builder_cls, "setTitle", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(alert_builder_cls, "setMessage", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(alert_builder_cls, "setPositiveButton", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(alert_builder_cls, "setNegativeButton", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(alert_builder_cls, "setNeutralButton", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(alert_builder_cls, "setCancelable", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(alert_builder_cls, "setView", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(alert_builder_cls, "setItems", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(alert_builder_cls, "create", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(alert_builder_cls, "show", "L", DX_ACC_PUBLIC, native_return_null, false);

    // Also register the appcompat version
    DxClass *appcompat_alert_cls = reg_class(vm, "Landroidx/appcompat/app/AlertDialog;", dialog_cls);
    (void)appcompat_alert_cls;
    DxClass *appcompat_alert_builder_cls = reg_class(vm, "Landroidx/appcompat/app/AlertDialog$Builder;", obj);
    add_method(appcompat_alert_builder_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(appcompat_alert_builder_cls, "setTitle", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(appcompat_alert_builder_cls, "setMessage", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(appcompat_alert_builder_cls, "setPositiveButton", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(appcompat_alert_builder_cls, "setNegativeButton", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(appcompat_alert_builder_cls, "setCancelable", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(appcompat_alert_builder_cls, "setView", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(appcompat_alert_builder_cls, "create", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(appcompat_alert_builder_cls, "show", "L", DX_ACC_PUBLIC, native_return_null, false);

    // --- NotificationManager (enhanced with logging) ---
    DxClass *notification_mgr_cls = reg_class(vm, "Landroid/app/NotificationManager;", obj);
    add_method(notification_mgr_cls, "notify", "VIL", DX_ACC_PUBLIC, native_notifmgr_notify, false);
    add_method(notification_mgr_cls, "cancel", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(notification_mgr_cls, "cancelAll", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(notification_mgr_cls, "createNotificationChannel", "VL", DX_ACC_PUBLIC,
               native_notifmgr_create_channel, false);
    add_method(notification_mgr_cls, "areNotificationsEnabled", "Z", DX_ACC_PUBLIC,
               native_return_true, false);

    // --- Notification (with priority constants) ---
    DxClass *notification_cls = reg_class(vm, "Landroid/app/Notification;", obj);
    {
        const char *notif_field_names[] = {
            "PRIORITY_DEFAULT", "PRIORITY_LOW", "PRIORITY_MIN",
            "PRIORITY_HIGH", "PRIORITY_MAX"
        };
        DxValue notif_field_vals[] = {
            DX_INT_VALUE(0), DX_INT_VALUE(-1), DX_INT_VALUE(-2),
            DX_INT_VALUE(1), DX_INT_VALUE(2)
        };
        add_static_fields(notification_cls, notif_field_names, notif_field_vals, 5);
    }

    // --- Notification.Builder ---
    DxClass *notification_builder_cls = reg_class(vm, "Landroid/app/Notification$Builder;", obj);
    add_method(notification_builder_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(notification_builder_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(notification_builder_cls, "setContentTitle", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "setContentText", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "setSmallIcon", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "setLargeIcon", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "setPriority", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "setAutoCancel", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "setContentIntent", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "addAction", "LILL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "setStyle", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "setChannelId", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notification_builder_cls, "build", "L", DX_ACC_PUBLIC, native_return_new_object, false);

    // --- NotificationCompat.Builder (same API, androidx path) ---
    DxClass *notif_compat_builder_cls = reg_class(vm, "Landroidx/core/app/NotificationCompat$Builder;", obj);
    add_method(notif_compat_builder_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(notif_compat_builder_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(notif_compat_builder_cls, "setContentTitle", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "setContentText", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "setSmallIcon", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "setLargeIcon", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "setPriority", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "setAutoCancel", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "setContentIntent", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "addAction", "LILL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "setStyle", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "setChannelId", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(notif_compat_builder_cls, "build", "L", DX_ACC_PUBLIC, native_return_new_object, false);

    // NotificationCompat parent class
    DxClass *notif_compat_cls = reg_class(vm, "Landroidx/core/app/NotificationCompat;", obj);
    (void)notif_compat_cls;

    // --- NotificationChannel (field-backed: id, name, importance) ---
    DxClass *notification_channel_cls = reg_class(vm, "Landroid/app/NotificationChannel;", obj);
    add_method(notification_channel_cls, "<init>", "VLLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_notif_channel_init, false);
    add_method(notification_channel_cls, "setDescription", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(notification_channel_cls, "setSound", "VLL", DX_ACC_PUBLIC, native_noop, false);
    add_method(notification_channel_cls, "enableLights", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(notification_channel_cls, "enableVibration", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(notification_channel_cls, "setLightColor", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(notification_channel_cls, "setLockscreenVisibility", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(notification_channel_cls, "getId", "L", DX_ACC_PUBLIC,
               native_notif_channel_get_id, false);
    add_method(notification_channel_cls, "getName", "L", DX_ACC_PUBLIC,
               native_notif_channel_get_name, false);
    add_method(notification_channel_cls, "getImportance", "I", DX_ACC_PUBLIC,
               native_notif_channel_get_importance, false);

    // --- PendingIntent (with constants and factory methods returning stub objects) ---
    DxClass *pending_intent_cls = reg_class(vm, "Landroid/app/PendingIntent;", obj);
    add_method(pending_intent_cls, "getActivity", "LLILI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_pending_intent_factory, true);
    add_method(pending_intent_cls, "getBroadcast", "LLILI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_pending_intent_factory, true);
    add_method(pending_intent_cls, "getService", "LLILI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_pending_intent_factory, true);
    {
        const char *pi_field_names[] = {
            "FLAG_UPDATE_CURRENT", "FLAG_IMMUTABLE",
            "FLAG_ONE_SHOT", "FLAG_CANCEL_CURRENT", "FLAG_NO_CREATE"
        };
        DxValue pi_field_vals[] = {
            DX_INT_VALUE(0x08000000), DX_INT_VALUE(0x04000000),
            DX_INT_VALUE(0x40000000), DX_INT_VALUE(0x10000000), DX_INT_VALUE(0x20000000)
        };
        add_static_fields(pending_intent_cls, pi_field_names, pi_field_vals, 5);
    }

    // --- android.app.AlarmManager ---
    DxClass *alarm_mgr_cls = reg_class(vm, "Landroid/app/AlarmManager;", obj);
    add_method(alarm_mgr_cls, "set", "VIJL", DX_ACC_PUBLIC, native_noop, false);
    add_method(alarm_mgr_cls, "setRepeating", "VIJJL", DX_ACC_PUBLIC, native_noop, false);
    add_method(alarm_mgr_cls, "setExact", "VIJL", DX_ACC_PUBLIC, native_noop, false);
    add_method(alarm_mgr_cls, "setExactAndAllowWhileIdle", "VIJL", DX_ACC_PUBLIC, native_noop, false);
    add_method(alarm_mgr_cls, "setAndAllowWhileIdle", "VIJL", DX_ACC_PUBLIC, native_noop, false);
    add_method(alarm_mgr_cls, "setInexactRepeating", "VIJJL", DX_ACC_PUBLIC, native_noop, false);
    add_method(alarm_mgr_cls, "cancel", "VL", DX_ACC_PUBLIC, native_noop, false);
    {
        const char *am_names[] = { "RTC_WAKEUP", "RTC", "ELAPSED_REALTIME_WAKEUP", "ELAPSED_REALTIME",
                                   "INTERVAL_FIFTEEN_MINUTES", "INTERVAL_HALF_HOUR", "INTERVAL_HOUR", "INTERVAL_DAY" };
        DxValue am_vals[] = {
            DX_INT_VALUE(0), DX_INT_VALUE(1), DX_INT_VALUE(2), DX_INT_VALUE(3),
            DX_INT_VALUE(900000), DX_INT_VALUE(1800000), DX_INT_VALUE(3600000), DX_INT_VALUE(86400000)
        };
        add_static_fields(alarm_mgr_cls, am_names, am_vals, 8);
    }

    // --- android.app.job.JobScheduler ---
    DxClass *job_scheduler_cls = reg_class(vm, "Landroid/app/job/JobScheduler;", obj);
    add_method(job_scheduler_cls, "schedule", "IL", DX_ACC_PUBLIC, native_job_scheduler_schedule, false);
    add_method(job_scheduler_cls, "cancel", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(job_scheduler_cls, "cancelAll", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(job_scheduler_cls, "getAllPendingJobs", "L", DX_ACC_PUBLIC, native_return_null, false);
    {
        const char *js_names[] = { "RESULT_SUCCESS", "RESULT_FAILURE" };
        DxValue js_vals[] = { DX_INT_VALUE(1), DX_INT_VALUE(0) };
        add_static_fields(job_scheduler_cls, js_names, js_vals, 2);
    }

    // android.app.job.JobInfo
    DxClass *job_info_cls = reg_class(vm, "Landroid/app/job/JobInfo;", obj);
    (void)job_info_cls;

    // android.app.job.JobInfo$Builder
    DxClass *job_info_builder_cls = reg_class(vm, "Landroid/app/job/JobInfo$Builder;", obj);
    add_method(job_info_builder_cls, "<init>", "VIL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(job_info_builder_cls, "setRequiredNetworkType", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(job_info_builder_cls, "setPeriodic", "LJ", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(job_info_builder_cls, "setPersisted", "LZ", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(job_info_builder_cls, "setRequiresCharging", "LZ", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(job_info_builder_cls, "setRequiresDeviceIdle", "LZ", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(job_info_builder_cls, "setMinimumLatency", "LJ", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(job_info_builder_cls, "setOverrideDeadline", "LJ", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(job_info_builder_cls, "setBackoffCriteria", "LJI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(job_info_builder_cls, "setExtras", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(job_info_builder_cls, "build", "L", DX_ACC_PUBLIC,
               native_jobinfo_builder_build, false);
    {
        const char *ji_names[] = { "NETWORK_TYPE_NONE", "NETWORK_TYPE_ANY", "NETWORK_TYPE_UNMETERED",
                                   "NETWORK_TYPE_NOT_ROAMING", "NETWORK_TYPE_CELLULAR" };
        DxValue ji_vals[] = { DX_INT_VALUE(0), DX_INT_VALUE(1), DX_INT_VALUE(2),
                              DX_INT_VALUE(3), DX_INT_VALUE(4) };
        add_static_fields(job_info_builder_cls, ji_names, ji_vals, 5);
    }

    // android.app.job.JobService (abstract base)
    DxClass *job_service_cls = reg_class(vm, "Landroid/app/job/JobService;", obj);
    job_service_cls->access_flags = DX_ACC_ABSTRACT;
    add_method(job_service_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(job_service_cls, "onStartJob", "ZL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_false, false);
    add_method(job_service_cls, "onStopJob", "ZL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_false, false);
    add_method(job_service_cls, "jobFinished", "VLZ", DX_ACC_PUBLIC, native_noop, false);

    // --- android.accounts.AccountManager ---
    DxClass *account_mgr_cls = reg_class(vm, "Landroid/accounts/AccountManager;", obj);
    add_method(account_mgr_cls, "get", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_account_manager_get, true);
    add_method(account_mgr_cls, "getAccounts", "L", DX_ACC_PUBLIC,
               native_account_manager_get_accounts, false);
    add_method(account_mgr_cls, "getAccountsByType", "LL", DX_ACC_PUBLIC,
               native_account_manager_get_accounts, false);
    add_method(account_mgr_cls, "addAccountExplicitly", "ZLLL", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(account_mgr_cls, "removeAccount", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);

    // android.accounts.Account (field-backed: name, type)
    DxClass *account_cls = reg_class(vm, "Landroid/accounts/Account;", obj);
    account_cls->instance_field_count = 2; // field[0] = name, field[1] = type
    {
        const char *acct_names[] = { "name", "type" };
        const char *acct_types[] = { "Ljava/lang/String;", "Ljava/lang/String;" };
        setup_instance_fields(account_cls, acct_names, acct_types, 2);
    }
    add_method(account_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);

    // --- android.location.Location (field-backed) ---
    DxClass *location_cls = reg_class(vm, "Landroid/location/Location;", obj);
    add_method(location_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_location_init, false);
    add_method(location_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_location_init, false);
    add_method(location_cls, "getLatitude", "D", DX_ACC_PUBLIC, native_location_get_latitude, false);
    add_method(location_cls, "getLongitude", "D", DX_ACC_PUBLIC, native_location_get_longitude, false);
    add_method(location_cls, "getAltitude", "D", DX_ACC_PUBLIC, native_location_get_altitude, false);
    add_method(location_cls, "getAccuracy", "F", DX_ACC_PUBLIC, native_location_get_accuracy, false);
    add_method(location_cls, "getTime", "J", DX_ACC_PUBLIC, native_location_get_time, false);
    add_method(location_cls, "getProvider", "L", DX_ACC_PUBLIC, native_location_get_provider, false);
    add_method(location_cls, "setLatitude", "VD", DX_ACC_PUBLIC, native_location_set_latitude, false);
    add_method(location_cls, "setLongitude", "VD", DX_ACC_PUBLIC, native_location_set_longitude, false);
    add_method(location_cls, "setAltitude", "VD", DX_ACC_PUBLIC, native_location_set_altitude, false);
    add_method(location_cls, "setAccuracy", "VF", DX_ACC_PUBLIC, native_location_set_accuracy, false);
    add_method(location_cls, "setTime", "VJ", DX_ACC_PUBLIC, native_location_set_time, false);
    add_method(location_cls, "setProvider", "VL", DX_ACC_PUBLIC, native_location_set_provider, false);
    add_method(location_cls, "distanceTo", "FL", DX_ACC_PUBLIC, native_location_distance_to, false);

    // --- android.location.LocationListener (interface) ---
    DxClass *location_listener_cls = reg_class(vm, "Landroid/location/LocationListener;", obj);
    location_listener_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(location_listener_cls, "onLocationChanged", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(location_listener_cls, "onStatusChanged", "VLI", DX_ACC_PUBLIC, native_noop, false);
    add_method(location_listener_cls, "onProviderEnabled", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(location_listener_cls, "onProviderDisabled", "VL", DX_ACC_PUBLIC, native_noop, false);

    // --- android.location.Criteria ---
    DxClass *criteria_cls = reg_class(vm, "Landroid/location/Criteria;", obj);
    add_method(criteria_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(criteria_cls, "setAccuracy", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(criteria_cls, "setPowerRequirement", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(criteria_cls, "setAltitudeRequired", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(criteria_cls, "setCostAllowed", "VZ", DX_ACC_PUBLIC, native_noop, false);

    // --- android.location.LocationManager ---
    DxClass *location_mgr_cls = reg_class(vm, "Landroid/location/LocationManager;", obj);
    add_method(location_mgr_cls, "getLastKnownLocation", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(location_mgr_cls, "requestLocationUpdates", "VLJFL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(location_mgr_cls, "removeUpdates", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(location_mgr_cls, "isProviderEnabled", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(location_mgr_cls, "getBestProvider", "LLZ", DX_ACC_PUBLIC,
               native_locmgr_get_best_provider, false);
    {
        const char *loc_field_names[] = {
            "GPS_PROVIDER", "NETWORK_PROVIDER", "PASSIVE_PROVIDER"
        };
        // Static string fields - store as string objects won't work with add_static_fields
        // since it only stores DxValues. We use OBJ values with string objects.
        DxValue loc_field_vals[] = {
            DX_OBJ_VALUE(dx_vm_create_string(vm, "gps")),
            DX_OBJ_VALUE(dx_vm_create_string(vm, "network")),
            DX_OBJ_VALUE(dx_vm_create_string(vm, "passive"))
        };
        add_static_fields(location_mgr_cls, loc_field_names, loc_field_vals, 3);
    }

    DxClass *activity_mgr_cls = reg_class(vm, "Landroid/app/ActivityManager;", obj);
    add_method(activity_mgr_cls, "getMemoryInfo", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(activity_mgr_cls, "getRunningAppProcesses", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *keyguard_mgr_cls = reg_class(vm, "Landroid/app/KeyguardManager;", obj);
    add_method(keyguard_mgr_cls, "isKeyguardLocked", "Z", DX_ACC_PUBLIC, native_return_false, false);

    // --- android.os.* (system APIs) ---
    DxClass *message_cls = reg_class(vm, "Landroid/os/Message;", obj);
    add_method(message_cls, "obtain", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(message_cls, "obtainLL", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // android.os.Parcelable (interface)
    DxClass *parcelable_cls = reg_class(vm, "Landroid/os/Parcelable;", obj);
    parcelable_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(parcelable_cls, "describeContents", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(parcelable_cls, "writeToParcel", "VLI", DX_ACC_PUBLIC,
               native_noop, false);

    // Parcelable.Creator (interface)
    DxClass *creator_cls = reg_class(vm, "Landroid/os/Parcelable$Creator;", obj);
    creator_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(creator_cls, "createFromParcel", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(creator_cls, "newArray", "LI", DX_ACC_PUBLIC,
               native_return_null, false);

    // android.os.Parcel — field-backed data container
    DxClass *parcel_cls = reg_class(vm, "Landroid/os/Parcel;", obj);
    parcel_cls->instance_field_count = DX_PARCEL_FIELD_COUNT;
    add_method(parcel_cls, "obtain", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_parcel_obtain, true);
    add_method(parcel_cls, "recycle", "V", DX_ACC_PUBLIC, native_noop, false);
    // String read/write
    add_method(parcel_cls, "writeString", "VL", DX_ACC_PUBLIC,
               native_parcel_write_string, false);
    add_method(parcel_cls, "readString", "L", DX_ACC_PUBLIC,
               native_parcel_read_string, false);
    // Int read/write
    add_method(parcel_cls, "writeInt", "VI", DX_ACC_PUBLIC,
               native_parcel_write_int, false);
    add_method(parcel_cls, "readInt", "I", DX_ACC_PUBLIC,
               native_parcel_read_int, false);
    // Long read/write
    add_method(parcel_cls, "writeLong", "VJ", DX_ACC_PUBLIC,
               native_parcel_write_long, false);
    add_method(parcel_cls, "readLong", "J", DX_ACC_PUBLIC,
               native_parcel_read_long, false);
    // Float read/write
    add_method(parcel_cls, "writeFloat", "VF", DX_ACC_PUBLIC,
               native_parcel_write_float, false);
    add_method(parcel_cls, "readFloat", "F", DX_ACC_PUBLIC,
               native_parcel_read_float, false);
    // Double read/write
    add_method(parcel_cls, "writeDouble", "VD", DX_ACC_PUBLIC,
               native_parcel_write_double, false);
    add_method(parcel_cls, "readDouble", "D", DX_ACC_PUBLIC,
               native_parcel_read_double, false);
    // Byte read/write
    add_method(parcel_cls, "writeByte", "VB", DX_ACC_PUBLIC,
               native_parcel_write_byte, false);
    add_method(parcel_cls, "readByte", "B", DX_ACC_PUBLIC,
               native_parcel_read_byte, false);
    // Parcelable/Bundle (no-op stubs)
    add_method(parcel_cls, "writeParcelable", "VLI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(parcel_cls, "readParcelable", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(parcel_cls, "writeBundle", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(parcel_cls, "readBundle", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    // Position/size stubs
    add_method(parcel_cls, "dataSize", "I", DX_ACC_PUBLIC,
               native_parcel_data_size, false);
    add_method(parcel_cls, "dataPosition", "I", DX_ACC_PUBLIC,
               native_parcel_data_position, false);
    add_method(parcel_cls, "setDataPosition", "VI", DX_ACC_PUBLIC,
               native_parcel_set_data_position, false);
    // marshall/unmarshall stubs
    add_method(parcel_cls, "marshall", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(parcel_cls, "unmarshall", "VLII", DX_ACC_PUBLIC,
               native_noop, false);

    DxClass *environment_cls = reg_class(vm, "Landroid/os/Environment;", obj);
    add_method(environment_cls, "getExternalStorageDirectory", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_env_get_ext_storage, true);
    add_method(environment_cls, "getDataDirectory", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_env_get_data_dir, true);
    add_method(environment_cls, "getExternalStorageState", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_env_get_storage_state, true);
    add_method(environment_cls, "isExternalStorageEmulated", "Z", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_true, true);

    DxClass *process_cls = reg_class(vm, "Landroid/os/Process;", obj);
    add_method(process_cls, "myPid", "I", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_int_1000, true);
    add_method(process_cls, "myTid", "I", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_int_1000, true);
    add_method(process_cls, "myUid", "I", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_int_10000, true);

    // android.os.Vibrator
    DxClass *vibrator_cls = reg_class(vm, "Landroid/os/Vibrator;", obj);
    add_method(vibrator_cls, "vibrate", "VJ", DX_ACC_PUBLIC, native_noop, false);
    add_method(vibrator_cls, "vibrate", "VL", DX_ACC_PUBLIC, native_noop, false); // vibrate(VibrationEffect)
    add_method(vibrator_cls, "cancel", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(vibrator_cls, "hasVibrator", "Z", DX_ACC_PUBLIC, native_return_true, false);

    // android.os.VibrationEffect
    DxClass *vibration_effect_cls = reg_class(vm, "Landroid/os/VibrationEffect;", obj);
    add_method(vibration_effect_cls, "createOneShot", "LJI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_vibration_effect_create_one_shot, true);
    add_method(vibration_effect_cls, "createWaveform", "LLJI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_vibration_effect_create_one_shot, true);
    {
        const char *ve_names[] = { "DEFAULT_AMPLITUDE" };
        DxValue ve_vals[] = { DX_INT_VALUE(-1) };
        add_static_fields(vibration_effect_cls, ve_names, ve_vals, 1);
    }

    // android.os.PowerManager
    DxClass *power_mgr_cls = reg_class(vm, "Landroid/os/PowerManager;", obj);
    add_method(power_mgr_cls, "isInteractive", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(power_mgr_cls, "isIgnoringBatteryOptimizations", "ZL", DX_ACC_PUBLIC, native_return_true, false);
    add_method(power_mgr_cls, "newWakeLock", "LIL", DX_ACC_PUBLIC, native_power_new_wakelock, false);
    {
        const char *pm_names[] = { "PARTIAL_WAKE_LOCK", "FULL_WAKE_LOCK", "SCREEN_DIM_WAKE_LOCK", "SCREEN_BRIGHT_WAKE_LOCK" };
        DxValue pm_vals[] = { DX_INT_VALUE(1), DX_INT_VALUE(26), DX_INT_VALUE(6), DX_INT_VALUE(10) };
        add_static_fields(power_mgr_cls, pm_names, pm_vals, 4);
    }

    // android.os.PowerManager$WakeLock
    DxClass *wakelock_cls = reg_class(vm, "Landroid/os/PowerManager$WakeLock;", obj);
    add_method(wakelock_cls, "acquire", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(wakelock_cls, "acquire", "VJ", DX_ACC_PUBLIC, native_noop, false); // acquire(timeout)
    add_method(wakelock_cls, "release", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(wakelock_cls, "isHeld", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(wakelock_cls, "setReferenceCounted", "VZ", DX_ACC_PUBLIC, native_noop, false);

    // android.view.inputmethod.InputMethodManager
    DxClass *imm_cls = reg_class(vm, "Landroid/view/inputmethod/InputMethodManager;", obj);
    add_method(imm_cls, "hideSoftInputFromWindow", "ZLI", DX_ACC_PUBLIC, native_return_false, false);
    add_method(imm_cls, "showSoftInput", "ZLI", DX_ACC_PUBLIC, native_return_false, false);
    add_method(imm_cls, "toggleSoftInput", "VII", DX_ACC_PUBLIC, native_noop, false);
    add_method(imm_cls, "isActive", "Z", DX_ACC_PUBLIC, native_return_false, false);

    // android.content.ClipboardManager (field-backed: field[0] = stored ClipData)
    DxClass *clipboard_cls = reg_class(vm, "Landroid/content/ClipboardManager;", obj);
    clipboard_cls->instance_field_count = CLIPBOARD_FIELD_COUNT;
    add_method(clipboard_cls, "setPrimaryClip", "VL", DX_ACC_PUBLIC, native_clipboard_set_primary_clip, false);
    add_method(clipboard_cls, "getPrimaryClip", "L", DX_ACC_PUBLIC, native_clipboard_get_primary_clip, false);
    add_method(clipboard_cls, "hasPrimaryClip", "Z", DX_ACC_PUBLIC, native_clipboard_has_primary_clip, false);
    add_method(clipboard_cls, "getText", "L", DX_ACC_PUBLIC, native_return_null, false); // deprecated API
    add_method(clipboard_cls, "setText", "VL", DX_ACC_PUBLIC, native_noop, false);       // deprecated API
    add_method(clipboard_cls, "addPrimaryClipChangedListener", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(clipboard_cls, "removePrimaryClipChangedListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    // android.content.ClipData (field-backed: field[0] = label, field[1] = text)
    DxClass *clipdata_cls = reg_class(vm, "Landroid/content/ClipData;", obj);
    clipdata_cls->instance_field_count = CLIPDATA_FIELD_COUNT;
    add_method(clipdata_cls, "newPlainText", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_clipdata_new_plain_text, true);
    add_method(clipdata_cls, "getItemAt", "LI", DX_ACC_PUBLIC, native_clipdata_get_item_at, false);
    add_method(clipdata_cls, "getItemCount", "I", DX_ACC_PUBLIC, native_return_int_one, false);
    add_method(clipdata_cls, "getDescription", "L", DX_ACC_PUBLIC, native_return_null, false);

    // android.content.ClipData$Item (field[0] = text)
    DxClass *clipdata_item_cls = reg_class(vm, "Landroid/content/ClipData$Item;", obj);
    clipdata_item_cls->instance_field_count = 1;
    add_method(clipdata_item_cls, "getText", "L", DX_ACC_PUBLIC, native_clipdata_item_get_text, false);
    add_method(clipdata_item_cls, "getHtmlText", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(clipdata_item_cls, "getUri", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(clipdata_item_cls, "getIntent", "L", DX_ACC_PUBLIC, native_return_null, false);

    // android.media.AudioManager
    DxClass *audio_mgr_cls = reg_class(vm, "Landroid/media/AudioManager;", obj);
    add_method(audio_mgr_cls, "getStreamMaxVolume", "II", DX_ACC_PUBLIC, native_return_int_15, false);
    add_method(audio_mgr_cls, "getStreamVolume", "II", DX_ACC_PUBLIC, native_return_int_10, false);
    add_method(audio_mgr_cls, "setStreamVolume", "VIII", DX_ACC_PUBLIC, native_noop, false);
    add_method(audio_mgr_cls, "getRingerMode", "I", DX_ACC_PUBLIC, native_return_int_zero, false);

    DxClass *strictmode_cls = reg_class(vm, "Landroid/os/StrictMode;", obj);
    add_method(strictmode_cls, "setThreadPolicy", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(strictmode_cls, "setVmPolicy", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);

    // --- android.content.* ---
    DxClass *content_values_cls = reg_class(vm, "Landroid/content/ContentValues;", obj);
    content_values_cls->instance_field_count = DX_CV_FIELD_COUNT;
    add_method(content_values_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_cv_init, false);
    add_method(content_values_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_cv_init, false);
    add_method(content_values_cls, "put", "VLL", DX_ACC_PUBLIC, native_cv_put_string, false);
    add_method(content_values_cls, "put", "VLI", DX_ACC_PUBLIC, native_cv_put_int, false);
    add_method(content_values_cls, "put", "VLJ", DX_ACC_PUBLIC, native_cv_put_long, false);
    add_method(content_values_cls, "put", "VLF", DX_ACC_PUBLIC, native_cv_put_float, false);
    add_method(content_values_cls, "put", "VLD", DX_ACC_PUBLIC, native_cv_put_double, false);
    add_method(content_values_cls, "put", "VLZ", DX_ACC_PUBLIC, native_cv_put_boolean, false);
    add_method(content_values_cls, "get", "LL", DX_ACC_PUBLIC, native_cv_get, false);
    add_method(content_values_cls, "getAsString", "LL", DX_ACC_PUBLIC, native_cv_get_as_string, false);
    add_method(content_values_cls, "getAsInteger", "LL", DX_ACC_PUBLIC, native_cv_get_as_integer, false);
    add_method(content_values_cls, "getAsLong", "LL", DX_ACC_PUBLIC, native_cv_get_as_long, false);
    add_method(content_values_cls, "getAsFloat", "LL", DX_ACC_PUBLIC, native_cv_get_as_float, false);
    add_method(content_values_cls, "containsKey", "ZL", DX_ACC_PUBLIC, native_cv_contains_key, false);
    add_method(content_values_cls, "remove", "VL", DX_ACC_PUBLIC, native_cv_remove, false);
    add_method(content_values_cls, "clear", "V", DX_ACC_PUBLIC, native_cv_clear, false);
    add_method(content_values_cls, "size", "I", DX_ACC_PUBLIC, native_cv_size, false);
    add_method(content_values_cls, "keySet", "L", DX_ACC_PUBLIC, native_cv_key_set, false);

    DxClass *content_provider_cls = reg_class(vm, "Landroid/content/ContentProvider;", obj);
    content_provider_cls->access_flags = DX_ACC_ABSTRACT;
    add_method(content_provider_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(content_provider_cls, "onCreate", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(content_provider_cls, "query", "LLLLL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_null, false);
    add_method(content_provider_cls, "insert", "LLL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_null, false);
    add_method(content_provider_cls, "update", "ILLLL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_int_zero, false);
    add_method(content_provider_cls, "delete", "ILLL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_int_zero, false);
    add_method(content_provider_cls, "getType", "LL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_null, false);
    add_method(content_provider_cls, "getContext", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // android.content.ServiceConnection (interface)
    DxClass *svc_conn_cls = reg_class(vm, "Landroid/content/ServiceConnection;", obj);
    svc_conn_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(svc_conn_cls, "onServiceConnected", "VLL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_noop, false);
    add_method(svc_conn_cls, "onServiceDisconnected", "VL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_noop, false);

    DxClass *asset_mgr_cls = reg_class(vm, "Landroid/content/res/AssetManager;", obj);
    add_method(asset_mgr_cls, "open", "LL", DX_ACC_PUBLIC, native_asset_manager_open, false);
    add_method(asset_mgr_cls, "open", "LLI", DX_ACC_PUBLIC, native_asset_manager_open, false); // open(name, accessMode)
    add_method(asset_mgr_cls, "list", "LL", DX_ACC_PUBLIC, native_asset_manager_list, false);

    DxClass *pkg_info_cls = reg_class(vm, "Landroid/content/pm/PackageInfo;", obj);
    add_method(pkg_info_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *app_info_cls = reg_class(vm, "Landroid/content/pm/ApplicationInfo;", obj);
    add_method(app_info_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *component_name_cls = reg_class(vm, "Landroid/content/ComponentName;", obj);
    add_method(component_name_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(component_name_cls, "<init>", "VLC", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(component_name_cls, "getClassName", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(component_name_cls, "getPackageName", "L", DX_ACC_PUBLIC, native_return_null, false);

    // --- android.net.* ---
    DxClass *connectivity_mgr_cls = reg_class(vm, "Landroid/net/ConnectivityManager;", obj);
    add_method(connectivity_mgr_cls, "getActiveNetworkInfo", "L", DX_ACC_PUBLIC,
               native_connectivity_get_active_network_info, false);
    add_method(connectivity_mgr_cls, "getActiveNetwork", "L", DX_ACC_PUBLIC,
               native_connectivity_get_active_network, false);
    add_method(connectivity_mgr_cls, "isActiveNetworkMetered", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(connectivity_mgr_cls, "getNetworkCapabilities", "LL", DX_ACC_PUBLIC,
               native_return_new_object, false);
    add_method(connectivity_mgr_cls, "registerNetworkCallback", "VLL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(connectivity_mgr_cls, "unregisterNetworkCallback", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(connectivity_mgr_cls, "registerDefaultNetworkCallback", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    {
        const char *cm_names[] = { "TYPE_WIFI", "TYPE_MOBILE" };
        DxValue cm_vals[] = { DX_INT_VALUE(1), DX_INT_VALUE(0) };
        add_static_fields(connectivity_mgr_cls, cm_names, cm_vals, 2);
    }

    DxClass *network_info_cls = reg_class(vm, "Landroid/net/NetworkInfo;", obj);
    add_method(network_info_cls, "isConnected", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(network_info_cls, "isAvailable", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(network_info_cls, "isConnectedOrConnecting", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(network_info_cls, "getType", "I", DX_ACC_PUBLIC, native_return_int_one, false); // TYPE_WIFI=1
    add_method(network_info_cls, "getTypeName", "L", DX_ACC_PUBLIC, native_network_info_get_type_name, false);
    add_method(network_info_cls, "getSubtype", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(network_info_cls, "getExtraInfo", "L", DX_ACC_PUBLIC, native_return_null, false);

    // android.net.Network
    DxClass *network_cls = reg_class(vm, "Landroid/net/Network;", obj);
    add_method(network_cls, "openConnection", "LL", DX_ACC_PUBLIC, native_return_null, false);

    // android.net.NetworkCapabilities
    DxClass *net_caps_cls = reg_class(vm, "Landroid/net/NetworkCapabilities;", obj);
    add_method(net_caps_cls, "hasCapability", "ZI", DX_ACC_PUBLIC, native_return_true, false);
    add_method(net_caps_cls, "hasTransport", "ZI", DX_ACC_PUBLIC, native_return_true, false);
    {
        const char *nc_names[] = { "NET_CAPABILITY_INTERNET", "NET_CAPABILITY_VALIDATED", "TRANSPORT_WIFI", "TRANSPORT_CELLULAR" };
        DxValue nc_vals[] = { DX_INT_VALUE(12), DX_INT_VALUE(16), DX_INT_VALUE(1), DX_INT_VALUE(0) };
        add_static_fields(net_caps_cls, nc_names, nc_vals, 4);
    }

    // android.net.NetworkRequest / NetworkRequest.Builder
    DxClass *net_req_cls = reg_class(vm, "Landroid/net/NetworkRequest;", obj);
    (void)net_req_cls;
    DxClass *net_req_builder_cls = reg_class(vm, "Landroid/net/NetworkRequest$Builder;", obj);
    add_method(net_req_builder_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, true);
    add_method(net_req_builder_cls, "addCapability", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(net_req_builder_cls, "addTransportType", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(net_req_builder_cls, "build", "L", DX_ACC_PUBLIC, native_return_new_object, false);

    // android.net.ConnectivityManager$NetworkCallback
    DxClass *net_cb_cls = reg_class(vm, "Landroid/net/ConnectivityManager$NetworkCallback;", obj);
    add_method(net_cb_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, true);
    add_method(net_cb_cls, "onAvailable", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(net_cb_cls, "onLost", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(net_cb_cls, "onCapabilitiesChanged", "VLL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *uri_builder_cls = reg_class(vm, "Landroid/net/Uri$Builder;", obj);
    add_method(uri_builder_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(uri_builder_cls, "scheme", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(uri_builder_cls, "authority", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(uri_builder_cls, "path", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(uri_builder_cls, "appendPath", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(uri_builder_cls, "appendQueryParameter", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(uri_builder_cls, "build", "L", DX_ACC_PUBLIC, native_return_null, false);

    // --- android.database.* ---
    DxClass *cursor_cls = reg_class(vm, "Landroid/database/Cursor;", obj);
    cursor_cls->instance_field_count = DX_CURSOR_FIELD_COUNT;
    add_method(cursor_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_cursor_init_fields, false);
    add_method(cursor_cls, "moveToFirst", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cursor_cls, "moveToNext", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cursor_cls, "moveToPosition", "ZI", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cursor_cls, "moveToPrevious", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cursor_cls, "moveToLast", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cursor_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(cursor_cls, "getString", "LI", DX_ACC_PUBLIC, native_cursor_get_string, false);
    add_method(cursor_cls, "getInt", "II", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(cursor_cls, "getLong", "JI", DX_ACC_PUBLIC, native_return_long_zero, false);
    add_method(cursor_cls, "getFloat", "FI", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(cursor_cls, "getDouble", "DI", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(cursor_cls, "getBlob", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(cursor_cls, "getColumnIndex", "IL", DX_ACC_PUBLIC, native_return_int_neg_one, false);
    add_method(cursor_cls, "getColumnIndexOrThrow", "IL", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(cursor_cls, "getColumnName", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(cursor_cls, "getColumnCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(cursor_cls, "getCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(cursor_cls, "getPosition", "I", DX_ACC_PUBLIC, native_return_int_neg_one, false);
    add_method(cursor_cls, "isAfterLast", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(cursor_cls, "isBeforeFirst", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(cursor_cls, "isFirst", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cursor_cls, "isLast", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cursor_cls, "isClosed", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cursor_cls, "isNull", "ZI", DX_ACC_PUBLIC, native_return_true, false);

    DxClass *sqlite_db_cls = reg_class(vm, "Landroid/database/sqlite/SQLiteDatabase;", obj);
    sqlite_db_cls->instance_field_count = DX_SQLITE_FIELD_COUNT;
    add_method(sqlite_db_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_sqlite_db_init, false);
    add_method(sqlite_db_cls, "openOrCreateDatabase", "LLIL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_sqlite_return_stub_db_v2, true);
    add_method(sqlite_db_cls, "openDatabase", "LLIL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_sqlite_return_stub_db_v2, true);
    add_method(sqlite_db_cls, "getWritableDatabase", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(sqlite_db_cls, "getReadableDatabase", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(sqlite_db_cls, "execSQL", "VL", DX_ACC_PUBLIC, native_sqlite_exec_sql, false);
    add_method(sqlite_db_cls, "execSQL", "VLL", DX_ACC_PUBLIC, native_sqlite_exec_sql, false);
    add_method(sqlite_db_cls, "rawQuery", "LLL", DX_ACC_PUBLIC,
               native_sqlite_return_empty_cursor_v2, false);
    add_method(sqlite_db_cls, "query", "LLLLLLL", DX_ACC_PUBLIC,
               native_sqlite_return_empty_cursor_v2, false);
    add_method(sqlite_db_cls, "query", "LLLLLLLL", DX_ACC_PUBLIC,
               native_sqlite_return_empty_cursor_v2, false);
    add_method(sqlite_db_cls, "insert", "JLL", DX_ACC_PUBLIC, native_sqlite_insert, false);
    add_method(sqlite_db_cls, "insertWithOnConflict", "JLLLI", DX_ACC_PUBLIC, native_sqlite_insert, false);
    add_method(sqlite_db_cls, "replace", "JLL", DX_ACC_PUBLIC, native_sqlite_insert, false);
    add_method(sqlite_db_cls, "delete", "ILLL", DX_ACC_PUBLIC, native_sqlite_delete, false);
    add_method(sqlite_db_cls, "update", "ILLLL", DX_ACC_PUBLIC, native_sqlite_update, false);
    add_method(sqlite_db_cls, "close", "V", DX_ACC_PUBLIC, native_sqlite_close, false);
    add_method(sqlite_db_cls, "isOpen", "Z", DX_ACC_PUBLIC, native_sqlite_is_open, false);
    add_method(sqlite_db_cls, "beginTransaction", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(sqlite_db_cls, "beginTransactionNonExclusive", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(sqlite_db_cls, "setTransactionSuccessful", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(sqlite_db_cls, "endTransaction", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(sqlite_db_cls, "inTransaction", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(sqlite_db_cls, "getVersion", "I", DX_ACC_PUBLIC, native_sqlite_get_version, false);
    add_method(sqlite_db_cls, "setVersion", "VI", DX_ACC_PUBLIC, native_sqlite_set_version, false);
    add_method(sqlite_db_cls, "getPath", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *sqlite_helper_cls = reg_class(vm, "Landroid/database/sqlite/SQLiteOpenHelper;", obj);
    add_method(sqlite_helper_cls, "<init>", "VLLII", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(sqlite_helper_cls, "<init>", "VLLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(sqlite_helper_cls, "<init>", "VLLLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(sqlite_helper_cls, "getWritableDatabase", "L", DX_ACC_PUBLIC,
               native_sqlite_return_stub_db_v2, false);
    add_method(sqlite_helper_cls, "getReadableDatabase", "L", DX_ACC_PUBLIC,
               native_sqlite_return_stub_db_v2, false);
    add_method(sqlite_helper_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(sqlite_helper_cls, "onCreate", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(sqlite_helper_cls, "onUpgrade", "VLII", DX_ACC_PUBLIC, native_noop, false);
    add_method(sqlite_helper_cls, "onDowngrade", "VLII", DX_ACC_PUBLIC, native_noop, false);
    add_method(sqlite_helper_cls, "getDatabaseName", "L", DX_ACC_PUBLIC, native_return_null, false);

    // --- androidx.room.* (Room database support) ---
    // Room annotation stubs (just need to exist as annotation classes)
    DxClass *room_entity_cls = reg_class(vm, "Landroidx/room/Entity;", obj);
    room_entity_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_dao_cls = reg_class(vm, "Landroidx/room/Dao;", obj);
    room_dao_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_database_ann_cls = reg_class(vm, "Landroidx/room/Database;", obj);
    room_database_ann_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_query_cls = reg_class(vm, "Landroidx/room/Query;", obj);
    room_query_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_insert_cls = reg_class(vm, "Landroidx/room/Insert;", obj);
    room_insert_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_update_cls = reg_class(vm, "Landroidx/room/Update;", obj);
    room_update_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_delete_cls = reg_class(vm, "Landroidx/room/Delete;", obj);
    room_delete_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_primary_key_cls = reg_class(vm, "Landroidx/room/PrimaryKey;", obj);
    room_primary_key_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_column_info_cls = reg_class(vm, "Landroidx/room/ColumnInfo;", obj);
    room_column_info_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_ignore_cls = reg_class(vm, "Landroidx/room/Ignore;", obj);
    room_ignore_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_type_converter_cls = reg_class(vm, "Landroidx/room/TypeConverter;", obj);
    room_type_converter_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_type_converters_cls = reg_class(vm, "Landroidx/room/TypeConverters;", obj);
    room_type_converters_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_relation_cls = reg_class(vm, "Landroidx/room/Relation;", obj);
    room_relation_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_embedded_cls = reg_class(vm, "Landroidx/room/Embedded;", obj);
    room_embedded_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_foreign_key_cls = reg_class(vm, "Landroidx/room/ForeignKey;", obj);
    room_foreign_key_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_index_cls = reg_class(vm, "Landroidx/room/Index;", obj);
    room_index_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *room_transaction_cls = reg_class(vm, "Landroidx/room/Transaction;", obj);
    room_transaction_cls->access_flags = DX_ACC_ANNOTATION | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    // RoomDatabase (abstract base class)
    DxClass *room_db_cls = reg_class(vm, "Landroidx/room/RoomDatabase;", obj);
    room_db_cls->access_flags = DX_ACC_PUBLIC | DX_ACC_ABSTRACT;
    add_method(room_db_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(room_db_cls, "getOpenHelper", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(room_db_cls, "createOpenHelper", "L", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_null, false);
    add_method(room_db_cls, "clearAllTables", "V", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_noop, false);
    add_method(room_db_cls, "close", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(room_db_cls, "isOpen", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(room_db_cls, "runInTransaction", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(room_db_cls, "beginTransaction", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(room_db_cls, "endTransaction", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(room_db_cls, "setTransactionSuccessful", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(room_db_cls, "query", "LLL", DX_ACC_PUBLIC,
               native_sqlite_return_empty_cursor_v2, false);

    // RoomDatabase.Builder
    DxClass *room_builder_cls = reg_class(vm, "Landroidx/room/RoomDatabase$Builder;", obj);
    room_builder_cls->instance_field_count = DX_ROOM_BUILDER_FIELD_COUNT;
    add_method(room_builder_cls, "build", "L", DX_ACC_PUBLIC,
               native_room_builder_build, false);
    add_method(room_builder_cls, "fallbackToDestructiveMigration", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(room_builder_cls, "fallbackToDestructiveMigrationOnDowngrade", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(room_builder_cls, "addMigrations", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(room_builder_cls, "allowMainThreadQueries", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(room_builder_cls, "addCallback", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(room_builder_cls, "setJournalMode", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(room_builder_cls, "enableMultiInstanceInvalidation", "L", DX_ACC_PUBLIC,
               native_return_self, false);

    // Room utility class (static factory methods)
    DxClass *room_cls = reg_class(vm, "Landroidx/room/Room;", obj);
    add_method(room_cls, "databaseBuilder", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_room_database_builder, true);
    add_method(room_cls, "inMemoryDatabaseBuilder", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_room_database_builder, true);

    // Room Migration class
    DxClass *room_migration_cls = reg_class(vm, "Landroidx/room/migration/Migration;", obj);
    add_method(room_migration_cls, "<init>", "VII", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(room_migration_cls, "migrate", "VL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_noop, false);

    // Room RoomDatabase.Callback
    DxClass *room_callback_cls = reg_class(vm, "Landroidx/room/RoomDatabase$Callback;", obj);
    add_method(room_callback_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(room_callback_cls, "onCreate", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(room_callback_cls, "onOpen", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(room_callback_cls, "onDestructiveMigration", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    // --- androidx.recyclerview.* (critical for modern apps) ---
    DxClass *recycler_cls = reg_class(vm, "Landroidx/recyclerview/widget/RecyclerView;", viewgroup_cls);
    recycler_cls->instance_field_count = 1;  // field[0] = adapter object
    add_method(recycler_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_recyclerview_init, false);
    add_method(recycler_cls, "setAdapter", "VL", DX_ACC_PUBLIC, native_recyclerview_set_adapter, false);
    add_method(recycler_cls, "setLayoutManager", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(recycler_cls, "addItemDecoration", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(recycler_cls, "setHasFixedSize", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(recycler_cls, "scrollToPosition", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(recycler_cls, "getAdapter", "L", DX_ACC_PUBLIC, native_recyclerview_get_adapter, false);
    add_method(recycler_cls, "getLayoutManager", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(recycler_cls, "addOnScrollListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    // RecyclerView.Adapter — base class for user adapters
    DxClass *rv_adapter_cls = reg_class(vm, "Landroidx/recyclerview/widget/RecyclerView$Adapter;", obj);
    add_method(rv_adapter_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(rv_adapter_cls, "notifyDataSetChanged", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "notifyItemInserted", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "notifyItemRemoved", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "notifyItemChanged", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "notifyItemRangeChanged", "VII", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "notifyItemRangeInserted", "VII", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "notifyItemRangeRemoved", "VII", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "getItemCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(rv_adapter_cls, "getItemViewType", "II", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(rv_adapter_cls, "onCreateViewHolder", "LLI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rv_adapter_cls, "onBindViewHolder", "VLI", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "onViewRecycled", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "onAttachedToRecyclerView", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(rv_adapter_cls, "onDetachedFromRecyclerView", "VL", DX_ACC_PUBLIC, native_noop, false);

    // RecyclerView.ViewHolder — holds itemView in field[0]
    DxClass *rv_viewholder_cls = reg_class(vm, "Landroidx/recyclerview/widget/RecyclerView$ViewHolder;", obj);
    rv_viewholder_cls->instance_field_count = 1;  // field[0] = itemView
    add_method(rv_viewholder_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_viewholder_init, false);

    // RecyclerView.LayoutManager — base class
    DxClass *layout_mgr_cls = reg_class(vm, "Landroidx/recyclerview/widget/RecyclerView$LayoutManager;", obj);
    add_method(layout_mgr_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(layout_mgr_cls, "canScrollVertically", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(layout_mgr_cls, "canScrollHorizontally", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(layout_mgr_cls, "getItemCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(layout_mgr_cls, "findViewByPosition", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(layout_mgr_cls, "scrollToPosition", "VI", DX_ACC_PUBLIC, native_noop, false);

    // LinearLayoutManager extends LayoutManager
    DxClass *linear_lm_cls = reg_class(vm, "Landroidx/recyclerview/widget/LinearLayoutManager;", layout_mgr_cls);
    add_method(linear_lm_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(linear_lm_cls, "<init>", "VLIZ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(linear_lm_cls, "findFirstVisibleItemPosition", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(linear_lm_cls, "findLastVisibleItemPosition", "I", DX_ACC_PUBLIC, native_return_int_zero, false);

    // GridLayoutManager extends LinearLayoutManager
    DxClass *grid_lm_cls = reg_class(vm, "Landroidx/recyclerview/widget/GridLayoutManager;", linear_lm_cls);
    add_method(grid_lm_cls, "<init>", "VLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(grid_lm_cls, "getSpanCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(grid_lm_cls, "setSpanCount", "VI", DX_ACC_PUBLIC, native_noop, false);

    // StaggeredGridLayoutManager extends LayoutManager
    DxClass *staggered_lm_cls = reg_class(vm, "Landroidx/recyclerview/widget/StaggeredGridLayoutManager;", layout_mgr_cls);
    add_method(staggered_lm_cls, "<init>", "VII", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *item_decoration_cls = reg_class(vm, "Landroidx/recyclerview/widget/RecyclerView$ItemDecoration;", obj);
    add_method(item_decoration_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *divider_item_cls = reg_class(vm, "Landroidx/recyclerview/widget/DividerItemDecoration;", item_decoration_cls);
    add_method(divider_item_cls, "<init>", "VLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    // --- androidx.viewpager.* ---
    DxClass *viewpager_cls = reg_class(vm, "Landroidx/viewpager/widget/ViewPager;", viewgroup_cls);
    add_method(viewpager_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(viewpager_cls, "setAdapter", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(viewpager_cls, "setCurrentItem", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(viewpager_cls, "addOnPageChangeListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *pager_adapter_cls = reg_class(vm, "Landroidx/viewpager/widget/PagerAdapter;", obj);
    add_method(pager_adapter_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(pager_adapter_cls, "getCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(pager_adapter_cls, "notifyDataSetChanged", "V", DX_ACC_PUBLIC, native_noop, false);

    DxClass *frag_pager_adapter_cls = reg_class(vm, "Landroidx/fragment/app/FragmentPagerAdapter;", pager_adapter_cls);
    add_method(frag_pager_adapter_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(frag_pager_adapter_cls, "<init>", "VLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *viewpager2_cls = reg_class(vm, "Landroidx/viewpager2/widget/ViewPager2;", viewgroup_cls);
    add_method(viewpager2_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(viewpager2_cls, "setAdapter", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(viewpager2_cls, "registerOnPageChangeCallback", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *frag_state_adapter_cls = reg_class(vm, "Landroidx/viewpager2/adapter/FragmentStateAdapter;", obj);
    add_method(frag_state_adapter_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    // --- androidx.lifecycle.* (expanded) ---
    DxClass *livedata_cls = dx_vm_find_class(vm, "Landroidx/lifecycle/LiveData;");
    if (livedata_cls) {
        add_method(livedata_cls, "getValue", "L", DX_ACC_PUBLIC, native_livedata_get_value, false);
        add_method(livedata_cls, "observe", "VLL", DX_ACC_PUBLIC, native_livedata_observe, false);
        add_method(livedata_cls, "observeForever", "VL", DX_ACC_PUBLIC, native_livedata_observe_forever, false);
        add_method(livedata_cls, "removeObserver", "VL", DX_ACC_PUBLIC, native_noop, false);
        add_method(livedata_cls, "hasObservers", "Z", DX_ACC_PUBLIC, native_return_false, false);
    }
    DxClass *mutable_livedata_cls = dx_vm_find_class(vm, "Landroidx/lifecycle/MutableLiveData;");
    if (mutable_livedata_cls) {
        add_method(mutable_livedata_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                   native_noop, false);
        add_method(mutable_livedata_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                   native_mutable_livedata_init_val, false);
        add_method(mutable_livedata_cls, "setValue", "VL", DX_ACC_PUBLIC, native_livedata_set_value, false);
        add_method(mutable_livedata_cls, "postValue", "VL", DX_ACC_PUBLIC, native_livedata_set_value, false);
        add_method(mutable_livedata_cls, "getValue", "L", DX_ACC_PUBLIC, native_livedata_get_value, false);
    }
    DxClass *viewmodel_cls = dx_vm_find_class(vm, "Landroidx/lifecycle/ViewModel;");
    if (viewmodel_cls) {
        add_method(viewmodel_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                   native_noop, false);
        add_method(viewmodel_cls, "onCleared", "V", DX_ACC_PUBLIC, native_noop, false);
    }

    DxClass *viewmodel_provider_cls = reg_class(vm, "Landroidx/lifecycle/ViewModelProvider;", obj);
    add_method(viewmodel_provider_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(viewmodel_provider_cls, "get", "LL", DX_ACC_PUBLIC, native_viewmodelprovider_get, false);

    DxClass *observer_cls = reg_class(vm, "Landroidx/lifecycle/Observer;", obj);
    add_method(observer_cls, "onChanged", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *lifecycle_cls = dx_vm_find_class(vm, "Landroidx/lifecycle/Lifecycle;");
    if (lifecycle_cls) {
        add_method(lifecycle_cls, "addObserver", "VL", DX_ACC_PUBLIC, native_noop, false);
        add_method(lifecycle_cls, "removeObserver", "VL", DX_ACC_PUBLIC, native_noop, false);
        add_method(lifecycle_cls, "getCurrentState", "L", DX_ACC_PUBLIC, native_return_null, false);
    }

    DxClass *lifecycle_owner_cls = dx_vm_find_class(vm, "Landroidx/lifecycle/LifecycleOwner;");
    if (lifecycle_owner_cls) {
        add_method(lifecycle_owner_cls, "getLifecycle", "L", DX_ACC_PUBLIC, native_return_null, false);
    }

    DxClass *vm_store_owner_cls = dx_vm_find_class(vm, "Landroidx/lifecycle/ViewModelStoreOwner;");
    if (vm_store_owner_cls) {
        add_method(vm_store_owner_cls, "getViewModelStore", "L", DX_ACC_PUBLIC, native_return_null, false);
    }

    DxClass *vm_store_cls = dx_vm_find_class(vm, "Landroidx/lifecycle/ViewModelStore;");
    if (vm_store_cls) {
        add_method(vm_store_cls, "clear", "V", DX_ACC_PUBLIC, native_noop, false);
    }

    // --- Lifecycle State/Event enums and Observer interfaces ---
    DxClass *lifecycle_state_cls = reg_class(vm, "Landroidx/lifecycle/Lifecycle$State;", obj);
    lifecycle_state_cls->access_flags = DX_ACC_PUBLIC | DX_ACC_ENUM;
    // Register enum constants as static fields conceptually; apps use compareTo/isAtLeast
    add_method(lifecycle_state_cls, "isAtLeast", "ZL", DX_ACC_PUBLIC, native_return_true, false);

    DxClass *lifecycle_event_cls = reg_class(vm, "Landroidx/lifecycle/Lifecycle$Event;", obj);
    lifecycle_event_cls->access_flags = DX_ACC_PUBLIC | DX_ACC_ENUM;

    DxClass *lifecycle_observer_cls = reg_class(vm, "Landroidx/lifecycle/LifecycleObserver;", obj);
    lifecycle_observer_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *default_lifecycle_observer_cls = reg_class(vm, "Landroidx/lifecycle/DefaultLifecycleObserver;", lifecycle_observer_cls);
    default_lifecycle_observer_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(default_lifecycle_observer_cls, "onCreate", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(default_lifecycle_observer_cls, "onStart", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(default_lifecycle_observer_cls, "onResume", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(default_lifecycle_observer_cls, "onPause", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(default_lifecycle_observer_cls, "onStop", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(default_lifecycle_observer_cls, "onDestroy", "VL", DX_ACC_PUBLIC, native_noop, false);

    // --- androidx.annotation stubs ---
    DxClass *ann_nonnull = reg_class(vm, "Landroidx/annotation/NonNull;", obj);
    ann_nonnull->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;
    DxClass *ann_nullable = reg_class(vm, "Landroidx/annotation/Nullable;", obj);
    ann_nullable->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;
    DxClass *ann_stringres = reg_class(vm, "Landroidx/annotation/StringRes;", obj);
    ann_stringres->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;
    DxClass *ann_drawableres = reg_class(vm, "Landroidx/annotation/DrawableRes;", obj);
    ann_drawableres->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;
    DxClass *ann_colorres = reg_class(vm, "Landroidx/annotation/ColorRes;", obj);
    ann_colorres->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;
    DxClass *ann_intdef = reg_class(vm, "Landroidx/annotation/IntDef;", obj);
    ann_intdef->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;
    DxClass *ann_stringdef = reg_class(vm, "Landroidx/annotation/StringDef;", obj);
    ann_stringdef->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *savedstate_cls = reg_class(vm, "Landroidx/savedstate/SavedStateRegistryOwner;", obj);
    (void)savedstate_cls;
    DxClass *savedstate_reg_cls = reg_class(vm, "Landroidx/savedstate/SavedStateRegistry;", obj);
    add_method(savedstate_reg_cls, "consumeRestoredStateForKey", "LL", DX_ACC_PUBLIC,
               native_return_null, false);

    // --- androidx.core.* ---
    DxClass *compat_cls = reg_class(vm, "Landroidx/core/content/ContextCompat;", obj);
    add_method(compat_cls, "getColor", "ILI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_int_zero, true);
    add_method(compat_cls, "getDrawable", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(compat_cls, "checkSelfPermission", "ILL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_compat_check_permission, true);
    add_method(compat_cls, "startForegroundService", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);

    // androidx.core.app.ActivityCompat
    DxClass *activity_compat_cls = reg_class(vm, "Landroidx/core/app/ActivityCompat;", obj);
    add_method(activity_compat_cls, "requestPermissions", "VLLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_compat_request_permissions, true);
    add_method(activity_compat_cls, "shouldShowRequestPermissionRationale", "ZLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);
    add_method(activity_compat_cls, "checkSelfPermission", "ILL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_compat_check_permission, true);

    // android.Manifest$permission — string constants for common permissions
    DxClass *manifest_perm_cls = reg_class(vm, "Landroid/Manifest$permission;", obj);
    {
        DxObject *s_internet = dx_vm_create_string(vm, "android.permission.INTERNET");
        DxObject *s_net_state = dx_vm_create_string(vm, "android.permission.ACCESS_NETWORK_STATE");
        DxObject *s_wifi = dx_vm_create_string(vm, "android.permission.ACCESS_WIFI_STATE");
        DxObject *s_vibrate = dx_vm_create_string(vm, "android.permission.VIBRATE");
        DxObject *s_wake = dx_vm_create_string(vm, "android.permission.WAKE_LOCK");
        DxObject *s_camera = dx_vm_create_string(vm, "android.permission.CAMERA");
        DxObject *s_fine_loc = dx_vm_create_string(vm, "android.permission.ACCESS_FINE_LOCATION");
        DxObject *s_coarse_loc = dx_vm_create_string(vm, "android.permission.ACCESS_COARSE_LOCATION");
        DxObject *s_read_cont = dx_vm_create_string(vm, "android.permission.READ_CONTACTS");
        DxObject *s_write_cont = dx_vm_create_string(vm, "android.permission.WRITE_CONTACTS");
        DxObject *s_read_ext = dx_vm_create_string(vm, "android.permission.READ_EXTERNAL_STORAGE");
        DxObject *s_write_ext = dx_vm_create_string(vm, "android.permission.WRITE_EXTERNAL_STORAGE");
        DxObject *s_record = dx_vm_create_string(vm, "android.permission.RECORD_AUDIO");
        DxObject *s_phone = dx_vm_create_string(vm, "android.permission.CALL_PHONE");
        DxObject *s_sms = dx_vm_create_string(vm, "android.permission.SEND_SMS");
        DxObject *s_fg_svc = dx_vm_create_string(vm, "android.permission.FOREGROUND_SERVICE");
        const char *mp_names[] = {
            "INTERNET", "ACCESS_NETWORK_STATE", "ACCESS_WIFI_STATE",
            "VIBRATE", "WAKE_LOCK", "CAMERA",
            "ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION",
            "READ_CONTACTS", "WRITE_CONTACTS",
            "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE",
            "RECORD_AUDIO", "CALL_PHONE", "SEND_SMS",
            "FOREGROUND_SERVICE"
        };
        DxValue mp_vals[] = {
            s_internet ? DX_OBJ_VALUE(s_internet) : DX_NULL_VALUE,
            s_net_state ? DX_OBJ_VALUE(s_net_state) : DX_NULL_VALUE,
            s_wifi ? DX_OBJ_VALUE(s_wifi) : DX_NULL_VALUE,
            s_vibrate ? DX_OBJ_VALUE(s_vibrate) : DX_NULL_VALUE,
            s_wake ? DX_OBJ_VALUE(s_wake) : DX_NULL_VALUE,
            s_camera ? DX_OBJ_VALUE(s_camera) : DX_NULL_VALUE,
            s_fine_loc ? DX_OBJ_VALUE(s_fine_loc) : DX_NULL_VALUE,
            s_coarse_loc ? DX_OBJ_VALUE(s_coarse_loc) : DX_NULL_VALUE,
            s_read_cont ? DX_OBJ_VALUE(s_read_cont) : DX_NULL_VALUE,
            s_write_cont ? DX_OBJ_VALUE(s_write_cont) : DX_NULL_VALUE,
            s_read_ext ? DX_OBJ_VALUE(s_read_ext) : DX_NULL_VALUE,
            s_write_ext ? DX_OBJ_VALUE(s_write_ext) : DX_NULL_VALUE,
            s_record ? DX_OBJ_VALUE(s_record) : DX_NULL_VALUE,
            s_phone ? DX_OBJ_VALUE(s_phone) : DX_NULL_VALUE,
            s_sms ? DX_OBJ_VALUE(s_sms) : DX_NULL_VALUE,
            s_fg_svc ? DX_OBJ_VALUE(s_fg_svc) : DX_NULL_VALUE
        };
        add_static_fields(manifest_perm_cls, mp_names, mp_vals, 16);
    }

    DxClass *view_compat_cls = reg_class(vm, "Landroidx/core/view/ViewCompat;", obj);
    add_method(view_compat_cls, "setElevation", "VLF", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(view_compat_cls, "setTranslationZ", "VLF", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(view_compat_cls, "setOnApplyWindowInsetsListener", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);

    DxClass *appcompat_res_cls = reg_class(vm, "Landroidx/appcompat/content/res/AppCompatResources;", obj);
    add_method(appcompat_res_cls, "getColorStateList", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(appcompat_res_cls, "getDrawable", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // --- androidx.appcompat.widget.* (additional) ---
    DxClass *appcompat_imageview_cls = reg_class(vm, "Landroidx/appcompat/widget/AppCompatImageView;", imageview_cls);
    add_method(appcompat_imageview_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *appcompat_edittext_cls = reg_class(vm, "Landroidx/appcompat/widget/AppCompatEditText;", edittext_cls);
    add_method(appcompat_edittext_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *appcompat_checkbox_cls = reg_class(vm, "Landroidx/appcompat/widget/AppCompatCheckBox;", checkbox_cls);
    add_method(appcompat_checkbox_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *switchcompat_cls = reg_class(vm, "Landroidx/appcompat/widget/SwitchCompat;", compoundbutton_cls);
    add_method(switchcompat_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *appcompat_spinner_cls = reg_class(vm, "Landroidx/appcompat/widget/AppCompatSpinner;", spinner_cls);
    add_method(appcompat_spinner_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *toolbar_widget_cls = reg_class(vm, "Landroidx/appcompat/widget/Toolbar;", viewgroup_cls);
    add_method(toolbar_widget_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(toolbar_widget_cls, "setTitle", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(toolbar_widget_cls, "setSubtitle", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(toolbar_widget_cls, "setNavigationOnClickListener", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(toolbar_widget_cls, "inflateMenu", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(toolbar_widget_cls, "setOnMenuItemClickListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *appbar_layout_cls = reg_class(vm, "Lcom/google/android/material/appbar/AppBarLayout;", linearlayout_cls);
    add_method(appbar_layout_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *collapsing_toolbar_cls = reg_class(vm, "Lcom/google/android/material/appbar/CollapsingToolbarLayout;", dx_vm_find_class(vm, "Landroid/widget/FrameLayout;"));
    add_method(collapsing_toolbar_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(collapsing_toolbar_cls, "setTitle", "VL", DX_ACC_PUBLIC, native_noop, false);

    // --- androidx.drawerlayout.* ---
    DxClass *drawer_layout_cls = reg_class(vm, "Landroidx/drawerlayout/widget/DrawerLayout;", viewgroup_cls);
    add_method(drawer_layout_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(drawer_layout_cls, "openDrawer", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(drawer_layout_cls, "closeDrawer", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(drawer_layout_cls, "addDrawerListener", "VL", DX_ACC_PUBLIC, native_noop, false);

    // --- androidx.navigation.* ---
    DxClass *nav_controller_cls = reg_class(vm, "Landroidx/navigation/NavController;", obj);
    add_method(nav_controller_cls, "navigate", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(nav_controller_cls, "navigate", "VIL", DX_ACC_PUBLIC, native_noop, false);
    add_method(nav_controller_cls, "navigateUp", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(nav_controller_cls, "popBackStack", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(nav_controller_cls, "getCurrentDestination", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *nav_cls = reg_class(vm, "Landroidx/navigation/Navigation;", obj);
    add_method(nav_cls, "findNavController", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    DxClass *nav_host_frag_cls = reg_class(vm, "Landroidx/navigation/fragment/NavHostFragment;",
               dx_vm_find_class(vm, "Landroidx/fragment/app/Fragment;"));
    add_method(nav_host_frag_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(nav_host_frag_cls, "getNavController", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(nav_host_frag_cls, "findNavController", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // --- java.io.* (with real File implementations) ---
    DxClass *file_cls = reg_class(vm, "Ljava/io/File;", obj);
    file_cls->instance_field_count = 1; // field[0] = path string
    add_method(file_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_file_init_string_sandboxed, true);
    add_method(file_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_file_init_parent_child, true);
    add_method(file_cls, "exists", "Z", DX_ACC_PUBLIC,
               native_file_exists, false);
    add_method(file_cls, "mkdir", "Z", DX_ACC_PUBLIC,
               native_file_mkdir, false);
    add_method(file_cls, "mkdirs", "Z", DX_ACC_PUBLIC,
               native_file_mkdir, false);
    add_method(file_cls, "delete", "Z", DX_ACC_PUBLIC,
               native_file_delete, false);
    add_method(file_cls, "isDirectory", "Z", DX_ACC_PUBLIC,
               native_file_is_directory, false);
    add_method(file_cls, "isFile", "Z", DX_ACC_PUBLIC,
               native_file_exists, false);
    add_method(file_cls, "getAbsolutePath", "L", DX_ACC_PUBLIC,
               native_file_get_absolute_path, false);
    add_method(file_cls, "getPath", "L", DX_ACC_PUBLIC,
               native_file_get_absolute_path, false);
    add_method(file_cls, "getName", "L", DX_ACC_PUBLIC,
               native_file_get_name, false);
    add_method(file_cls, "length", "J", DX_ACC_PUBLIC,
               native_file_length, false);
    add_method(file_cls, "canRead", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(file_cls, "canWrite", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(file_cls, "listFiles", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(file_cls, "list", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(file_cls, "getParentFile", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(file_cls, "renameTo", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(file_cls, "createTempFile", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_file_create_temp_file, true);
    add_method(file_cls, "createTempFile", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_file_create_temp_file, true);
    add_method(file_cls, "toString", "L", DX_ACC_PUBLIC,
               native_file_to_string, false);
    add_method(file_cls, "getParent", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // java.io.InputStream (field-backed with _data/_size/_position)
    DxClass *inputstream_cls = reg_class(vm, "Ljava/io/InputStream;", obj);
    inputstream_cls->instance_field_count = 3; // _data (long ptr), _size (int), _position (int)
    add_method(inputstream_cls, "read", "I", DX_ACC_PUBLIC, native_inputstream_read, false);
    add_method(inputstream_cls, "read", "IL", DX_ACC_PUBLIC, native_inputstream_read_array, false); // read(byte[])
    add_method(inputstream_cls, "close", "V", DX_ACC_PUBLIC, native_inputstream_close, false);
    add_method(inputstream_cls, "available", "I", DX_ACC_PUBLIC, native_inputstream_available, false);

    // java.io.OutputStream (abstract base)
    DxClass *outputstream_cls = reg_class(vm, "Ljava/io/OutputStream;", obj);
    add_method(outputstream_cls, "write", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(outputstream_cls, "write", "VL", DX_ACC_PUBLIC, native_noop, false); // write(byte[])
    add_method(outputstream_cls, "flush", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(outputstream_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    // java.io.FileInputStream (inherits field-backed _data/_size/_position from InputStream)
    DxClass *fileinput_cls = reg_class(vm, "Ljava/io/FileInputStream;", inputstream_cls);
    add_method(fileinput_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(fileinput_cls, "read", "I", DX_ACC_PUBLIC, native_inputstream_read, false);
    add_method(fileinput_cls, "read", "IL", DX_ACC_PUBLIC, native_inputstream_read_array, false);
    add_method(fileinput_cls, "close", "V", DX_ACC_PUBLIC, native_inputstream_close, false);
    add_method(fileinput_cls, "available", "I", DX_ACC_PUBLIC, native_inputstream_available, false);

    // java.io.FileOutputStream
    DxClass *fileoutput_cls = reg_class(vm, "Ljava/io/FileOutputStream;", outputstream_cls);
    add_method(fileoutput_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(fileoutput_cls, "write", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(fileoutput_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(fileoutput_cls, "flush", "V", DX_ACC_PUBLIC, native_noop, false);

    // java.io.BufferedReader
    DxClass *buffered_reader_cls = reg_class(vm, "Ljava/io/BufferedReader;", obj);
    add_method(buffered_reader_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(buffered_reader_cls, "readLine", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(buffered_reader_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(buffered_reader_cls, "ready", "Z", DX_ACC_PUBLIC, native_return_false, false);

    // java.io.InputStreamReader
    DxClass *input_stream_reader_cls = reg_class(vm, "Ljava/io/InputStreamReader;", obj);
    add_method(input_stream_reader_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(input_stream_reader_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(input_stream_reader_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    // java.io.BufferedWriter
    DxClass *buffered_writer_cls = reg_class(vm, "Ljava/io/BufferedWriter;", obj);
    add_method(buffered_writer_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(buffered_writer_cls, "write", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(buffered_writer_cls, "newLine", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(buffered_writer_cls, "flush", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(buffered_writer_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    // java.io.OutputStreamWriter
    DxClass *output_stream_writer_cls = reg_class(vm, "Ljava/io/OutputStreamWriter;", obj);
    add_method(output_stream_writer_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(output_stream_writer_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(output_stream_writer_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    // java.io.PrintWriter
    DxClass *print_writer_cls = reg_class(vm, "Ljava/io/PrintWriter;", obj);
    add_method(print_writer_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(print_writer_cls, "println", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(print_writer_cls, "print", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(print_writer_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(print_writer_cls, "flush", "V", DX_ACC_PUBLIC, native_noop, false);

    // java.io.ByteArrayOutputStream
    DxClass *baos_cls = reg_class(vm, "Ljava/io/ByteArrayOutputStream;", outputstream_cls);
    add_method(baos_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, true);
    add_method(baos_cls, "toByteArray", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(baos_cls, "toString", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(baos_cls, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(baos_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    // java.io.ByteArrayInputStream
    DxClass *bais_cls = reg_class(vm, "Ljava/io/ByteArrayInputStream;", inputstream_cls);
    add_method(bais_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, true);
    add_method(bais_cls, "read", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(bais_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    DxClass *serializable_cls = reg_class(vm, "Ljava/io/Serializable;", obj);
    serializable_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *closeable_cls = reg_class(vm, "Ljava/io/Closeable;", obj);
    closeable_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(closeable_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    // --- java.net.* ---
    DxClass *url_cls = reg_class(vm, "Ljava/net/URL;", obj);
    url_cls->instance_field_count = 1; // field[0] = url string
    add_method(url_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_url_init, false);
    add_method(url_cls, "openConnection", "L", DX_ACC_PUBLIC, native_url_open_connection, false);
    add_method(url_cls, "toString", "L", DX_ACC_PUBLIC, native_url_to_string, false);
    add_method(url_cls, "getProtocol", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(url_cls, "getHost", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(url_cls, "getPath", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *http_url_conn_cls = reg_class(vm, "Ljava/net/HttpURLConnection;", obj);
    http_url_conn_cls->instance_field_count = 10; // field[0]=URL, [1]=method, [2]=status, [3]=connected, [4]=req headers, [5]=resp body ptr, [6]=resp body size, [7]=resp hdr names, [8]=resp hdr values, [9]=output stream
    add_method(http_url_conn_cls, "setRequestMethod", "VL", DX_ACC_PUBLIC,
               native_http_set_request_method, false);
    add_method(http_url_conn_cls, "setDoOutput", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(http_url_conn_cls, "setDoInput", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(http_url_conn_cls, "setRequestProperty", "VLL", DX_ACC_PUBLIC,
               native_http_set_request_property, false);
    add_method(http_url_conn_cls, "setConnectTimeout", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(http_url_conn_cls, "setReadTimeout", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(http_url_conn_cls, "connect", "V", DX_ACC_PUBLIC, native_http_connect, false);
    add_method(http_url_conn_cls, "getResponseCode", "I", DX_ACC_PUBLIC,
               native_http_get_response_code, false);
    add_method(http_url_conn_cls, "getResponseMessage", "L", DX_ACC_PUBLIC,
               native_http_get_response_message, false);
    add_method(http_url_conn_cls, "getInputStream", "L", DX_ACC_PUBLIC,
               native_http_get_input_stream, false);
    add_method(http_url_conn_cls, "getOutputStream", "L", DX_ACC_PUBLIC,
               native_http_get_output_stream, false);
    add_method(http_url_conn_cls, "getHeaderField", "LL", DX_ACC_PUBLIC, native_http_get_header_field, false);
    add_method(http_url_conn_cls, "disconnect", "V", DX_ACC_PUBLIC, native_http_disconnect, false);
    add_method(http_url_conn_cls, "getURL", "L", DX_ACC_PUBLIC, native_http_get_url, false);

    // javax.net.ssl.HttpsURLConnection (extends HttpURLConnection)
    DxClass *https_url_conn_cls = reg_class(vm, "Ljavax/net/ssl/HttpsURLConnection;", http_url_conn_cls);
    https_url_conn_cls->instance_field_count = 10;
    add_method(https_url_conn_cls, "setRequestMethod", "VL", DX_ACC_PUBLIC,
               native_http_set_request_method, false);
    add_method(https_url_conn_cls, "setDoOutput", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(https_url_conn_cls, "setDoInput", "VZ", DX_ACC_PUBLIC, native_noop, false);
    add_method(https_url_conn_cls, "setRequestProperty", "VLL", DX_ACC_PUBLIC,
               native_http_set_request_property, false);
    add_method(https_url_conn_cls, "setConnectTimeout", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(https_url_conn_cls, "setReadTimeout", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(https_url_conn_cls, "connect", "V", DX_ACC_PUBLIC, native_http_connect, false);
    add_method(https_url_conn_cls, "getResponseCode", "I", DX_ACC_PUBLIC,
               native_http_get_response_code, false);
    add_method(https_url_conn_cls, "getResponseMessage", "L", DX_ACC_PUBLIC,
               native_http_get_response_message, false);
    add_method(https_url_conn_cls, "getInputStream", "L", DX_ACC_PUBLIC,
               native_http_get_input_stream, false);
    add_method(https_url_conn_cls, "getOutputStream", "L", DX_ACC_PUBLIC,
               native_http_get_output_stream, false);
    add_method(https_url_conn_cls, "getHeaderField", "LL", DX_ACC_PUBLIC, native_http_get_header_field, false);
    add_method(https_url_conn_cls, "disconnect", "V", DX_ACC_PUBLIC, native_http_disconnect, false);
    add_method(https_url_conn_cls, "getURL", "L", DX_ACC_PUBLIC, native_http_get_url, false);
    add_method(https_url_conn_cls, "setSSLSocketFactory", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(https_url_conn_cls, "setHostnameVerifier", "VL", DX_ACC_PUBLIC, native_noop, false);

    // java.net.URI
    DxClass *jnet_uri_cls = reg_class(vm, "Ljava/net/URI;", obj);
    jnet_uri_cls->instance_field_count = 1; // field[0] = uri string
    add_method(jnet_uri_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_juri_init, false);
    add_method(jnet_uri_cls, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_juri_create, true);
    add_method(jnet_uri_cls, "toString", "L", DX_ACC_PUBLIC, native_juri_to_string, false);
    add_method(jnet_uri_cls, "getScheme", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(jnet_uri_cls, "getHost", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(jnet_uri_cls, "getPath", "L", DX_ACC_PUBLIC, native_return_null, false);

    // --- java.net.Socket (real TCP) ---
    DxClass *socket_cls = reg_class(vm, "Ljava/net/Socket;", obj);
    socket_cls->instance_field_count = 3; // [0]=fd, [1]=connected, [2]=closed
    add_method(socket_cls, "<init>", "VLI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_socket_init, true);
    add_method(socket_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(socket_cls, "getInputStream", "L", DX_ACC_PUBLIC,
               native_socket_get_input_stream, false);
    add_method(socket_cls, "getOutputStream", "L", DX_ACC_PUBLIC,
               native_socket_get_output_stream, false);
    add_method(socket_cls, "close", "V", DX_ACC_PUBLIC, native_socket_close, false);
    add_method(socket_cls, "isConnected", "Z", DX_ACC_PUBLIC, native_socket_is_connected, false);
    add_method(socket_cls, "isClosed", "Z", DX_ACC_PUBLIC, native_socket_is_closed, false);

    // java.net.SocketInputStream (internal — reads from socket fd)
    DxClass *sock_is_cls = reg_class(vm, "Ljava/net/SocketInputStream;", inputstream_cls);
    sock_is_cls->instance_field_count = 1; // [0] = reference to Socket object
    add_method(sock_is_cls, "read", "IL", DX_ACC_PUBLIC, native_socket_input_read, false);
    add_method(sock_is_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    // java.net.SocketOutputStream (internal — writes to socket fd)
    DxClass *sock_os_cls = reg_class(vm, "Ljava/net/SocketOutputStream;", outputstream_cls);
    sock_os_cls->instance_field_count = 1; // [0] = reference to Socket object
    add_method(sock_os_cls, "write", "VL", DX_ACC_PUBLIC, native_socket_output_write, false);
    add_method(sock_os_cls, "flush", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(sock_os_cls, "close", "V", DX_ACC_PUBLIC, native_noop, false);

    // --- java.net.ServerSocket (real TCP server) ---
    DxClass *server_socket_cls = reg_class(vm, "Ljava/net/ServerSocket;", obj);
    server_socket_cls->instance_field_count = 2; // [0]=fd, [1]=closed
    add_method(server_socket_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_server_socket_init, true);
    add_method(server_socket_cls, "accept", "L", DX_ACC_PUBLIC,
               native_server_socket_accept, false);
    add_method(server_socket_cls, "close", "V", DX_ACC_PUBLIC,
               native_server_socket_close, false);

    // --- java.util.* (additional) ---
    DxClass *set_cls = reg_class(vm, "Ljava/util/Set;", obj);
    add_method(set_cls, "add", "ZL", DX_ACC_PUBLIC, native_return_true, false);
    add_method(set_cls, "contains", "ZL", DX_ACC_PUBLIC, native_return_false, false);
    add_method(set_cls, "remove", "ZL", DX_ACC_PUBLIC, native_return_false, false);
    add_method(set_cls, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(set_cls, "isEmpty", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(set_cls, "iterator", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *iterator_cls = reg_class(vm, "Ljava/util/Iterator;", obj);
    // Iterator needs fields to store backing list reference and current index
    iterator_cls->instance_field_count = 2;
    iterator_cls->field_defs = (typeof(iterator_cls->field_defs))dx_malloc(
        sizeof(*iterator_cls->field_defs) * 2);
    if (iterator_cls->field_defs) {
        iterator_cls->field_defs[0].name = "_list";
        iterator_cls->field_defs[0].type = "Ljava/util/ArrayList;";
        iterator_cls->field_defs[0].flags = DX_ACC_PRIVATE;
        iterator_cls->field_defs[1].name = "_index";
        iterator_cls->field_defs[1].type = "I";
        iterator_cls->field_defs[1].flags = DX_ACC_PRIVATE;
    }
    add_method(iterator_cls, "hasNext", "Z", DX_ACC_PUBLIC, native_iterator_hasnext, false);
    add_method(iterator_cls, "next", "L", DX_ACC_PUBLIC, native_iterator_next, false);
    add_method(iterator_cls, "remove", "V", DX_ACC_PUBLIC, native_noop, false);

    DxClass *map_entry_cls = reg_class(vm, "Ljava/util/Map$Entry;", obj);
    add_method(map_entry_cls, "getKey", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(map_entry_cls, "getValue", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *stack_cls = reg_class(vm, "Ljava/util/Stack;", dx_vm_find_class(vm, "Ljava/util/ArrayList;"));
    add_method(stack_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(stack_cls, "push", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(stack_cls, "pop", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(stack_cls, "peek", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(stack_cls, "empty", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(stack_cls, "isEmpty", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(stack_cls, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(stack_cls, "search", "IL", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(stack_cls, "clear", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(stack_cls, "contains", "ZL", DX_ACC_PUBLIC, native_return_false, false);

    DxClass *vector_cls = reg_class(vm, "Ljava/util/Vector;", dx_vm_find_class(vm, "Ljava/util/ArrayList;"));
    add_method(vector_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(vector_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(vector_cls, "add", "ZL", DX_ACC_PUBLIC, native_return_true, false);
    add_method(vector_cls, "get", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(vector_cls, "set", "LIL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(vector_cls, "remove", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(vector_cls, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(vector_cls, "isEmpty", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(vector_cls, "contains", "ZL", DX_ACC_PUBLIC, native_return_false, false);
    add_method(vector_cls, "clear", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(vector_cls, "iterator", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(vector_cls, "elementAt", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(vector_cls, "addElement", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(vector_cls, "removeElement", "ZL", DX_ACC_PUBLIC, native_return_false, false);
    add_method(vector_cls, "removeAllElements", "V", DX_ACC_PUBLIC, native_noop, false);
    vector_cls->interface_count = 3;
    vector_cls->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (vector_cls->interfaces) {
        vector_cls->interfaces[0] = "Ljava/util/List;";
        vector_cls->interfaces[1] = "Ljava/util/Collection;";
        vector_cls->interfaces[2] = "Ljava/lang/Iterable;";
    }

    DxClass *uuid_cls = reg_class(vm, "Ljava/util/UUID;", obj);
    uuid_cls->instance_field_count = 1; // field[0] = string representation
    add_method(uuid_cls, "randomUUID", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(uuid_cls, "fromString", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(uuid_cls, "toString", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(uuid_cls, "getMostSignificantBits", "J", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(uuid_cls, "getLeastSignificantBits", "J", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(uuid_cls, "compareTo", "IL", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(uuid_cls, "equals", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(uuid_cls, "hashCode", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    DxClass *locale_cls = reg_class(vm, "Ljava/util/Locale;", obj);
    locale_cls->instance_field_count = 2; // field[0] = language, field[1] = country
    add_method(locale_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(locale_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(locale_cls, "getDefault", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(locale_cls, "getLanguage", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(locale_cls, "getCountry", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(locale_cls, "toString", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(locale_cls, "getDisplayName", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(locale_cls, "getDisplayLanguage", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(locale_cls, "getDisplayCountry", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(locale_cls, "toLanguageTag", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(locale_cls, "forLanguageTag", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    {
        const char *locale_snames[] = { "US", "ENGLISH", "UK", "CANADA", "FRENCH", "GERMAN",
                                         "ITALIAN", "JAPANESE", "KOREAN", "CHINESE", "ROOT" };
        DxValue locale_svals[] = {
            DX_NULL_VALUE, DX_NULL_VALUE, DX_NULL_VALUE, DX_NULL_VALUE, DX_NULL_VALUE,
            DX_NULL_VALUE, DX_NULL_VALUE, DX_NULL_VALUE, DX_NULL_VALUE, DX_NULL_VALUE,
            DX_NULL_VALUE
        };
        add_static_fields(locale_cls, locale_snames, locale_svals, 11);
    }

    DxClass *timer_cls = reg_class(vm, "Ljava/util/Timer;", obj);
    add_method(timer_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(timer_cls, "schedule", "VLJ", DX_ACC_PUBLIC, native_noop, false);
    add_method(timer_cls, "cancel", "V", DX_ACC_PUBLIC, native_noop, false);

    DxClass *timer_task_cls = reg_class(vm, "Ljava/util/TimerTask;", obj);
    add_method(timer_task_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(timer_task_cls, "run", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(timer_task_cls, "cancel", "Z", DX_ACC_PUBLIC, native_return_true, false);

    // --- java.util.Optional ---
    DxClass *optional_cls = reg_class(vm, "Ljava/util/Optional;", obj);
    optional_cls->instance_field_count = 1; // field[0] = wrapped value
    add_method(optional_cls, "of", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(optional_cls, "ofNullable", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(optional_cls, "empty", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(optional_cls, "isPresent", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(optional_cls, "isEmpty", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(optional_cls, "get", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(optional_cls, "orElse", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(optional_cls, "orElseGet", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(optional_cls, "orElseThrow", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(optional_cls, "ifPresent", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(optional_cls, "map", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(optional_cls, "flatMap", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(optional_cls, "filter", "LL", DX_ACC_PUBLIC,
               native_return_null, false);

    // --- java.util.OptionalInt / OptionalLong / OptionalDouble ---
    DxClass *opt_int = reg_class(vm, "Ljava/util/OptionalInt;", obj);
    opt_int->instance_field_count = 1;
    add_method(opt_int, "of", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(opt_int, "empty", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(opt_int, "isPresent", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(opt_int, "getAsInt", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(opt_int, "orElse", "II", DX_ACC_PUBLIC, native_return_int_zero, false);

    DxClass *opt_long = reg_class(vm, "Ljava/util/OptionalLong;", obj);
    opt_long->instance_field_count = 1;
    add_method(opt_long, "of", "LJ", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(opt_long, "empty", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(opt_long, "isPresent", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(opt_long, "getAsLong", "J", DX_ACC_PUBLIC, native_return_int_zero, false);

    DxClass *opt_double = reg_class(vm, "Ljava/util/OptionalDouble;", obj);
    opt_double->instance_field_count = 1;
    add_method(opt_double, "of", "LD", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(opt_double, "empty", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(opt_double, "isPresent", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(opt_double, "getAsDouble", "D", DX_ACC_PUBLIC, native_return_int_zero, false);

    // --- java.util.Calendar / GregorianCalendar ---
    DxClass *calendar_cls = reg_class(vm, "Ljava/util/Calendar;", obj);
    calendar_cls->instance_field_count = 2;
    calendar_cls->access_flags = DX_ACC_PUBLIC | DX_ACC_ABSTRACT;
    add_method(calendar_cls, "getInstance", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(calendar_cls, "getInstance", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(calendar_cls, "get", "II", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(calendar_cls, "set", "VII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(calendar_cls, "set", "VIIIIII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(calendar_cls, "getTime", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(calendar_cls, "setTime", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(calendar_cls, "getTimeInMillis", "J", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(calendar_cls, "setTimeInMillis", "VJ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(calendar_cls, "add", "VII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(calendar_cls, "before", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(calendar_cls, "after", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(calendar_cls, "compareTo", "IL", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(calendar_cls, "clear", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(calendar_cls, "getTimeZone", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(calendar_cls, "setTimeZone", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    {
        const char *cal_snames[] = { "YEAR", "MONTH", "DAY_OF_MONTH", "HOUR_OF_DAY",
                                      "MINUTE", "SECOND", "MILLISECOND", "DAY_OF_WEEK",
                                      "WEEK_OF_YEAR", "AM_PM", "HOUR",
                                      "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY",
                                      "THURSDAY", "FRIDAY", "SATURDAY",
                                      "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY",
                                      "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER",
                                      "NOVEMBER", "DECEMBER" };
        DxValue cal_svals[] = {
            DX_INT_VALUE(1), DX_INT_VALUE(2), DX_INT_VALUE(5), DX_INT_VALUE(11),
            DX_INT_VALUE(12), DX_INT_VALUE(13), DX_INT_VALUE(14), DX_INT_VALUE(7),
            DX_INT_VALUE(3), DX_INT_VALUE(9), DX_INT_VALUE(10),
            DX_INT_VALUE(1), DX_INT_VALUE(2), DX_INT_VALUE(3), DX_INT_VALUE(4),
            DX_INT_VALUE(5), DX_INT_VALUE(6), DX_INT_VALUE(7),
            DX_INT_VALUE(0), DX_INT_VALUE(1), DX_INT_VALUE(2), DX_INT_VALUE(3), DX_INT_VALUE(4),
            DX_INT_VALUE(5), DX_INT_VALUE(6), DX_INT_VALUE(7), DX_INT_VALUE(8), DX_INT_VALUE(9),
            DX_INT_VALUE(10), DX_INT_VALUE(11)
        };
        add_static_fields(calendar_cls, cal_snames, cal_svals, 30);
    }

    DxClass *gregorian_cal = reg_class(vm, "Ljava/util/GregorianCalendar;", calendar_cls);
    gregorian_cal->instance_field_count = 2;
    add_method(gregorian_cal, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(gregorian_cal, "<init>", "VIII", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(gregorian_cal, "<init>", "VIIIII", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(gregorian_cal, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(gregorian_cal, "get", "II", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(gregorian_cal, "set", "VII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(gregorian_cal, "getTime", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(gregorian_cal, "getTimeInMillis", "J", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(gregorian_cal, "add", "VII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(gregorian_cal, "isLeapYear", "ZI", DX_ACC_PUBLIC,
               native_return_false, false);

    // --- java.util.Date ---
    DxClass *date_cls = dx_vm_find_class(vm, "Ljava/util/Date;");
    if (!date_cls) {
        date_cls = reg_class(vm, "Ljava/util/Date;", obj);
        date_cls->instance_field_count = 1;
        add_method(date_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                   native_noop, true);
        add_method(date_cls, "<init>", "VJ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                   native_noop, true);
        add_method(date_cls, "getTime", "J", DX_ACC_PUBLIC,
                   native_return_int_zero, false);
        add_method(date_cls, "setTime", "VJ", DX_ACC_PUBLIC,
                   native_noop, false);
        add_method(date_cls, "before", "ZL", DX_ACC_PUBLIC,
                   native_return_false, false);
        add_method(date_cls, "after", "ZL", DX_ACC_PUBLIC,
                   native_return_false, false);
        add_method(date_cls, "compareTo", "IL", DX_ACC_PUBLIC,
                   native_return_int_zero, false);
        add_method(date_cls, "toString", "L", DX_ACC_PUBLIC,
                   native_return_null, false);
    }

    // --- java.util.TimeZone ---
    DxClass *tz_cls = dx_vm_find_class(vm, "Ljava/util/TimeZone;");
    if (!tz_cls) {
        tz_cls = reg_class(vm, "Ljava/util/TimeZone;", obj);
        add_method(tz_cls, "getDefault", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_null, true);
        add_method(tz_cls, "getTimeZone", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_null, true);
        add_method(tz_cls, "getID", "L", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(tz_cls, "getDisplayName", "L", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(tz_cls, "getRawOffset", "I", DX_ACC_PUBLIC,
                   native_return_int_zero, false);
    }

    // --- java.text.SimpleDateFormat ---
    DxClass *sdf_cls = dx_vm_find_class(vm, "Ljava/text/SimpleDateFormat;");
    if (!sdf_cls) {
        sdf_cls = reg_class(vm, "Ljava/text/SimpleDateFormat;", obj);
        add_method(sdf_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                   native_noop, true);
        add_method(sdf_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                   native_noop, true);
        add_method(sdf_cls, "format", "LL", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(sdf_cls, "parse", "LL", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(sdf_cls, "setTimeZone", "VL", DX_ACC_PUBLIC,
                   native_noop, false);
        add_method(sdf_cls, "setLenient", "VZ", DX_ACC_PUBLIC,
                   native_noop, false);
    }

    // --- java.text.DateFormat ---
    DxClass *df_cls = dx_vm_find_class(vm, "Ljava/text/DateFormat;");
    if (!df_cls) {
        df_cls = reg_class(vm, "Ljava/text/DateFormat;", obj);
        df_cls->access_flags = DX_ACC_PUBLIC | DX_ACC_ABSTRACT;
        add_method(df_cls, "getDateInstance", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_null, true);
        add_method(df_cls, "getDateInstance", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_null, true);
        add_method(df_cls, "getTimeInstance", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_null, true);
        add_method(df_cls, "getDateTimeInstance", "LII", DX_ACC_PUBLIC | DX_ACC_STATIC,
                   native_return_null, true);
        add_method(df_cls, "format", "LL", DX_ACC_PUBLIC,
                   native_return_null, false);
        add_method(df_cls, "parse", "LL", DX_ACC_PUBLIC,
                   native_return_null, false);
    }

    // --- java.util.Enumeration (interface) ---
    DxClass *enum_iface = dx_vm_find_class(vm, "Ljava/util/Enumeration;");
    if (!enum_iface) {
        enum_iface = reg_class(vm, "Ljava/util/Enumeration;", obj);
        enum_iface->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
        add_method(enum_iface, "hasMoreElements", "Z", DX_ACC_PUBLIC,
                   native_return_false, false);
        add_method(enum_iface, "nextElement", "L", DX_ACC_PUBLIC,
                   native_return_null, false);
    }

    // --- java.util.Queue (interface) ---
    DxClass *queue_iface = dx_vm_find_class(vm, "Ljava/util/Queue;");
    if (!queue_iface) {
        queue_iface = reg_class(vm, "Ljava/util/Queue;", obj);
        queue_iface->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
        add_method(queue_iface, "offer", "ZL", DX_ACC_PUBLIC, native_return_true, false);
        add_method(queue_iface, "poll", "L", DX_ACC_PUBLIC, native_return_null, false);
        add_method(queue_iface, "peek", "L", DX_ACC_PUBLIC, native_return_null, false);
        add_method(queue_iface, "add", "ZL", DX_ACC_PUBLIC, native_return_true, false);
        add_method(queue_iface, "remove", "L", DX_ACC_PUBLIC, native_return_null, false);
    }

    // --- java.util.Deque (interface) ---
    DxClass *deque_iface = dx_vm_find_class(vm, "Ljava/util/Deque;");
    if (!deque_iface) {
        deque_iface = reg_class(vm, "Ljava/util/Deque;", obj);
        deque_iface->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
        add_method(deque_iface, "addFirst", "VL", DX_ACC_PUBLIC, native_noop, false);
        add_method(deque_iface, "addLast", "VL", DX_ACC_PUBLIC, native_noop, false);
        add_method(deque_iface, "removeFirst", "L", DX_ACC_PUBLIC, native_return_null, false);
        add_method(deque_iface, "removeLast", "L", DX_ACC_PUBLIC, native_return_null, false);
        add_method(deque_iface, "peekFirst", "L", DX_ACC_PUBLIC, native_return_null, false);
        add_method(deque_iface, "peekLast", "L", DX_ACC_PUBLIC, native_return_null, false);
        add_method(deque_iface, "pollFirst", "L", DX_ACC_PUBLIC, native_return_null, false);
        add_method(deque_iface, "pollLast", "L", DX_ACC_PUBLIC, native_return_null, false);
        add_method(deque_iface, "offerFirst", "ZL", DX_ACC_PUBLIC, native_return_true, false);
        add_method(deque_iface, "offerLast", "ZL", DX_ACC_PUBLIC, native_return_true, false);
    }

    // --- java.util.concurrent.* ---
    DxClass *executor_cls = reg_class(vm, "Ljava/util/concurrent/Executor;", obj);
    add_method(executor_cls, "execute", "VL", DX_ACC_PUBLIC,
               native_handler_post, false); // execute Runnable synchronously

    DxClass *executor_svc_cls = reg_class(vm, "Ljava/util/concurrent/ExecutorService;", executor_cls);
    add_method(executor_svc_cls, "execute", "VL", DX_ACC_PUBLIC,
               native_handler_post, false);
    add_method(executor_svc_cls, "submit", "LL", DX_ACC_PUBLIC,
               native_executor_submit, false);
    add_method(executor_svc_cls, "shutdown", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(executor_svc_cls, "shutdownNow", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(executor_svc_cls, "isShutdown", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(executor_svc_cls, "isTerminated", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(executor_svc_cls, "awaitTermination", "ZJL", DX_ACC_PUBLIC, native_return_true, false);

    DxClass *executors_cls = reg_class(vm, "Ljava/util/concurrent/Executors;", obj);
    add_method(executors_cls, "newSingleThreadExecutor", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_executors_new_pool, true);
    add_method(executors_cls, "newFixedThreadPool", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_executors_new_pool, true);
    add_method(executors_cls, "newCachedThreadPool", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_executors_new_pool, true);
    add_method(executors_cls, "newScheduledThreadPool", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_executors_new_pool, true);
    add_method(executors_cls, "newSingleThreadScheduledExecutor", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_executors_new_pool, true);
    add_method(executors_cls, "newWorkStealingPool", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_executors_new_pool, true);
    add_method(executors_cls, "newWorkStealingPool", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_executors_new_pool, true);

    DxClass *future_cls = reg_class(vm, "Ljava/util/concurrent/Future;", obj);
    future_cls->instance_field_count = 1; // field[0] = stored result
    add_method(future_cls, "get", "L", DX_ACC_PUBLIC, native_future_get, false);
    add_method(future_cls, "get", "LJL", DX_ACC_PUBLIC, native_future_get, false); // get(long timeout, TimeUnit)
    add_method(future_cls, "isDone", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(future_cls, "isCancelled", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(future_cls, "cancel", "ZZ", DX_ACC_PUBLIC, native_return_false, false);

    // java.util.concurrent.Callable
    DxClass *callable_cls = reg_class(vm, "Ljava/util/concurrent/Callable;", obj);
    add_method(callable_cls, "call", "L", DX_ACC_PUBLIC, native_return_null, false);

    // java.util.concurrent.CompletableFuture
    DxClass *cf_cls = reg_class(vm, "Ljava/util/concurrent/CompletableFuture;", future_cls);
    cf_cls->instance_field_count = 1; // field[0] = stored value
    add_method(cf_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(cf_cls, "completedFuture", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_cf_completed_future, true);
    add_method(cf_cls, "get", "L", DX_ACC_PUBLIC, native_future_get, false);
    add_method(cf_cls, "get", "LJL", DX_ACC_PUBLIC, native_future_get, false);
    add_method(cf_cls, "join", "L", DX_ACC_PUBLIC, native_future_get, false);
    add_method(cf_cls, "getNow", "LL", DX_ACC_PUBLIC, native_future_get, false);
    add_method(cf_cls, "isDone", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(cf_cls, "isCancelled", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cf_cls, "isCompletedExceptionally", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(cf_cls, "complete", "ZL", DX_ACC_PUBLIC, native_cf_complete, false);
    add_method(cf_cls, "thenApply", "LL", DX_ACC_PUBLIC, native_cf_then_apply, false);
    add_method(cf_cls, "thenAccept", "LL", DX_ACC_PUBLIC, native_cf_then_accept, false);
    add_method(cf_cls, "thenRun", "LL", DX_ACC_PUBLIC, native_cf_then_run, false);
    add_method(cf_cls, "thenApplyAsync", "LL", DX_ACC_PUBLIC, native_cf_then_apply, false);
    add_method(cf_cls, "thenAcceptAsync", "LL", DX_ACC_PUBLIC, native_cf_then_accept, false);
    add_method(cf_cls, "thenRunAsync", "LL", DX_ACC_PUBLIC, native_cf_then_run, false);
    add_method(cf_cls, "whenComplete", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(cf_cls, "exceptionally", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(cf_cls, "handle", "LL", DX_ACC_PUBLIC, native_return_self, false);

    // java.util.concurrent.ThreadPoolExecutor (extends ExecutorService)
    DxClass *tpe_cls = reg_class(vm, "Ljava/util/concurrent/ThreadPoolExecutor;", executor_svc_cls);
    add_method(tpe_cls, "<init>", "VIIJLLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(tpe_cls, "execute", "VL", DX_ACC_PUBLIC, native_handler_post, false);
    add_method(tpe_cls, "submit", "LL", DX_ACC_PUBLIC, native_executor_submit, false);
    add_method(tpe_cls, "shutdown", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(tpe_cls, "shutdownNow", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(tpe_cls, "isShutdown", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(tpe_cls, "isTerminated", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(tpe_cls, "getPoolSize", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(tpe_cls, "getActiveCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(tpe_cls, "setCorePoolSize", "VI", DX_ACC_PUBLIC, native_noop, false);
    add_method(tpe_cls, "setMaximumPoolSize", "VI", DX_ACC_PUBLIC, native_noop, false);

    // java.util.concurrent.ScheduledExecutorService
    DxClass *sched_exec_cls = reg_class(vm, "Ljava/util/concurrent/ScheduledExecutorService;", executor_svc_cls);
    add_method(sched_exec_cls, "schedule", "LLJL", DX_ACC_PUBLIC, native_executor_submit, false);
    add_method(sched_exec_cls, "scheduleAtFixedRate", "LLLJL", DX_ACC_PUBLIC, native_executor_submit, false);
    add_method(sched_exec_cls, "scheduleWithFixedDelay", "LLLJL", DX_ACC_PUBLIC, native_executor_submit, false);
    add_method(sched_exec_cls, "execute", "VL", DX_ACC_PUBLIC, native_handler_post, false);
    add_method(sched_exec_cls, "submit", "LL", DX_ACC_PUBLIC, native_executor_submit, false);
    add_method(sched_exec_cls, "shutdown", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(sched_exec_cls, "shutdownNow", "L", DX_ACC_PUBLIC, native_return_null, false);

    // java.util.concurrent.ScheduledThreadPoolExecutor
    DxClass *stpe_cls = reg_class(vm, "Ljava/util/concurrent/ScheduledThreadPoolExecutor;", sched_exec_cls);
    add_method(stpe_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(stpe_cls, "<init>", "VIL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(stpe_cls, "schedule", "LLJL", DX_ACC_PUBLIC, native_executor_submit, false);
    add_method(stpe_cls, "execute", "VL", DX_ACC_PUBLIC, native_handler_post, false);
    add_method(stpe_cls, "submit", "LL", DX_ACC_PUBLIC, native_executor_submit, false);
    add_method(stpe_cls, "shutdown", "V", DX_ACC_PUBLIC, native_noop, false);

    DxClass *countdown_cls = reg_class(vm, "Ljava/util/concurrent/CountDownLatch;", obj);
    countdown_cls->instance_field_count = 1; // field[0] = count
    add_method(countdown_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_countdown_init, false);
    add_method(countdown_cls, "countDown", "V", DX_ACC_PUBLIC,
               native_countdown_count_down, false);
    add_method(countdown_cls, "await", "V", DX_ACC_PUBLIC, native_noop, false); // no-op (single-threaded)
    add_method(countdown_cls, "await", "ZJL", DX_ACC_PUBLIC, native_return_true, false); // await(timeout, unit)
    add_method(countdown_cls, "getCount", "J", DX_ACC_PUBLIC,
               native_countdown_get_count, false);

    DxClass *semaphore_cls = reg_class(vm, "Ljava/util/concurrent/Semaphore;", obj);
    semaphore_cls->instance_field_count = 1; // field[0] = permits
    add_method(semaphore_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_semaphore_init, false);
    add_method(semaphore_cls, "<init>", "VIZ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_semaphore_init, false); // (permits, fair) — ignore fair flag
    add_method(semaphore_cls, "acquire", "V", DX_ACC_PUBLIC,
               native_semaphore_acquire, false);
    add_method(semaphore_cls, "release", "V", DX_ACC_PUBLIC,
               native_semaphore_release, false);
    add_method(semaphore_cls, "availablePermits", "I", DX_ACC_PUBLIC,
               native_semaphore_available_permits, false);
    add_method(semaphore_cls, "tryAcquire", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(semaphore_cls, "tryAcquire", "ZJL", DX_ACC_PUBLIC, native_return_true, false);

    DxClass *atomic_bool_cls = reg_class(vm, "Ljava/util/concurrent/atomic/AtomicBoolean;", obj);
    atomic_bool_cls->instance_field_count = 1; // field[0] = boolean value
    add_method(atomic_bool_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(atomic_bool_cls, "<init>", "VZ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_atomic_bool_init_value, false);
    add_method(atomic_bool_cls, "get", "Z", DX_ACC_PUBLIC, native_atomic_bool_get, false);
    add_method(atomic_bool_cls, "set", "VZ", DX_ACC_PUBLIC, native_atomic_bool_set, false);
    add_method(atomic_bool_cls, "compareAndSet", "ZZZ", DX_ACC_PUBLIC, native_atomic_bool_compare_and_set, false);
    add_method(atomic_bool_cls, "getAndSet", "ZZ", DX_ACC_PUBLIC, native_atomic_bool_get_and_set, false);

    DxClass *atomic_long_cls = reg_class(vm, "Ljava/util/concurrent/atomic/AtomicLong;", obj);
    atomic_long_cls->instance_field_count = 1; // field[0] = long value (stored as int32)
    add_method(atomic_long_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(atomic_long_cls, "<init>", "VJ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_atomic_long_init_value, false);
    add_method(atomic_long_cls, "get", "J", DX_ACC_PUBLIC,
               native_atomic_long_get, false);
    add_method(atomic_long_cls, "set", "VJ", DX_ACC_PUBLIC,
               native_atomic_long_set, false);
    add_method(atomic_long_cls, "incrementAndGet", "J", DX_ACC_PUBLIC,
               native_atomic_long_increment_and_get, false);
    add_method(atomic_long_cls, "getAndIncrement", "J", DX_ACC_PUBLIC,
               native_atomic_long_get_and_increment, false);

    // --- java.lang.ClassLoader ---
    DxClass *classloader_cls = reg_class(vm, "Ljava/lang/ClassLoader;", obj);
    classloader_cls->instance_field_count = 1; // field[0] = parent ClassLoader
    add_method(classloader_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(classloader_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false); // ClassLoader(ClassLoader parent)
    add_method(classloader_cls, "loadClass", "LL", DX_ACC_PUBLIC,
               native_classloader_load_class, false);
    add_method(classloader_cls, "getParent", "L", DX_ACC_PUBLIC,
               native_classloader_get_parent, false);
    add_method(classloader_cls, "getResource", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(classloader_cls, "getResourceAsStream", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(classloader_cls, "getSystemClassLoader", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_class_get_class_loader, true);

    // --- dalvik.system.PathClassLoader ---
    DxClass *path_cl_cls = reg_class(vm, "Ldalvik/system/PathClassLoader;", classloader_cls);
    path_cl_cls->instance_field_count = 1; // field[0] = parent ClassLoader
    add_method(path_cl_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false); // PathClassLoader(String dexPath, ClassLoader parent)
    add_method(path_cl_cls, "<init>", "VLLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false); // PathClassLoader(String dexPath, String libPath, ClassLoader parent)
    add_method(path_cl_cls, "loadClass", "LL", DX_ACC_PUBLIC,
               native_classloader_load_class, false);
    add_method(path_cl_cls, "getParent", "L", DX_ACC_PUBLIC,
               native_classloader_get_parent, false);

    // --- dalvik.system.DexClassLoader ---
    DxClass *dex_cl_cls = reg_class(vm, "Ldalvik/system/DexClassLoader;", classloader_cls);
    dex_cl_cls->instance_field_count = 1; // field[0] = parent ClassLoader
    add_method(dex_cl_cls, "<init>", "VLLLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false); // DexClassLoader(String dexPath, String optDir, String libPath, ClassLoader parent)
    add_method(dex_cl_cls, "loadClass", "LL", DX_ACC_PUBLIC,
               native_classloader_load_class, false);
    add_method(dex_cl_cls, "getParent", "L", DX_ACC_PUBLIC,
               native_classloader_get_parent, false);

    // --- java.net.URLClassLoader ---
    DxClass *url_cl_cls = reg_class(vm, "Ljava/net/URLClassLoader;", classloader_cls);
    url_cl_cls->instance_field_count = 1; // field[0] = parent ClassLoader
    add_method(url_cl_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false); // URLClassLoader(URL[] urls)
    add_method(url_cl_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false); // URLClassLoader(URL[] urls, ClassLoader parent)
    add_method(url_cl_cls, "loadClass", "LL", DX_ACC_PUBLIC,
               native_classloader_load_class, false);
    add_method(url_cl_cls, "getParent", "L", DX_ACC_PUBLIC,
               native_classloader_get_parent, false);

    // --- java.lang.* (additional) ---
    DxClass *thread_cls = reg_class(vm, "Ljava/lang/Thread;", obj);
    thread_cls->instance_field_count = 1; // field[0] = Runnable target
    add_method(thread_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(thread_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_thread_init_runnable, false);
    add_method(thread_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_thread_init_runnable, false); // Thread(Runnable, String)
    add_method(thread_cls, "start", "V", DX_ACC_PUBLIC,
               native_thread_start, false); // synchronous: run this.run()
    add_method(thread_cls, "run", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(thread_cls, "join", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(thread_cls, "join", "VJ", DX_ACC_PUBLIC, native_noop, false);
    add_method(thread_cls, "isAlive", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(thread_cls, "interrupt", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(thread_cls, "isInterrupted", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(thread_cls, "currentThread", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_thread_current, true);
    add_method(thread_cls, "sleep", "VJ", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(thread_cls, "setName", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(thread_cls, "getName", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(thread_cls, "setDaemon", "VZ", DX_ACC_PUBLIC, native_noop, false);

    DxClass *runnable_cls = reg_class(vm, "Ljava/lang/Runnable;", obj);
    add_method(runnable_cls, "run", "V", DX_ACC_PUBLIC, native_noop, false);

    // Exception classes are already registered by dx_register_java_lang() with proper
    // field definitions and native methods. Just look them up for local use if needed.
    // (Do NOT re-register - that would create duplicates without detailMessage field.)

    DxClass *integer_cls = reg_class(vm, "Ljava/lang/Integer;", obj);
    integer_cls->instance_field_count = 1; // field[0] = int value
    add_method(integer_cls, "valueOf", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_integer_valueOf, true);
    add_method(integer_cls, "parseInt", "IL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_parse_int, true);
    add_method(integer_cls, "intValue", "I", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(integer_cls, "longValue", "J", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(integer_cls, "floatValue", "F", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(integer_cls, "doubleValue", "D", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(integer_cls, "toString", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_boxed_tostring, true);  // arg[0] is int, reads as .i
    add_method(integer_cls, "toString", "L", DX_ACC_PUBLIC,
               native_boxed_tostring, false);
    add_method(integer_cls, "compareTo", "IL", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(integer_cls, "equals", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(integer_cls, "hashCode", "I", DX_ACC_PUBLIC,
               native_unbox_int, false);

    DxClass *long_cls = reg_class(vm, "Ljava/lang/Long;", obj);
    long_cls->instance_field_count = 1;
    add_method(long_cls, "valueOf", "LJ", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_long_valueOf, true);
    add_method(long_cls, "parseLong", "JL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_parse_long, true);
    add_method(long_cls, "longValue", "J", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(long_cls, "intValue", "I", DX_ACC_PUBLIC, native_unbox_int, false);

    DxClass *float_cls = reg_class(vm, "Ljava/lang/Float;", obj);
    float_cls->instance_field_count = 1;
    add_method(float_cls, "valueOf", "LF", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_float_valueOf, true);
    add_method(float_cls, "parseFloat", "FL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_parse_float, true);
    add_method(float_cls, "floatValue", "F", DX_ACC_PUBLIC, native_unbox_float, false);
    add_method(float_cls, "doubleValue", "D", DX_ACC_PUBLIC, native_unbox_float, false);
    add_method(float_cls, "intValue", "I", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(float_cls, "isNaN", "ZF", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);

    DxClass *double_cls = reg_class(vm, "Ljava/lang/Double;", obj);
    double_cls->instance_field_count = 1;
    add_method(double_cls, "valueOf", "LD", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_double_valueOf, true);
    add_method(double_cls, "parseDouble", "DL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_parse_double, true);
    add_method(double_cls, "doubleValue", "D", DX_ACC_PUBLIC, native_unbox_double, false);
    add_method(double_cls, "floatValue", "F", DX_ACC_PUBLIC, native_unbox_float, false);
    add_method(double_cls, "intValue", "I", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(double_cls, "isNaN", "ZD", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);

    DxClass *boolean_cls = reg_class(vm, "Ljava/lang/Boolean;", obj);
    boolean_cls->instance_field_count = 1;
    add_method(boolean_cls, "valueOf", "LZ", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_boolean_valueOf, true);
    add_method(boolean_cls, "booleanValue", "Z", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(boolean_cls, "parseBoolean", "ZL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_parse_boolean, true);

    DxClass *byte_cls = reg_class(vm, "Ljava/lang/Byte;", obj);
    byte_cls->instance_field_count = 1;
    add_method(byte_cls, "valueOf", "LB", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_byte_valueOf, true);
    add_method(byte_cls, "byteValue", "B", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(byte_cls, "intValue", "I", DX_ACC_PUBLIC, native_unbox_int, false);

    DxClass *short_cls = reg_class(vm, "Ljava/lang/Short;", obj);
    short_cls->instance_field_count = 1;
    add_method(short_cls, "valueOf", "LS", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_short_valueOf, true);
    add_method(short_cls, "shortValue", "S", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(short_cls, "intValue", "I", DX_ACC_PUBLIC, native_unbox_int, false);

    DxClass *character_cls = reg_class(vm, "Ljava/lang/Character;", obj);
    character_cls->instance_field_count = 1;
    add_method(character_cls, "valueOf", "LC", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_char_valueOf, true);
    add_method(character_cls, "charValue", "C", DX_ACC_PUBLIC, native_unbox_int, false);
    add_method(character_cls, "isDigit", "ZC", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);
    add_method(character_cls, "isLetter", "ZC", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);
    add_method(character_cls, "isWhitespace", "ZC", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);

    DxClass *number_cls = reg_class(vm, "Ljava/lang/Number;", obj);
    add_method(number_cls, "intValue", "I", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_int_zero, false);
    add_method(number_cls, "longValue", "J", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_int_zero, false);
    add_method(number_cls, "floatValue", "F", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_int_zero, false);
    add_method(number_cls, "doubleValue", "D", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_int_zero, false);

    DxClass *system_cls = reg_class(vm, "Ljava/lang/System;", obj);
    add_method(system_cls, "currentTimeMillis", "J", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_system_current_time_millis, true);
    add_method(system_cls, "nanoTime", "J", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_system_nano_time, true);
    add_method(system_cls, "arraycopy", "VLILII", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(system_cls, "gc", "V", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(system_cls, "exit", "VI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(system_cls, "getProperty", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(system_cls, "loadLibrary", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_system_loadlibrary_fw, true);
    add_method(system_cls, "load", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_system_loadlibrary_fw, true);

    DxClass *arrays_cls = reg_class(vm, "Ljava/util/Arrays;", obj);
    add_method(arrays_cls, "asList", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_arrays_asList, true);
    add_method(arrays_cls, "sort", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(arrays_cls, "copyOf", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_arrays_copyOf, true);
    add_method(arrays_cls, "fill", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_arrays_fill, true);
    add_method(arrays_cls, "equals", "ZLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_arrays_equals, true);
    add_method(arrays_cls, "toString", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_arrays_toString, true);

    DxClass *objects_cls = reg_class(vm, "Ljava/util/Objects;", obj);
    add_method(objects_cls, "equals", "ZLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_objects_equals, true);
    add_method(objects_cls, "requireNonNull", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_objects_requireNonNull, true);
    add_method(objects_cls, "hashCode", "IL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_objects_hashCode, true);
    add_method(objects_cls, "hash", "IL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_objects_hashCode, true);
    add_method(objects_cls, "toString", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_objects_toString, true);

    // --- java.text.* ---
    DxClass *simple_date_format_cls = reg_class(vm, "Ljava/text/SimpleDateFormat;", obj);
    add_method(simple_date_format_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_sdf_init, false);
    add_method(simple_date_format_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_sdf_init, false);
    add_method(simple_date_format_cls, "format", "LL", DX_ACC_PUBLIC, native_sdf_format, false);
    add_method(simple_date_format_cls, "parse", "LL", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *decimal_format_cls = reg_class(vm, "Ljava/text/DecimalFormat;", obj);
    add_method(decimal_format_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(decimal_format_cls, "format", "LD", DX_ACC_PUBLIC, native_return_null, false);

    // --- android.util.* (additional) ---
    DxClass *pair_cls = reg_class(vm, "Landroid/util/Pair;", obj);
    add_method(pair_cls, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_pair_init, false);
    add_method(pair_cls, "create", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_pair_create, true);
    add_method(pair_cls, "toString", "L", DX_ACC_PUBLIC,
               native_pair_toString, false);
    add_method(pair_cls, "equals", "ZL", DX_ACC_PUBLIC,
               native_objects_equals, false);
    add_method(pair_cls, "hashCode", "I", DX_ACC_PUBLIC,
               native_objects_hashCode, false);
    // Instance fields for first/second are handled by instance_field_count on Pair
    pair_cls->static_field_count = 0;  // no statics for Pair

    // android.util.ArrayMap (same API as HashMap)
    DxClass *arraymap_cls = reg_class(vm, "Landroid/util/ArrayMap;", vm->class_hashmap);
    add_method(arraymap_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(arraymap_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *long_sparse_cls = reg_class(vm, "Landroid/util/LongSparseArray;", obj);
    add_method(long_sparse_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(long_sparse_cls, "get", "LJ", DX_ACC_PUBLIC, native_return_null, false);
    add_method(long_sparse_cls, "put", "VJL", DX_ACC_PUBLIC, native_noop, false);
    add_method(long_sparse_cls, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);

    DxClass *sparse_int_cls = reg_class(vm, "Landroid/util/SparseIntArray;", obj);
    add_method(sparse_int_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(sparse_int_cls, "get", "II", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(sparse_int_cls, "put", "VII", DX_ACC_PUBLIC, native_noop, false);
    add_method(sparse_int_cls, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);

    DxClass *attr_set_cls = reg_class(vm, "Landroid/util/AttributeSet;", obj);
    add_method(attr_set_cls, "getAttributeCount", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(attr_set_cls, "getAttributeName", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(attr_set_cls, "getAttributeValue", "LI", DX_ACC_PUBLIC, native_return_null, false);

    // --- android.transition.* ---
    DxClass *transition_cls = reg_class(vm, "Landroid/transition/Transition;", obj);
    add_method(transition_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(transition_cls, "addListener", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(transition_cls, "removeListener", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(transition_cls, "setDuration", "LJ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(transition_cls, "setInterpolator", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(transition_cls, "setStartDelay", "LJ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(transition_cls, "addTarget", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(transition_cls, "addTarget", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(transition_cls, "excludeTarget", "LLZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(transition_cls, "excludeTarget", "LIZ", DX_ACC_PUBLIC, native_return_self, false);

    // android.transition.Fade (extends Transition)
    DxClass *fade_cls = reg_class(vm, "Landroid/transition/Fade;", transition_cls);
    add_method(fade_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(fade_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    // android.transition.ChangeBounds (extends Transition)
    DxClass *change_bounds_cls = reg_class(vm, "Landroid/transition/ChangeBounds;", transition_cls);
    add_method(change_bounds_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(change_bounds_cls, "setResizeClip", "VZ", DX_ACC_PUBLIC, native_noop, false);

    // android.transition.TransitionSet (extends Transition)
    DxClass *transition_set_cls = reg_class(vm, "Landroid/transition/TransitionSet;", transition_cls);
    add_method(transition_set_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(transition_set_cls, "addTransition", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(transition_set_cls, "setOrdering", "LI", DX_ACC_PUBLIC,
               native_return_self, false);

    // android.transition.AutoTransition (extends TransitionSet)
    DxClass *auto_transition_cls = reg_class(vm, "Landroid/transition/AutoTransition;", transition_set_cls);
    add_method(auto_transition_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    // android.transition.Slide (extends Transition)
    DxClass *slide_cls = reg_class(vm, "Landroid/transition/Slide;", transition_cls);
    add_method(slide_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(slide_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *transition_mgr_cls = reg_class(vm, "Landroid/transition/TransitionManager;", obj);
    add_method(transition_mgr_cls, "beginDelayedTransition", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(transition_mgr_cls, "beginDelayedTransition", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(transition_mgr_cls, "go", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(transition_mgr_cls, "go", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);

    // ================================================================
    // Timber (timber.log.Timber) - extremely common logging library
    // ================================================================
    DxClass *timber_tree_cls = reg_class(vm, "Ltimber/log/Timber$Tree;", obj);
    add_method(timber_tree_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(timber_tree_cls, "d", "VL", DX_ACC_PUBLIC,
               native_timber_log_debug, false);
    add_method(timber_tree_cls, "i", "VL", DX_ACC_PUBLIC,
               native_timber_log_info, false);
    add_method(timber_tree_cls, "w", "VL", DX_ACC_PUBLIC,
               native_timber_log_warn, false);
    add_method(timber_tree_cls, "e", "VL", DX_ACC_PUBLIC,
               native_timber_log_error, false);
    add_method(timber_tree_cls, "v", "VL", DX_ACC_PUBLIC,
               native_timber_log_verbose, false);
    add_method(timber_tree_cls, "log", "VILL", DX_ACC_PUBLIC,
               native_noop, false);

    DxClass *timber_debug_tree_cls = reg_class(vm, "Ltimber/log/Timber$DebugTree;", timber_tree_cls);
    add_method(timber_debug_tree_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *timber_cls = reg_class(vm, "Ltimber/log/Timber;", obj);
    add_method(timber_cls, "plant", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(timber_cls, "uprootAll", "V", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(timber_cls, "d", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_debug, true);
    add_method(timber_cls, "i", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_info, true);
    add_method(timber_cls, "w", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_warn, true);
    add_method(timber_cls, "e", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_error, true);
    add_method(timber_cls, "v", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_verbose, true);
    add_method(timber_cls, "tag", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true); // returns Timber.Tree, but null is safe
    add_method(timber_cls, "d", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_debug, true); // d(String, Object...)
    add_method(timber_cls, "i", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_info, true);
    add_method(timber_cls, "w", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_warn, true);
    add_method(timber_cls, "e", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_error, true);
    add_method(timber_cls, "v", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_verbose, true);
    add_method(timber_cls, "e", "VLl", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_error, true); // e(Throwable, String)
    add_method(timber_cls, "w", "VLl", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_timber_log_warn, true);

    // ================================================================
    // Gson (com.google.gson) - very common JSON library
    // ================================================================
    DxClass *gson_cls = reg_class(vm, "Lcom/google/gson/Gson;", obj);
    add_method(gson_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(gson_cls, "toJson", "LL", DX_ACC_PUBLIC,
               native_gson_to_json, false);
    add_method(gson_cls, "fromJson", "LLL", DX_ACC_PUBLIC,
               native_return_null, false); // fromJson(String, Class)
    add_method(gson_cls, "fromJson", "LLLL", DX_ACC_PUBLIC,
               native_return_null, false); // fromJson(Reader, Class)
    add_method(gson_cls, "fromJson", "LLl", DX_ACC_PUBLIC,
               native_return_null, false); // fromJson(String, Type)
    add_method(gson_cls, "toJsonTree", "LL", DX_ACC_PUBLIC,
               native_return_null, false);

    DxClass *gson_builder_cls = reg_class(vm, "Lcom/google/gson/GsonBuilder;", obj);
    add_method(gson_builder_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(gson_builder_cls, "create", "L", DX_ACC_PUBLIC,
               native_return_null, false); // ideally returns Gson; null is safe
    add_method(gson_builder_cls, "setPrettyPrinting", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(gson_builder_cls, "setLenient", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(gson_builder_cls, "serializeNulls", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(gson_builder_cls, "disableHtmlEscaping", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(gson_builder_cls, "excludeFieldsWithoutExposeAnnotation", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(gson_builder_cls, "setDateFormat", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(gson_builder_cls, "registerTypeAdapter", "LLL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(gson_builder_cls, "enableComplexMapKeySerialization", "L", DX_ACC_PUBLIC,
               native_return_self, false);

    DxClass *json_element_cls = reg_class(vm, "Lcom/google/gson/JsonElement;", obj);
    add_method(json_element_cls, "getAsString", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_element_cls, "getAsInt", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(json_element_cls, "getAsBoolean", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(json_element_cls, "isJsonNull", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(json_element_cls, "isJsonObject", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(json_element_cls, "isJsonArray", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(json_element_cls, "getAsJsonObject", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_element_cls, "getAsJsonArray", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    DxClass *json_obj_gson_cls = reg_class(vm, "Lcom/google/gson/JsonObject;", json_element_cls);
    add_method(json_obj_gson_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(json_obj_gson_cls, "addProperty", "VLL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(json_obj_gson_cls, "add", "VLL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(json_obj_gson_cls, "get", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_obj_gson_cls, "has", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);

    DxClass *json_arr_gson_cls = reg_class(vm, "Lcom/google/gson/JsonArray;", json_element_cls);
    add_method(json_arr_gson_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(json_arr_gson_cls, "add", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(json_arr_gson_cls, "get", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_arr_gson_cls, "size", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);

    DxClass *json_prim_cls = reg_class(vm, "Lcom/google/gson/JsonPrimitive;", json_element_cls);
    add_method(json_prim_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);

    DxClass *json_null_cls = reg_class(vm, "Lcom/google/gson/JsonNull;", json_element_cls);
    (void)json_null_cls;

    DxClass *type_token_cls = reg_class(vm, "Lcom/google/gson/reflect/TypeToken;", obj);
    add_method(type_token_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(type_token_cls, "getType", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // ================================================================
    // org.json.JSONObject - Android built-in JSON (with field storage)
    // ================================================================
    DxClass *json_obj_cls = reg_class(vm, "Lorg/json/JSONObject;", obj);
    add_method(json_obj_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_json_object_init, false);
    add_method(json_obj_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_json_object_init, false); // <init>(String)
    add_method(json_obj_cls, "put", "LLL", DX_ACC_PUBLIC,
               native_json_object_put, false); // put(String, Object)
    add_method(json_obj_cls, "put", "LLI", DX_ACC_PUBLIC,
               native_json_object_put_int, false); // put(String, int)
    add_method(json_obj_cls, "put", "LLJ", DX_ACC_PUBLIC,
               native_json_object_put_int, false); // put(String, long)
    add_method(json_obj_cls, "put", "LLD", DX_ACC_PUBLIC,
               native_json_object_put_int, false); // put(String, double)
    add_method(json_obj_cls, "put", "LLZ", DX_ACC_PUBLIC,
               native_json_object_put_int, false); // put(String, boolean)
    add_method(json_obj_cls, "get", "LL", DX_ACC_PUBLIC,
               native_json_object_get, false);
    add_method(json_obj_cls, "getString", "LL", DX_ACC_PUBLIC,
               native_json_object_get_string, false);
    add_method(json_obj_cls, "getInt", "IL", DX_ACC_PUBLIC,
               native_json_object_get_int, false);
    add_method(json_obj_cls, "getLong", "JL", DX_ACC_PUBLIC,
               native_json_object_get_long, false);
    add_method(json_obj_cls, "getDouble", "DL", DX_ACC_PUBLIC,
               native_json_object_get_double, false);
    add_method(json_obj_cls, "getBoolean", "ZL", DX_ACC_PUBLIC,
               native_json_object_get_boolean, false);
    add_method(json_obj_cls, "has", "ZL", DX_ACC_PUBLIC,
               native_json_object_has, false);
    add_method(json_obj_cls, "optString", "LL", DX_ACC_PUBLIC,
               native_json_object_opt_string, false); // optString(String)
    add_method(json_obj_cls, "optString", "LLL", DX_ACC_PUBLIC,
               native_json_object_opt_string, false); // optString(String, String)
    add_method(json_obj_cls, "optInt", "IL", DX_ACC_PUBLIC,
               native_json_object_opt_int, false); // optInt(String)
    add_method(json_obj_cls, "optInt", "ILI", DX_ACC_PUBLIC,
               native_json_object_opt_int, false); // optInt(String, int)
    add_method(json_obj_cls, "optLong", "JL", DX_ACC_PUBLIC,
               native_json_object_opt_long, false);
    add_method(json_obj_cls, "optLong", "JLJ", DX_ACC_PUBLIC,
               native_json_object_opt_long, false);
    add_method(json_obj_cls, "optBoolean", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(json_obj_cls, "optBoolean", "ZLZ", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(json_obj_cls, "optDouble", "DL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_obj_cls, "optJSONObject", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_obj_cls, "optJSONArray", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_obj_cls, "getJSONObject", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_obj_cls, "getJSONArray", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_obj_cls, "toString", "L", DX_ACC_PUBLIC,
               native_json_object_to_string, false);
    add_method(json_obj_cls, "toString", "LI", DX_ACC_PUBLIC,
               native_json_object_to_string, false); // toString(int indent)
    add_method(json_obj_cls, "keys", "L", DX_ACC_PUBLIC,
               native_return_null, false); // returns Iterator
    add_method(json_obj_cls, "names", "L", DX_ACC_PUBLIC,
               native_return_null, false); // returns JSONArray
    add_method(json_obj_cls, "length", "I", DX_ACC_PUBLIC,
               native_json_object_length, false);
    add_method(json_obj_cls, "isNull", "ZL", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(json_obj_cls, "remove", "LL", DX_ACC_PUBLIC,
               native_return_null, false);

    // ================================================================
    // org.json.JSONArray - Android built-in JSON array (ArrayList-backed)
    // ================================================================
    DxClass *json_arr_cls = reg_class(vm, "Lorg/json/JSONArray;", obj);
    add_method(json_arr_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_json_array_init, false);
    add_method(json_arr_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_json_array_init, false); // <init>(String)
    add_method(json_arr_cls, "put", "LL", DX_ACC_PUBLIC,
               native_json_array_put, false); // put(Object)
    add_method(json_arr_cls, "put", "LIL", DX_ACC_PUBLIC,
               native_json_array_put_at, false); // put(int, Object)
    add_method(json_arr_cls, "put", "LI", DX_ACC_PUBLIC,
               native_json_array_put, false); // put(int) as value
    add_method(json_arr_cls, "put", "LZ", DX_ACC_PUBLIC,
               native_json_array_put, false); // put(boolean)
    add_method(json_arr_cls, "put", "LD", DX_ACC_PUBLIC,
               native_json_array_put, false); // put(double)
    add_method(json_arr_cls, "put", "LJ", DX_ACC_PUBLIC,
               native_json_array_put, false); // put(long)
    add_method(json_arr_cls, "get", "LI", DX_ACC_PUBLIC,
               native_json_array_get, false);
    add_method(json_arr_cls, "getString", "LI", DX_ACC_PUBLIC,
               native_json_array_get_string, false);
    add_method(json_arr_cls, "getInt", "II", DX_ACC_PUBLIC,
               native_json_array_get_int, false);
    add_method(json_arr_cls, "getLong", "JI", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(json_arr_cls, "getDouble", "DI", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(json_arr_cls, "getBoolean", "ZI", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(json_arr_cls, "getJSONObject", "LI", DX_ACC_PUBLIC,
               native_json_array_get_json_object, false);
    add_method(json_arr_cls, "getJSONArray", "LI", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_arr_cls, "optString", "LI", DX_ACC_PUBLIC,
               native_json_array_get_string, false);
    add_method(json_arr_cls, "optInt", "II", DX_ACC_PUBLIC,
               native_json_array_get_int, false);
    add_method(json_arr_cls, "optJSONObject", "LI", DX_ACC_PUBLIC,
               native_json_array_get_json_object, false);
    add_method(json_arr_cls, "length", "I", DX_ACC_PUBLIC,
               native_json_array_length, false);
    add_method(json_arr_cls, "toString", "L", DX_ACC_PUBLIC,
               native_json_array_to_string, false);
    add_method(json_arr_cls, "toString", "LI", DX_ACC_PUBLIC,
               native_json_array_to_string, false); // toString(int indent)
    add_method(json_arr_cls, "isNull", "ZI", DX_ACC_PUBLIC,
               native_return_false, false);

    // ================================================================
    // org.json.JSONException
    // ================================================================
    DxClass *json_exc_cls = reg_class(vm, "Lorg/json/JSONException;", obj);
    add_method(json_exc_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(json_exc_cls, "getMessage", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // ================================================================
    // Moshi (com.squareup.moshi) - alternative JSON library
    // ================================================================
    DxClass *moshi_cls = reg_class(vm, "Lcom/squareup/moshi/Moshi;", obj);
    add_method(moshi_cls, "adapter", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(moshi_cls, "adapter", "LLL", DX_ACC_PUBLIC,
               native_return_null, false);

    DxClass *moshi_builder_cls = reg_class(vm, "Lcom/squareup/moshi/Moshi$Builder;", obj);
    add_method(moshi_builder_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(moshi_builder_cls, "build", "L", DX_ACC_PUBLIC,
               native_return_null, false); // returns Moshi
    add_method(moshi_builder_cls, "add", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(moshi_builder_cls, "add", "LLL", DX_ACC_PUBLIC,
               native_return_self, false);

    DxClass *json_adapter_cls = reg_class(vm, "Lcom/squareup/moshi/JsonAdapter;", obj);
    add_method(json_adapter_cls, "fromJson", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_adapter_cls, "toJson", "LL", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(json_adapter_cls, "lenient", "L", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(json_adapter_cls, "nullSafe", "L", DX_ACC_PUBLIC,
               native_return_self, false);

    // --- StringBuilder/StringBuffer ---
    DxClass *string_builder_cls = reg_class(vm, "Ljava/lang/StringBuilder;", obj);
    add_method(string_builder_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(string_builder_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(string_builder_cls, "append", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(string_builder_cls, "appendI", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(string_builder_cls, "appendC", "LC", DX_ACC_PUBLIC, native_return_self, false);
    add_method(string_builder_cls, "toString", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(string_builder_cls, "length", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(string_builder_cls, "delete", "LII", DX_ACC_PUBLIC, native_return_self, false);
    add_method(string_builder_cls, "insert", "LIL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *string_buffer_cls = reg_class(vm, "Ljava/lang/StringBuffer;", obj);
    add_method(string_buffer_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(string_buffer_cls, "append", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(string_buffer_cls, "toString", "L", DX_ACC_PUBLIC, native_return_null, false);

    // --- Kotlin stdlib (very common in modern APKs) ---
    DxClass *kotlin_intrinsics = reg_class(vm, "Lkotlin/jvm/internal/Intrinsics;", obj);
    add_method(kotlin_intrinsics, "checkNotNullParameter", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(kotlin_intrinsics, "checkNotNull", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(kotlin_intrinsics, "checkNotNullExpressionValue", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(kotlin_intrinsics, "checkParameterIsNotNull", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(kotlin_intrinsics, "checkExpressionValueIsNotNull", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);
    add_method(kotlin_intrinsics, "areEqual", "ZLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);
    add_method(kotlin_intrinsics, "throwUninitializedPropertyAccessException", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_noop, true);

    DxClass *kotlin_unit = reg_class(vm, "Lkotlin/Unit;", obj);
    add_method(kotlin_unit, "toString", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *kotlin_lazy = reg_class(vm, "Lkotlin/Lazy;", obj);
    add_method(kotlin_lazy, "getValue", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(kotlin_lazy, "isInitialized", "Z", DX_ACC_PUBLIC, native_return_true, false);

    // kotlin.LazyKt — lazy {} initializer helper
    DxClass *kotlin_lazy_kt = reg_class(vm, "Lkotlin/LazyKt;", obj);
    add_method(kotlin_lazy_kt, "lazy", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_kotlin_lazy, true);

    // kotlin.LazyKt__LazyJVMKt — JVM implementation of lazy {}
    DxClass *kotlin_lazy_jvm = reg_class(vm, "Lkotlin/LazyKt__LazyJVMKt;", obj);
    add_method(kotlin_lazy_jvm, "lazy", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_kotlin_lazy, true);

    DxClass *kotlin_pair = reg_class(vm, "Lkotlin/Pair;", obj);
    add_method(kotlin_pair, "<init>", "VLL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, false);
    add_method(kotlin_pair, "getFirst", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(kotlin_pair, "getSecond", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *kotlin_collections = reg_class(vm, "Lkotlin/collections/CollectionsKt;", obj);
    add_method(kotlin_collections, "listOf", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(kotlin_collections, "emptyList", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_empty_list, true);
    add_method(kotlin_collections, "mutableListOf", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // kotlin.collections.MapsKt
    DxClass *kotlin_maps = reg_class(vm, "Lkotlin/collections/MapsKt;", obj);
    add_method(kotlin_maps, "mapOf", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(kotlin_maps, "emptyMap", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_empty_map, true);
    add_method(kotlin_maps, "mutableMapOf", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(kotlin_maps, "hashMapOf", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // kotlin.collections.ArraysKt
    DxClass *kotlin_arrays = reg_class(vm, "Lkotlin/collections/ArraysKt;", obj);
    add_method(kotlin_arrays, "arrayListOf", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // kotlin.Result
    DxClass *kotlin_result = reg_class(vm, "Lkotlin/Result;", obj);
    add_method(kotlin_result, "isSuccess", "Z", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(kotlin_result, "isFailure", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(kotlin_result, "getOrNull", "L", DX_ACC_PUBLIC,
               native_return_null, false);
    add_method(kotlin_result, "exceptionOrNull", "L", DX_ACC_PUBLIC,
               native_return_null, false);

    // kotlin.text.StringsKt (very common in Kotlin apps)
    DxClass *kotlin_strings = reg_class(vm, "Lkotlin/text/StringsKt;", obj);
    add_method(kotlin_strings, "isBlank", "ZL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);
    add_method(kotlin_strings, "trim", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_arg0, true);
    add_method(kotlin_strings, "isNullOrEmpty", "ZL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);
    add_method(kotlin_strings, "isNullOrBlank", "ZL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_false, true);

    // ---- Kotlin coroutines & Flow stubs (extremely common) ----

    // kotlin.coroutines.CoroutineContext
    DxClass *coroutine_ctx = reg_class(vm, "Lkotlin/coroutines/CoroutineContext;", obj);
    add_method(coroutine_ctx, "get", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(coroutine_ctx, "plus", "LL", DX_ACC_PUBLIC, native_coroutine_context_plus, false);

    // kotlin.coroutines.CoroutineContext.Key (marker interface)
    DxClass *ctx_key = reg_class(vm, "Lkotlin/coroutines/CoroutineContext$Key;", obj);
    (void)ctx_key;

    // kotlinx.coroutines.CoroutineDispatcher
    DxClass *coroutine_disp = reg_class(vm, "Lkotlinx/coroutines/CoroutineDispatcher;", coroutine_ctx);
    add_method(coroutine_disp, "dispatch", "VLL", DX_ACC_PUBLIC, native_noop, false);

    // kotlinx.coroutines.CoroutineScope
    DxClass *coroutine_scope = reg_class(vm, "Lkotlinx/coroutines/CoroutineScope;", obj);
    add_method(coroutine_scope, "getCoroutineContext", "L", DX_ACC_PUBLIC,
               native_scope_get_context, false);

    // kotlinx.coroutines.Job
    DxClass *job_cls = reg_class(vm, "Lkotlinx/coroutines/Job;", obj);
    add_method(job_cls, "isActive", "Z", DX_ACC_PUBLIC, native_return_true, false);
    add_method(job_cls, "isCancelled", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(job_cls, "isCompleted", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(job_cls, "cancel", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(job_cls, "cancel", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(job_cls, "join", "V", DX_ACC_PUBLIC, native_noop, false);

    // kotlinx.coroutines.Deferred (extends Job)
    DxClass *deferred_cls = reg_class(vm, "Lkotlinx/coroutines/Deferred;", job_cls);
    add_method(deferred_cls, "await", "L", DX_ACC_PUBLIC, native_deferred_await, false);
    add_method(deferred_cls, "getCompleted", "L", DX_ACC_PUBLIC, native_deferred_await, false);

    // kotlinx.coroutines.Dispatchers
    DxClass *dispatchers = reg_class(vm, "Lkotlinx/coroutines/Dispatchers;", obj);
    add_method(dispatchers, "getMain", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_dispatchers_get, true);
    add_method(dispatchers, "getIO", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_dispatchers_get, true);
    add_method(dispatchers, "getDefault", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_dispatchers_get, true);
    add_method(dispatchers, "getUnconfined", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_dispatchers_get, true);

    // kotlinx.coroutines.Dispatchers$Main (alias)
    DxClass *disp_main = reg_class(vm, "Lkotlinx/coroutines/Dispatchers$Main;", coroutine_disp);
    (void)disp_main;

    // kotlinx.coroutines.GlobalScope (singleton, extends CoroutineScope)
    DxClass *global_scope = reg_class(vm, "Lkotlinx/coroutines/GlobalScope;", coroutine_scope);
    add_method(global_scope, "getCoroutineContext", "L", DX_ACC_PUBLIC,
               native_scope_get_context, false);

    // kotlinx.coroutines.CoroutineScopeKt — launch/async builder functions
    DxClass *scope_kt = reg_class(vm, "Lkotlinx/coroutines/CoroutineScopeKt;", obj);
    add_method(scope_kt, "launch", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_launch, true);
    add_method(scope_kt, "async", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_async, true);

    // kotlinx.coroutines.BuildersKt — alternate location for launch/async
    DxClass *builders_kt = reg_class(vm, "Lkotlinx/coroutines/BuildersKt;", obj);
    add_method(builders_kt, "launch", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_launch, true);
    add_method(builders_kt, "launch$default", "LLLLIL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_launch, true);
    add_method(builders_kt, "async", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_async, true);
    add_method(builders_kt, "async$default", "LLLLIL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_async, true);
    add_method(builders_kt, "withContext", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_launch, true);
    add_method(builders_kt, "runBlocking", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_launch, true);
    add_method(builders_kt, "runBlocking$default", "LLLIL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_launch, true);

    // kotlinx.coroutines.BuildersKt__Builders_commonKt (Kotlin internal name mangling)
    DxClass *builders_common = reg_class(vm, "Lkotlinx/coroutines/BuildersKt__Builders_commonKt;", obj);
    add_method(builders_common, "launch", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_launch, true);
    add_method(builders_common, "launch$default", "LLLLIL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_launch, true);
    add_method(builders_common, "async", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_async, true);
    add_method(builders_common, "withContext", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_coroutine_launch, true);

    // kotlinx.coroutines.DelayKt — delay() is a no-op
    DxClass *delay_kt = reg_class(vm, "Lkotlinx/coroutines/DelayKt;", obj);
    add_method(delay_kt, "delay", "VJ", DX_ACC_PUBLIC | DX_ACC_STATIC, native_noop, true);
    add_method(delay_kt, "delay", "VJL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_noop, true);

    // kotlinx.coroutines.SupervisorKt
    DxClass *supervisor_kt = reg_class(vm, "Lkotlinx/coroutines/SupervisorKt;", obj);
    add_method(supervisor_kt, "SupervisorJob", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // kotlinx.coroutines.NonCancellable
    DxClass *non_cancel = reg_class(vm, "Lkotlinx/coroutines/NonCancellable;", job_cls);
    (void)non_cancel;

    // ---- Kotlin Flow stubs ----

    // kotlinx.coroutines.flow.Flow (interface)
    DxClass *flow_cls = reg_class(vm, "Lkotlinx/coroutines/flow/Flow;", obj);
    add_method(flow_cls, "collect", "VL", DX_ACC_PUBLIC, native_noop, false);

    // kotlinx.coroutines.flow.FlowCollector (interface)
    DxClass *flow_collector = reg_class(vm, "Lkotlinx/coroutines/flow/FlowCollector;", obj);
    add_method(flow_collector, "emit", "VL", DX_ACC_PUBLIC, native_noop, false);

    // kotlinx.coroutines.flow.SharedFlow (extends Flow)
    DxClass *shared_flow = reg_class(vm, "Lkotlinx/coroutines/flow/SharedFlow;", flow_cls);
    add_method(shared_flow, "collect", "VL", DX_ACC_PUBLIC, native_noop, false);

    // kotlinx.coroutines.flow.MutableSharedFlow (extends SharedFlow)
    DxClass *mut_shared_flow = reg_class(vm, "Lkotlinx/coroutines/flow/MutableSharedFlow;", shared_flow);
    add_method(mut_shared_flow, "emit", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(mut_shared_flow, "tryEmit", "ZL", DX_ACC_PUBLIC, native_return_true, false);
    add_method(mut_shared_flow, "collect", "VL", DX_ACC_PUBLIC, native_noop, false);

    // kotlinx.coroutines.flow.StateFlow (extends SharedFlow)
    DxClass *state_flow = reg_class(vm, "Lkotlinx/coroutines/flow/StateFlow;", shared_flow);
    add_method(state_flow, "getValue", "L", DX_ACC_PUBLIC, native_stateflow_get_value, false);
    add_method(state_flow, "collect", "VL", DX_ACC_PUBLIC, native_noop, false);

    // kotlinx.coroutines.flow.MutableStateFlow (extends StateFlow)
    DxClass *mut_state_flow = reg_class(vm, "Lkotlinx/coroutines/flow/MutableStateFlow;", state_flow);
    add_method(mut_state_flow, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_mutable_stateflow_init, true);
    add_method(mut_state_flow, "getValue", "L", DX_ACC_PUBLIC, native_stateflow_get_value, false);
    add_method(mut_state_flow, "setValue", "VL", DX_ACC_PUBLIC, native_stateflow_set_value, false);
    add_method(mut_state_flow, "emit", "VL", DX_ACC_PUBLIC, native_stateflow_set_value, false);
    add_method(mut_state_flow, "collect", "VL", DX_ACC_PUBLIC, native_noop, false);

    // kotlinx.coroutines.flow.FlowKt — flow builder helpers
    DxClass *flow_kt = reg_class(vm, "Lkotlinx/coroutines/flow/FlowKt;", obj);
    add_method(flow_kt, "flowOf", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(flow_kt, "emptyFlow", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(flow_kt, "asFlow", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // kotlinx.coroutines.flow.StateFlowKt — MutableStateFlow() factory
    DxClass *stateflow_kt = reg_class(vm, "Lkotlinx/coroutines/flow/StateFlowKt;", obj);
    add_method(stateflow_kt, "MutableStateFlow", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_arg0, true);

    // kotlinx.coroutines.flow.SharedFlowKt — MutableSharedFlow() factory
    DxClass *sharedflow_kt = reg_class(vm, "Lkotlinx/coroutines/flow/SharedFlowKt;", obj);
    add_method(sharedflow_kt, "MutableSharedFlow", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    add_method(sharedflow_kt, "MutableSharedFlow", "LIIZ", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // --- Annotation framework ---
    DxClass *annotation_cls = reg_class(vm, "Ljava/lang/annotation/Annotation;", obj);
    annotation_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_PUBLIC;
    // field[0] = DxAnnotationEntry* (as int), field[1] = index into class/method annotations
    annotation_cls->instance_field_count = 2;
    annotation_cls->field_defs = (typeof(annotation_cls->field_defs))dx_malloc(sizeof(*annotation_cls->field_defs) * 2);
    if (annotation_cls->field_defs) {
        annotation_cls->field_defs[0].name = "__anno_ptr";
        annotation_cls->field_defs[0].type = "I";
        annotation_cls->field_defs[0].flags = DX_ACC_PRIVATE;
        annotation_cls->field_defs[1].name = "__anno_idx";
        annotation_cls->field_defs[1].type = "I";
        annotation_cls->field_defs[1].flags = DX_ACC_PRIVATE;
    }
    add_method(annotation_cls, "value", "L", DX_ACC_PUBLIC, native_annotation_value, false);
    add_method(annotation_cls, "annotationType", "L", DX_ACC_PUBLIC, native_annotation_annotation_type, false);

    DxClass *retention_cls = reg_class(vm, "Ljava/lang/annotation/Retention;", obj);
    (void)retention_cls;

    DxClass *target_cls = reg_class(vm, "Ljava/lang/annotation/Target;", obj);
    (void)target_cls;

    DxClass *documented_cls = reg_class(vm, "Ljava/lang/annotation/Documented;", obj);
    (void)documented_cls;

    // Common AndroidX annotations
    DxClass *nullable_cls = reg_class(vm, "Landroidx/annotation/Nullable;", obj);
    (void)nullable_cls;
    DxClass *nonnull_cls = reg_class(vm, "Landroidx/annotation/NonNull;", obj);
    (void)nonnull_cls;
    DxClass *stringres_cls = reg_class(vm, "Landroidx/annotation/StringRes;", obj);
    (void)stringres_cls;
    DxClass *drawableres_cls = reg_class(vm, "Landroidx/annotation/DrawableRes;", obj);
    (void)drawableres_cls;
    DxClass *colorint_cls = reg_class(vm, "Landroidx/annotation/ColorInt;", obj);
    (void)colorint_cls;
    DxClass *layoutres_cls = reg_class(vm, "Landroidx/annotation/LayoutRes;", obj);
    (void)layoutres_cls;
    DxClass *idres_cls = reg_class(vm, "Landroidx/annotation/IdRes;", obj);
    (void)idres_cls;
    DxClass *keep_cls = reg_class(vm, "Landroidx/annotation/Keep;", obj);
    (void)keep_cls;
    DxClass *mainthread_cls = reg_class(vm, "Landroidx/annotation/MainThread;", obj);
    (void)mainthread_cls;
    DxClass *workerthread_cls = reg_class(vm, "Landroidx/annotation/WorkerThread;", obj);
    (void)workerthread_cls;
    DxClass *uithread_cls = reg_class(vm, "Landroidx/annotation/UiThread;", obj);
    (void)uithread_cls;
    DxClass *callsuper_cls = reg_class(vm, "Landroidx/annotation/CallSuper;", obj);
    (void)callsuper_cls;
    DxClass *visiblefortesting_cls = reg_class(vm, "Landroidx/annotation/VisibleForTesting;", obj);
    (void)visiblefortesting_cls;

    // Kotlin annotations
    DxClass *jvmstatic_cls = reg_class(vm, "Lkotlin/jvm/JvmStatic;", obj);
    (void)jvmstatic_cls;
    DxClass *jvmfield_cls = reg_class(vm, "Lkotlin/jvm/JvmField;", obj);
    (void)jvmfield_cls;
    DxClass *jvmoverloads_cls = reg_class(vm, "Lkotlin/jvm/JvmOverloads;", obj);
    (void)jvmoverloads_cls;
    DxClass *metadata_cls = reg_class(vm, "Lkotlin/Metadata;", obj);
    (void)metadata_cls;
    DxClass *deprecated_cls = reg_class(vm, "Lkotlin/Deprecated;", obj);
    (void)deprecated_cls;

    // --- javax.inject (JSR-330 dependency injection) ---
    DxClass *inject_cls = reg_class(vm, "Ljavax/inject/Inject;", obj);
    inject_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *singleton_cls = reg_class(vm, "Ljavax/inject/Singleton;", obj);
    singleton_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *named_cls = reg_class(vm, "Ljavax/inject/Named;", obj);
    named_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *javax_provider_cls = reg_class(vm, "Ljavax/inject/Provider;", obj);
    javax_provider_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(javax_provider_cls, "get", "L", DX_ACC_PUBLIC, native_return_null, false);

    // --- Dagger core ---
    DxClass *dagger_module_cls = reg_class(vm, "Ldagger/Module;", obj);
    dagger_module_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *dagger_provides_cls = reg_class(vm, "Ldagger/Provides;", obj);
    dagger_provides_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *dagger_binds_cls = reg_class(vm, "Ldagger/Binds;", obj);
    dagger_binds_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *dagger_component_cls = reg_class(vm, "Ldagger/Component;", obj);
    dagger_component_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *dagger_subcomponent_cls = reg_class(vm, "Ldagger/Subcomponent;", obj);
    dagger_subcomponent_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *dagger_lazy_cls = reg_class(vm, "Ldagger/Lazy;", obj);
    dagger_lazy_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(dagger_lazy_cls, "get", "L", DX_ACC_PUBLIC, native_return_null, false);

    // --- Dagger Hilt ---
    DxClass *hilt_android_app_cls = reg_class(vm, "Ldagger/hilt/android/HiltAndroidApp;", obj);
    hilt_android_app_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *hilt_entry_point_cls = reg_class(vm, "Ldagger/hilt/android/AndroidEntryPoint;", obj);
    hilt_entry_point_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *hilt_install_in_cls = reg_class(vm, "Ldagger/hilt/InstallIn;", obj);
    hilt_install_in_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    DxClass *hilt_singleton_comp_cls = reg_class(vm, "Ldagger/hilt/components/SingletonComponent;", obj);
    hilt_singleton_comp_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *hilt_viewmodel_cls = reg_class(vm, "Ldagger/hilt/android/lifecycle/HiltViewModel;", obj);
    hilt_viewmodel_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT | DX_ACC_ANNOTATION;

    // --- RxJava / RxAndroid stubs (extremely common in older apps) ---
    // RxJava1
    DxClass *rx_observable = reg_class(vm, "Lrx/Observable;", obj);
    add_method(rx_observable, "subscribe", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx_observable, "subscribe", "LLL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx_observable, "unsubscribe", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx_observable, "observeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx_observable, "subscribeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx_observable, "just", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx_observable, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx_observable, "empty", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx_observable, "map", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx_observable, "flatMap", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx_observable, "filter", "LL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *rx_subscriber = reg_class(vm, "Lrx/Subscriber;", obj);
    add_method(rx_subscriber, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(rx_subscriber, "onNext", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx_subscriber, "onError", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx_subscriber, "onCompleted", "V", DX_ACC_PUBLIC, native_noop, false);

    DxClass *rx_subscription = reg_class(vm, "Lrx/Subscription;", obj);
    add_method(rx_subscription, "unsubscribe", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx_subscription, "isUnsubscribed", "Z", DX_ACC_PUBLIC, native_return_true, false);

    DxClass *rx_schedulers = reg_class(vm, "Lrx/schedulers/Schedulers;", obj);
    add_method(rx_schedulers, "io", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx_schedulers, "computation", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx_schedulers, "newThread", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx_schedulers, "immediate", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx_schedulers, "from", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx_schedulers, "shutdown", "V", DX_ACC_PUBLIC | DX_ACC_STATIC, native_noop, true);
    add_method(rx_schedulers, "start", "V", DX_ACC_PUBLIC | DX_ACC_STATIC, native_noop, true);

    DxClass *rx_scheduler = reg_class(vm, "Lrx/Scheduler;", obj);
    add_method(rx_scheduler, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(rx_scheduler, "createWorker", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx_scheduler, "shutdown", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx_scheduler, "start", "V", DX_ACC_PUBLIC, native_noop, false);

    DxClass *rx_android_schedulers = reg_class(vm, "Lrx/android/schedulers/AndroidSchedulers;", obj);
    add_method(rx_android_schedulers, "mainThread", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    // RxJava internal obfuscated classes (commonly seen in Aptoide, etc.)
    DxClass *rx_nck = reg_class(vm, "Lrx/n/c/k;", obj);
    add_method(rx_nck, "shutdown", "V", DX_ACC_PUBLIC | DX_ACC_STATIC, native_noop, true);
    add_method(rx_nck, "start", "V", DX_ACC_PUBLIC | DX_ACC_STATIC, native_noop, true);
    add_method(rx_nck, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);

    DxClass *rx_ncbb = reg_class(vm, "Lrx/n/c/b$b;", obj);
    add_method(rx_ncbb, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(rx_ncbb, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);

    DxClass *rx_ncb = reg_class(vm, "Lrx/n/c/b;", obj);
    add_method(rx_ncb, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(rx_ncb, "shutdown", "V", DX_ACC_PUBLIC, native_noop, false);

    // RxJava2 (io.reactivex)
    DxClass *rx2_observable = reg_class(vm, "Lio/reactivex/Observable;", obj);
    add_method(rx2_observable, "subscribe", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx2_observable, "observeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx2_observable, "subscribeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx2_observable, "just", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx2_observable, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx2_observable, "map", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx2_observable, "flatMap", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx2_observable, "filter", "LL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *rx2_single = reg_class(vm, "Lio/reactivex/Single;", obj);
    add_method(rx2_single, "subscribe", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx2_single, "observeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx2_single, "subscribeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx2_single, "just", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx2_single, "map", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx2_single, "flatMap", "LL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *rx2_completable = reg_class(vm, "Lio/reactivex/Completable;", obj);
    add_method(rx2_completable, "subscribe", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx2_completable, "subscribeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx2_completable, "observeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx2_completable, "complete", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx2_completable, "andThen", "LL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *rx2_schedulers = reg_class(vm, "Lio/reactivex/schedulers/Schedulers;", obj);
    add_method(rx2_schedulers, "io", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx2_schedulers, "computation", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx2_schedulers, "newThread", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx2_schedulers, "single", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx2_schedulers, "shutdown", "V", DX_ACC_PUBLIC | DX_ACC_STATIC, native_noop, true);

    DxClass *rx2_android_schedulers = reg_class(vm, "Lio/reactivex/android/schedulers/AndroidSchedulers;", obj);
    add_method(rx2_android_schedulers, "mainThread", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);

    DxClass *rx2_disposable = reg_class(vm, "Lio/reactivex/disposables/Disposable;", obj);
    rx2_disposable->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(rx2_disposable, "dispose", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx2_disposable, "isDisposed", "Z", DX_ACC_PUBLIC, native_return_false, false);

    DxClass *rx2_composite = reg_class(vm, "Lio/reactivex/disposables/CompositeDisposable;", obj);
    add_method(rx2_composite, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(rx2_composite, "add", "ZL", DX_ACC_PUBLIC, native_return_true, false);
    add_method(rx2_composite, "dispose", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx2_composite, "clear", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx2_composite, "isDisposed", "Z", DX_ACC_PUBLIC, native_return_false, false);

    // RxJava3 (io.reactivex.rxjava3) - most common in modern apps
    DxClass *rx3_observable = reg_class(vm, "Lio/reactivex/rxjava3/core/Observable;", obj);
    add_method(rx3_observable, "subscribe", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx3_observable, "subscribe", "LLLL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx3_observable, "map", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "flatMap", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "filter", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "observeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "subscribeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "just", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_observable, "fromIterable", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_observable, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_observable, "empty", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_observable, "defer", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_observable, "doOnNext", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "doOnError", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "doOnComplete", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "toList", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx3_observable, "distinctUntilChanged", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "take", "LJ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "skip", "LJ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "debounce", "LJL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "switchMap", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_observable, "concatMap", "LL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *rx3_single = reg_class(vm, "Lio/reactivex/rxjava3/core/Single;", obj);
    add_method(rx3_single, "subscribe", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx3_single, "observeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_single, "subscribeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_single, "just", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_single, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_single, "map", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_single, "flatMap", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_single, "doOnSuccess", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_single, "doOnError", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_single, "toObservable", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *rx3_completable = reg_class(vm, "Lio/reactivex/rxjava3/core/Completable;", obj);
    add_method(rx3_completable, "subscribe", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx3_completable, "subscribeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_completable, "observeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_completable, "complete", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_completable, "andThen", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_completable, "doOnComplete", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_completable, "doOnError", "LL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *rx3_maybe = reg_class(vm, "Lio/reactivex/rxjava3/core/Maybe;", obj);
    add_method(rx3_maybe, "subscribe", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx3_maybe, "map", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_maybe, "flatMap", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_maybe, "observeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_maybe, "subscribeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_maybe, "just", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_maybe, "empty", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_maybe, "doOnSuccess", "LL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *rx3_flowable = reg_class(vm, "Lio/reactivex/rxjava3/core/Flowable;", obj);
    add_method(rx3_flowable, "subscribe", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx3_flowable, "map", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_flowable, "flatMap", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_flowable, "filter", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_flowable, "observeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_flowable, "subscribeOn", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(rx3_flowable, "just", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_flowable, "fromIterable", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_flowable, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_flowable, "toObservable", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *rx3_disposable = reg_class(vm, "Lio/reactivex/rxjava3/disposables/Disposable;", obj);
    rx3_disposable->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(rx3_disposable, "dispose", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx3_disposable, "isDisposed", "Z", DX_ACC_PUBLIC, native_return_false, false);

    DxClass *rx3_composite = reg_class(vm, "Lio/reactivex/rxjava3/disposables/CompositeDisposable;", obj);
    add_method(rx3_composite, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(rx3_composite, "add", "ZL", DX_ACC_PUBLIC, native_return_true, false);
    add_method(rx3_composite, "dispose", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx3_composite, "clear", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(rx3_composite, "isDisposed", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(rx3_composite, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(rx3_composite, "delete", "ZL", DX_ACC_PUBLIC, native_return_true, false);

    DxClass *rx3_schedulers = reg_class(vm, "Lio/reactivex/rxjava3/schedulers/Schedulers;", obj);
    add_method(rx3_schedulers, "io", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_schedulers, "computation", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_schedulers, "newThread", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_schedulers, "single", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_schedulers, "trampoline", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_schedulers, "shutdown", "V", DX_ACC_PUBLIC | DX_ACC_STATIC, native_noop, true);

    DxClass *rx3_android_schedulers = reg_class(vm, "Lio/reactivex/rxjava3/android/schedulers/AndroidSchedulers;", obj);
    add_method(rx3_android_schedulers, "mainThread", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    DxClass *rx3_scheduler = reg_class(vm, "Lio/reactivex/rxjava3/core/Scheduler;", obj);
    add_method(rx3_scheduler, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(rx3_scheduler, "createWorker", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(rx3_scheduler, "scheduleDirect", "LLL", DX_ACC_PUBLIC, native_return_null, false);

    // --- OkHttp3 stubs (com.squareup.okhttp3) ---
    DxClass *okhttp_client = reg_class(vm, "Lokhttp3/OkHttpClient;", obj);
    add_method(okhttp_client, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_client, "newCall", "LL", DX_ACC_PUBLIC, native_okhttp_client_new_call, false);
    add_method(okhttp_client, "dispatcher", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_client, "connectionPool", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_client, "interceptors", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_client, "networkInterceptors", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_client, "cache", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_client, "newBuilder", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_builder = reg_class(vm, "Lokhttp3/OkHttpClient$Builder;", obj);
    add_method(okhttp_builder, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_builder, "build", "L", DX_ACC_PUBLIC, native_okhttp_client_builder_build, false);
    add_method(okhttp_builder, "connectTimeout", "LJL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "readTimeout", "LJL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "writeTimeout", "LJL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "callTimeout", "LJL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "addInterceptor", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "addNetworkInterceptor", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "cache", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "cookieJar", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "dns", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "followRedirects", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "followSslRedirects", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "hostnameVerifier", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "sslSocketFactory", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "retryOnConnectionFailure", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "proxy", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "certificatePinner", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "authenticator", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "dispatcher", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "connectionPool", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "protocols", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "connectionSpecs", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "eventListenerFactory", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_builder, "pingInterval", "LJL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *okhttp_request = reg_class(vm, "Lokhttp3/Request;", obj);
    okhttp_request->instance_field_count = 5;
    add_method(okhttp_request, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_request, "url", "L", DX_ACC_PUBLIC, native_okhttp_request_url, false);
    add_method(okhttp_request, "method", "L", DX_ACC_PUBLIC, native_okhttp_request_method, false);
    add_method(okhttp_request, "headers", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_request, "body", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_request, "header", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_request, "newBuilder", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_request, "tag", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_req_builder = reg_class(vm, "Lokhttp3/Request$Builder;", obj);
    okhttp_req_builder->instance_field_count = 5;
    add_method(okhttp_req_builder, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_req_builder, "url", "LL", DX_ACC_PUBLIC, native_okhttp_req_builder_url, false);
    add_method(okhttp_req_builder, "build", "L", DX_ACC_PUBLIC, native_okhttp_req_builder_build, false);
    add_method(okhttp_req_builder, "addHeader", "LLL", DX_ACC_PUBLIC, native_okhttp_req_builder_add_header, false);
    add_method(okhttp_req_builder, "header", "LLL", DX_ACC_PUBLIC, native_okhttp_req_builder_add_header, false);
    add_method(okhttp_req_builder, "removeHeader", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_req_builder, "get", "L", DX_ACC_PUBLIC, native_okhttp_req_builder_get, false);
    add_method(okhttp_req_builder, "post", "LL", DX_ACC_PUBLIC, native_okhttp_req_builder_post, false);
    add_method(okhttp_req_builder, "put", "LL", DX_ACC_PUBLIC, native_okhttp_req_builder_put, false);
    add_method(okhttp_req_builder, "delete", "L", DX_ACC_PUBLIC, native_okhttp_req_builder_delete, false);
    add_method(okhttp_req_builder, "delete", "LL", DX_ACC_PUBLIC, native_okhttp_req_builder_delete, false);
    add_method(okhttp_req_builder, "patch", "LL", DX_ACC_PUBLIC, native_okhttp_req_builder_patch, false);
    add_method(okhttp_req_builder, "method", "LLL", DX_ACC_PUBLIC, native_okhttp_req_builder_method, false);
    add_method(okhttp_req_builder, "tag", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_req_builder, "cacheControl", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_req_builder, "headers", "LL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *okhttp_response = reg_class(vm, "Lokhttp3/Response;", obj);
    okhttp_response->instance_field_count = 4; // [0]=status, [1]=body, [2]=request, [3]=headers
    add_method(okhttp_response, "code", "I", DX_ACC_PUBLIC, native_okhttp_response_code, false);
    add_method(okhttp_response, "body", "L", DX_ACC_PUBLIC, native_okhttp_response_body, false);
    add_method(okhttp_response, "isSuccessful", "Z", DX_ACC_PUBLIC, native_okhttp_response_is_successful, false);
    add_method(okhttp_response, "message", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_response, "headers", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_response, "header", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_response, "request", "L", DX_ACC_PUBLIC, native_okhttp_response_request, false);
    add_method(okhttp_response, "protocol", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_response, "close", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(okhttp_response, "newBuilder", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_response, "cacheResponse", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_response, "networkResponse", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_resp_builder = reg_class(vm, "Lokhttp3/Response$Builder;", obj);
    add_method(okhttp_resp_builder, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_resp_builder, "code", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_resp_builder, "message", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_resp_builder, "body", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_resp_builder, "request", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_resp_builder, "protocol", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_resp_builder, "header", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_resp_builder, "addHeader", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_resp_builder, "build", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_resp_body = reg_class(vm, "Lokhttp3/ResponseBody;", obj);
    okhttp_resp_body->instance_field_count = 2; // [0]=body string, [1]=body bytes ptr
    add_method(okhttp_resp_body, "string", "L", DX_ACC_PUBLIC, native_okhttp_resp_body_string, false);
    add_method(okhttp_resp_body, "bytes", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_resp_body, "byteStream", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_resp_body, "charStream", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_resp_body, "source", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_resp_body, "contentType", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_resp_body, "contentLength", "J", DX_ACC_PUBLIC, native_return_long_zero, false);
    add_method(okhttp_resp_body, "close", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(okhttp_resp_body, "create", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    DxClass *okhttp_req_body = reg_class(vm, "Lokhttp3/RequestBody;", obj);
    add_method(okhttp_req_body, "create", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(okhttp_req_body, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(okhttp_req_body, "contentType", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_req_body, "contentLength", "J", DX_ACC_PUBLIC, native_return_long_zero, false);
    add_method(okhttp_req_body, "writeTo", "VL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *okhttp_media_type = reg_class(vm, "Lokhttp3/MediaType;", obj);
    add_method(okhttp_media_type, "parse", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(okhttp_media_type, "get", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(okhttp_media_type, "type", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_media_type, "subtype", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_media_type, "charset", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_call = reg_class(vm, "Lokhttp3/Call;", obj);
    okhttp_call->instance_field_count = 1; // [0]=Request
    add_method(okhttp_call, "execute", "L", DX_ACC_PUBLIC, native_okhttp_call_execute, false);
    add_method(okhttp_call, "enqueue", "VL", DX_ACC_PUBLIC, native_okhttp_call_enqueue, false);
    add_method(okhttp_call, "cancel", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(okhttp_call, "isExecuted", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(okhttp_call, "isCanceled", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(okhttp_call, "clone", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_call, "request", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_callback = reg_class(vm, "Lokhttp3/Callback;", obj);
    okhttp_callback->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(okhttp_callback, "onResponse", "VLL", DX_ACC_PUBLIC, native_noop, false);
    add_method(okhttp_callback, "onFailure", "VLL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *okhttp_interceptor = reg_class(vm, "Lokhttp3/Interceptor;", obj);
    okhttp_interceptor->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(okhttp_interceptor, "intercept", "LL", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_interceptor_chain = reg_class(vm, "Lokhttp3/Interceptor$Chain;", obj);
    okhttp_interceptor_chain->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(okhttp_interceptor_chain, "request", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_interceptor_chain, "proceed", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_interceptor_chain, "connection", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_headers = reg_class(vm, "Lokhttp3/Headers;", obj);
    add_method(okhttp_headers, "get", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_headers, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(okhttp_headers, "name", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_headers, "value", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_headers, "names", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_headers, "values", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_headers, "newBuilder", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_headers, "of", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    DxClass *okhttp_headers_builder = reg_class(vm, "Lokhttp3/Headers$Builder;", obj);
    add_method(okhttp_headers_builder, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_headers_builder, "add", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_headers_builder, "set", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_headers_builder, "removeAll", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_headers_builder, "build", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_http_url = reg_class(vm, "Lokhttp3/HttpUrl;", obj);
    okhttp_http_url->instance_field_count = 1; // [0]=url string
    add_method(okhttp_http_url, "parse", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(okhttp_http_url, "newBuilder", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_http_url, "toString", "L", DX_ACC_PUBLIC, native_okhttp_httpurl_tostring, false);

    DxClass *okhttp_cache_control = reg_class(vm, "Lokhttp3/CacheControl;", obj);
    add_method(okhttp_cache_control, "parse", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(okhttp_cache_control, "noCache", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(okhttp_cache_control, "noStore", "Z", DX_ACC_PUBLIC, native_return_false, false);

    DxClass *okhttp_form_body = reg_class(vm, "Lokhttp3/FormBody;", okhttp_req_body);
    add_method(okhttp_form_body, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(okhttp_form_body, "name", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_form_body, "value", "LI", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_form_body_builder = reg_class(vm, "Lokhttp3/FormBody$Builder;", obj);
    add_method(okhttp_form_body_builder, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_form_body_builder, "add", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_form_body_builder, "addEncoded", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_form_body_builder, "build", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_multipart_body = reg_class(vm, "Lokhttp3/MultipartBody;", okhttp_req_body);
    add_method(okhttp_multipart_body, "parts", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(okhttp_multipart_body, "size", "I", DX_ACC_PUBLIC, native_return_int_zero, false);
    add_method(okhttp_multipart_body, "type", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_multipart_builder = reg_class(vm, "Lokhttp3/MultipartBody$Builder;", obj);
    add_method(okhttp_multipart_builder, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_multipart_builder, "setType", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_multipart_builder, "addFormDataPart", "LLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_multipart_builder, "addFormDataPart", "LLLL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_multipart_builder, "addPart", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_multipart_builder, "build", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_logging = reg_class(vm, "Lokhttp3/logging/HttpLoggingInterceptor;", obj);
    add_method(okhttp_logging, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_logging, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(okhttp_logging, "setLevel", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(okhttp_logging, "getLevel", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *okhttp_logging_level = reg_class(vm, "Lokhttp3/logging/HttpLoggingInterceptor$Level;", obj);
    add_method(okhttp_logging_level, "values", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    // --- Retrofit2: Real annotation-driven HTTP dispatch (com.squareup.retrofit2) ---
    DxClass *retrofit_cls = reg_class(vm, "Lretrofit2/Retrofit;", obj);
    retrofit_cls->instance_field_count = 2; // [0]=base URL string, [1]=OkHttpClient
    add_method(retrofit_cls, "create", "LL", DX_ACC_PUBLIC, native_retrofit_create, false);
    add_method(retrofit_cls, "baseUrl", "L", DX_ACC_PUBLIC, native_retrofit_baseurl, false);
    add_method(retrofit_cls, "callFactory", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(retrofit_cls, "converterFactories", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(retrofit_cls, "callAdapterFactories", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(retrofit_cls, "newBuilder", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_builder = reg_class(vm, "Lretrofit2/Retrofit$Builder;", obj);
    retrofit_builder->instance_field_count = 3; // [0]=base URL, [1]=OkHttpClient, [2]=converters
    add_method(retrofit_builder, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(retrofit_builder, "baseUrl", "LL", DX_ACC_PUBLIC, native_retrofit_builder_baseurl, false);
    add_method(retrofit_builder, "client", "LL", DX_ACC_PUBLIC, native_retrofit_builder_client, false);
    add_method(retrofit_builder, "addConverterFactory", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(retrofit_builder, "addCallAdapterFactory", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(retrofit_builder, "build", "L", DX_ACC_PUBLIC, native_retrofit_builder_build, false);
    add_method(retrofit_builder, "callFactory", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(retrofit_builder, "callbackExecutor", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(retrofit_builder, "validateEagerly", "LZ", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *retrofit_converter_factory = reg_class(vm, "Lretrofit2/Converter$Factory;", obj);
    retrofit_converter_factory->access_flags = DX_ACC_ABSTRACT;
    add_method(retrofit_converter_factory, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(retrofit_converter_factory, "responseBodyConverter", "LLLL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(retrofit_converter_factory, "requestBodyConverter", "LLLLL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(retrofit_converter_factory, "stringConverter", "LLLL", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_calladapter_factory = reg_class(vm, "Lretrofit2/CallAdapter$Factory;", obj);
    retrofit_calladapter_factory->access_flags = DX_ACC_ABSTRACT;
    add_method(retrofit_calladapter_factory, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(retrofit_calladapter_factory, "get", "LLLL", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_call = reg_class(vm, "Lretrofit2/Call;", obj);
    retrofit_call->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_call->instance_field_count = 2; // [0]=Response (pre-fetched), [1]=Request info
    add_method(retrofit_call, "execute", "L", DX_ACC_PUBLIC, native_retrofit_call_execute, false);
    add_method(retrofit_call, "enqueue", "VL", DX_ACC_PUBLIC, native_retrofit_call_enqueue, false);
    add_method(retrofit_call, "cancel", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(retrofit_call, "clone", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(retrofit_call, "isExecuted", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(retrofit_call, "isCanceled", "Z", DX_ACC_PUBLIC, native_return_false, false);
    add_method(retrofit_call, "request", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_callback = reg_class(vm, "Lretrofit2/Callback;", obj);
    retrofit_callback->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_method(retrofit_callback, "onResponse", "VLL", DX_ACC_PUBLIC, native_noop, false);
    add_method(retrofit_callback, "onFailure", "VLL", DX_ACC_PUBLIC, native_noop, false);

    DxClass *retrofit_response = reg_class(vm, "Lretrofit2/Response;", obj);
    retrofit_response->instance_field_count = 3; // [0]=status code, [1]=body obj, [2]=raw body string
    add_method(retrofit_response, "body", "L", DX_ACC_PUBLIC, native_retrofit_response_body, false);
    add_method(retrofit_response, "code", "I", DX_ACC_PUBLIC, native_retrofit_response_code, false);
    add_method(retrofit_response, "isSuccessful", "Z", DX_ACC_PUBLIC, native_retrofit_response_is_successful, false);
    add_method(retrofit_response, "errorBody", "L", DX_ACC_PUBLIC, native_retrofit_response_errorbody, false);
    add_method(retrofit_response, "message", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(retrofit_response, "headers", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(retrofit_response, "raw", "L", DX_ACC_PUBLIC, native_retrofit_response_raw, false);
    add_method(retrofit_response, "success", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_retrofit_response_success, true);
    add_method(retrofit_response, "error", "LIL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_retrofit_response_error, true);

    // Gson converter (most common Retrofit converter)
    DxClass *gson_converter = reg_class(vm, "Lretrofit2/converter/gson/GsonConverterFactory;", retrofit_converter_factory);
    add_method(gson_converter, "create", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(gson_converter, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    // Moshi converter (another common Retrofit converter)
    DxClass *moshi_converter = reg_class(vm, "Lretrofit2/converter/moshi/MoshiConverterFactory;", retrofit_converter_factory);
    add_method(moshi_converter, "create", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(moshi_converter, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    // Scalars converter
    DxClass *scalars_converter = reg_class(vm, "Lretrofit2/converter/scalars/ScalarsConverterFactory;", retrofit_converter_factory);
    add_method(scalars_converter, "create", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    // RxJava3 call adapter
    DxClass *rx3_calladapter = reg_class(vm, "Lretrofit2/adapter/rxjava3/RxJava3CallAdapterFactory;", retrofit_calladapter_factory);
    add_method(rx3_calladapter, "create", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx3_calladapter, "createSynchronous", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    // RxJava2 call adapter
    DxClass *rx2_calladapter = reg_class(vm, "Lretrofit2/adapter/rxjava2/RxJava2CallAdapterFactory;", retrofit_calladapter_factory);
    add_method(rx2_calladapter, "create", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(rx2_calladapter, "createAsync", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    // --- Retrofit2 HTTP annotation classes ---
    // These are annotation types used in interface method declarations
    DxClass *anno_base = dx_vm_find_class(vm, "Ljava/lang/annotation/Annotation;");
    if (!anno_base) anno_base = obj;

    DxClass *retrofit_get_anno = reg_class(vm, "Lretrofit2/http/GET;", anno_base);
    retrofit_get_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_get_anno->instance_field_count = 1;
    add_method(retrofit_get_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_post_anno = reg_class(vm, "Lretrofit2/http/POST;", anno_base);
    retrofit_post_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_post_anno->instance_field_count = 1;
    add_method(retrofit_post_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_put_anno = reg_class(vm, "Lretrofit2/http/PUT;", anno_base);
    retrofit_put_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_put_anno->instance_field_count = 1;
    add_method(retrofit_put_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_delete_anno = reg_class(vm, "Lretrofit2/http/DELETE;", anno_base);
    retrofit_delete_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_delete_anno->instance_field_count = 1;
    add_method(retrofit_delete_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_patch_anno = reg_class(vm, "Lretrofit2/http/PATCH;", anno_base);
    retrofit_patch_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_patch_anno->instance_field_count = 1;
    add_method(retrofit_patch_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_head_anno = reg_class(vm, "Lretrofit2/http/HEAD;", anno_base);
    retrofit_head_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_head_anno->instance_field_count = 1;
    add_method(retrofit_head_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_options_anno = reg_class(vm, "Lretrofit2/http/OPTIONS;", anno_base);
    retrofit_options_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_options_anno->instance_field_count = 1;
    add_method(retrofit_options_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_http_anno = reg_class(vm, "Lretrofit2/http/HTTP;", anno_base);
    retrofit_http_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_http_anno->instance_field_count = 2;
    add_method(retrofit_http_anno, "method", "L", DX_ACC_PUBLIC, native_return_null, false);
    add_method(retrofit_http_anno, "path", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_path_anno = reg_class(vm, "Lretrofit2/http/Path;", anno_base);
    retrofit_path_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_path_anno->instance_field_count = 1;
    add_method(retrofit_path_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_query_anno = reg_class(vm, "Lretrofit2/http/Query;", anno_base);
    retrofit_query_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_query_anno->instance_field_count = 1;
    add_method(retrofit_query_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_body_anno = reg_class(vm, "Lretrofit2/http/Body;", anno_base);
    retrofit_body_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *retrofit_header_anno = reg_class(vm, "Lretrofit2/http/Header;", anno_base);
    retrofit_header_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_header_anno->instance_field_count = 1;
    add_method(retrofit_header_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_field_anno = reg_class(vm, "Lretrofit2/http/Field;", anno_base);
    retrofit_field_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_field_anno->instance_field_count = 1;
    add_method(retrofit_field_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_querymap_anno = reg_class(vm, "Lretrofit2/http/QueryMap;", anno_base);
    retrofit_querymap_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *retrofit_fieldmap_anno = reg_class(vm, "Lretrofit2/http/FieldMap;", anno_base);
    retrofit_fieldmap_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *retrofit_url_anno = reg_class(vm, "Lretrofit2/http/Url;", anno_base);
    retrofit_url_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *retrofit_headers_anno = reg_class(vm, "Lretrofit2/http/Headers;", anno_base);
    retrofit_headers_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    retrofit_headers_anno->instance_field_count = 1;
    add_method(retrofit_headers_anno, "value", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *retrofit_formurlencoded_anno = reg_class(vm, "Lretrofit2/http/FormUrlEncoded;", anno_base);
    retrofit_formurlencoded_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *retrofit_multipart_anno = reg_class(vm, "Lretrofit2/http/Multipart;", anno_base);
    retrofit_multipart_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    DxClass *retrofit_streaming_anno = reg_class(vm, "Lretrofit2/http/Streaming;", anno_base);
    retrofit_streaming_anno->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;

    // --- Glide stubs (com.bumptech.glide) ---
    DxClass *glide_cls = reg_class(vm, "Lcom/bumptech/glide/Glide;", obj);
    add_method(glide_cls, "with", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(glide_cls, "get", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(glide_cls, "init", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_noop, true);

    DxClass *glide_req_manager = reg_class(vm, "Lcom/bumptech/glide/RequestManager;", obj);
    add_method(glide_req_manager, "load", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(glide_req_manager, "load", "LI", DX_ACC_PUBLIC, native_return_null, false);
    add_method(glide_req_manager, "asBitmap", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_manager, "asDrawable", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_manager, "asGif", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_manager, "clear", "VL", DX_ACC_PUBLIC, native_noop, false);
    add_method(glide_req_manager, "pauseRequests", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(glide_req_manager, "resumeRequests", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(glide_req_manager, "isPaused", "Z", DX_ACC_PUBLIC, native_return_false, false);

    DxClass *glide_req_builder = reg_class(vm, "Lcom/bumptech/glide/RequestBuilder;", obj);
    add_method(glide_req_builder, "into", "LL", DX_ACC_PUBLIC, native_return_null, false);
    add_method(glide_req_builder, "placeholder", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "placeholder", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "error", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "error", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "override", "LII", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "override", "LI", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "centerCrop", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "centerInside", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "fitCenter", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "circleCrop", "L", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "transform", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "diskCacheStrategy", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "skipMemoryCache", "LZ", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "transition", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "thumbnail", "LF", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "listener", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "apply", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "load", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_req_builder, "preload", "V", DX_ACC_PUBLIC, native_noop, false);
    add_method(glide_req_builder, "submit", "L", DX_ACC_PUBLIC, native_return_null, false);

    DxClass *glide_req_options = reg_class(vm, "Lcom/bumptech/glide/request/RequestOptions;", obj);
    add_method(glide_req_options, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, native_noop, false);
    add_method(glide_req_options, "centerCropTransform", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(glide_req_options, "circleCropTransform", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(glide_req_options, "fitCenterTransform", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(glide_req_options, "overrideOf", "LII", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(glide_req_options, "placeholderOf", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(glide_req_options, "errorOf", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(glide_req_options, "diskCacheStrategyOf", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(glide_req_options, "skipMemoryCacheOf", "LZ", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);

    DxClass *glide_disk_cache = reg_class(vm, "Lcom/bumptech/glide/load/engine/DiskCacheStrategy;", obj);
    (void)glide_disk_cache; // NONE, DATA, RESOURCE, ALL, AUTOMATIC are static fields; class presence suffices

    DxClass *glide_builder = reg_class(vm, "Lcom/bumptech/glide/GlideBuilder;", obj);
    add_method(glide_builder, "setMemoryCache", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_builder, "setDiskCache", "LL", DX_ACC_PUBLIC, native_return_self, false);
    add_method(glide_builder, "setDefaultRequestOptions", "LL", DX_ACC_PUBLIC, native_return_self, false);

    DxClass *picasso_cls = reg_class(vm, "Lcom/squareup/picasso/Picasso;", obj);
    add_method(picasso_cls, "get", "L", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(picasso_cls, "with", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC, native_return_null, true);
    add_method(picasso_cls, "load", "LL", DX_ACC_PUBLIC, native_return_null, false);

    // --- android.app.AlertDialog + Builder ---
    DxClass *alertdialog_cls = reg_class(vm, "Landroid/app/AlertDialog;", dialog_cls);
    add_method(alertdialog_cls, "show", "V", DX_ACC_PUBLIC,
               native_noop, false);

    DxClass *alertdialog_builder = reg_class(vm, "Landroid/app/AlertDialog$Builder;", obj);
    add_method(alertdialog_builder, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_alertdialog_builder_init, true);
    add_method(alertdialog_builder, "setTitle", "LL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setMessage", "LL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setPositiveButton", "LLL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setNegativeButton", "LLL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setNeutralButton", "LLL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setView", "LL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setView", "LI", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setIcon", "LI", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setCancelable", "LZ", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setItems", "LLL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setSingleChoiceItems", "LLIL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setMultiChoiceItems", "LLLL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setOnDismissListener", "LL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "setOnCancelListener", "LL", DX_ACC_PUBLIC,
               native_alertdialog_builder_set_return_self, false);
    add_method(alertdialog_builder, "create", "L", DX_ACC_PUBLIC,
               native_alertdialog_builder_create, false);
    add_method(alertdialog_builder, "show", "L", DX_ACC_PUBLIC,
               native_alertdialog_builder_show, false);

    // androidx.appcompat.app.AlertDialog + Builder
    DxClass *appcompat_alertdialog = reg_class(vm, "Landroidx/appcompat/app/AlertDialog;", alertdialog_cls);
    (void)appcompat_alertdialog;
    DxClass *appcompat_alertdialog_builder = reg_class(vm, "Landroidx/appcompat/app/AlertDialog$Builder;", alertdialog_builder);
    (void)appcompat_alertdialog_builder;

    // com.google.android.material.dialog.MaterialAlertDialogBuilder
    DxClass *material_dialog_builder = reg_class(vm, "Lcom/google/android/material/dialog/MaterialAlertDialogBuilder;", alertdialog_builder);
    (void)material_dialog_builder;

    // --- java.nio.ByteOrder ---
    DxClass *byteorder_cls = reg_class(vm, "Ljava/nio/ByteOrder;", obj);
    {
        // Create BIG_ENDIAN (val=0) and LITTLE_ENDIAN (val=1) static field objects
        DxObject *be_obj = dx_vm_alloc_object(vm, byteorder_cls);
        DxObject *le_obj = dx_vm_alloc_object(vm, byteorder_cls);
        if (be_obj) dx_vm_set_field(be_obj, "_val", DX_INT_VALUE(0));
        if (le_obj) dx_vm_set_field(le_obj, "_val", DX_INT_VALUE(1));
        const char *bo_names[] = { "BIG_ENDIAN", "LITTLE_ENDIAN" };
        DxValue bo_vals[] = {
            be_obj ? DX_OBJ_VALUE(be_obj) : DX_NULL_VALUE,
            le_obj ? DX_OBJ_VALUE(le_obj) : DX_NULL_VALUE
        };
        add_static_fields(byteorder_cls, bo_names, bo_vals, 2);
    }
    add_method(byteorder_cls, "nativeOrder", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_byteorder_nativeOrder, true);

    // --- java.nio.ByteBuffer ---
    DxClass *bytebuffer_cls = reg_class(vm, "Ljava/nio/ByteBuffer;", obj);
    // Static methods
    add_method(bytebuffer_cls, "allocate", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_bb_allocate, true);
    add_method(bytebuffer_cls, "wrap", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_bb_wrap, true);
    // put(byte) -> ByteBuffer (virtual, shorty LB = "LI" since byte is int in Dalvik)
    add_method(bytebuffer_cls, "put", "LI", DX_ACC_PUBLIC,
               native_bb_put_byte, false);
    // put(byte[]) -> ByteBuffer
    add_method(bytebuffer_cls, "put", "LL", DX_ACC_PUBLIC,
               native_bb_put_array, false);
    // get() -> byte
    add_method(bytebuffer_cls, "get", "I", DX_ACC_PUBLIC,
               native_bb_get, false);
    // get(int) -> byte
    add_method(bytebuffer_cls, "get", "II", DX_ACC_PUBLIC,
               native_bb_get_index, false);
    // position() -> int
    add_method(bytebuffer_cls, "position", "I", DX_ACC_PUBLIC,
               native_bb_get_position, false);
    // position(int) -> ByteBuffer
    add_method(bytebuffer_cls, "position", "LI", DX_ACC_PUBLIC,
               native_bb_set_position, false);
    // limit() -> int
    add_method(bytebuffer_cls, "limit", "I", DX_ACC_PUBLIC,
               native_bb_get_limit, false);
    // limit(int) -> ByteBuffer
    add_method(bytebuffer_cls, "limit", "LI", DX_ACC_PUBLIC,
               native_bb_set_limit, false);
    // capacity() -> int
    add_method(bytebuffer_cls, "capacity", "I", DX_ACC_PUBLIC,
               native_bb_capacity, false);
    // remaining() -> int
    add_method(bytebuffer_cls, "remaining", "I", DX_ACC_PUBLIC,
               native_bb_remaining, false);
    // hasRemaining() -> boolean
    add_method(bytebuffer_cls, "hasRemaining", "Z", DX_ACC_PUBLIC,
               native_bb_hasRemaining, false);
    // flip() -> ByteBuffer
    add_method(bytebuffer_cls, "flip", "L", DX_ACC_PUBLIC,
               native_bb_flip, false);
    // clear() -> ByteBuffer
    add_method(bytebuffer_cls, "clear", "L", DX_ACC_PUBLIC,
               native_bb_clear, false);
    // rewind() -> ByteBuffer
    add_method(bytebuffer_cls, "rewind", "L", DX_ACC_PUBLIC,
               native_bb_rewind, false);
    // array() -> byte[]
    add_method(bytebuffer_cls, "array", "L", DX_ACC_PUBLIC,
               native_bb_array, false);
    // order() -> ByteOrder
    add_method(bytebuffer_cls, "order", "L", DX_ACC_PUBLIC,
               native_bb_get_order, false);
    // order(ByteOrder) -> ByteBuffer
    add_method(bytebuffer_cls, "order", "LL", DX_ACC_PUBLIC,
               native_bb_set_order, false);
    // getInt() -> int
    add_method(bytebuffer_cls, "getInt", "I", DX_ACC_PUBLIC,
               native_bb_getInt, false);
    // putInt(int) -> ByteBuffer
    add_method(bytebuffer_cls, "putInt", "LI", DX_ACC_PUBLIC,
               native_bb_putInt, false);
    // getShort() -> short
    add_method(bytebuffer_cls, "getShort", "S", DX_ACC_PUBLIC,
               native_bb_getShort, false);
    // putShort(short) -> ByteBuffer
    add_method(bytebuffer_cls, "putShort", "LS", DX_ACC_PUBLIC,
               native_bb_putShort, false);
    // getLong() -> long
    add_method(bytebuffer_cls, "getLong", "J", DX_ACC_PUBLIC,
               native_bb_getLong, false);
    // putLong(long) -> ByteBuffer
    add_method(bytebuffer_cls, "putLong", "LJ", DX_ACC_PUBLIC,
               native_bb_putLong, false);

    // --- java.nio.charset.Charset ---
    DxClass *charset_cls = reg_class(vm, "Ljava/nio/charset/Charset;", obj);
    add_method(charset_cls, "forName", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_charset_forName, true);
    add_method(charset_cls, "defaultCharset", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_charset_defaultCharset, true);
    add_method(charset_cls, "name", "L", DX_ACC_PUBLIC,
               native_charset_name, false);

    // --- java.nio.charset.StandardCharsets ---
    DxClass *stdcharsets_cls = reg_class(vm, "Ljava/nio/charset/StandardCharsets;", obj);
    {
        // Create Charset objects for UTF_8, US_ASCII, ISO_8859_1
        DxObject *utf8_cs = dx_vm_alloc_object(vm, charset_cls);
        if (utf8_cs) {
            DxObject *n = dx_vm_create_string(vm, "UTF-8");
            dx_vm_set_field(utf8_cs, "_name", n ? DX_OBJ_VALUE(n) : DX_NULL_VALUE);
        }
        DxObject *ascii_cs = dx_vm_alloc_object(vm, charset_cls);
        if (ascii_cs) {
            DxObject *n = dx_vm_create_string(vm, "US-ASCII");
            dx_vm_set_field(ascii_cs, "_name", n ? DX_OBJ_VALUE(n) : DX_NULL_VALUE);
        }
        DxObject *iso_cs = dx_vm_alloc_object(vm, charset_cls);
        if (iso_cs) {
            DxObject *n = dx_vm_create_string(vm, "ISO-8859-1");
            dx_vm_set_field(iso_cs, "_name", n ? DX_OBJ_VALUE(n) : DX_NULL_VALUE);
        }
        const char *sc_names[] = { "UTF_8", "US_ASCII", "ISO_8859_1" };
        DxValue sc_vals[] = {
            utf8_cs ? DX_OBJ_VALUE(utf8_cs) : DX_NULL_VALUE,
            ascii_cs ? DX_OBJ_VALUE(ascii_cs) : DX_NULL_VALUE,
            iso_cs ? DX_OBJ_VALUE(iso_cs) : DX_NULL_VALUE
        };
        add_static_fields(stdcharsets_cls, sc_names, sc_vals, 3);
    }

    // --- java.nio.channels.FileChannel --- (stub)
    DxClass *filechannel_cls = reg_class(vm, "Ljava/nio/channels/FileChannel;", obj);
    add_method(filechannel_cls, "close", "V", DX_ACC_PUBLIC,
               native_noop, false);

    // --- android.util.Base64 ---
    DxClass *base64_cls = reg_class(vm, "Landroid/util/Base64;", obj);
    add_method(base64_cls, "encode", "L[BI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_base64_encode, true);
    add_method(base64_cls, "decode", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_base64_decode, true);
    add_method(base64_cls, "encodeToString", "L[BI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_base64_encode_to_string, true);
    {
        const char *b64_names[] = { "DEFAULT", "NO_PADDING", "NO_WRAP", "URL_SAFE" };
        DxValue b64_vals[] = {
            DX_INT_VALUE(0), DX_INT_VALUE(1), DX_INT_VALUE(2), DX_INT_VALUE(8)
        };
        add_static_fields(base64_cls, b64_names, b64_vals, 4);
    }

    // --- android.text.format.DateFormat ---
    DxClass *dateformat_cls = reg_class(vm, "Landroid/text/format/DateFormat;", obj);
    add_method(dateformat_cls, "format", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_dateformat_format, true);
    add_method(dateformat_cls, "is24HourFormat", "ZL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_true, true);

    // ============================================================
    // android.media.MediaPlayer
    // ============================================================
    DxClass *mediaplayer_cls = reg_class(vm, "Landroid/media/MediaPlayer;", obj);
    add_method(mediaplayer_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(mediaplayer_cls, "create", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_mediaplayer_create, true);
    add_method(mediaplayer_cls, "create", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_mediaplayer_create, true);
    add_method(mediaplayer_cls, "setDataSource", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "setDataSource", "VLL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "prepare", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "prepareAsync", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "start", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "pause", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "stop", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "release", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "reset", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "isPlaying", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(mediaplayer_cls, "getDuration", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(mediaplayer_cls, "getCurrentPosition", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(mediaplayer_cls, "seekTo", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "setLooping", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "isLooping", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(mediaplayer_cls, "setVolume", "VFF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "setOnPreparedListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "setOnCompletionListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "setOnErrorListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "setAudioAttributes", "VL", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "setAudioStreamType", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(mediaplayer_cls, "setWakeMode", "VLI", DX_ACC_PUBLIC,
               native_noop, false);

    // MediaPlayer listener interfaces
    DxClass *mp_on_prepared = reg_class(vm, "Landroid/media/MediaPlayer$OnPreparedListener;", obj);
    mp_on_prepared->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE;
    add_method(mp_on_prepared, "onPrepared", "VL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_noop, false);

    DxClass *mp_on_completion = reg_class(vm, "Landroid/media/MediaPlayer$OnCompletionListener;", obj);
    mp_on_completion->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE;
    add_method(mp_on_completion, "onCompletion", "VL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_noop, false);

    DxClass *mp_on_error = reg_class(vm, "Landroid/media/MediaPlayer$OnErrorListener;", obj);
    mp_on_error->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE;
    add_method(mp_on_error, "onError", "ZLII", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_return_false, false);

    // ============================================================
    // android.media.AudioAttributes + Builder
    // ============================================================
    DxClass *audio_attr_cls = reg_class(vm, "Landroid/media/AudioAttributes;", obj);
    add_method(audio_attr_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    {
        const char *aa_names[] = {
            "USAGE_MEDIA", "USAGE_GAME", "USAGE_ALARM", "USAGE_NOTIFICATION",
            "USAGE_ASSISTANCE_SONIFICATION", "USAGE_VOICE_COMMUNICATION",
            "CONTENT_TYPE_MUSIC", "CONTENT_TYPE_MOVIE", "CONTENT_TYPE_SONIFICATION",
            "CONTENT_TYPE_SPEECH", "CONTENT_TYPE_UNKNOWN"
        };
        DxValue aa_vals[] = {
            DX_INT_VALUE(1), DX_INT_VALUE(14), DX_INT_VALUE(4), DX_INT_VALUE(5),
            DX_INT_VALUE(13), DX_INT_VALUE(2),
            DX_INT_VALUE(2), DX_INT_VALUE(3), DX_INT_VALUE(4),
            DX_INT_VALUE(1), DX_INT_VALUE(0)
        };
        add_static_fields(audio_attr_cls, aa_names, aa_vals, 11);
    }

    DxClass *audio_attr_builder_cls = reg_class(vm, "Landroid/media/AudioAttributes$Builder;", obj);
    add_method(audio_attr_builder_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(audio_attr_builder_cls, "setUsage", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_attr_builder_cls, "setContentType", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_attr_builder_cls, "setFlags", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_attr_builder_cls, "setLegacyStreamType", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_attr_builder_cls, "build", "L", DX_ACC_PUBLIC,
               native_audio_attr_builder_build, false);

    // ============================================================
    // android.media.SoundPool + Builder
    // ============================================================
    DxClass *soundpool_cls = reg_class(vm, "Landroid/media/SoundPool;", obj);
    add_method(soundpool_cls, "<init>", "VIII", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(soundpool_cls, "load", "ILII", DX_ACC_PUBLIC,
               native_soundpool_load, false);
    add_method(soundpool_cls, "load", "ILI", DX_ACC_PUBLIC,
               native_soundpool_load, false);
    add_method(soundpool_cls, "play", "IIFFIFI", DX_ACC_PUBLIC,
               native_soundpool_play, false);
    add_method(soundpool_cls, "stop", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "pause", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "resume", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "release", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "setVolume", "VIF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "setRate", "VIF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "setLoop", "VII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "setPriority", "VII", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "autoPause", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "autoResume", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(soundpool_cls, "unload", "ZI", DX_ACC_PUBLIC,
               native_return_true, false);
    add_method(soundpool_cls, "setOnLoadCompleteListener", "VL", DX_ACC_PUBLIC,
               native_noop, false);

    DxClass *soundpool_builder_cls = reg_class(vm, "Landroid/media/SoundPool$Builder;", obj);
    add_method(soundpool_builder_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(soundpool_builder_cls, "setMaxStreams", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(soundpool_builder_cls, "setAudioAttributes", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(soundpool_builder_cls, "build", "L", DX_ACC_PUBLIC,
               native_soundpool_builder_build, false);

    // SoundPool.OnLoadCompleteListener interface
    DxClass *sp_on_load = reg_class(vm, "Landroid/media/SoundPool$OnLoadCompleteListener;", obj);
    sp_on_load->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE;
    add_method(sp_on_load, "onLoadComplete", "VLII", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_noop, false);

    // ============================================================
    // android.media.AudioManager (expand existing stub)
    // ============================================================
    // audio_mgr_cls already registered above; add missing methods
    add_method(audio_mgr_cls, "requestAudioFocus", "ILII", DX_ACC_PUBLIC,
               native_audio_focus_granted, false);
    add_method(audio_mgr_cls, "requestAudioFocus", "ILL", DX_ACC_PUBLIC,
               native_audio_focus_granted, false);
    add_method(audio_mgr_cls, "abandonAudioFocus", "IL", DX_ACC_PUBLIC,
               native_return_int_one, false);
    add_method(audio_mgr_cls, "abandonAudioFocusRequest", "IL", DX_ACC_PUBLIC,
               native_return_int_one, false);
    add_method(audio_mgr_cls, "isMusicActive", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(audio_mgr_cls, "getMode", "I", DX_ACC_PUBLIC,
               native_return_int_zero, false);
    add_method(audio_mgr_cls, "setMode", "VI", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(audio_mgr_cls, "setSpeakerphoneOn", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(audio_mgr_cls, "isSpeakerphoneOn", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    {
        const char *am_names[] = {
            "STREAM_VOICE_CALL", "STREAM_SYSTEM", "STREAM_RING",
            "STREAM_MUSIC", "STREAM_ALARM", "STREAM_NOTIFICATION",
            "STREAM_DTMF",
            "AUDIOFOCUS_REQUEST_GRANTED", "AUDIOFOCUS_REQUEST_FAILED",
            "AUDIOFOCUS_GAIN", "AUDIOFOCUS_LOSS",
            "AUDIOFOCUS_LOSS_TRANSIENT", "AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK",
            "MODE_NORMAL", "MODE_RINGTONE", "MODE_IN_CALL"
        };
        DxValue am_vals[] = {
            DX_INT_VALUE(0), DX_INT_VALUE(1), DX_INT_VALUE(2),
            DX_INT_VALUE(3), DX_INT_VALUE(4), DX_INT_VALUE(5),
            DX_INT_VALUE(8),
            DX_INT_VALUE(1), DX_INT_VALUE(0),
            DX_INT_VALUE(1), DX_INT_VALUE(-1),
            DX_INT_VALUE(-2), DX_INT_VALUE(-3),
            DX_INT_VALUE(0), DX_INT_VALUE(1), DX_INT_VALUE(2)
        };
        add_static_fields(audio_mgr_cls, am_names, am_vals, 16);
    }

    // AudioManager.OnAudioFocusChangeListener interface
    DxClass *audio_focus_listener = reg_class(vm, "Landroid/media/AudioManager$OnAudioFocusChangeListener;", obj);
    audio_focus_listener->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE;
    add_method(audio_focus_listener, "onAudioFocusChange", "VI", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
               native_noop, false);

    // AudioFocusRequest + Builder
    DxClass *audio_focus_req = reg_class(vm, "Landroid/media/AudioFocusRequest;", obj);
    add_method(audio_focus_req, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);

    DxClass *audio_focus_req_builder = reg_class(vm, "Landroid/media/AudioFocusRequest$Builder;", obj);
    add_method(audio_focus_req_builder, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(audio_focus_req_builder, "setAudioAttributes", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_focus_req_builder, "setOnAudioFocusChangeListener", "LL", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_focus_req_builder, "setAcceptsDelayedFocusGain", "LZ", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_focus_req_builder, "setWillPauseWhenDucked", "LZ", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_focus_req_builder, "build", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);

    // ============================================================
    // android.media.Ringtone + RingtoneManager (expand existing)
    // ============================================================
    DxClass *ringtone_cls = reg_class(vm, "Landroid/media/Ringtone;", obj);
    add_method(ringtone_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(ringtone_cls, "play", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(ringtone_cls, "stop", "V", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(ringtone_cls, "isPlaying", "Z", DX_ACC_PUBLIC,
               native_return_false, false);
    add_method(ringtone_cls, "setLooping", "VZ", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(ringtone_cls, "setVolume", "VF", DX_ACC_PUBLIC,
               native_noop, false);
    add_method(ringtone_cls, "getTitle", "LL", DX_ACC_PUBLIC,
               native_return_null, false);

    // Expand RingtoneManager (rm_cls already registered above with getDefaultUri)
    add_method(rm_cls, "getRingtone", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_ringtone_manager_get_ringtone, true);
    add_method(rm_cls, "getActualDefaultRingtoneUri", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
               native_return_null, true);
    {
        const char *rm_names[] = { "TYPE_RINGTONE", "TYPE_NOTIFICATION", "TYPE_ALARM", "TYPE_ALL" };
        DxValue rm_vals[] = {
            DX_INT_VALUE(1), DX_INT_VALUE(2), DX_INT_VALUE(4), DX_INT_VALUE(7)
        };
        add_static_fields(rm_cls, rm_names, rm_vals, 4);
    }

    // ============================================================
    // android.media.AudioFormat + Builder
    // ============================================================
    DxClass *audio_format_cls = reg_class(vm, "Landroid/media/AudioFormat;", obj);
    {
        const char *af_names[] = {
            "ENCODING_PCM_16BIT", "ENCODING_PCM_8BIT", "ENCODING_PCM_FLOAT",
            "CHANNEL_OUT_MONO", "CHANNEL_OUT_STEREO",
            "CHANNEL_IN_MONO", "CHANNEL_IN_STEREO"
        };
        DxValue af_vals[] = {
            DX_INT_VALUE(2), DX_INT_VALUE(3), DX_INT_VALUE(4),
            DX_INT_VALUE(4), DX_INT_VALUE(12),
            DX_INT_VALUE(16), DX_INT_VALUE(12)
        };
        add_static_fields(audio_format_cls, af_names, af_vals, 7);
    }

    DxClass *audio_format_builder = reg_class(vm, "Landroid/media/AudioFormat$Builder;", obj);
    add_method(audio_format_builder, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
               native_noop, true);
    add_method(audio_format_builder, "setEncoding", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_format_builder, "setSampleRate", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_format_builder, "setChannelMask", "LI", DX_ACC_PUBLIC,
               native_return_self, false);
    add_method(audio_format_builder, "build", "L", DX_ACC_PUBLIC,
               native_return_new_object, false);

    // --- Increase DX_MAX_CLASSES if needed ---
    // We're now registering 380+ classes, the limit of 2048 should be fine

    DX_INFO(TAG, "Registered Android framework classes (%u total, production-grade)", vm->class_count);
    return DX_OK;
}

// Build vtables for all framework classes so DEX subclasses can inherit them
static void build_framework_vtables(DxVM *vm) {
    for (uint32_t i = 0; i < vm->class_count; i++) {
        DxClass *cls = vm->classes[i];
        if (!cls || !cls->is_framework || cls->vtable) continue;

        // Count total virtual methods up the chain
        uint32_t super_vtable_size = 0;
        if (cls->super_class && cls->super_class->vtable) {
            super_vtable_size = cls->super_class->vtable_size;
        }

        uint32_t total = super_vtable_size + cls->virtual_method_count;
        if (total == 0) continue;

        cls->vtable = (DxMethod **)dx_malloc(sizeof(DxMethod *) * total);
        if (!cls->vtable) continue;
        memset(cls->vtable, 0, sizeof(DxMethod *) * total);

        // Copy super vtable
        for (uint32_t v = 0; v < super_vtable_size; v++) {
            cls->vtable[v] = cls->super_class->vtable[v];
        }

        // Add own virtual methods, checking for overrides
        uint32_t next_slot = super_vtable_size;
        for (uint32_t m = 0; m < cls->virtual_method_count; m++) {
            DxMethod *method = &cls->virtual_methods[m];
            bool overridden = false;
            for (uint32_t v = 0; v < super_vtable_size; v++) {
                if (cls->vtable[v] && cls->vtable[v]->name &&
                    strcmp(cls->vtable[v]->name, method->name) == 0) {
                    cls->vtable[v] = method;
                    method->vtable_idx = (int32_t)v;
                    overridden = true;
                    break;
                }
            }
            if (!overridden) {
                method->vtable_idx = (int32_t)next_slot;
                cls->vtable[next_slot] = method;
                next_slot++;
            }
        }
        cls->vtable_size = next_slot;
    }
}

// ============================================================
// Reflection native methods
// ============================================================

static DxResult native_class_forName(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] is string with class name like "com.example.MyClass"
    // 1-arg: forName(String) — defaults to initialize=true
    // 3-arg: forName(String, boolean initialize, ClassLoader) — respects initialize flag
    if (arg_count < 1 || args[0].tag != DX_VAL_OBJ || !args[0].obj) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    const char *name = dx_vm_get_string_value(args[0].obj);
    if (!name) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    // Determine initialize flag: 1-arg defaults to true, 3-arg reads args[1]
    bool initialize = true;
    if (arg_count >= 3) {
        initialize = (args[1].tag == DX_VAL_INT) ? (args[1].i != 0) : true;
    }

    // Convert "com.example.Foo" to "Lcom/example/Foo;"
    size_t len = strlen(name);
    char *desc = (char *)dx_malloc(len + 3);
    desc[0] = 'L';
    for (size_t i = 0; i < len; i++)
        desc[i + 1] = (name[i] == '.') ? '/' : name[i];
    desc[len + 1] = ';';
    desc[len + 2] = '\0';

    DxClass *cls = dx_vm_find_class(vm, desc);
    dx_free(desc);

    if (cls) {
        // Run <clinit> if initialize=true and class not yet initialized
        if (initialize && cls->status < DX_CLASS_INITIALIZED) {
            dx_vm_init_class(vm, cls);
        }

        // Return a Class object wrapping this class
        DxClass *class_cls = dx_vm_find_class(vm, "Ljava/lang/Class;");
        DxObject *class_obj = class_cls ? dx_vm_alloc_object(vm, class_cls) : NULL;
        if (class_obj && class_obj->fields && class_cls->instance_field_count > 0) {
            // Store the DxClass pointer in field[0] using pointer-as-int trick
            class_obj->fields[0].tag = DX_VAL_INT;
            class_obj->fields[0].i = (int32_t)(uintptr_t)cls;
        }
        frame->result = class_obj ? DX_OBJ_VALUE(class_obj) : DX_NULL_VALUE;
    } else {
        DX_WARN("Reflect", "Class.forName(\"%s\") not found", name);
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_class_new_instance(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    // self is the Class object, extract the DxClass* from field[0]
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *cls = NULL;
    if (self && self->fields && self->klass && self->klass->instance_field_count > 0
        && self->fields[0].tag == DX_VAL_INT) {
        cls = (DxClass *)(uintptr_t)self->fields[0].i;
    }
    if (!cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    DxObject *obj = dx_vm_alloc_object(vm, cls);
    if (obj) {
        DxMethod *init = dx_vm_find_method(cls, "<init>", "V");
        if (init) {
            DxValue init_args[1] = { DX_OBJ_VALUE(obj) };
            dx_vm_execute_method(vm, init, init_args, 1, NULL);
            if (vm->pending_exception) vm->pending_exception = NULL;
        }
    }
    frame->result = obj ? DX_OBJ_VALUE(obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_class_is_assignable_from(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0] = this Class, args[1] = other Class
    DxClass *this_cls = NULL, *other_cls = NULL;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj
        && args[0].obj->fields && args[0].obj->klass->instance_field_count > 0
        && args[0].obj->fields[0].tag == DX_VAL_INT)
        this_cls = (DxClass *)(uintptr_t)args[0].obj->fields[0].i;
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj
        && args[1].obj->fields && args[1].obj->klass->instance_field_count > 0
        && args[1].obj->fields[0].tag == DX_VAL_INT)
        other_cls = (DxClass *)(uintptr_t)args[1].obj->fields[0].i;

    bool assignable = false;
    if (this_cls && other_cls) {
        // Walk the super chain of other_cls to see if this_cls is in it
        DxClass *walk = other_cls;
        while (walk) {
            if (walk == this_cls) { assignable = true; break; }
            walk = walk->super_class;
        }
    }
    frame->result = (DxValue){ .tag = DX_VAL_INT, .i = assignable ? 1 : 0 };
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_class_get_declared_field(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *cls = NULL;
    if (self && self->fields && self->klass->instance_field_count > 0 && self->fields[0].tag == DX_VAL_INT)
        cls = (DxClass *)(uintptr_t)self->fields[0].i;

    const char *fname = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        fname = dx_vm_get_string_value(args[1].obj);

    if (!cls || !fname) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    // Create a Field object; store field name in field[0]
    DxClass *field_cls = dx_vm_find_class(vm, "Ljava/lang/reflect/Field;");
    DxObject *fobj = field_cls ? dx_vm_alloc_object(vm, field_cls) : NULL;
    if (fobj && fobj->fields && field_cls->instance_field_count > 0) {
        DxObject *name_str = dx_vm_create_string(vm, fname);
        if (name_str) fobj->fields[0] = DX_OBJ_VALUE(name_str);
    }
    frame->result = fobj ? DX_OBJ_VALUE(fobj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_class_get_declared_method(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *cls = NULL;
    if (self && self->fields && self->klass->instance_field_count > 0 && self->fields[0].tag == DX_VAL_INT)
        cls = (DxClass *)(uintptr_t)self->fields[0].i;

    const char *mname = NULL;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj)
        mname = dx_vm_get_string_value(args[1].obj);

    if (!cls || !mname) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    // Find the method on the class
    DxMethod *found = dx_vm_find_method(cls, mname, NULL);

    // Create Method object; store DxMethod* in field[0]
    DxClass *method_cls = dx_vm_find_class(vm, "Ljava/lang/reflect/Method;");
    DxObject *mobj = method_cls ? dx_vm_alloc_object(vm, method_cls) : NULL;
    if (mobj && mobj->fields && method_cls->instance_field_count > 0 && found) {
        mobj->fields[0].tag = DX_VAL_INT;
        mobj->fields[0].i = (int32_t)(uintptr_t)found;
    }
    frame->result = mobj ? DX_OBJ_VALUE(mobj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_method_invoke(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = Method object, args[1] = target object, args[2] = Object[] params
    DxObject *method_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxMethod *method = NULL;
    if (method_obj && method_obj->fields && method_obj->klass
        && method_obj->klass->instance_field_count > 0
        && method_obj->fields[0].tag == DX_VAL_INT) {
        method = (DxMethod *)(uintptr_t)method_obj->fields[0].i;
    }

    if (!method) {
        DX_WARN("Reflect", "Method.invoke: no method stored");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Build args: target object + array elements
    DxObject *target = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    DxValue call_args[DX_MAX_REGISTERS];
    uint32_t call_count = 0;

    if (!(method->access_flags & DX_ACC_STATIC)) {
        call_args[call_count++] = target ? DX_OBJ_VALUE(target) : DX_NULL_VALUE;
    }

    // Extract params from Object[] array (args[2])
    if (arg_count > 2 && args[2].tag == DX_VAL_OBJ && args[2].obj && args[2].obj->is_array) {
        DxObject *params = args[2].obj;
        for (uint32_t i = 0; i < params->array_length && call_count < DX_MAX_REGISTERS; i++) {
            call_args[call_count++] = params->array_elements[i];
        }
    }

    DxValue result = {0};
    vm->insn_count = 0;
    DxResult res = dx_vm_execute_method(vm, method, call_args, call_count, &result);
    if (res == DX_OK) {
        frame->result = result;
    } else {
        frame->result = DX_NULL_VALUE;
        if (vm->pending_exception) vm->pending_exception = NULL;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_field_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // args[0] = Field object, args[1] = target object
    DxObject *field_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *target = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    const char *field_name = NULL;
    if (field_obj && field_obj->fields && field_obj->klass
        && field_obj->klass->instance_field_count > 0
        && field_obj->fields[0].tag == DX_VAL_OBJ && field_obj->fields[0].obj) {
        field_name = dx_vm_get_string_value(field_obj->fields[0].obj);
    }

    if (target && field_name) {
        DxValue val = {0};
        dx_vm_get_field(target, field_name, &val);
        frame->result = val;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_field_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *field_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxObject *target = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    DxValue new_val = (arg_count > 2) ? args[2] : DX_NULL_VALUE;

    const char *field_name = NULL;
    if (field_obj && field_obj->fields && field_obj->klass
        && field_obj->klass->instance_field_count > 0
        && field_obj->fields[0].tag == DX_VAL_OBJ && field_obj->fields[0].obj) {
        field_name = dx_vm_get_string_value(field_obj->fields[0].obj);
    }

    if (target && field_name) {
        dx_vm_set_field(target, field_name, new_val);
    }
    return DX_OK;
}

// ============================================================
// Annotation element value access
// ============================================================

// Helper: extract DxAnnotationEntry* from an annotation object's field[0]
static const DxAnnotationEntry *extract_anno_entry(DxObject *anno_obj) {
    if (!anno_obj || !anno_obj->fields) return NULL;
    if (anno_obj->fields[0].tag == DX_VAL_INT && anno_obj->fields[0].i != 0) {
        return (const DxAnnotationEntry *)(uintptr_t)anno_obj->fields[0].i;
    }
    return NULL;
}

// Helper: create annotation object with element values packed in
static DxObject *create_annotation_object(DxVM *vm, DxClass *anno_cls, const DxAnnotationEntry *entry) {
    DxObject *anno_obj = dx_vm_alloc_object(vm, anno_cls);
    if (!anno_obj) return NULL;
    // Store the DxAnnotationEntry pointer in field[0] (allocated by Annotation base class or object)
    if (anno_obj->fields && anno_cls->instance_field_count >= 2) {
        anno_obj->fields[0].tag = DX_VAL_INT;
        anno_obj->fields[0].i = (int32_t)(uintptr_t)entry;
    }
    return anno_obj;
}

// Annotation.value() -> Object (typically String)
static DxResult native_annotation_value(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const DxAnnotationEntry *entry = extract_anno_entry(self);

    if (entry) {
        const char *str_val = dx_annotation_get_string(entry, "value");
        if (str_val) {
            DxObject *str = dx_vm_create_string(vm, str_val);
            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
            frame->has_result = true;
            return DX_OK;
        }
        // Try int value
        const DxAnnotationElement *elem = NULL;
        for (uint32_t i = 0; i < entry->element_count; i++) {
            if (entry->elements[i].name && strcmp(entry->elements[i].name, "value") == 0) {
                elem = &entry->elements[i];
                break;
            }
        }
        if (elem) {
            switch (elem->val_type) {
                case DX_ANNO_VAL_INT:
                case DX_ANNO_VAL_SHORT:
                case DX_ANNO_VAL_BYTE:
                case DX_ANNO_VAL_CHAR:
                case DX_ANNO_VAL_BOOLEAN:
                    frame->result = DX_INT_VALUE(elem->i_value);
                    frame->has_result = true;
                    return DX_OK;
                case DX_ANNO_VAL_LONG:
                    frame->result = (DxValue){.tag = DX_VAL_LONG, .l = elem->l_value};
                    frame->has_result = true;
                    return DX_OK;
                case DX_ANNO_VAL_FLOAT:
                    frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = elem->f_value};
                    frame->has_result = true;
                    return DX_OK;
                case DX_ANNO_VAL_DOUBLE:
                    frame->result = (DxValue){.tag = DX_VAL_DOUBLE, .d = elem->d_value};
                    frame->has_result = true;
                    return DX_OK;
                case DX_ANNO_VAL_TYPE: {
                    DxObject *str = dx_vm_create_string(vm, elem->str_value ? elem->str_value : "");
                    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
                    frame->has_result = true;
                    return DX_OK;
                }
                case DX_ANNO_VAL_ENUM: {
                    DxObject *str = dx_vm_create_string(vm, elem->str_value ? elem->str_value : "");
                    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
                    frame->has_result = true;
                    return DX_OK;
                }
                default:
                    break;
            }
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Annotation.annotationType() -> Class
static DxResult native_annotation_annotation_type(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;

    if (self && self->klass) {
        // Return a Class object wrapping the annotation's class
        DxClass *class_cls = dx_vm_find_class(vm, "Ljava/lang/Class;");
        if (class_cls) {
            DxObject *cls_obj = dx_vm_alloc_object(vm, class_cls);
            if (cls_obj && cls_obj->fields && class_cls->instance_field_count > 0) {
                cls_obj->fields[0].tag = DX_VAL_INT;
                cls_obj->fields[0].i = (int32_t)(uintptr_t)self->klass;
            }
            frame->result = cls_obj ? DX_OBJ_VALUE(cls_obj) : DX_NULL_VALUE;
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Framework reflection: Class annotation/method/field support
// (uses field[0] = DxClass* as int pattern from forName)
// ============================================================

// Helper: extract DxClass* from a Class object (fw variant: field[0] as int)
static DxClass *extract_dxclass_fw(DxObject *class_obj) {
    if (!class_obj) return NULL;
    // Try field[0] as int (framework pattern from Class.forName in this file)
    if (class_obj->fields && class_obj->klass && class_obj->klass->instance_field_count > 0
        && class_obj->fields[0].tag == DX_VAL_INT && class_obj->fields[0].i != 0) {
        return (DxClass *)(uintptr_t)class_obj->fields[0].i;
    }
    // Fall back to klass pointer (dx_vm.c pattern from Object.getClass)
    if (class_obj->klass) return class_obj->klass;
    return NULL;
}

// Class.getAnnotation(Class annotationType) -> Annotation or null
static DxResult native_class_get_annotation_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *cls = extract_dxclass_fw(self);
    DxClass *anno_type = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? extract_dxclass_fw(args[1].obj) : NULL;

    if (cls && anno_type && cls->annotations && anno_type->descriptor) {
        for (uint32_t i = 0; i < cls->annotation_count; i++) {
            if (cls->annotations[i].type && strcmp(cls->annotations[i].type, anno_type->descriptor) == 0) {
                DxObject *anno_obj = create_annotation_object(vm, anno_type, &cls->annotations[i]);
                frame->result = anno_obj ? DX_OBJ_VALUE(anno_obj) : DX_NULL_VALUE;
                frame->has_result = true;
                return DX_OK;
            }
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Class.isAnnotationPresent(Class annotationType) -> boolean
static DxResult native_class_is_annotation_present_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *cls = extract_dxclass_fw(self);
    DxClass *anno_type = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? extract_dxclass_fw(args[1].obj) : NULL;

    bool found = false;
    if (cls && anno_type && cls->annotations && anno_type->descriptor) {
        for (uint32_t i = 0; i < cls->annotation_count; i++) {
            if (cls->annotations[i].type && strcmp(cls->annotations[i].type, anno_type->descriptor) == 0) {
                found = true;
                break;
            }
        }
    }
    frame->result = DX_INT_VALUE(found ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// Class.getAnnotations() -> Annotation[]
static DxResult native_class_get_annotations_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *cls = extract_dxclass_fw(self);

    uint32_t count = (cls && cls->annotations) ? cls->annotation_count : 0;
    DxObject *arr = dx_vm_alloc_array(vm, count);
    if (arr && cls && cls->annotations) {
        for (uint32_t i = 0; i < count; i++) {
            DxClass *anno_cls = dx_vm_find_class(vm, cls->annotations[i].type);
            if (anno_cls) {
                DxObject *anno_obj = create_annotation_object(vm, anno_cls, &cls->annotations[i]);
                if (anno_obj) arr->array_elements[i] = DX_OBJ_VALUE(anno_obj);
            }
        }
    }
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Class.getDeclaredMethods() -> Method[]
static DxResult native_class_get_declared_methods_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *cls = extract_dxclass_fw(self);
    DxClass *method_cls = dx_vm_find_class(vm, "Ljava/lang/reflect/Method;");

    if (!cls || !method_cls) {
        DxObject *empty = dx_vm_alloc_array(vm, 0);
        frame->result = empty ? DX_OBJ_VALUE(empty) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    uint32_t total = cls->direct_method_count + cls->virtual_method_count;
    DxObject *arr = dx_vm_alloc_array(vm, total);
    if (!arr) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    uint32_t idx = 0;
    for (uint32_t i = 0; i < cls->direct_method_count && idx < total; i++) {
        DxMethod *m = &cls->direct_methods[i];
        DxObject *mobj = dx_vm_alloc_object(vm, method_cls);
        if (mobj && mobj->fields && method_cls->instance_field_count > 0) {
            mobj->fields[0].tag = DX_VAL_INT;
            mobj->fields[0].i = (int32_t)(uintptr_t)m;
        }
        arr->array_elements[idx++] = mobj ? DX_OBJ_VALUE(mobj) : DX_NULL_VALUE;
    }
    for (uint32_t i = 0; i < cls->virtual_method_count && idx < total; i++) {
        DxMethod *m = &cls->virtual_methods[i];
        DxObject *mobj = dx_vm_alloc_object(vm, method_cls);
        if (mobj && mobj->fields && method_cls->instance_field_count > 0) {
            mobj->fields[0].tag = DX_VAL_INT;
            mobj->fields[0].i = (int32_t)(uintptr_t)m;
        }
        arr->array_elements[idx++] = mobj ? DX_OBJ_VALUE(mobj) : DX_NULL_VALUE;
    }

    frame->result = DX_OBJ_VALUE(arr);
    frame->has_result = true;
    return DX_OK;
}

// Class.getDeclaredFields() -> Field[]
static DxResult native_class_get_declared_fields_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxClass *cls = extract_dxclass_fw(self);
    DxClass *field_cls_type = dx_vm_find_class(vm, "Ljava/lang/reflect/Field;");

    if (!cls || !field_cls_type) {
        DxObject *empty = dx_vm_alloc_array(vm, 0);
        frame->result = empty ? DX_OBJ_VALUE(empty) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    uint32_t total = cls->instance_field_count + cls->static_field_count;
    DxObject *arr = dx_vm_alloc_array(vm, total);
    if (!arr) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    uint32_t idx = 0;
    uint32_t field_def_count = 0;
    if (cls->field_defs) {
        field_def_count = cls->instance_field_count + cls->static_field_count;
    }
    for (uint32_t i = 0; i < field_def_count && idx < total; i++) {
        DxObject *fobj = dx_vm_alloc_object(vm, field_cls_type);
        if (fobj && fobj->fields && field_cls_type->instance_field_count > 0 && cls->field_defs[i].name) {
            DxObject *name_str = dx_vm_create_string(vm, cls->field_defs[i].name);
            fobj->fields[0] = name_str ? DX_OBJ_VALUE(name_str) : DX_NULL_VALUE;
        }
        arr->array_elements[idx++] = fobj ? DX_OBJ_VALUE(fobj) : DX_NULL_VALUE;
    }

    frame->result = DX_OBJ_VALUE(arr);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Framework reflection: Method annotation support
// ============================================================

// Method.getAnnotation(Class annotationType) -> Annotation or null
static DxResult native_method_get_annotation_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *method_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxMethod *method = NULL;
    if (method_obj && method_obj->fields && method_obj->klass
        && method_obj->klass->instance_field_count > 0
        && method_obj->fields[0].tag == DX_VAL_INT) {
        method = (DxMethod *)(uintptr_t)method_obj->fields[0].i;
    }

    DxClass *anno_type = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? extract_dxclass_fw(args[1].obj) : NULL;

    if (method && anno_type && method->annotations && anno_type->descriptor) {
        for (uint32_t i = 0; i < method->annotation_count; i++) {
            if (method->annotations[i].type && strcmp(method->annotations[i].type, anno_type->descriptor) == 0) {
                DxObject *anno_obj = create_annotation_object(vm, anno_type, &method->annotations[i]);
                frame->result = anno_obj ? DX_OBJ_VALUE(anno_obj) : DX_NULL_VALUE;
                frame->has_result = true;
                return DX_OK;
            }
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Method.isAnnotationPresent(Class annotationType) -> boolean
static DxResult native_method_is_annotation_present_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *method_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxMethod *method = NULL;
    if (method_obj && method_obj->fields && method_obj->klass
        && method_obj->klass->instance_field_count > 0
        && method_obj->fields[0].tag == DX_VAL_INT) {
        method = (DxMethod *)(uintptr_t)method_obj->fields[0].i;
    }

    DxClass *anno_type = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? extract_dxclass_fw(args[1].obj) : NULL;

    bool found = false;
    if (method && anno_type && method->annotations && anno_type->descriptor) {
        for (uint32_t i = 0; i < method->annotation_count; i++) {
            if (method->annotations[i].type && strcmp(method->annotations[i].type, anno_type->descriptor) == 0) {
                found = true;
                break;
            }
        }
    }
    frame->result = DX_INT_VALUE(found ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// Method.getAnnotations() -> Annotation[]
static DxResult native_method_get_annotations_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *method_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxMethod *method = NULL;
    if (method_obj && method_obj->fields && method_obj->klass
        && method_obj->klass->instance_field_count > 0
        && method_obj->fields[0].tag == DX_VAL_INT) {
        method = (DxMethod *)(uintptr_t)method_obj->fields[0].i;
    }

    uint32_t count = (method && method->annotations) ? method->annotation_count : 0;
    DxObject *arr = dx_vm_alloc_array(vm, count);
    if (arr && method && method->annotations) {
        for (uint32_t i = 0; i < count; i++) {
            DxClass *anno_cls = dx_vm_find_class(vm, method->annotations[i].type);
            if (anno_cls) {
                DxObject *anno_obj = create_annotation_object(vm, anno_cls, &method->annotations[i]);
                if (anno_obj) arr->array_elements[i] = DX_OBJ_VALUE(anno_obj);
            }
        }
    }
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Method.getName() -> String
static DxResult native_method_get_name_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *method_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxMethod *method = NULL;
    if (method_obj && method_obj->fields && method_obj->klass
        && method_obj->klass->instance_field_count > 0
        && method_obj->fields[0].tag == DX_VAL_INT) {
        method = (DxMethod *)(uintptr_t)method_obj->fields[0].i;
    }
    const char *name = (method && method->name) ? method->name : "unknown";
    DxObject *str = dx_vm_create_string(vm, name);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Field.getName() -> String
static DxResult native_field_get_name_fw(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *field_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    const char *name = NULL;
    if (field_obj && field_obj->fields && field_obj->klass
        && field_obj->klass->instance_field_count > 0
        && field_obj->fields[0].tag == DX_VAL_OBJ && field_obj->fields[0].obj) {
        name = dx_vm_get_string_value(field_obj->fields[0].obj);
    }
    DxObject *str = dx_vm_create_string(vm, name ? name : "unknown");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

DxResult dx_vm_register_framework_classes(DxVM *vm) {
    DxResult res = dx_register_java_lang(vm);
    if (res != DX_OK) return res;
    res = dx_register_android_framework(vm);
    if (res != DX_OK) return res;

    // Build vtables for framework classes in dependency order
    // Multiple passes ensure super vtables are built before subclass vtables
    for (int pass = 0; pass < 4; pass++) {
        build_framework_vtables(vm);
    }
    return DX_OK;
}

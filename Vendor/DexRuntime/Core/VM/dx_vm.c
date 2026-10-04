#include "../Include/dx_vm.h"
#include "../Include/dx_log.h"
#include "../Include/dx_view.h"
#include "../Include/dx_context.h"
#include "../Include/dx_runtime.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <mach/mach_time.h>

#define TAG "VM"

#include "../Include/dx_memory.h"

// Nanoseconds using Mach absolute time (for profiling)
static uint64_t dx_vm_time_ns(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

DxVM *dx_vm_create(DxContext *ctx) {
    DxVM *vm = (DxVM *)dx_malloc(sizeof(DxVM));
    if (!vm) return NULL;
    memset(vm, 0, sizeof(DxVM));
    vm->ctx = ctx;
    vm->insn_limit = DX_MAX_INSTRUCTIONS;
    vm->watchdog_timeout_ms = 10000;  // 10 seconds default
    vm->watchdog_start_time = 0;
    vm->watchdog_triggered = false;
    vm->young_gen_count = 0;
    vm->young_gen_threshold = 256;
    vm->gc_cycle_count = 0;
    DX_INFO(TAG, "VM created (insn limit=%u, watchdog=%ums)", DX_MAX_INSTRUCTIONS, vm->watchdog_timeout_ms);
    return vm;
}

void dx_vm_destroy(DxVM *vm) {
    if (!vm) return;

    // Clear intern table (values alias string object fields, freed with heap)
    vm->interned_count = 0;

    for (uint32_t i = 0; i < vm->heap_count; i++) {
        if (vm->heap[i]) {
            dx_free(vm->heap[i]->fields);
            dx_free(vm->heap[i]->string_data);
            dx_free(vm->heap[i]->array_elements);
            dx_free(vm->heap[i]);
        }
    }

    for (uint32_t i = 0; i < vm->class_count; i++) {
        if (vm->classes[i]) {
            dx_free(vm->classes[i]->field_defs);
            dx_free(vm->classes[i]->static_fields);
            // Free method annotations and line tables before freeing methods
            for (uint32_t m = 0; m < vm->classes[i]->direct_method_count; m++) {
                dx_free(vm->classes[i]->direct_methods[m].annotations);
                dx_free(vm->classes[i]->direct_methods[m].ic_table);
                dx_dex_free_code_item(&vm->classes[i]->direct_methods[m].code);
            }
            for (uint32_t m = 0; m < vm->classes[i]->virtual_method_count; m++) {
                dx_free(vm->classes[i]->virtual_methods[m].annotations);
                dx_free(vm->classes[i]->virtual_methods[m].ic_table);
                dx_dex_free_code_item(&vm->classes[i]->virtual_methods[m].code);
            }
            dx_free(vm->classes[i]->direct_methods);
            dx_free(vm->classes[i]->virtual_methods);
            dx_free(vm->classes[i]->vtable);
            // Free itable
            if (vm->classes[i]->itable) {
                for (int it = 0; it < vm->classes[i]->itable_count; it++) {
                    dx_free(vm->classes[i]->itable[it].methods);
                }
                dx_free(vm->classes[i]->itable);
            }
            dx_free(vm->classes[i]->interfaces);
            dx_free(vm->classes[i]->annotations);
            dx_free(vm->classes[i]);
        }
    }

    // Free per-DEX class_def caches
    for (uint32_t d = 0; d < vm->dex_count; d++) {
        dx_free(vm->class_def_cache[d]);
    }

    // Free pooled frames
    for (uint32_t i = 0; i < vm->frame_pool_count; i++) {
        dx_free(vm->frame_pool[i]);
    }

    dx_free(vm);
    DX_INFO(TAG, "VM destroyed");
}

// --------------------------------------------------------------------------
// Frame pool
// --------------------------------------------------------------------------

DxFrame *dx_vm_alloc_frame(DxVM *vm) {
    if (vm->frame_pool_count > 0) {
        DxFrame *f = vm->frame_pool[--vm->frame_pool_count];
        memset(f, 0, sizeof(DxFrame));
        return f;
    }
    return (DxFrame *)dx_malloc(sizeof(DxFrame));
}

void dx_vm_free_frame(DxVM *vm, DxFrame *frame) {
    if (!frame) return;
    if (vm->frame_pool_count < DX_FRAME_POOL_SIZE) {
        vm->frame_pool[vm->frame_pool_count++] = frame;
    } else {
        dx_free(frame);
    }
}

DxResult dx_vm_load_dex(DxVM *vm, DxDexFile *dex) {
    if (!vm || !dex) return DX_ERR_NULL_PTR;
    if (!vm->dex) {
        vm->dex = dex;  // first DEX becomes primary
    }
    if (vm->dex_count < DX_MAX_DEX_FILES) {
        uint32_t idx = vm->dex_count;
        vm->dex_files[idx] = dex;
        // Allocate class_def cache for O(1) lookup by class_def_index
        if (dex->class_count > 0) {
            vm->class_def_cache[idx] = (DxClass **)calloc(dex->class_count, sizeof(DxClass *));
            vm->class_def_cache_size[idx] = dex->class_count;
        }
        vm->dex_count++;
        DX_INFO(TAG, "DEX %u loaded into VM: %u classes", vm->dex_count, dex->class_count);
    } else {
        DX_WARN(TAG, "Too many DEX files (max %d), skipping", DX_MAX_DEX_FILES);
    }
    return DX_OK;
}

// FNV-1a hash for class descriptor strings
static uint32_t class_hash_fn(const char *s) {
    uint32_t h = 2166136261u;
    for (; *s; s++) {
        h ^= (uint8_t)*s;
        h *= 16777619u;
    }
    return h & (DX_CLASS_HASH_SIZE - 1);
}

// Insert a class into the hash table (also called from dx_android_framework.c)
void dx_vm_class_hash_insert(DxVM *vm, DxClass *cls) {
    if (!cls || !cls->descriptor) return;
    uint32_t idx = class_hash_fn(cls->descriptor);
    for (uint32_t i = 0; i < DX_CLASS_HASH_SIZE; i++) {
        uint32_t slot = (idx + i) & (DX_CLASS_HASH_SIZE - 1);
        if (!vm->class_hash[slot].descriptor) {
            vm->class_hash[slot].descriptor = cls->descriptor;
            vm->class_hash[slot].cls = cls;
            return;
        }
        if (strcmp(vm->class_hash[slot].descriptor, cls->descriptor) == 0) {
            vm->class_hash[slot].cls = cls;  // update existing
            return;
        }
    }
}

static DxClass *create_class(DxVM *vm, const char *descriptor, DxClass *super, bool is_framework) {
    if (vm->class_count >= DX_MAX_CLASSES) {
        DX_ERROR(TAG, "Class table full");
        return NULL;
    }

    DxClass *cls = (DxClass *)dx_malloc(sizeof(DxClass));
    if (!cls) return NULL;

    cls->descriptor = descriptor;  // owned by DEX or static string
    cls->super_class = super;
    cls->status = DX_CLASS_LOADED;
    cls->is_framework = is_framework;

    vm->classes[vm->class_count++] = cls;
    dx_vm_class_hash_insert(vm, cls);

    // Debug tracing: log class loads
    if (vm->debug.class_load_trace) {
        uint32_t dex_idx = 0;
        for (uint32_t d = 0; d < vm->dex_count; d++) {
            if (vm->dex_files[d] == vm->dex) { dex_idx = d; break; }
        }
        DX_INFO("Trace", "LOAD CLASS: %s from DEX %u", descriptor, dex_idx);
    }

    return cls;
}

static void add_native_method(DxClass *cls, const char *name, const char *shorty,
                               uint32_t access_flags, DxNativeMethodFn fn, bool is_direct) {
    DxMethod *methods;
    uint32_t *count;

    if (is_direct) {
        methods = cls->direct_methods;
        count = &cls->direct_method_count;
    } else {
        methods = cls->virtual_methods;
        count = &cls->virtual_method_count;
    }

    // Grow method array
    uint32_t idx = *count;
    uint32_t new_count = idx + 1;
    DxMethod *new_methods = (DxMethod *)dx_realloc(methods, sizeof(DxMethod) * new_count);
    if (!new_methods) return;

    memset(&new_methods[idx], 0, sizeof(DxMethod));
    new_methods[idx].name = name;
    new_methods[idx].shorty = shorty;
    new_methods[idx].declaring_class = cls;
    new_methods[idx].access_flags = access_flags;
    new_methods[idx].native_fn = fn;
    new_methods[idx].is_native = true;
    new_methods[idx].vtable_idx = is_direct ? -1 : (int32_t)idx;

    if (is_direct) {
        cls->direct_methods = new_methods;
    } else {
        cls->virtual_methods = new_methods;
    }
    *count = new_count;
}

// --- java.lang.Object native methods ---

static DxResult native_object_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)args; (void)arg_count;
    return DX_OK;
}

static DxResult native_return_null_vm(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_return_false_vm(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_object_tostring(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    const char *desc = (self && self->klass) ? self->klass->descriptor : "Object";
    char buf[128];
    snprintf(buf, sizeof(buf), "%s@%p", desc, (void *)self);
    DxObject *str = dx_vm_create_string(vm, buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_object_hashcode(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    frame->result = DX_INT_VALUE((int32_t)(uintptr_t)args[0].obj);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_object_equals(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    frame->result = DX_INT_VALUE(args[0].obj == args[1].obj ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_object_getclass(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    DxClass *actual_class = (self && self->klass) ? self->klass : vm->class_object;
    // Return a proper java.lang.Class object with klass pointing to the actual class
    DxClass *class_cls = dx_vm_find_class(vm, "Ljava/lang/Class;");
    DxObject *class_obj = dx_vm_alloc_object(vm, class_cls ? class_cls : actual_class);
    if (class_obj) {
        class_obj->klass = actual_class;  // The klass pointer IS the class it represents
    }
    frame->result = class_obj ? DX_OBJ_VALUE(class_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- java.lang.String native methods ---

static DxResult native_string_equals(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *other = args[1].obj;
    if (self == other) {
        frame->result = DX_INT_VALUE(1);
    } else if (!self || !other) {
        frame->result = DX_INT_VALUE(0);
    } else {
        const char *a = dx_vm_get_string_value(self);
        const char *b = dx_vm_get_string_value(other);
        frame->result = DX_INT_VALUE((a && b && strcmp(a, b) == 0) ? 1 : 0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_hashcode(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    int32_t h = 0;
    if (s) {
        for (const char *p = s; *p; p++) {
            h = h * 31 + (unsigned char)*p;
        }
    }
    frame->result = DX_INT_VALUE(h);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_length(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    frame->result = DX_INT_VALUE(s ? (int32_t)strlen(s) : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_tostring(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    frame->result = DX_OBJ_VALUE(args[0].obj);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_valueof(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    if (args[0].tag == DX_VAL_OBJ && args[0].obj) {
        const char *s = dx_vm_get_string_value(args[0].obj);
        if (s) {
            frame->result = DX_OBJ_VALUE(args[0].obj);
        } else {
            DxObject *str = dx_vm_create_string(vm, "null");
            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
        }
    } else {
        DxObject *str = dx_vm_create_string(vm, "null");
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_contains(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    const char *sub = dx_vm_get_string_value(args[1].obj);
    frame->result = DX_INT_VALUE((s && sub && strstr(s, sub)) ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// --- Additional String native methods ---

static DxResult native_string_charat(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    int32_t idx = args[1].i;
    if (!s || idx < 0 || idx >= (int32_t)strlen(s)) {
        frame->result = DX_INT_VALUE(0);
    } else {
        frame->result = DX_INT_VALUE((int32_t)(unsigned char)s[idx]);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_substring(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    const char *s = dx_vm_get_string_value(args[0].obj);
    if (!s) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    int32_t len = (int32_t)strlen(s);
    int32_t begin = args[1].i;
    int32_t end = (arg_count > 2) ? args[2].i : len;
    if (begin < 0) begin = 0;
    if (end > len) end = len;
    if (begin >= end) {
        DxObject *str = dx_vm_create_string(vm, "");
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    int32_t sub_len = end - begin;
    if (sub_len < 0) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    char *buf = (char *)dx_malloc((size_t)sub_len + 1);
    if (!buf) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    memcpy(buf, s + begin, (size_t)sub_len);
    buf[sub_len] = '\0';
    DxObject *str = dx_vm_create_string(vm, buf);
    dx_free(buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_indexof(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    const char *s = dx_vm_get_string_value(args[0].obj);
    const char *sub = dx_vm_get_string_value(args[1].obj);
    int32_t from = (arg_count > 2) ? args[2].i : 0;
    if (!s || !sub) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }
    int32_t len = (int32_t)strlen(s);
    if (from < 0) from = 0;
    if (from >= len) {
        frame->result = DX_INT_VALUE(sub[0] == '\0' ? len : -1);
        frame->has_result = true;
        return DX_OK;
    }
    const char *found = strstr(s + from, sub);
    frame->result = DX_INT_VALUE(found ? (int32_t)(found - s) : -1);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_lastindexof(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    const char *sub = dx_vm_get_string_value(args[1].obj);
    if (!s || !sub) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }
    int32_t sub_len = (int32_t)strlen(sub);
    int32_t s_len = (int32_t)strlen(s);
    int32_t last = -1;
    for (int32_t i = 0; i <= s_len - sub_len; i++) {
        if (strncmp(s + i, sub, (size_t)sub_len) == 0) last = i;
    }
    frame->result = DX_INT_VALUE(last);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_startswith(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    const char *prefix = dx_vm_get_string_value(args[1].obj);
    if (!s || !prefix) {
        frame->result = DX_INT_VALUE(0);
    } else {
        size_t plen = strlen(prefix);
        frame->result = DX_INT_VALUE(strncmp(s, prefix, plen) == 0 ? 1 : 0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_endswith(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    const char *suffix = dx_vm_get_string_value(args[1].obj);
    if (!s || !suffix) {
        frame->result = DX_INT_VALUE(0);
    } else {
        size_t slen = strlen(s);
        size_t xlen = strlen(suffix);
        if (xlen > slen) {
            frame->result = DX_INT_VALUE(0);
        } else {
            frame->result = DX_INT_VALUE(strcmp(s + slen - xlen, suffix) == 0 ? 1 : 0);
        }
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_trim(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    if (!s) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    while (*s && (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r')) s++;
    int32_t len = (int32_t)strlen(s);
    while (len > 0 && (s[len-1] == ' ' || s[len-1] == '\t' || s[len-1] == '\n' || s[len-1] == '\r')) len--;
    char *buf = (char *)dx_malloc((size_t)len + 1);
    if (!buf) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    memcpy(buf, s, (size_t)len);
    buf[len] = '\0';
    DxObject *str = dx_vm_create_string(vm, buf);
    dx_free(buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_tolowercase(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    if (!s) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    size_t len = strlen(s);
    char *buf = (char *)dx_malloc(len + 1);
    if (!buf) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        buf[i] = (c >= 'A' && c <= 'Z') ? (c + 32) : c;
    }
    buf[len] = '\0';
    DxObject *str = dx_vm_create_string(vm, buf);
    dx_free(buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_touppercase(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    if (!s) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    size_t len = strlen(s);
    char *buf = (char *)dx_malloc(len + 1);
    if (!buf) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        buf[i] = (c >= 'a' && c <= 'z') ? (c - 32) : c;
    }
    buf[len] = '\0';
    DxObject *str = dx_vm_create_string(vm, buf);
    dx_free(buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_replace(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    const char *target = dx_vm_get_string_value(args[1].obj);
    const char *replacement = dx_vm_get_string_value(args[2].obj);
    if (!s || !target || !replacement) {
        frame->result = DX_OBJ_VALUE(args[0].obj);
        frame->has_result = true;
        return DX_OK;
    }
    size_t tlen = strlen(target);
    if (tlen == 0) {
        frame->result = DX_OBJ_VALUE(args[0].obj);
        frame->has_result = true;
        return DX_OK;
    }
    size_t rlen = strlen(replacement);
    size_t slen = strlen(s);
    size_t count = 0;
    const char *p = s;
    while ((p = strstr(p, target)) != NULL) { count++; p += tlen; }
    if (count == 0) {
        frame->result = DX_OBJ_VALUE(args[0].obj);
        frame->has_result = true;
        return DX_OK;
    }
    size_t new_len = slen - (count * tlen) + (count * rlen);
    char *buf = (char *)dx_malloc(new_len + 1);
    if (!buf) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    char *dst = buf;
    p = s;
    while (*p) {
        const char *found = strstr(p, target);
        if (!found) {
            strcpy(dst, p);
            dst += strlen(p);
            break;
        }
        size_t chunk = (size_t)(found - p);
        memcpy(dst, p, chunk);
        dst += chunk;
        memcpy(dst, replacement, rlen);
        dst += rlen;
        p = found + tlen;
    }
    *dst = '\0';
    DxObject *str = dx_vm_create_string(vm, buf);
    dx_free(buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_isempty(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    frame->result = DX_INT_VALUE((!s || s[0] == '\0') ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_tochararray(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_compareto(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *a = dx_vm_get_string_value(args[0].obj);
    const char *b = dx_vm_get_string_value(args[1].obj);
    if (!a) a = "";
    if (!b) b = "";
    frame->result = DX_INT_VALUE((int32_t)strcmp(a, b));
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_concat(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *a = dx_vm_get_string_value(args[0].obj);
    const char *b = dx_vm_get_string_value(args[1].obj);
    if (!a) a = "";
    if (!b) b = "";
    size_t alen = strlen(a), blen = strlen(b);
    char *buf = (char *)dx_malloc(alen + blen + 1);
    if (!buf) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    memcpy(buf, a, alen);
    memcpy(buf + alen, b, blen);
    buf[alen + blen] = '\0';
    DxObject *str = dx_vm_create_string(vm, buf);
    dx_free(buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_split(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    const char *delim = dx_vm_get_string_value(args[1].obj);
    if (!s || !delim) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    size_t dlen = strlen(delim);
    if (dlen == 0) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    // Count splits
    int count = 1;
    const char *p = s;
    while ((p = strstr(p, delim)) != NULL) { count++; p += dlen; }
    // Create an ArrayList to hold result strings
    DxClass *list_cls = dx_vm_find_class(vm, "Ljava/util/ArrayList;");
    if (!list_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxObject *list = dx_vm_alloc_object(vm, list_cls);
    if (!list) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxValue *elements = (DxValue *)dx_malloc(sizeof(DxValue) * (size_t)count);
    if (!elements) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    p = s;
    int idx = 0;
    while (idx < count - 1) {
        const char *found = strstr(p, delim);
        if (!found) break;
        size_t chunk = (size_t)(found - p);
        char *part = (char *)dx_malloc(chunk + 1);
        if (part) {
            memcpy(part, p, chunk);
            part[chunk] = '\0';
            DxObject *str_obj = dx_vm_create_string(vm, part);
            dx_free(part);
            elements[idx] = str_obj ? DX_OBJ_VALUE(str_obj) : DX_NULL_VALUE;
        } else {
            elements[idx] = DX_NULL_VALUE;
        }
        p = found + dlen;
        idx++;
    }
    DxObject *last_str = dx_vm_create_string(vm, p);
    elements[idx] = last_str ? DX_OBJ_VALUE(last_str) : DX_NULL_VALUE;
    // Store in list using internal fields
    DxValue items_val; items_val.tag = DX_VAL_OBJ; items_val.obj = (DxObject *)(uintptr_t)elements;
    dx_vm_set_field(list, "_items", items_val);
    DxValue size_val; size_val.tag = DX_VAL_INT; size_val.i = count;
    dx_vm_set_field(list, "_size", size_val);
    DxValue cap_val; cap_val.tag = DX_VAL_INT; cap_val.i = count;
    dx_vm_set_field(list, "_capacity", cap_val);
    frame->result = DX_OBJ_VALUE(list);
    frame->has_result = true;
    return DX_OK;
}

// --- String.format / String.valueOf ---

static DxResult native_string_format(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // String.format(String, Object...) — simplified: just return the format string
    // Real implementation would need full Java Formatter, which is extremely complex
    const char *fmt = NULL;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        fmt = dx_vm_get_string_value(args[0].obj);
    }
    if (!fmt) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    // Basic %s/%d substitution for common cases
    char buf[1024];
    int pos = 0;
    int argIdx = 1; // args after format string
    const char *p = fmt;
    while (*p && pos < 1020) {
        if (*p == '%' && *(p+1)) {
            p++;
            if (*p == 's' && argIdx < (int)arg_count) {
                const char *s = NULL;
                if (args[argIdx].tag == DX_VAL_OBJ && args[argIdx].obj) {
                    s = dx_vm_get_string_value(args[argIdx].obj);
                }
                if (s) {
                    int n = snprintf(buf + pos, 1024 - pos, "%s", s);
                    if (n > 0) pos += n;
                }
                argIdx++;
                p++;
            } else if (*p == 'd' && argIdx < (int)arg_count) {
                int n = snprintf(buf + pos, 1024 - pos, "%d", args[argIdx].i);
                if (n > 0) pos += n;
                argIdx++;
                p++;
            } else if (*p == 'f' && argIdx < (int)arg_count) {
                double v = (args[argIdx].tag == DX_VAL_DOUBLE) ? args[argIdx].d : (double)args[argIdx].f;
                int n = snprintf(buf + pos, 1024 - pos, "%f", v);
                if (n > 0) pos += n;
                argIdx++;
                p++;
            } else if (*p == '%') {
                buf[pos++] = '%';
                p++;
            } else {
                buf[pos++] = '%';
                buf[pos++] = *p++;
            }
        } else {
            buf[pos++] = *p++;
        }
    }
    buf[pos] = '\0';

    DxObject *result = dx_vm_create_string(vm, buf);
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_valueof_int(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    char buf[32];
    int32_t val = (arg_count >= 1) ? args[0].i : 0;
    snprintf(buf, sizeof(buf), "%d", val);
    DxObject *result = dx_vm_create_string(vm, buf);
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_valueof_long(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    char buf[32];
    // Longs stored as int in our system
    int32_t val = (arg_count >= 1) ? args[0].i : 0;
    snprintf(buf, sizeof(buf), "%d", val);
    DxObject *result = dx_vm_create_string(vm, buf);
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_valueof_float(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    char buf[64];
    float val = (arg_count >= 1) ? args[0].f : 0.0f;
    snprintf(buf, sizeof(buf), "%g", (double)val);
    DxObject *result = dx_vm_create_string(vm, buf);
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_valueof_double(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    char buf[64];
    double val = (arg_count >= 1) ? args[0].d : 0.0;
    snprintf(buf, sizeof(buf), "%g", val);
    DxObject *result = dx_vm_create_string(vm, buf);
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_valueof_bool(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    int32_t val = (arg_count >= 1) ? args[0].i : 0;
    DxObject *result = dx_vm_create_string(vm, val ? "true" : "false");
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_valueof_char(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    char buf[2] = {0, 0};
    if (arg_count >= 1) buf[0] = (char)(args[0].i & 0xFF);
    DxObject *result = dx_vm_create_string(vm, buf);
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- Additional String methods ---

static DxResult native_string_replaceall(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    /* replaceAll(String regex, String replacement) — literal replacement (same as replace) */
    return native_string_replace(vm, frame, args, arg_count);
}

static DxResult native_string_getbytes(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    if (!s) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    size_t len = strlen(s);
    DxObject *arr = dx_vm_alloc_array(vm, (uint32_t)len);
    if (!arr) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    for (size_t i = 0; i < len; i++) {
        arr->array_elements[i] = DX_INT_VALUE((int32_t)(unsigned char)s[i]);
    }
    frame->result = DX_OBJ_VALUE(arr);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_getbytes_charset(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    /* getBytes(String charset) — ignore charset, same as getBytes() */
    return native_string_getbytes(vm, frame, args, arg_count);
}

static DxResult native_string_intern(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    frame->result = DX_OBJ_VALUE(args[0].obj);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_matches(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    const char *pattern = dx_vm_get_string_value(args[1].obj);
    if (!s || !pattern) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    /* Handle common regex patterns */
    if (strcmp(pattern, "\\d+") == 0) {
        int match = (s[0] != '\0') ? 1 : 0;
        for (const char *p = s; *p && match; p++) {
            if (*p < '0' || *p > '9') match = 0;
        }
        frame->result = DX_INT_VALUE(match);
    } else if (strcmp(pattern, "\\s+") == 0) {
        int match = (s[0] != '\0') ? 1 : 0;
        for (const char *p = s; *p && match; p++) {
            if (*p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') match = 0;
        }
        frame->result = DX_INT_VALUE(match);
    } else {
        /* Fallback: exact string match */
        frame->result = DX_INT_VALUE(strcmp(s, pattern) == 0 ? 1 : 0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_codepointat(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    const char *s = dx_vm_get_string_value(args[0].obj);
    int32_t idx = args[1].i;
    if (!s || idx < 0 || idx >= (int32_t)strlen(s)) {
        frame->result = DX_INT_VALUE(-1);
        frame->has_result = true;
        return DX_OK;
    }
    frame->result = DX_INT_VALUE((int32_t)(unsigned char)s[idx]);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_equalsignorecase(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    if (!args[1].obj || args[1].tag != DX_VAL_OBJ) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }
    const char *a = dx_vm_get_string_value(args[0].obj);
    const char *b = dx_vm_get_string_value(args[1].obj);
    if (!a || !b) {
        frame->result = DX_INT_VALUE((!a && !b) ? 1 : 0);
        frame->has_result = true;
        return DX_OK;
    }
    frame->result = DX_INT_VALUE(strcasecmp(a, b) == 0 ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_regionmatches(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_copyvalueof(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    /* copyValueOf(char[]) — static, args[0] is the char array */
    DxObject *arr = args[0].obj;
    if (!arr || !arr->is_array || arr->array_length == 0) {
        DxObject *empty = dx_vm_create_string(vm, "");
        frame->result = empty ? DX_OBJ_VALUE(empty) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    size_t len = arr->array_length;
    char *buf = (char *)dx_malloc(len + 1);
    if (!buf) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    for (size_t i = 0; i < len; i++) {
        buf[i] = (char)(arr->array_elements[i].i & 0xFF);
    }
    buf[len] = '\0';
    DxObject *str = dx_vm_create_string(vm, buf);
    dx_free(buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_string_join(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    /* String.join(CharSequence delimiter, CharSequence... elements) — static */
    const char *delim = dx_vm_get_string_value(args[0].obj);
    if (!delim) delim = "";
    size_t dlen = strlen(delim);
    /* Remaining args are the elements to join */
    if (arg_count <= 1) {
        DxObject *empty = dx_vm_create_string(vm, "");
        frame->result = empty ? DX_OBJ_VALUE(empty) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    /* If args[1] is an array, join its elements */
    if (arg_count == 2 && args[1].tag == DX_VAL_OBJ && args[1].obj && args[1].obj->is_array) {
        DxObject *arr = args[1].obj;
        size_t total = 0;
        for (uint32_t i = 0; i < arr->array_length; i++) {
            const char *elem = (arr->array_elements[i].tag == DX_VAL_OBJ && arr->array_elements[i].obj)
                ? dx_vm_get_string_value(arr->array_elements[i].obj) : "";
            if (!elem) elem = "";
            total += strlen(elem);
            if (i > 0) total += dlen;
        }
        char *buf = (char *)dx_malloc(total + 1);
        if (!buf) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
        char *dst = buf;
        for (uint32_t i = 0; i < arr->array_length; i++) {
            if (i > 0) { memcpy(dst, delim, dlen); dst += dlen; }
            const char *elem = (arr->array_elements[i].tag == DX_VAL_OBJ && arr->array_elements[i].obj)
                ? dx_vm_get_string_value(arr->array_elements[i].obj) : "";
            if (!elem) elem = "";
            size_t elen = strlen(elem);
            memcpy(dst, elem, elen);
            dst += elen;
        }
        *dst = '\0';
        DxObject *str = dx_vm_create_string(vm, buf);
        dx_free(buf);
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    /* Varargs: join args[1..N] */
    size_t total = 0;
    for (uint32_t i = 1; i < arg_count; i++) {
        const char *elem = (args[i].tag == DX_VAL_OBJ && args[i].obj)
            ? dx_vm_get_string_value(args[i].obj) : "";
        if (!elem) elem = "";
        total += strlen(elem);
        if (i > 1) total += dlen;
    }
    char *buf = (char *)dx_malloc(total + 1);
    if (!buf) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    char *dst = buf;
    for (uint32_t i = 1; i < arg_count; i++) {
        if (i > 1) { memcpy(dst, delim, dlen); dst += dlen; }
        const char *elem = (args[i].tag == DX_VAL_OBJ && args[i].obj)
            ? dx_vm_get_string_value(args[i].obj) : "";
        if (!elem) elem = "";
        size_t elen = strlen(elem);
        memcpy(dst, elem, elen);
        dst += elen;
    }
    *dst = '\0';
    DxObject *str = dx_vm_create_string(vm, buf);
    dx_free(buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- StringBuilder native methods ---

static DxResult native_sb_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self) {
        // Store empty string as initial buffer in dedicated string_data field
        dx_free(self->string_data);
        self->string_data = dx_strdup("");
    }
    return DX_OK;
}

static DxResult native_sb_append(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }

    const char *existing = self->string_data;
    if (!existing) existing = "";

    const char *append_str = "";
    if (arg_count > 1) {
        if (args[1].tag == DX_VAL_OBJ && args[1].obj) {
            const char *s = dx_vm_get_string_value(args[1].obj);
            if (s) append_str = s;
            else append_str = "null";
        } else if (args[1].tag == DX_VAL_INT) {
            char tmp[32];
            snprintf(tmp, sizeof(tmp), "%d", args[1].i);
            size_t len = strlen(existing) + strlen(tmp) + 1;
            char *combined = (char *)dx_malloc(len);
            snprintf(combined, len, "%s%s", existing, tmp);
            dx_free(self->string_data);
            self->string_data = combined;
            frame->result = DX_OBJ_VALUE(self);
            frame->has_result = true;
            return DX_OK;
        } else {
            append_str = "null";
        }
    }

    size_t len = strlen(existing) + strlen(append_str) + 1;
    char *combined = (char *)dx_malloc(len);
    snprintf(combined, len, "%s%s", existing, append_str);
    dx_free(self->string_data);
    self->string_data = combined;

    frame->result = DX_OBJ_VALUE(self);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_sb_tostring(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    const char *buf = "";
    if (self) {
        const char *s = self->string_data;
        if (s) buf = s;
    }
    DxObject *str = dx_vm_create_string(vm, buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- Throwable native methods ---

static DxResult native_throwable_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    // Store message if provided
    DxObject *self = args[0].obj;
    if (self && arg_count > 1 && args[1].tag == DX_VAL_OBJ) {
        dx_vm_set_field(self, "detailMessage", args[1]);
    }
    return DX_OK;
}

static DxResult native_throwable_get_message(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self) {
        DxValue msg;
        dx_vm_get_field(self, "detailMessage", &msg);
        if (msg.tag == DX_VAL_OBJ && msg.obj) {
            frame->result = msg;
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_throwable_get_stacktrace(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    // Return an empty StackTraceElement[] array
    DxObject *arr = dx_vm_alloc_array(vm, 0);
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_throwable_tostring(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    const char *desc = (self && self->klass) ? self->klass->descriptor : "Throwable";
    // Convert "Ljava/lang/Foo;" to "java.lang.Foo"
    char cls_name[256];
    size_t dlen = strlen(desc);
    if (dlen > 2 && desc[0] == 'L' && desc[dlen - 1] == ';') {
        size_t copy_len = dlen - 2;
        if (copy_len >= sizeof(cls_name)) copy_len = sizeof(cls_name) - 1;
        memcpy(cls_name, desc + 1, copy_len);
        cls_name[copy_len] = '\0';
        for (size_t i = 0; i < copy_len; i++) {
            if (cls_name[i] == '/') cls_name[i] = '.';
        }
    } else {
        snprintf(cls_name, sizeof(cls_name), "%s", desc);
    }
    const char *msg = NULL;
    if (self) {
        DxValue msg_val;
        dx_vm_get_field(self, "detailMessage", &msg_val);
        if (msg_val.tag == DX_VAL_OBJ && msg_val.obj)
            msg = dx_vm_get_string_value(msg_val.obj);
    }
    char buf[512];
    if (msg) snprintf(buf, sizeof(buf), "%s: %s", cls_name, msg);
    else     snprintf(buf, sizeof(buf), "%s", cls_name);
    DxObject *str = dx_vm_create_string(vm, buf);
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_throwable_get_cause(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    // Stub: return null (no chained exception support yet)
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_throwable_print_stacktrace(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)args; (void)arg_count;
    // No-op: single-threaded interpreter, no real stderr
    return DX_OK;
}

// --- StackTraceElement native methods ---

static DxResult native_ste_getclassname(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_ste_getmethodname(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    DxObject *str = dx_vm_create_string(vm, "");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- Kotlin Intrinsics native methods ---

static DxResult native_kotlin_noop(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)args; (void)arg_count;
    return DX_OK;
}

static DxResult native_kotlin_check_not_null(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    // In real Kotlin, this throws NPE if arg is null. We just warn and continue.
    if (args[0].tag != DX_VAL_OBJ || !args[0].obj) {
        DX_WARN(TAG, "Kotlin checkNotNull: value is null");
    }
    return DX_OK;
}

// --- System native methods ---

static DxResult native_system_currenttimemillis(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    frame->result.tag = DX_VAL_LONG;
    frame->result.l = 0; // Stub - could use real time but not necessary
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_system_arraycopy(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    // System.arraycopy(src, srcPos, dest, destPos, length)
    if (arg_count < 5) return DX_OK;

    DxObject *src = args[0].obj;
    int32_t src_pos = args[1].i;
    DxObject *dst = args[2].obj;
    int32_t dst_pos = args[3].i;
    int32_t length = args[4].i;

    if (!src || !dst || !src->is_array || !dst->is_array) {
        DX_TRACE(TAG, "System.arraycopy: non-array argument, absorbed");
        return DX_OK;
    }
    if (length <= 0) return DX_OK;
    if (src_pos < 0 || dst_pos < 0) return DX_OK;
    if ((uint32_t)(src_pos + length) > src->array_length) return DX_OK;
    if ((uint32_t)(dst_pos + length) > dst->array_length) return DX_OK;

    // Use memmove for overlapping regions (src and dst may be the same array)
    memmove(&dst->array_elements[dst_pos], &src->array_elements[src_pos],
            sizeof(DxValue) * (size_t)length);
    DX_TRACE(TAG, "System.arraycopy: copied %d elements", length);
    return DX_OK;
}

static DxResult native_system_loadlibrary(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    const char *lib_name = "(unknown)";
    if (arg_count > 0 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        const char *s = dx_vm_get_string_value(args[0].obj);
        if (s) lib_name = s;
    }
    char feat_buf[160];
    snprintf(feat_buf, sizeof(feat_buf), "System.loadLibrary(\"%s\") — native .so loading unsupported", lib_name);
    dx_vm_report_missing_feature(vm, feat_buf);
    DX_WARN(TAG, "System.loadLibrary(\"%s\") called — .so loading not supported, absorbed", lib_name);
    return DX_OK;
}

// --- PrintStream (for System.out.println) ---

static DxResult native_println(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        const char *s = dx_vm_get_string_value(args[1].obj);
        DX_INFO(TAG, "System.out: %s", s ? s : "(null)");
    } else if (arg_count > 1 && args[1].tag == DX_VAL_INT) {
        DX_INFO(TAG, "System.out: %d", args[1].i);
    } else {
        DX_INFO(TAG, "System.out: (empty)");
    }
    return DX_OK;
}

// ============================================================
// ArrayList native methods
// ============================================================

// Internal helpers to access ArrayList backing storage via DxObject arrays
// Fields: _items (DxObject array with is_array=true), _size (int)

static DxObject *arraylist_get_items_obj(DxObject *self) {
    DxValue v;
    if (dx_vm_get_field(self, "_items", &v) == DX_OK && v.tag == DX_VAL_OBJ && v.obj && v.obj->is_array) {
        return v.obj;
    }
    return NULL;
}

static int32_t arraylist_get_size(DxObject *self) {
    DxValue v;
    if (dx_vm_get_field(self, "_size", &v) == DX_OK && v.tag == DX_VAL_INT) {
        return v.i;
    }
    return 0;
}

static void arraylist_set_items_obj(DxObject *self, DxObject *arr) {
    DxValue v; v.tag = DX_VAL_OBJ; v.obj = arr;
    dx_vm_set_field(self, "_items", v);
}

static void arraylist_set_size(DxObject *self, int32_t size) {
    DxValue v; v.tag = DX_VAL_INT; v.i = size;
    dx_vm_set_field(self, "_size", v);
}

static bool arraylist_ensure_capacity(DxVM *vm, DxObject *self, int32_t min_cap) {
    DxObject *arr = arraylist_get_items_obj(self);
    int32_t cap = arr ? (int32_t)arr->array_length : 0;
    if (cap >= min_cap) return true;
    int32_t new_cap = cap < 4 ? 8 : cap * 2;
    if (new_cap < min_cap) new_cap = min_cap;
    DxObject *new_arr = dx_vm_alloc_array(vm, (uint32_t)new_cap);
    if (!new_arr) return false;
    // Copy existing elements
    if (arr && arr->array_elements && new_arr->array_elements) {
        for (int32_t i = 0; i < cap; i++) {
            new_arr->array_elements[i] = arr->array_elements[i];
        }
    }
    arraylist_set_items_obj(self, new_arr);
    return true;
}

static DxResult native_arraylist_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) return DX_OK;
    arraylist_set_size(self, 0);
    // Allocate initial backing array of capacity 8
    DxObject *arr = dx_vm_alloc_array(vm, 8);
    arraylist_set_items_obj(self, arr);
    return DX_OK;
}

static DxResult native_arraylist_add(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    int32_t size = arraylist_get_size(self);
    if (!arraylist_ensure_capacity(vm, self, size + 1)) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *arr = arraylist_get_items_obj(self);
    if (arr && arr->array_elements) arr->array_elements[size] = args[1];
    arraylist_set_size(self, size + 1);
    frame->result = DX_INT_VALUE(1); // true
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arraylist_add_at(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) return DX_OK;
    int32_t index = args[1].i;
    int32_t size = arraylist_get_size(self);
    if (index < 0 || index > size) return DX_OK;
    if (!arraylist_ensure_capacity(vm, self, size + 1)) return DX_OK;
    DxObject *arr = arraylist_get_items_obj(self);
    if (!arr || !arr->array_elements) return DX_OK;
    // Shift elements right
    for (int32_t i = size; i > index; i--) {
        arr->array_elements[i] = arr->array_elements[i - 1];
    }
    arr->array_elements[index] = args[2];
    arraylist_set_size(self, size + 1);
    return DX_OK;
}

static DxResult native_arraylist_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t index = args[1].i;
    int32_t size = arraylist_get_size(self);
    if (!self || index < 0 || index >= size) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *arr = arraylist_get_items_obj(self);
    frame->result = (arr && arr->array_elements) ? arr->array_elements[index] : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arraylist_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t index = args[1].i;
    int32_t size = arraylist_get_size(self);
    if (!self || index < 0 || index >= size) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *arr = arraylist_get_items_obj(self);
    DxValue prev = (arr && arr->array_elements) ? arr->array_elements[index] : DX_NULL_VALUE;
    if (arr && arr->array_elements) arr->array_elements[index] = args[2];
    frame->result = prev;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arraylist_remove(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t index = args[1].i;
    int32_t size = arraylist_get_size(self);
    if (!self || index < 0 || index >= size) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *arr = arraylist_get_items_obj(self);
    DxValue removed = (arr && arr->array_elements) ? arr->array_elements[index] : DX_NULL_VALUE;
    // Shift left
    if (arr && arr->array_elements) {
        for (int32_t i = index; i < size - 1; i++) {
            arr->array_elements[i] = arr->array_elements[i + 1];
        }
        arr->array_elements[size - 1] = DX_NULL_VALUE;
    }
    arraylist_set_size(self, size - 1);
    frame->result = removed;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arraylist_size(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    frame->result = DX_INT_VALUE(self ? arraylist_get_size(self) : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arraylist_isempty(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    frame->result = DX_INT_VALUE((!self || arraylist_get_size(self) == 0) ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arraylist_contains(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    DxValue target = args[1];
    int32_t size = arraylist_get_size(self);
    DxObject *arr = arraylist_get_items_obj(self);
    if (!arr || !arr->array_elements) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    for (int32_t i = 0; i < size; i++) {
        DxValue item = arr->array_elements[i];
        if (item.tag == target.tag) {
            if (target.tag == DX_VAL_OBJ && item.obj == target.obj) {
                frame->result = DX_INT_VALUE(1);
                frame->has_result = true;
                return DX_OK;
            }
            if (target.tag == DX_VAL_INT && item.i == target.i) {
                frame->result = DX_INT_VALUE(1);
                frame->has_result = true;
                return DX_OK;
            }
        }
    }
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arraylist_clear(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self) {
        DxObject *arr = arraylist_get_items_obj(self);
        if (arr && arr->array_elements) {
            int32_t size = arraylist_get_size(self);
            for (int32_t i = 0; i < size; i++) arr->array_elements[i] = DX_NULL_VALUE;
        }
        arraylist_set_size(self, 0);
    }
    return DX_OK;
}

static DxResult native_arraylist_indexof(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(-1); frame->has_result = true; return DX_OK; }
    DxValue target = args[1];
    int32_t size = arraylist_get_size(self);
    DxObject *arr = arraylist_get_items_obj(self);
    if (!arr || !arr->array_elements) { frame->result = DX_INT_VALUE(-1); frame->has_result = true; return DX_OK; }
    for (int32_t i = 0; i < size; i++) {
        DxValue item = arr->array_elements[i];
        if (item.tag == target.tag) {
            if (target.tag == DX_VAL_OBJ && item.obj == target.obj) {
                frame->result = DX_INT_VALUE(i);
                frame->has_result = true;
                return DX_OK;
            }
            if (target.tag == DX_VAL_INT && item.i == target.i) {
                frame->result = DX_INT_VALUE(i);
                frame->has_result = true;
                return DX_OK;
            }
        }
    }
    frame->result = DX_INT_VALUE(-1);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arraylist_iterator(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;  // the ArrayList
    DxClass *iter_cls = dx_vm_find_class(vm, "Ljava/util/Iterator;");
    if (iter_cls) {
        DxObject *iter = dx_vm_alloc_object(vm, iter_cls);
        if (iter) {
            // Store reference to the ArrayList and starting index
            dx_vm_set_field(iter, "_list", DX_OBJ_VALUE(self));
            dx_vm_set_field(iter, "_index", DX_INT_VALUE(0));
            frame->result = DX_OBJ_VALUE(iter);
        } else {
            frame->result = DX_NULL_VALUE;
        }
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_arraylist_toarray(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    int32_t size = self ? arraylist_get_size(self) : 0;
    DxObject *result = dx_vm_alloc_array(vm, (uint32_t)size);
    if (result && result->array_elements && size > 0) {
        DxObject *arr = arraylist_get_items_obj(self);
        if (arr && arr->array_elements) {
            for (int32_t i = 0; i < size; i++) {
                result->array_elements[i] = arr->array_elements[i];
            }
        }
    }
    frame->result = result ? DX_OBJ_VALUE(result) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Enum native methods
// ============================================================

static DxResult native_enum_name(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self || !self->klass) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    // Enum stores name in field "name" (set by <init>(String, int))
    DxValue name_val;
    if (dx_vm_get_field(self, "name", &name_val) == DX_OK && name_val.tag == DX_VAL_OBJ && name_val.obj) {
        frame->result = name_val;
    } else {
        // Fallback: return the class descriptor as name
        DxObject *str = dx_vm_create_string(vm, self->klass->descriptor);
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_enum_ordinal(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) {
        frame->result = DX_INT_VALUE(0);
        frame->has_result = true;
        return DX_OK;
    }
    // Enum stores ordinal in field "ordinal" (set by <init>(String, int))
    DxValue ord_val;
    if (dx_vm_get_field(self, "ordinal", &ord_val) == DX_OK && ord_val.tag == DX_VAL_INT) {
        frame->result = ord_val;
    } else {
        frame->result = DX_INT_VALUE(0);
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_enum_values(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)args; (void)arg_count;
    // Return an empty array as a stub for framework enums
    DxObject *arr = dx_vm_alloc_array(vm, 0);
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_enum_valueof(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    // Stub: return null for framework enums
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_enum_compareto(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    // compareTo compares ordinals: this.ordinal - other.ordinal
    int32_t this_ord = 0, other_ord = 0;
    if (arg_count >= 1 && args[0].tag == DX_VAL_OBJ && args[0].obj) {
        DxValue v;
        if (dx_vm_get_field(args[0].obj, "ordinal", &v) == DX_OK && v.tag == DX_VAL_INT) {
            this_ord = v.i;
        }
    }
    if (arg_count >= 2 && args[1].tag == DX_VAL_OBJ && args[1].obj) {
        DxValue v;
        if (dx_vm_get_field(args[1].obj, "ordinal", &v) == DX_OK && v.tag == DX_VAL_INT) {
            other_ord = v.i;
        }
    }
    frame->result = DX_INT_VALUE(this_ord - other_ord);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// HashMap native methods
// ============================================================

// HashMap storage: parallel arrays of keys and values
// Fields: _keys (DxValue* as obj ptr), _vals (DxValue* as obj ptr), _size (int), _capacity (int)

static DxObject *hashmap_get_keys_obj(DxObject *self) {
    DxValue v;
    if (dx_vm_get_field(self, "_keys", &v) == DX_OK && v.tag == DX_VAL_OBJ && v.obj && v.obj->is_array) {
        return v.obj;
    }
    return NULL;
}

static DxObject *hashmap_get_vals_obj(DxObject *self) {
    DxValue v;
    if (dx_vm_get_field(self, "_vals", &v) == DX_OK && v.tag == DX_VAL_OBJ && v.obj && v.obj->is_array) {
        return v.obj;
    }
    return NULL;
}

static int32_t hashmap_get_size(DxObject *self) {
    DxValue v;
    if (dx_vm_get_field(self, "_size", &v) == DX_OK && v.tag == DX_VAL_INT) {
        return v.i;
    }
    return 0;
}

static void hashmap_set_keys_obj(DxObject *self, DxObject *arr) {
    DxValue v; v.tag = DX_VAL_OBJ; v.obj = arr;
    dx_vm_set_field(self, "_keys", v);
}

static void hashmap_set_vals_obj(DxObject *self, DxObject *arr) {
    DxValue v; v.tag = DX_VAL_OBJ; v.obj = arr;
    dx_vm_set_field(self, "_vals", v);
}

static void hashmap_set_size(DxObject *self, int32_t size) {
    DxValue v; v.tag = DX_VAL_INT; v.i = size;
    dx_vm_set_field(self, "_size", v);
}

static bool hashmap_keys_equal(DxValue a, DxValue b) {
    if (a.tag == b.tag && a.tag == DX_VAL_OBJ && a.obj == b.obj) return true;
    if (a.tag != DX_VAL_OBJ || b.tag != DX_VAL_OBJ || !a.obj || !b.obj) {
        // Non-object comparison
        if (a.tag != b.tag) return false;
        if (a.tag == DX_VAL_INT) return a.i == b.i;
        if (a.tag == DX_VAL_LONG) return a.l == b.l;
        return false;
    }
    // String comparison for objects
    const char *sa = dx_vm_get_string_value(a.obj);
    const char *sb = dx_vm_get_string_value(b.obj);
    if (sa && sb) return strcmp(sa, sb) == 0;
    return false;
}

static bool hashmap_ensure_capacity(DxVM *vm, DxObject *self, int32_t min_cap) {
    DxObject *keys_arr = hashmap_get_keys_obj(self);
    DxObject *vals_arr = hashmap_get_vals_obj(self);
    int32_t cap = keys_arr ? (int32_t)keys_arr->array_length : 0;
    if (cap >= min_cap) return true;
    int32_t new_cap = cap < 8 ? 16 : cap * 2;
    if (new_cap < min_cap) new_cap = min_cap;
    DxObject *new_keys = dx_vm_alloc_array(vm, (uint32_t)new_cap);
    DxObject *new_vals = dx_vm_alloc_array(vm, (uint32_t)new_cap);
    if (!new_keys || !new_vals) return false;
    // Copy existing elements
    if (keys_arr && keys_arr->array_elements && new_keys->array_elements) {
        for (int32_t i = 0; i < cap; i++) {
            new_keys->array_elements[i] = keys_arr->array_elements[i];
        }
    }
    if (vals_arr && vals_arr->array_elements && new_vals->array_elements) {
        for (int32_t i = 0; i < cap; i++) {
            new_vals->array_elements[i] = vals_arr->array_elements[i];
        }
    }
    hashmap_set_keys_obj(self, new_keys);
    hashmap_set_vals_obj(self, new_vals);
    return true;
}

static int32_t hashmap_find_key(DxObject *self, DxValue key) {
    int32_t size = hashmap_get_size(self);
    DxObject *keys_arr = hashmap_get_keys_obj(self);
    if (!keys_arr || !keys_arr->array_elements) return -1;
    for (int32_t i = 0; i < size; i++) {
        if (hashmap_keys_equal(keys_arr->array_elements[i], key)) return i;
    }
    return -1;
}

static DxResult native_hashmap_init(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) return DX_OK;
    hashmap_set_size(self, 0);
    // Allocate initial backing arrays of capacity 16
    DxObject *keys_arr = dx_vm_alloc_array(vm, 16);
    DxObject *vals_arr = dx_vm_alloc_array(vm, 16);
    hashmap_set_keys_obj(self, keys_arr);
    hashmap_set_vals_obj(self, vals_arr);
    return DX_OK;
}

static DxResult native_hashmap_put(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxValue key = args[1];
    DxValue val = args[2];
    int32_t idx = hashmap_find_key(self, key);
    if (idx >= 0) {
        // Replace existing
        DxObject *vals_arr = hashmap_get_vals_obj(self);
        DxValue prev = (vals_arr && vals_arr->array_elements) ? vals_arr->array_elements[idx] : DX_NULL_VALUE;
        if (vals_arr && vals_arr->array_elements) vals_arr->array_elements[idx] = val;
        frame->result = prev;
        frame->has_result = true;
        return DX_OK;
    }
    // Add new entry
    int32_t size = hashmap_get_size(self);
    if (!hashmap_ensure_capacity(vm, self, size + 1)) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *keys_arr = hashmap_get_keys_obj(self);
    DxObject *vals_arr = hashmap_get_vals_obj(self);
    if (keys_arr && keys_arr->array_elements) keys_arr->array_elements[size] = key;
    if (vals_arr && vals_arr->array_elements) vals_arr->array_elements[size] = val;
    hashmap_set_size(self, size + 1);
    frame->result = DX_NULL_VALUE; // no previous value
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    int32_t idx = hashmap_find_key(self, args[1]);
    if (idx >= 0) {
        DxObject *vals_arr = hashmap_get_vals_obj(self);
        frame->result = (vals_arr && vals_arr->array_elements) ? vals_arr->array_elements[idx] : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_containskey(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    frame->result = DX_INT_VALUE(hashmap_find_key(self, args[1]) >= 0 ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_remove(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    int32_t idx = hashmap_find_key(self, args[1]);
    if (idx < 0) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *keys_arr = hashmap_get_keys_obj(self);
    DxObject *vals_arr = hashmap_get_vals_obj(self);
    DxValue removed = (vals_arr && vals_arr->array_elements) ? vals_arr->array_elements[idx] : DX_NULL_VALUE;
    int32_t size = hashmap_get_size(self);
    // Shift remaining entries
    if (keys_arr && keys_arr->array_elements && vals_arr && vals_arr->array_elements) {
        for (int32_t i = idx; i < size - 1; i++) {
            keys_arr->array_elements[i] = keys_arr->array_elements[i + 1];
            vals_arr->array_elements[i] = vals_arr->array_elements[i + 1];
        }
        keys_arr->array_elements[size - 1] = DX_NULL_VALUE;
        vals_arr->array_elements[size - 1] = DX_NULL_VALUE;
    }
    hashmap_set_size(self, size - 1);
    frame->result = removed;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_size(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    frame->result = DX_INT_VALUE(self ? hashmap_get_size(self) : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_isempty(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    frame->result = DX_INT_VALUE((!self || hashmap_get_size(self) == 0) ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_clear(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    if (self) {
        int32_t size = hashmap_get_size(self);
        DxObject *keys_arr = hashmap_get_keys_obj(self);
        DxObject *vals_arr = hashmap_get_vals_obj(self);
        if (keys_arr && keys_arr->array_elements && vals_arr && vals_arr->array_elements) {
            for (int32_t i = 0; i < size; i++) {
                keys_arr->array_elements[i] = DX_NULL_VALUE;
                vals_arr->array_elements[i] = DX_NULL_VALUE;
            }
        }
        hashmap_set_size(self, 0);
    }
    return DX_OK;
}

// Helper: create an ArrayList populated with elements from a HashMap backing array
static DxObject *hashmap_collect_to_arraylist(DxVM *vm, DxObject *src_arr, int32_t count) {
    if (!vm->class_arraylist) return NULL;
    DxObject *list = dx_vm_alloc_object(vm, vm->class_arraylist);
    if (!list) return NULL;
    DxObject *items = dx_vm_alloc_array(vm, count > 0 ? (uint32_t)count : 1);
    if (!items) return NULL;
    for (int32_t i = 0; i < count && src_arr && src_arr->array_elements; i++) {
        items->array_elements[i] = src_arr->array_elements[i];
    }
    arraylist_set_items_obj(list, items);
    arraylist_set_size(list, count);
    return list;
}

static DxResult native_hashmap_keyset(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t size = self ? hashmap_get_size(self) : 0;
    DxObject *keys_arr = self ? hashmap_get_keys_obj(self) : NULL;
    DxObject *list = hashmap_collect_to_arraylist(vm, keys_arr, size);
    frame->result = list ? DX_OBJ_VALUE(list) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_values(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t size = self ? hashmap_get_size(self) : 0;
    DxObject *vals_arr = self ? hashmap_get_vals_obj(self) : NULL;
    DxObject *list = hashmap_collect_to_arraylist(vm, vals_arr, size);
    frame->result = list ? DX_OBJ_VALUE(list) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_entryset(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    // Return an ArrayList of keys as a stand-in for Set<Map.Entry>
    DxObject *self = (arg_count >= 1 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t size = self ? hashmap_get_size(self) : 0;
    DxObject *keys_arr = self ? hashmap_get_keys_obj(self) : NULL;
    DxObject *list = hashmap_collect_to_arraylist(vm, keys_arr, size);
    frame->result = list ? DX_OBJ_VALUE(list) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_containsvalue(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    int32_t size = hashmap_get_size(self);
    DxObject *vals_arr = hashmap_get_vals_obj(self);
    if (!vals_arr || !vals_arr->array_elements) { frame->result = DX_INT_VALUE(0); frame->has_result = true; return DX_OK; }
    DxValue needle = args[1];
    for (int32_t i = 0; i < size; i++) {
        if (hashmap_keys_equal(vals_arr->array_elements[i], needle)) {
            frame->result = DX_INT_VALUE(1);
            frame->has_result = true;
            return DX_OK;
        }
    }
    frame->result = DX_INT_VALUE(0);
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_putall(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    DxObject *self = args[0].obj;
    DxObject *other = (arg_count >= 2 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    if (!self || !other) return DX_OK;
    int32_t other_size = hashmap_get_size(other);
    DxObject *other_keys = hashmap_get_keys_obj(other);
    DxObject *other_vals = hashmap_get_vals_obj(other);
    if (!other_keys || !other_keys->array_elements || !other_vals || !other_vals->array_elements) return DX_OK;
    for (int32_t i = 0; i < other_size; i++) {
        DxValue key = other_keys->array_elements[i];
        DxValue val = other_vals->array_elements[i];
        int32_t idx = hashmap_find_key(self, key);
        if (idx >= 0) {
            DxObject *vals_arr = hashmap_get_vals_obj(self);
            if (vals_arr && vals_arr->array_elements) vals_arr->array_elements[idx] = val;
        } else {
            int32_t size = hashmap_get_size(self);
            if (!hashmap_ensure_capacity(vm, self, size + 1)) continue;
            DxObject *keys_arr = hashmap_get_keys_obj(self);
            DxObject *vals_arr = hashmap_get_vals_obj(self);
            if (keys_arr && keys_arr->array_elements) keys_arr->array_elements[size] = key;
            if (vals_arr && vals_arr->array_elements) vals_arr->array_elements[size] = val;
            hashmap_set_size(self, size + 1);
        }
    }
    return DX_OK;
}

static DxResult native_hashmap_getordefault(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = (arg_count >= 3) ? args[2] : DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    int32_t idx = hashmap_find_key(self, args[1]);
    if (idx >= 0) {
        DxObject *vals_arr = hashmap_get_vals_obj(self);
        frame->result = (vals_arr && vals_arr->array_elements) ? vals_arr->array_elements[idx] : DX_NULL_VALUE;
    } else {
        frame->result = (arg_count >= 3) ? args[2] : DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_putifabsent(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    DxValue key = args[1];
    DxValue val = args[2];
    int32_t idx = hashmap_find_key(self, key);
    if (idx >= 0) {
        // Key exists - return existing value, do not overwrite
        DxObject *vals_arr = hashmap_get_vals_obj(self);
        frame->result = (vals_arr && vals_arr->array_elements) ? vals_arr->array_elements[idx] : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    // Key absent - insert and return null
    int32_t size = hashmap_get_size(self);
    if (!hashmap_ensure_capacity(vm, self, size + 1)) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    DxObject *keys_arr = hashmap_get_keys_obj(self);
    DxObject *vals_arr = hashmap_get_vals_obj(self);
    if (keys_arr && keys_arr->array_elements) keys_arr->array_elements[size] = key;
    if (vals_arr && vals_arr->array_elements) vals_arr->array_elements[size] = val;
    hashmap_set_size(self, size + 1);
    frame->result = DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_hashmap_tostring(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self) {
        DxObject *s = dx_vm_create_string(vm, "null");
        frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    int32_t size = hashmap_get_size(self);
    DxObject *keys_arr = hashmap_get_keys_obj(self);
    DxObject *vals_arr = hashmap_get_vals_obj(self);
    // Calculate buffer size: "{" + entries + "}"
    // Each entry: key_str + "=" + val_str + ", "
    // Estimate 64 bytes per entry, minimum 3 for "{}"
    size_t buf_cap = (size_t)size * 128 + 4;
    char *buf = (char *)dx_malloc(buf_cap);
    if (!buf) {
        DxObject *s = dx_vm_create_string(vm, "{}");
        frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    size_t pos = 0;
    buf[pos++] = '{';
    for (int32_t i = 0; i < size; i++) {
        if (i > 0 && pos + 2 < buf_cap) {
            buf[pos++] = ',';
            buf[pos++] = ' ';
        }
        // Key
        const char *ks = NULL;
        if (keys_arr && keys_arr->array_elements) {
            DxValue kv = keys_arr->array_elements[i];
            if (kv.tag == DX_VAL_OBJ && kv.obj) {
                ks = dx_vm_get_string_value(kv.obj);
            }
        }
        if (!ks) ks = "null";
        for (const char *p = ks; *p && pos + 1 < buf_cap; p++) buf[pos++] = *p;
        // "="
        if (pos + 1 < buf_cap) buf[pos++] = '=';
        // Value
        const char *vs = NULL;
        if (vals_arr && vals_arr->array_elements) {
            DxValue vv = vals_arr->array_elements[i];
            if (vv.tag == DX_VAL_OBJ && vv.obj) {
                vs = dx_vm_get_string_value(vv.obj);
            } else if (vv.tag == DX_VAL_INT) {
                // Format int inline
                static char ibuf[20];
                snprintf(ibuf, sizeof(ibuf), "%d", vv.i);
                vs = ibuf;
            } else if (vv.tag == DX_VAL_LONG) {
                static char lbuf[30];
                snprintf(lbuf, sizeof(lbuf), "%lld", (long long)vv.l);
                vs = lbuf;
            }
        }
        if (!vs) vs = "null";
        for (const char *p = vs; *p && pos + 1 < buf_cap; p++) buf[pos++] = *p;
    }
    if (pos + 1 < buf_cap) buf[pos++] = '}';
    buf[pos] = '\0';
    DxObject *s = dx_vm_create_string(vm, buf);
    dx_free(buf);
    frame->result = s ? DX_OBJ_VALUE(s) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Class.getName() - returns the class descriptor as a Java-style name
static DxResult native_class_getname(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    const char *desc = NULL;
    if (self && self->klass && self->klass->descriptor) {
        desc = self->klass->descriptor;
    }
    if (desc) {
        // Convert "Lcom/example/Foo;" -> "com.example.Foo"
        size_t len = strlen(desc);
        char *name = (char *)dx_malloc(len + 1);
        if (name) {
            size_t start = (desc[0] == 'L') ? 1 : 0;
            size_t end = (len > 0 && desc[len - 1] == ';') ? len - 1 : len;
            size_t j = 0;
            for (size_t i = start; i < end; i++) {
                name[j++] = (desc[i] == '/') ? '.' : desc[i];
            }
            name[j] = '\0';
            DxObject *str = dx_vm_create_string(vm, name);
            dx_free(name);
            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
            frame->has_result = true;
            return DX_OK;
        }
    }
    DxObject *str = dx_vm_create_string(vm, "Unknown");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

static DxResult native_class_getsimplename(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    const char *desc = NULL;
    if (self && self->klass && self->klass->descriptor) {
        desc = self->klass->descriptor;
    }
    if (desc) {
        // Find last '/' or start
        const char *last_slash = strrchr(desc, '/');
        const char *start = last_slash ? last_slash + 1 : desc;
        if (*start == 'L') start++;
        size_t len = strlen(start);
        if (len > 0 && start[len - 1] == ';') len--;
        char *name = (char *)dx_malloc(len + 1);
        if (name) {
            memcpy(name, start, len);
            name[len] = '\0';
            DxObject *str = dx_vm_create_string(vm, name);
            dx_free(name);
            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
            frame->has_result = true;
            return DX_OK;
        }
    }
    DxObject *str = dx_vm_create_string(vm, "Unknown");
    frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// --- Thread.start() -> synchronous run() ---

static DxResult native_thread_start(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)frame; (void)arg_count;
    // Get `this` (the Thread object) from args[0]
    DxObject *self = args[0].obj;
    if (!self || !self->klass) {
        DX_TRACE(TAG, "Thread.start: null thread object");
        return DX_OK;
    }

    // Find run() on the actual class (may be overridden in a subclass)
    DxMethod *run_method = dx_vm_find_method(self->klass, "run", "V");
    if (!run_method) {
        DX_TRACE(TAG, "Thread.start: no run() method found on %s", self->klass->descriptor);
        return DX_OK;
    }

    DX_INFO(TAG, "Thread.start: running %s.run() synchronously", self->klass->descriptor);
    DxValue run_args[1];
    run_args[0] = args[0];  // pass `this`
    dx_vm_execute_method(vm, run_method, run_args, 1, NULL);
    return DX_OK;
}

static DxResult native_thread_isalive(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)args; (void)arg_count;
    // Single-threaded: thread is never alive after start() returns synchronously
    frame->result.tag = DX_VAL_INT;
    frame->result.i = 0;  // false
    frame->has_result = true;
    return DX_OK;
}

// --- Array.clone() ---

static DxResult native_array_clone(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (!self || !self->is_array) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *clone = dx_vm_alloc_array(vm, self->array_length);
    if (!clone) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    if (self->array_length > 0 && self->array_elements) {
        memcpy(clone->array_elements, self->array_elements,
               sizeof(DxValue) * self->array_length);
    }

    frame->result = DX_OBJ_VALUE(clone);
    frame->has_result = true;
    DX_TRACE(TAG, "Array.clone: cloned array of length %u", self->array_length);
    return DX_OK;
}

// --- Class.forName() -> actual class lookup ---
// 1-arg: forName(String className) — defaults to initialize=true
// 3-arg: forName(String className, boolean initialize, ClassLoader loader)

static DxResult native_class_forname(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] is the class name string (static method, no `this`)
    DxObject *name_obj = args[0].obj;
    if (!name_obj) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    const char *name = dx_vm_get_string_value(name_obj);
    if (!name) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Determine initialize flag: 1-arg defaults to true, 3-arg reads args[1]
    bool initialize = true;
    if (arg_count >= 3) {
        initialize = (args[1].tag == DX_VAL_INT) ? (args[1].i != 0) : true;
    }

    // Convert "com.example.Foo" to "Lcom/example/Foo;" descriptor format
    size_t len = strlen(name);
    char *desc = (char *)dx_malloc(len + 3);  // L + name + ; + \0
    if (!desc) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    desc[0] = 'L';
    for (size_t i = 0; i < len; i++) {
        desc[i + 1] = (name[i] == '.') ? '/' : name[i];
    }
    desc[len + 1] = ';';
    desc[len + 2] = '\0';

    DX_INFO(TAG, "Class.forName(\"%s\", initialize=%d) -> %s", name, initialize, desc);

    DxClass *cls = dx_vm_find_class(vm, desc);
    if (!cls) {
        // Try loading from DEX
        dx_vm_load_class(vm, desc, &cls);
    }
    dx_free(desc);

    if (cls) {
        // Run <clinit> if initialize=true and class not yet initialized
        if (initialize && cls->status < DX_CLASS_INITIALIZED) {
            dx_vm_init_class(vm, cls);
        }

        // Return an object representing the class
        DxClass *class_cls = dx_vm_find_class(vm, "Ljava/lang/Class;");
        DxObject *class_obj = dx_vm_alloc_object(vm, class_cls ? class_cls : cls);
        if (class_obj) {
            class_obj->klass = cls;  // The klass pointer IS the class it represents
        }
        frame->result = class_obj ? DX_OBJ_VALUE(class_obj) : DX_NULL_VALUE;
    } else {
        DX_TRACE(TAG, "Class.forName: class not found");
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// --- Class.isInterface() ---

static DxResult native_class_isinterface(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    bool is_iface = false;
    if (self && self->klass) {
        is_iface = (self->klass->access_flags & DX_ACC_INTERFACE) != 0;
    }
    frame->result = DX_INT_VALUE(is_iface ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// --- Class.getSuperclass() ---

static DxResult native_class_getsuperclass(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *self = args[0].obj;
    if (self && self->klass && self->klass->super_class) {
        // Return a Class object representing the superclass
        // We create a stub object with the superclass as its klass
        DxObject *cls_obj = dx_vm_alloc_object(vm, self->klass->super_class);
        frame->result = cls_obj ? DX_OBJ_VALUE(cls_obj) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// --- Class.isArray() ---

static DxResult native_class_isarray(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    DxObject *self = args[0].obj;
    bool is_arr = false;
    if (self && self->is_array) {
        is_arr = true;
    } else if (self && self->klass && self->klass->descriptor && self->klass->descriptor[0] == '[') {
        is_arr = true;
    }
    frame->result = DX_INT_VALUE(is_arr ? 1 : 0);
    frame->has_result = true;
    return DX_OK;
}

// --- Class.isAssignableFrom() ---

static DxResult native_class_isassignablefrom(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)arg_count;
    // this.isAssignableFrom(other) - check if `other` class is a subclass of `this`
    DxObject *self = args[0].obj;
    DxObject *other = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;

    if (!self || !self->klass || !other || !other->klass) {
        frame->result.tag = DX_VAL_INT;
        frame->result.i = 0;
        frame->has_result = true;
        return DX_OK;
    }

    // Walk the superclass chain of `other` to see if `self`'s class appears
    DxClass *target = self->klass;
    DxClass *check = other->klass;
    bool assignable = false;
    while (check) {
        if (check == target) {
            assignable = true;
            break;
        }
        check = check->super_class;
    }

    frame->result.tag = DX_VAL_INT;
    frame->result.i = assignable ? 1 : 0;
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Reflection: Annotations on Class
// ============================================================

// Helper: extract DxClass* from a java.lang.Class object
// Supports both patterns: klass-pointer-as-class and field[0]-as-int
static DxClass *extract_dxclass(DxObject *class_obj) {
    if (!class_obj) return NULL;
    // The dx_vm.c pattern: class_obj->klass IS the class it represents
    // (as set by Object.getClass() and Class.forName in dx_vm.c)
    if (class_obj->klass) return class_obj->klass;
    return NULL;
}

// Helper: create an annotation object with element data stored in field[0]
static DxObject *vm_create_annotation_object(DxVM *vm, DxClass *anno_cls, const DxAnnotationEntry *entry) {
    DxObject *anno_obj = dx_vm_alloc_object(vm, anno_cls);
    if (anno_obj && anno_obj->fields && anno_cls->instance_field_count >= 2) {
        anno_obj->fields[0].tag = DX_VAL_INT;
        anno_obj->fields[0].i = (int32_t)(uintptr_t)entry;
    }
    return anno_obj;
}

// Class.getAnnotation(Class annotationType) -> Annotation or null
static DxResult native_class_getannotation(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxClass *cls = extract_dxclass(args[0].obj);
    // args[1] = annotation type Class object
    DxClass *anno_type = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? extract_dxclass(args[1].obj) : NULL;

    if (cls && anno_type && cls->annotations && anno_type->descriptor) {
        for (uint32_t i = 0; i < cls->annotation_count; i++) {
            if (cls->annotations[i].type && strcmp(cls->annotations[i].type, anno_type->descriptor) == 0) {
                DxObject *anno_obj = vm_create_annotation_object(vm, anno_type, &cls->annotations[i]);
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

// Class.getAnnotations() -> Annotation[]
static DxResult native_class_getannotations(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxClass *cls = extract_dxclass(args[0].obj);

    uint32_t count = (cls && cls->annotations) ? cls->annotation_count : 0;
    DxObject *arr = dx_vm_alloc_array(vm, count);
    if (arr && cls && cls->annotations) {
        for (uint32_t i = 0; i < count; i++) {
            DxClass *anno_cls = dx_vm_find_class(vm, cls->annotations[i].type);
            if (anno_cls) {
                DxObject *anno_obj = vm_create_annotation_object(vm, anno_cls, &cls->annotations[i]);
                if (anno_obj) arr->array_elements[i] = DX_OBJ_VALUE(anno_obj);
            }
        }
    }
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Class.isAnnotationPresent(Class annotationType) -> boolean
static DxResult native_class_isannotationpresent(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxClass *cls = extract_dxclass(args[0].obj);
    DxClass *anno_type = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? extract_dxclass(args[1].obj) : NULL;

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

// ============================================================
// Reflection: getDeclaredMethods / getDeclaredFields on Class
// ============================================================

// Class.getDeclaredMethods() -> Method[]
static DxResult native_class_getdeclaredmethods(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxClass *cls = extract_dxclass(args[0].obj);
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
    // Direct methods
    for (uint32_t i = 0; i < cls->direct_method_count && idx < total; i++) {
        DxMethod *m = &cls->direct_methods[i];
        DxObject *mobj = dx_vm_alloc_object(vm, method_cls);
        if (mobj && mobj->fields && method_cls->instance_field_count > 0) {
            mobj->fields[0].tag = DX_VAL_INT;
            mobj->fields[0].i = (int32_t)(uintptr_t)m;
        }
        arr->array_elements[idx++] = mobj ? DX_OBJ_VALUE(mobj) : DX_NULL_VALUE;
    }
    // Virtual methods
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
static DxResult native_class_getdeclaredfields(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxClass *cls = extract_dxclass(args[0].obj);
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
    // All fields come from field_defs (covers both instance and static)
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
// Reflection: Constructor
// ============================================================

// Class.getConstructor(Class...) / getDeclaredConstructor(Class...) -> Constructor
static DxResult native_class_getconstructor(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxClass *cls = extract_dxclass(args[0].obj);
    DxClass *ctor_cls = dx_vm_find_class(vm, "Ljava/lang/reflect/Constructor;");

    if (!cls || !ctor_cls) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Find <init> method - try matching param count if Class[] arg provided
    DxMethod *found = NULL;
    // Check if args[1] is a Class[] array (parameter types)
    uint32_t wanted_params = 0;
    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj && args[1].obj->is_array) {
        wanted_params = args[1].obj->array_length;
    }

    // Search direct methods for <init>
    for (uint32_t i = 0; i < cls->direct_method_count; i++) {
        DxMethod *m = &cls->direct_methods[i];
        if (m->name && strcmp(m->name, "<init>") == 0) {
            // Approximate param count from shorty: shorty length - 1 (return type) = param count
            uint32_t param_count = m->shorty ? (uint32_t)(strlen(m->shorty) - 1) : 0;
            if (!found || param_count == wanted_params) {
                found = m;
                if (param_count == wanted_params) break;
            }
        }
    }

    if (!found) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Create Constructor object: field[0] = DxMethod*, field[1] = DxClass*
    DxObject *ctor_obj = dx_vm_alloc_object(vm, ctor_cls);
    if (ctor_obj && ctor_obj->fields && ctor_cls->instance_field_count >= 2) {
        ctor_obj->fields[0].tag = DX_VAL_INT;
        ctor_obj->fields[0].i = (int32_t)(uintptr_t)found;
        ctor_obj->fields[1].tag = DX_VAL_INT;
        ctor_obj->fields[1].i = (int32_t)(uintptr_t)cls;
    }
    frame->result = ctor_obj ? DX_OBJ_VALUE(ctor_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Constructor.newInstance(Object...) -> Object
static DxResult native_constructor_newinstance(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *self = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields || self->klass->instance_field_count < 2) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxMethod *init_method = (self->fields[0].tag == DX_VAL_INT) ? (DxMethod *)(uintptr_t)self->fields[0].i : NULL;
    DxClass *cls = (self->fields[1].tag == DX_VAL_INT) ? (DxClass *)(uintptr_t)self->fields[1].i : NULL;

    if (!init_method || !cls) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Allocate the new object
    DxObject *obj = dx_vm_alloc_object(vm, cls);
    if (!obj) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Build arg list: this + params from Object[] array (args[1])
    DxValue call_args[DX_MAX_REGISTERS];
    uint32_t call_count = 0;
    call_args[call_count++] = DX_OBJ_VALUE(obj);

    if (arg_count > 1 && args[1].tag == DX_VAL_OBJ && args[1].obj && args[1].obj->is_array) {
        DxObject *params = args[1].obj;
        for (uint32_t i = 0; i < params->array_length && call_count < DX_MAX_REGISTERS; i++) {
            call_args[call_count++] = params->array_elements[i];
        }
    }

    DxValue result = {0};
    vm->insn_count = 0;
    DxResult res = dx_vm_execute_method(vm, init_method, call_args, call_count, &result);
    if (res != DX_OK && vm->pending_exception) {
        vm->pending_exception = NULL;
    }

    frame->result = DX_OBJ_VALUE(obj);
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Reflection: Array.newInstance
// ============================================================

static DxResult native_array_newinstance(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    // args[0] = Class componentType, args[1] = int length
    int32_t length = (arg_count > 1 && args[1].tag == DX_VAL_INT) ? args[1].i : 0;
    if (length < 0) length = 0;

    DxObject *arr = dx_vm_alloc_array(vm, (uint32_t)length);
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Array.getLength(Object array) -> int
static DxResult native_array_getlength(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *arr = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t len = (arr && arr->is_array) ? (int32_t)arr->array_length : 0;
    frame->result = DX_INT_VALUE(len);
    frame->has_result = true;
    return DX_OK;
}

// Array.get(Object array, int index) -> Object
static DxResult native_array_get(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *arr = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t idx = (arg_count > 1 && args[1].tag == DX_VAL_INT) ? args[1].i : -1;
    if (arr && arr->is_array && idx >= 0 && (uint32_t)idx < arr->array_length) {
        frame->result = arr->array_elements[idx];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Array.set(Object array, int index, Object value)
static DxResult native_array_set(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm; (void)frame;
    DxObject *arr = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    int32_t idx = (arg_count > 1 && args[1].tag == DX_VAL_INT) ? args[1].i : -1;
    if (arr && arr->is_array && idx >= 0 && (uint32_t)idx < arr->array_length && arg_count > 2) {
        arr->array_elements[idx] = args[2];
    }
    return DX_OK;
}

// ============================================================
// Reflection: Proxy.newProxyInstance (simplified)
// ============================================================

// Native dispatch function for proxy method calls
// The proxy object stores: field[0] = InvocationHandler, field[1] = Class[] interfaces
static DxResult native_proxy_dispatch(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // This is called as an instance method on the proxy: args[0] = proxy (this)
    // We need to route to InvocationHandler.invoke(proxy, method, args)
    DxObject *proxy = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!proxy || !proxy->fields || proxy->klass->instance_field_count < 1) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // field[0] = InvocationHandler
    DxObject *handler = (proxy->fields[0].tag == DX_VAL_OBJ) ? proxy->fields[0].obj : NULL;
    if (!handler) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Find InvocationHandler.invoke method
    DxMethod *invoke_method = dx_vm_find_method(handler->klass, "invoke", NULL);
    if (!invoke_method) {
        // Try virtual methods on the handler's class
        for (uint32_t i = 0; i < handler->klass->virtual_method_count; i++) {
            if (handler->klass->virtual_methods[i].name &&
                strcmp(handler->klass->virtual_methods[i].name, "invoke") == 0) {
                invoke_method = &handler->klass->virtual_methods[i];
                break;
            }
        }
    }
    if (!invoke_method) {
        DX_WARN("Proxy", "InvocationHandler has no invoke method");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Create Method object for the called method (use frame->method)
    DxClass *method_cls = dx_vm_find_class(vm, "Ljava/lang/reflect/Method;");
    DxObject *method_obj = method_cls ? dx_vm_alloc_object(vm, method_cls) : NULL;
    if (method_obj && method_obj->fields && method_cls->instance_field_count > 0 && frame->method) {
        method_obj->fields[0].tag = DX_VAL_INT;
        method_obj->fields[0].i = (int32_t)(uintptr_t)frame->method;
    }

    // Create args array from remaining arguments
    uint32_t extra_args = (arg_count > 1) ? arg_count - 1 : 0;
    DxObject *args_arr = dx_vm_alloc_array(vm, extra_args);
    if (args_arr) {
        for (uint32_t i = 0; i < extra_args; i++) {
            args_arr->array_elements[i] = args[i + 1];
        }
    }

    // Call handler.invoke(proxy, method, args)
    DxValue invoke_args[4];
    invoke_args[0] = DX_OBJ_VALUE(handler);    // this (handler)
    invoke_args[1] = DX_OBJ_VALUE(proxy);       // proxy
    invoke_args[2] = method_obj ? DX_OBJ_VALUE(method_obj) : DX_NULL_VALUE;  // method
    invoke_args[3] = args_arr ? DX_OBJ_VALUE(args_arr) : DX_NULL_VALUE;      // args

    DxValue result = {0};
    vm->insn_count = 0;
    DxResult res = dx_vm_execute_method(vm, invoke_method, invoke_args, 4, &result);
    if (res == DX_OK) {
        frame->result = result;
    } else {
        frame->result = DX_NULL_VALUE;
        if (vm->pending_exception) vm->pending_exception = NULL;
    }
    frame->has_result = true;
    return DX_OK;
}

// Proxy.newProxyInstance(ClassLoader, Class[], InvocationHandler) -> Object
static DxResult native_proxy_newproxyinstance(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // args[0] = ClassLoader (ignored), args[1] = Class[] interfaces, args[2] = InvocationHandler
    DxObject *interfaces_arr = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? args[1].obj : NULL;
    DxObject *handler = (arg_count > 2 && args[2].tag == DX_VAL_OBJ) ? args[2].obj : NULL;

    if (!handler) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Create a dynamic proxy class
    // We need a runtime-generated class that delegates all method calls to the handler
    char proxy_desc[128];
    static int proxy_counter = 0;
    snprintf(proxy_desc, sizeof(proxy_desc), "L$Proxy%d;", proxy_counter++);

    DxClass *obj_cls = vm->class_object;
    DxClass *proxy_cls = (DxClass *)dx_malloc(sizeof(DxClass));
    if (!proxy_cls) { frame->result = DX_NULL_VALUE; frame->has_result = true; return DX_OK; }
    memset(proxy_cls, 0, sizeof(DxClass));

    // Store the descriptor string permanently
    proxy_cls->descriptor = dx_strdup(proxy_desc);
    proxy_cls->super_class = obj_cls;
    proxy_cls->status = DX_CLASS_INITIALIZED;
    proxy_cls->is_framework = true;
    proxy_cls->instance_field_count = 2; // field[0]=handler, field[1]=interfaces

    // Copy interface methods as proxy dispatch methods
    if (interfaces_arr && interfaces_arr->is_array) {
        // Set interfaces on the proxy class
        proxy_cls->interface_count = interfaces_arr->array_length;
        proxy_cls->interfaces = (const char **)dx_malloc(sizeof(char *) * interfaces_arr->array_length);

        for (uint32_t ii = 0; ii < interfaces_arr->array_length; ii++) {
            DxClass *iface = NULL;
            if (interfaces_arr->array_elements[ii].tag == DX_VAL_OBJ &&
                interfaces_arr->array_elements[ii].obj) {
                iface = extract_dxclass(interfaces_arr->array_elements[ii].obj);
            }
            if (!iface) continue;
            if (proxy_cls->interfaces) {
                proxy_cls->interfaces[ii] = iface->descriptor;
            }

            // Add each virtual method from the interface as a proxy dispatch method
            for (uint32_t mi = 0; mi < iface->virtual_method_count; mi++) {
                DxMethod *im = &iface->virtual_methods[mi];
                // Grow virtual methods
                uint32_t idx = proxy_cls->virtual_method_count;
                DxMethod *new_methods = (DxMethod *)dx_realloc(proxy_cls->virtual_methods,
                    sizeof(DxMethod) * (idx + 1));
                if (!new_methods) continue;
                memset(&new_methods[idx], 0, sizeof(DxMethod));
                new_methods[idx].name = im->name;
                new_methods[idx].shorty = im->shorty;
                new_methods[idx].declaring_class = proxy_cls;
                new_methods[idx].access_flags = DX_ACC_PUBLIC;
                new_methods[idx].native_fn = native_proxy_dispatch;
                new_methods[idx].is_native = true;
                new_methods[idx].vtable_idx = (int32_t)idx;
                proxy_cls->virtual_methods = new_methods;
                proxy_cls->virtual_method_count = idx + 1;
            }
        }
    }

    // Register in VM
    if (vm->class_count < DX_MAX_CLASSES) {
        vm->classes[vm->class_count++] = proxy_cls;
        dx_vm_class_hash_insert(vm, proxy_cls);
    }

    // Allocate the proxy object
    DxObject *proxy_obj = dx_vm_alloc_object(vm, proxy_cls);
    if (proxy_obj && proxy_obj->fields) {
        proxy_obj->fields[0] = DX_OBJ_VALUE(handler);       // InvocationHandler
        if (interfaces_arr) {
            proxy_obj->fields[1] = DX_OBJ_VALUE(interfaces_arr); // Class[] interfaces
        }
    }

    frame->result = proxy_obj ? DX_OBJ_VALUE(proxy_obj) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Proxy.getInvocationHandler(Object proxy) -> InvocationHandler
static DxResult native_proxy_getinvocationhandler(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *proxy = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (proxy && proxy->fields && proxy->klass && proxy->klass->instance_field_count >= 1
        && proxy->fields[0].tag == DX_VAL_OBJ) {
        frame->result = proxy->fields[0];
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// ============================================================
// Reflection: Method annotations
// ============================================================

// Method.getAnnotation(Class annotationType) -> Annotation or null
static DxResult native_method_getannotation(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    DxObject *method_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxMethod *method = NULL;
    if (method_obj && method_obj->fields && method_obj->klass
        && method_obj->klass->instance_field_count > 0
        && method_obj->fields[0].tag == DX_VAL_INT) {
        method = (DxMethod *)(uintptr_t)method_obj->fields[0].i;
    }

    DxClass *anno_type = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? extract_dxclass(args[1].obj) : NULL;

    if (method && anno_type && method->annotations && anno_type->descriptor) {
        for (uint32_t i = 0; i < method->annotation_count; i++) {
            if (method->annotations[i].type && strcmp(method->annotations[i].type, anno_type->descriptor) == 0) {
                DxObject *anno_obj = vm_create_annotation_object(vm, anno_type, &method->annotations[i]);
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

// Method.getAnnotations() -> Annotation[]
static DxResult native_method_getannotations(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
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
                DxObject *anno_obj = vm_create_annotation_object(vm, anno_cls, &method->annotations[i]);
                if (anno_obj) arr->array_elements[i] = DX_OBJ_VALUE(anno_obj);
            }
        }
    }
    frame->result = arr ? DX_OBJ_VALUE(arr) : DX_NULL_VALUE;
    frame->has_result = true;
    return DX_OK;
}

// Method.isAnnotationPresent(Class annotationType) -> boolean
static DxResult native_method_isannotationpresent(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)vm;
    DxObject *method_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxMethod *method = NULL;
    if (method_obj && method_obj->fields && method_obj->klass
        && method_obj->klass->instance_field_count > 0
        && method_obj->fields[0].tag == DX_VAL_INT) {
        method = (DxMethod *)(uintptr_t)method_obj->fields[0].i;
    }

    DxClass *anno_type = (arg_count > 1 && args[1].tag == DX_VAL_OBJ) ? extract_dxclass(args[1].obj) : NULL;

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

// Method.getName() -> String
static DxResult native_method_getname(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
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

// Method.getDeclaringClass() -> Class
static DxResult native_method_getdeclaringclass(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    (void)arg_count;
    DxObject *method_obj = (args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    DxMethod *method = NULL;
    if (method_obj && method_obj->fields && method_obj->klass
        && method_obj->klass->instance_field_count > 0
        && method_obj->fields[0].tag == DX_VAL_INT) {
        method = (DxMethod *)(uintptr_t)method_obj->fields[0].i;
    }

    if (method && method->declaring_class) {
        DxClass *class_cls = dx_vm_find_class(vm, "Ljava/lang/Class;");
        DxObject *class_obj = dx_vm_alloc_object(vm, class_cls ? class_cls : method->declaring_class);
        if (class_obj) {
            class_obj->klass = method->declaring_class;
        }
        frame->result = class_obj ? DX_OBJ_VALUE(class_obj) : DX_NULL_VALUE;
    } else {
        frame->result = DX_NULL_VALUE;
    }
    frame->has_result = true;
    return DX_OK;
}

// Field.getName() -> String
static DxResult native_field_getname(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
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

// --- Register java.lang classes ---

DxResult dx_register_java_lang(DxVM *vm) {
    // java.lang.Object
    DxClass *obj_cls = create_class(vm, "Ljava/lang/Object;", NULL, true);
    if (!obj_cls) return DX_ERR_OUT_OF_MEMORY;
    vm->class_object = obj_cls;
    add_native_method(obj_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(obj_cls, "toString", "L", DX_ACC_PUBLIC,
                      native_object_tostring, false);
    add_native_method(obj_cls, "hashCode", "I", DX_ACC_PUBLIC,
                      native_object_hashcode, false);
    add_native_method(obj_cls, "equals", "ZL", DX_ACC_PUBLIC,
                      native_object_equals, false);
    add_native_method(obj_cls, "getClass", "L", DX_ACC_PUBLIC,
                      native_object_getclass, false);
    add_native_method(obj_cls, "clone", "L", DX_ACC_PUBLIC,
                      native_array_clone, false);  // works for arrays; objects get shallow copy
    add_native_method(obj_cls, "wait", "V", DX_ACC_PUBLIC,
                      native_object_init, false);  // no-op (single-threaded)
    add_native_method(obj_cls, "wait", "VJ", DX_ACC_PUBLIC,
                      native_object_init, false);
    add_native_method(obj_cls, "wait", "VJI", DX_ACC_PUBLIC,
                      native_object_init, false);
    add_native_method(obj_cls, "notify", "V", DX_ACC_PUBLIC,
                      native_object_init, false);
    add_native_method(obj_cls, "notifyAll", "V", DX_ACC_PUBLIC,
                      native_object_init, false);
    obj_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.String
    DxClass *str_cls = create_class(vm, "Ljava/lang/String;", obj_cls, true);
    if (!str_cls) return DX_ERR_OUT_OF_MEMORY;
    vm->class_string = str_cls;
    str_cls->instance_field_count = 1;
    str_cls->field_defs = (typeof(str_cls->field_defs))dx_malloc(sizeof(*str_cls->field_defs));
    if (str_cls->field_defs) {
        str_cls->field_defs[0].name = "value";
        str_cls->field_defs[0].type = "[C";
        str_cls->field_defs[0].flags = DX_ACC_PRIVATE;
    }
    add_native_method(str_cls, "equals", "ZL", DX_ACC_PUBLIC,
                      native_string_equals, false);
    add_native_method(str_cls, "hashCode", "I", DX_ACC_PUBLIC,
                      native_string_hashcode, false);
    add_native_method(str_cls, "length", "I", DX_ACC_PUBLIC,
                      native_string_length, false);
    add_native_method(str_cls, "toString", "L", DX_ACC_PUBLIC,
                      native_string_tostring, false);
    add_native_method(str_cls, "valueOf", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_valueof, true);
    add_native_method(str_cls, "contains", "ZL", DX_ACC_PUBLIC,
                      native_string_contains, false);
    add_native_method(str_cls, "charAt", "CI", DX_ACC_PUBLIC,
                      native_string_charat, false);
    add_native_method(str_cls, "substring", "LI", DX_ACC_PUBLIC,
                      native_string_substring, false);
    add_native_method(str_cls, "substring", "LII", DX_ACC_PUBLIC,
                      native_string_substring, false);
    add_native_method(str_cls, "indexOf", "IL", DX_ACC_PUBLIC,
                      native_string_indexof, false);
    add_native_method(str_cls, "indexOf", "ILI", DX_ACC_PUBLIC,
                      native_string_indexof, false);
    add_native_method(str_cls, "lastIndexOf", "IL", DX_ACC_PUBLIC,
                      native_string_lastindexof, false);
    add_native_method(str_cls, "startsWith", "ZL", DX_ACC_PUBLIC,
                      native_string_startswith, false);
    add_native_method(str_cls, "endsWith", "ZL", DX_ACC_PUBLIC,
                      native_string_endswith, false);
    add_native_method(str_cls, "trim", "L", DX_ACC_PUBLIC,
                      native_string_trim, false);
    add_native_method(str_cls, "toLowerCase", "L", DX_ACC_PUBLIC,
                      native_string_tolowercase, false);
    add_native_method(str_cls, "toUpperCase", "L", DX_ACC_PUBLIC,
                      native_string_touppercase, false);
    add_native_method(str_cls, "replace", "LLL", DX_ACC_PUBLIC,
                      native_string_replace, false);
    add_native_method(str_cls, "isEmpty", "Z", DX_ACC_PUBLIC,
                      native_string_isempty, false);
    add_native_method(str_cls, "toCharArray", "L", DX_ACC_PUBLIC,
                      native_string_tochararray, false);
    add_native_method(str_cls, "compareTo", "IL", DX_ACC_PUBLIC,
                      native_string_compareto, false);
    add_native_method(str_cls, "concat", "LL", DX_ACC_PUBLIC,
                      native_string_concat, false);
    add_native_method(str_cls, "split", "LL", DX_ACC_PUBLIC,
                      native_string_split, false);
    add_native_method(str_cls, "format", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_format, true);
    add_native_method(str_cls, "valueOf", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_valueof_int, true);
    add_native_method(str_cls, "valueOf", "LJ", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_valueof_long, true);
    add_native_method(str_cls, "valueOf", "LF", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_valueof_float, true);
    add_native_method(str_cls, "valueOf", "LD", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_valueof_double, true);
    add_native_method(str_cls, "valueOf", "LZ", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_valueof_bool, true);
    add_native_method(str_cls, "valueOf", "LC", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_valueof_char, true);
    add_native_method(str_cls, "replaceAll", "LLL", DX_ACC_PUBLIC,
                      native_string_replaceall, false);
    add_native_method(str_cls, "getBytes", "L", DX_ACC_PUBLIC,
                      native_string_getbytes, false);
    add_native_method(str_cls, "getBytes", "LL", DX_ACC_PUBLIC,
                      native_string_getbytes_charset, false);
    add_native_method(str_cls, "intern", "L", DX_ACC_PUBLIC,
                      native_string_intern, false);
    add_native_method(str_cls, "matches", "ZL", DX_ACC_PUBLIC,
                      native_string_matches, false);
    add_native_method(str_cls, "codePointAt", "II", DX_ACC_PUBLIC,
                      native_string_codepointat, false);
    add_native_method(str_cls, "equalsIgnoreCase", "ZL", DX_ACC_PUBLIC,
                      native_string_equalsignorecase, false);
    add_native_method(str_cls, "regionMatches", "ZLILI", DX_ACC_PUBLIC,
                      native_string_regionmatches, false);
    add_native_method(str_cls, "copyValueOf", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_copyvalueof, true);
    add_native_method(str_cls, "join", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_string_join, true);
    str_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.CharSequence (interface)
    DxClass *charseq_cls = create_class(vm, "Ljava/lang/CharSequence;", obj_cls, true);
    charseq_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    charseq_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Comparable (interface)
    DxClass *comparable_cls = create_class(vm, "Ljava/lang/Comparable;", obj_cls, true);
    comparable_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    comparable_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.StringBuilder
    DxClass *sb_cls = create_class(vm, "Ljava/lang/StringBuilder;", obj_cls, true);
    sb_cls->instance_field_count = 1;
    sb_cls->field_defs = (typeof(sb_cls->field_defs))dx_malloc(sizeof(*sb_cls->field_defs));
    if (sb_cls->field_defs) {
        sb_cls->field_defs[0].name = "buf";
        sb_cls->field_defs[0].type = "Ljava/lang/Object;";
        sb_cls->field_defs[0].flags = DX_ACC_PRIVATE;
    }
    add_native_method(sb_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_sb_init, true);
    add_native_method(sb_cls, "append", "LL", DX_ACC_PUBLIC,
                      native_sb_append, false);
    add_native_method(sb_cls, "toString", "L", DX_ACC_PUBLIC,
                      native_sb_tostring, false);
    sb_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.StringBuffer (same as StringBuilder for our purposes)
    DxClass *sbuf_cls = create_class(vm, "Ljava/lang/StringBuffer;", obj_cls, true);
    sbuf_cls->instance_field_count = 1;
    sbuf_cls->field_defs = (typeof(sbuf_cls->field_defs))dx_malloc(sizeof(*sbuf_cls->field_defs));
    if (sbuf_cls->field_defs) {
        sbuf_cls->field_defs[0].name = "buf";
        sbuf_cls->field_defs[0].type = "Ljava/lang/Object;";
        sbuf_cls->field_defs[0].flags = DX_ACC_PRIVATE;
    }
    add_native_method(sbuf_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_sb_init, true);
    add_native_method(sbuf_cls, "append", "LL", DX_ACC_PUBLIC,
                      native_sb_append, false);
    add_native_method(sbuf_cls, "toString", "L", DX_ACC_PUBLIC,
                      native_sb_tostring, false);
    sbuf_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Throwable
    DxClass *throwable_cls = create_class(vm, "Ljava/lang/Throwable;", obj_cls, true);
    throwable_cls->instance_field_count = 1;
    throwable_cls->field_defs = (typeof(throwable_cls->field_defs))dx_malloc(sizeof(*throwable_cls->field_defs));
    if (throwable_cls->field_defs) {
        throwable_cls->field_defs[0].name = "detailMessage";
        throwable_cls->field_defs[0].type = "Ljava/lang/String;";
        throwable_cls->field_defs[0].flags = DX_ACC_PRIVATE;
    }
    add_native_method(throwable_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(throwable_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_throwable_init, true);
    add_native_method(throwable_cls, "getMessage", "L", DX_ACC_PUBLIC,
                      native_throwable_get_message, false);
    add_native_method(throwable_cls, "getStackTrace", "L", DX_ACC_PUBLIC,
                      native_throwable_get_stacktrace, false);
    add_native_method(throwable_cls, "toString", "L", DX_ACC_PUBLIC,
                      native_throwable_tostring, false);
    add_native_method(throwable_cls, "getCause", "L", DX_ACC_PUBLIC,
                      native_throwable_get_cause, false);
    add_native_method(throwable_cls, "printStackTrace", "V", DX_ACC_PUBLIC,
                      native_throwable_print_stacktrace, false);
    throwable_cls->status = DX_CLASS_INITIALIZED;

    // Helper macro: register an exception subclass with inherited detailMessage field,
    // <init>(V), <init>(VL), getMessage(L), toString(L)
    #define REG_EXCEPTION(var, desc, super_cls) \
        DxClass *var = create_class(vm, desc, super_cls, true); \
        var->instance_field_count = 1; /* inherit detailMessage from Throwable */ \
        add_native_method(var, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, \
                          native_object_init, true); \
        add_native_method(var, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR, \
                          native_throwable_init, true); \
        add_native_method(var, "getMessage", "L", DX_ACC_PUBLIC, \
                          native_throwable_get_message, false); \
        add_native_method(var, "getStackTrace", "L", DX_ACC_PUBLIC, \
                          native_throwable_get_stacktrace, false); \
        add_native_method(var, "toString", "L", DX_ACC_PUBLIC, \
                          native_throwable_tostring, false); \
        add_native_method(var, "getCause", "L", DX_ACC_PUBLIC, \
                          native_throwable_get_cause, false); \
        add_native_method(var, "printStackTrace", "V", DX_ACC_PUBLIC, \
                          native_throwable_print_stacktrace, false); \
        var->status = DX_CLASS_INITIALIZED;

    // java.lang.Error extends Throwable
    REG_EXCEPTION(error_cls, "Ljava/lang/Error;", throwable_cls);

    // java.lang.StackOverflowError extends Error
    REG_EXCEPTION(soe_cls, "Ljava/lang/StackOverflowError;", error_cls);

    // java.lang.OutOfMemoryError extends Error
    REG_EXCEPTION(oom_cls, "Ljava/lang/OutOfMemoryError;", error_cls);

    // java.lang.Exception extends Throwable
    REG_EXCEPTION(exception_cls, "Ljava/lang/Exception;", throwable_cls);

    // java.lang.RuntimeException extends Exception
    REG_EXCEPTION(rte_cls, "Ljava/lang/RuntimeException;", exception_cls);

    // java.lang.NullPointerException extends RuntimeException
    REG_EXCEPTION(npe_cls, "Ljava/lang/NullPointerException;", rte_cls);

    // java.lang.IllegalArgumentException extends RuntimeException
    REG_EXCEPTION(iae_cls, "Ljava/lang/IllegalArgumentException;", rte_cls);

    // java.lang.IllegalStateException extends RuntimeException
    REG_EXCEPTION(ise_cls, "Ljava/lang/IllegalStateException;", rte_cls);

    // java.lang.UnsupportedOperationException extends RuntimeException
    REG_EXCEPTION(uoe_cls, "Ljava/lang/UnsupportedOperationException;", rte_cls);

    // java.lang.ClassCastException extends RuntimeException
    REG_EXCEPTION(cce_cls, "Ljava/lang/ClassCastException;", rte_cls);

    // java.lang.IndexOutOfBoundsException extends RuntimeException
    REG_EXCEPTION(ioob_cls, "Ljava/lang/IndexOutOfBoundsException;", rte_cls);

    // java.lang.ArrayIndexOutOfBoundsException extends IndexOutOfBoundsException
    REG_EXCEPTION(aioob_cls, "Ljava/lang/ArrayIndexOutOfBoundsException;", ioob_cls);

    // java.lang.ArithmeticException extends RuntimeException
    REG_EXCEPTION(arith_cls, "Ljava/lang/ArithmeticException;", rte_cls);

    // java.lang.NumberFormatException extends IllegalArgumentException
    REG_EXCEPTION(nfe_cls, "Ljava/lang/NumberFormatException;", iae_cls);

    // java.lang.ClassNotFoundException extends Exception
    REG_EXCEPTION(cnfe_cls, "Ljava/lang/ClassNotFoundException;", exception_cls);

    // java.lang.NoSuchMethodException extends Exception
    REG_EXCEPTION(nsme_cls, "Ljava/lang/NoSuchMethodException;", exception_cls);

    #undef REG_EXCEPTION

    // java.lang.StackTraceElement
    DxClass *ste_cls = create_class(vm, "Ljava/lang/StackTraceElement;", obj_cls, true);
    add_native_method(ste_cls, "getClassName", "L", DX_ACC_PUBLIC,
                      native_ste_getclassname, false);
    add_native_method(ste_cls, "getMethodName", "L", DX_ACC_PUBLIC,
                      native_ste_getmethodname, false);
    add_native_method(ste_cls, "toString", "L", DX_ACC_PUBLIC,
                      native_ste_getclassname, false);
    ste_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Class
    DxClass *class_cls = create_class(vm, "Ljava/lang/Class;", obj_cls, true);
    add_native_method(class_cls, "getName", "L", DX_ACC_PUBLIC,
                      native_class_getname, false);
    add_native_method(class_cls, "getSimpleName", "L", DX_ACC_PUBLIC,
                      native_class_getsimplename, false);
    add_native_method(class_cls, "getCanonicalName", "L", DX_ACC_PUBLIC,
                      native_class_getname, false);
    add_native_method(class_cls, "forName", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_class_forname, true);
    add_native_method(class_cls, "forName", "LLZL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_class_forname, true);  // 3-arg variant
    add_native_method(class_cls, "isAssignableFrom", "ZL", DX_ACC_PUBLIC,
                      native_class_isassignablefrom, false);
    // Real annotation support
    add_native_method(class_cls, "getAnnotation", "LL", DX_ACC_PUBLIC,
                      native_class_getannotation, false);
    add_native_method(class_cls, "getAnnotations", "L", DX_ACC_PUBLIC,
                      native_class_getannotations, false);
    add_native_method(class_cls, "getDeclaredAnnotations", "L", DX_ACC_PUBLIC,
                      native_class_getannotations, false);
    add_native_method(class_cls, "isAnnotationPresent", "ZL", DX_ACC_PUBLIC,
                      native_class_isannotationpresent, false);
    add_native_method(class_cls, "getInterfaces", "L", DX_ACC_PUBLIC,
                      native_return_null_vm, false);
    // getDeclaredMethods / getDeclaredFields (real implementations)
    add_native_method(class_cls, "getDeclaredMethods", "L", DX_ACC_PUBLIC,
                      native_class_getdeclaredmethods, false);
    add_native_method(class_cls, "getDeclaredFields", "L", DX_ACC_PUBLIC,
                      native_class_getdeclaredfields, false);
    add_native_method(class_cls, "getMethods", "L", DX_ACC_PUBLIC,
                      native_class_getdeclaredmethods, false);
    add_native_method(class_cls, "getFields", "L", DX_ACC_PUBLIC,
                      native_class_getdeclaredfields, false);
    // Constructor access
    add_native_method(class_cls, "getConstructor", "LL", DX_ACC_PUBLIC,
                      native_class_getconstructor, false);
    add_native_method(class_cls, "getDeclaredConstructor", "LL", DX_ACC_PUBLIC,
                      native_class_getconstructor, false);
    add_native_method(class_cls, "getConstructors", "L", DX_ACC_PUBLIC,
                      native_return_null_vm, false);
    add_native_method(class_cls, "getDeclaredConstructors", "L", DX_ACC_PUBLIC,
                      native_return_null_vm, false);
    add_native_method(class_cls, "isInterface", "Z", DX_ACC_PUBLIC,
                      native_class_isinterface, false);
    add_native_method(class_cls, "getSuperclass", "L", DX_ACC_PUBLIC,
                      native_class_getsuperclass, false);
    add_native_method(class_cls, "isArray", "Z", DX_ACC_PUBLIC,
                      native_class_isarray, false);
    class_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.reflect.Constructor
    DxClass *ctor_cls = create_class(vm, "Ljava/lang/reflect/Constructor;", obj_cls, true);
    ctor_cls->instance_field_count = 2;  // field[0] = DxMethod* (as int), field[1] = DxClass* (as int)
    add_native_method(ctor_cls, "newInstance", "LL", DX_ACC_PUBLIC,
                      native_constructor_newinstance, false);
    add_native_method(ctor_cls, "setAccessible", "VZ", DX_ACC_PUBLIC,
                      native_object_init, false);
    add_native_method(ctor_cls, "getParameterTypes", "L", DX_ACC_PUBLIC,
                      native_return_null_vm, false);
    add_native_method(ctor_cls, "getModifiers", "I", DX_ACC_PUBLIC,
                      native_return_false_vm, false);
    ctor_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.reflect.Array
    DxClass *array_cls = create_class(vm, "Ljava/lang/reflect/Array;", obj_cls, true);
    add_native_method(array_cls, "newInstance", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_array_newinstance, true);
    add_native_method(array_cls, "getLength", "IL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_array_getlength, true);
    add_native_method(array_cls, "get", "LLI", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_array_get, true);
    add_native_method(array_cls, "set", "VLIL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_array_set, true);
    array_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.reflect.InvocationHandler (interface)
    DxClass *invhandler_cls = create_class(vm, "Ljava/lang/reflect/InvocationHandler;", obj_cls, true);
    invhandler_cls->access_flags = DX_ACC_PUBLIC | DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_native_method(invhandler_cls, "invoke", "LLLL", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
                      native_return_null_vm, false);
    invhandler_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.reflect.Proxy
    DxClass *proxy_cls = create_class(vm, "Ljava/lang/reflect/Proxy;", obj_cls, true);
    add_native_method(proxy_cls, "newProxyInstance", "LLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_proxy_newproxyinstance, true);
    add_native_method(proxy_cls, "getInvocationHandler", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_proxy_getinvocationhandler, true);
    proxy_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.System
    DxClass *sys_cls = create_class(vm, "Ljava/lang/System;", obj_cls, true);
    add_native_method(sys_cls, "currentTimeMillis", "J", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_system_currenttimemillis, true);
    add_native_method(sys_cls, "arraycopy", "VLILII", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_system_arraycopy, true);
    add_native_method(sys_cls, "getProperties", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_init, true);  // returns a stub object
    add_native_method(sys_cls, "loadLibrary", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_system_loadlibrary, true);
    sys_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Math
    DxClass *math_cls = create_class(vm, "Ljava/lang/Math;", obj_cls, true);
    math_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Number (abstract parent of Integer, Long, Float, Double)
    DxClass *number_cls = create_class(vm, "Ljava/lang/Number;", obj_cls, true);
    add_native_method(number_cls, "intValue", "I", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
                      native_object_hashcode, false);
    add_native_method(number_cls, "longValue", "J", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
                      native_object_hashcode, false);
    add_native_method(number_cls, "floatValue", "F", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
                      native_object_hashcode, false);
    add_native_method(number_cls, "doubleValue", "D", DX_ACC_PUBLIC | DX_ACC_ABSTRACT,
                      native_object_hashcode, false);
    number_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Integer extends Number
    DxClass *int_cls = create_class(vm, "Ljava/lang/Integer;", number_cls, true);
    add_native_method(int_cls, "valueOf", "LI", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_init, true);
    add_native_method(int_cls, "intValue", "I", DX_ACC_PUBLIC,
                      native_object_hashcode, false);
    int_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Long extends Number
    DxClass *long_cls = create_class(vm, "Ljava/lang/Long;", number_cls, true);
    add_native_method(long_cls, "valueOf", "LJ", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_init, true);
    long_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Float extends Number
    DxClass *float_cls = create_class(vm, "Ljava/lang/Float;", number_cls, true);
    add_native_method(float_cls, "valueOf", "LF", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_init, true);
    float_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Double extends Number
    DxClass *double_cls = create_class(vm, "Ljava/lang/Double;", number_cls, true);
    add_native_method(double_cls, "valueOf", "LD", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_init, true);
    double_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Boolean
    DxClass *bool_cls = create_class(vm, "Ljava/lang/Boolean;", obj_cls, true);
    add_native_method(bool_cls, "valueOf", "LZ", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_init, true);  // returns null, absorbed
    add_native_method(bool_cls, "booleanValue", "Z", DX_ACC_PUBLIC,
                      native_object_hashcode, false);  // returns 0
    bool_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Byte extends Number
    create_class(vm, "Ljava/lang/Byte;", number_cls, true)->status = DX_CLASS_INITIALIZED;

    // java.lang.Short extends Number
    create_class(vm, "Ljava/lang/Short;", number_cls, true)->status = DX_CLASS_INITIALIZED;

    // java.lang.Character
    create_class(vm, "Ljava/lang/Character;", obj_cls, true)->status = DX_CLASS_INITIALIZED;

    // java.lang.Void
    create_class(vm, "Ljava/lang/Void;", obj_cls, true)->status = DX_CLASS_INITIALIZED;

    // java.lang.Enum
    DxClass *enum_cls = create_class(vm, "Ljava/lang/Enum;", obj_cls, true);
    add_native_method(enum_cls, "name", "L", DX_ACC_PUBLIC,
                      native_enum_name, false);
    add_native_method(enum_cls, "ordinal", "I", DX_ACC_PUBLIC,
                      native_enum_ordinal, false);
    add_native_method(enum_cls, "values", "[L", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_enum_values, true);
    add_native_method(enum_cls, "valueOf", "LL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_enum_valueof, true);
    add_native_method(enum_cls, "toString", "L", DX_ACC_PUBLIC,
                      native_enum_name, false);  // toString() returns name() for enums
    add_native_method(enum_cls, "compareTo", "IL", DX_ACC_PUBLIC,
                      native_enum_compareto, false);
    enum_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Iterable (interface) - for-each loops compile to Iterable.iterator()
    DxClass *iterable_cls = create_class(vm, "Ljava/lang/Iterable;", obj_cls, true);
    iterable_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_native_method(iterable_cls, "iterator", "L", DX_ACC_PUBLIC,
                      native_arraylist_iterator, false);  // default iterator()
    iterable_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Runnable (interface)
    DxClass *runnable_cls = create_class(vm, "Ljava/lang/Runnable;", obj_cls, true);
    runnable_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    runnable_cls->status = DX_CLASS_INITIALIZED;

    // java.lang.Thread
    DxClass *thread_cls = create_class(vm, "Ljava/lang/Thread;", obj_cls, true);
    add_native_method(thread_cls, "start", "V", DX_ACC_PUBLIC,
                      native_thread_start, false);  // synchronous run()
    add_native_method(thread_cls, "join", "V", DX_ACC_PUBLIC,
                      native_object_init, false);  // no-op (already finished)
    add_native_method(thread_cls, "join", "VJ", DX_ACC_PUBLIC,
                      native_object_init, false);  // no-op with timeout
    add_native_method(thread_cls, "isAlive", "Z", DX_ACC_PUBLIC,
                      native_thread_isalive, false);  // always false
    add_native_method(thread_cls, "setDaemon", "VZ", DX_ACC_PUBLIC,
                      native_object_init, false);  // no-op
    add_native_method(thread_cls, "currentThread", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_init, true);  // returns null, absorbed
    add_native_method(thread_cls, "getId", "J", DX_ACC_PUBLIC,
                      native_system_currenttimemillis, false);  // returns 0L
    add_native_method(thread_cls, "getName", "L", DX_ACC_PUBLIC,
                      native_object_init, false);
    thread_cls->status = DX_CLASS_INITIALIZED;

    // java.io.PrintStream (for System.out.println)
    DxClass *ps_cls = create_class(vm, "Ljava/io/PrintStream;", obj_cls, true);
    add_native_method(ps_cls, "println", "VL", DX_ACC_PUBLIC, native_println, false);
    add_native_method(ps_cls, "print", "VL", DX_ACC_PUBLIC, native_println, false);
    ps_cls->status = DX_CLASS_INITIALIZED;

    // java.io.Serializable (interface)
    DxClass *serial_cls = create_class(vm, "Ljava/io/Serializable;", obj_cls, true);
    serial_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    serial_cls->status = DX_CLASS_INITIALIZED;

    // java.util common interfaces
    // Collection extends Iterable
    DxClass *collection_iface = create_class(vm, "Ljava/util/Collection;", obj_cls, true);
    collection_iface->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    collection_iface->interface_count = 1;
    collection_iface->interfaces = (const char **)dx_malloc(sizeof(const char *) * 1);
    if (collection_iface->interfaces) {
        collection_iface->interfaces[0] = "Ljava/lang/Iterable;";
    }
    collection_iface->status = DX_CLASS_INITIALIZED;

    // List extends Collection (and transitively Iterable)
    DxClass *list_iface = create_class(vm, "Ljava/util/List;", obj_cls, true);
    list_iface->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    list_iface->interface_count = 2;
    list_iface->interfaces = (const char **)dx_malloc(sizeof(const char *) * 2);
    if (list_iface->interfaces) {
        list_iface->interfaces[0] = "Ljava/util/Collection;";
        list_iface->interfaces[1] = "Ljava/lang/Iterable;";
    }
    list_iface->status = DX_CLASS_INITIALIZED;

    // Map (does not extend Collection)
    DxClass *map_iface = create_class(vm, "Ljava/util/Map;", obj_cls, true);
    map_iface->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    map_iface->status = DX_CLASS_INITIALIZED;

    // Set extends Collection (and transitively Iterable)
    DxClass *set_cls = create_class(vm, "Ljava/util/Set;", obj_cls, true);
    set_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    set_cls->interface_count = 2;
    set_cls->interfaces = (const char **)dx_malloc(sizeof(const char *) * 2);
    if (set_cls->interfaces) {
        set_cls->interfaces[0] = "Ljava/util/Collection;";
        set_cls->interfaces[1] = "Ljava/lang/Iterable;";
    }
    add_native_method(set_cls, "iterator", "L", DX_ACC_PUBLIC,
                      native_arraylist_iterator, false);  // returns empty iterator
    add_native_method(set_cls, "size", "I", DX_ACC_PUBLIC,
                      native_object_init, false);  // returns 0
    add_native_method(set_cls, "isEmpty", "Z", DX_ACC_PUBLIC,
                      native_object_init, false);  // returns false (0)
    set_cls->status = DX_CLASS_INITIALIZED;

    DxClass *iter_cls = create_class(vm, "Ljava/util/Iterator;", obj_cls, true);
    iter_cls->access_flags = DX_ACC_INTERFACE | DX_ACC_ABSTRACT;
    add_native_method(iter_cls, "hasNext", "Z", DX_ACC_PUBLIC,
                      native_object_init, false);  // returns 0 (false) - empty iterator
    add_native_method(iter_cls, "next", "L", DX_ACC_PUBLIC,
                      native_object_init, false);  // returns null
    iter_cls->status = DX_CLASS_INITIALIZED;

    create_class(vm, "Ljava/util/Collections;", obj_cls, true)->status = DX_CLASS_INITIALIZED;
    create_class(vm, "Ljava/util/Arrays;", obj_cls, true)->status = DX_CLASS_INITIALIZED;

    // java.util.ArrayList with actual storage
    DxClass *arraylist_cls = create_class(vm, "Ljava/util/ArrayList;", obj_cls, true);
    vm->class_arraylist = arraylist_cls;
    arraylist_cls->instance_field_count = 2;
    arraylist_cls->field_defs = (typeof(arraylist_cls->field_defs))dx_malloc(sizeof(*arraylist_cls->field_defs) * 2);
    if (arraylist_cls->field_defs) {
        arraylist_cls->field_defs[0].name = "_items";
        arraylist_cls->field_defs[0].type = "Ljava/lang/Object;";
        arraylist_cls->field_defs[0].flags = DX_ACC_PRIVATE;
        arraylist_cls->field_defs[1].name = "_size";
        arraylist_cls->field_defs[1].type = "I";
        arraylist_cls->field_defs[1].flags = DX_ACC_PRIVATE;
    }
    add_native_method(arraylist_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_arraylist_init, true);
    add_native_method(arraylist_cls, "add", "ZL", DX_ACC_PUBLIC,
                      native_arraylist_add, false);
    add_native_method(arraylist_cls, "add", "VIL", DX_ACC_PUBLIC,
                      native_arraylist_add_at, false);
    add_native_method(arraylist_cls, "get", "LI", DX_ACC_PUBLIC,
                      native_arraylist_get, false);
    add_native_method(arraylist_cls, "set", "LIL", DX_ACC_PUBLIC,
                      native_arraylist_set, false);
    add_native_method(arraylist_cls, "remove", "LI", DX_ACC_PUBLIC,
                      native_arraylist_remove, false);
    add_native_method(arraylist_cls, "size", "I", DX_ACC_PUBLIC,
                      native_arraylist_size, false);
    add_native_method(arraylist_cls, "isEmpty", "Z", DX_ACC_PUBLIC,
                      native_arraylist_isempty, false);
    add_native_method(arraylist_cls, "contains", "ZL", DX_ACC_PUBLIC,
                      native_arraylist_contains, false);
    add_native_method(arraylist_cls, "clear", "V", DX_ACC_PUBLIC,
                      native_arraylist_clear, false);
    add_native_method(arraylist_cls, "indexOf", "IL", DX_ACC_PUBLIC,
                      native_arraylist_indexof, false);
    add_native_method(arraylist_cls, "iterator", "L", DX_ACC_PUBLIC,
                      native_arraylist_iterator, false);
    add_native_method(arraylist_cls, "toArray", "L", DX_ACC_PUBLIC,
                      native_arraylist_toarray, false);
    // ArrayList implements List, Collection, Iterable
    arraylist_cls->interface_count = 3;
    arraylist_cls->interfaces = (const char **)dx_malloc(sizeof(const char *) * 3);
    if (arraylist_cls->interfaces) {
        arraylist_cls->interfaces[0] = "Ljava/util/List;";
        arraylist_cls->interfaces[1] = "Ljava/util/Collection;";
        arraylist_cls->interfaces[2] = "Ljava/lang/Iterable;";
    }
    arraylist_cls->status = DX_CLASS_INITIALIZED;

    // java.util.HashMap with actual storage
    DxClass *hashmap_cls = create_class(vm, "Ljava/util/HashMap;", obj_cls, true);
    vm->class_hashmap = hashmap_cls;
    hashmap_cls->instance_field_count = 3;
    hashmap_cls->field_defs = (typeof(hashmap_cls->field_defs))dx_malloc(sizeof(*hashmap_cls->field_defs) * 3);
    if (hashmap_cls->field_defs) {
        hashmap_cls->field_defs[0].name = "_keys";
        hashmap_cls->field_defs[0].type = "Ljava/lang/Object;";
        hashmap_cls->field_defs[0].flags = DX_ACC_PRIVATE;
        hashmap_cls->field_defs[1].name = "_vals";
        hashmap_cls->field_defs[1].type = "Ljava/lang/Object;";
        hashmap_cls->field_defs[1].flags = DX_ACC_PRIVATE;
        hashmap_cls->field_defs[2].name = "_size";
        hashmap_cls->field_defs[2].type = "I";
        hashmap_cls->field_defs[2].flags = DX_ACC_PRIVATE;
    }
    add_native_method(hashmap_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_hashmap_init, true);
    add_native_method(hashmap_cls, "put", "LLL", DX_ACC_PUBLIC,
                      native_hashmap_put, false);
    add_native_method(hashmap_cls, "get", "LL", DX_ACC_PUBLIC,
                      native_hashmap_get, false);
    add_native_method(hashmap_cls, "containsKey", "ZL", DX_ACC_PUBLIC,
                      native_hashmap_containskey, false);
    add_native_method(hashmap_cls, "remove", "LL", DX_ACC_PUBLIC,
                      native_hashmap_remove, false);
    add_native_method(hashmap_cls, "size", "I", DX_ACC_PUBLIC,
                      native_hashmap_size, false);
    add_native_method(hashmap_cls, "isEmpty", "Z", DX_ACC_PUBLIC,
                      native_hashmap_isempty, false);
    add_native_method(hashmap_cls, "keySet", "L", DX_ACC_PUBLIC,
                      native_hashmap_keyset, false);
    add_native_method(hashmap_cls, "values", "L", DX_ACC_PUBLIC,
                      native_hashmap_values, false);
    add_native_method(hashmap_cls, "clear", "V", DX_ACC_PUBLIC,
                      native_hashmap_clear, false);
    add_native_method(hashmap_cls, "entrySet", "L", DX_ACC_PUBLIC,
                      native_hashmap_entryset, false);
    add_native_method(hashmap_cls, "containsValue", "ZL", DX_ACC_PUBLIC,
                      native_hashmap_containsvalue, false);
    add_native_method(hashmap_cls, "putAll", "VL", DX_ACC_PUBLIC,
                      native_hashmap_putall, false);
    add_native_method(hashmap_cls, "getOrDefault", "LLL", DX_ACC_PUBLIC,
                      native_hashmap_getordefault, false);
    add_native_method(hashmap_cls, "putIfAbsent", "LLL", DX_ACC_PUBLIC,
                      native_hashmap_putifabsent, false);
    add_native_method(hashmap_cls, "toString", "L", DX_ACC_PUBLIC,
                      native_hashmap_tostring, false);
    // HashMap implements Map
    hashmap_cls->interface_count = 1;
    hashmap_cls->interfaces = (const char **)dx_malloc(sizeof(const char *) * 1);
    if (hashmap_cls->interfaces) {
        hashmap_cls->interfaces[0] = "Ljava/util/Map;";
    }
    hashmap_cls->status = DX_CLASS_INITIALIZED;

    // --- java.util.concurrent stubs ---
    // Prevent infinite init loops in RxJava/reactive libraries

    DxClass *atomic_long_cls = create_class(vm, "Ljava/util/concurrent/atomic/AtomicLong;", obj_cls, true);
    atomic_long_cls->instance_field_count = 1;
    atomic_long_cls->field_defs = (typeof(atomic_long_cls->field_defs))dx_malloc(sizeof(*atomic_long_cls->field_defs));
    if (atomic_long_cls->field_defs) {
        atomic_long_cls->field_defs[0].name = "value";
        atomic_long_cls->field_defs[0].type = "J";
        atomic_long_cls->field_defs[0].flags = DX_ACC_PRIVATE;
    }
    add_native_method(atomic_long_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(atomic_long_cls, "<init>", "VJ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(atomic_long_cls, "get", "J", DX_ACC_PUBLIC,
                      native_object_hashcode, false);  // returns 0
    add_native_method(atomic_long_cls, "set", "VJ", DX_ACC_PUBLIC,
                      native_object_init, false);  // no-op
    add_native_method(atomic_long_cls, "incrementAndGet", "J", DX_ACC_PUBLIC,
                      native_object_hashcode, false);
    add_native_method(atomic_long_cls, "getAndIncrement", "J", DX_ACC_PUBLIC,
                      native_object_hashcode, false);
    atomic_long_cls->status = DX_CLASS_INITIALIZED;

    DxClass *atomic_int_cls = create_class(vm, "Ljava/util/concurrent/atomic/AtomicInteger;", obj_cls, true);
    atomic_int_cls->instance_field_count = 1;
    atomic_int_cls->field_defs = (typeof(atomic_int_cls->field_defs))dx_malloc(sizeof(*atomic_int_cls->field_defs));
    if (atomic_int_cls->field_defs) {
        atomic_int_cls->field_defs[0].name = "value";
        atomic_int_cls->field_defs[0].type = "I";
        atomic_int_cls->field_defs[0].flags = DX_ACC_PRIVATE;
    }
    add_native_method(atomic_int_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(atomic_int_cls, "<init>", "VI", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(atomic_int_cls, "get", "I", DX_ACC_PUBLIC,
                      native_object_hashcode, false);
    add_native_method(atomic_int_cls, "set", "VI", DX_ACC_PUBLIC,
                      native_object_init, false);
    atomic_int_cls->status = DX_CLASS_INITIALIZED;

    DxClass *atomic_bool_cls = create_class(vm, "Ljava/util/concurrent/atomic/AtomicBoolean;", obj_cls, true);
    add_native_method(atomic_bool_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(atomic_bool_cls, "<init>", "VZ", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    atomic_bool_cls->status = DX_CLASS_INITIALIZED;

    DxClass *atomic_ref_cls = create_class(vm, "Ljava/util/concurrent/atomic/AtomicReference;", obj_cls, true);
    atomic_ref_cls->instance_field_count = 1;
    atomic_ref_cls->field_defs = (typeof(atomic_ref_cls->field_defs))dx_malloc(sizeof(*atomic_ref_cls->field_defs));
    if (atomic_ref_cls->field_defs) {
        atomic_ref_cls->field_defs[0].name = "value";
        atomic_ref_cls->field_defs[0].type = "Ljava/lang/Object;";
        atomic_ref_cls->field_defs[0].flags = DX_ACC_PRIVATE;
    }
    add_native_method(atomic_ref_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(atomic_ref_cls, "<init>", "VL", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(atomic_ref_cls, "get", "L", DX_ACC_PUBLIC,
                      native_object_init, false);  // returns null
    add_native_method(atomic_ref_cls, "set", "VL", DX_ACC_PUBLIC,
                      native_object_init, false);
    add_native_method(atomic_ref_cls, "compareAndSet", "ZLL", DX_ACC_PUBLIC,
                      native_object_init, false);  // returns false (0)
    add_native_method(atomic_ref_cls, "getAndSet", "LL", DX_ACC_PUBLIC,
                      native_object_init, false);
    atomic_ref_cls->status = DX_CLASS_INITIALIZED;

    // ConcurrentLinkedQueue - stub as ArrayList
    DxClass *clq_cls = create_class(vm, "Ljava/util/concurrent/ConcurrentLinkedQueue;", arraylist_cls, true);
    add_native_method(clq_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_arraylist_init, true);
    clq_cls->status = DX_CLASS_INITIALIZED;

    // ConcurrentHashMap - stub as HashMap
    DxClass *chm_cls = create_class(vm, "Ljava/util/concurrent/ConcurrentHashMap;", hashmap_cls, true);
    add_native_method(chm_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_hashmap_init, true);
    chm_cls->status = DX_CLASS_INITIALIZED;

    // CopyOnWriteArrayList - stub as ArrayList
    DxClass *cowal_cls = create_class(vm, "Ljava/util/concurrent/CopyOnWriteArrayList;", arraylist_cls, true);
    add_native_method(cowal_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_arraylist_init, true);
    cowal_cls->status = DX_CLASS_INITIALIZED;

    // java.util.Properties - stub as HashMap
    DxClass *props_cls = create_class(vm, "Ljava/util/Properties;", hashmap_cls, true);
    add_native_method(props_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_hashmap_init, true);
    add_native_method(props_cls, "getProperty", "LL", DX_ACC_PUBLIC,
                      native_hashmap_get, false);
    add_native_method(props_cls, "setProperty", "LLL", DX_ACC_PUBLIC,
                      native_hashmap_put, false);
    add_native_method(props_cls, "clone", "L", DX_ACC_PUBLIC,
                      native_object_init, false);
    props_cls->status = DX_CLASS_INITIALIZED;

    // java.util.Locale
    DxClass *locale_cls = create_class(vm, "Ljava/util/Locale;", obj_cls, true);
    add_native_method(locale_cls, "<init>", "V", DX_ACC_PUBLIC | DX_ACC_CONSTRUCTOR,
                      native_object_init, true);
    add_native_method(locale_cls, "getDefault", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_init, true);
    add_native_method(locale_cls, "getLanguage", "L", DX_ACC_PUBLIC,
                      native_object_tostring, false);
    add_native_method(locale_cls, "getCountry", "L", DX_ACC_PUBLIC,
                      native_object_tostring, false);
    locale_cls->status = DX_CLASS_INITIALIZED;

    // java.util.UUID
    DxClass *uuid_cls = create_class(vm, "Ljava/util/UUID;", obj_cls, true);
    add_native_method(uuid_cls, "randomUUID", "L", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_init, true);
    add_native_method(uuid_cls, "toString", "L", DX_ACC_PUBLIC,
                      native_object_tostring, false);
    uuid_cls->status = DX_CLASS_INITIALIZED;

    // --- Kotlin runtime stubs ---
    // These prevent the Kotlin runtime from burning instructions in intrinsics loops

    DxClass *kt_intrinsics = create_class(vm, "Lkotlin/jvm/internal/Intrinsics;", obj_cls, true);
    add_native_method(kt_intrinsics, "checkNotNullParameter", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_check_not_null, true);
    add_native_method(kt_intrinsics, "checkParameterIsNotNull", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_check_not_null, true);
    add_native_method(kt_intrinsics, "checkNotNullExpressionValue", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_check_not_null, true);
    add_native_method(kt_intrinsics, "checkExpressionValueIsNotNull", "VLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_check_not_null, true);
    add_native_method(kt_intrinsics, "checkNotNull", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_check_not_null, true);
    add_native_method(kt_intrinsics, "checkReturnedValueIsNotNull", "VLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_noop, true);
    add_native_method(kt_intrinsics, "checkFieldIsNotNull", "VLLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_noop, true);
    add_native_method(kt_intrinsics, "throwUninitializedPropertyAccessException", "VL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_noop, true);
    add_native_method(kt_intrinsics, "areEqual", "ZLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_object_equals, true);
    add_native_method(kt_intrinsics, "stringPlus", "LLL", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_noop, true);
    add_native_method(kt_intrinsics, "createParameterIsNullExceptionMessage", "LL", DX_ACC_PRIVATE | DX_ACC_STATIC,
                      native_kotlin_noop, true);
    add_native_method(kt_intrinsics, "throwParameterIsNullNPE", "VL", DX_ACC_PRIVATE | DX_ACC_STATIC,
                      native_kotlin_noop, true);
    add_native_method(kt_intrinsics, "sanitizeStackTrace", "LL", DX_ACC_PRIVATE | DX_ACC_STATIC,
                      native_kotlin_noop, true);
    add_native_method(kt_intrinsics, "throwNpe", "V", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_noop, true);
    add_native_method(kt_intrinsics, "throwJavaNpe", "V", DX_ACC_PUBLIC | DX_ACC_STATIC,
                      native_kotlin_noop, true);
    kt_intrinsics->status = DX_CLASS_INITIALIZED;

    // kotlin.Unit
    create_class(vm, "Lkotlin/Unit;", obj_cls, true)->status = DX_CLASS_INITIALIZED;

    // kotlin.collections.CollectionsKt
    create_class(vm, "Lkotlin/collections/CollectionsKt;", obj_cls, true)->status = DX_CLASS_INITIALIZED;

    // kotlin.jvm.internal.DefaultConstructorMarker
    create_class(vm, "Lkotlin/jvm/internal/DefaultConstructorMarker;", obj_cls, true)->status = DX_CLASS_INITIALIZED;

    // kotlin.jvm.functions
    create_class(vm, "Lkotlin/jvm/functions/Function0;", obj_cls, true)->status = DX_CLASS_INITIALIZED;
    create_class(vm, "Lkotlin/jvm/functions/Function1;", obj_cls, true)->status = DX_CLASS_INITIALIZED;

    DX_INFO(TAG, "Registered java.lang + kotlin runtime classes");
    return DX_OK;
}

DxClass *dx_vm_find_class(DxVM *vm, const char *descriptor) {
    if (!vm || !descriptor) return NULL;
    uint32_t idx = class_hash_fn(descriptor);
    for (uint32_t i = 0; i < DX_CLASS_HASH_SIZE; i++) {
        uint32_t slot = (idx + i) & (DX_CLASS_HASH_SIZE - 1);
        if (!vm->class_hash[slot].descriptor) return NULL;
        if (strcmp(vm->class_hash[slot].descriptor, descriptor) == 0)
            return vm->class_hash[slot].cls;
    }
    return NULL;
}

// ─── Class unloading (for hot-reload or memory pressure) ───

DxResult dx_vm_unload_class(DxVM *vm, const char *descriptor) {
    if (!vm || !descriptor) return DX_ERR_NULL_PTR;

    // Find the class in the hash table
    DxClass *cls = dx_vm_find_class(vm, descriptor);
    if (!cls) {
        DX_WARN(TAG, "Cannot unload class '%s': not found", descriptor);
        return DX_ERR_CLASS_NOT_FOUND;
    }

    // Warn if any live heap objects are instances of this class
    for (uint32_t i = 0; i < vm->heap_count; i++) {
        if (vm->heap[i] && vm->heap[i]->klass == cls) {
            DX_WARN(TAG, "Unloading class '%s' that still has live instances on the heap", descriptor);
            break;
        }
    }

    // 1. Remove from hash table (open-addressing with tombstone rehash)
    uint32_t idx = 0;
    {
        // Find the slot
        uint32_t h = 2166136261u;
        for (const char *s = descriptor; *s; s++) {
            h ^= (uint8_t)*s;
            h *= 16777619u;
        }
        h &= (DX_CLASS_HASH_SIZE - 1);

        bool found = false;
        for (uint32_t i = 0; i < DX_CLASS_HASH_SIZE; i++) {
            uint32_t slot = (h + i) & (DX_CLASS_HASH_SIZE - 1);
            if (!vm->class_hash[slot].descriptor) break;
            if (strcmp(vm->class_hash[slot].descriptor, descriptor) == 0) {
                idx = slot;
                found = true;
                break;
            }
        }
        if (!found) return DX_ERR_CLASS_NOT_FOUND;

        // Clear the slot
        vm->class_hash[idx].descriptor = NULL;
        vm->class_hash[idx].cls = NULL;

        // Rehash subsequent entries in the cluster to fill the gap
        uint32_t hole = idx;
        for (uint32_t i = 1; i < DX_CLASS_HASH_SIZE; i++) {
            uint32_t next = (idx + i) & (DX_CLASS_HASH_SIZE - 1);
            if (!vm->class_hash[next].descriptor) break;

            // Compute the natural slot for this entry
            uint32_t nh = 2166136261u;
            for (const char *s = vm->class_hash[next].descriptor; *s; s++) {
                nh ^= (uint8_t)*s;
                nh *= 16777619u;
            }
            nh &= (DX_CLASS_HASH_SIZE - 1);

            // Check if this entry needs to be moved (its natural position is at or before the hole)
            // Using the "does the hole lie between the natural slot and the current slot" test
            bool needs_move = false;
            if (hole < next) {
                needs_move = (nh <= hole || nh > next);
            } else {
                needs_move = (nh <= hole && nh > next);
            }

            if (needs_move) {
                vm->class_hash[hole] = vm->class_hash[next];
                vm->class_hash[next].descriptor = NULL;
                vm->class_hash[next].cls = NULL;
                hole = next;
            }
        }
    }

    // 2. Remove from vm->classes[] linear array
    for (uint32_t i = 0; i < vm->class_count; i++) {
        if (vm->classes[i] == cls) {
            // Shift remaining entries down
            for (uint32_t j = i; j < vm->class_count - 1; j++) {
                vm->classes[j] = vm->classes[j + 1];
            }
            vm->classes[vm->class_count - 1] = NULL;
            vm->class_count--;
            break;
        }
    }

    // 3. Free class memory
    // Free method annotations, ic_tables, and code items
    for (uint32_t m = 0; m < cls->direct_method_count; m++) {
        dx_free(cls->direct_methods[m].annotations);
        dx_free(cls->direct_methods[m].ic_table);
        dx_dex_free_code_item(&cls->direct_methods[m].code);
    }
    for (uint32_t m = 0; m < cls->virtual_method_count; m++) {
        dx_free(cls->virtual_methods[m].annotations);
        dx_free(cls->virtual_methods[m].ic_table);
        dx_dex_free_code_item(&cls->virtual_methods[m].code);
    }
    dx_free(cls->field_defs);
    dx_free(cls->static_fields);
    dx_free(cls->direct_methods);
    dx_free(cls->virtual_methods);
    dx_free(cls->vtable);
    if (cls->itable) {
        for (int it = 0; it < cls->itable_count; it++) {
            dx_free(cls->itable[it].methods);
        }
        dx_free(cls->itable);
    }
    dx_free(cls->interfaces);
    dx_free(cls->annotations);

    DX_INFO(TAG, "Unloaded class: %s", descriptor);
    dx_free(cls);

    return DX_OK;
}

const DxAnnotationEntry *dx_class_get_annotation(DxClass *cls, const char *type_desc) {
    if (!cls || !type_desc || !cls->annotations) return NULL;
    for (uint32_t i = 0; i < cls->annotation_count; i++) {
        if (cls->annotations[i].type && strcmp(cls->annotations[i].type, type_desc) == 0) {
            return &cls->annotations[i];
        }
    }
    return NULL;
}

const DxAnnotationEntry *dx_method_get_annotation(DxMethod *method, const char *type_desc) {
    if (!method || !type_desc || !method->annotations) return NULL;
    for (uint32_t i = 0; i < method->annotation_count; i++) {
        if (method->annotations[i].type && strcmp(method->annotations[i].type, type_desc) == 0) {
            return &method->annotations[i];
        }
    }
    return NULL;
}

DxResult dx_vm_load_class(DxVM *vm, const char *descriptor, DxClass **out) {
    if (!vm || !descriptor) return DX_ERR_NULL_PTR;

    // Check if already loaded
    DxClass *cls = dx_vm_find_class(vm, descriptor);
    if (cls) {
        if (out) *out = cls;
        return DX_OK;
    }

    // Recursion guard: check if this class is currently being loaded
    // (prevents infinite recursion from circular superclass chains)
    static __thread const char *loading_stack[64];
    static __thread int loading_depth = 0;
    for (int k = 0; k < loading_depth; k++) {
        if (strcmp(loading_stack[k], descriptor) == 0) {
            DX_WARN(TAG, "Circular class loading detected for %s, using Object", descriptor);
            if (out) *out = vm->class_object;
            return DX_OK;
        }
    }
    if (loading_depth < 64) {
        loading_stack[loading_depth++] = descriptor;
    }

    // Look up across all loaded DEX files
    if (vm->dex_count == 0) {
        DX_ERROR(TAG, "No DEX loaded, cannot find class %s", descriptor);
        loading_depth--;
        return DX_ERR_CLASS_NOT_FOUND;
    }

    // Search all DEX files for exact match, detecting conflicts
    DxDexFile *found_dex = NULL;
    int32_t found_idx = -1;
    uint32_t found_dex_idx = 0;
    for (uint32_t d = 0; d < vm->dex_count; d++) {
        DxDexFile *dex = vm->dex_files[d];
        for (uint32_t i = 0; i < dex->class_count; i++) {
            const char *type = dx_dex_get_type(dex, dex->class_defs[i].class_idx);
            if (type && strcmp(type, descriptor) == 0) {
                if (found_idx < 0) {
                    // First occurrence wins
                    found_dex = dex;
                    found_idx = (int32_t)i;
                    found_dex_idx = d;
                } else {
                    // Conflict: same class in multiple DEX files
                    DX_WARN(TAG, "Class conflict: %s found in DEX %u and DEX %u",
                            descriptor, found_dex_idx, d);
                }
                break;
            }
        }
    }

    // If not found, try suffix match across all DEX files
    if (found_idx < 0) {
        const char *simple_name = strrchr(descriptor, '/');
        if (simple_name) {
            simple_name++;
            size_t slen = strlen(simple_name);
            if (slen > 1 && simple_name[slen - 1] == ';') slen--;
            for (uint32_t d = 0; d < vm->dex_count && found_idx < 0; d++) {
                DxDexFile *dex = vm->dex_files[d];
                for (uint32_t i = 0; i < dex->class_count; i++) {
                    const char *type = dx_dex_get_type(dex, dex->class_defs[i].class_idx);
                    if (!type) continue;
                    const char *t_simple = strrchr(type, '/');
                    if (t_simple) {
                        t_simple++;
                        if (strncmp(t_simple, simple_name, slen) == 0 &&
                            t_simple[slen] == ';') {
                            DX_INFO(TAG, "Class %s not found, using suffix match: %s", descriptor, type);
                            found_dex = dex;
                            found_idx = (int32_t)i;
                            break;
                        }
                    }
                }
            }
        }
    }

    // If still not found, log for debugging
    if (found_idx < 0) {
        uint32_t total = 0;
        for (uint32_t d = 0; d < vm->dex_count; d++) total += vm->dex_files[d]->class_count;
        DX_ERROR(TAG, "Class not found: %s (%u classes across %u DEX files)",
                descriptor, total, vm->dex_count);
        // Track as missing feature for diagnostics
        char feat_buf[160];
        snprintf(feat_buf, sizeof(feat_buf), "Class not found: %s", descriptor);
        dx_vm_report_missing_feature(vm, feat_buf);
        if (out) *out = NULL;
        loading_depth--;
        return DX_ERR_CLASS_NOT_FOUND;
    }

    // Check per-DEX class_def cache for O(1) hit on previously loaded class_def
    if (vm->class_def_cache[found_dex_idx] &&
        (uint32_t)found_idx < vm->class_def_cache_size[found_dex_idx] &&
        vm->class_def_cache[found_dex_idx][found_idx]) {
        cls = vm->class_def_cache[found_dex_idx][found_idx];
        if (out) *out = cls;
        loading_depth--;
        return DX_OK;
    }

    // Temporarily set vm->dex to the found DEX for parsing helpers
    DxDexFile *prev_dex = vm->dex;
    vm->dex = found_dex;

    {
        uint32_t i = (uint32_t)found_idx;
        const char *type = dx_dex_get_type(found_dex, found_dex->class_defs[i].class_idx);
        if (type) {
            // Found class def, load it
            DxResult res = dx_dex_parse_class_data(found_dex, i);
            if (res != DX_OK) { vm->dex = prev_dex; loading_depth--; return res; }

            // Load superclass first
            DxClass *super = NULL;
            uint32_t super_idx = found_dex->class_defs[i].superclass_idx;
            if (super_idx != 0xFFFFFFFF) {
                const char *super_desc = dx_dex_get_type(found_dex, super_idx);
                if (super_desc) {
                    // First check framework classes
                    super = dx_vm_find_class(vm, super_desc);
                    if (!super) {
                        // Try loading from DEX
                        dx_vm_load_class(vm, super_desc, &super);
                    }
                    if (!super) {
                        DX_WARN(TAG, "Superclass %s not found, defaulting to Object", super_desc);
                        super = vm->class_object;
                    }
                }
            }

            cls = create_class(vm, type, super ? super : vm->class_object, false);
            if (!cls) { vm->dex = prev_dex; loading_depth--; return DX_ERR_OUT_OF_MEMORY; }

            cls->access_flags = found_dex->class_defs[i].access_flags;
            cls->dex_class_def_idx = i;
            cls->dex_file = found_dex;
            cls->source_dex_idx = (uint8_t)found_dex_idx;

            // Parse interfaces from type_list at interfaces_off
            uint32_t iface_off = found_dex->class_defs[i].interfaces_off;
            if (iface_off != 0 && iface_off + 4 <= found_dex->raw_size) {
                const uint8_t *iface_data = found_dex->raw_data + iface_off;
                uint32_t iface_size = *(const uint32_t *)iface_data;
                if (iface_size > 0 && iface_off + 4 + iface_size * 2 <= found_dex->raw_size) {
                    const uint16_t *iface_type_idxs = (const uint16_t *)(iface_data + 4);
                    cls->interfaces = (const char **)dx_malloc(sizeof(const char *) * iface_size);
                    if (cls->interfaces) {
                        cls->interface_count = iface_size;
                        for (uint32_t fi = 0; fi < iface_size; fi++) {
                            cls->interfaces[fi] = dx_dex_get_type(found_dex, iface_type_idxs[fi]);
                        }
                        DX_TRACE(TAG, "Class %s implements %u interfaces", type, iface_size);
                    }
                }
            }

            DxDexClassData *cd = found_dex->class_data[i];
            if (!cd) {
                // Cache even classes with no class_data
                if (vm->class_def_cache[found_dex_idx] &&
                    i < vm->class_def_cache_size[found_dex_idx]) {
                    vm->class_def_cache[found_dex_idx][i] = cls;
                }
                vm->dex = prev_dex;
                if (out) *out = cls;
                loading_depth--;
                return DX_OK;
            }

            // Set up instance fields
            cls->instance_field_count = cd->instance_fields_count;
            if (cd->instance_fields_count > 0) {
                cls->field_defs = (typeof(cls->field_defs))dx_malloc(
                    sizeof(*cls->field_defs) * cd->instance_fields_count);
                uint32_t super_field_count = super ? super->instance_field_count : 0;
                for (uint32_t f = 0; f < cd->instance_fields_count; f++) {
                    uint32_t fidx = cd->instance_fields[f].field_idx;
                    cls->field_defs[f].name = dx_dex_get_field_name(vm->dex, fidx);
                    cls->field_defs[f].type = fidx < vm->dex->field_count ?
                        dx_dex_get_type(vm->dex, vm->dex->field_ids[fidx].type_idx) : "?";
                    cls->field_defs[f].flags = cd->instance_fields[f].access_flags;
                    cls->field_defs[f].is_volatile =
                        (cd->instance_fields[f].access_flags & DX_ACC_VOLATILE) != 0;
                    // Precompute absolute slot index: super fields come first
                    cls->field_defs[f].slot_index = super_field_count + f;
                }
            }

            // Add super's instance field count
            if (super) {
                cls->instance_field_count += super->instance_field_count;
            }

            // Set up static fields
            cls->static_field_count = cd->static_fields_count;
            if (cd->static_fields_count > 0) {
                cls->static_fields = (DxValue *)dx_malloc(
                    sizeof(DxValue) * cd->static_fields_count);
            }

            // Parse encoded static field defaults from DEX
            uint32_t sv_off = found_dex->class_defs[i].static_values_off;
            if (sv_off != 0 && cls->static_fields) {
                dx_dex_parse_static_values(found_dex, sv_off, cls->static_fields, cls->static_field_count);
            }

            // Set up direct methods
            if (cd->direct_methods_count > 0) {
                cls->direct_methods = (DxMethod *)dx_malloc(sizeof(DxMethod) * cd->direct_methods_count);
                cls->direct_method_count = cd->direct_methods_count;
                for (uint32_t m = 0; m < cd->direct_methods_count; m++) {
                    DxMethod *method = &cls->direct_methods[m];
                    memset(method, 0, sizeof(DxMethod));
                    uint32_t midx = cd->direct_methods[m].method_idx;
                    method->name = dx_dex_get_method_name(vm->dex, midx);
                    method->shorty = dx_dex_get_method_shorty(vm->dex, midx);
                    method->declaring_class = cls;
                    method->access_flags = cd->direct_methods[m].access_flags;
                    method->dex_method_idx = midx;
                    method->vtable_idx = -1;

                    if (cd->direct_methods[m].code_off != 0) {
                        DxResult cr = dx_dex_parse_code_item(vm->dex,
                            cd->direct_methods[m].code_off, &method->code);
                        method->has_code = (cr == DX_OK);
                        if (method->has_code) {
                            dx_dex_parse_debug_info(vm->dex, &method->code);
                        }
                    }
                }
            }

            // Set up virtual methods
            if (cd->virtual_methods_count > 0) {
                cls->virtual_methods = (DxMethod *)dx_malloc(sizeof(DxMethod) * cd->virtual_methods_count);
                cls->virtual_method_count = cd->virtual_methods_count;
                for (uint32_t m = 0; m < cd->virtual_methods_count; m++) {
                    DxMethod *method = &cls->virtual_methods[m];
                    memset(method, 0, sizeof(DxMethod));
                    uint32_t midx = cd->virtual_methods[m].method_idx;
                    method->name = dx_dex_get_method_name(vm->dex, midx);
                    method->shorty = dx_dex_get_method_shorty(vm->dex, midx);
                    method->declaring_class = cls;
                    method->access_flags = cd->virtual_methods[m].access_flags;
                    method->dex_method_idx = midx;
                    method->vtable_idx = (int32_t)m;

                    if (cd->virtual_methods[m].code_off != 0) {
                        DxResult cr = dx_dex_parse_code_item(vm->dex,
                            cd->virtual_methods[m].code_off, &method->code);
                        method->has_code = (cr == DX_OK);
                        if (method->has_code) {
                            dx_dex_parse_debug_info(vm->dex, &method->code);
                        }
                    }
                }
            }

            // Build vtable: inherit super vtable, apply overrides, append new methods
            uint32_t super_vtable_size = super ? super->vtable_size : 0;
            cls->vtable_size = super_vtable_size + cls->virtual_method_count;
            if (cls->vtable_size > 0) {
                cls->vtable = (DxMethod **)dx_malloc(sizeof(DxMethod *) * cls->vtable_size);
                // Copy super vtable
                for (uint32_t v = 0; v < super_vtable_size; v++) {
                    cls->vtable[v] = super->vtable[v];
                }
                // Check for overrides, then append
                for (uint32_t m = 0; m < cls->virtual_method_count; m++) {
                    DxMethod *method = &cls->virtual_methods[m];
                    bool overridden = false;
                    for (uint32_t v = 0; v < super_vtable_size; v++) {
                        if (cls->vtable[v] &&
                            strcmp(cls->vtable[v]->name, method->name) == 0) {
                            // Name matches — verify shorty (signature) also matches before overriding
                            if (cls->vtable[v]->shorty && method->shorty &&
                                strcmp(cls->vtable[v]->shorty, method->shorty) == 0) {
                                cls->vtable[v] = method;
                                method->vtable_idx = (int32_t)v;
                                overridden = true;
                                break;
                            } else {
                                // Name matches but signature differs — not a valid override.
                                // Log warning for potential DEX inconsistency or method overload
                                // that should not replace the vtable slot.
                                DX_WARN(TAG, "vtable[%u] signature mismatch during override: "
                                        "%s.%s (shorty=%s) vs %s.%s (shorty=%s)",
                                        v,
                                        cls->vtable[v]->declaring_class ?
                                            cls->vtable[v]->declaring_class->descriptor : "?",
                                        cls->vtable[v]->name,
                                        cls->vtable[v]->shorty ? cls->vtable[v]->shorty : "null",
                                        cls->descriptor ? cls->descriptor : "?",
                                        method->name,
                                        method->shorty ? method->shorty : "null");
                            }
                        }
                    }
                    if (!overridden) {
                        method->vtable_idx = (int32_t)(super_vtable_size + m);
                        cls->vtable[super_vtable_size + m] = method;
                    }
                }
            }

            // Build itable: for each implemented interface, map interface methods to class methods
            if (cls->interface_count > 0) {
                cls->itable = (typeof(cls->itable))dx_malloc(sizeof(*cls->itable) * cls->interface_count);
                if (cls->itable) {
                    cls->itable_count = 0;
                    for (uint32_t ii = 0; ii < cls->interface_count; ii++) {
                        if (!cls->interfaces[ii]) continue;
                        DxClass *iface = dx_vm_find_class(vm, cls->interfaces[ii]);
                        if (!iface || iface->virtual_method_count == 0) continue;

                        int idx = cls->itable_count;
                        cls->itable[idx].interface_desc = cls->interfaces[ii];
                        cls->itable[idx].method_count = (int)iface->virtual_method_count;
                        cls->itable[idx].methods = (DxMethod **)dx_malloc(
                            sizeof(DxMethod *) * iface->virtual_method_count);
                        if (!cls->itable[idx].methods) continue;

                        for (uint32_t im = 0; im < iface->virtual_method_count; im++) {
                            DxMethod *imethod = &iface->virtual_methods[im];
                            // Search the class vtable for a matching method
                            DxMethod *resolved = NULL;
                            for (uint32_t v = 0; v < cls->vtable_size; v++) {
                                if (cls->vtable[v] &&
                                    strcmp(cls->vtable[v]->name, imethod->name) == 0 &&
                                    cls->vtable[v]->shorty && imethod->shorty &&
                                    strcmp(cls->vtable[v]->shorty, imethod->shorty) == 0) {
                                    resolved = cls->vtable[v];
                                    break;
                                }
                            }
                            // Also check direct methods (for static interface methods etc.)
                            if (!resolved) {
                                resolved = dx_vm_find_method(cls, imethod->name, imethod->shorty);
                            }
                            cls->itable[idx].methods[im] = resolved; // may be NULL
                        }
                        cls->itable_count++;
                    }
                }
            }

            // Parse annotations from DEX
            uint32_t ann_off = found_dex->class_defs[i].annotations_off;
            if (ann_off != 0) {
                DxAnnotationsDirectory ann_dir;
                if (dx_dex_parse_annotations(found_dex, ann_off, &ann_dir) == DX_OK) {
                    // Store class-level annotations (steal element ownership from directory)
                    if (ann_dir.class_annotation_count > 0) {
                        cls->annotations = (typeof(cls->annotations))dx_malloc(
                            sizeof(*cls->annotations) * ann_dir.class_annotation_count);
                        if (cls->annotations) {
                            cls->annotation_count = ann_dir.class_annotation_count;
                            for (uint32_t a = 0; a < ann_dir.class_annotation_count; a++) {
                                cls->annotations[a].type = ann_dir.class_annotations[a].type;
                                cls->annotations[a].visibility = ann_dir.class_annotations[a].visibility;
                                // Steal elements from directory (transfer ownership)
                                cls->annotations[a].elements = ann_dir.class_annotations[a].elements;
                                cls->annotations[a].element_count = ann_dir.class_annotations[a].element_count;
                                ann_dir.class_annotations[a].elements = NULL;
                                ann_dir.class_annotations[a].element_count = 0;
                            }
                        }
                    }
                    // Store method-level annotations (steal element ownership)
                    for (uint32_t ma = 0; ma < ann_dir.annotated_method_count; ma++) {
                        uint32_t midx = ann_dir.method_idxs[ma];
                        // Find matching DxMethod in direct or virtual methods
                        DxMethod *target = NULL;
                        for (uint32_t m = 0; m < cls->direct_method_count; m++) {
                            if (cls->direct_methods[m].dex_method_idx == midx) {
                                target = &cls->direct_methods[m];
                                break;
                            }
                        }
                        if (!target) {
                            for (uint32_t m = 0; m < cls->virtual_method_count; m++) {
                                if (cls->virtual_methods[m].dex_method_idx == midx) {
                                    target = &cls->virtual_methods[m];
                                    break;
                                }
                            }
                        }
                        if (target && ann_dir.method_annotation_counts[ma] > 0) {
                            uint32_t cnt = ann_dir.method_annotation_counts[ma];
                            target->annotations = (typeof(target->annotations))dx_malloc(
                                sizeof(*target->annotations) * cnt);
                            if (target->annotations) {
                                target->annotation_count = cnt;
                                for (uint32_t a = 0; a < cnt; a++) {
                                    target->annotations[a].type = ann_dir.method_annotations[ma][a].type;
                                    target->annotations[a].visibility = ann_dir.method_annotations[ma][a].visibility;
                                    target->annotations[a].elements = ann_dir.method_annotations[ma][a].elements;
                                    target->annotations[a].element_count = ann_dir.method_annotations[ma][a].element_count;
                                    ann_dir.method_annotations[ma][a].elements = NULL;
                                    ann_dir.method_annotations[ma][a].element_count = 0;
                                }
                            }
                        }
                    }
                    dx_dex_free_annotations(&ann_dir);
                }
            }

            cls->status = DX_CLASS_LOADED;
            DX_INFO(TAG, "Loaded class %s (%u ifields, %u dmethods, %u vmethods, %u annotations)",
                    descriptor, cls->instance_field_count,
                    cls->direct_method_count, cls->virtual_method_count,
                    cls->annotation_count);

            // Store in per-DEX class_def cache for O(1) re-lookup
            if (vm->class_def_cache[found_dex_idx] &&
                i < vm->class_def_cache_size[found_dex_idx]) {
                vm->class_def_cache[found_dex_idx][i] = cls;
            }

            vm->dex = prev_dex;
            if (out) *out = cls;
            loading_depth--;
            return DX_OK;
        }
    }

    vm->dex = prev_dex;
    loading_depth--;
    return DX_ERR_CLASS_NOT_FOUND;
}

DxResult dx_vm_init_class(DxVM *vm, DxClass *cls) {
    if (!cls) return DX_ERR_NULL_PTR;
    if (cls->status >= DX_CLASS_INITIALIZED) return DX_OK;

    // Initialize superclass first
    if (cls->super_class && cls->super_class->status < DX_CLASS_INITIALIZED) {
        DxResult res = dx_vm_init_class(vm, cls->super_class);
        if (res != DX_OK) return res;
    }

    cls->status = DX_CLASS_INITIALIZING;

    // Look for <clinit>
    for (uint32_t i = 0; i < cls->direct_method_count; i++) {
        if (strcmp(cls->direct_methods[i].name, "<clinit>") == 0) {
            DX_DEBUG(TAG, "Running <clinit> for %s", cls->descriptor);
            DxResult res = dx_vm_execute_method(vm, &cls->direct_methods[i], NULL, 0, NULL);
            if (res != DX_OK) {
                cls->status = DX_CLASS_ERROR;
                return res;
            }
            break;
        }
    }

    cls->status = DX_CLASS_INITIALIZED;
    return DX_OK;
}

// ── Mark-and-sweep garbage collection ──

// Check if a class is a WeakReference or SoftReference type
static bool gc_is_weak_ref_class(DxClass *cls) {
    if (!cls || !cls->descriptor) return false;
    return (strstr(cls->descriptor, "WeakReference") != NULL ||
            strstr(cls->descriptor, "SoftReference") != NULL);
}

static void gc_mark_object(DxObject *obj) {
    if (!obj || obj->gc_mark) return;
    obj->gc_mark = true;

    // Mark objects referenced by instance fields
    if (obj->fields && obj->klass) {
        bool is_weak = gc_is_weak_ref_class(obj->klass);
        for (uint32_t i = 0; i < obj->klass->instance_field_count; i++) {
            // Skip the referent field (field[0]) on WeakReference/SoftReference
            // so that weak referents don't prevent collection
            if (is_weak && i == 0) continue;
            if (obj->fields[i].tag == DX_VAL_OBJ && obj->fields[i].obj) {
                gc_mark_object(obj->fields[i].obj);
            }
        }
    }

    // Mark objects referenced by array elements
    if (obj->is_array && obj->array_elements) {
        for (uint32_t i = 0; i < obj->array_length; i++) {
            if (obj->array_elements[i].tag == DX_VAL_OBJ && obj->array_elements[i].obj) {
                gc_mark_object(obj->array_elements[i].obj);
            }
        }
    }
}

// Forward declarations for incremental GC
static void gc_clear_weak_refs(DxVM *vm);
static void gc_mark_ui_tree(DxUINode *node);

// ── Mark stack helpers for incremental GC (non-recursive marking) ──

static void gc_mark_stack_push(DxVM *vm, DxObject *obj) {
    if (!obj || obj->gc_mark) return;
    if (vm->gc_mark_stack_top >= DX_GC_MARK_STACK_SIZE) {
        // Overflow: fall back to immediate recursive mark
        gc_mark_object(obj);
        return;
    }
    obj->gc_mark = true;
    vm->gc_mark_stack[vm->gc_mark_stack_top++] = obj;
}

// Process one object from the mark stack: mark its children (pushing them)
static void gc_mark_stack_process_one(DxVM *vm) {
    if (vm->gc_mark_stack_top == 0) return;
    DxObject *obj = vm->gc_mark_stack[--vm->gc_mark_stack_top];
    if (!obj) return;

    // Trace instance fields
    if (obj->fields && obj->klass) {
        bool is_weak = gc_is_weak_ref_class(obj->klass);
        for (uint32_t i = 0; i < obj->klass->instance_field_count; i++) {
            if (is_weak && i == 0) continue;
            if (obj->fields[i].tag == DX_VAL_OBJ && obj->fields[i].obj) {
                gc_mark_stack_push(vm, obj->fields[i].obj);
            }
        }
    }

    // Trace array elements
    if (obj->is_array && obj->array_elements) {
        for (uint32_t i = 0; i < obj->array_length; i++) {
            if (obj->array_elements[i].tag == DX_VAL_OBJ && obj->array_elements[i].obj) {
                gc_mark_stack_push(vm, obj->array_elements[i].obj);
            }
        }
    }
}

// Push all GC roots onto the mark stack (used to start incremental marking)
static void gc_push_roots(DxVM *vm) {
    // Root 1: activity instance
    gc_mark_stack_push(vm, vm->activity_instance);

    // Root 2: all registers in the current frame chain
    DxFrame *frame = vm->current_frame;
    while (frame) {
        if (frame->method && frame->method->has_code) {
            uint32_t reg_count = frame->method->code.registers_size;
            if (reg_count > DX_MAX_REGISTERS) reg_count = DX_MAX_REGISTERS;
            for (uint32_t r = 0; r < reg_count; r++) {
                if (frame->registers[r].tag == DX_VAL_OBJ && frame->registers[r].obj) {
                    gc_mark_stack_push(vm, frame->registers[r].obj);
                }
            }
        }
        if (frame->result.tag == DX_VAL_OBJ && frame->result.obj) {
            gc_mark_stack_push(vm, frame->result.obj);
        }
        if (frame->exception) {
            gc_mark_stack_push(vm, frame->exception);
        }
        frame = frame->caller;
    }

    // Root 3: static fields of all loaded classes
    for (uint32_t c = 0; c < vm->class_count; c++) {
        DxClass *cls = vm->classes[c];
        if (!cls || !cls->static_fields) continue;
        for (uint32_t f = 0; f < cls->static_field_count; f++) {
            if (cls->static_fields[f].tag == DX_VAL_OBJ && cls->static_fields[f].obj) {
                gc_mark_stack_push(vm, cls->static_fields[f].obj);
            }
        }
    }

    // Root 4: UI tree nodes
    if (vm->ctx && vm->ctx->ui_root) {
        gc_mark_ui_tree(vm->ctx->ui_root);
    }

    // Root 5: interned strings
    for (uint32_t i = 0; i < vm->interned_count; i++) {
        if (vm->interned_strings[i].obj) {
            gc_mark_stack_push(vm, vm->interned_strings[i].obj);
        }
    }
}

// Incremental GC step: processes up to max_objects in the current phase
static void gc_incremental_step(DxVM *vm, int max_objects) {
    if (!vm) return;

    if (vm->gc_phase == DX_GC_IDLE) {
        // Start a new incremental cycle: clear marks, push roots, enter MARKING
        for (uint32_t i = 0; i < vm->heap_count; i++) {
            if (vm->heap[i]) vm->heap[i]->gc_mark = false;
        }
        vm->gc_mark_stack_top = 0;
        gc_push_roots(vm);
        vm->gc_phase = DX_GC_MARKING;
        DX_INFO(TAG, "Incremental GC started: %u objects in heap", vm->heap_count);
        return;  // roots pushed; actual marking starts on next step
    }

    if (vm->gc_phase == DX_GC_MARKING) {
        int processed = 0;
        while (vm->gc_mark_stack_top > 0 && processed < max_objects) {
            gc_mark_stack_process_one(vm);
            processed++;
        }
        if (vm->gc_mark_stack_top == 0) {
            // Marking complete, transition to sweep phase
            vm->gc_sweep_cursor = 0;
            vm->gc_phase = DX_GC_SWEEPING;
            DX_TRACE(TAG, "Incremental GC: mark phase complete, starting sweep");
        }
        return;
    }

    if (vm->gc_phase == DX_GC_SWEEPING) {
        uint32_t before = vm->heap_count;
        int processed = 0;
        // We sweep from gc_sweep_cursor; compact into the same array
        // For simplicity, we do the compaction in one final pass when sweep completes
        // During incremental sweep, we just free unmarked objects and NULL their slots
        while (vm->gc_sweep_cursor < vm->heap_count && processed < max_objects) {
            DxObject *obj = vm->heap[vm->gc_sweep_cursor];
            if (obj && !obj->gc_mark) {
                dx_free(obj->fields);
                dx_free(obj->string_data);
                dx_free(obj->array_elements);
                dx_free(obj);
                vm->heap[vm->gc_sweep_cursor] = NULL;
            }
            vm->gc_sweep_cursor++;
            processed++;
        }

        if (vm->gc_sweep_cursor >= vm->heap_count) {
            // Sweep complete: compact the heap
            uint32_t write = 0;
            for (uint32_t i = 0; i < vm->heap_count; i++) {
                if (vm->heap[i]) {
                    vm->heap[i]->heap_idx = write;
                    vm->heap[write++] = vm->heap[i];
                }
            }
            for (uint32_t i = write; i < vm->heap_count; i++) {
                vm->heap[i] = NULL;
            }
            uint32_t freed = vm->heap_count - write;
            vm->heap_count = write;

            gc_clear_weak_refs(vm);

            // Post-sweep dangling pointer scrub for incremental GC
            // Scrub frame registers
            DxFrame *sf = vm->current_frame;
            while (sf) {
                if (sf->method && sf->method->has_code) {
                    uint32_t rc = sf->method->code.registers_size;
                    if (rc > DX_MAX_REGISTERS) rc = DX_MAX_REGISTERS;
                    for (uint32_t r = 0; r < rc; r++) {
                        if (sf->registers[r].tag == DX_VAL_OBJ &&
                            sf->registers[r].obj &&
                            !sf->registers[r].obj->gc_mark) {
                            sf->registers[r] = DX_NULL_VALUE;
                        }
                    }
                }
                if (sf->result.tag == DX_VAL_OBJ &&
                    sf->result.obj && !sf->result.obj->gc_mark) {
                    sf->result = DX_NULL_VALUE;
                    sf->has_result = false;
                }
                if (sf->exception && !sf->exception->gc_mark) {
                    sf->exception = NULL;
                }
                sf = sf->caller;
            }
            // Scrub static fields
            for (uint32_t ci = 0; ci < vm->class_count; ci++) {
                DxClass *cls = vm->classes[ci];
                if (!cls || !cls->static_fields) continue;
                for (uint32_t fi = 0; fi < cls->static_field_count; fi++) {
                    if (cls->static_fields[fi].tag == DX_VAL_OBJ &&
                        cls->static_fields[fi].obj &&
                        !cls->static_fields[fi].obj->gc_mark) {
                        cls->static_fields[fi] = DX_NULL_VALUE;
                    }
                }
            }
            // Scrub activity instance and pending exception
            if (vm->activity_instance && !vm->activity_instance->gc_mark) {
                vm->activity_instance = NULL;
            }
            if (vm->pending_exception && !vm->pending_exception->gc_mark) {
                vm->pending_exception = NULL;
            }

            vm->gc_phase = DX_GC_IDLE;
            DX_INFO(TAG, "Incremental GC completed: %u -> %u objects (%u freed)",
                    before, write, freed);
        }
        return;
    }
}

// After sweep, clear referent (field[0]) of surviving WeakReference/SoftReference
// objects whose referent was collected
static void gc_clear_weak_refs(DxVM *vm) {
    for (uint32_t i = 0; i < vm->heap_count; i++) {
        DxObject *obj = vm->heap[i];
        if (!obj || !obj->klass || !obj->fields) continue;
        if (!gc_is_weak_ref_class(obj->klass)) continue;
        if (obj->klass->instance_field_count == 0) continue;

        // field[0] is the referent — if it points to a swept object, null it out
        if (obj->fields[0].tag == DX_VAL_OBJ && obj->fields[0].obj) {
            DxObject *referent = obj->fields[0].obj;
            // The referent was not marked (it was swept), so it's now a dangling ptr.
            // We detect this by checking gc_mark: after sweep, surviving objects
            // have gc_mark == true. If referent was swept, its memory is freed.
            // Instead, we check whether the referent is still in the heap.
            bool found = false;
            for (uint32_t h = 0; h < vm->heap_count; h++) {
                if (vm->heap[h] == referent) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                obj->fields[0] = DX_NULL_VALUE;
            }
        }
    }
}

static void gc_mark_ui_tree(DxUINode *node) {
    if (!node) return;
    if (node->runtime_obj) gc_mark_object(node->runtime_obj);
    if (node->click_listener) gc_mark_object(node->click_listener);
    for (uint32_t i = 0; i < node->child_count; i++) {
        gc_mark_ui_tree(node->children[i]);
    }
}

DxResult dx_vm_gc(DxVM *vm) {
    if (!vm) return DX_ERR_NULL_PTR;

    uint64_t gc_start_ns = 0;
    if (vm->profiling_enabled) {
        gc_start_ns = dx_vm_time_ns();
    }

    uint32_t before = vm->heap_count;
    DX_INFO(TAG, "GC started: %u objects in heap", before);

    // Clear all marks
    for (uint32_t i = 0; i < vm->heap_count; i++) {
        if (vm->heap[i]) vm->heap[i]->gc_mark = false;
    }

    // ── Mark phase: walk all GC roots ──

    // Root 1: activity instance
    gc_mark_object(vm->activity_instance);

    // Root 2: all registers in the current frame chain
    DxFrame *frame = vm->current_frame;
    while (frame) {
        if (frame->method && frame->method->has_code) {
            uint32_t reg_count = frame->method->code.registers_size;
            if (reg_count > DX_MAX_REGISTERS) reg_count = DX_MAX_REGISTERS;
            for (uint32_t r = 0; r < reg_count; r++) {
                if (frame->registers[r].tag == DX_VAL_OBJ && frame->registers[r].obj) {
                    gc_mark_object(frame->registers[r].obj);
                }
            }
        }
        // Also mark the result and exception
        if (frame->result.tag == DX_VAL_OBJ && frame->result.obj) {
            gc_mark_object(frame->result.obj);
        }
        if (frame->exception) {
            gc_mark_object(frame->exception);
        }
        frame = frame->caller;
    }

    // Root 3: static fields of all loaded classes
    for (uint32_t c = 0; c < vm->class_count; c++) {
        DxClass *cls = vm->classes[c];
        if (!cls || !cls->static_fields) continue;
        for (uint32_t f = 0; f < cls->static_field_count; f++) {
            if (cls->static_fields[f].tag == DX_VAL_OBJ && cls->static_fields[f].obj) {
                gc_mark_object(cls->static_fields[f].obj);
            }
        }
    }

    // Root 4: UI tree nodes
    if (vm->ctx && vm->ctx->ui_root) {
        gc_mark_ui_tree(vm->ctx->ui_root);
    }

    // Root 5: interned strings
    for (uint32_t i = 0; i < vm->interned_count; i++) {
        if (vm->interned_strings[i].obj) {
            gc_mark_object(vm->interned_strings[i].obj);
        }
    }

    // ── Sweep phase: free unmarked objects, compact heap ──
    uint32_t write = 0;
    for (uint32_t i = 0; i < vm->heap_count; i++) {
        DxObject *obj = vm->heap[i];
        if (!obj) continue;

        if (obj->gc_mark) {
            // Keep this object, update its heap index
            obj->heap_idx = write;
            vm->heap[write++] = obj;
        } else {
            // Free this object
            dx_free(obj->fields);
            dx_free(obj->string_data);
            dx_free(obj->array_elements);
            dx_free(obj);
        }
    }

    // Null out the remaining slots
    for (uint32_t i = write; i < vm->heap_count; i++) {
        vm->heap[i] = NULL;
    }

    vm->heap_count = write;

    // Clear referent fields of surviving WeakReference/SoftReference objects
    // whose referents were swept
    gc_clear_weak_refs(vm);

    // ── Post-sweep dangling pointer scrub ──
    // Validate that all object references in frame registers, static fields,
    // and the UI tree still point to surviving (marked) heap objects.
    // This guards against corruption if a reference was missed during marking.

    // Scrub frame registers in the active call chain
    DxFrame *scrub_frame = vm->current_frame;
    while (scrub_frame) {
        if (scrub_frame->method && scrub_frame->method->has_code) {
            uint32_t reg_count = scrub_frame->method->code.registers_size;
            if (reg_count > DX_MAX_REGISTERS) reg_count = DX_MAX_REGISTERS;
            for (uint32_t r = 0; r < reg_count; r++) {
                if (scrub_frame->registers[r].tag == DX_VAL_OBJ &&
                    scrub_frame->registers[r].obj &&
                    !scrub_frame->registers[r].obj->gc_mark) {
                    DX_WARN(TAG, "GC: nulling dangling register v%u in frame %s.%s",
                            r,
                            scrub_frame->method->declaring_class ?
                                scrub_frame->method->declaring_class->descriptor : "?",
                            scrub_frame->method->name ? scrub_frame->method->name : "?");
                    scrub_frame->registers[r] = DX_NULL_VALUE;
                }
            }
        }
        // Scrub frame result
        if (scrub_frame->result.tag == DX_VAL_OBJ &&
            scrub_frame->result.obj && !scrub_frame->result.obj->gc_mark) {
            scrub_frame->result = DX_NULL_VALUE;
            scrub_frame->has_result = false;
        }
        // Scrub frame exception
        if (scrub_frame->exception && !scrub_frame->exception->gc_mark) {
            scrub_frame->exception = NULL;
        }
        scrub_frame = scrub_frame->caller;
    }

    // Scrub static fields of all loaded classes
    for (uint32_t c = 0; c < vm->class_count; c++) {
        DxClass *cls = vm->classes[c];
        if (!cls || !cls->static_fields) continue;
        for (uint32_t f = 0; f < cls->static_field_count; f++) {
            if (cls->static_fields[f].tag == DX_VAL_OBJ &&
                cls->static_fields[f].obj &&
                !cls->static_fields[f].obj->gc_mark) {
                DX_WARN(TAG, "GC: nulling dangling static field %u in class %s",
                        f, cls->descriptor ? cls->descriptor : "?");
                cls->static_fields[f] = DX_NULL_VALUE;
            }
        }
    }

    // Scrub activity instance
    if (vm->activity_instance && !vm->activity_instance->gc_mark) {
        DX_WARN(TAG, "GC: nulling dangling activity_instance");
        vm->activity_instance = NULL;
    }

    // Scrub pending exception
    if (vm->pending_exception && !vm->pending_exception->gc_mark) {
        DX_WARN(TAG, "GC: nulling dangling pending_exception");
        vm->pending_exception = NULL;
    }

    // Reset young generation count: all survivors in a major GC become old
    vm->young_gen_count = 0;
    for (uint32_t i = 0; i < vm->heap_count; i++) {
        if (vm->heap[i] && vm->heap[i]->generation == 0) {
            vm->heap[i]->generation = 1;  // promote all surviving young to old
        }
    }

    DX_INFO(TAG, "Major GC completed: %u -> %u objects (%u freed)", before, write, before - write);

    // Profiling: record GC pause time
    if (vm->profiling_enabled && gc_start_ns > 0) {
        uint64_t pause_ns = dx_vm_time_ns() - gc_start_ns;
        vm->last_gc_pause_ns = pause_ns;
        vm->total_gc_pause_ns += pause_ns;
        DX_INFO(TAG, "GC pause: %.3f ms (total: %.3f ms)",
                (double)pause_ns / 1000000.0,
                (double)vm->total_gc_pause_ns / 1000000.0);
    }

    return DX_OK;
}

DxObject *dx_vm_alloc_object(DxVM *vm, DxClass *cls) {
    if (!vm || !cls) return NULL;

    // Trigger minor GC when young generation exceeds threshold
    if (vm->young_gen_count >= vm->young_gen_threshold) {
        dx_vm_gc_minor(vm);
    }

    // Trigger major GC at 80% capacity
    if (vm->heap_count >= DX_MAX_HEAP_OBJECTS * 80 / 100) {
        dx_vm_gc(vm);
    }

    if (vm->heap_count >= DX_MAX_HEAP_OBJECTS) {
        DX_ERROR(TAG, "Heap full (%u objects) even after GC — OutOfMemoryError", DX_MAX_HEAP_OBJECTS);
        snprintf(vm->error_msg, sizeof(vm->error_msg),
                 "OutOfMemoryError: heap exhausted (%u/%u objects) allocating %s",
                 vm->heap_count, DX_MAX_HEAP_OBJECTS, cls->descriptor);
        // Set pending exception so the interpreter can unwind properly
        if (!vm->pending_exception) {
            // Avoid recursive alloc: only create exception if we have headroom
            // (the exception itself would need a heap slot, so skip if truly full)
            DX_ERROR(TAG, "Cannot allocate OutOfMemoryError object (heap full)");
        }
        return NULL;
    }
    // Warn when approaching limit
    if (vm->heap_count > 0 && (vm->heap_count % 1000) == 0) {
        DX_WARN(TAG, "Heap usage: %u/%u objects", vm->heap_count, DX_MAX_HEAP_OBJECTS);
    }

    DxObject *obj = (DxObject *)dx_malloc(sizeof(DxObject));
    if (!obj) {
        snprintf(vm->error_msg, sizeof(vm->error_msg),
                 "OutOfMemoryError: malloc failed allocating %s", cls->descriptor);
        return NULL;
    }

    obj->klass = cls;
    obj->ref_count = 1;
    obj->heap_idx = vm->heap_count;
    obj->ui_node = NULL;
    obj->string_data = NULL;
    obj->gc_mark = false;
    obj->generation = 0;  // new objects start in young generation
    obj->is_array = false;
    obj->array_length = 0;
    obj->array_elements = NULL;

    if (cls->instance_field_count > 0) {
        obj->fields = (DxValue *)dx_malloc(sizeof(DxValue) * cls->instance_field_count);
        if (!obj->fields) {
            dx_free(obj);
            return NULL;
        }
    }

    vm->heap[vm->heap_count++] = obj;
    vm->young_gen_count++;

    // Profiling: track allocation count and bytes
    if (vm->profiling_enabled) {
        vm->total_allocations++;
        vm->total_bytes_allocated += sizeof(DxObject);
        if (cls->instance_field_count > 0) {
            vm->total_bytes_allocated += sizeof(DxValue) * cls->instance_field_count;
        }
    }

    DX_TRACE(TAG, "Allocated %s (heap[%u])", cls->descriptor, obj->heap_idx);
    return obj;
}

DxObject *dx_vm_alloc_array(DxVM *vm, uint32_t length) {
    if (!vm) return NULL;

    // Trigger minor GC when young generation exceeds threshold
    if (vm->young_gen_count >= vm->young_gen_threshold) {
        dx_vm_gc_minor(vm);
    }

    // Trigger major GC at 80% capacity
    if (vm->heap_count >= DX_MAX_HEAP_OBJECTS * 80 / 100) {
        dx_vm_gc(vm);
    }

    if (vm->heap_count >= DX_MAX_HEAP_OBJECTS) {
        DX_ERROR(TAG, "Heap full (%u objects) even after GC — OutOfMemoryError (array[%u])",
                 DX_MAX_HEAP_OBJECTS, length);
        snprintf(vm->error_msg, sizeof(vm->error_msg),
                 "OutOfMemoryError: heap exhausted (%u/%u objects) allocating array[%u]",
                 vm->heap_count, DX_MAX_HEAP_OBJECTS, length);
        return NULL;
    }

    DxObject *obj = (DxObject *)dx_malloc(sizeof(DxObject));
    if (!obj) {
        snprintf(vm->error_msg, sizeof(vm->error_msg),
                 "OutOfMemoryError: malloc failed allocating array[%u]", length);
        return NULL;
    }

    obj->klass = vm->class_object;  // arrays are Object subtype
    obj->ref_count = 1;
    obj->heap_idx = vm->heap_count;
    obj->ui_node = NULL;
    obj->gc_mark = false;
    obj->generation = 0;  // new arrays start in young generation
    obj->fields = NULL;
    obj->is_array = true;
    obj->array_length = length;

    if (length > 0) {
        obj->array_elements = (DxValue *)dx_malloc(sizeof(DxValue) * length);
        if (!obj->array_elements) {
            dx_free(obj);
            return NULL;
        }
        memset(obj->array_elements, 0, sizeof(DxValue) * length);
    } else {
        obj->array_elements = NULL;
    }

    vm->heap[vm->heap_count++] = obj;
    vm->young_gen_count++;
    DX_TRACE(TAG, "Allocated array[%u] (heap[%u])", length, obj->heap_idx);
    return obj;
}

void dx_vm_release_object(DxVM *vm, DxObject *obj) {
    if (!obj) return;
    obj->ref_count--;
    // Actual deallocation deferred to GC or shutdown
}

DxResult dx_vm_set_field(DxObject *obj, const char *name, DxValue value) {
    if (!obj || !name || !obj->klass) return DX_ERR_NULL_PTR;

    uint32_t total_fields = obj->klass->instance_field_count;

    // Walk the class hierarchy from the concrete class upward
    DxClass *cls = obj->klass;
    while (cls) {
        uint32_t super_count = cls->super_class ? cls->super_class->instance_field_count : 0;
        uint32_t own_count = cls->instance_field_count - super_count;

        if (cls->field_defs && own_count > 0) {
            for (uint32_t i = 0; i < own_count; i++) {
                if (cls->field_defs[i].name && strcmp(cls->field_defs[i].name, name) == 0) {
                    // Use precomputed slot_index if available, otherwise compute
                    uint32_t slot = cls->field_defs[i].slot_index;
                    if (slot == 0 && i > 0) {
                        // Fallback for framework classes without precomputed slots
                        slot = super_count + i;
                    }
                    if (obj->fields && slot < total_fields) {
                        if (cls->field_defs[i].is_volatile) {
                            __sync_synchronize();  // store-store barrier before volatile write
                        }
                        obj->fields[slot] = value;
                        if (cls->field_defs[i].is_volatile) {
                            __sync_synchronize();  // store-load barrier after volatile write
                        }
                        return DX_OK;
                    }
                }
            }
        }
        cls = cls->super_class;
    }

    // Field not found - silently absorb for framework compatibility
    // (e.g. AppCompatActivity fields we don't model)
    DX_TRACE(TAG, "Field %s not found in %s (absorbed)", name, obj->klass->descriptor);
    return DX_OK;
}

DxResult dx_vm_get_field(DxObject *obj, const char *name, DxValue *out) {
    if (!obj || !name || !out || !obj->klass) return DX_ERR_NULL_PTR;

    uint32_t total_fields = obj->klass->instance_field_count;

    // Walk the class hierarchy from the concrete class upward
    DxClass *cls = obj->klass;
    while (cls) {
        uint32_t super_count = cls->super_class ? cls->super_class->instance_field_count : 0;
        uint32_t own_count = cls->instance_field_count - super_count;

        if (cls->field_defs && own_count > 0) {
            for (uint32_t i = 0; i < own_count; i++) {
                if (cls->field_defs[i].name && strcmp(cls->field_defs[i].name, name) == 0) {
                    // Use precomputed slot_index if available, otherwise compute
                    uint32_t slot = cls->field_defs[i].slot_index;
                    if (slot == 0 && i > 0) {
                        // Fallback for framework classes without precomputed slots
                        slot = super_count + i;
                    }
                    if (obj->fields && slot < total_fields) {
                        *out = obj->fields[slot];
                        if (cls->field_defs[i].is_volatile) {
                            __sync_synchronize();  // load-load/load-store barrier after volatile read
                        }
                        return DX_OK;
                    }
                }
            }
        }
        cls = cls->super_class;
    }

    // Field not found - return zero/null for framework compatibility
    *out = DX_NULL_VALUE;
    return DX_OK;
}

DxObject *dx_vm_create_string(DxVM *vm, const char *utf8) {
    if (!vm || !utf8) return NULL;

    // Check intern table first - return existing object for duplicate strings
    for (uint32_t i = 0; i < vm->interned_count; i++) {
        if (vm->interned_strings[i].value &&
            strcmp(vm->interned_strings[i].value, utf8) == 0) {
            return vm->interned_strings[i].obj;
        }
    }

    // Check if heap is getting full
    if (vm->heap_count >= DX_MAX_HEAP_OBJECTS - 1) {
        DX_WARN(TAG, "Heap near capacity (%u/%u), string creation may fail",
                vm->heap_count, DX_MAX_HEAP_OBJECTS);
        return NULL;
    }

    DxObject *str = dx_vm_alloc_object(vm, vm->class_string);
    if (!str) return NULL;

    // Store C string in dedicated string_data field (no pointer-cast abuse)
    char *dup = dx_strdup(utf8);
    str->string_data = dup;

    // Add to intern table
    if (vm->interned_count < DX_MAX_INTERNED_STRINGS) {
        vm->interned_strings[vm->interned_count].value = dup;
        vm->interned_strings[vm->interned_count].obj = str;
        vm->interned_count++;
    }

    return str;
}

DxObject *dx_vm_intern_string(DxVM *vm, const char *utf8) {
    // Public API - same as create_string since all strings are now interned
    return dx_vm_create_string(vm, utf8);
}

const char *dx_vm_get_string_value(DxObject *str_obj) {
    if (!str_obj || !str_obj->klass) return NULL;
    if (strcmp(str_obj->klass->descriptor, "Ljava/lang/String;") != 0) return NULL;
    return str_obj->string_data;
}

DxMethod *dx_vm_resolve_method(DxVM *vm, uint32_t dex_method_idx) {
    if (!vm) return NULL;

    // Use the current frame's class DEX file if available, else primary
    DxDexFile *dex = vm->dex;
    if (vm->current_frame && vm->current_frame->method &&
        vm->current_frame->method->declaring_class &&
        vm->current_frame->method->declaring_class->dex_file) {
        dex = vm->current_frame->method->declaring_class->dex_file;
    }
    if (!dex) return NULL;
    if (dex_method_idx >= dex->method_count) return NULL;

    const char *class_desc = dx_dex_get_method_class(dex, dex_method_idx);
    const char *method_name = dx_dex_get_method_name(dex, dex_method_idx);
    const char *shorty = dx_dex_get_method_shorty(dex, dex_method_idx);

    if (!class_desc || !method_name) return NULL;

    // Find or load class
    DxClass *cls = dx_vm_find_class(vm, class_desc);
    if (!cls) {
        dx_vm_load_class(vm, class_desc, &cls);
    }
    if (!cls) {
        DX_WARN(TAG, "Cannot resolve method: class %s not found", class_desc);
        return NULL;
    }

    DxMethod *m = dx_vm_find_method(cls, method_name, shorty);
    if (m) return m;

    // Fallback: search implemented interfaces for a default method
    return dx_vm_find_interface_method(vm, cls, method_name, shorty);
}

DxMethod *dx_vm_find_method(DxClass *cls, const char *name, const char *shorty) {
    if (!cls || !name) return NULL;

    // For framework native methods, match by name only (shorty may differ
    // between our stub and the DEX reference due to overloads or generics)
    bool lenient = cls->is_framework;

    // Search direct methods
    DxMethod *name_match = NULL;
    for (uint32_t i = 0; i < cls->direct_method_count; i++) {
        if (strcmp(cls->direct_methods[i].name, name) == 0) {
            if (!shorty || !cls->direct_methods[i].shorty ||
                strcmp(cls->direct_methods[i].shorty, shorty) == 0) {
                return &cls->direct_methods[i];
            }
            if (lenient && cls->direct_methods[i].is_native) {
                name_match = &cls->direct_methods[i];
            }
        }
    }

    // Search virtual methods
    for (uint32_t i = 0; i < cls->virtual_method_count; i++) {
        if (strcmp(cls->virtual_methods[i].name, name) == 0) {
            if (!shorty || !cls->virtual_methods[i].shorty ||
                strcmp(cls->virtual_methods[i].shorty, shorty) == 0) {
                return &cls->virtual_methods[i];
            }
            if (lenient && cls->virtual_methods[i].is_native) {
                name_match = &cls->virtual_methods[i];
            }
        }
    }

    // Return lenient name match for native framework methods
    if (name_match) return name_match;

    // Search superclass
    if (cls->super_class) {
        return dx_vm_find_method(cls->super_class, name, shorty);
    }

    return NULL;
}

// Search implemented interfaces for a default (non-abstract) method.
// Handles diamond inheritance by preferring sub-interfaces over parent interfaces.
DxMethod *dx_vm_find_interface_method(DxVM *vm, DxClass *cls, const char *name, const char *shorty) {
    if (!vm || !cls || !name) return NULL;

    // Fast path: check itable for O(1) lookup on the receiver's class
    if (cls->itable && cls->itable_count > 0) {
        for (int it = 0; it < cls->itable_count; it++) {
            const char *iface_desc = cls->itable[it].interface_desc;
            DxClass *iface = dx_vm_find_class(vm, iface_desc);
            if (!iface) continue;
            for (int im = 0; im < cls->itable[it].method_count; im++) {
                if ((uint32_t)im >= iface->virtual_method_count) break;
                DxMethod *imethod = &iface->virtual_methods[im];
                if (strcmp(imethod->name, name) != 0) continue;
                if (shorty && imethod->shorty && strcmp(imethod->shorty, shorty) != 0) continue;
                DxMethod *resolved = cls->itable[it].methods[im];
                if (resolved && (resolved->has_code || resolved->is_native)) {
                    return resolved;
                }
            }
        }
    }

    DxMethod *best = NULL;

    // Walk the class hierarchy upward, checking interfaces at each level
    for (DxClass *cur = cls; cur != NULL; cur = cur->super_class) {
        for (uint32_t i = 0; i < cur->interface_count; i++) {
            if (!cur->interfaces[i]) continue;
            DxClass *iface = dx_vm_find_class(vm, cur->interfaces[i]);
            if (!iface) continue;

            // Search this interface's virtual methods for a non-abstract match
            for (uint32_t m = 0; m < iface->virtual_method_count; m++) {
                DxMethod *im = &iface->virtual_methods[m];
                if (strcmp(im->name, name) != 0) continue;
                if (shorty && im->shorty && strcmp(im->shorty, shorty) != 0) continue;
                // Must have code (default method) or be native — skip purely abstract
                if (!im->has_code && !im->is_native) continue;
                // Skip bridge methods if a non-bridge candidate exists already
                if (best && (im->access_flags & DX_ACC_BRIDGE) && !(best->access_flags & DX_ACC_BRIDGE))
                    continue;

                if (!best) {
                    best = im;
                } else {
                    // Diamond resolution: prefer the more-specific interface.
                    // If this interface extends the interface that declared `best`,
                    // then this one is more specific.
                    DxClass *best_iface = best->declaring_class;
                    if (best_iface) {
                        for (uint32_t k = 0; k < iface->interface_count; k++) {
                            if (iface->interfaces[k] && best_iface->descriptor &&
                                strcmp(iface->interfaces[k], best_iface->descriptor) == 0) {
                                // iface extends best_iface → iface is more specific
                                best = im;
                                break;
                            }
                        }
                    }
                    // Prefer non-bridge over bridge
                    if ((best->access_flags & DX_ACC_BRIDGE) && !(im->access_flags & DX_ACC_BRIDGE)) {
                        best = im;
                    }
                }
            }

            // Also recursively search parent interfaces of this interface
            for (uint32_t k = 0; k < iface->interface_count; k++) {
                if (!iface->interfaces[k]) continue;
                DxClass *parent_iface = dx_vm_find_class(vm, iface->interfaces[k]);
                if (!parent_iface) continue;
                for (uint32_t m = 0; m < parent_iface->virtual_method_count; m++) {
                    DxMethod *im = &parent_iface->virtual_methods[m];
                    if (strcmp(im->name, name) != 0) continue;
                    if (shorty && im->shorty && strcmp(im->shorty, shorty) != 0) continue;
                    if (!im->has_code && !im->is_native) continue;
                    // Only use parent interface method if we have no better candidate
                    if (!best) best = im;
                }
            }
        }
    }

    return best;
}

DxObject *dx_vm_create_exception(DxVM *vm, const char *class_descriptor, const char *message) {
    if (!vm || !class_descriptor) return NULL;

    DxClass *cls = dx_vm_find_class(vm, class_descriptor);
    if (!cls) {
        // Fallback to generic Exception if the specific class isn't registered
        cls = dx_vm_find_class(vm, "Ljava/lang/Exception;");
        if (!cls) return NULL;
    }

    DxObject *exc = dx_vm_alloc_object(vm, cls);
    if (!exc) return NULL;

    // Store the message string in the detailMessage field (inherited from Throwable)
    if (message) {
        DxObject *msg_str = dx_vm_create_string(vm, message);
        if (msg_str) {
            DxValue msg_val;
            msg_val.tag = DX_VAL_OBJ;
            msg_val.obj = msg_str;
            dx_vm_set_field(exc, "detailMessage", msg_val);
        }
    }

    return exc;
}

// ============================================================
// Diagnostics: heap inspector
// ============================================================

char *dx_vm_heap_stats(DxVM *vm) {
    if (!vm) return dx_strdup("(no VM)\n");

    // Count live objects and tally by class
    uint32_t live = 0;
    uint32_t arrays = 0;

    // Top-N class tracking
    #define HEAP_TOP_N 10
    struct { const char *desc; uint32_t count; } top[HEAP_TOP_N];
    memset(top, 0, sizeof(top));
    uint32_t top_count = 0;

    for (uint32_t i = 0; i < vm->heap_count; i++) {
        DxObject *obj = vm->heap[i];
        if (!obj) continue;
        live++;
        if (obj->is_array) { arrays++; continue; }

        const char *desc = obj->klass ? obj->klass->descriptor : "(null)";
        // Find or insert in top list
        bool found = false;
        for (uint32_t t = 0; t < top_count; t++) {
            if (strcmp(top[t].desc, desc) == 0) {
                top[t].count++;
                found = true;
                break;
            }
        }
        if (!found) {
            if (top_count < HEAP_TOP_N) {
                top[top_count].desc = desc;
                top[top_count].count = 1;
                top_count++;
            } else {
                // Replace the smallest entry if this one is bigger
                uint32_t min_idx = 0;
                for (uint32_t t = 1; t < HEAP_TOP_N; t++) {
                    if (top[t].count < top[min_idx].count) min_idx = t;
                }
                if (top[min_idx].count == 0) {
                    top[min_idx].desc = desc;
                    top[min_idx].count = 1;
                }
            }
        }
    }

    // Sort top entries by count descending
    for (uint32_t i = 0; i < top_count; i++) {
        for (uint32_t j = i + 1; j < top_count; j++) {
            if (top[j].count > top[i].count) {
                const char *td = top[i].desc; uint32_t tc = top[i].count;
                top[i].desc = top[j].desc; top[i].count = top[j].count;
                top[j].desc = td; top[j].count = tc;
            }
        }
    }

    // Memory stats
    uint64_t allocs = 0, frees = 0, bytes = 0;
    dx_memory_stats(&allocs, &frees, &bytes);

    // Build output
    char buf[2048];
    size_t pos = 0;
    pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
        "Heap Statistics:\n"
        "  Capacity:      %u slots\n"
        "  Used:          %u slots\n"
        "  Live objects:  %u\n"
        "  Arrays:        %u\n"
        "  Classes:       %u\n"
        "  Instructions:  %llu total\n"
        "  Memory:        %llu allocs, %llu frees, %llu bytes outstanding\n",
        DX_MAX_HEAP_OBJECTS, vm->heap_count, live, arrays,
        vm->class_count, vm->insn_total,
        allocs, frees, bytes);

    if (top_count > 0) {
        pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos, "  Top classes by instance count:\n");
        for (uint32_t t = 0; t < top_count && t < HEAP_TOP_N; t++) {
            if (top[t].count == 0) break;
            pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                "    %4u  %s\n", top[t].count, top[t].desc);
        }
    }

    #undef HEAP_TOP_N
    return dx_strdup(buf);
}

// ============================================================
// Diagnostics: error detail with stack trace
// ============================================================

char *dx_vm_get_last_error_detail(DxVM *vm) {
    if (!vm || !vm->diag.has_error) return dx_strdup("(no error recorded)\n");

    char buf[4096];
    size_t pos = 0;

    pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
        "Error Detail:\n"
        "  Method:  %s\n"
        "  PC:      %u\n"
        "  Opcode:  0x%02x (%s)\n",
        vm->diag.method_name,
        vm->diag.pc,
        vm->diag.opcode,
        vm->diag.opcode_name);

    // Register snapshot
    if (vm->diag.reg_count > 0) {
        pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos, "  Registers:\n");
        for (uint32_t r = 0; r < vm->diag.reg_count && r < 16; r++) {
            DxValue v = vm->diag.registers[r];
            switch (v.tag) {
                case DX_VAL_INT:
                    pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                        "    v%-3u = int %d (0x%x)\n", r, v.i, (uint32_t)v.i);
                    break;
                case DX_VAL_LONG:
                    pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                        "    v%-3u = long %lld\n", r, (long long)v.l);
                    break;
                case DX_VAL_FLOAT:
                    pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                        "    v%-3u = float %f\n", r, v.f);
                    break;
                case DX_VAL_DOUBLE:
                    pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                        "    v%-3u = double %f\n", r, v.d);
                    break;
                case DX_VAL_OBJ:
                    if (v.obj) {
                        pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                            "    v%-3u = obj %s @%p\n", r,
                            v.obj->klass ? v.obj->klass->descriptor : "?",
                            (void *)v.obj);
                    } else {
                        pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                            "    v%-3u = null\n", r);
                    }
                    break;
                default:
                    pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                        "    v%-3u = void\n", r);
                    break;
            }
            if (pos >= sizeof(buf) - 100) break;
        }
    }

    // Stack trace
    if (vm->diag.stack_trace[0] != '\0') {
        pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
            "  Stack Trace:\n%s", vm->diag.stack_trace);
    }

    // Pending exception info
    if (vm->pending_exception && vm->pending_exception->klass) {
        const char *exc_desc = vm->pending_exception->klass->descriptor;
        DxValue msg_val;
        const char *msg = "";
        if (dx_vm_get_field(vm->pending_exception, "detailMessage", &msg_val) == DX_OK &&
            msg_val.tag == DX_VAL_OBJ && msg_val.obj) {
            msg = dx_vm_get_string_value(msg_val.obj);
            if (!msg) msg = "";
        }
        pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
            "  Exception: %s: %s\n", exc_desc, msg);
    }

    return dx_strdup(buf);
}

// ============================================================
// invoke-custom support: LambdaMetafactory + StringConcatFactory
// ============================================================

// Native dispatch for lambda proxy objects.
// field[0] = captured args array (or NULL), field[1] = impl_method_idx (int), field[2] = impl_kind (int)
static DxResult native_lambda_dispatch(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count) {
    // 'this' is args[0]
    DxObject *self = (arg_count > 0 && args[0].tag == DX_VAL_OBJ) ? args[0].obj : NULL;
    if (!self || !self->fields) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxObject *captured = (self->fields[0].tag == DX_VAL_OBJ) ? self->fields[0].obj : NULL;
    uint32_t impl_method_idx = (uint32_t)self->fields[1].i;
    (void)self->fields[2]; // impl_kind, reserved for future use

    // Build argument list: captured args first, then lambda call args (skip 'this')
    uint32_t captured_count = (captured && captured->is_array) ? captured->array_length : 0;
    uint32_t lambda_args = (arg_count > 1) ? arg_count - 1 : 0;
    uint32_t total_args = captured_count + lambda_args;

    DxValue call_args[DX_MAX_REGISTERS];
    if (total_args > DX_MAX_REGISTERS) total_args = DX_MAX_REGISTERS;

    uint32_t ci = 0;
    for (uint32_t i = 0; i < captured_count && ci < total_args; i++) {
        call_args[ci++] = captured->array_elements[i];
    }
    for (uint32_t i = 1; i < arg_count && ci < total_args; i++) {
        call_args[ci++] = args[i];
    }

    // Resolve the implementation method
    DxMethod *impl = dx_vm_resolve_method(vm, impl_method_idx);
    if (!impl) {
        DX_WARN(TAG, "Lambda: cannot resolve impl method idx=%u", impl_method_idx);
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxValue result = DX_NULL_VALUE;
    DxResult res = dx_vm_execute_method(vm, impl, call_args, ci, &result);
    frame->result = result;
    frame->has_result = true;

    if (res == DX_ERR_EXCEPTION) return DX_ERR_EXCEPTION;
    return DX_OK;
}

// Helper: convert a DxValue to a string representation for StringConcatFactory
static const char *dx_value_to_str(DxVM *vm, DxValue val, char *buf, size_t bufsz) {
    switch (val.tag) {
        case DX_VAL_INT:
            snprintf(buf, bufsz, "%d", val.i);
            return buf;
        case DX_VAL_LONG:
            snprintf(buf, bufsz, "%lld", (long long)val.l);
            return buf;
        case DX_VAL_FLOAT:
            snprintf(buf, bufsz, "%g", (double)val.f);
            return buf;
        case DX_VAL_DOUBLE:
            snprintf(buf, bufsz, "%g", val.d);
            return buf;
        case DX_VAL_OBJ:
            if (!val.obj) return "null";
            {
                const char *s = dx_vm_get_string_value(val.obj);
                if (s) return s;
                if (val.obj->klass && val.obj->fields) {
                    const char *desc = val.obj->klass->descriptor;
                    if (desc) {
                        if (strstr(desc, "Integer;") || strstr(desc, "Long;") ||
                            strstr(desc, "Short;") || strstr(desc, "Byte;")) {
                            snprintf(buf, bufsz, "%d", val.obj->fields[0].i);
                            return buf;
                        }
                        if (strstr(desc, "Boolean;")) {
                            return val.obj->fields[0].i ? "true" : "false";
                        }
                        if (strstr(desc, "Float;")) {
                            snprintf(buf, bufsz, "%g", (double)val.obj->fields[0].f);
                            return buf;
                        }
                        if (strstr(desc, "Double;")) {
                            snprintf(buf, bufsz, "%g", val.obj->fields[0].d);
                            return buf;
                        }
                        if (strstr(desc, "Character;")) {
                            snprintf(buf, bufsz, "%c", (char)val.obj->fields[0].i);
                            return buf;
                        }
                    }
                }
                snprintf(buf, bufsz, "%s@%p",
                         val.obj->klass ? val.obj->klass->descriptor : "Object",
                         (void *)val.obj);
                return buf;
            }
        default:
            return "";
    }
}

DxResult dx_vm_invoke_custom(DxVM *vm, DxFrame *frame, uint32_t call_site_idx,
                              DxValue *args, uint32_t arg_count) {
    if (!vm || !frame) return DX_ERR_NULL_PTR;

    // Get the DEX file from the current method
    DxDexFile *dex = NULL;
    if (frame->method && frame->method->declaring_class &&
        frame->method->declaring_class->dex_file) {
        dex = frame->method->declaring_class->dex_file;
    }
    if (!dex) dex = vm->dex;
    if (!dex) {
        DX_WARN(TAG, "invoke-custom: no DEX file available");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    const DxCallSite *cs = dx_dex_get_call_site(dex, call_site_idx);
    if (!cs) {
        DX_WARN(TAG, "invoke-custom: call site %u not found or not parsed", call_site_idx);
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // ---- StringConcatFactory ----
    if (cs->is_string_concat) {
        const char *recipe = cs->concat_recipe;
        if (!recipe) recipe = "";

        char result_buf[4096];
        size_t pos = 0;
        uint32_t arg_idx = 0;

        for (const char *rp = recipe; *rp && pos < sizeof(result_buf) - 1; rp++) {
            if (*rp == '\x01') {
                // Replace placeholder with next argument
                if (arg_idx < arg_count) {
                    char vbuf[256];
                    const char *s = dx_value_to_str(vm, args[arg_idx], vbuf, sizeof(vbuf));
                    size_t slen = strlen(s);
                    if (pos + slen < sizeof(result_buf) - 1) {
                        memcpy(result_buf + pos, s, slen);
                        pos += slen;
                    }
                    arg_idx++;
                }
            } else if (*rp == '\x02') {
                // \x02 = constant from bootstrap args (skip)
            } else {
                result_buf[pos++] = *rp;
            }
        }
        result_buf[pos] = '\0';

        DxObject *str = dx_vm_create_string(vm, result_buf);
        frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // ---- LambdaMetafactory ----
    // Create a synthetic lambda class implementing the functional interface

    const char *iface_desc = NULL;
    if (cs->proto_idx < dex->proto_count) {
        uint32_t ret_type_idx = dex->proto_ids[cs->proto_idx].return_type_idx;
        iface_desc = dx_dex_get_type(dex, ret_type_idx);
    }

    static int lambda_counter = 0;
    char lambda_desc[128];
    snprintf(lambda_desc, sizeof(lambda_desc), "L$Lambda%d;", lambda_counter++);

    DxClass *lambda_cls = (DxClass *)dx_malloc(sizeof(DxClass));
    if (!lambda_cls) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }
    memset(lambda_cls, 0, sizeof(DxClass));

    lambda_cls->descriptor = dx_strdup(lambda_desc);
    lambda_cls->super_class = vm->class_object;
    lambda_cls->status = DX_CLASS_INITIALIZED;
    lambda_cls->is_framework = true;
    lambda_cls->instance_field_count = 4; // [0]=captured, [1]=impl_method_idx, [2]=impl_kind, [3]=reserved

    if (iface_desc) {
        lambda_cls->interface_count = 1;
        lambda_cls->interfaces = (const char **)dx_malloc(sizeof(char *));
        if (lambda_cls->interfaces) {
            lambda_cls->interfaces[0] = iface_desc;
        }
    }

    // Create the virtual method for the functional interface method
    lambda_cls->virtual_methods = (DxMethod *)dx_malloc(sizeof(DxMethod));
    if (lambda_cls->virtual_methods) {
        memset(lambda_cls->virtual_methods, 0, sizeof(DxMethod));
        lambda_cls->virtual_methods[0].name = cs->method_name;
        lambda_cls->virtual_methods[0].declaring_class = lambda_cls;
        lambda_cls->virtual_methods[0].access_flags = DX_ACC_PUBLIC;
        lambda_cls->virtual_methods[0].native_fn = native_lambda_dispatch;
        lambda_cls->virtual_methods[0].is_native = true;
        lambda_cls->virtual_methods[0].vtable_idx = 0;

        // Get shorty from erased proto
        if (cs->proto_idx < dex->proto_count) {
            uint32_t shorty_idx = dex->proto_ids[cs->proto_idx].shorty_idx;
            lambda_cls->virtual_methods[0].shorty = dx_dex_get_string(dex, shorty_idx);
        }

        lambda_cls->virtual_method_count = 1;
    }

    // Register in VM
    if (vm->class_count < DX_MAX_CLASSES) {
        vm->classes[vm->class_count++] = lambda_cls;
        dx_vm_class_hash_insert(vm, lambda_cls);
    }

    // Allocate the lambda instance
    DxObject *lambda_obj = dx_vm_alloc_object(vm, lambda_cls);
    if (!lambda_obj) {
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // Capture closed-over arguments
    if (arg_count > 0) {
        DxObject *captured = dx_vm_alloc_array(vm, arg_count);
        if (captured) {
            for (uint32_t i = 0; i < arg_count; i++) {
                captured->array_elements[i] = args[i];
            }
            lambda_obj->fields[0] = DX_OBJ_VALUE(captured);
        }
    }

    lambda_obj->fields[1] = DX_INT_VALUE((int32_t)cs->impl_method_idx);
    lambda_obj->fields[2] = DX_INT_VALUE((int32_t)cs->impl_kind);

    frame->result = DX_OBJ_VALUE(lambda_obj);
    frame->has_result = true;

    DX_DEBUG(TAG, "invoke-custom: created lambda %s implementing %s.%s (impl method %u)",
             lambda_desc, iface_desc ? iface_desc : "?",
             cs->method_name ? cs->method_name : "?", cs->impl_method_idx);

    return DX_OK;
}

// ─── invoke-polymorphic: MethodHandle dispatch ───

DxResult dx_vm_invoke_method_handle(DxVM *vm, DxObject *handle_obj, DxValue *args, int argc, DxValue *result) {
    if (!vm || !handle_obj) {
        if (result) *result = DX_NULL_VALUE;
        return DX_OK;
    }

    // The handle object stores: fields[0] = kind (int), fields[1] = target index (int),
    // fields[2] = dex file pointer (stored as long/intptr)
    if (!handle_obj->fields) {
        DX_WARN(TAG, "invoke-method-handle: handle has no fields");
        if (result) *result = DX_NULL_VALUE;
        return DX_OK;
    }

    int32_t kind = handle_obj->fields[0].i;
    int32_t target_idx = handle_obj->fields[1].i;

    // Get the DEX file - stored in field[2] or fall back to VM's current
    DxDexFile *dex = NULL;
    if (handle_obj->fields[2].tag == DX_VAL_LONG) {
        dex = (DxDexFile *)(uintptr_t)handle_obj->fields[2].l;
    }
    if (!dex) {
        if (vm->current_frame && vm->current_frame->method &&
            vm->current_frame->method->declaring_class &&
            vm->current_frame->method->declaring_class->dex_file) {
            dex = vm->current_frame->method->declaring_class->dex_file;
        }
        if (!dex) dex = vm->dex;
    }

    switch (kind) {
        case DX_METHOD_HANDLE_INVOKE_STATIC: {
            // Static method: all args are method params (no receiver)
            DxMethod *target = dx_vm_resolve_method(vm, (uint32_t)target_idx);
            if (!target) {
                DX_WARN(TAG, "invoke-method-handle: cannot resolve static method %d", target_idx);
                if (result) *result = DX_NULL_VALUE;
                return DX_OK;
            }
            return dx_vm_execute_method(vm, target, args, (uint32_t)argc, result);
        }

        case DX_METHOD_HANDLE_INVOKE_INSTANCE:
        case DX_METHOD_HANDLE_INVOKE_DIRECT:
        case DX_METHOD_HANDLE_INVOKE_INTERFACE: {
            // Instance method: args[0] is receiver, rest are params
            DxMethod *target = dx_vm_resolve_method(vm, (uint32_t)target_idx);
            if (!target) {
                DX_WARN(TAG, "invoke-method-handle: cannot resolve instance method %d", target_idx);
                if (result) *result = DX_NULL_VALUE;
                return DX_OK;
            }
            return dx_vm_execute_method(vm, target, args, (uint32_t)argc, result);
        }

        case DX_METHOD_HANDLE_INVOKE_CONSTRUCTOR: {
            // Constructor: args[0] is the new-instance, invoke <init>
            DxMethod *target = dx_vm_resolve_method(vm, (uint32_t)target_idx);
            if (!target) {
                DX_WARN(TAG, "invoke-method-handle: cannot resolve constructor %d", target_idx);
                if (result) *result = DX_NULL_VALUE;
                return DX_OK;
            }
            DxResult r = dx_vm_execute_method(vm, target, args, (uint32_t)argc, result);
            // Constructor returns the instance
            if (r == DX_OK && result && argc > 0) {
                *result = args[0];
            }
            return r;
        }

        case DX_METHOD_HANDLE_INSTANCE_GET: {
            // iget: args[0] is receiver object, result is field value
            if (argc < 1 || args[0].tag != DX_VAL_OBJ || !args[0].obj) {
                if (result) *result = DX_NULL_VALUE;
                return DX_OK;
            }
            if (!dex || (uint32_t)target_idx >= dex->field_count) {
                if (result) *result = DX_NULL_VALUE;
                return DX_OK;
            }
            const char *fname = dx_dex_get_field_name(dex, (uint32_t)target_idx);
            DxValue val;
            if (dx_vm_get_field(args[0].obj, fname, &val) == DX_OK) {
                if (result) *result = val;
            } else {
                if (result) *result = DX_NULL_VALUE;
            }
            return DX_OK;
        }

        case DX_METHOD_HANDLE_INSTANCE_PUT: {
            // iput: args[0] is receiver, args[1] is value
            if (argc < 2 || args[0].tag != DX_VAL_OBJ || !args[0].obj) {
                if (result) *result = DX_NULL_VALUE;
                return DX_OK;
            }
            if (!dex || (uint32_t)target_idx >= dex->field_count) {
                if (result) *result = DX_NULL_VALUE;
                return DX_OK;
            }
            const char *fname = dx_dex_get_field_name(dex, (uint32_t)target_idx);
            dx_vm_set_field(args[0].obj, fname, args[1]);
            if (result) *result = DX_NULL_VALUE;
            return DX_OK;
        }

        case DX_METHOD_HANDLE_STATIC_GET: {
            // sget: no receiver args, result is static field value
            if (!dex || (uint32_t)target_idx >= dex->field_count) {
                if (result) *result = DX_NULL_VALUE;
                return DX_OK;
            }
            const char *fclass = dx_dex_get_field_class(dex, (uint32_t)target_idx);
            const char *fname = dx_dex_get_field_name(dex, (uint32_t)target_idx);
            DxClass *cls = fclass ? dx_vm_find_class(vm, fclass) : NULL;
            if (cls && cls->static_fields && fname) {
                // Search static fields by name
                for (uint32_t i = 0; i < cls->static_field_count; i++) {
                    if (cls->field_defs && cls->field_defs[i].name &&
                        strcmp(cls->field_defs[i].name, fname) == 0) {
                        if (result) *result = cls->static_fields[i];
                        return DX_OK;
                    }
                }
            }
            if (result) *result = DX_NULL_VALUE;
            return DX_OK;
        }

        case DX_METHOD_HANDLE_STATIC_PUT: {
            // sput: args[0] is value to store
            if (!dex || (uint32_t)target_idx >= dex->field_count) {
                if (result) *result = DX_NULL_VALUE;
                return DX_OK;
            }
            const char *fclass = dx_dex_get_field_class(dex, (uint32_t)target_idx);
            const char *fname = dx_dex_get_field_name(dex, (uint32_t)target_idx);
            DxClass *cls = fclass ? dx_vm_find_class(vm, fclass) : NULL;
            if (cls && cls->static_fields && fname && argc > 0) {
                for (uint32_t i = 0; i < cls->static_field_count; i++) {
                    if (cls->field_defs && cls->field_defs[i].name &&
                        strcmp(cls->field_defs[i].name, fname) == 0) {
                        cls->static_fields[i] = args[0];
                        break;
                    }
                }
            }
            if (result) *result = DX_NULL_VALUE;
            return DX_OK;
        }

        default:
            DX_WARN(TAG, "invoke-method-handle: unsupported handle kind %d", kind);
            if (result) *result = DX_NULL_VALUE;
            return DX_OK;
    }
}

// ─── Minor GC: only collect young generation (generation 0) objects ───

// Mark young-reachable objects: only traverse from roots into young objects,
// but also mark young objects referenced by old objects (remembered set scan).
static void gc_mark_object_young(DxObject *obj) {
    if (!obj || obj->gc_mark) return;
    if (obj->generation != 0) return;  // skip old generation objects
    obj->gc_mark = true;

    // Mark young objects referenced by instance fields
    if (obj->fields && obj->klass) {
        bool is_weak = gc_is_weak_ref_class(obj->klass);
        for (uint32_t i = 0; i < obj->klass->instance_field_count; i++) {
            if (is_weak && i == 0) continue;
            if (obj->fields[i].tag == DX_VAL_OBJ && obj->fields[i].obj) {
                gc_mark_object_young(obj->fields[i].obj);
            }
        }
    }

    // Mark young objects referenced by array elements
    if (obj->is_array && obj->array_elements) {
        for (uint32_t i = 0; i < obj->array_length; i++) {
            if (obj->array_elements[i].tag == DX_VAL_OBJ && obj->array_elements[i].obj) {
                gc_mark_object_young(obj->array_elements[i].obj);
            }
        }
    }
}

// Scan old-generation objects for references to young objects (remembered set approximation)
static void gc_scan_old_to_young(DxVM *vm) {
    for (uint32_t i = 0; i < vm->heap_count; i++) {
        DxObject *obj = vm->heap[i];
        if (!obj || obj->generation != 1) continue;  // only scan old objects

        // Check instance fields for references to young objects
        if (obj->fields && obj->klass) {
            for (uint32_t f = 0; f < obj->klass->instance_field_count; f++) {
                if (obj->fields[f].tag == DX_VAL_OBJ && obj->fields[f].obj) {
                    gc_mark_object_young(obj->fields[f].obj);
                }
            }
        }

        // Check array elements for references to young objects
        if (obj->is_array && obj->array_elements) {
            for (uint32_t e = 0; e < obj->array_length; e++) {
                if (obj->array_elements[e].tag == DX_VAL_OBJ && obj->array_elements[e].obj) {
                    gc_mark_object_young(obj->array_elements[e].obj);
                }
            }
        }
    }
}

DxResult dx_vm_gc_minor(DxVM *vm) {
    if (!vm) return DX_ERR_NULL_PTR;

    uint64_t gc_start_ns = 0;
    if (vm->profiling_enabled) {
        gc_start_ns = dx_vm_time_ns();
    }

    vm->gc_cycle_count++;

    // Every 4th cycle, promote to a full (major) GC instead
    if ((vm->gc_cycle_count % 4) == 0) {
        DX_INFO(TAG, "Minor GC -> promoting to major GC (cycle %u)", vm->gc_cycle_count);
        return dx_vm_gc(vm);
    }

    uint32_t before = vm->heap_count;
    DX_TRACE(TAG, "Minor GC started: %u objects in heap, %u young", before, vm->young_gen_count);

    // Clear gc_mark on young objects only
    for (uint32_t i = 0; i < vm->heap_count; i++) {
        if (vm->heap[i] && vm->heap[i]->generation == 0) {
            vm->heap[i]->gc_mark = false;
        }
    }

    // ── Mark phase: mark young objects reachable from roots ──

    // Root 1: activity instance
    if (vm->activity_instance) gc_mark_object_young(vm->activity_instance);

    // Root 2: frame registers
    DxFrame *frame = vm->current_frame;
    while (frame) {
        if (frame->method && frame->method->has_code) {
            uint32_t reg_count = frame->method->code.registers_size;
            if (reg_count > DX_MAX_REGISTERS) reg_count = DX_MAX_REGISTERS;
            for (uint32_t r = 0; r < reg_count; r++) {
                if (frame->registers[r].tag == DX_VAL_OBJ && frame->registers[r].obj) {
                    gc_mark_object_young(frame->registers[r].obj);
                }
            }
        }
        if (frame->result.tag == DX_VAL_OBJ && frame->result.obj) {
            gc_mark_object_young(frame->result.obj);
        }
        if (frame->exception) gc_mark_object_young(frame->exception);
        frame = frame->caller;
    }

    // Root 3: static fields
    for (uint32_t c = 0; c < vm->class_count; c++) {
        DxClass *cls = vm->classes[c];
        if (!cls || !cls->static_fields) continue;
        for (uint32_t f = 0; f < cls->static_field_count; f++) {
            if (cls->static_fields[f].tag == DX_VAL_OBJ && cls->static_fields[f].obj) {
                gc_mark_object_young(cls->static_fields[f].obj);
            }
        }
    }

    // Root 4: interned strings
    for (uint32_t i = 0; i < vm->interned_count; i++) {
        if (vm->interned_strings[i].obj) {
            gc_mark_object_young(vm->interned_strings[i].obj);
        }
    }

    // Root 5: old-to-young references (remembered set scan)
    gc_scan_old_to_young(vm);

    // ── Sweep phase: free unmarked young objects, promote surviving young to old ──
    uint32_t write = 0;
    uint32_t freed = 0;
    uint32_t promoted = 0;
    vm->young_gen_count = 0;

    for (uint32_t i = 0; i < vm->heap_count; i++) {
        DxObject *obj = vm->heap[i];
        if (!obj) continue;

        if (obj->generation == 0 && !obj->gc_mark) {
            // Young and unreachable: free it
            dx_free(obj->fields);
            dx_free(obj->string_data);
            dx_free(obj->array_elements);
            dx_free(obj);
            freed++;
        } else {
            // Surviving young objects get promoted to old generation
            if (obj->generation == 0) {
                obj->generation = 1;
                promoted++;
            }
            obj->heap_idx = write;
            vm->heap[write++] = obj;
        }
    }

    // Null out remaining slots
    for (uint32_t i = write; i < vm->heap_count; i++) {
        vm->heap[i] = NULL;
    }
    vm->heap_count = write;

    // Post-sweep dangling pointer scrub for frame registers
    DxFrame *sf = vm->current_frame;
    while (sf) {
        if (sf->method && sf->method->has_code) {
            uint32_t reg_count = sf->method->code.registers_size;
            if (reg_count > DX_MAX_REGISTERS) reg_count = DX_MAX_REGISTERS;
            for (uint32_t r = 0; r < reg_count; r++) {
                if (sf->registers[r].tag == DX_VAL_OBJ &&
                    sf->registers[r].obj &&
                    !sf->registers[r].obj->gc_mark && sf->registers[r].obj->generation == 0) {
                    sf->registers[r] = DX_NULL_VALUE;
                }
            }
        }
        if (sf->result.tag == DX_VAL_OBJ &&
            sf->result.obj && !sf->result.obj->gc_mark) {
            sf->result = DX_NULL_VALUE;
            sf->has_result = false;
        }
        if (sf->exception && !sf->exception->gc_mark) {
            sf->exception = NULL;
        }
        sf = sf->caller;
    }

    DX_INFO(TAG, "Minor GC completed: %u -> %u objects (%u freed, %u promoted)",
            before, vm->heap_count, freed, promoted);

    if (vm->profiling_enabled && gc_start_ns > 0) {
        uint64_t pause_ns = dx_vm_time_ns() - gc_start_ns;
        vm->last_gc_pause_ns = pause_ns;
        vm->total_gc_pause_ns += pause_ns;
    }

    return DX_OK;
}

// ─── GC collect (public entry point for memory-pressure handling) ───

DxResult dx_vm_gc_collect(DxVM *vm) {
    if (!vm) return DX_ERR_NULL_PTR;
    DX_INFO(TAG, "GC collect triggered (memory pressure or manual)");
    return dx_vm_gc(vm);
}

// ─── Incremental GC public API ───

void dx_vm_gc_step(DxVM *vm) {
    if (!vm) return;
    gc_incremental_step(vm, 256);
}

// ─── Missing feature tracking ───

void dx_vm_report_missing_feature(DxVM *vm, const char *feature) {
    if (!vm || !feature) return;

    // Deduplicate: don't record the same feature twice
    for (uint32_t i = 0; i < vm->missing_features.count; i++) {
        if (strcmp(vm->missing_features.features[i], feature) == 0) {
            return;
        }
    }

    if (vm->missing_features.count >= DX_MAX_MISSING_FEATURES) {
        DX_WARN(TAG, "Missing feature table full, dropping: %s", feature);
        return;
    }

    snprintf(vm->missing_features.features[vm->missing_features.count],
             sizeof(vm->missing_features.features[0]),
             "%s", feature);
    vm->missing_features.count++;
    DX_WARN(TAG, "Unsupported feature used: %s", feature);
}

const char *dx_vm_get_missing_features(DxVM *vm) {
    static char buf[4096];
    if (!vm || vm->missing_features.count == 0) {
        snprintf(buf, sizeof(buf), "(none)");
        return buf;
    }

    size_t pos = 0;
    pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                    "Unsupported features encountered (%u):\n",
                    vm->missing_features.count);
    for (uint32_t i = 0; i < vm->missing_features.count && pos < sizeof(buf) - 140; i++) {
        pos += (size_t)snprintf(buf + pos, sizeof(buf) - pos,
                        "  - %s\n", vm->missing_features.features[i]);
    }
    return buf;
}

// ---- Debug tracing API ----

void dx_vm_set_trace(DxVM *vm, bool bytecode, bool class_load, bool method_call) {
    if (!vm) return;
    vm->debug.bytecode_trace = bytecode;
    vm->debug.class_load_trace = class_load;
    vm->debug.method_call_trace = method_call;
    DX_INFO(TAG, "Trace config: bytecode=%d class_load=%d method_call=%d",
            bytecode, class_load, method_call);
}

void dx_vm_set_trace_filter(DxVM *vm, const char *method_filter) {
    if (!vm) return;
    vm->debug.trace_method_filter = method_filter;
    DX_INFO(TAG, "Trace filter: %s", method_filter ? method_filter : "(all)");
}

// ---- Inline Cache Operations ----

// Get (or lazily create) the inline cache for a call site at the given PC in a method.
// Uses a simple open-addressing hash table keyed by PC offset.
DxInlineCache *dx_vm_ic_get(DxMethod *method, uint32_t pc) {
    if (!method) return NULL;

    // Lazily allocate the IC table on first use
    if (!method->ic_table) {
        method->ic_table = (DxICTable *)dx_malloc(sizeof(DxICTable));
        if (!method->ic_table) return NULL;
        memset(method->ic_table, 0, sizeof(DxICTable));
    }

    DxICTable *table = method->ic_table;
    // We store pc+1 so that 0 means "empty slot" (pc=0 is a valid offset)
    uint32_t key = pc + 1;
    uint32_t idx = pc % DX_IC_TABLE_SIZE;

    // Linear probe to find existing or empty slot
    for (uint32_t i = 0; i < DX_IC_TABLE_SIZE; i++) {
        uint32_t slot = (idx + i) % DX_IC_TABLE_SIZE;
        if (table->slots[slot].pc == key) {
            return &table->slots[slot].ic;
        }
        if (table->slots[slot].pc == 0) {
            // Empty slot — claim it for this PC
            table->slots[slot].pc = key;
            return &table->slots[slot].ic;
        }
    }

    // Table full (shouldn't happen with 32 slots for typical methods)
    return NULL;
}

// Look up a cached method for the given receiver class. Returns NULL on miss.
DxMethod *dx_vm_ic_lookup(DxInlineCache *ic, DxClass *receiver_class) {
    if (!ic || !receiver_class) return NULL;

    for (uint8_t i = 0; i < ic->count; i++) {
        if (ic->entries[i].receiver_class == receiver_class) {
            ic->hits++;
            return ic->entries[i].resolved_method;
        }
    }

    ic->misses++;
    return NULL;
}

// Insert a resolved method into the inline cache for a receiver class.
void dx_vm_ic_insert(DxInlineCache *ic, DxClass *receiver_class, DxMethod *resolved) {
    if (!ic || !receiver_class || !resolved) return;

    // Check if already present (avoid duplicates)
    for (uint8_t i = 0; i < ic->count; i++) {
        if (ic->entries[i].receiver_class == receiver_class) {
            ic->entries[i].resolved_method = resolved;
            return;
        }
    }

    if (ic->count < DX_IC_SIZE) {
        // Append to cache
        ic->entries[ic->count].receiver_class = receiver_class;
        ic->entries[ic->count].resolved_method = resolved;
        ic->count++;
    } else {
        // Cache full — evict oldest (slot 0) and shift
        for (uint8_t i = 1; i < DX_IC_SIZE; i++) {
            ic->entries[i - 1] = ic->entries[i];
        }
        ic->entries[DX_IC_SIZE - 1].receiver_class = receiver_class;
        ic->entries[DX_IC_SIZE - 1].resolved_method = resolved;
    }
}

// Log aggregate inline cache statistics across all loaded methods.
void dx_vm_ic_stats(DxVM *vm) {
    if (!vm) return;

    uint64_t total_hits = 0;
    uint64_t total_misses = 0;
    uint32_t total_sites = 0;
    uint32_t monomorphic = 0;
    uint32_t polymorphic = 0;
    uint32_t megamorphic = 0;

    for (uint32_t c = 0; c < vm->class_count; c++) {
        DxClass *cls = vm->classes[c];
        if (!cls) continue;

        // Scan both direct and virtual methods
        DxMethod *method_lists[2] = { cls->direct_methods, cls->virtual_methods };
        uint32_t  method_counts[2] = { cls->direct_method_count, cls->virtual_method_count };

        for (int ml = 0; ml < 2; ml++) {
            for (uint32_t m = 0; m < method_counts[ml]; m++) {
                DxMethod *method = &method_lists[ml][m];
                if (!method->ic_table) continue;

                DxICTable *table = method->ic_table;
                for (uint32_t s = 0; s < DX_IC_TABLE_SIZE; s++) {
                    if (table->slots[s].pc == 0) continue;
                    DxInlineCache *ic = &table->slots[s].ic;
                    total_hits += ic->hits;
                    total_misses += ic->misses;
                    total_sites++;

                    if (ic->count == 1) monomorphic++;
                    else if (ic->count > 1 && ic->count <= DX_IC_SIZE) polymorphic++;
                    else if (ic->count >= DX_IC_SIZE) megamorphic++;
                }
            }
        }
    }

    uint64_t total = total_hits + total_misses;
    double hit_rate = total > 0 ? (double)total_hits / (double)total * 100.0 : 0.0;

    DX_INFO(TAG, "Inline cache stats: %u sites, %llu hits, %llu misses, %.1f%% hit rate",
            total_sites, total_hits, total_misses, hit_rate);
    DX_INFO(TAG, "  Monomorphic: %u, Polymorphic: %u, Megamorphic: %u",
            monomorphic, polymorphic, megamorphic);
}

// ─── Profiling API ───────────────────────────────────────────────────────────

void dx_vm_set_profiling(DxVM *vm, bool enabled) {
    if (!vm) return;
    vm->profiling_enabled = enabled;
    if (enabled) {
        DX_INFO(TAG, "Profiling enabled");
    } else {
        DX_INFO(TAG, "Profiling disabled");
    }
}

void dx_vm_dump_opcode_stats(DxVM *vm) {
    if (!vm) return;

    // Find the top 20 most frequent opcodes
    typedef struct { uint8_t opcode; uint64_t count; } OpcodeEntry;
    OpcodeEntry entries[256];
    for (int i = 0; i < 256; i++) {
        entries[i].opcode = (uint8_t)i;
        entries[i].count = vm->opcode_histogram[i];
    }

    // Simple selection sort for top 20
    for (int i = 0; i < 20 && i < 256; i++) {
        int max_idx = i;
        for (int j = i + 1; j < 256; j++) {
            if (entries[j].count > entries[max_idx].count) {
                max_idx = j;
            }
        }
        if (max_idx != i) {
            OpcodeEntry tmp = entries[i];
            entries[i] = entries[max_idx];
            entries[max_idx] = tmp;
        }
    }

    DX_INFO(TAG, "=== Opcode Frequency (top 20) ===");
    uint64_t total = 0;
    for (int i = 0; i < 256; i++) total += vm->opcode_histogram[i];

    for (int i = 0; i < 20 && entries[i].count > 0; i++) {
        double pct = total > 0 ? (double)entries[i].count / (double)total * 100.0 : 0.0;
        DX_INFO(TAG, "  #%2d  0x%02x %-30s  %llu  (%.1f%%)",
                i + 1, entries[i].opcode, dx_opcode_name(entries[i].opcode),
                entries[i].count, pct);
    }
    DX_INFO(TAG, "  Total instructions profiled: %llu", total);
}

void dx_vm_dump_hot_methods(DxVM *vm, int top_n) {
    if (!vm || top_n <= 0) return;

    // Collect all methods with call_count > 0
    typedef struct { DxMethod *method; } MethodRef;
    #define MAX_PROFILED_METHODS 4096
    MethodRef refs[MAX_PROFILED_METHODS];
    int ref_count = 0;

    for (uint32_t c = 0; c < vm->class_count && ref_count < MAX_PROFILED_METHODS; c++) {
        DxClass *cls = vm->classes[c];
        if (!cls) continue;

        DxMethod *method_lists[2] = { cls->direct_methods, cls->virtual_methods };
        uint32_t  method_counts[2] = { cls->direct_method_count, cls->virtual_method_count };

        for (int ml = 0; ml < 2; ml++) {
            for (uint32_t m = 0; m < method_counts[ml] && ref_count < MAX_PROFILED_METHODS; m++) {
                DxMethod *method = &method_lists[ml][m];
                if (method->call_count > 0) {
                    refs[ref_count++].method = method;
                }
            }
        }
    }

    // Sort by total_time_ns descending (selection sort for top_n)
    int limit = top_n < ref_count ? top_n : ref_count;
    for (int i = 0; i < limit; i++) {
        int max_idx = i;
        for (int j = i + 1; j < ref_count; j++) {
            if (refs[j].method->total_time_ns > refs[max_idx].method->total_time_ns) {
                max_idx = j;
            }
        }
        if (max_idx != i) {
            MethodRef tmp = refs[i];
            refs[i] = refs[max_idx];
            refs[max_idx] = tmp;
        }
    }

    DX_INFO(TAG, "=== Hot Methods (top %d by total time) ===", limit);
    for (int i = 0; i < limit; i++) {
        DxMethod *m = refs[i].method;
        const char *cls_name = m->declaring_class ? m->declaring_class->descriptor : "?";
        const char *mth_name = m->name ? m->name : "?";
        double total_ms = (double)m->total_time_ns / 1000000.0;
        double avg_us = m->call_count > 0 ? (double)m->total_time_ns / (double)m->call_count / 1000.0 : 0.0;
        DX_INFO(TAG, "  #%2d  %s.%s  calls=%u  total=%.3f ms  avg=%.1f us",
                i + 1, cls_name, mth_name, m->call_count, total_ms, avg_us);
    }
    DX_INFO(TAG, "  Heap: %llu allocations, %llu bytes total",
            vm->total_allocations, vm->total_bytes_allocated);
    DX_INFO(TAG, "  GC: last pause=%.3f ms, total pause=%.3f ms",
            (double)vm->last_gc_pause_ns / 1000000.0,
            (double)vm->total_gc_pause_ns / 1000000.0);
    #undef MAX_PROFILED_METHODS
}

// ─── Telemetry ───

DxTelemetry dx_vm_get_telemetry(DxVM *vm) {
    DxTelemetry t = {0};
    if (!vm) return t;
    t = vm->telemetry;
    // Also pull in counters that the VM already tracks natively
    t.total_instructions_executed = vm->insn_total;
    t.total_gc_pause_ns           = vm->total_gc_pause_ns;
    t.total_gc_collections        = vm->gc_cycle_count;
    t.classes_loaded              = vm->class_count;
    return t;
}

void dx_vm_set_telemetry_enabled(DxVM *vm, bool enabled) {
    if (!vm) return;
    vm->telemetry.telemetry_enabled = enabled;
}

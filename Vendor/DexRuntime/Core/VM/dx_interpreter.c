#include "../Include/dx_vm.h"
#include "../Include/dx_dex.h"
#include "../Include/dx_log.h"
#include "../Include/dx_runtime.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <mach/mach_time.h>

// Wall-clock milliseconds using Mach absolute time
static uint64_t dx_current_time_ms(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    uint64_t ns = mach_absolute_time() * tb.numer / tb.denom;
    return ns / 1000000ULL;
}

// Nanoseconds using Mach absolute time (for profiling)
static uint64_t dx_current_time_ns(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

#define TAG "Interp"

// Superinstruction optimization: fuse common 2-instruction patterns
// (e.g., const/4 + if-eqz) to avoid re-dispatch overhead.
#define USE_SUPERINSTRUCTIONS 1

// Computed goto (threaded dispatch) for interpreter speedup.
// Uses GCC/Clang's &&label extension; falls back to switch on other compilers.
#if defined(__GNUC__) || defined(__clang__)
#define USE_COMPUTED_GOTO 1
#else
#define USE_COMPUTED_GOTO 0
#endif

#include "../Include/dx_memory.h"

// Forward declaration for get_current_dex (defined below)
static DxDexFile *get_current_dex(DxVM *vm);

// ---- ULEB128 / SLEB128 readers for try/catch parsing ----

static uint32_t interp_read_uleb128(const uint8_t **pp) {
    const uint8_t *p = *pp;
    uint32_t result = 0;
    int shift = 0;
    uint8_t b;
    do {
        b = *p++;
        result |= (uint32_t)(b & 0x7F) << shift;
        shift += 7;
    } while (b & 0x80);
    *pp = p;
    return result;
}

static int32_t interp_read_sleb128(const uint8_t **pp) {
    const uint8_t *p = *pp;
    int32_t result = 0;
    int shift = 0;
    uint8_t b;
    do {
        b = *p++;
        result |= (int32_t)(b & 0x7F) << shift;
        shift += 7;
    } while (b & 0x80);
    // Sign extend
    if (shift < 32 && (b & 0x40)) {
        result |= -(1 << shift);
    }
    *pp = p;
    return result;
}

// DEX try_item structure (8 bytes each, after insns array)
typedef struct {
    uint32_t start_addr;       // start of try block (code unit offset)
    uint16_t try_insn_count;   // length of try block (code units)
    uint16_t handler_off;      // offset to encoded_catch_handler from handler list start
} DxTryItem;

// Search try/catch handlers for a matching handler at the given pc.
// Returns the handler address (code unit offset) or UINT32_MAX if no handler found.
// If found, stores the exception object in frame->exception.
static uint32_t find_catch_handler(DxVM *vm, DxFrame *frame, const uint16_t *insns,
                                    uint32_t insns_size, uint16_t tries_size,
                                    uint32_t throw_pc, DxObject *exception) {
    if (tries_size == 0) return UINT32_MAX;

    // Compute pointer to try_items: right after insns array, padded to 4-byte boundary
    const uint8_t *insns_end = (const uint8_t *)(insns + insns_size);
    // If insns_size is odd, there's 2 bytes of padding
    if (insns_size & 1) {
        insns_end += 2;
    }

    const uint8_t *try_data = insns_end;

    // Parse try_items to find one covering throw_pc
    uint16_t matched_handler_off = 0;
    bool found_try = false;
    for (uint16_t i = 0; i < tries_size; i++) {
        // Each try_item is 8 bytes: uint32_t start_addr, uint16_t insn_count, uint16_t handler_off
        const uint8_t *entry = try_data + (i * 8);
        uint32_t start_addr = (uint32_t)entry[0] | ((uint32_t)entry[1] << 8) | ((uint32_t)entry[2] << 16) | ((uint32_t)entry[3] << 24);
        uint16_t insn_count_val = (uint16_t)(entry[4] | (entry[5] << 8));
        uint16_t handler_off = (uint16_t)(entry[6] | (entry[7] << 8));

        if (throw_pc >= start_addr && throw_pc < start_addr + insn_count_val) {
            matched_handler_off = handler_off;
            found_try = true;
            break;
        }
    }

    if (!found_try) return UINT32_MAX;

    // Handler list starts right after all try_items
    const uint8_t *handlers_base = try_data + (tries_size * 8);
    const uint8_t *handler_ptr = handlers_base + matched_handler_off;

    // Parse encoded_catch_handler
    int32_t handler_size = interp_read_sleb128(&handler_ptr);
    bool has_catch_all = (handler_size <= 0);
    int32_t abs_size = handler_size < 0 ? -handler_size : handler_size;

    // Get the exception's type descriptor for matching
    const char *exc_descriptor = NULL;
    if (exception && exception->klass) {
        exc_descriptor = exception->klass->descriptor;
    }

    // Check each typed catch handler
    for (int32_t i = 0; i < abs_size; i++) {
        uint32_t type_idx = interp_read_uleb128(&handler_ptr);
        uint32_t addr = interp_read_uleb128(&handler_ptr);

        // Try to match the exception type
        DxDexFile *dex = get_current_dex(vm);
        const char *catch_type = NULL;
        if (dex && type_idx < dex->type_count) {
            catch_type = dx_dex_get_type(dex, type_idx);
        }

        if (catch_type && exc_descriptor) {
            // Exact match or catch java/lang/Throwable or java/lang/Exception (broad catches)
            if (strcmp(catch_type, exc_descriptor) == 0 ||
                strcmp(catch_type, "Ljava/lang/Throwable;") == 0 ||
                strcmp(catch_type, "Ljava/lang/Exception;") == 0) {
                DX_DEBUG(TAG, "Exception %s caught by handler at addr %u (type %s)",
                         exc_descriptor, addr, catch_type);
                frame->exception = exception;
                return addr;
            }

            // Walk the exception's class hierarchy for a match
            if (exception && exception->klass) {
                DxClass *cls = exception->klass->super_class;
                while (cls) {
                    if (cls->descriptor && strcmp(catch_type, cls->descriptor) == 0) {
                        DX_DEBUG(TAG, "Exception %s caught by handler at addr %u (super type %s)",
                                 exc_descriptor, addr, catch_type);
                        frame->exception = exception;
                        return addr;
                    }
                    cls = cls->super_class;
                }
            }
        }
    }

    // If there's a catch-all handler, use it
    if (has_catch_all) {
        uint32_t catch_all_addr = interp_read_uleb128(&handler_ptr);
        DX_DEBUG(TAG, "Exception %s caught by catch-all handler at addr %u",
                 exc_descriptor ? exc_descriptor : "unknown", catch_all_addr);
        frame->exception = exception;
        return catch_all_addr;
    }

    return UINT32_MAX;
}

// Find a catch-all (finally) handler covering the given pc.
// Unlike find_catch_handler, this does NOT require an exception — it is used
// on normal return paths to ensure finally blocks execute.
// Returns the handler address or UINT32_MAX if no catch-all covers this pc.
static uint32_t find_finally_handler(const uint16_t *insns, uint32_t insns_size,
                                      uint16_t tries_size, uint32_t pc) {
    if (tries_size == 0) return UINT32_MAX;

    const uint8_t *insns_end = (const uint8_t *)(insns + insns_size);
    if (insns_size & 1) {
        insns_end += 2;
    }
    const uint8_t *try_data = insns_end;

    // Search all try_items covering this pc
    for (uint16_t i = 0; i < tries_size; i++) {
        const uint8_t *entry = try_data + (i * 8);
        uint32_t start_addr = (uint32_t)entry[0] | ((uint32_t)entry[1] << 8) | ((uint32_t)entry[2] << 16) | ((uint32_t)entry[3] << 24);
        uint16_t insn_count_val = (uint16_t)(entry[4] | (entry[5] << 8));
        uint16_t handler_off = (uint16_t)(entry[6] | (entry[7] << 8));

        if (pc >= start_addr && pc < start_addr + insn_count_val) {
            // Parse encoded_catch_handler to check for catch-all
            const uint8_t *handlers_base = try_data + (tries_size * 8);
            const uint8_t *handler_ptr = handlers_base + handler_off;
            int32_t handler_size = interp_read_sleb128(&handler_ptr);
            bool has_catch_all = (handler_size <= 0);
            int32_t abs_size = handler_size < 0 ? -handler_size : handler_size;

            // Skip over typed handlers
            for (int32_t j = 0; j < abs_size; j++) {
                (void)interp_read_uleb128(&handler_ptr); // type_idx
                (void)interp_read_uleb128(&handler_ptr); // addr
            }

            if (has_catch_all) {
                uint32_t catch_all_addr = interp_read_uleb128(&handler_ptr);
                // Only return it if the handler is outside the try block range
                // (to avoid looping back into the same try block endlessly)
                if (catch_all_addr < start_addr || catch_all_addr >= start_addr + insn_count_val) {
                    return catch_all_addr;
                }
            }
        }
    }
    return UINT32_MAX;
}

// Decode register arguments from 35c format (invoke-kind)
static void decode_35c_args(const uint16_t *insns, uint32_t pc,
                             uint8_t *arg_count, uint8_t args[5]) {
    uint16_t inst = insns[pc];
    uint16_t arg_word = insns[pc + 2];

    *arg_count = (inst >> 12) & 0x0F;
    args[0] = arg_word & 0x0F;
    args[1] = (arg_word >> 4) & 0x0F;
    args[2] = (arg_word >> 8) & 0x0F;
    args[3] = (arg_word >> 12) & 0x0F;
    args[4] = (inst >> 8) & 0x0F;  // for 5-arg case, vG is in the A field
}

// Pack trailing arguments into an Object[] for varargs methods.
// fixed_params is the number of declared (non-varargs) parameters (excluding 'this').
// is_static: true if the method is static (no implicit 'this' argument).
// args/argc are the original arguments; on return they are rewritten in-place.
// Returns the new argc. The packed array is allocated on the VM heap.
static uint8_t pack_varargs(DxVM *vm, DxValue *args, uint8_t argc,
                            uint32_t fixed_params, bool is_static) {
    // 'this' occupies args[0] for instance methods
    uint32_t this_offset = is_static ? 0 : 1;
    // Index in args[] where the vararg values start
    uint32_t vararg_start = this_offset + fixed_params;

    if (vararg_start > argc) {
        // Fewer args than fixed params -- nothing to pack (shouldn't happen normally)
        return argc;
    }

    uint32_t vararg_count = argc - vararg_start;

    // Allocate an Object[] array on the VM heap
    DxObject *arr = dx_vm_alloc_array(vm, vararg_count);
    if (!arr) {
        // OOM -- leave args unchanged; the callee will see raw args
        return argc;
    }

    // Copy trailing args into the array
    for (uint32_t i = 0; i < vararg_count; i++) {
        arr->array_elements[i] = args[vararg_start + i];
    }

    // Replace the trailing args with the single array argument
    args[vararg_start] = DX_OBJ_VALUE(arr);
    return (uint8_t)(vararg_start + 1);
}

// Analyze a method to detect trivial getter/setter patterns for inlining.
// Getter pattern: iget-* vA, vB, field@CCCC + return-* vA (2 instructions)
// Setter pattern: iput-* vA, vB, field@CCCC + return-void (2 instructions)
void dx_method_analyze_inline(DxMethod *method) {
    if (method->analyzed_for_inline) return;
    method->analyzed_for_inline = true;
    method->inline_type = DX_INLINE_NONE;

    // Only analyze DEX methods with code, not native
    if (!method->has_code || method->is_native) return;
    if (!method->code.insns) return;

    // Must be exactly 2 code units (two 16-bit instructions) for getter
    // or exactly 2 code units for setter
    // iget family: 0x52-0x58 (22c, 2 code units each)
    // iput family: 0x59-0x5F (22c, 2 code units each)
    // return-void: 0x0E (10x, 1 code unit)
    // return: 0x0F (11x, 1 code unit)
    // return-wide: 0x10 (11x, 1 code unit)
    // return-object: 0x11 (11x, 1 code unit)
    // Getter = iget (2 units) + return (1 unit) = 3 code units total
    // Setter = iput (2 units) + return-void (1 unit) = 3 code units total
    uint32_t insns_size = method->code.insns_size;
    if (insns_size != 3) return;

    const uint16_t *insns = method->code.insns;
    uint8_t op0 = insns[0] & 0xFF;
    uint8_t op1 = insns[2] & 0xFF;

    // Check for getter: iget-* (0x52-0x58) followed by return-*/return-object (0x0F-0x11)
    if (op0 >= 0x52 && op0 <= 0x58) {
        uint8_t dst = (insns[0] >> 8) & 0x0F;
        uint16_t field_idx = insns[1];

        if (op1 >= 0x0F && op1 <= 0x11) {
            uint8_t ret_src = (insns[2] >> 8) & 0xFF;
            if (ret_src == dst) {
                method->inline_type = DX_INLINE_GETTER;
                method->inline_field_idx = field_idx;
                return;
            }
        }
    }

    // Check for setter: iput-* (0x59-0x5F) followed by return-void (0x0E)
    if (op0 >= 0x59 && op0 <= 0x5F) {
        uint16_t field_idx = insns[1];

        if (op1 == 0x0E) {
            method->inline_type = DX_INLINE_SETTER;
            method->inline_field_idx = field_idx;
            return;
        }
    }
}

// Resolve and execute an invoke instruction
static DxResult handle_invoke(DxVM *vm, DxFrame *frame, const uint16_t *code,
                                uint32_t pc, uint8_t opcode) {
    uint16_t method_idx = code[pc + 1];
    uint8_t argc;
    uint8_t arg_regs[5];
    decode_35c_args(code, pc, &argc, arg_regs);

    DxMethod *target = dx_vm_resolve_method(vm, method_idx);

    if (!target) {
        DxDexFile *cur = (frame->method && frame->method->declaring_class &&
                          frame->method->declaring_class->dex_file)
                         ? frame->method->declaring_class->dex_file : vm->dex;
        const char *cls_name = dx_dex_get_method_class(cur, method_idx);
        const char *mth_name = dx_dex_get_method_name(cur, method_idx);
        DX_WARN(TAG, "Cannot resolve method %s.%s - skipping",
                cls_name ? cls_name : "?", mth_name ? mth_name : "?");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // For invoke-virtual, resolve actual target from receiver's vtable
    // with inline cache optimization for monomorphic/polymorphic call sites
    if (opcode == 0x6E && argc > 0 && target->vtable_idx >= 0) {
        DxValue recv_val = frame->registers[arg_regs[0]];
        if (recv_val.tag == DX_VAL_OBJ && recv_val.obj) {
            DxObject *receiver = recv_val.obj;
            if (receiver->klass) {
                // Try inline cache first (keyed by caller method + PC)
                DxMethod *ic_result = NULL;
                DxInlineCache *ic = frame->method ? dx_vm_ic_get(frame->method, pc) : NULL;
                if (ic) {
                    ic_result = dx_vm_ic_lookup(ic, receiver->klass);
                }

                if (ic_result) {
                    // IC hit — use cached method directly, skip vtable walk
                    target = ic_result;
                } else {
                    // IC miss — do the full vtable lookup
                    if ((uint32_t)target->vtable_idx < receiver->klass->vtable_size) {
                        DxMethod *vtable_target = receiver->klass->vtable[target->vtable_idx];
                        if (vtable_target) target = vtable_target;
                    }
                    // Insert into inline cache for next time
                    if (ic) {
                        dx_vm_ic_insert(ic, receiver->klass, target);
                    }
                }
            }
        }
    }

    // For invoke-interface, dispatch on the receiver's actual class.
    // 1) Check if the concrete class (or its parents) overrides the method
    // 2) If not found, search implemented interfaces for a default method
    if (opcode == 0x72 && argc > 0) {
        DxValue recv_val = frame->registers[arg_regs[0]];
        if (recv_val.tag == DX_VAL_OBJ && recv_val.obj && recv_val.obj->klass) {
            DxClass *recv_cls = recv_val.obj->klass;
            // Try the receiver's class hierarchy first (concrete override)
            DxMethod *override = dx_vm_find_method(recv_cls, target->name, target->shorty);
            if (override) {
                target = override;
            } else {
                // Fall back to interface default method search
                DxMethod *iface_default = dx_vm_find_interface_method(vm, recv_cls,
                                                                        target->name, target->shorty);
                if (iface_default) target = iface_default;
            }
        }
        // If target is a bridge method, try to find the non-bridge version
        if ((target->access_flags & DX_ACC_BRIDGE) && target->declaring_class) {
            DxMethod *real = dx_vm_find_method(target->declaring_class, target->name, target->shorty);
            if (real && !(real->access_flags & DX_ACC_BRIDGE)) target = real;
        }
    }

    // For invoke-super, resolve on the declaring class's super (Dalvik semantics)
    // Walk up the entire superclass chain to find the method (grandparent etc.)
    if (opcode == 0x6F && argc > 0) {
        DxClass *declaring = target->declaring_class;
        DxMethod *original_target = target;
        bool super_found = false;
        if (declaring && declaring->super_class) {
            // Walk up the superclass hierarchy to find the method
            DxClass *walk = declaring->super_class;
            while (walk && !super_found) {
                DxMethod *super_method = dx_vm_find_method(walk, target->name, target->shorty);
                if (super_method && super_method != original_target) {
                    target = super_method;
                    super_found = true;
                }
                walk = walk->super_class;
            }
            // Fallback: try vtable lookup on receiver's super chain
            if (!super_found && target->vtable_idx >= 0) {
                DxValue recv_val = frame->registers[arg_regs[0]];
                if (recv_val.tag == DX_VAL_OBJ && recv_val.obj) {
                    DxObject *receiver = recv_val.obj;
                    DxClass *super = receiver->klass ? receiver->klass->super_class : NULL;
                    while (super && !super_found) {
                        if ((uint32_t)target->vtable_idx < super->vtable_size) {
                            DxMethod *vtbl = super->vtable[target->vtable_idx];
                            if (vtbl && vtbl != original_target) {
                                target = vtbl;
                                super_found = true;
                            }
                        }
                        super = super->super_class;
                    }
                }
            }
        }
        // If super method not found or resolves to self, skip to avoid infinite recursion
        if (!super_found) {
            DX_WARN(TAG, "invoke-super: method %s not found in %s hierarchy",
                    original_target->name,
                    original_target->declaring_class ? original_target->declaring_class->descriptor : "?");
            frame->result = DX_NULL_VALUE;
            frame->has_result = true;
            return DX_OK;
        }
    }

    // Build argument array
    DxValue call_args[5];
    for (uint8_t i = 0; i < argc && i < 5; i++) {
        call_args[i] = frame->registers[arg_regs[i]];
    }

    // Varargs packing: if target has ACC_VARARGS, pack trailing args into Object[]
    if ((target->access_flags & DX_ACC_VARARGS) && target->shorty) {
        uint32_t fixed_params = (uint32_t)(strlen(target->shorty) - 1); // shorty[0] is return type
        if (fixed_params > 0) fixed_params--; // last declared param is the varargs array
        bool is_static = (target->access_flags & DX_ACC_STATIC) != 0;
        argc = pack_varargs(vm, call_args, argc, fixed_params, is_static);
    }

    // Annotation element dispatch: when calling an abstract method on an annotation
    // object (e.g., @GET("/path").value()), look up the element from the DxAnnotationEntry
    // stored in the object's field[0].
    if (target && !target->has_code && !target->is_native
        && target->declaring_class
        && (target->declaring_class->access_flags & DX_ACC_ANNOTATION)
        && argc > 0 && call_args[0].tag == DX_VAL_OBJ && call_args[0].obj) {
        DxObject *anno_obj = call_args[0].obj;
        if (anno_obj->fields && anno_obj->fields[0].tag == DX_VAL_INT
            && anno_obj->fields[0].i != 0) {
            const DxAnnotationEntry *entry = (const DxAnnotationEntry *)(uintptr_t)anno_obj->fields[0].i;
            const char *elem_name = target->name;
            // Search annotation elements for a matching name
            for (uint32_t ei = 0; ei < entry->element_count; ei++) {
                if (entry->elements[ei].name && strcmp(entry->elements[ei].name, elem_name) == 0) {
                    const DxAnnotationElement *elem = &entry->elements[ei];
                    switch (elem->val_type) {
                        case DX_ANNO_VAL_STRING: {
                            DxObject *str = dx_vm_create_string(vm, elem->str_value ? elem->str_value : "");
                            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
                            break;
                        }
                        case DX_ANNO_VAL_BYTE:
                        case DX_ANNO_VAL_SHORT:
                        case DX_ANNO_VAL_CHAR:
                        case DX_ANNO_VAL_INT:
                        case DX_ANNO_VAL_BOOLEAN:
                            frame->result = DX_INT_VALUE(elem->i_value);
                            break;
                        case DX_ANNO_VAL_LONG:
                            frame->result = (DxValue){.tag = DX_VAL_LONG, .l = elem->l_value};
                            break;
                        case DX_ANNO_VAL_FLOAT:
                            frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = elem->f_value};
                            break;
                        case DX_ANNO_VAL_DOUBLE:
                            frame->result = (DxValue){.tag = DX_VAL_DOUBLE, .d = elem->d_value};
                            break;
                        case DX_ANNO_VAL_TYPE: {
                            DxObject *str = dx_vm_create_string(vm, elem->str_value ? elem->str_value : "");
                            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
                            break;
                        }
                        case DX_ANNO_VAL_ENUM: {
                            DxObject *str = dx_vm_create_string(vm, elem->str_value ? elem->str_value : "");
                            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
                            break;
                        }
                        default:
                            frame->result = DX_NULL_VALUE;
                            break;
                    }
                    frame->has_result = true;
                    return DX_OK;
                }
            }
        }
        // Also handle annotationType() for annotation objects
        if (strcmp(target->name, "annotationType") == 0) {
            DxClass *class_cls = dx_vm_find_class(vm, "Ljava/lang/Class;");
            if (class_cls) {
                DxObject *cls_obj = dx_vm_alloc_object(vm, class_cls);
                if (cls_obj && cls_obj->fields && class_cls->instance_field_count > 0) {
                    cls_obj->fields[0].tag = DX_VAL_INT;
                    cls_obj->fields[0].i = (int32_t)(uintptr_t)anno_obj->klass;
                }
                frame->result = cls_obj ? DX_OBJ_VALUE(cls_obj) : DX_NULL_VALUE;
            } else {
                frame->result = DX_NULL_VALUE;
            }
            frame->has_result = true;
            return DX_OK;
        }
    }

    // Method inlining: skip frame creation for trivial getters/setters
    if (!target->analyzed_for_inline) {
        dx_method_analyze_inline(target);
    }
    if (target->inline_type == DX_INLINE_GETTER && argc >= 1) {
        // Inline getter: iget field from receiver, return value directly
        DxValue recv_val = call_args[0];
        DxObject *obj = (recv_val.tag == DX_VAL_OBJ) ? recv_val.obj : NULL;
        if (obj) {
            DxDexFile *cur = (frame->method && frame->method->declaring_class &&
                              frame->method->declaring_class->dex_file)
                             ? frame->method->declaring_class->dex_file : vm->dex;
            const char *fname = dx_dex_get_field_name(cur, target->inline_field_idx);
            DxValue val;
            if (fname && dx_vm_get_field(obj, fname, &val) == DX_OK) {
                frame->result = val;
            } else {
                frame->result = DX_NULL_VALUE;
            }
        } else {
            frame->result = DX_NULL_VALUE;
        }
        frame->has_result = true;
        return DX_OK;
    }
    if (target->inline_type == DX_INLINE_SETTER && argc >= 2) {
        // Inline setter: iput value into receiver field, return void
        // args[0] = this (receiver object), args[1] = value to store
        DxValue recv_val = call_args[0];
        DxObject *obj = (recv_val.tag == DX_VAL_OBJ) ? recv_val.obj : NULL;
        if (obj) {
            DxDexFile *cur = (frame->method && frame->method->declaring_class &&
                              frame->method->declaring_class->dex_file)
                             ? frame->method->declaring_class->dex_file : vm->dex;
            const char *fname = dx_dex_get_field_name(cur, target->inline_field_idx);
            if (fname) {
                dx_vm_set_field(obj, fname, call_args[1]);
            }
        }
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxValue call_result;
    memset(&call_result, 0, sizeof(call_result));
    DxResult res = dx_vm_execute_method(vm, target, call_args, argc, &call_result);

    // Store result for move-result
    frame->result = call_result;
    frame->has_result = true;

    // Exception unwinding: callee threw and didn't catch — try our catch handlers
    if (res == DX_ERR_EXCEPTION && vm->pending_exception) {
        DxObject *exc = vm->pending_exception;
        const char *exc_class = exc->klass ? exc->klass->descriptor : "unknown";
        DxMethod *caller_method = frame->method;
        if (caller_method && caller_method->code.tries_size > 0) {
            uint32_t handler_addr = find_catch_handler(vm, frame,
                caller_method->code.insns, caller_method->code.insns_size,
                caller_method->code.tries_size, pc, exc);
            if (handler_addr != UINT32_MAX) {
                DX_INFO(TAG, "Exception %s unwound to %s.%s handler at %u",
                        exc_class,
                        caller_method->declaring_class ? caller_method->declaring_class->descriptor : "?",
                        caller_method->name, handler_addr);
                vm->pending_exception = NULL;
                frame->pc = handler_addr;
                return DX_OK; // caller must jump to handler_addr
            }
        }
        // No handler here either — keep propagating
        DX_DEBUG(TAG, "Exception %s not caught in %s.%s, propagating further",
                exc_class,
                caller_method ? (caller_method->declaring_class ? caller_method->declaring_class->descriptor : "?") : "?",
                caller_method ? caller_method->name : "?");
        return DX_ERR_EXCEPTION;
    }

    // Non-fatal errors from sub-calls: log and continue execution
    if (res != DX_OK && res != DX_ERR_STACK_OVERFLOW) {
        DX_WARN(TAG, "Method %s.%s returned %s (absorbed)",
                target->declaring_class ? target->declaring_class->descriptor : "?",
                target->name, dx_result_string(res));
        return DX_OK;
    }
    return res;
}

// Resolve and execute an invoke/range instruction
static DxResult handle_invoke_range(DxVM *vm, DxFrame *frame, const uint16_t *code,
                                      uint32_t pc, uint8_t opcode) {
    uint16_t method_idx = code[pc + 1];
    uint16_t inst = code[pc];
    uint8_t argc = (inst >> 8) & 0xFF;
    uint16_t first_reg = code[pc + 2];

    DxMethod *target = dx_vm_resolve_method(vm, method_idx);

    if (!target) {
        DxDexFile *cur = (frame->method && frame->method->declaring_class &&
                          frame->method->declaring_class->dex_file)
                         ? frame->method->declaring_class->dex_file : vm->dex;
        const char *cls_name = dx_dex_get_method_class(cur, method_idx);
        const char *mth_name = dx_dex_get_method_name(cur, method_idx);
        DX_WARN(TAG, "Cannot resolve method %s.%s (range) - skipping",
                cls_name ? cls_name : "?", mth_name ? mth_name : "?");
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    // vtable dispatch for invoke-virtual/range
    // with inline cache optimization for monomorphic/polymorphic call sites
    if (opcode == 0x74 && argc > 0 && target->vtable_idx >= 0) {
        DxValue recv_val = frame->registers[first_reg];
        if (recv_val.tag == DX_VAL_OBJ && recv_val.obj) {
            DxObject *receiver = recv_val.obj;
            if (receiver->klass) {
                // Try inline cache first
                DxMethod *ic_result = NULL;
                DxInlineCache *ic = frame->method ? dx_vm_ic_get(frame->method, pc) : NULL;
                if (ic) {
                    ic_result = dx_vm_ic_lookup(ic, receiver->klass);
                }

                if (ic_result) {
                    // IC hit — skip vtable walk
                    target = ic_result;
                } else {
                    // IC miss — full vtable lookup
                    if ((uint32_t)target->vtable_idx < receiver->klass->vtable_size) {
                        DxMethod *vt = receiver->klass->vtable[target->vtable_idx];
                        if (vt) target = vt;
                    }
                    // Update inline cache
                    if (ic) {
                        dx_vm_ic_insert(ic, receiver->klass, target);
                    }
                }
            }
        }
    }

    // invoke-interface/range: dispatch on receiver's actual class + interface defaults
    if (opcode == 0x78 && argc > 0) {
        DxValue recv_val = frame->registers[first_reg];
        if (recv_val.tag == DX_VAL_OBJ && recv_val.obj && recv_val.obj->klass) {
            DxClass *recv_cls = recv_val.obj->klass;
            DxMethod *override = dx_vm_find_method(recv_cls, target->name, target->shorty);
            if (override) {
                target = override;
            } else {
                DxMethod *iface_default = dx_vm_find_interface_method(vm, recv_cls,
                                                                        target->name, target->shorty);
                if (iface_default) target = iface_default;
            }
        }
        // Bridge method unwrap
        if ((target->access_flags & DX_ACC_BRIDGE) && target->declaring_class) {
            DxMethod *real = dx_vm_find_method(target->declaring_class, target->name, target->shorty);
            if (real && !(real->access_flags & DX_ACC_BRIDGE)) target = real;
        }
    }

    // invoke-super/range: resolve on declaring class's superclass (Dalvik semantics)
    // Walk up the entire superclass chain to find the method (grandparent etc.)
    if (opcode == 0x75 && argc > 0) {
        DxClass *declaring = target->declaring_class;
        DxMethod *original_target = target;
        bool super_found = false;
        if (declaring && declaring->super_class) {
            // Walk up the superclass hierarchy
            DxClass *walk = declaring->super_class;
            while (walk && !super_found) {
                DxMethod *super_method = dx_vm_find_method(walk, target->name, target->shorty);
                if (super_method && super_method != original_target) {
                    target = super_method;
                    super_found = true;
                }
                walk = walk->super_class;
            }
            // Fallback: try vtable lookup on receiver's super chain
            if (!super_found && target->vtable_idx >= 0) {
                DxValue recv_val = frame->registers[first_reg];
                if (recv_val.tag == DX_VAL_OBJ && recv_val.obj) {
                    DxObject *receiver = recv_val.obj;
                    DxClass *super = receiver->klass ? receiver->klass->super_class : NULL;
                    while (super && !super_found) {
                        if ((uint32_t)target->vtable_idx < super->vtable_size) {
                            DxMethod *vtbl = super->vtable[target->vtable_idx];
                            if (vtbl && vtbl != original_target) {
                                target = vtbl;
                                super_found = true;
                            }
                        }
                        super = super->super_class;
                    }
                }
            }
        }
        if (!super_found) {
            DX_WARN(TAG, "invoke-super/range: method %s not found in %s hierarchy",
                    original_target->name,
                    original_target->declaring_class ? original_target->declaring_class->descriptor : "?");
            frame->result = DX_NULL_VALUE;
            frame->has_result = true;
            return DX_OK;
        }
    }

    // Build argument array on the stack (max 255 args but clamp for safety)
    uint8_t clamped_argc = argc > 16 ? 16 : argc;
    DxValue call_args[16];
    memset(call_args, 0, sizeof(call_args));
    for (uint8_t i = 0; i < clamped_argc; i++) {
        uint16_t reg = first_reg + i;
        if (reg < DX_MAX_REGISTERS) {
            call_args[i] = frame->registers[reg];
        }
    }

    // Varargs packing: if target has ACC_VARARGS, pack trailing args into Object[]
    if ((target->access_flags & DX_ACC_VARARGS) && target->shorty) {
        uint32_t fixed_params = (uint32_t)(strlen(target->shorty) - 1);
        if (fixed_params > 0) fixed_params--; // last declared param is the varargs array
        bool is_static = (target->access_flags & DX_ACC_STATIC) != 0;
        clamped_argc = pack_varargs(vm, call_args, clamped_argc, fixed_params, is_static);
    }

    // Annotation element dispatch (range variant)
    if (target && !target->has_code && !target->is_native
        && target->declaring_class
        && (target->declaring_class->access_flags & DX_ACC_ANNOTATION)
        && clamped_argc > 0 && call_args[0].tag == DX_VAL_OBJ && call_args[0].obj) {
        DxObject *anno_obj = call_args[0].obj;
        if (anno_obj->fields && anno_obj->fields[0].tag == DX_VAL_INT
            && anno_obj->fields[0].i != 0) {
            const DxAnnotationEntry *entry = (const DxAnnotationEntry *)(uintptr_t)anno_obj->fields[0].i;
            const char *elem_name = target->name;
            for (uint32_t ei = 0; ei < entry->element_count; ei++) {
                if (entry->elements[ei].name && strcmp(entry->elements[ei].name, elem_name) == 0) {
                    const DxAnnotationElement *elem = &entry->elements[ei];
                    switch (elem->val_type) {
                        case DX_ANNO_VAL_STRING: {
                            DxObject *str = dx_vm_create_string(vm, elem->str_value ? elem->str_value : "");
                            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
                            break;
                        }
                        case DX_ANNO_VAL_BYTE: case DX_ANNO_VAL_SHORT: case DX_ANNO_VAL_CHAR:
                        case DX_ANNO_VAL_INT: case DX_ANNO_VAL_BOOLEAN:
                            frame->result = DX_INT_VALUE(elem->i_value);
                            break;
                        case DX_ANNO_VAL_LONG:
                            frame->result = (DxValue){.tag = DX_VAL_LONG, .l = elem->l_value};
                            break;
                        case DX_ANNO_VAL_FLOAT:
                            frame->result = (DxValue){.tag = DX_VAL_FLOAT, .f = elem->f_value};
                            break;
                        case DX_ANNO_VAL_DOUBLE:
                            frame->result = (DxValue){.tag = DX_VAL_DOUBLE, .d = elem->d_value};
                            break;
                        case DX_ANNO_VAL_TYPE:
                        case DX_ANNO_VAL_ENUM: {
                            DxObject *str = dx_vm_create_string(vm, elem->str_value ? elem->str_value : "");
                            frame->result = str ? DX_OBJ_VALUE(str) : DX_NULL_VALUE;
                            break;
                        }
                        default:
                            frame->result = DX_NULL_VALUE;
                            break;
                    }
                    frame->has_result = true;
                    return DX_OK;
                }
            }
        }
        if (strcmp(target->name, "annotationType") == 0) {
            DxClass *class_cls = dx_vm_find_class(vm, "Ljava/lang/Class;");
            if (class_cls) {
                DxObject *cls_obj = dx_vm_alloc_object(vm, class_cls);
                if (cls_obj && cls_obj->fields && class_cls->instance_field_count > 0) {
                    cls_obj->fields[0].tag = DX_VAL_INT;
                    cls_obj->fields[0].i = (int32_t)(uintptr_t)anno_obj->klass;
                }
                frame->result = cls_obj ? DX_OBJ_VALUE(cls_obj) : DX_NULL_VALUE;
            } else {
                frame->result = DX_NULL_VALUE;
            }
            frame->has_result = true;
            return DX_OK;
        }
    }

    // Method inlining: skip frame creation for trivial getters/setters
    if (!target->analyzed_for_inline) {
        dx_method_analyze_inline(target);
    }
    if (target->inline_type == DX_INLINE_GETTER && clamped_argc >= 1) {
        DxValue recv_val = call_args[0];
        DxObject *obj = (recv_val.tag == DX_VAL_OBJ) ? recv_val.obj : NULL;
        if (obj) {
            DxDexFile *cur = (frame->method && frame->method->declaring_class &&
                              frame->method->declaring_class->dex_file)
                             ? frame->method->declaring_class->dex_file : vm->dex;
            const char *fname = dx_dex_get_field_name(cur, target->inline_field_idx);
            DxValue val;
            if (fname && dx_vm_get_field(obj, fname, &val) == DX_OK) {
                frame->result = val;
            } else {
                frame->result = DX_NULL_VALUE;
            }
        } else {
            frame->result = DX_NULL_VALUE;
        }
        frame->has_result = true;
        return DX_OK;
    }
    if (target->inline_type == DX_INLINE_SETTER && clamped_argc >= 2) {
        DxValue recv_val = call_args[0];
        DxObject *obj = (recv_val.tag == DX_VAL_OBJ) ? recv_val.obj : NULL;
        if (obj) {
            DxDexFile *cur = (frame->method && frame->method->declaring_class &&
                              frame->method->declaring_class->dex_file)
                             ? frame->method->declaring_class->dex_file : vm->dex;
            const char *fname = dx_dex_get_field_name(cur, target->inline_field_idx);
            if (fname) {
                dx_vm_set_field(obj, fname, call_args[1]);
            }
        }
        frame->result = DX_NULL_VALUE;
        frame->has_result = true;
        return DX_OK;
    }

    DxValue call_result;
    memset(&call_result, 0, sizeof(call_result));
    DxResult res = dx_vm_execute_method(vm, target, call_args, clamped_argc, &call_result);

    frame->result = call_result;
    frame->has_result = true;

    // Exception unwinding: callee threw and didn't catch — try our catch handlers
    if (res == DX_ERR_EXCEPTION && vm->pending_exception) {
        DxObject *exc = vm->pending_exception;
        const char *exc_class = exc->klass ? exc->klass->descriptor : "unknown";
        DxMethod *caller_method = frame->method;
        if (caller_method && caller_method->code.tries_size > 0) {
            uint32_t handler_addr = find_catch_handler(vm, frame,
                caller_method->code.insns, caller_method->code.insns_size,
                caller_method->code.tries_size, pc, exc);
            if (handler_addr != UINT32_MAX) {
                DX_INFO(TAG, "Exception %s unwound to %s.%s handler at %u (range)",
                        exc_class,
                        caller_method->declaring_class ? caller_method->declaring_class->descriptor : "?",
                        caller_method->name, handler_addr);
                vm->pending_exception = NULL;
                frame->pc = handler_addr;
                return DX_OK;
            }
        }
        DX_DEBUG(TAG, "Exception %s not caught in %s.%s, propagating further (range)",
                exc_class,
                caller_method ? (caller_method->declaring_class ? caller_method->declaring_class->descriptor : "?") : "?",
                caller_method ? caller_method->name : "?");
        return DX_ERR_EXCEPTION;
    }

    if (res != DX_OK && res != DX_ERR_STACK_OVERFLOW) {
        DX_WARN(TAG, "Method %s.%s (range) returned %s (absorbed)",
                target->declaring_class ? target->declaring_class->descriptor : "?",
                target->name, dx_result_string(res));
        return DX_OK;
    }
    return res;
}

// Get the DEX file for the currently executing method
static DxDexFile *get_current_dex(DxVM *vm) {
    if (vm->current_frame && vm->current_frame->method &&
        vm->current_frame->method->declaring_class &&
        vm->current_frame->method->declaring_class->dex_file) {
        return vm->current_frame->method->declaring_class->dex_file;
    }
    return vm->dex;
}

// Find the static field index within a class's DEX-defined static fields
static int32_t find_static_field_idx(DxVM *vm, DxClass *cls, const char *fname) {
    if (!cls || !vm || !fname) return -1;

    // Framework classes with field_defs: look up by name directly
    if (cls->is_framework) {
        if (cls->field_defs && cls->static_field_count > 0) {
            for (uint32_t i = 0; i < cls->static_field_count; i++) {
                if (cls->field_defs[i].name && strcmp(cls->field_defs[i].name, fname) == 0) {
                    return (int32_t)i;
                }
            }
        }
        return -1;
    }

    // Walk class hierarchy to find the field in the declaring class
    while (cls && !cls->is_framework) {
        DxDexFile *dex = cls->dex_file ? cls->dex_file : vm->dex;
        if (dex && cls->dex_class_def_idx < dex->class_count) {
            DxDexClassData *cd = dex->class_data[cls->dex_class_def_idx];
            if (cd) {
                for (uint32_t i = 0; i < cd->static_fields_count; i++) {
                    const char *name = dx_dex_get_field_name(dex, cd->static_fields[i].field_idx);
                    if (name && strcmp(name, fname) == 0) {
                        return (int32_t)i;
                    }
                }
            }
        }
        cls = cls->super_class;
    }
    return -1;
}

// Static field get/set helpers
static DxResult handle_sget(DxVM *vm, DxFrame *frame, uint8_t dst, uint16_t field_idx, bool is_object) {
    DxDexFile *dex = get_current_dex(vm);
    const char *fname = dx_dex_get_field_name(dex, field_idx);
    const char *fclass = dx_dex_get_field_class(dex, field_idx);

    DxClass *cls = dx_vm_find_class(vm, fclass);
    if (!cls) {
        dx_vm_load_class(vm, fclass, &cls);
    }

    if (cls && cls->static_fields && cls->static_field_count > 0) {
        int32_t idx = find_static_field_idx(vm, cls, fname);
        if (idx >= 0 && (uint32_t)idx < cls->static_field_count) {
            frame->registers[dst] = cls->static_fields[idx];
            return DX_OK;
        }
    }

    // Field not found or framework class - return default
    frame->registers[dst] = is_object ? DX_NULL_VALUE : DX_INT_VALUE(0);
    return DX_OK;
}

static DxResult handle_sput(DxVM *vm, DxFrame *frame, uint8_t src, uint16_t field_idx, bool is_object) {
    DxDexFile *dex = get_current_dex(vm);
    const char *fname = dx_dex_get_field_name(dex, field_idx);
    const char *fclass = dx_dex_get_field_class(dex, field_idx);
    (void)is_object;

    DxClass *cls = dx_vm_find_class(vm, fclass);
    if (!cls) {
        dx_vm_load_class(vm, fclass, &cls);
    }

    if (cls && cls->static_fields && cls->static_field_count > 0) {
        int32_t idx = find_static_field_idx(vm, cls, fname);
        if (idx >= 0 && (uint32_t)idx < cls->static_field_count) {
            cls->static_fields[idx] = frame->registers[src];
            return DX_OK;
        }
    }

    // Field not found or framework class - silently absorb
    DX_TRACE(TAG, "sput %s.%s (absorbed)", fclass ? fclass : "?", fname ? fname : "?");
    return DX_OK;
}

DxResult dx_vm_execute_method(DxVM *vm, DxMethod *method, DxValue *args,
                               uint32_t arg_count, DxValue *result) {
    if (!vm || !method) return DX_ERR_NULL_PTR;

    // Start watchdog timer on top-level call (stack_depth == 0)
    if (vm->watchdog_timeout_ms > 0 && vm->watchdog_start_time == 0) {
        vm->watchdog_start_time = dx_current_time_ms();
        vm->watchdog_triggered = false;
    }

    // Profiling: record method entry time
    uint64_t _prof_start_ns = 0;
    if (vm->profiling_enabled) {
        _prof_start_ns = dx_current_time_ns();
    }

    // Debug tracing: method entry
    const char *_trace_cls = method->declaring_class ? method->declaring_class->descriptor : "?";
    const char *_trace_mth = method->name ? method->name : "?";
    bool _trace_method_active = false;
    if (vm->debug.method_call_trace) {
        bool passes_filter = true;
        if (vm->debug.trace_method_filter) {
            passes_filter = (strncmp(_trace_cls, vm->debug.trace_method_filter,
                                     strlen(vm->debug.trace_method_filter)) == 0);
        }
        if (passes_filter) {
            _trace_method_active = true;
            DX_INFO("Trace", "%*sENTER %s->%s (depth=%d, args=%u)",
                    vm->debug.trace_depth * 2, "", _trace_cls, _trace_mth,
                    vm->debug.trace_depth, arg_count);
            vm->debug.trace_depth++;
        }
    }

    // Check call depth BEFORE allocating stack frame to prevent stack overflow
    if (vm->stack_depth >= DX_MAX_STACK_DEPTH) {
        DX_ERROR(TAG, "Stack overflow at %s.%s (depth %u)",
                 method->declaring_class ? method->declaring_class->descriptor : "?",
                 method->name, vm->stack_depth);
        if (_trace_method_active) vm->debug.trace_depth--;
        return DX_ERR_STACK_OVERFLOW;
    }

    // Detect infinite recursion: same method pointer appearing too many times
    {
        uint32_t recur_count = 0;
        DxFrame *f = vm->current_frame;
        while (f && recur_count <= 8) {
            if (f->method == method) recur_count++;
            f = f->caller;
        }
        if (recur_count > 8) {
            DX_WARN(TAG, "Recursion limit for %s.%s (%u occurrences) - skipping",
                     method->declaring_class ? method->declaring_class->descriptor : "?",
                     method->name, recur_count);
            if (result) *result = DX_NULL_VALUE;
            return DX_OK;
        }
    }

    DX_DEBUG(TAG, ">> %s.%s %s",
             method->declaring_class ? method->declaring_class->descriptor : "?",
             method->name, method->shorty ? method->shorty : "");

    // Telemetry: count method invocations
    if (vm->telemetry.telemetry_enabled) {
        vm->telemetry.total_methods_invoked++;
    }

    // Handle native methods
    if (method->is_native) {
        if (!method->native_fn) {
            DX_ERROR(TAG, "Native method has no implementation: %s.%s",
                     method->declaring_class->descriptor, method->name);
            return DX_ERR_METHOD_NOT_FOUND;
        }

        DxFrame *frame = dx_vm_alloc_frame(vm);
        if (!frame) return DX_ERR_OUT_OF_MEMORY;
        frame->method = method;
        frame->caller = vm->current_frame;

        for (uint32_t i = 0; i < arg_count && i < DX_MAX_REGISTERS; i++) {
            frame->registers[i] = args[i];
        }

        vm->current_frame = frame;
        vm->stack_depth++;

        DxResult res = method->native_fn(vm, frame, args, arg_count);

        vm->stack_depth--;
        vm->current_frame = frame->caller;

        if (result && frame->has_result) {
            *result = frame->result;
        }

        DX_DEBUG(TAG, "<< %s.%s (native) -> %s",
                 method->declaring_class->descriptor, method->name,
                 dx_result_string(res));
        if (_trace_method_active) {
            vm->debug.trace_depth--;
            DX_INFO("Trace", "%*sEXIT  %s->%s (native, result=%s)",
                    vm->debug.trace_depth * 2, "", _trace_cls, _trace_mth,
                    dx_result_string(res));
        }
        dx_vm_free_frame(vm, frame);
        return res;
    }

    // Bytecode interpretation — if method has no code (abstract/interface), skip gracefully
    if (!method->has_code) {
        DX_WARN(TAG, "Method has no code: %s.%s (skipping)",
                 method->declaring_class ? method->declaring_class->descriptor : "?",
                 method->name);
        if (_trace_method_active) {
            vm->debug.trace_depth--;
            DX_INFO("Trace", "%*sEXIT  %s->%s (no code)",
                    vm->debug.trace_depth * 2, "", _trace_cls, _trace_mth);
        }
        if (result) *result = DX_NULL_VALUE;
        return DX_OK;
    }

    // Validate code_item before using it — corrupt or missing insns pointer
    // would cause immediate segfault in the hot path
    if (!method->code.insns || method->code.insns_size == 0) {
        DX_ERROR(TAG, "Method %s.%s has_code=true but insns is NULL or insns_size=0",
                 method->declaring_class ? method->declaring_class->descriptor : "?",
                 method->name ? method->name : "?");
        if (_trace_method_active) vm->debug.trace_depth--;
        return DX_ERR_VERIFICATION_FAILED;
    }

    DxFrame *frame = dx_vm_alloc_frame(vm);
    if (!frame) return DX_ERR_OUT_OF_MEMORY;

    frame->method = method;
    frame->caller = vm->current_frame;

    // Place arguments in the last N registers (Dalvik convention)
    uint16_t regs = method->code.registers_size;
    uint16_t ins = method->code.ins_size;

    // Bounds check: registers_size must accommodate ins_size
    if (regs > DX_MAX_REGISTERS) regs = DX_MAX_REGISTERS;
    if (ins > regs) ins = regs;

    uint16_t first_arg_reg = regs - ins;
    for (uint32_t i = 0; i < arg_count && i < ins; i++) {
        frame->registers[first_arg_reg + i] = args[i];
    }

    vm->current_frame = frame;
    vm->stack_depth++;

    const uint16_t *code = method->code.insns;
    uint32_t code_size = method->code.insns_size;
    uint32_t pc = 0;
    DxDexFile *cur_dex = get_current_dex(vm);

    // Register file pinning: keep frequently dereferenced pointers in locals
    // to avoid repeated indirection through frame-> and method-> on every opcode.
    // The compiler may already do this, but explicit pinning ensures it across
    // all optimization levels and prevents re-loads after calls that may alias.
    DxValue *pinned_regs = frame->registers;
    const uint16_t *pinned_code = code;
    uint32_t pinned_code_size = code_size;
    // Suppress unused warnings — pinned_code/pinned_code_size mirror code/code_size
    (void)pinned_code;
    (void)pinned_code_size;

    DxResult exec_result = DX_OK;
    uint32_t null_access_count = 0;  // total iget/iput on null counter (not reset)

    // Register bounds checking macro: validates register index against declared count.
    // On violation, captures diagnostic and aborts the method with VERIFICATION_FAILED.
    #define CHECK_REG(idx) do { \
        if ((uint32_t)(idx) >= regs) { \
            DX_ERROR(TAG, "Register v%u out of bounds (registers_size=%u) at pc=%u in %s.%s op=0x%02x", \
                     (uint32_t)(idx), (uint32_t)regs, pc, \
                     method->declaring_class ? method->declaring_class->descriptor : "?", \
                     method->name ? method->name : "?", opcode); \
            snprintf(vm->error_msg, sizeof(vm->error_msg), \
                     "Register v%u out of bounds (max v%u) at pc=%u in %s.%s", \
                     (uint32_t)(idx), (uint32_t)(regs - 1), pc, \
                     method->declaring_class ? method->declaring_class->descriptor : "?", \
                     method->name ? method->name : "?"); \
            exec_result = DX_ERR_VERIFICATION_FAILED; \
            goto done; \
        } \
    } while (0)

    // Instruction trace ring buffer for watchdog diagnostics
    #define INSN_TRACE_SIZE 16
    struct { uint32_t pc; uint8_t opcode; } insn_trace[INSN_TRACE_SIZE];
    uint32_t insn_trace_idx = 0;

    // Macro for safe code access with bounds check
    #define CODE_AT(off) ((pc + (off)) < code_size ? code[pc + (off)] : 0)

#if USE_COMPUTED_GOTO
    // Threaded interpreter dispatch table - one entry per Dalvik opcode
    static const void *dispatch_table[256] = {
        [0x00] = &&op_0x00,
        [0x01] = &&op_0x01,
        [0x02] = &&op_0x02,
        [0x03] = &&op_0x03,
        [0x04] = &&op_0x04,
        [0x05] = &&op_0x05,
        [0x06] = &&op_0x06,
        [0x07] = &&op_0x07,
        [0x08] = &&op_0x08,
        [0x09] = &&op_0x09,
        [0x0A] = &&op_0x0A,
        [0x0B] = &&op_0x0B,
        [0x0C] = &&op_0x0C,
        [0x0D] = &&op_0x0D,
        [0x0E] = &&op_0x0E,
        [0x0F] = &&op_0x0F,
        [0x10] = &&op_0x10,
        [0x11] = &&op_0x11,
        [0x12] = &&op_0x12,
        [0x13] = &&op_0x13,
        [0x14] = &&op_0x14,
        [0x15] = &&op_0x15,
        [0x16] = &&op_0x16,
        [0x17] = &&op_0x17,
        [0x18] = &&op_0x18,
        [0x19] = &&op_0x19,
        [0x1A] = &&op_0x1A,
        [0x1B] = &&op_0x1B,
        [0x1C] = &&op_0x1C,
        [0x1D] = &&op_0x1D,
        [0x1E] = &&op_0x1E,
        [0x1F] = &&op_0x1F,
        [0x20] = &&op_0x20,
        [0x21] = &&op_0x21,
        [0x22] = &&op_0x22,
        [0x23] = &&op_0x23,
        [0x24] = &&op_0x24,
        [0x25] = &&op_0x25,
        [0x26] = &&op_0x26,
        [0x27] = &&op_0x27,
        [0x28] = &&op_0x28,
        [0x29] = &&op_0x29,
        [0x2A] = &&op_0x2A,
        [0x2B] = &&op_0x2B,
        [0x2C] = &&op_0x2C,
        [0x2D] = &&op_0x2D,
        [0x2E] = &&op_0x2E,
        [0x2F] = &&op_0x2F,
        [0x30] = &&op_0x30,
        [0x31] = &&op_0x31,
        [0x32] = &&op_0x32,
        [0x33] = &&op_0x33,
        [0x34] = &&op_0x34,
        [0x35] = &&op_0x35,
        [0x36] = &&op_0x36,
        [0x37] = &&op_0x37,
        [0x38] = &&op_0x38,
        [0x39] = &&op_0x39,
        [0x3A] = &&op_0x3A,
        [0x3B] = &&op_0x3B,
        [0x3C] = &&op_0x3C,
        [0x3D] = &&op_0x3D,
        [0x3E] = &&op_default,
        [0x3F] = &&op_default,
        [0x40] = &&op_default,
        [0x41] = &&op_default,
        [0x42] = &&op_default,
        [0x43] = &&op_default,
        [0x44] = &&op_0x44,
        [0x45] = &&op_0x45,
        [0x46] = &&op_0x46,
        [0x47] = &&op_0x47,
        [0x48] = &&op_0x48,
        [0x49] = &&op_0x49,
        [0x4A] = &&op_0x4A,
        [0x4B] = &&op_0x4B,
        [0x4C] = &&op_0x4C,
        [0x4D] = &&op_0x4D,
        [0x4E] = &&op_0x4E,
        [0x4F] = &&op_0x4F,
        [0x50] = &&op_0x50,
        [0x51] = &&op_0x51,
        [0x52] = &&op_0x52,
        [0x53] = &&op_0x53,
        [0x54] = &&op_0x54,
        [0x55] = &&op_0x55,
        [0x56] = &&op_0x56,
        [0x57] = &&op_0x57,
        [0x58] = &&op_0x58,
        [0x59] = &&op_0x59,
        [0x5A] = &&op_0x5A,
        [0x5B] = &&op_0x5B,
        [0x5C] = &&op_0x5C,
        [0x5D] = &&op_0x5D,
        [0x5E] = &&op_0x5E,
        [0x5F] = &&op_0x5F,
        [0x60] = &&op_0x60,
        [0x61] = &&op_0x61,
        [0x62] = &&op_0x62,
        [0x63] = &&op_0x63,
        [0x64] = &&op_0x64,
        [0x65] = &&op_0x65,
        [0x66] = &&op_0x66,
        [0x67] = &&op_0x67,
        [0x68] = &&op_0x68,
        [0x69] = &&op_0x69,
        [0x6A] = &&op_0x6A,
        [0x6B] = &&op_0x6B,
        [0x6C] = &&op_0x6C,
        [0x6D] = &&op_0x6D,
        [0x6E] = &&op_0x6E,
        [0x6F] = &&op_0x6F,
        [0x70] = &&op_0x70,
        [0x71] = &&op_0x71,
        [0x72] = &&op_0x72,
        [0x73] = &&op_default,
        [0x74] = &&op_0x74,
        [0x75] = &&op_0x75,
        [0x76] = &&op_0x76,
        [0x77] = &&op_0x77,
        [0x78] = &&op_0x78,
        [0x79] = &&op_default,
        [0x7A] = &&op_default,
        [0x7B] = &&op_0x7B,
        [0x7C] = &&op_0x7C,
        [0x7D] = &&op_0x7D,
        [0x7E] = &&op_0x7E,
        [0x7F] = &&op_0x7F,
        [0x80] = &&op_0x80,
        [0x81] = &&op_0x81,
        [0x82] = &&op_0x82,
        [0x83] = &&op_0x83,
        [0x84] = &&op_0x84,
        [0x85] = &&op_0x85,
        [0x86] = &&op_0x86,
        [0x87] = &&op_0x87,
        [0x88] = &&op_0x88,
        [0x89] = &&op_0x89,
        [0x8A] = &&op_0x8A,
        [0x8B] = &&op_0x8B,
        [0x8C] = &&op_0x8C,
        [0x8D] = &&op_0x8D,
        [0x8E] = &&op_0x8E,
        [0x8F] = &&op_0x8F,
        [0x90] = &&op_0x90,
        [0x91] = &&op_0x91,
        [0x92] = &&op_0x92,
        [0x93] = &&op_0x93,
        [0x94] = &&op_0x94,
        [0x95] = &&op_0x95,
        [0x96] = &&op_0x96,
        [0x97] = &&op_0x97,
        [0x98] = &&op_0x98,
        [0x99] = &&op_0x99,
        [0x9A] = &&op_0x9A,
        [0x9B] = &&op_0x9B,
        [0x9C] = &&op_0x9C,
        [0x9D] = &&op_0x9D,
        [0x9E] = &&op_0x9E,
        [0x9F] = &&op_0x9F,
        [0xA0] = &&op_0xA0,
        [0xA1] = &&op_0xA1,
        [0xA2] = &&op_0xA2,
        [0xA3] = &&op_0xA3,
        [0xA4] = &&op_0xA4,
        [0xA5] = &&op_0xA5,
        [0xA6] = &&op_0xA6,
        [0xA7] = &&op_0xA7,
        [0xA8] = &&op_0xA8,
        [0xA9] = &&op_0xA9,
        [0xAA] = &&op_0xAA,
        [0xAB] = &&op_0xAB,
        [0xAC] = &&op_0xAC,
        [0xAD] = &&op_0xAD,
        [0xAE] = &&op_0xAE,
        [0xAF] = &&op_0xAF,
        [0xB0] = &&op_0xB0,
        [0xB1] = &&op_0xB1,
        [0xB2] = &&op_0xB2,
        [0xB3] = &&op_0xB3,
        [0xB4] = &&op_0xB4,
        [0xB5] = &&op_0xB5,
        [0xB6] = &&op_0xB6,
        [0xB7] = &&op_0xB7,
        [0xB8] = &&op_0xB8,
        [0xB9] = &&op_0xB9,
        [0xBA] = &&op_0xBA,
        [0xBB] = &&op_0xBB,
        [0xBC] = &&op_0xBC,
        [0xBD] = &&op_0xBD,
        [0xBE] = &&op_0xBE,
        [0xBF] = &&op_0xBF,
        [0xC0] = &&op_0xC0,
        [0xC1] = &&op_0xC1,
        [0xC2] = &&op_0xC2,
        [0xC3] = &&op_0xC3,
        [0xC4] = &&op_0xC4,
        [0xC5] = &&op_0xC5,
        [0xC6] = &&op_0xC6,
        [0xC7] = &&op_0xC7,
        [0xC8] = &&op_0xC8,
        [0xC9] = &&op_0xC9,
        [0xCA] = &&op_0xCA,
        [0xCB] = &&op_0xCB,
        [0xCC] = &&op_0xCC,
        [0xCD] = &&op_0xCD,
        [0xCE] = &&op_0xCE,
        [0xCF] = &&op_0xCF,
        [0xD0] = &&op_0xD0,
        [0xD1] = &&op_0xD1,
        [0xD2] = &&op_0xD2,
        [0xD3] = &&op_0xD3,
        [0xD4] = &&op_0xD4,
        [0xD5] = &&op_0xD5,
        [0xD6] = &&op_0xD6,
        [0xD7] = &&op_0xD7,
        [0xD8] = &&op_0xD8,
        [0xD9] = &&op_0xD9,
        [0xDA] = &&op_0xDA,
        [0xDB] = &&op_0xDB,
        [0xDC] = &&op_0xDC,
        [0xDD] = &&op_0xDD,
        [0xDE] = &&op_0xDE,
        [0xDF] = &&op_0xDF,
        [0xE0] = &&op_0xE0,
        [0xE1] = &&op_0xE1,
        [0xE2] = &&op_0xE2,
        [0xE3] = &&op_default,
        [0xE4] = &&op_default,
        [0xE5] = &&op_default,
        [0xE6] = &&op_default,
        [0xE7] = &&op_default,
        [0xE8] = &&op_default,
        [0xE9] = &&op_default,
        [0xEA] = &&op_default,
        [0xEB] = &&op_default,
        [0xEC] = &&op_default,
        [0xED] = &&op_default,
        [0xEE] = &&op_default,
        [0xEF] = &&op_default,
        [0xF0] = &&op_default,
        [0xF1] = &&op_default,
        [0xF2] = &&op_default,
        [0xF3] = &&op_default,
        [0xF4] = &&op_default,
        [0xF5] = &&op_default,
        [0xF6] = &&op_default,
        [0xF7] = &&op_default,
        [0xF8] = &&op_default,
        [0xF9] = &&op_default,
        [0xFA] = &&op_0xFA,
        [0xFB] = &&op_0xFB,
        [0xFC] = &&op_0xFC,
        [0xFD] = &&op_0xFD,
        [0xFE] = &&op_0xFE,
        [0xFF] = &&op_0xFF
    };
    #define DISPATCH_NEXT goto next_instruction
#else
    #define DISPATCH_NEXT break
#endif

    while (pc < code_size) {
        next_instruction: (void)0;
        // Enforce global instruction limit to prevent runaway execution
        vm->insn_count++;
        vm->insn_total++;

        // Record instruction in trace ring buffer
        insn_trace[insn_trace_idx % INSN_TRACE_SIZE].pc = pc;
        insn_trace[insn_trace_idx % INSN_TRACE_SIZE].opcode = code[pc] & 0xFF;
        insn_trace_idx++;

        // Profiling: opcode frequency histogram
        if (vm->profiling_enabled) {
            vm->opcode_histogram[code[pc] & 0xFF]++;
        }

        // Cancellation: check every 10000 instructions (set from UI thread)
        if (vm->cancel_requested && (vm->insn_count % 10000) == 0) {
            const char *cls_desc = method->declaring_class ? method->declaring_class->descriptor : "?";
            const char *mth_name = method->name ? method->name : "?";
            DX_INFO(TAG, "Execution cancelled by user in %s.%s at pc=%u after %llu instructions",
                    cls_desc, mth_name, pc, vm->insn_count);
            snprintf(vm->error_msg, sizeof(vm->error_msg),
                     "Execution cancelled by user in %s.%s at pc=%u",
                     cls_desc, mth_name, pc);
            exec_result = DX_ERR_CANCELLED;
            if (result) *result = DX_NULL_VALUE;
            goto done;
        }

        // Watchdog: check wall-clock timeout every 10000 instructions
        if (vm->watchdog_timeout_ms > 0 && (vm->insn_count % 10000) == 0) {
            uint64_t now_ms = dx_current_time_ms();
            if (now_ms - vm->watchdog_start_time > vm->watchdog_timeout_ms) {
                vm->watchdog_triggered = true;
                const char *cls_desc = method->declaring_class ? method->declaring_class->descriptor : "?";
                const char *mth_name = method->name ? method->name : "?";
                DX_ERROR(TAG, "Watchdog timeout (%ums) in %s.%s at pc=%u after %llu instructions",
                         vm->watchdog_timeout_ms, cls_desc, mth_name, pc, vm->insn_count);
                snprintf(vm->error_msg, sizeof(vm->error_msg),
                         "Watchdog timeout (%ums) in %s.%s at pc=%u",
                         vm->watchdog_timeout_ms, cls_desc, mth_name, pc);
                exec_result = DX_ERR_BUDGET_EXHAUSTED;
                if (result) *result = DX_NULL_VALUE;
                goto done;
            }
        }

        if (vm->insn_limit > 0 && vm->insn_count > vm->insn_limit) {
            const char *cls_desc = method->declaring_class ? method->declaring_class->descriptor : "?";
            const char *mth_name = method->name ? method->name : "?";

            // Build a trace of the last N instructions for debugging
            char trace_buf[512];
            size_t tpos = 0;
            tpos += (size_t)snprintf(trace_buf + tpos, sizeof(trace_buf) - tpos,
                             "Last %d instructions before budget exhaustion:\n", INSN_TRACE_SIZE);
            uint32_t start = insn_trace_idx >= INSN_TRACE_SIZE ? insn_trace_idx - INSN_TRACE_SIZE : 0;
            for (uint32_t ti = start; ti < insn_trace_idx && tpos < sizeof(trace_buf) - 60; ti++) {
                uint32_t slot = ti % INSN_TRACE_SIZE;
                tpos += (size_t)snprintf(trace_buf + tpos, sizeof(trace_buf) - tpos,
                                 "  pc=%u op=0x%02x (%s)\n",
                                 insn_trace[slot].pc, insn_trace[slot].opcode,
                                 dx_opcode_name(insn_trace[slot].opcode));
            }

            DX_WARN(TAG, "Instruction budget exhausted (%llu) in %s.%s at pc=%u - probable infinite loop",
                     vm->insn_limit, cls_desc, mth_name, pc);
            DX_WARN(TAG, "%s", trace_buf);

            snprintf(vm->error_msg, sizeof(vm->error_msg),
                     "Instruction budget exhausted (%llu insns) in %s.%s at pc=%u — probable infinite loop",
                     vm->insn_limit, cls_desc, mth_name, pc);

            exec_result = DX_ERR_BUDGET_EXHAUSTED;
            if (result) *result = DX_NULL_VALUE;
            goto done;
        }

        uint16_t inst = code[pc];
        uint8_t opcode = inst & 0xFF;

        DX_TRACE(TAG, "  pc=%u op=0x%02x (%s)", pc, opcode, dx_opcode_name(opcode));

        // Debug tracing: bytecode trace with register state
        if (vm->debug.bytecode_trace && _trace_method_active) {
            DX_INFO("Trace", "  [PC=%04x] op=%02x (%s) regs: v0=%lld v1=%lld v2=%lld",
                    pc, opcode, dx_opcode_name(opcode),
                    (long long)pinned_regs[0].l,
                    (long long)(regs > 1 ? pinned_regs[1].l : 0),
                    (long long)(regs > 2 ? pinned_regs[2].l : 0));
        }

#if USE_COMPUTED_GOTO
        goto *dispatch_table[opcode];
#else
        switch (opcode) {
#endif

#if USE_COMPUTED_GOTO
        op_0x00: // nop
#else
        case 0x00: // nop
#endif
            pc += 1;
            DISPATCH_NEXT;

#if USE_COMPUTED_GOTO
        op_0x01: { // move vA, vB (12x)
#else
        case 0x01: { // move vA, vB (12x)
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            CHECK_REG(dst); CHECK_REG(src);
            pinned_regs[dst] = pinned_regs[src];
            pc += 1;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x02: { // move/from16 vAA, vBBBB (22x)
#else
        case 0x02: { // move/from16 vAA, vBBBB (22x)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint16_t src = code[pc + 1];
            if (src < DX_MAX_REGISTERS)
                pinned_regs[dst] = pinned_regs[src];
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x03: { // move/16 vAAAA, vBBBB (32x)
#else
        case 0x03: { // move/16 vAAAA, vBBBB (32x)
#endif
            uint16_t dst = code[pc + 1];
            uint16_t src = code[pc + 2];
            if (dst < DX_MAX_REGISTERS && src < DX_MAX_REGISTERS)
                pinned_regs[dst] = pinned_regs[src];
            pc += 3;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x04: { // move-wide vA, vB (12x) - treat as move for v1
#else
        case 0x04: { // move-wide vA, vB (12x) - treat as move for v1
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst] = pinned_regs[src];
            if (dst + 1 < DX_MAX_REGISTERS && src + 1 < DX_MAX_REGISTERS)
                pinned_regs[dst + 1] = pinned_regs[src + 1];
            pc += 1;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x05: { // move-wide/from16 vAA, vBBBB (22x)
#else
        case 0x05: { // move-wide/from16 vAA, vBBBB (22x)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint16_t src = code[pc + 1];
            if (src < DX_MAX_REGISTERS) {
                pinned_regs[dst] = pinned_regs[src];
                if (dst + 1 < DX_MAX_REGISTERS && src + 1 < DX_MAX_REGISTERS)
                    pinned_regs[dst + 1] = pinned_regs[src + 1];
            }
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x06: { // move-wide/16 vAAAA, vBBBB (32x)
#else
        case 0x06: { // move-wide/16 vAAAA, vBBBB (32x)
#endif
            uint16_t dst = code[pc + 1];
            uint16_t src = code[pc + 2];
            if (dst < DX_MAX_REGISTERS && src < DX_MAX_REGISTERS) {
                pinned_regs[dst] = pinned_regs[src];
                if (dst + 1 < DX_MAX_REGISTERS && src + 1 < DX_MAX_REGISTERS)
                    pinned_regs[dst + 1] = pinned_regs[src + 1];
            }
            pc += 3;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x07: { // move-object vA, vB (12x)
#else
        case 0x07: { // move-object vA, vB (12x)
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            CHECK_REG(dst); CHECK_REG(src);
            pinned_regs[dst] = pinned_regs[src];
            pc += 1;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x08: { // move-object/from16 vAA, vBBBB (22x)
#else
        case 0x08: { // move-object/from16 vAA, vBBBB (22x)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint16_t src = code[pc + 1];
            if (src < DX_MAX_REGISTERS)
                pinned_regs[dst] = pinned_regs[src];
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x09: { // move-object/16 vAAAA, vBBBB (32x)
#else
        case 0x09: { // move-object/16 vAAAA, vBBBB (32x)
#endif
            uint16_t dst = code[pc + 1];
            uint16_t src = code[pc + 2];
            if (dst < DX_MAX_REGISTERS && src < DX_MAX_REGISTERS)
                pinned_regs[dst] = pinned_regs[src];
            pc += 3;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x0A: { // move-result vAA (11x)
#else
        case 0x0A: { // move-result vAA (11x)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            pinned_regs[dst] = frame->result;
            pc += 1;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x0B: { // move-result-wide vAA (11x)
#else
        case 0x0B: { // move-result-wide vAA (11x)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            pinned_regs[dst] = frame->result;
            pc += 1;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x0C: { // move-result-object vAA (11x)
#else
        case 0x0C: { // move-result-object vAA (11x)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            pinned_regs[dst] = frame->result;
            pc += 1;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x0D: { // move-exception vAA (11x)
#else
        case 0x0D: { // move-exception vAA (11x)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            if (frame->exception) {
                pinned_regs[dst] = DX_OBJ_VALUE(frame->exception);
                frame->exception = NULL;  // clear after retrieval
            } else {
                pinned_regs[dst] = DX_NULL_VALUE;
            }
            pc += 1;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x0E: { // return-void
#else
        case 0x0E: { // return-void
#endif
            // Check for finally (catch-all) blocks covering this return
            if (method->code.tries_size > 0) {
                uint32_t finally_addr = find_finally_handler(code, code_size,
                                                              method->code.tries_size, pc);
                if (finally_addr != UINT32_MAX) {
                    DX_DEBUG(TAG, "return-void inside try-finally, running finally at %u", finally_addr);
                    frame->exception = NULL; // no exception on normal return
                    pc = finally_addr;
                    DISPATCH_NEXT;
                }
            }
            goto done;
        }

#if USE_COMPUTED_GOTO
        op_0x0F: { // return vAA
#else
        case 0x0F: { // return vAA
#endif
            uint8_t src = (inst >> 8) & 0xFF;
            frame->result = pinned_regs[src];
            frame->has_result = true;
            if (result) *result = pinned_regs[src];
            // Check for finally blocks covering this return
            if (method->code.tries_size > 0) {
                uint32_t finally_addr = find_finally_handler(code, code_size,
                                                              method->code.tries_size, pc);
                if (finally_addr != UINT32_MAX) {
                    DX_DEBUG(TAG, "return inside try-finally, running finally at %u", finally_addr);
                    frame->exception = NULL;
                    pc = finally_addr;
                    DISPATCH_NEXT;
                }
            }
            goto done;
        }

#if USE_COMPUTED_GOTO
        op_0x10: { // return-wide vAA
#else
        case 0x10: { // return-wide vAA
#endif
            uint8_t src = (inst >> 8) & 0xFF;
            frame->result = pinned_regs[src];
            frame->has_result = true;
            if (result) *result = pinned_regs[src];
            if (method->code.tries_size > 0) {
                uint32_t finally_addr = find_finally_handler(code, code_size,
                                                              method->code.tries_size, pc);
                if (finally_addr != UINT32_MAX) {
                    DX_DEBUG(TAG, "return-wide inside try-finally, running finally at %u", finally_addr);
                    frame->exception = NULL;
                    pc = finally_addr;
                    DISPATCH_NEXT;
                }
            }
            goto done;
        }

#if USE_COMPUTED_GOTO
        op_0x11: { // return-object vAA
#else
        case 0x11: { // return-object vAA
#endif
            uint8_t src = (inst >> 8) & 0xFF;
            frame->result = pinned_regs[src];
            frame->has_result = true;
            if (result) *result = pinned_regs[src];
            if (method->code.tries_size > 0) {
                uint32_t finally_addr = find_finally_handler(code, code_size,
                                                              method->code.tries_size, pc);
                if (finally_addr != UINT32_MAX) {
                    DX_DEBUG(TAG, "return-object inside try-finally, running finally at %u", finally_addr);
                    frame->exception = NULL;
                    pc = finally_addr;
                    DISPATCH_NEXT;
                }
            }
            goto done;
        }

#if USE_COMPUTED_GOTO
        op_0x12: { // const/4 vA, #+B (11n)
#else
        case 0x12: { // const/4 vA, #+B (11n)
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            int32_t val = (int32_t)(inst >> 12);
            if (val & 0x8) val |= (int32_t)0xFFFFFFF0;
            pinned_regs[dst] = DX_INT_VALUE(val);
            pc += 1;

#if USE_SUPERINSTRUCTIONS
            // Superinstruction: const/4 vA, #+B followed by if-eqz vA, +CCCC
            // Peek at next instruction and fuse if it's if-eqz on the same register
            if (pc < code_size) {
                uint16_t next_inst = code[pc];
                uint8_t next_op = next_inst & 0xFF;
                if (next_op == 0x38) { // if-eqz
                    uint8_t eqz_reg = (next_inst >> 8) & 0xFF;
                    if (eqz_reg == dst) {
                        // Fused: skip re-dispatch, do the branch inline
                        vm->insn_count++;
                        vm->insn_total++;
                        if (vm->profiling_enabled) {
                            vm->opcode_histogram[0x38]++;
                        }
                        int16_t offset = (int16_t)code[pc + 1];
                        pc = (uint32_t)((int32_t)pc + ((val == 0) ? (int32_t)offset : 2));
                        DISPATCH_NEXT;
                    }
                }
            }
#endif
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x13: { // const/16 vAA, #+BBBB (21s)
#else
        case 0x13: { // const/16 vAA, #+BBBB (21s)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            int16_t val = (int16_t)code[pc + 1];
            pinned_regs[dst] = DX_INT_VALUE((int32_t)val);
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x14: { // const vAA, #+BBBBBBBB (31i)
#else
        case 0x14: { // const vAA, #+BBBBBBBB (31i)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            int32_t val = (int32_t)(code[pc + 1] | ((uint32_t)code[pc + 2] << 16));
            pinned_regs[dst] = DX_INT_VALUE(val);
            pc += 3;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x15: { // const/high16 vAA, #+BBBB0000 (21h)
#else
        case 0x15: { // const/high16 vAA, #+BBBB0000 (21h)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            int32_t val = (int32_t)((uint32_t)code[pc + 1] << 16);
            pinned_regs[dst] = DX_INT_VALUE(val);
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x16: { // const-wide/16 vAA, #+BBBB (21s)
#else
        case 0x16: { // const-wide/16 vAA, #+BBBB (21s)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            int64_t val = (int16_t)code[pc + 1];
            pinned_regs[dst].tag = DX_VAL_LONG;
            pinned_regs[dst].l = val;
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x17: { // const-wide/32 vAA, #+BBBBBBBB (31i)
#else
        case 0x17: { // const-wide/32 vAA, #+BBBBBBBB (31i)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            int32_t val = (int32_t)(code[pc + 1] | ((uint32_t)code[pc + 2] << 16));
            pinned_regs[dst].tag = DX_VAL_LONG;
            pinned_regs[dst].l = (int64_t)val;
            pc += 3;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x18: { // const-wide vAA, #+BBBBBBBBBBBBBBBB (51l)
#else
        case 0x18: { // const-wide vAA, #+BBBBBBBBBBBBBBBB (51l)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            int64_t val = (int64_t)code[pc + 1] |
                          ((int64_t)code[pc + 2] << 16) |
                          ((int64_t)code[pc + 3] << 32) |
                          ((int64_t)code[pc + 4] << 48);
            pinned_regs[dst].tag = DX_VAL_LONG;
            pinned_regs[dst].l = val;
            pc += 5;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x19: { // const-wide/high16 vAA, #+BBBB000000000000 (21h)
#else
        case 0x19: { // const-wide/high16 vAA, #+BBBB000000000000 (21h)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            int64_t val = (int64_t)((uint64_t)code[pc + 1] << 48);
            pinned_regs[dst].tag = DX_VAL_LONG;
            pinned_regs[dst].l = val;
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x1A: { // const-string vAA, string@BBBB (21c)
#else
        case 0x1A: { // const-string vAA, string@BBBB (21c)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint16_t str_idx = code[pc + 1];
            const char *str = dx_dex_get_string(cur_dex, str_idx);
            DxObject *str_obj = dx_vm_create_string(vm, str ? str : "");
            pinned_regs[dst] = DX_OBJ_VALUE(str_obj);
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x1B: { // const-string/jumbo vAA, string@BBBBBBBB (31c)
#else
        case 0x1B: { // const-string/jumbo vAA, string@BBBBBBBB (31c)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint32_t str_idx = code[pc + 1] | ((uint32_t)code[pc + 2] << 16);
            const char *str = dx_dex_get_string(cur_dex, str_idx);
            DxObject *str_obj = dx_vm_create_string(vm, str ? str : "");
            pinned_regs[dst] = DX_OBJ_VALUE(str_obj);
            pc += 3;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x1C: { // const-class vAA, type@BBBB (21c)
#else
        case 0x1C: { // const-class vAA, type@BBBB (21c)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            // Return null for class objects - proper Class<T> not modeled
            pinned_regs[dst] = DX_NULL_VALUE;
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x1D: // monitor-enter (11x) - no threading model, with spin detection
#else
        case 0x1D: // monitor-enter (11x) - no threading model, with spin detection
#endif
        {
            // Detect potential deadlock: same monitor-enter PC hit repeatedly
            static uint32_t monitor_last_pc = UINT32_MAX;
            static uint32_t monitor_spin_count = 0;
            if (pc == monitor_last_pc) {
                monitor_spin_count++;
                if (monitor_spin_count > 10000) {
                    DX_WARN(TAG, "Potential deadlock: monitor-enter at PC %u hit %u times without progress",
                            pc, monitor_spin_count);
                    monitor_spin_count = 0; // reset so we don't spam
                }
            } else {
                monitor_last_pc = pc;
                monitor_spin_count = 1;
            }
            pc += 1;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x1E: // monitor-exit (11x) - no threading model
#else
        case 0x1E: // monitor-exit (11x) - no threading model
#endif
            pc += 1;
            DISPATCH_NEXT;

#if USE_COMPUTED_GOTO
        op_0x1F: { // check-cast vAA, type@BBBB (21c)
#else
        case 0x1F: { // check-cast vAA, type@BBBB (21c)
#endif
            uint8_t src = (inst >> 8) & 0xFF;
            uint16_t type_idx = code[pc + 1];
            DxObject *obj = (pinned_regs[src].tag == DX_VAL_OBJ) ? pinned_regs[src].obj : NULL;
            if (obj) {
                const char *type_desc = dx_dex_get_type(cur_dex, type_idx);
                DxClass *cls = obj->klass;
                bool match = false;
                while (cls && !match) {
                    if (cls->descriptor && type_desc && strcmp(cls->descriptor, type_desc) == 0) {
                        match = true;
                    }
                    // Check interfaces
                    if (!match) {
                        for (uint32_t ii = 0; ii < cls->interface_count && !match; ii++) {
                            if (cls->interfaces[ii] && type_desc &&
                                strcmp(cls->interfaces[ii], type_desc) == 0) {
                                match = true;
                            }
                        }
                    }
                    cls = cls->super_class;
                }
                if (!match) {
                    // ClassCastException
                    char msg[256];
                    snprintf(msg, sizeof(msg), "%s cannot be cast to %s",
                             obj->klass->descriptor ? obj->klass->descriptor : "?",
                             type_desc ? type_desc : "?");
                    DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/ClassCastException;", msg);
                    if (exc && method->code.tries_size > 0) {
                        uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                               method->code.tries_size, pc, exc);
                        if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                    }
                    // No handler - propagate
                    if (exc) {
                        vm->pending_exception = exc;
                        exec_result = DX_ERR_EXCEPTION;
                        goto done;
                    }
                    DX_WARN(TAG, "ClassCastException: %s", msg);
                }
            }
            // null passes check-cast (Java spec)
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x20: { // instance-of vA, vB, type@CCCC (22c)
#else
        case 0x20: { // instance-of vA, vB, type@CCCC (22c)
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t obj_reg = (inst >> 12) & 0x0F;
            uint16_t type_idx = code[pc + 1];

            DxObject *obj = (pinned_regs[obj_reg].tag == DX_VAL_OBJ)
                            ? pinned_regs[obj_reg].obj : NULL;
            if (!obj) {
                pinned_regs[dst] = DX_INT_VALUE(0);
            } else {
                const char *type_desc = dx_dex_get_type(cur_dex, type_idx);
                // Walk class hierarchy to check class and interfaces
                DxClass *cls = obj->klass;
                bool match = false;
                while (cls && !match) {
                    if (cls->descriptor && type_desc && strcmp(cls->descriptor, type_desc) == 0) {
                        match = true;
                        break;
                    }
                    // Check interfaces implemented by this class in the hierarchy
                    for (uint32_t ifc = 0; ifc < cls->interface_count && !match; ifc++) {
                        if (cls->interfaces[ifc] && type_desc &&
                            strcmp(cls->interfaces[ifc], type_desc) == 0) {
                            match = true;
                        }
                    }
                    cls = cls->super_class;
                }
                pinned_regs[dst] = DX_INT_VALUE(match ? 1 : 0);
            }
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x21: { // array-length vA, vB (12x)
#else
        case 0x21: { // array-length vA, vB (12x)
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            DxObject *arr = pinned_regs[src].obj;
            if (arr && arr->is_array) {
                pinned_regs[dst] = DX_INT_VALUE((int32_t)arr->array_length);
            } else {
                pinned_regs[dst] = DX_INT_VALUE(0);
            }
            pc += 1;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x22: { // new-instance vAA, type@BBBB (21c)
#else
        case 0x22: { // new-instance vAA, type@BBBB (21c)
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint16_t type_idx = code[pc + 1];
            const char *type_desc = dx_dex_get_type(cur_dex, type_idx);

            DxClass *cls = NULL;
            exec_result = dx_vm_load_class(vm, type_desc, &cls);
            if (exec_result != DX_OK) {
                DX_WARN(TAG, "new-instance: cannot load %s, using Object", type_desc);
                cls = vm->class_object;
                exec_result = DX_OK;
            }

            exec_result = dx_vm_init_class(vm, cls);
            if (exec_result != DX_OK) goto done;

            DxObject *obj = dx_vm_alloc_object(vm, cls);
            if (!obj) { exec_result = DX_ERR_OUT_OF_MEMORY; goto done; }

            pinned_regs[dst] = DX_OBJ_VALUE(obj);
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x23: { // new-array vA, vB, type@CCCC (22c)
#else
        case 0x23: { // new-array vA, vB, type@CCCC (22c)
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t size_reg = (inst >> 12) & 0x0F;
            int32_t length = pinned_regs[size_reg].i;
            if (length < 0) length = 0;
            DxObject *arr = dx_vm_alloc_array(vm, (uint32_t)length);
            if (arr) {
                pinned_regs[dst] = DX_OBJ_VALUE(arr);
            } else {
                pinned_regs[dst] = DX_NULL_VALUE;
            }
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x24: { // filled-new-array {vC, vD, vE, vF, vG}, type@BBBB (35c)
#else
        case 0x24: { // filled-new-array {vC, vD, vE, vF, vG}, type@BBBB (35c)
#endif
            uint8_t argc;
            uint8_t arg_regs[5];
            decode_35c_args(code, pc, &argc, arg_regs);
            DxObject *arr = dx_vm_alloc_array(vm, argc);
            if (arr) {
                for (uint8_t i = 0; i < argc; i++) {
                    arr->array_elements[i] = pinned_regs[arg_regs[i]];
                }
                frame->result = DX_OBJ_VALUE(arr);
            } else {
                frame->result = DX_NULL_VALUE;
            }
            frame->has_result = true;
            pc += 3;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x25: { // filled-new-array/range {vCCCC .. vNNNN}, type@BBBB (3rc)
#else
        case 0x25: { // filled-new-array/range {vCCCC .. vNNNN}, type@BBBB (3rc)
#endif
            uint8_t argc = (inst >> 8) & 0xFF;
            uint16_t first_reg = code[pc + 2];
            DxObject *arr = dx_vm_alloc_array(vm, argc);
            if (arr) {
                for (uint8_t i = 0; i < argc; i++) {
                    uint16_t reg = first_reg + i;
                    if (reg < DX_MAX_REGISTERS) {
                        arr->array_elements[i] = pinned_regs[reg];
                    }
                }
                frame->result = DX_OBJ_VALUE(arr);
            } else {
                frame->result = DX_NULL_VALUE;
            }
            frame->has_result = true;
            pc += 3;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x26: { // fill-array-data vAA, +BBBBBBBB (31t)
#else
        case 0x26: { // fill-array-data vAA, +BBBBBBBB (31t)
#endif
            uint8_t arr_reg = (inst >> 8) & 0xFF;
            int32_t offset = (int32_t)(code[pc + 1] | ((uint32_t)code[pc + 2] << 16));
            const uint16_t *payload = &code[(uint32_t)((int32_t)pc + offset)];
            uint16_t ident = payload[0];
            if (ident != 0x0300) {
                DX_WARN(TAG, "fill-array-data: bad ident 0x%04x at pc=%u", ident, pc);
                pc += 3;
                DISPATCH_NEXT;
            }
            uint16_t elem_width = payload[1];
            uint32_t size = (uint32_t)payload[2] | ((uint32_t)payload[3] << 16);
            const uint8_t *data = (const uint8_t *)&payload[4];

            DxObject *arr = pinned_regs[arr_reg].obj;
            if (arr && arr->is_array && arr->array_elements) {
                uint32_t count = size < arr->array_length ? size : arr->array_length;
                for (uint32_t i = 0; i < count; i++) {
                    int32_t val = 0;
                    const uint8_t *elem = data + (i * elem_width);
                    if (elem_width == 1) {
                        val = (int8_t)elem[0];
                    } else if (elem_width == 2) {
                        val = (int16_t)(elem[0] | (elem[1] << 8));
                    } else if (elem_width == 4) {
                        val = (int32_t)(elem[0] | (elem[1] << 8) | (elem[2] << 16) | (elem[3] << 24));
                    }
                    if (elem_width == 8) {
                        // 8-byte elements (long/double)
                        int64_t val64 = 0;
                        for (int b = 0; b < 8; b++) {
                            val64 |= (int64_t)elem[b] << (b * 8);
                        }
                        arr->array_elements[i].tag = DX_VAL_LONG;
                        arr->array_elements[i].l = val64;
                    } else {
                        arr->array_elements[i] = DX_INT_VALUE(val);
                    }
                }
            }
            pc += 3;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x27: { // throw vAA (11x)
#else
        case 0x27: { // throw vAA (11x)
#endif
            uint8_t src = (inst >> 8) & 0xFF;
            DxObject *exc = (pinned_regs[src].tag == DX_VAL_OBJ) ? pinned_regs[src].obj : NULL;
            const char *exc_class = exc && exc->klass ? exc->klass->descriptor : "unknown";

            // Telemetry: count exceptions thrown
            if (vm->telemetry.telemetry_enabled) {
                vm->telemetry.exceptions_thrown++;
            }

            // Search for a try/catch handler covering this pc
            if (method->code.tries_size > 0) {
                uint32_t handler_addr = find_catch_handler(vm, frame, code, code_size,
                                                            method->code.tries_size, pc, exc);
                if (handler_addr != UINT32_MAX) {
                    DX_INFO(TAG, "throw %s -> caught at handler addr %u", exc_class, handler_addr);
                    pc = handler_addr;
                    DISPATCH_NEXT;
                }
            }

            // No handler found - propagate up to caller via exception unwinding
            DX_INFO(TAG, "throw %s (no handler, propagating to caller)", exc_class);
            vm->pending_exception = exc;
            exec_result = DX_ERR_EXCEPTION;
            goto done;
        }

#if USE_COMPUTED_GOTO
        op_0x28: { // goto +AA (10t)
#else
        case 0x28: { // goto +AA (10t)
#endif
            int8_t offset = (int8_t)((inst >> 8) & 0xFF);
            pc = (uint32_t)((int32_t)pc + offset);
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x29: { // goto/16 +AAAA (20t)
#else
        case 0x29: { // goto/16 +AAAA (20t)
#endif
            int16_t offset = (int16_t)code[pc + 1];
            pc = (uint32_t)((int32_t)pc + offset);
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x2A: { // goto/32 +AAAAAAAA (30t)
#else
        case 0x2A: { // goto/32 +AAAAAAAA (30t)
#endif
            int32_t offset = (int32_t)(code[pc + 1] | ((uint32_t)code[pc + 2] << 16));
            pc = (uint32_t)((int32_t)pc + offset);
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x2B: { // packed-switch vAA, +BBBBBBBB (31t)
#else
        case 0x2B: { // packed-switch vAA, +BBBBBBBB (31t)
#endif
            uint8_t test_reg = (inst >> 8) & 0xFF;
            int32_t offset = (int32_t)(code[pc + 1] | ((uint32_t)code[pc + 2] << 16));
            uint32_t payload_pc = (uint32_t)((int32_t)pc + offset);
            if (payload_pc >= code_size) {
                DX_WARN(TAG, "packed-switch: payload offset %u out of bounds (code_size=%u)", payload_pc, code_size);
                pc += 3;
                DISPATCH_NEXT;
            }
            const uint16_t *payload = &code[payload_pc];
            uint16_t ident = payload[0];
            if (ident != 0x0100) {
                DX_WARN(TAG, "packed-switch: bad ident 0x%04x at pc=%u", ident, pc);
                pc += 3;
                DISPATCH_NEXT;
            }
            uint16_t size = payload[1];
            int32_t first_key = (int32_t)(payload[2] | ((uint32_t)payload[3] << 16));
            const int32_t *targets = (const int32_t *)&payload[4];

            int32_t test_val = pinned_regs[test_reg].i;
            int32_t idx = test_val - first_key;
            if (idx >= 0 && (uint32_t)idx < size) {
                pc = (uint32_t)((int32_t)pc + targets[idx]);
            } else {
                pc += 3; // fall through
            }
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_0x2C: { // sparse-switch vAA, +BBBBBBBB (31t)
#else
        case 0x2C: { // sparse-switch vAA, +BBBBBBBB (31t)
#endif
            uint8_t test_reg = (inst >> 8) & 0xFF;
            int32_t offset = (int32_t)(code[pc + 1] | ((uint32_t)code[pc + 2] << 16));
            uint32_t payload_pc = (uint32_t)((int32_t)pc + offset);
            if (payload_pc >= code_size) {
                DX_WARN(TAG, "sparse-switch: payload offset %u out of bounds (code_size=%u)", payload_pc, code_size);
                pc += 3;
                DISPATCH_NEXT;
            }
            const uint16_t *payload = &code[payload_pc];
            uint16_t ident = payload[0];
            if (ident != 0x0200) {
                DX_WARN(TAG, "sparse-switch: bad ident 0x%04x at pc=%u", ident, pc);
                pc += 3;
                DISPATCH_NEXT;
            }
            uint16_t size = payload[1];
            const int32_t *keys = (const int32_t *)&payload[2];
            const int32_t *targets = (const int32_t *)&payload[2 + size * 2]; // after keys array

            int32_t test_val = pinned_regs[test_reg].i;
            bool found = false;
            for (uint16_t si = 0; si < size; si++) {
                if (keys[si] == test_val) {
                    pc = (uint32_t)((int32_t)pc + targets[si]);
                    found = true;
                    break;
                }
            }
            if (!found) {
                pc += 3; // fall through
            }
            DISPATCH_NEXT;
        }

        // Comparison operations (23x)
#if USE_COMPUTED_GOTO
        op_0x2D: { // cmpl-float vAA, vBB, vCC
#else
        case 0x2D: { // cmpl-float vAA, vBB, vCC
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint8_t b = code[pc + 1] & 0xFF;
            uint8_t c = (code[pc + 1] >> 8) & 0xFF;
            float fb = pinned_regs[b].f;
            float fc = pinned_regs[c].f;
            pinned_regs[dst] = DX_INT_VALUE(fb < fc ? -1 : (fb > fc ? 1 : 0));
            pc += 2;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x2E: { // cmpg-float
#else
        case 0x2E: { // cmpg-float
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint8_t b = code[pc + 1] & 0xFF;
            uint8_t c = (code[pc + 1] >> 8) & 0xFF;
            float fb = pinned_regs[b].f;
            float fc = pinned_regs[c].f;
            pinned_regs[dst] = DX_INT_VALUE(fb > fc ? 1 : (fb < fc ? -1 : 0));
            pc += 2;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x2F: { // cmpl-double
#else
        case 0x2F: { // cmpl-double
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint8_t b = code[pc + 1] & 0xFF;
            uint8_t c = (code[pc + 1] >> 8) & 0xFF;
            double db = pinned_regs[b].d;
            double dc = pinned_regs[c].d;
            pinned_regs[dst] = DX_INT_VALUE(db < dc ? -1 : (db > dc ? 1 : 0));
            pc += 2;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x30: { // cmpg-double
#else
        case 0x30: { // cmpg-double
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint8_t b = code[pc + 1] & 0xFF;
            uint8_t c = (code[pc + 1] >> 8) & 0xFF;
            double db = pinned_regs[b].d;
            double dc = pinned_regs[c].d;
            pinned_regs[dst] = DX_INT_VALUE(db > dc ? 1 : (db < dc ? -1 : 0));
            pc += 2;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x31: { // cmp-long
#else
        case 0x31: { // cmp-long
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint8_t b = code[pc + 1] & 0xFF;
            uint8_t c = (code[pc + 1] >> 8) & 0xFF;
            int64_t lb = pinned_regs[b].l;
            int64_t lc = pinned_regs[c].l;
            pinned_regs[dst] = DX_INT_VALUE(lb < lc ? -1 : (lb > lc ? 1 : 0));
            pc += 2;
            DISPATCH_NEXT;
        }

        // if-test vA, vB, +CCCC (22t)
#if USE_COMPUTED_GOTO
        op_0x32:
        op_0x33:
        op_0x34:
        op_0x35:
        op_0x36:
        op_0x37: {
#else
        case 0x32: case 0x33: case 0x34: case 0x35: case 0x36: case 0x37: {
#endif
            uint8_t a = (inst >> 8) & 0x0F;
            uint8_t b = (inst >> 12) & 0x0F;
            int16_t offset = (int16_t)code[pc + 1];
            int32_t va = pinned_regs[a].i;
            int32_t vb = pinned_regs[b].i;
            bool take = false;
            switch (opcode) {
                case 0x32: take = (va == vb); break; // if-eq
                case 0x33: take = (va != vb); break; // if-ne
                case 0x34: take = (va <  vb); break; // if-lt
                case 0x35: take = (va >= vb); break; // if-ge
                case 0x36: take = (va >  vb); break; // if-gt
                case 0x37: take = (va <= vb); break; // if-le
            }
            pc = (uint32_t)((int32_t)pc + (take ? (int32_t)offset : 2));
            DISPATCH_NEXT;
        }

        // if-testz vAA, +BBBB (21t)
#if USE_COMPUTED_GOTO
        op_0x38:
        op_0x39:
        op_0x3A:
        op_0x3B:
        op_0x3C:
        op_0x3D: {
#else
        case 0x38: case 0x39: case 0x3A: case 0x3B: case 0x3C: case 0x3D: {
#endif
            uint8_t src = (inst >> 8) & 0xFF;
            int16_t offset = (int16_t)code[pc + 1];
            int32_t val;
            if (pinned_regs[src].tag == DX_VAL_OBJ) {
                val = (pinned_regs[src].obj == NULL) ? 0 : 1;
            } else {
                val = pinned_regs[src].i;
            }
            bool take = false;
            switch (opcode) {
                case 0x38: take = (val == 0); break; // if-eqz
                case 0x39: take = (val != 0); break; // if-nez
                case 0x3A: take = (val <  0); break; // if-ltz
                case 0x3B: take = (val >= 0); break; // if-gez
                case 0x3C: take = (val >  0); break; // if-gtz
                case 0x3D: take = (val <= 0); break; // if-lez
            }
            pc = (uint32_t)((int32_t)pc + (take ? (int32_t)offset : 2));
            DISPATCH_NEXT;
        }

        // aget variants (23x): aget vAA, vBB, vCC
#if USE_COMPUTED_GOTO
        op_0x44:
        op_0x45:
        op_0x46:
        op_0x47:
#else
        case 0x44: case 0x45: case 0x46: case 0x47:
#endif
#if USE_COMPUTED_GOTO
        op_0x48:
        op_0x49:
        op_0x4A: {
#else
        case 0x48: case 0x49: case 0x4A: {
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint8_t arr_reg = code[pc + 1] & 0xFF;
            uint8_t idx_reg = (code[pc + 1] >> 8) & 0xFF;
            CHECK_REG(dst); CHECK_REG(arr_reg); CHECK_REG(idx_reg);
            DxObject *arr = (pinned_regs[arr_reg].tag == DX_VAL_OBJ) ? pinned_regs[arr_reg].obj : NULL;
            int32_t index = pinned_regs[idx_reg].i;
            if (!arr) {
                // NullPointerException on null array
                DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/NullPointerException;",
                    "Attempt to get array element from null array");
                if (exc && method->code.tries_size > 0) {
                    uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                           method->code.tries_size, pc, exc);
                    if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                }
                if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                pinned_regs[dst] = (opcode == 0x46) ? DX_NULL_VALUE : DX_INT_VALUE(0);
            } else if (arr->is_array && index >= 0 && (uint32_t)index < arr->array_length) {
                pinned_regs[dst] = arr->array_elements[index];
            } else if (arr->is_array) {
                // ArrayIndexOutOfBoundsException
                char msg[64];
                snprintf(msg, sizeof(msg), "length=%u; index=%d", arr->array_length, index);
                DxObject *exc = dx_vm_create_exception(vm,
                    "Ljava/lang/ArrayIndexOutOfBoundsException;", msg);
                if (exc && method->code.tries_size > 0) {
                    uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                           method->code.tries_size, pc, exc);
                    if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                }
                if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                pinned_regs[dst] = (opcode == 0x46) ? DX_NULL_VALUE : DX_INT_VALUE(0);
            } else {
                pinned_regs[dst] = (opcode == 0x46) ? DX_NULL_VALUE : DX_INT_VALUE(0);
            }
            pc += 2;
            DISPATCH_NEXT;
        }
        // aput variants (23x): aput vAA, vBB, vCC
#if USE_COMPUTED_GOTO
        op_0x4B:
        op_0x4C:
        op_0x4D:
        op_0x4E:
#else
        case 0x4B: case 0x4C: case 0x4D: case 0x4E:
#endif
#if USE_COMPUTED_GOTO
        op_0x4F:
        op_0x50:
        op_0x51: {
#else
        case 0x4F: case 0x50: case 0x51: {
#endif
            uint8_t src = (inst >> 8) & 0xFF;
            uint8_t arr_reg = code[pc + 1] & 0xFF;
            uint8_t idx_reg = (code[pc + 1] >> 8) & 0xFF;
            CHECK_REG(src); CHECK_REG(arr_reg); CHECK_REG(idx_reg);
            DxObject *arr = (pinned_regs[arr_reg].tag == DX_VAL_OBJ) ? pinned_regs[arr_reg].obj : NULL;
            int32_t index = pinned_regs[idx_reg].i;
            if (!arr) {
                DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/NullPointerException;",
                    "Attempt to store to null array");
                if (exc && method->code.tries_size > 0) {
                    uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                           method->code.tries_size, pc, exc);
                    if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                }
                if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
            } else if (arr->is_array && index >= 0 && (uint32_t)index < arr->array_length) {
                arr->array_elements[index] = pinned_regs[src];
            } else if (arr->is_array) {
                char msg[64];
                snprintf(msg, sizeof(msg), "length=%u; index=%d", arr->array_length, index);
                DxObject *exc = dx_vm_create_exception(vm,
                    "Ljava/lang/ArrayIndexOutOfBoundsException;", msg);
                if (exc && method->code.tries_size > 0) {
                    uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                           method->code.tries_size, pc, exc);
                    if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                }
                if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
            }
            pc += 2;
            DISPATCH_NEXT;
        }

        // iget family (22c)
#if USE_COMPUTED_GOTO
        op_0x52:
        op_0x53:
        op_0x54:
        op_0x55:
#else
        case 0x52: case 0x53: case 0x54: case 0x55:
#endif
#if USE_COMPUTED_GOTO
        op_0x56:
        op_0x57:
        op_0x58: {
#else
        case 0x56: case 0x57: case 0x58: {
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t obj_reg = (inst >> 12) & 0x0F;
            uint16_t field_idx = code[pc + 1];
            CHECK_REG(dst); CHECK_REG(obj_reg);

            DxValue obj_val = pinned_regs[obj_reg];
            DxObject *obj = (obj_val.tag == DX_VAL_OBJ) ? obj_val.obj : NULL;
            if (!obj) {
                null_access_count++;
                // Try to throw NullPointerException
                DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/NullPointerException;",
                    "Attempt to read from field on a null object reference");
                if (exc && method->code.tries_size > 0) {
                    uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                           method->code.tries_size, pc, exc);
                    if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                }
                if (exc && null_access_count <= 1) {
                    // First null access with no local handler — propagate
                    vm->pending_exception = exc;
                    exec_result = DX_ERR_EXCEPTION;
                    goto done;
                }
                // Fallback: absorb after first to avoid cascading failures
                if (null_access_count <= 3) {
                    DX_WARN(TAG, "iget on null object at pc=%u (NPE absorbed)", pc);
                }
                if (null_access_count > 100) {
                    DX_ERROR(TAG, "Too many null field accesses (%u), aborting method %s.%s",
                             null_access_count,
                             method->declaring_class ? method->declaring_class->descriptor : "?",
                             method->name);
                    exec_result = DX_ERR_INTERNAL;
                    goto done;
                }
                pinned_regs[dst] = (opcode == 0x54) ? DX_NULL_VALUE : DX_INT_VALUE(0);
                pc += 2;
                DISPATCH_NEXT;
            }

            // Corruption guard: validate object has a valid class pointer
            if (!obj->klass) {
                DX_WARN(TAG, "iget on corrupted object (null klass) at pc=%u", pc);
                pinned_regs[dst] = (opcode == 0x54) ? DX_NULL_VALUE : DX_INT_VALUE(0);
                pc += 2;
                DISPATCH_NEXT;
            }

            const char *fname = dx_dex_get_field_name(cur_dex, field_idx);
            DxValue val;
            DxResult fr = dx_vm_get_field(obj, fname, &val);
            if (fr == DX_OK) {
                pinned_regs[dst] = val;
            } else {
                pinned_regs[dst] = (opcode == 0x54) ? DX_NULL_VALUE : DX_INT_VALUE(0);
            }
            pc += 2;

#if USE_SUPERINSTRUCTIONS
            // Superinstruction: iget-object (0x54) followed by return-object (0x11)
            // Optimizes trivial getter methods: return this.field
            if (opcode == 0x54 && pc < code_size) {
                uint16_t next_inst = code[pc];
                uint8_t next_op = next_inst & 0xFF;
                if (next_op == 0x11) { // return-object
                    uint8_t ret_reg = (next_inst >> 8) & 0xFF;
                    if (ret_reg == dst) {
                        // Fused: skip re-dispatch, do the return inline
                        vm->insn_count++;
                        vm->insn_total++;
                        if (vm->profiling_enabled) {
                            vm->opcode_histogram[0x11]++;
                        }
                        frame->result = pinned_regs[dst];
                        frame->has_result = true;
                        if (result) *result = pinned_regs[dst];
                        goto done;
                    }
                }
            }
#endif
            DISPATCH_NEXT;
        }

        // iput family (22c)
#if USE_COMPUTED_GOTO
        op_0x59:
        op_0x5A:
        op_0x5B:
        op_0x5C:
#else
        case 0x59: case 0x5A: case 0x5B: case 0x5C:
#endif
#if USE_COMPUTED_GOTO
        op_0x5D:
        op_0x5E:
        op_0x5F: {
#else
        case 0x5D: case 0x5E: case 0x5F: {
#endif
            uint8_t src = (inst >> 8) & 0x0F;
            uint8_t obj_reg = (inst >> 12) & 0x0F;
            uint16_t field_idx = code[pc + 1];
            CHECK_REG(src); CHECK_REG(obj_reg);

            DxValue obj_val = pinned_regs[obj_reg];
            DxObject *obj = (obj_val.tag == DX_VAL_OBJ) ? obj_val.obj : NULL;
            if (!obj) {
                null_access_count++;
                if (null_access_count <= 3) {
                    DX_WARN(TAG, "iput on null object at pc=%u", pc);
                }
                if (null_access_count > 100) {
                    DX_ERROR(TAG, "Too many null field accesses (%u), aborting method %s.%s",
                             null_access_count,
                             method->declaring_class ? method->declaring_class->descriptor : "?",
                             method->name);
                    exec_result = DX_ERR_INTERNAL;
                    goto done;
                }
                pc += 2;
                DISPATCH_NEXT;
            }

            // Corruption guard: validate object has a valid class pointer
            if (!obj->klass) {
                DX_WARN(TAG, "iput on corrupted object (null klass) at pc=%u", pc);
                pc += 2;
                DISPATCH_NEXT;
            }

            const char *fname = dx_dex_get_field_name(cur_dex, field_idx);
            dx_vm_set_field(obj, fname, pinned_regs[src]);
            pc += 2;
            DISPATCH_NEXT;
        }

        // sget family (21c)
#if USE_COMPUTED_GOTO
        op_0x60:
        op_0x61:
        op_0x62:
        op_0x63:
#else
        case 0x60: case 0x61: case 0x62: case 0x63:
#endif
#if USE_COMPUTED_GOTO
        op_0x64:
        op_0x65:
        op_0x66: {
#else
        case 0x64: case 0x65: case 0x66: {
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint16_t field_idx = code[pc + 1];
            bool is_obj = (opcode == 0x62);
            handle_sget(vm, frame, dst, field_idx, is_obj);
            pc += 2;
            DISPATCH_NEXT;
        }

        // sput family (21c)
#if USE_COMPUTED_GOTO
        op_0x67:
        op_0x68:
        op_0x69:
        op_0x6A:
#else
        case 0x67: case 0x68: case 0x69: case 0x6A:
#endif
#if USE_COMPUTED_GOTO
        op_0x6B:
        op_0x6C:
        op_0x6D: {
#else
        case 0x6B: case 0x6C: case 0x6D: {
#endif
            uint8_t src = (inst >> 8) & 0xFF;
            uint16_t field_idx = code[pc + 1];
            bool is_obj = (opcode == 0x69);
            handle_sput(vm, frame, src, field_idx, is_obj);
            pc += 2;
            DISPATCH_NEXT;
        }

        // invoke-kind (35c)
#if USE_COMPUTED_GOTO
        op_0x6E:
        op_0x6F:
        op_0x70:
        op_0x71:
        op_0x72: {
#else
        case 0x6E: case 0x6F: case 0x70: case 0x71: case 0x72: {
#endif
            frame->pc = 0; // sentinel
            exec_result = handle_invoke(vm, frame, code, pc, opcode);
            if (exec_result != DX_OK) goto done;
            if (frame->pc != 0) {
                // Exception was caught by our try/catch — jump to handler
                pc = frame->pc;
                frame->pc = 0;
            } else {
                pc += 3;
            }
            DISPATCH_NEXT;
        }

        // invoke-kind/range (3rc)
#if USE_COMPUTED_GOTO
        op_0x74:
        op_0x75:
        op_0x76:
        op_0x77:
        op_0x78: {
#else
        case 0x74: case 0x75: case 0x76: case 0x77: case 0x78: {
#endif
            frame->pc = 0; // sentinel
            exec_result = handle_invoke_range(vm, frame, code, pc, opcode);
            if (exec_result != DX_OK) goto done;
            if (frame->pc != 0) {
                pc = frame->pc;
                frame->pc = 0;
            } else {
                pc += 3;
            }
            DISPATCH_NEXT;
        }

        // Unary operations (12x)
#if USE_COMPUTED_GOTO
        op_0x7B: { // neg-int vA, vB
#else
        case 0x7B: { // neg-int vA, vB
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst] = DX_INT_VALUE(-pinned_regs[src].i);
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x7C: { // not-int vA, vB
#else
        case 0x7C: { // not-int vA, vB
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst] = DX_INT_VALUE(~pinned_regs[src].i);
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x7D: { // neg-long
#else
        case 0x7D: { // neg-long
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_LONG;
            pinned_regs[dst].l = -pinned_regs[src].l;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x7E: { // not-long
#else
        case 0x7E: { // not-long
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_LONG;
            pinned_regs[dst].l = ~pinned_regs[src].l;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x7F: { // neg-float
#else
        case 0x7F: { // neg-float
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_FLOAT;
            pinned_regs[dst].f = -pinned_regs[src].f;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x80: { // neg-double
#else
        case 0x80: { // neg-double
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_DOUBLE;
            pinned_regs[dst].d = -pinned_regs[src].d;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x81: { // int-to-long
#else
        case 0x81: { // int-to-long
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_LONG;
            pinned_regs[dst].l = (int64_t)pinned_regs[src].i;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x82: { // int-to-float
#else
        case 0x82: { // int-to-float
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_FLOAT;
            pinned_regs[dst].f = (float)pinned_regs[src].i;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x83: { // int-to-double
#else
        case 0x83: { // int-to-double
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_DOUBLE;
            pinned_regs[dst].d = (double)pinned_regs[src].i;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x84: { // long-to-int
#else
        case 0x84: { // long-to-int
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst] = DX_INT_VALUE((int32_t)pinned_regs[src].l);
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x85: { // long-to-float
#else
        case 0x85: { // long-to-float
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_FLOAT;
            pinned_regs[dst].f = (float)pinned_regs[src].l;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x86: { // long-to-double
#else
        case 0x86: { // long-to-double
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_DOUBLE;
            pinned_regs[dst].d = (double)pinned_regs[src].l;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x87: { // float-to-int
#else
        case 0x87: { // float-to-int
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst] = DX_INT_VALUE((int32_t)pinned_regs[src].f);
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x88: { // float-to-long
#else
        case 0x88: { // float-to-long
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_LONG;
            pinned_regs[dst].l = (int64_t)pinned_regs[src].f;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x89: { // float-to-double
#else
        case 0x89: { // float-to-double
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_DOUBLE;
            pinned_regs[dst].d = (double)pinned_regs[src].f;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x8A: { // double-to-int
#else
        case 0x8A: { // double-to-int
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst] = DX_INT_VALUE((int32_t)pinned_regs[src].d);
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x8B: { // double-to-long
#else
        case 0x8B: { // double-to-long
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_LONG;
            pinned_regs[dst].l = (int64_t)pinned_regs[src].d;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x8C: { // double-to-float
#else
        case 0x8C: { // double-to-float
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst].tag = DX_VAL_FLOAT;
            pinned_regs[dst].f = (float)pinned_regs[src].d;
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x8D: { // int-to-byte
#else
        case 0x8D: { // int-to-byte
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst] = DX_INT_VALUE((int32_t)(int8_t)(pinned_regs[src].i & 0xFF));
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x8E: { // int-to-char
#else
        case 0x8E: { // int-to-char
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst] = DX_INT_VALUE((int32_t)(uint16_t)(pinned_regs[src].i & 0xFFFF));
            pc += 1;
            DISPATCH_NEXT;
        }
#if USE_COMPUTED_GOTO
        op_0x8F: { // int-to-short
#else
        case 0x8F: { // int-to-short
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            pinned_regs[dst] = DX_INT_VALUE((int32_t)(int16_t)(pinned_regs[src].i & 0xFFFF));
            pc += 1;
            DISPATCH_NEXT;
        }

        // Binary operations (23x): binop vAA, vBB, vCC
#if USE_COMPUTED_GOTO
        op_0x90:
        op_0x91:
        op_0x92:
        op_0x93:
#else
        case 0x90: case 0x91: case 0x92: case 0x93:
#endif
#if USE_COMPUTED_GOTO
        op_0x94:
        op_0x95:
        op_0x96:
        op_0x97:
#else
        case 0x94: case 0x95: case 0x96: case 0x97:
#endif
#if USE_COMPUTED_GOTO
        op_0x98:
        op_0x99:
        op_0x9A:
        op_0x9B:
#else
        case 0x98: case 0x99: case 0x9A: case 0x9B:
#endif
#if USE_COMPUTED_GOTO
        op_0x9C:
        op_0x9D:
        op_0x9E:
        op_0x9F:
#else
        case 0x9C: case 0x9D: case 0x9E: case 0x9F:
#endif
#if USE_COMPUTED_GOTO
        op_0xA0:
        op_0xA1:
        op_0xA2:
        op_0xA3:
#else
        case 0xA0: case 0xA1: case 0xA2: case 0xA3:
#endif
#if USE_COMPUTED_GOTO
        op_0xA4:
        op_0xA5:
        op_0xA6:
        op_0xA7:
#else
        case 0xA4: case 0xA5: case 0xA6: case 0xA7:
#endif
#if USE_COMPUTED_GOTO
        op_0xA8:
        op_0xA9:
        op_0xAA:
        op_0xAB:
#else
        case 0xA8: case 0xA9: case 0xAA: case 0xAB:
#endif
#if USE_COMPUTED_GOTO
        op_0xAC:
        op_0xAD:
        op_0xAE:
        op_0xAF: {
#else
        case 0xAC: case 0xAD: case 0xAE: case 0xAF: {
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint8_t b = code[pc + 1] & 0xFF;
            uint8_t c = (code[pc + 1] >> 8) & 0xFF;
            int32_t vb = pinned_regs[b].i;
            int32_t vc = pinned_regs[c].i;
            int32_t r = 0;
            bool use_int = true;
            switch (opcode) {
                case 0x90: r = vb + vc; break; // add-int
                case 0x91: r = vb - vc; break; // sub-int
                case 0x92: r = vb * vc; break; // mul-int
                case 0x93: // div-int
                    if (vc == 0) {
                        DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/ArithmeticException;", "divide by zero");
                        if (exc && method->code.tries_size > 0) {
                            uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                                   method->code.tries_size, pc, exc);
                            if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                        }
                        if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                        DX_WARN(TAG, "ArithmeticException: divide by zero"); goto done;
                    }
                    // Java: INT_MIN / -1 = INT_MIN (wraps)
                    r = (vb == INT32_MIN && vc == -1) ? INT32_MIN : vb / vc; break;
                case 0x94: // rem-int
                    if (vc == 0) {
                        DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/ArithmeticException;", "divide by zero");
                        if (exc && method->code.tries_size > 0) {
                            uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                                   method->code.tries_size, pc, exc);
                            if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                        }
                        if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                        DX_WARN(TAG, "ArithmeticException: divide by zero"); goto done;
                    }
                    // Java: INT_MIN % -1 = 0
                    r = (vb == INT32_MIN && vc == -1) ? 0 : vb % vc; break;
                case 0x95: r = vb & vc; break; // and-int
                case 0x96: r = vb | vc; break; // or-int
                case 0x97: r = vb ^ vc; break; // xor-int
                case 0x98: r = vb << (vc & 0x1F); break; // shl-int
                case 0x99: r = vb >> (vc & 0x1F); break; // shr-int
                case 0x9A: r = (int32_t)((uint32_t)vb >> (vc & 0x1F)); break; // ushr-int
                // Long operations
                case 0x9B: { int64_t lb = pinned_regs[b].l; int64_t lc = pinned_regs[c].l;
                    pinned_regs[dst].tag = DX_VAL_LONG; pinned_regs[dst].l = lb + lc; use_int = false; break; }
                case 0x9C: { int64_t lb = pinned_regs[b].l; int64_t lc = pinned_regs[c].l;
                    pinned_regs[dst].tag = DX_VAL_LONG; pinned_regs[dst].l = lb - lc; use_int = false; break; }
                case 0x9D: { int64_t lb = pinned_regs[b].l; int64_t lc = pinned_regs[c].l;
                    pinned_regs[dst].tag = DX_VAL_LONG; pinned_regs[dst].l = lb * lc; use_int = false; break; }
                case 0x9E: { int64_t lb = pinned_regs[b].l; int64_t lc = pinned_regs[c].l;
                    if (lc == 0) {
                        DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/ArithmeticException;", "divide by zero");
                        if (exc && method->code.tries_size > 0) {
                            uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                                   method->code.tries_size, pc, exc);
                            if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                        }
                        if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                        goto done;
                    }
                    // LLONG_MIN / -1 = LLONG_MIN in Java
                    pinned_regs[dst].tag = DX_VAL_LONG;
                    pinned_regs[dst].l = (lb == INT64_MIN && lc == -1) ? INT64_MIN : lb / lc;
                    use_int = false; break; }
                case 0x9F: { int64_t lb = pinned_regs[b].l; int64_t lc = pinned_regs[c].l;
                    if (lc == 0) {
                        DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/ArithmeticException;", "divide by zero");
                        if (exc && method->code.tries_size > 0) {
                            uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                                   method->code.tries_size, pc, exc);
                            if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                        }
                        if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                        goto done;
                    }
                    pinned_regs[dst].tag = DX_VAL_LONG;
                    pinned_regs[dst].l = (lb == INT64_MIN && lc == -1) ? 0 : lb % lc;
                    use_int = false; break; }
                case 0xA0: { int64_t lb = pinned_regs[b].l; int64_t lc = pinned_regs[c].l;
                    pinned_regs[dst].tag = DX_VAL_LONG; pinned_regs[dst].l = lb & lc; use_int = false; break; }
                case 0xA1: { int64_t lb = pinned_regs[b].l; int64_t lc = pinned_regs[c].l;
                    pinned_regs[dst].tag = DX_VAL_LONG; pinned_regs[dst].l = lb | lc; use_int = false; break; }
                case 0xA2: { int64_t lb = pinned_regs[b].l; int64_t lc = pinned_regs[c].l;
                    pinned_regs[dst].tag = DX_VAL_LONG; pinned_regs[dst].l = lb ^ lc; use_int = false; break; }
                case 0xA3: { int64_t lb = pinned_regs[b].l; int32_t shift = pinned_regs[c].i;
                    pinned_regs[dst].tag = DX_VAL_LONG; pinned_regs[dst].l = lb << (shift & 0x3F); use_int = false; break; }
                case 0xA4: { int64_t lb = pinned_regs[b].l; int32_t shift = pinned_regs[c].i;
                    pinned_regs[dst].tag = DX_VAL_LONG; pinned_regs[dst].l = lb >> (shift & 0x3F); use_int = false; break; }
                case 0xA5: { int64_t lb = pinned_regs[b].l; int32_t shift = pinned_regs[c].i;
                    pinned_regs[dst].tag = DX_VAL_LONG; pinned_regs[dst].l = (int64_t)((uint64_t)lb >> (shift & 0x3F)); use_int = false; break; }
                // Float operations
                case 0xA6: { float fb = pinned_regs[b].f; float fc = pinned_regs[c].f;
                    pinned_regs[dst].tag = DX_VAL_FLOAT; pinned_regs[dst].f = fb + fc; use_int = false; break; }
                case 0xA7: { float fb = pinned_regs[b].f; float fc = pinned_regs[c].f;
                    pinned_regs[dst].tag = DX_VAL_FLOAT; pinned_regs[dst].f = fb - fc; use_int = false; break; }
                case 0xA8: { float fb = pinned_regs[b].f; float fc = pinned_regs[c].f;
                    pinned_regs[dst].tag = DX_VAL_FLOAT; pinned_regs[dst].f = fb * fc; use_int = false; break; }
                case 0xA9: { float fb = pinned_regs[b].f; float fc = pinned_regs[c].f;
                    pinned_regs[dst].tag = DX_VAL_FLOAT; pinned_regs[dst].f = fc != 0 ? fb / fc : 0; use_int = false; break; }
                case 0xAA: { float fb = pinned_regs[b].f; float fc = pinned_regs[c].f;
                    pinned_regs[dst].tag = DX_VAL_FLOAT; pinned_regs[dst].f = fmodf(fb, fc); use_int = false; break; }
                // Double operations
                case 0xAB: { double db = pinned_regs[b].d; double dc = pinned_regs[c].d;
                    pinned_regs[dst].tag = DX_VAL_DOUBLE; pinned_regs[dst].d = db + dc; use_int = false; break; }
                case 0xAC: { double db = pinned_regs[b].d; double dc = pinned_regs[c].d;
                    pinned_regs[dst].tag = DX_VAL_DOUBLE; pinned_regs[dst].d = db - dc; use_int = false; break; }
                case 0xAD: { double db = pinned_regs[b].d; double dc = pinned_regs[c].d;
                    pinned_regs[dst].tag = DX_VAL_DOUBLE; pinned_regs[dst].d = db * dc; use_int = false; break; }
                case 0xAE: { double db = pinned_regs[b].d; double dc = pinned_regs[c].d;
                    pinned_regs[dst].tag = DX_VAL_DOUBLE; pinned_regs[dst].d = dc != 0 ? db / dc : 0; use_int = false; break; }
                case 0xAF: { double db = pinned_regs[b].d; double dc = pinned_regs[c].d;
                    pinned_regs[dst].tag = DX_VAL_DOUBLE; pinned_regs[dst].d = fmod(db, dc); use_int = false; break; }
                default: r = 0; break;
            }
            if (use_int) pinned_regs[dst] = DX_INT_VALUE(r);
            pc += 2;
            DISPATCH_NEXT;
        }

        // Binary operations /2addr (12x): binop/2addr vA, vB
#if USE_COMPUTED_GOTO
        op_0xB0:
        op_0xB1:
        op_0xB2:
        op_0xB3:
#else
        case 0xB0: case 0xB1: case 0xB2: case 0xB3:
#endif
#if USE_COMPUTED_GOTO
        op_0xB4:
        op_0xB5:
        op_0xB6:
        op_0xB7:
#else
        case 0xB4: case 0xB5: case 0xB6: case 0xB7:
#endif
#if USE_COMPUTED_GOTO
        op_0xB8:
        op_0xB9:
        op_0xBA:
        op_0xBB:
#else
        case 0xB8: case 0xB9: case 0xBA: case 0xBB:
#endif
#if USE_COMPUTED_GOTO
        op_0xBC:
        op_0xBD:
        op_0xBE:
        op_0xBF:
#else
        case 0xBC: case 0xBD: case 0xBE: case 0xBF:
#endif
#if USE_COMPUTED_GOTO
        op_0xC0:
        op_0xC1:
        op_0xC2:
        op_0xC3:
#else
        case 0xC0: case 0xC1: case 0xC2: case 0xC3:
#endif
#if USE_COMPUTED_GOTO
        op_0xC4:
        op_0xC5:
        op_0xC6:
        op_0xC7:
#else
        case 0xC4: case 0xC5: case 0xC6: case 0xC7:
#endif
#if USE_COMPUTED_GOTO
        op_0xC8:
        op_0xC9:
        op_0xCA:
        op_0xCB:
#else
        case 0xC8: case 0xC9: case 0xCA: case 0xCB:
#endif
#if USE_COMPUTED_GOTO
        op_0xCC:
        op_0xCD:
        op_0xCE:
        op_0xCF: {
#else
        case 0xCC: case 0xCD: case 0xCE: case 0xCF: {
#endif
            uint8_t a = (inst >> 8) & 0x0F;
            uint8_t b = (inst >> 12) & 0x0F;
            int32_t va = pinned_regs[a].i;
            int32_t vb = pinned_regs[b].i;
            int32_t r = 0;
            bool use_int_2addr = true;
            switch (opcode) {
                case 0xB0: r = va + vb; break; // add-int/2addr
                case 0xB1: r = va - vb; break; // sub-int/2addr
                case 0xB2: r = va * vb; break; // mul-int/2addr
                case 0xB3: // div-int/2addr
                    if (vb == 0) {
                        DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/ArithmeticException;", "divide by zero");
                        if (exc && method->code.tries_size > 0) {
                            uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                                   method->code.tries_size, pc, exc);
                            if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                        }
                        if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                        DX_WARN(TAG, "ArithmeticException: divide by zero"); goto done;
                    }
                    r = (va == INT32_MIN && vb == -1) ? INT32_MIN : va / vb; break;
                case 0xB4: // rem-int/2addr
                    if (vb == 0) {
                        DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/ArithmeticException;", "divide by zero");
                        if (exc && method->code.tries_size > 0) {
                            uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                                   method->code.tries_size, pc, exc);
                            if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                        }
                        if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                        DX_WARN(TAG, "ArithmeticException: divide by zero"); goto done;
                    }
                    r = (va == INT32_MIN && vb == -1) ? 0 : va % vb; break;
                case 0xB5: r = va & vb; break; // and-int/2addr
                case 0xB6: r = va | vb; break; // or-int/2addr
                case 0xB7: r = va ^ vb; break; // xor-int/2addr
                case 0xB8: r = va << (vb & 0x1F); break; // shl-int/2addr
                case 0xB9: r = va >> (vb & 0x1F); break; // shr-int/2addr
                case 0xBA: r = (int32_t)((uint32_t)va >> (vb & 0x1F)); break; // ushr-int/2addr
                // Long operations /2addr
                case 0xBB: { int64_t la = pinned_regs[a].l; int64_t lb = pinned_regs[b].l;
                    pinned_regs[a].tag = DX_VAL_LONG; pinned_regs[a].l = la + lb; use_int_2addr = false; break; }
                case 0xBC: { int64_t la = pinned_regs[a].l; int64_t lb = pinned_regs[b].l;
                    pinned_regs[a].tag = DX_VAL_LONG; pinned_regs[a].l = la - lb; use_int_2addr = false; break; }
                case 0xBD: { int64_t la = pinned_regs[a].l; int64_t lb = pinned_regs[b].l;
                    pinned_regs[a].tag = DX_VAL_LONG; pinned_regs[a].l = la * lb; use_int_2addr = false; break; }
                case 0xBE: { int64_t la = pinned_regs[a].l; int64_t lb2 = pinned_regs[b].l;
                    if (lb2 == 0) {
                        DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/ArithmeticException;", "divide by zero");
                        if (exc && method->code.tries_size > 0) {
                            uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                                   method->code.tries_size, pc, exc);
                            if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                        }
                        if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                        goto done;
                    }
                    pinned_regs[a].tag = DX_VAL_LONG;
                    pinned_regs[a].l = (la == INT64_MIN && lb2 == -1) ? INT64_MIN : la / lb2;
                    use_int_2addr = false; break; }
                case 0xBF: { int64_t la = pinned_regs[a].l; int64_t lb2 = pinned_regs[b].l;
                    if (lb2 == 0) {
                        DxObject *exc = dx_vm_create_exception(vm, "Ljava/lang/ArithmeticException;", "divide by zero");
                        if (exc && method->code.tries_size > 0) {
                            uint32_t handler = find_catch_handler(vm, frame, code, code_size,
                                                                   method->code.tries_size, pc, exc);
                            if (handler != UINT32_MAX) { pc = handler; goto next_instruction; }
                        }
                        if (exc) { vm->pending_exception = exc; exec_result = DX_ERR_EXCEPTION; goto done; }
                        goto done;
                    }
                    pinned_regs[a].tag = DX_VAL_LONG;
                    pinned_regs[a].l = (la == INT64_MIN && lb2 == -1) ? 0 : la % lb2;
                    use_int_2addr = false; break; }
                case 0xC0: { int64_t la = pinned_regs[a].l; int64_t lb = pinned_regs[b].l;
                    pinned_regs[a].tag = DX_VAL_LONG; pinned_regs[a].l = la & lb; use_int_2addr = false; break; }
                case 0xC1: { int64_t la = pinned_regs[a].l; int64_t lb = pinned_regs[b].l;
                    pinned_regs[a].tag = DX_VAL_LONG; pinned_regs[a].l = la | lb; use_int_2addr = false; break; }
                case 0xC2: { int64_t la = pinned_regs[a].l; int64_t lb = pinned_regs[b].l;
                    pinned_regs[a].tag = DX_VAL_LONG; pinned_regs[a].l = la ^ lb; use_int_2addr = false; break; }
                case 0xC3: { int64_t la = pinned_regs[a].l; int32_t shift = pinned_regs[b].i;
                    pinned_regs[a].tag = DX_VAL_LONG; pinned_regs[a].l = la << (shift & 0x3F); use_int_2addr = false; break; }
                case 0xC4: { int64_t la = pinned_regs[a].l; int32_t shift = pinned_regs[b].i;
                    pinned_regs[a].tag = DX_VAL_LONG; pinned_regs[a].l = la >> (shift & 0x3F); use_int_2addr = false; break; }
                case 0xC5: { int64_t la = pinned_regs[a].l; int32_t shift = pinned_regs[b].i;
                    pinned_regs[a].tag = DX_VAL_LONG; pinned_regs[a].l = (int64_t)((uint64_t)la >> (shift & 0x3F)); use_int_2addr = false; break; }
                // Float operations /2addr
                case 0xC6: { float fa = pinned_regs[a].f; float fb2 = pinned_regs[b].f;
                    pinned_regs[a].tag = DX_VAL_FLOAT; pinned_regs[a].f = fa + fb2; use_int_2addr = false; break; }
                case 0xC7: { float fa = pinned_regs[a].f; float fb2 = pinned_regs[b].f;
                    pinned_regs[a].tag = DX_VAL_FLOAT; pinned_regs[a].f = fa - fb2; use_int_2addr = false; break; }
                case 0xC8: { float fa = pinned_regs[a].f; float fb2 = pinned_regs[b].f;
                    pinned_regs[a].tag = DX_VAL_FLOAT; pinned_regs[a].f = fa * fb2; use_int_2addr = false; break; }
                case 0xC9: { float fa = pinned_regs[a].f; float fb2 = pinned_regs[b].f;
                    pinned_regs[a].tag = DX_VAL_FLOAT; pinned_regs[a].f = fb2 != 0 ? fa / fb2 : 0; use_int_2addr = false; break; }
                case 0xCA: { float fa = pinned_regs[a].f; float fb2 = pinned_regs[b].f;
                    pinned_regs[a].tag = DX_VAL_FLOAT; pinned_regs[a].f = fmodf(fa, fb2); use_int_2addr = false; break; }
                // Double operations /2addr
                case 0xCB: { double da = pinned_regs[a].d; double db2 = pinned_regs[b].d;
                    pinned_regs[a].tag = DX_VAL_DOUBLE; pinned_regs[a].d = da + db2; use_int_2addr = false; break; }
                case 0xCC: { double da = pinned_regs[a].d; double db2 = pinned_regs[b].d;
                    pinned_regs[a].tag = DX_VAL_DOUBLE; pinned_regs[a].d = da - db2; use_int_2addr = false; break; }
                case 0xCD: { double da = pinned_regs[a].d; double db2 = pinned_regs[b].d;
                    pinned_regs[a].tag = DX_VAL_DOUBLE; pinned_regs[a].d = da * db2; use_int_2addr = false; break; }
                case 0xCE: { double da = pinned_regs[a].d; double db2 = pinned_regs[b].d;
                    pinned_regs[a].tag = DX_VAL_DOUBLE; pinned_regs[a].d = db2 != 0 ? da / db2 : 0; use_int_2addr = false; break; }
                case 0xCF: { double da = pinned_regs[a].d; double db2 = pinned_regs[b].d;
                    pinned_regs[a].tag = DX_VAL_DOUBLE; pinned_regs[a].d = fmod(da, db2); use_int_2addr = false; break; }
                default: r = 0; break;
            }
            if (use_int_2addr) pinned_regs[a] = DX_INT_VALUE(r);
            pc += 1;
            DISPATCH_NEXT;
        }

        // binop/lit16 (22s): binop/lit16 vA, vB, #+CCCC
#if USE_COMPUTED_GOTO
        op_0xD0:
        op_0xD1:
        op_0xD2:
        op_0xD3:
#else
        case 0xD0: case 0xD1: case 0xD2: case 0xD3:
#endif
#if USE_COMPUTED_GOTO
        op_0xD4:
        op_0xD5:
        op_0xD6:
        op_0xD7: {
#else
        case 0xD4: case 0xD5: case 0xD6: case 0xD7: {
#endif
            uint8_t dst = (inst >> 8) & 0x0F;
            uint8_t src = (inst >> 12) & 0x0F;
            int16_t lit = (int16_t)code[pc + 1];
            int32_t va = pinned_regs[src].i;
            int32_t r = 0;
            switch (opcode) {
                case 0xD0: r = va + lit; break; // add-int/lit16
                case 0xD1: r = (int32_t)lit - va; break; // rsub-int
                case 0xD2: r = va * lit; break; // mul-int/lit16
                case 0xD3: r = lit ? ((va == INT32_MIN && lit == -1) ? INT32_MIN : va / lit) : 0; break;
                case 0xD4: r = lit ? ((va == INT32_MIN && lit == -1) ? 0 : va % lit) : 0; break;
                case 0xD5: r = va & lit; break; // and-int/lit16
                case 0xD6: r = va | lit; break; // or-int/lit16
                case 0xD7: r = va ^ lit; break; // xor-int/lit16
            }
            pinned_regs[dst] = DX_INT_VALUE(r);
            pc += 2;
            DISPATCH_NEXT;
        }

        // binop/lit8 (22b): binop/lit8 vAA, vBB, #+CC
#if USE_COMPUTED_GOTO
        op_0xD8:
        op_0xD9:
        op_0xDA:
        op_0xDB:
#else
        case 0xD8: case 0xD9: case 0xDA: case 0xDB:
#endif
#if USE_COMPUTED_GOTO
        op_0xDC:
        op_0xDD:
        op_0xDE:
        op_0xDF:
#else
        case 0xDC: case 0xDD: case 0xDE: case 0xDF:
#endif
#if USE_COMPUTED_GOTO
        op_0xE0:
        op_0xE1:
        op_0xE2: {
#else
        case 0xE0: case 0xE1: case 0xE2: {
#endif
            uint8_t dst = (inst >> 8) & 0xFF;
            uint8_t src = code[pc + 1] & 0xFF;
            int8_t lit = (int8_t)((code[pc + 1] >> 8) & 0xFF);
            int32_t va = pinned_regs[src].i;
            int32_t r = 0;
            switch (opcode) {
                case 0xD8: r = va + lit; break; // add-int/lit8
                case 0xD9: r = (int32_t)lit - va; break; // rsub-int/lit8
                case 0xDA: r = va * lit; break; // mul-int/lit8
                case 0xDB: r = lit ? ((va == INT32_MIN && lit == -1) ? INT32_MIN : va / lit) : 0; break;
                case 0xDC: r = lit ? ((va == INT32_MIN && lit == -1) ? 0 : va % lit) : 0; break;
                case 0xDD: r = va & lit; break; // and-int/lit8
                case 0xDE: r = va | lit; break; // or-int/lit8
                case 0xDF: r = va ^ lit; break; // xor-int/lit8
                case 0xE0: r = va << (lit & 0x1F); break; // shl-int/lit8
                case 0xE1: r = va >> (lit & 0x1F); break; // shr-int/lit8
                case 0xE2: r = (int32_t)((uint32_t)va >> (lit & 0x1F)); break; // ushr-int/lit8
            }
            pinned_regs[dst] = DX_INT_VALUE(r);
            pc += 2;
            DISPATCH_NEXT;
        }

        // invoke-polymorphic (45cc format, 4 code units)
#if USE_COMPUTED_GOTO
        op_0xFA: {
#else
        case 0xFA: {
#endif
            // Format 45cc: [A|G|op BBBB F|E|D|C HHHH]
            // B = method ref, H = proto index, A = arg count, C..G = arg regs
            uint16_t method_idx = code[pc + 1];
            uint16_t proto_idx = code[pc + 3];
            uint8_t poly_argc;
            uint8_t poly_arg_regs[5];
            decode_35c_args(code, pc, &poly_argc, poly_arg_regs);

            // First arg register holds the MethodHandle receiver
            if (poly_argc < 1) {
                DX_WARN(TAG, "invoke-polymorphic: no args (need at least MethodHandle receiver)");
                frame->result = DX_NULL_VALUE;
                frame->has_result = true;
                pc += 4;
                DISPATCH_NEXT;
            }

            DxObject *mh_obj = (pinned_regs[poly_arg_regs[0]].tag == DX_VAL_OBJ)
                               ? pinned_regs[poly_arg_regs[0]].obj : NULL;
            if (!mh_obj) {
                DX_WARN(TAG, "invoke-polymorphic: null MethodHandle at v%u", poly_arg_regs[0]);
                frame->result = DX_NULL_VALUE;
                frame->has_result = true;
                pc += 4;
                DISPATCH_NEXT;
            }

            // Check if this is invokeExact (verify proto matches)
            const char *mname = dx_dex_get_method_name(cur_dex, method_idx);
            bool is_exact = (mname && strcmp(mname, "invokeExact") == 0);
            (void)is_exact;  // proto verification logged but non-fatal
            (void)proto_idx;

            // Remaining args (after the MethodHandle receiver) are the actual call args
            uint8_t call_argc = poly_argc - 1;
            DxValue call_args[5];
            for (uint8_t ai = 0; ai < call_argc && ai < 5; ai++) {
                call_args[ai] = pinned_regs[poly_arg_regs[ai + 1]];
            }

            DxValue poly_result;
            poly_result = DX_NULL_VALUE;
            DxResult hr = dx_vm_invoke_method_handle(vm, mh_obj, call_args, call_argc, &poly_result);
            if (hr != DX_OK) {
                exec_result = hr;
                goto done;
            }
            frame->result = poly_result;
            frame->has_result = true;
            pc += 4;
            DISPATCH_NEXT;
        }

        // invoke-polymorphic/range (4rcc format, 4 code units)
#if USE_COMPUTED_GOTO
        op_0xFB: {
#else
        case 0xFB: {
#endif
            // Format 4rcc: [AA|op BBBB CCCC HHHH]
            // B = method ref, H = proto index, A = arg count, C = first register
            uint16_t method_idx_r = code[pc + 1];
            uint8_t range_argc = (inst >> 8) & 0xFF;
            uint16_t first_reg = code[pc + 2];
            uint16_t proto_idx_r = code[pc + 3];

            if (range_argc < 1) {
                DX_WARN(TAG, "invoke-polymorphic/range: no args");
                frame->result = DX_NULL_VALUE;
                frame->has_result = true;
                pc += 4;
                DISPATCH_NEXT;
            }

            DxObject *mh_obj_r = (pinned_regs[first_reg].tag == DX_VAL_OBJ)
                                 ? pinned_regs[first_reg].obj : NULL;
            if (!mh_obj_r) {
                DX_WARN(TAG, "invoke-polymorphic/range: null MethodHandle at v%u", first_reg);
                frame->result = DX_NULL_VALUE;
                frame->has_result = true;
                pc += 4;
                DISPATCH_NEXT;
            }

            const char *mname_r = dx_dex_get_method_name(cur_dex, method_idx_r);
            bool is_exact_r = (mname_r && strcmp(mname_r, "invokeExact") == 0);
            (void)is_exact_r;
            (void)proto_idx_r;

            // Remaining args after MethodHandle receiver
            uint32_t call_argc_r = range_argc - 1;
            if (call_argc_r > DX_MAX_REGISTERS) call_argc_r = DX_MAX_REGISTERS;
            DxValue range_call_args[DX_MAX_REGISTERS];
            for (uint32_t ai = 0; ai < call_argc_r; ai++) {
                range_call_args[ai] = pinned_regs[first_reg + 1 + ai];
            }

            DxValue poly_result_r;
            poly_result_r = DX_NULL_VALUE;
            DxResult hr_r = dx_vm_invoke_method_handle(vm, mh_obj_r, range_call_args, (int)call_argc_r, &poly_result_r);
            if (hr_r != DX_OK) {
                exec_result = hr_r;
                goto done;
            }
            frame->result = poly_result_r;
            frame->has_result = true;
            pc += 4;
            DISPATCH_NEXT;
        }

        // invoke-custom (35c format, 3 code units)
#if USE_COMPUTED_GOTO
        op_0xFC: {
#else
        case 0xFC: {
#endif
            uint16_t call_site_idx = code[pc + 1];
            uint8_t argc;
            uint8_t arg_regs[5];
            decode_35c_args(code, pc, &argc, arg_regs);

            DxValue ic_args[5];
            for (uint8_t ai = 0; ai < argc && ai < 5; ai++) {
                ic_args[ai] = pinned_regs[arg_regs[ai]];
            }

            exec_result = dx_vm_invoke_custom(vm, frame, call_site_idx, ic_args, argc);
            if (exec_result != DX_OK) goto done;
            pc += 3;
            DISPATCH_NEXT;
        }

        // invoke-custom/range (3rc format, 3 code units)
#if USE_COMPUTED_GOTO
        op_0xFD: {
#else
        case 0xFD: {
#endif
            uint16_t call_site_idx = code[pc + 1];
            uint8_t argc = (inst >> 8) & 0xFF;
            uint16_t first_reg = code[pc + 2];

            DxValue ic_args[DX_MAX_REGISTERS];
            uint32_t actual_argc = argc;
            if (actual_argc > DX_MAX_REGISTERS) actual_argc = DX_MAX_REGISTERS;
            for (uint32_t ai = 0; ai < actual_argc; ai++) {
                ic_args[ai] = pinned_regs[first_reg + ai];
            }

            exec_result = dx_vm_invoke_custom(vm, frame, call_site_idx, ic_args, actual_argc);
            if (exec_result != DX_OK) goto done;
            pc += 3;
            DISPATCH_NEXT;
        }

        // const-method-handle (21c format, 2 code units)
#if USE_COMPUTED_GOTO
        op_0xFE: {
#else
        case 0xFE: {
#endif
            uint8_t mh_dst = (inst >> 8) & 0xFF;
            uint16_t mh_idx = code[pc + 1];
            if (cur_dex && mh_idx < cur_dex->method_handle_count && cur_dex->method_handles) {
                const DxMethodHandle *mh = &cur_dex->method_handles[mh_idx];
                DxClass *mh_cls = dx_vm_find_class(vm, "Ljava/lang/invoke/MethodHandle;");
                DxObject *mh_obj = NULL;
                if (mh_cls) {
                    mh_obj = dx_vm_alloc_object(vm, mh_cls);
                }
                if (!mh_obj) {
                    mh_obj = dx_vm_alloc_array(vm, 0);
                    if (mh_obj) {
                        mh_obj->is_array = false;
                        mh_obj->fields = (DxValue *)dx_malloc(sizeof(DxValue) * 4);
                        if (mh_obj->fields) {
                            memset(mh_obj->fields, 0, sizeof(DxValue) * 4);
                        }
                    }
                }
                if (mh_obj && mh_obj->fields) {
                    mh_obj->fields[0] = DX_INT_VALUE((int32_t)mh->method_handle_type);
                    mh_obj->fields[1] = DX_INT_VALUE((int32_t)mh->field_or_method_id);
                    mh_obj->fields[2].tag = DX_VAL_LONG;
                    mh_obj->fields[2].l = (int64_t)(uintptr_t)cur_dex;
                }
                pinned_regs[mh_dst] = mh_obj ? DX_OBJ_VALUE(mh_obj) : DX_NULL_VALUE;
            } else {
                DX_WARN(TAG, "const-method-handle: index %u out of range (count=%u)",
                         mh_idx, cur_dex ? cur_dex->method_handle_count : 0);
                pinned_regs[mh_dst] = DX_NULL_VALUE;
            }
            pc += 2;
            DISPATCH_NEXT;
        }

        // const-method-type (21c format, 2 code units)
#if USE_COMPUTED_GOTO
        op_0xFF: {
#else
        case 0xFF: {
#endif
            uint8_t mt_dst = (inst >> 8) & 0xFF;
            uint16_t mt_proto_idx = code[pc + 1];
            if (cur_dex && mt_proto_idx < cur_dex->proto_count) {
                const DxDexProtoId *proto = &cur_dex->proto_ids[mt_proto_idx];
                const char *shorty = dx_dex_get_string(cur_dex, proto->shorty_idx);
                const char *ret_type = dx_dex_get_type(cur_dex, proto->return_type_idx);
                char mt_desc[256];
                snprintf(mt_desc, sizeof(mt_desc), "(%s)%s",
                         shorty ? shorty : "?", ret_type ? ret_type : "V");
                DxObject *mt_obj = dx_vm_create_string(vm, mt_desc);
                if (mt_obj) {
                    DxClass *mt_cls = dx_vm_find_class(vm, "Ljava/lang/invoke/MethodType;");
                    if (mt_cls) {
                        mt_obj->klass = mt_cls;
                    }
                }
                pinned_regs[mt_dst] = mt_obj ? DX_OBJ_VALUE(mt_obj) : DX_NULL_VALUE;
            } else {
                DX_WARN(TAG, "const-method-type: proto index %u out of range (count=%u)",
                         mt_proto_idx, cur_dex ? cur_dex->proto_count : 0);
                pinned_regs[mt_dst] = DX_NULL_VALUE;
            }
            pc += 2;
            DISPATCH_NEXT;
        }

#if USE_COMPUTED_GOTO
        op_default: {
#else
        default: {
#endif
            const char *op_name = dx_opcode_name(opcode);
            const char *cls_desc = method->declaring_class ? method->declaring_class->descriptor : "?";
            const char *mth_name = method->name ? method->name : "?";
            DX_WARN(TAG, "Unsupported opcode 0x%02x (%s) at pc=%u in %s.%s - skipping",
                     opcode, op_name, pc, cls_desc, mth_name);
            snprintf(vm->error_msg, sizeof(vm->error_msg),
                     "Unsupported feature: opcode 0x%02x (%s) at pc=%u in %s.%s",
                     opcode, op_name, pc, cls_desc, mth_name);
            // Skip by instruction width instead of failing
            uint32_t width = dx_opcode_width(opcode);
            pc += width;
            DISPATCH_NEXT;
        }
#if !USE_COMPUTED_GOTO
        } // end switch
#endif
    }

done:
    #undef DISPATCH_NEXT
    #undef CODE_AT
    #undef CHECK_REG
    #undef INSN_TRACE_SIZE

    // Before leaving the method on an exception path, check if the current PC
    // falls inside a try block with a catch-all (finally) handler that wasn't
    // already tried by the inline exception dispatch.  This covers cases where
    // an exception was created + goto done without going through find_catch_handler
    // (e.g. some runtime errors), or where find_catch_handler matched a typed
    // handler but there's also a finally on an outer try block.
    if (exec_result == DX_ERR_EXCEPTION && vm->pending_exception &&
        method->code.tries_size > 0) {
        uint32_t finally_addr = find_catch_handler(vm, frame, code, code_size,
                                                    method->code.tries_size, pc,
                                                    vm->pending_exception);
        if (finally_addr != UINT32_MAX) {
            DX_DEBUG(TAG, "Exception finally handler at %u in %s.%s (exit path)",
                     finally_addr,
                     method->declaring_class ? method->declaring_class->descriptor : "?",
                     method->name);
            vm->pending_exception = NULL;
            exec_result = DX_OK;
            pc = finally_addr;
            goto next_instruction;
        }
    }

    // Capture diagnostic info on error
    if (exec_result != DX_OK) {
        vm->diag.has_error = true;
        snprintf(vm->diag.method_name, sizeof(vm->diag.method_name), "%s.%s",
                 method->declaring_class ? method->declaring_class->descriptor : "?",
                 method->name ? method->name : "?");
        vm->diag.pc = pc;
        if (pc < code_size) {
            vm->diag.opcode = code[pc] & 0xFF;
        } else {
            vm->diag.opcode = 0;
        }
        snprintf(vm->diag.opcode_name, sizeof(vm->diag.opcode_name), "%s",
                 dx_opcode_name(vm->diag.opcode));

        // Snapshot registers (up to 16)
        uint16_t snap_count = method->code.registers_size;
        if (snap_count > 16) snap_count = 16;
        vm->diag.reg_count = snap_count;
        for (uint32_t r = 0; r < snap_count; r++) {
            vm->diag.registers[r] = frame->registers[r];
        }

        // Build stack trace from frame chain
        size_t spos = 0;
        vm->diag.stack_trace[0] = '\0';
        DxFrame *sf = frame;
        int depth = 0;
        while (sf && depth < 32 && spos < sizeof(vm->diag.stack_trace) - 80) {
            if (sf->method) {
                spos += (size_t)snprintf(vm->diag.stack_trace + spos,
                                 sizeof(vm->diag.stack_trace) - spos,
                                 "    at %s.%s (pc=%u)\n",
                                 sf->method->declaring_class ? sf->method->declaring_class->descriptor : "?",
                                 sf->method->name ? sf->method->name : "?",
                                 sf->pc);
            }
            sf = sf->caller;
            depth++;
        }
    }

    // Profiling: accumulate method execution time
    if (vm->profiling_enabled && _prof_start_ns > 0) {
        uint64_t elapsed_ns = dx_current_time_ns() - _prof_start_ns;
        method->total_time_ns += elapsed_ns;
        method->call_count++;
    }

    // Debug tracing: method exit
    if (_trace_method_active) {
        vm->debug.trace_depth--;
        DX_INFO("Trace", "%*sEXIT  %s->%s (result=%s)",
                vm->debug.trace_depth * 2, "", _trace_cls, _trace_mth,
                dx_result_string(exec_result));
    }

    vm->stack_depth--;
    vm->current_frame = frame->caller;

    if (frame->has_result && result) {
        *result = frame->result;
    }

    dx_vm_free_frame(vm, frame);
    return exec_result;
}

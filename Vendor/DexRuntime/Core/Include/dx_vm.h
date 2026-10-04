#ifndef DX_VM_H
#define DX_VM_H

#include "dx_types.h"
#include "dx_dex.h"

// Release vs Debug build configuration
#ifdef NDEBUG
#define DX_RELEASE 1
#else
#define DX_RELEASE 0
#endif

// Class status
typedef enum {
    DX_CLASS_NOT_LOADED = 0,
    DX_CLASS_LOADING,
    DX_CLASS_LOADED,
    DX_CLASS_INITIALIZING,
    DX_CLASS_INITIALIZED,
    DX_CLASS_ERROR,
} DxClassStatus;

// Runtime class representation
struct DxClass {
    const char      *descriptor;        // e.g., "Lcom/example/Main;"
    DxClass         *super_class;
    DxClassStatus    status;
    uint32_t         access_flags;

    // Interfaces
    const char     **interfaces;        // interface descriptors this class implements
    uint32_t         interface_count;

    // Fields
    uint32_t         instance_field_count;
    uint32_t         static_field_count;
    struct {
        const char  *name;
        const char  *type;
        uint32_t     flags;
        uint32_t     slot_index;    // precomputed absolute slot in obj->fields[]
        bool         is_volatile;   // ACC_VOLATILE (0x0040) -- memory barrier semantics
    } *field_defs;
    DxValue         *static_fields;     // array[static_field_count]

    // Methods
    DxMethod        *direct_methods;
    uint32_t         direct_method_count;
    DxMethod        *virtual_methods;
    uint32_t         virtual_method_count;

    // VTable (flattened: super virtuals + own virtuals)
    DxMethod       **vtable;
    uint32_t         vtable_size;

    // ITable (interface method dispatch table)
    struct {
        const char *interface_desc;
        DxMethod **methods;
        int method_count;
    } *itable;
    int itable_count;

    // Annotations (with element values)
    DxAnnotationEntry *annotations;
    uint32_t annotation_count;

    // DEX origin
    DxDexFile       *dex_file;          // which DEX file this class came from
    uint32_t         dex_class_def_idx;
    uint8_t          source_dex_idx;    // index into vm->dex_files[] this class came from
    bool             is_framework;      // true for built-in Android stubs
};

// Inline cache for monomorphic/polymorphic call site optimization
#define DX_IC_SIZE 4  // max polymorphic cache entries per call site

typedef struct {
    DxClass  *receiver_class;
    DxMethod *resolved_method;
} DxICEntry;

typedef struct {
    DxICEntry entries[DX_IC_SIZE];
    uint8_t   count;       // how many entries populated (0..DX_IC_SIZE)
    uint32_t  hits;        // cache hit count
    uint32_t  misses;      // cache miss count
} DxInlineCache;

// Inline cache table: maps PC offsets to inline caches within a method
#define DX_IC_TABLE_SIZE 32  // hash table slots per method

typedef struct {
    uint32_t       pc;     // PC offset of the invoke instruction (0 = empty)
    DxInlineCache  ic;
} DxICSlot;

typedef struct {
    DxICSlot slots[DX_IC_TABLE_SIZE];
} DxICTable;

// Native method implementation signature
typedef DxResult (*DxNativeMethodFn)(DxVM *vm, DxFrame *frame, DxValue *args, uint32_t arg_count);

// Runtime method representation
struct DxMethod {
    const char        *name;
    const char        *shorty;          // return+param type chars
    DxClass           *declaring_class;
    uint32_t           access_flags;
    uint32_t           dex_method_idx;

    // Bytecode (NULL for native methods)
    DxDexCodeItem      code;
    bool               has_code;

    // Native implementation (for framework stubs)
    DxNativeMethodFn   native_fn;
    bool               is_native;

    // Verification flag (set after bytecode passes structural verification)
    bool               verified;

    // VTable index (-1 if not virtual)
    int32_t            vtable_idx;

    // Inline cache table for invoke-virtual/interface call sites
    DxICTable         *ic_table;     // lazily allocated on first invoke-virtual

    // Method inlining for trivial getters/setters
    uint8_t            inline_type;       // 0=none, 1=getter, 2=setter
    uint16_t           inline_field_idx;  // field index for inlined getter/setter
    bool               analyzed_for_inline; // true after inline analysis performed

    // Profiling: method-level execution time
    uint64_t           total_time_ns;     // accumulated wall-clock time in this method
    uint32_t           call_count;        // number of times this method was invoked

    // Annotations (with element values)
    DxAnnotationEntry *annotations;
    uint32_t           annotation_count;
};

// Runtime object
struct DxObject {
    DxClass   *klass;
    DxValue   *fields;          // array[klass->instance_field_count]
    uint32_t   ref_count;
    uint32_t   heap_idx;        // index in VM heap
    bool       gc_mark;         // used by mark-sweep GC
    uint8_t    generation;      // 0 = young, 1 = old (generational GC)

    // For View objects: link to UI node
    DxUINode  *ui_node;

    // String storage (owned; freed with object)
    char      *string_data;     // UTF-8 C string for java.lang.String / StringBuilder buf

    // Array support
    bool       is_array;
    uint32_t   array_length;
    DxValue   *array_elements;  // array[array_length] for array objects
};

// Interpreter frame (heap-allocated per method call)
struct DxFrame {
    DxMethod  *method;
    DxValue    registers[DX_MAX_REGISTERS];
    uint32_t   pc;              // program counter (in 16-bit code units)
    DxFrame   *caller;
    DxValue    result;          // return value from callee
    bool       has_result;
    DxObject  *exception;       // pending exception for try/catch handling
};

// ── Telemetry (opt-in) ──

typedef struct {
    uint64_t total_instructions_executed;
    uint64_t total_gc_collections;
    uint64_t total_gc_pause_ns;
    uint64_t total_methods_invoked;
    uint32_t classes_loaded;
    uint32_t exceptions_thrown;
    bool     telemetry_enabled;
} DxTelemetry;

// VM state
#define DX_MAX_DEX_FILES 8

// Forward declaration for missing feature tracker (full definition below)
#define DX_MAX_MISSING_FEATURES 32
typedef struct {
    char features[DX_MAX_MISSING_FEATURES][128];
    uint32_t count;
} DxMissingFeatures;

struct DxVM {
    DxContext  *ctx;
    DxDexFile *dex;              // primary DEX (for backwards compat)
    DxDexFile *dex_files[DX_MAX_DEX_FILES];
    uint32_t   dex_count;

    // Per-DEX class cache: maps class_def_index -> already-loaded DxClass*
    // Avoids re-parsing the same class_def on repeated load_class calls
    DxClass  **class_def_cache[DX_MAX_DEX_FILES];  // lazily allocated per DEX
    uint32_t   class_def_cache_size[DX_MAX_DEX_FILES];

    // Class table
    DxClass   *classes[DX_MAX_CLASSES];
    uint32_t   class_count;

    // Class hash table for O(1) lookup
    #define DX_CLASS_HASH_SIZE 4096
    struct {
        const char *descriptor;  // key (points to DxClass->descriptor)
        DxClass    *cls;         // value
    } class_hash[DX_CLASS_HASH_SIZE];

    // Heap
    DxObject  *heap[DX_MAX_HEAP_OBJECTS];
    uint32_t   heap_count;

    // Call stack
    DxFrame   *current_frame;
    uint32_t   stack_depth;

    // Framework classes (pre-registered)
    DxClass   *class_object;        // java/lang/Object
    DxClass   *class_string;        // java/lang/String
    DxClass   *class_activity;      // android/app/Activity
    DxClass   *class_view;          // android/view/View
    DxClass   *class_textview;      // android/widget/TextView
    DxClass   *class_button;        // android/widget/Button
    DxClass   *class_viewgroup;     // android/view/ViewGroup
    DxClass   *class_linearlayout;  // android/widget/LinearLayout
    DxClass   *class_context;       // android/content/Context
    DxClass   *class_bundle;        // android/os/Bundle
    DxClass   *class_resources;     // android/content/res/Resources
    DxClass   *class_onclick;       // android/view/View$OnClickListener
    DxClass   *class_appcompat;     // androidx/.../AppCompatActivity
    DxClass   *class_edittext;      // android/widget/EditText
    DxClass   *class_imageview;     // android/widget/ImageView
    DxClass   *class_toast;         // android/widget/Toast
    DxClass   *class_log;           // android/util/Log
    DxClass   *class_intent;        // android/content/Intent
    DxClass   *class_shared_prefs;  // android/content/SharedPreferences
    DxClass   *class_inflater;      // android/view/LayoutInflater
    DxClass   *class_arraylist;     // java/util/ArrayList
    DxClass   *class_hashmap;       // java/util/HashMap

    // Current activity instance
    DxObject  *activity_instance;

    // Activity back-stack for startActivityForResult / finish
    #define DX_MAX_ACTIVITY_STACK 16
    struct {
        DxObject   *activity;     // the Activity object
        const char *class_name;   // class descriptor of the activity
        DxObject   *intent;       // Intent that launched it
        int32_t     request_code; // -1 if plain startActivity
        DxObject   *saved_state;  // Bundle from onSaveInstanceState (NULL if none)
    } activity_stack[DX_MAX_ACTIVITY_STACK];
    uint32_t activity_stack_depth;

    // Per-activity result state (set via setResult before finish)
    int32_t   activity_result_code;    // RESULT_CANCELED=0 by default
    DxObject *activity_result_data;    // optional Intent

    // String intern table
    #define DX_MAX_INTERNED_STRINGS 8192
    struct { char *value; DxObject *obj; } interned_strings[DX_MAX_INTERNED_STRINGS];
    uint32_t   interned_count;

    // Execution state
    bool       running;
    DxResult   last_error;
    char       error_msg[256];
    uint64_t   insn_count;      // Instructions executed in current top-level call
    uint64_t   insn_total;      // Lifetime total instructions (for stats)
    uint64_t   insn_limit;      // Max instructions per top-level call (0 = unlimited)

    // Frame pool for interpreter performance
    #define DX_FRAME_POOL_SIZE 64
    DxFrame  *frame_pool[DX_FRAME_POOL_SIZE];
    uint32_t  frame_pool_count;

    // Pending exception for cross-method unwinding
    DxObject  *pending_exception;

    // Watchdog: detect stuck interpreter (wall-clock timeout)
    uint64_t watchdog_start_time;   // mach_absolute_time() when top-level execute began
    uint32_t watchdog_timeout_ms;   // 0 = disabled, default 10000 (10 s)
    bool     watchdog_triggered;

    // Cancellation: set from another thread to stop execution gracefully
    volatile bool cancel_requested; // checked every 10000 instructions alongside watchdog

    // Missing feature tracker
    DxMissingFeatures missing_features;

    // Debug tracing
    struct {
        bool bytecode_trace;      // Log each instruction
        bool class_load_trace;    // Log class loads
        bool method_call_trace;   // Log method entry/exit
        const char *trace_method_filter; // NULL = all, else prefix match
        int trace_depth;          // Current call depth (for indentation)
    } debug;

    // Diagnostic info captured on error
    struct {
        bool     has_error;
        char     method_name[128];    // "Lcom/example/Foo;.bar"
        uint32_t pc;                  // program counter at error
        uint8_t  opcode;              // opcode at error
        char     opcode_name[32];     // human-readable opcode name
        uint32_t reg_count;           // number of registers to show
        DxValue  registers[16];       // snapshot of first 16 registers
        char     stack_trace[2048];   // formatted call chain
    } diag;

    // SharedPreferences in-memory store (simple key-value)
    #define DX_MAX_PREFS_ENTRIES 256
    struct {
        char    *key;
        DxValue  value;
    } prefs[DX_MAX_PREFS_ENTRIES];
    uint32_t prefs_count;

    // Incremental GC state
    enum { DX_GC_IDLE = 0, DX_GC_MARKING, DX_GC_SWEEPING } gc_phase;
    #define DX_GC_MARK_STACK_SIZE 4096
    DxObject  *gc_mark_stack[DX_GC_MARK_STACK_SIZE];
    uint32_t   gc_mark_stack_top;
    uint32_t   gc_sweep_cursor;       // current position in heap during incremental sweep

    // Generational GC state
    uint32_t   young_gen_count;      // number of young (generation 0) objects in heap
    uint32_t   young_gen_threshold;  // minor GC trigger threshold (default 256)
    uint32_t   gc_cycle_count;       // total GC cycles (used to schedule major GC)

    // Singleton ClassLoader object (returned by Class.getClassLoader())
    DxObject  *singleton_classloader;

    // ── Profiling ──
    bool       profiling_enabled;

    // Opcode frequency histogram (256 Dalvik opcodes)
    uint64_t   opcode_histogram[256];

    // GC pause time measurement
    uint64_t   last_gc_pause_ns;
    uint64_t   total_gc_pause_ns;

    // Heap allocation profiling
    uint64_t   total_allocations;
    uint64_t   total_bytes_allocated;

    // ── Telemetry (opt-in counters) ──
    DxTelemetry telemetry;
};

// VM lifecycle
DxVM    *dx_vm_create(DxContext *ctx);
void     dx_vm_destroy(DxVM *vm);
DxResult dx_vm_load_dex(DxVM *vm, DxDexFile *dex);
DxResult dx_vm_register_framework_classes(DxVM *vm);

// Class operations
DxResult dx_vm_load_class(DxVM *vm, const char *descriptor, DxClass **out);
DxResult dx_vm_init_class(DxVM *vm, DxClass *cls);
DxClass *dx_vm_find_class(DxVM *vm, const char *descriptor);
void     dx_vm_class_hash_insert(DxVM *vm, DxClass *cls);
DxResult dx_vm_unload_class(DxVM *vm, const char *descriptor);

// Framework class registration (called by dx_vm_register_framework_classes)
DxResult dx_register_java_lang(DxVM *vm);
DxResult dx_register_android_framework(DxVM *vm);

// Garbage collection
DxResult  dx_vm_gc(DxVM *vm);
DxResult  dx_vm_gc_minor(DxVM *vm);  // minor GC: only collect young generation objects
void      dx_vm_gc_step(DxVM *vm);   // incremental GC step (processes up to 256 objects)

// Object operations
DxObject *dx_vm_alloc_object(DxVM *vm, DxClass *cls);
DxObject *dx_vm_alloc_array(DxVM *vm, uint32_t length);
void      dx_vm_release_object(DxVM *vm, DxObject *obj);
DxResult  dx_vm_set_field(DxObject *obj, const char *name, DxValue value);
DxResult  dx_vm_get_field(DxObject *obj, const char *name, DxValue *out);

// Exception creation
DxObject *dx_vm_create_exception(DxVM *vm, const char *class_descriptor, const char *message);

// String operations
DxObject *dx_vm_create_string(DxVM *vm, const char *utf8);
DxObject *dx_vm_intern_string(DxVM *vm, const char *utf8);
const char *dx_vm_get_string_value(DxObject *str_obj);

// Method resolution
DxMethod *dx_vm_resolve_method(DxVM *vm, uint32_t dex_method_idx);
DxMethod *dx_vm_find_method(DxClass *cls, const char *name, const char *shorty);
DxMethod *dx_vm_find_interface_method(DxVM *vm, DxClass *cls, const char *name, const char *shorty);

// Frame pool
DxFrame *dx_vm_alloc_frame(DxVM *vm);
void     dx_vm_free_frame(DxVM *vm, DxFrame *frame);

// Bytecode verification (called automatically before first execution)
DxResult dx_verify_method(DxDexFile *dex, DxMethod *method);

// Execution
DxResult dx_vm_execute_method(DxVM *vm, DxMethod *method, DxValue *args, uint32_t arg_count, DxValue *result);
DxResult dx_vm_run_main_activity(DxVM *vm, const char *activity_class);

// invoke-custom (lambda / string concat)
DxResult dx_vm_invoke_custom(DxVM *vm, DxFrame *frame, uint32_t call_site_idx,
                              DxValue *args, uint32_t arg_count);

// invoke-polymorphic (MethodHandle.invoke / invokeExact dispatch)
DxResult dx_vm_invoke_method_handle(DxVM *vm, DxObject *handle_obj, DxValue *args, int argc, DxValue *result);

// Annotation lookup on class/method
const DxAnnotationEntry *dx_class_get_annotation(DxClass *cls, const char *type_desc);
const DxAnnotationEntry *dx_method_get_annotation(DxMethod *method, const char *type_desc);

// Garbage collection — force a full mark-sweep cycle (e.g. on memory pressure)
DxResult dx_vm_gc_collect(DxVM *vm);

// Diagnostics
char *dx_vm_heap_stats(DxVM *vm);
char *dx_vm_get_last_error_detail(DxVM *vm);

// Missing feature tracking
void        dx_vm_report_missing_feature(DxVM *vm, const char *feature);
const char *dx_vm_get_missing_features(DxVM *vm);

// Crash isolation (signal-based recovery)
#include <setjmp.h>
void        dx_crash_install_handlers(DxVM *vm);
void        dx_crash_uninstall_handlers(void);
int         dx_crash_get_signal(void);
sigjmp_buf *dx_crash_get_jmpbuf(void);

// Debug tracing configuration
void dx_vm_set_trace(DxVM *vm, bool bytecode, bool class_load, bool method_call);
void dx_vm_set_trace_filter(DxVM *vm, const char *method_filter);

// Inline cache operations
DxInlineCache *dx_vm_ic_get(DxMethod *method, uint32_t pc);
DxMethod      *dx_vm_ic_lookup(DxInlineCache *ic, DxClass *receiver_class);
void           dx_vm_ic_insert(DxInlineCache *ic, DxClass *receiver_class, DxMethod *resolved);
void           dx_vm_ic_stats(DxVM *vm);

// Method inlining constants
#define DX_INLINE_NONE   0
#define DX_INLINE_GETTER 1
#define DX_INLINE_SETTER 2

// Analyze a method for trivial getter/setter inlining
void dx_method_analyze_inline(DxMethod *method);

// Profiling
void dx_vm_set_profiling(DxVM *vm, bool enabled);
void dx_vm_dump_opcode_stats(DxVM *vm);
void dx_vm_dump_hot_methods(DxVM *vm, int top_n);

/// Get a snapshot of the current telemetry counters.
DxTelemetry dx_vm_get_telemetry(DxVM *vm);

/// Enable or disable telemetry collection.
void dx_vm_set_telemetry_enabled(DxVM *vm, bool enabled);

#endif // DX_VM_H

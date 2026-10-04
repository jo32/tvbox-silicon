#ifndef DX_TYPES_H
#define DX_TYPES_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// Forward declarations
typedef struct DxContext DxContext;
typedef struct DxVM DxVM;
typedef struct DxClass DxClass;
typedef struct DxMethod DxMethod;
typedef struct DxObject DxObject;
typedef struct DxFrame DxFrame;
typedef struct DxDexFile DxDexFile;
typedef struct DxUINode DxUINode;
typedef struct DxRenderModel DxRenderModel;

// Result codes
typedef enum {
    DX_OK = 0,
    DX_ERR_NULL_PTR,
    DX_ERR_INVALID_MAGIC,
    DX_ERR_INVALID_FORMAT,
    DX_ERR_OUT_OF_MEMORY,
    DX_ERR_NOT_FOUND,
    DX_ERR_UNSUPPORTED_OPCODE,
    DX_ERR_CLASS_NOT_FOUND,
    DX_ERR_METHOD_NOT_FOUND,
    DX_ERR_FIELD_NOT_FOUND,
    DX_ERR_STACK_OVERFLOW,
    DX_ERR_STACK_UNDERFLOW,
    DX_ERR_EXCEPTION,
    DX_ERR_VERIFICATION_FAILED,
    DX_ERR_IO,
    DX_ERR_ZIP_INVALID,
    DX_ERR_AXML_INVALID,
    DX_ERR_UNSUPPORTED_VERSION,
    DX_ERR_INTERNAL,
    DX_ERR_SIGNAL,              // Recovered from SIGSEGV/SIGBUS via crash isolation
    DX_ERR_BUDGET_EXHAUSTED,    // Instruction budget exhausted (infinite loop watchdog)
    DX_ERR_CANCELLED,           // Execution cancelled by user
} DxResult;

// Value types for the register file
typedef enum {
    DX_VAL_VOID = 0,
    DX_VAL_INT,
    DX_VAL_LONG,
    DX_VAL_FLOAT,
    DX_VAL_DOUBLE,
    DX_VAL_OBJ,
} DxValueTag;

typedef struct {
    DxValueTag tag;
    union {
        int32_t  i;
        int64_t  l;
        float    f;
        double   d;
        DxObject *obj;
    };
} DxValue;

// Access flags (subset of Android's)
typedef enum {
    DX_ACC_PUBLIC       = 0x0001,
    DX_ACC_PRIVATE      = 0x0002,
    DX_ACC_PROTECTED    = 0x0004,
    DX_ACC_STATIC       = 0x0008,
    DX_ACC_FINAL        = 0x0010,
    DX_ACC_SYNCHRONIZED = 0x0020,
    DX_ACC_BRIDGE       = 0x0040,
    DX_ACC_VOLATILE     = 0x0040,  // Same bit as BRIDGE; VOLATILE for fields, BRIDGE for methods
    DX_ACC_VARARGS      = 0x0080,
    DX_ACC_NATIVE       = 0x0100,
    DX_ACC_INTERFACE    = 0x0200,
    DX_ACC_ABSTRACT     = 0x0400,
    DX_ACC_ANNOTATION   = 0x2000,
    DX_ACC_ENUM         = 0x4000,
    DX_ACC_CONSTRUCTOR  = 0x10000,
} DxAccessFlags;

// View types for UI bridge
typedef enum {
    DX_VIEW_NONE = 0,
    DX_VIEW_LINEAR_LAYOUT,
    DX_VIEW_TEXT_VIEW,
    DX_VIEW_BUTTON,
    DX_VIEW_IMAGE_VIEW,
    DX_VIEW_EDIT_TEXT,
    DX_VIEW_FRAME_LAYOUT,
    DX_VIEW_RELATIVE_LAYOUT,
    DX_VIEW_CONSTRAINT_LAYOUT,
    DX_VIEW_SCROLL_VIEW,
    DX_VIEW_RECYCLER_VIEW,
    DX_VIEW_CARD_VIEW,
    DX_VIEW_SWITCH,
    DX_VIEW_CHECKBOX,
    DX_VIEW_PROGRESS_BAR,
    DX_VIEW_TOOLBAR,
    DX_VIEW_VIEW,              // generic <View/> (spacer/divider)
    DX_VIEW_VIEW_GROUP,        // any unrecognized ViewGroup container
    DX_VIEW_LIST_VIEW,         // android.widget.ListView
    DX_VIEW_GRID_VIEW,         // android.widget.GridView
    DX_VIEW_SPINNER,           // android.widget.Spinner (dropdown)
    DX_VIEW_SEEK_BAR,          // android.widget.SeekBar
    DX_VIEW_RATING_BAR,        // android.widget.RatingBar
    DX_VIEW_RADIO_BUTTON,      // android.widget.RadioButton
    DX_VIEW_RADIO_GROUP,       // android.widget.RadioGroup
    DX_VIEW_FAB,               // FloatingActionButton
    DX_VIEW_TAB_LAYOUT,        // TabLayout
    DX_VIEW_VIEW_PAGER,        // ViewPager
    DX_VIEW_WEB_VIEW,          // android.webkit.WebView
    DX_VIEW_CHIP,              // Material Chip
    DX_VIEW_BOTTOM_NAV,        // BottomNavigationView
    DX_VIEW_SWIPE_REFRESH,     // SwipeRefreshLayout
} DxViewType;

// Layout orientation
typedef enum {
    DX_ORIENTATION_HORIZONTAL = 0,
    DX_ORIENTATION_VERTICAL = 1,
} DxOrientation;

// Visibility
typedef enum {
    DX_VISIBLE = 0,
    DX_INVISIBLE = 4,
    DX_GONE = 8,
} DxVisibility;

// Log levels
typedef enum {
    DX_LOG_TRACE = 0,
    DX_LOG_DEBUG,
    DX_LOG_INFO,
    DX_LOG_WARN,
    DX_LOG_ERROR,
} DxLogLevel;

// Maximum limits
#define DX_MAX_CLASSES      2048
#define DX_MAX_METHODS      1024
#define DX_MAX_FIELDS       512
#define DX_MAX_STRINGS      4096
#define DX_MAX_STACK_DEPTH  128
#define DX_MAX_REGISTERS    256
#define DX_MAX_UI_NODES     128
#define DX_MAX_HEAP_OBJECTS 65536
#define DX_MAX_INSTRUCTIONS 500000  // Per method invocation limit to prevent runaway loops

// Null constants
#define DX_NULL_VALUE ((DxValue){.tag = DX_VAL_OBJ, .obj = NULL})
#define DX_INT_VALUE(v) ((DxValue){.tag = DX_VAL_INT, .i = (v)})
#define DX_OBJ_VALUE(o) ((DxValue){.tag = DX_VAL_OBJ, .obj = (o)})

// ─── NaN-boxing representation ───────────────────────────────────────────────
//
// When USE_NANBOXING is defined, DxNanboxValue is a single uint64_t (8 bytes)
// instead of the 16-byte tagged union DxValue.
//
// IEEE 754 double: sign(1) | exponent(11) | mantissa(52)
// A quiet NaN has exponent = 0x7FF and mantissa bit 51 set.
// We use the remaining bits to encode type tags and payloads.
//
// Encoding layout (MSB to LSB):
//   Doubles:  any bit pattern that is NOT a NaN with our tag prefix
//   Integers: 0x7FF8_0001_xxxx_xxxx  (lower 32 bits = int32_t value)
//   Objects:  0x7FFC_xxxx_xxxx_xxxx  (lower 48 bits = pointer)
//   Floats:   0x7FF8_0002_xxxx_xxxx  (lower 32 bits = float bits)
//   Longs:    stored as heap-allocated int64_t* via OBJ tag (or two regs)
//   Void:     0x7FF8_0000_0000_0000  (canonical quiet NaN, no payload)
//
#ifdef USE_NANBOXING

#include <string.h>

typedef uint64_t DxNanboxValue;

// The quiet NaN base: exponent all-1s + quiet NaN bit (bit 51)
#define DX_NANBOX_QNAN        UINT64_C(0x7FF8000000000000)

// Tag constants (placed in bits 48..32 above the 32-bit payload)
#define DX_NANBOX_TAG_VOID    UINT64_C(0x7FF8000000000000)
#define DX_NANBOX_TAG_INT     UINT64_C(0x7FF8000100000000)
#define DX_NANBOX_TAG_FLOAT   UINT64_C(0x7FF8000200000000)

// Object pointer: bit 50 set (0x7FFC prefix), pointer in lower 48 bits
#define DX_NANBOX_TAG_OBJ     UINT64_C(0x7FFC000000000000)

// Masks
#define DX_NANBOX_MASK_TAG    UINT64_C(0xFFFF000000000000)
#define DX_NANBOX_MASK_SUBTAG UINT64_C(0xFFFFFFFF00000000)
#define DX_NANBOX_MASK_PTR    UINT64_C(0x0000FFFFFFFFFFFF)
#define DX_NANBOX_MASK_32     UINT64_C(0x00000000FFFFFFFF)

// ── Type checks ──

static inline bool DX_NANBOX_IS_DOUBLE(DxNanboxValue v) {
    return (v & DX_NANBOX_QNAN) != DX_NANBOX_QNAN;
}

static inline bool DX_NANBOX_IS_VOID(DxNanboxValue v) {
    return v == DX_NANBOX_TAG_VOID;
}

static inline bool DX_NANBOX_IS_INT(DxNanboxValue v) {
    return (v & DX_NANBOX_MASK_SUBTAG) == DX_NANBOX_TAG_INT;
}

static inline bool DX_NANBOX_IS_FLOAT(DxNanboxValue v) {
    return (v & DX_NANBOX_MASK_SUBTAG) == DX_NANBOX_TAG_FLOAT;
}

static inline bool DX_NANBOX_IS_OBJ(DxNanboxValue v) {
    return (v & DX_NANBOX_MASK_TAG) == DX_NANBOX_TAG_OBJ;
}

// ── Packing ──

static inline DxNanboxValue DX_NANBOX_PACK_DOUBLE(double d) {
    DxNanboxValue v;
    memcpy(&v, &d, sizeof(v));
    return v;
}

static inline DxNanboxValue DX_NANBOX_PACK_INT(int32_t i) {
    return DX_NANBOX_TAG_INT | ((DxNanboxValue)(uint32_t)i);
}

static inline DxNanboxValue DX_NANBOX_PACK_FLOAT(float f) {
    uint32_t bits;
    memcpy(&bits, &f, sizeof(bits));
    return DX_NANBOX_TAG_FLOAT | (DxNanboxValue)bits;
}

static inline DxNanboxValue DX_NANBOX_PACK_OBJ(DxObject *obj) {
    return DX_NANBOX_TAG_OBJ | ((DxNanboxValue)(uintptr_t)obj & DX_NANBOX_MASK_PTR);
}

static inline DxNanboxValue DX_NANBOX_PACK_VOID(void) {
    return DX_NANBOX_TAG_VOID;
}

// ── Unpacking ──

static inline double DX_NANBOX_UNPACK_DOUBLE(DxNanboxValue v) {
    double d;
    memcpy(&d, &v, sizeof(d));
    return d;
}

static inline int32_t DX_NANBOX_UNPACK_INT(DxNanboxValue v) {
    return (int32_t)(v & DX_NANBOX_MASK_32);
}

static inline float DX_NANBOX_UNPACK_FLOAT(DxNanboxValue v) {
    uint32_t bits = (uint32_t)(v & DX_NANBOX_MASK_32);
    float f;
    memcpy(&f, &bits, sizeof(f));
    return f;
}

static inline DxObject *DX_NANBOX_UNPACK_OBJ(DxNanboxValue v) {
    return (DxObject *)(uintptr_t)(v & DX_NANBOX_MASK_PTR);
}

// ── Convenience: null object ──
#define DX_NANBOX_NULL  DX_NANBOX_PACK_OBJ(NULL)

#endif // USE_NANBOXING

#endif // DX_TYPES_H

#ifndef DX_DEX_H
#define DX_DEX_H

#include "dx_types.h"
#include "dx_arena.h"

// DEX file magic: "dex\n035\0" (or 037, 038, 039)
#define DEX_MAGIC_SIZE 8
#define DEX_MAGIC "dex\n"

// DEX header (standard 0x70 bytes)
typedef struct {
    uint8_t  magic[DEX_MAGIC_SIZE];
    uint32_t checksum;
    uint8_t  signature[20];
    uint32_t file_size;
    uint32_t header_size;
    uint32_t endian_tag;
    uint32_t link_size;
    uint32_t link_off;
    uint32_t map_off;
    uint32_t string_ids_size;
    uint32_t string_ids_off;
    uint32_t type_ids_size;
    uint32_t type_ids_off;
    uint32_t proto_ids_size;
    uint32_t proto_ids_off;
    uint32_t field_ids_size;
    uint32_t field_ids_off;
    uint32_t method_ids_size;
    uint32_t method_ids_off;
    uint32_t class_defs_size;
    uint32_t class_defs_off;
    uint32_t data_size;
    uint32_t data_off;
} DxDexHeader;

// String ID item
typedef struct {
    uint32_t string_data_off;
} DxDexStringId;

// Type ID item
typedef struct {
    uint32_t descriptor_idx;    // index into string_ids
} DxDexTypeId;

// Proto ID item
typedef struct {
    uint32_t shorty_idx;
    uint32_t return_type_idx;
    uint32_t parameters_off;    // offset to type_list or 0
} DxDexProtoId;

// Field ID item
typedef struct {
    uint16_t class_idx;
    uint16_t type_idx;
    uint32_t name_idx;
} DxDexFieldId;

// Method ID item
typedef struct {
    uint16_t class_idx;
    uint16_t proto_idx;
    uint32_t name_idx;
} DxDexMethodId;

// Class def item
typedef struct {
    uint32_t class_idx;
    uint32_t access_flags;
    uint32_t superclass_idx;
    uint32_t interfaces_off;
    uint32_t source_file_idx;
    uint32_t annotations_off;
    uint32_t class_data_off;
    uint32_t static_values_off;
} DxDexClassDef;

// Line number table entry (bytecode address -> source line)
#define DX_MAX_LINE_ENTRIES 100

typedef struct {
    uint32_t address;           // bytecode address (in 16-bit code units)
    int32_t  line;              // source line number
} DxLineEntry;

// Code item
typedef struct {
    uint16_t registers_size;
    uint16_t ins_size;
    uint16_t outs_size;
    uint16_t tries_size;
    uint32_t debug_info_off;
    uint32_t insns_size;        // in 16-bit code units
    uint16_t *insns;            // pointer into DEX data (not owned)

    // Line number table (populated from debug_info_item)
    DxLineEntry *line_table;    // heap-allocated, NULL if no debug info
    uint32_t     line_count;    // number of entries in line_table
} DxDexCodeItem;

// Encoded method from class_data
typedef struct {
    uint32_t method_idx;        // index into method_ids (delta-encoded in file)
    uint32_t access_flags;
    uint32_t code_off;          // offset to code_item or 0
} DxDexEncodedMethod;

// Encoded field from class_data
typedef struct {
    uint32_t field_idx;         // index into field_ids (delta-encoded)
    uint32_t access_flags;
} DxDexEncodedField;

// Parsed class data
typedef struct {
    DxDexEncodedField  *static_fields;
    uint32_t            static_fields_count;
    DxDexEncodedField  *instance_fields;
    uint32_t            instance_fields_count;
    DxDexEncodedMethod *direct_methods;
    uint32_t            direct_methods_count;
    DxDexEncodedMethod *virtual_methods;
    uint32_t            virtual_methods_count;
} DxDexClassData;

// Method handle kinds (from DEX spec)
typedef enum {
    DX_METHOD_HANDLE_STATIC_PUT      = 0x00,
    DX_METHOD_HANDLE_STATIC_GET      = 0x01,
    DX_METHOD_HANDLE_INSTANCE_PUT    = 0x02,
    DX_METHOD_HANDLE_INSTANCE_GET    = 0x03,
    DX_METHOD_HANDLE_INVOKE_STATIC   = 0x04,
    DX_METHOD_HANDLE_INVOKE_INSTANCE = 0x05,
    DX_METHOD_HANDLE_INVOKE_CONSTRUCTOR = 0x06,
    DX_METHOD_HANDLE_INVOKE_DIRECT   = 0x07,
    DX_METHOD_HANDLE_INVOKE_INTERFACE = 0x08,
} DxMethodHandleKind;

// Method handle item (parsed from method_handle_item section)
typedef struct {
    uint16_t method_handle_type;    // DxMethodHandleKind
    uint16_t field_or_method_id;    // index into field_ids or method_ids
} DxMethodHandle;

// Call site item (parsed from call_site_id + encoded_array_item)
typedef struct {
    uint32_t method_handle_idx;     // bootstrap method handle index
    const char *method_name;        // functional interface method name
    uint32_t proto_idx;             // erased method type (proto_ids index)
    // For LambdaMetafactory additional args:
    uint32_t target_proto_idx;      // instantiated method type
    uint32_t impl_method_idx;       // implementation method (method_ids index)
    uint32_t impl_kind;             // implementation method handle kind
    // For StringConcatFactory:
    const char *concat_recipe;      // recipe string (NULL if not StringConcat)
    bool is_string_concat;          // true if bootstrap is StringConcatFactory
    bool parsed;                    // true if successfully parsed
} DxCallSite;

// Map item (from DEX map_list section)
typedef struct {
    uint16_t type;
    uint32_t size;
    uint32_t offset;
} DxMapItem;

// Complete parsed DEX file
struct DxDexFile {
    const uint8_t  *raw_data;
    uint32_t        raw_size;

    DxDexHeader     header;

    // Map section
    DxMapItem      *map_items;
    uint32_t        map_item_count;

    // Tables (point into raw_data)
    char          **strings;        // decoded string table (lazy: NULL until first access)
    uint32_t       *string_data_offsets; // raw data offsets for lazy string decoding
    uint32_t        string_count;

    DxDexTypeId    *type_ids;
    uint32_t        type_count;

    DxDexProtoId   *proto_ids;
    uint32_t        proto_count;

    DxDexFieldId   *field_ids;
    uint32_t        field_count;

    DxDexMethodId  *method_ids;
    uint32_t        method_count;

    DxDexClassDef  *class_defs;
    uint32_t        class_count;

    // Parsed class data (lazy, indexed by class_def index)
    DxDexClassData **class_data;    // array of pointers, NULL until parsed

    // Method handles (from method_handle_item section in map list)
    DxMethodHandle *method_handles;
    uint32_t        method_handle_count;

    // Call sites (from call_site_id_item section in map list)
    DxCallSite     *call_sites;
    uint32_t        call_site_count;

    // Arena allocator for parse-time allocations (strings, string_data_offsets)
    DxArena        *arena;
};

// Parse a DEX file from a buffer (buffer must remain valid)
DxResult dx_dex_parse(const uint8_t *data, uint32_t size, DxDexFile **out);
void     dx_dex_free(DxDexFile *dex);

// Get string by index
const char *dx_dex_get_string(const DxDexFile *dex, uint32_t idx);

// Get type descriptor string by type index
const char *dx_dex_get_type(const DxDexFile *dex, uint32_t type_idx);

// Parse class data for a class_def (lazy)
DxResult dx_dex_parse_class_data(DxDexFile *dex, uint32_t class_def_idx);

// Parse a code item at the given offset
DxResult dx_dex_parse_code_item(const DxDexFile *dex, uint32_t offset, DxDexCodeItem *out);

// Get method name
const char *dx_dex_get_method_name(const DxDexFile *dex, uint32_t method_idx);

// Get method's class descriptor
const char *dx_dex_get_method_class(const DxDexFile *dex, uint32_t method_idx);

// Get method's prototype shorty
const char *dx_dex_get_method_shorty(const DxDexFile *dex, uint32_t method_idx);

// Get field name
const char *dx_dex_get_field_name(const DxDexFile *dex, uint32_t field_idx);

// Get field's class descriptor
const char *dx_dex_get_field_class(const DxDexFile *dex, uint32_t field_idx);

// Get method parameter count
uint32_t dx_dex_get_method_param_count(const DxDexFile *dex, uint32_t method_idx);

// Get method parameter type descriptor by index
const char *dx_dex_get_method_param_type(const DxDexFile *dex, uint32_t method_idx, uint32_t param_idx);

// Get method return type descriptor
const char *dx_dex_get_method_return_type(const DxDexFile *dex, uint32_t method_idx);

// Parse encoded static field default values from class_def.static_values_off
DxResult dx_dex_parse_static_values(const DxDexFile *dex, uint32_t offset,
                                     DxValue *out_values, uint32_t max_count);

// Annotation element value types
typedef enum {
    DX_ANNO_VAL_NONE = 0,     // not set / unsupported
    DX_ANNO_VAL_BYTE,
    DX_ANNO_VAL_SHORT,
    DX_ANNO_VAL_CHAR,
    DX_ANNO_VAL_INT,
    DX_ANNO_VAL_LONG,
    DX_ANNO_VAL_FLOAT,
    DX_ANNO_VAL_DOUBLE,
    DX_ANNO_VAL_STRING,       // value stored in str_value
    DX_ANNO_VAL_TYPE,         // type descriptor in str_value
    DX_ANNO_VAL_ENUM,         // enum field name in str_value, enum class in extra_str
    DX_ANNO_VAL_BOOLEAN,
    DX_ANNO_VAL_NULL,
    DX_ANNO_VAL_ARRAY,        // stub — element_count in i_value
    DX_ANNO_VAL_ANNOTATION,   // stub — nested annotation
} DxAnnotationValueType;

// A single name-value pair in an annotation
typedef struct {
    const char             *name;       // element name (e.g., "value", "method", "path")
    DxAnnotationValueType   val_type;
    union {
        int32_t     i_value;            // byte, short, char, int, boolean
        int64_t     l_value;            // long
        float       f_value;            // float
        double      d_value;            // double
    };
    const char             *str_value;  // string/type/enum value (points into DEX string table)
    const char             *extra_str;  // enum class descriptor
} DxAnnotationElement;

// Annotation entry (type descriptor + visibility + element values)
typedef struct {
    const char           *type;           // annotation type descriptor e.g. "Lretrofit2/http/GET;"
    uint8_t               visibility;     // 0=BUILD, 1=RUNTIME, 2=SYSTEM
    DxAnnotationElement  *elements;       // array of name-value pairs (heap-allocated)
    uint32_t              element_count;  // number of elements
} DxAnnotationEntry;

// Parsed annotations directory for a class_def
typedef struct {
    DxAnnotationEntry *class_annotations;
    uint32_t           class_annotation_count;

    // Per-method annotations (parallel arrays)
    uint32_t          *method_idxs;           // DEX method_idx for each entry
    DxAnnotationEntry **method_annotations;   // array of annotation arrays
    uint32_t          *method_annotation_counts;
    uint32_t           annotated_method_count;
} DxAnnotationsDirectory;

// Parse debug info for a code item, populating its line_table.
// Call after dx_dex_parse_code_item. The DxDexFile must remain valid.
DxResult dx_dex_parse_debug_info(const DxDexFile *dex, DxDexCodeItem *code);

// Look up source line number for a bytecode address. Returns -1 if unknown.
int dx_method_get_line(const DxMethod *method, uint32_t pc);

// Free a code item's line table (call before discarding a DxDexCodeItem)
void dx_dex_free_code_item(DxDexCodeItem *code);

// Parse annotations directory for a class_def. Caller must free with dx_dex_free_annotations.
DxResult dx_dex_parse_annotations(const DxDexFile *dex, uint32_t annotations_off,
                                   DxAnnotationsDirectory *out);

// Free a parsed annotations directory
void dx_dex_free_annotations(DxAnnotationsDirectory *dir);

// Parse method handles and call sites from DEX map list (called during dx_dex_parse)
DxResult dx_dex_parse_call_sites(DxDexFile *dex);

// Get a call site by index (returns NULL if index out of range or not parsed)
const DxCallSite *dx_dex_get_call_site(const DxDexFile *dex, uint32_t call_site_idx);

// ── Annotation element lookup helpers ──

// Get a string element value from an annotation (returns NULL if not found or wrong type)
const char *dx_annotation_get_string(const DxAnnotationEntry *ann, const char *element_name);

// Get an int element value from an annotation (returns default_val if not found)
int32_t dx_annotation_get_int(const DxAnnotationEntry *ann, const char *element_name, int32_t default_val);

// Get a long element value
int64_t dx_annotation_get_long(const DxAnnotationEntry *ann, const char *element_name, int64_t default_val);

// Get a float element value
float dx_annotation_get_float(const DxAnnotationEntry *ann, const char *element_name, float default_val);

// Get a double element value
double dx_annotation_get_double(const DxAnnotationEntry *ann, const char *element_name, double default_val);

// Get a boolean element value
bool dx_annotation_get_bool(const DxAnnotationEntry *ann, const char *element_name, bool default_val);

// Get a type descriptor element value (returns NULL if not found)
const char *dx_annotation_get_type(const DxAnnotationEntry *ann, const char *element_name);

// Free annotation elements (call when freeing DxAnnotationEntry)
void dx_annotation_entry_free_elements(DxAnnotationEntry *entry);

#endif // DX_DEX_H

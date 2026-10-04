#ifndef DX_RESOURCES_H
#define DX_RESOURCES_H

#include "dx_types.h"

// Forward declaration
typedef struct DxStyleRecord DxStyleRecord;

// ============================================================
// Resource qualifier configuration (ResTable_config)
// ============================================================

// Screen orientation constants
#define DX_ORIENTATION_ANY       0
#define DX_SCREEN_ORIENT_PORT    1
#define DX_SCREEN_ORIENT_LAND    2

// Well-known density values
#define DX_DENSITY_DEFAULT       0
#define DX_DENSITY_LDPI        120
#define DX_DENSITY_MDPI        160
#define DX_DENSITY_HDPI        240
#define DX_DENSITY_XHDPI       320
#define DX_DENSITY_XXHDPI      480
#define DX_DENSITY_XXXHDPI     640
#define DX_DENSITY_NODPI       0xFFFE
#define DX_DENSITY_ANYDPI      0xFFFE

// Parsed resource configuration qualifiers (from ResTable_config in resources.arsc)
typedef struct {
    char     language[2];     // ISO 639-1 language code (e.g., "en")
    char     country[2];      // ISO 3166-1 country code (e.g., "US")
    uint16_t density;         // screen density (dpi): 160=mdpi, 240=hdpi, etc.
    uint16_t sdk_version;     // minSdkVersion for this config
    uint16_t screen_width;    // screen width in dp (0 = any)
    uint16_t screen_height;   // screen height in dp (0 = any)
    uint8_t  orientation;     // 0=any, 1=port, 2=land
    uint8_t  screen_layout;   // raw screen size + long flags byte
    uint8_t  ui_mode;         // raw night mode + type byte
    uint8_t  night_mode;      // parsed: 0=unset, 1=notnight, 2=night
    uint8_t  screen_size;     // parsed: 0=unset, 1=small, 2=normal, 3=large, 4=xlarge
    uint16_t smallest_screen_width_dp; // sw<N>dp qualifier
} DxResConfig;

// Night mode constants
#define DX_NIGHT_MODE_NOTNIGHT  1
#define DX_NIGHT_MODE_NIGHT     2

// Screen size constants
#define DX_SCREEN_SIZE_SMALL    1
#define DX_SCREEN_SIZE_NORMAL   2
#define DX_SCREEN_SIZE_LARGE    3
#define DX_SCREEN_SIZE_XLARGE   4

// Device configuration for qualifier matching
typedef struct {
    char     language[3];     // e.g., "en" (null-terminated)
    char     country[3];      // e.g., "US" (null-terminated)
    uint16_t density;         // screen density in dpi (e.g., 440 for iPhone)
    uint16_t sdk_version;     // emulated Android SDK version (e.g., 33)
    uint16_t screen_width;    // screen width in dp
    uint16_t screen_height;   // screen height in dp
    uint8_t  orientation;     // 1=portrait, 2=landscape
    uint8_t  night_mode;      // 1=notnight (default), 2=night
    uint8_t  screen_size;     // 1=small, 2=normal (default), 3=large, 4=xlarge
} DxDeviceConfig;

// Initialize a device config with iPhone defaults
void dx_device_config_init(DxDeviceConfig *cfg);

// Resource value types (from Android's ResourceTypes.h)
typedef enum {
    DX_RES_TYPE_NULL     = 0,
    DX_RES_TYPE_REF      = 1,   // reference to another resource
    DX_RES_TYPE_STRING   = 3,
    DX_RES_TYPE_FLOAT    = 4,
    DX_RES_TYPE_DIMEN    = 5,   // dimension (dp, sp, px, etc.)
    DX_RES_TYPE_FRACTION = 6,
    DX_RES_TYPE_INT_DEC  = 16,  // 0x10
    DX_RES_TYPE_INT_HEX  = 17,  // 0x11
    DX_RES_TYPE_INT_BOOL = 18,  // 0x12
    DX_RES_TYPE_INT_COLOR_ARGB8 = 28, // 0x1c
    DX_RES_TYPE_INT_COLOR_RGB8  = 29, // 0x1d
    DX_RES_TYPE_INT_COLOR_ARGB4 = 30, // 0x1e
    DX_RES_TYPE_INT_COLOR_RGB4  = 31, // 0x1f
} DxResValueType;

// Dimension unit types (stored in low 4 bits of dimension data)
typedef enum {
    DX_DIMEN_UNIT_PX = 0,
    DX_DIMEN_UNIT_DIP = 1, // dp
    DX_DIMEN_UNIT_SP = 2,
    DX_DIMEN_UNIT_PT = 3,
    DX_DIMEN_UNIT_IN = 4,
    DX_DIMEN_UNIT_MM = 5,
} DxDimenUnit;

// A general resource entry (covers all value types)
typedef struct {
    uint32_t id;             // resource ID (0x7fXXYYYY)
    uint8_t  value_type;     // DxResValueType
    union {
        char    *str_val;    // for DX_RES_TYPE_STRING
        int32_t  int_val;    // for DX_RES_TYPE_INT_DEC, INT_HEX
        float    float_val;  // for DX_RES_TYPE_FLOAT
        uint32_t color_val;  // for DX_RES_TYPE_INT_COLOR_* (ARGB)
        bool     bool_val;   // for DX_RES_TYPE_INT_BOOL
        struct {
            float value;     // dimension value
            uint8_t unit;    // DxDimenUnit
        } dimen;
        uint32_t ref_id;     // for DX_RES_TYPE_REF
    };
    char *entry_name;        // key name, e.g., "app_name", "main_layout"
    char *type_name;         // type name, e.g., "string", "layout", "color"
    DxResConfig config;      // qualifier config for this entry
} DxResourceEntry;

// Array resource (string-array or integer-array)
typedef struct {
    uint32_t res_id;
    char **string_values;     // for string-array (NULL if integer-array)
    int32_t *int_values;      // for integer-array (NULL if string-array)
    uint32_t count;
    bool is_string_array;     // true=string-array, false=integer-array
} DxArrayResource;

// Plural resource (quantity strings)
typedef struct {
    uint32_t res_id;
    char *zero;
    char *one;
    char *two;
    char *few;
    char *many;
    char *other;
} DxPluralResource;

// Resource cache entry (for resolved resource lookups)
#define DX_RES_CACHE_SIZE 512

typedef struct {
    uint32_t resource_id;       // resource ID (0 = empty slot)
    const DxResourceEntry *entry; // cached resolved entry
    uint32_t insert_order;      // monotonic counter for FIFO eviction
} DxResCacheEntry;

typedef struct {
    DxResCacheEntry entries[DX_RES_CACHE_SIZE];
    uint32_t count;             // number of occupied slots
    uint32_t next_order;        // monotonic counter for FIFO
} DxResCache;

// Parsed resources.arsc data
typedef struct {
    // String pool from resources
    char     **strings;
    uint32_t   string_count;

    // Resource entries: map resource ID -> string value
    // String resource entries (type 0x03 string references)
    struct {
        uint32_t  id;
        char     *value;
    } *string_entries;
    uint32_t string_entry_count;

    // Layout resource IDs (maps ID -> index in layout_buffers)
    struct {
        uint32_t id;
        char    *filename;  // e.g., "res/layout/activity_main.xml"
    } *layout_entries;
    uint32_t layout_entry_count;

    // General resource entry table (all types)
    DxResourceEntry *entries;
    uint32_t entry_count;
    uint32_t entry_capacity;

    // Style bag records (parsed from complex/bag entries in resources.arsc)
    DxStyleRecord *styles;
    uint32_t style_count;
    uint32_t style_capacity;

    // Array resources (string-array, integer-array)
    DxArrayResource *arrays;
    uint32_t array_count;
    uint32_t array_capacity;

    // Plural resources
    DxPluralResource *plurals;
    uint32_t plural_count;
    uint32_t plural_capacity;

    // Resource resolution cache (FIFO eviction, max DX_RES_CACHE_SIZE entries)
    DxResCache cache;
} DxResources;

DxResult dx_resources_parse(const uint8_t *data, uint32_t size, DxResources **out);
void     dx_resources_free(DxResources *res);

// Look up a string resource by ID
const char *dx_resources_get_string(const DxResources *res, uint32_t id);

// Look up a layout filename by resource ID
const char *dx_resources_get_layout_filename(const DxResources *res, uint32_t id);

// Look up any resource entry by ID
const DxResourceEntry *dx_resources_find_by_id(const DxResources *res, uint32_t id);

// Convenience: look up a string value by resource ID (checks general table too)
const char *dx_resources_get_string_by_id(const DxResources *res, uint32_t id);

// Convenience: look up a resource entry by entry name and type name
const DxResourceEntry *dx_resources_find_by_name(const DxResources *res,
                                                   const char *type_name,
                                                   const char *entry_name);

// Qualifier-aware resource lookup: picks the best-matching entry for the device config
const DxResourceEntry *dx_resources_find_by_id_q(const DxResources *res, uint32_t id,
                                                   const DxDeviceConfig *dev);

// Qualifier-aware string lookup: prefers locale-matched strings
const char *dx_resources_find_string(const DxResources *res, uint32_t id,
                                      const DxDeviceConfig *dev);

// Decode a dimension value to a float in the given unit
float dx_resources_decode_dimen(uint32_t raw_data, uint8_t *out_unit);

// Format a dimension value as a string (e.g., "16.0dp"), caller must free
char *dx_resources_format_dimen(float value, uint8_t unit);

// Format a color value as "#AARRGGBB" string, caller must free
char *dx_resources_format_color(uint32_t argb);

// ============================================================
// Array resource lookup
// ============================================================

// Returns array of strings for a string-array resource ID. out_count receives element count.
const char **dx_resources_get_string_array(const DxResources *res, uint32_t res_id, uint32_t *out_count);

// Returns array of ints for an integer-array resource ID. out_count receives element count.
const int32_t *dx_resources_get_integer_array(const DxResources *res, uint32_t res_id, uint32_t *out_count);

// Returns the array resource record for a given resource ID, or NULL.
const DxArrayResource *dx_resources_find_array(const DxResources *res, uint32_t res_id);

// ============================================================
// Plural resource lookup
// ============================================================

// Returns the appropriate plural string for the given quantity.
// Uses CLDR English rules: 1=one, else=other. Returns NULL if not found.
const char *dx_resources_get_plural(const DxResources *res, uint32_t res_id, int quantity);

// ============================================================
// Style / Theme resolution
// ============================================================

// A single attribute within a style bag (attr_id -> typed value)
typedef struct {
    uint32_t attr_id;       // attribute resource ID (e.g., 0x01010098 = textColor)
    uint8_t  value_type;    // DxResValueType
    uint32_t value_data;    // raw value data (color, ref, int, dimension, etc.)
} DxStyleEntry;

// A resolved style bag: array of attribute key-value pairs
typedef struct {
    DxStyleEntry *entries;
    uint32_t      entry_count;
    uint32_t      parent_id;    // parent style resource ID (0 = none)
} DxStyleBag;

// Internal storage for parsed style bags
struct DxStyleRecord {
    uint32_t    style_res_id; // resource ID of this style
    uint32_t    parent_id;    // parent style resource ID (0 = none)
    DxStyleEntry *entries;
    uint32_t     entry_count;
};

// Resolve a style resource ID into a flattened bag of attribute entries.
// Follows parent chain up to 20 levels. Child entries override parent entries.
// Caller must free the returned DxStyleBag and its entries array with dx_style_bag_free().
DxStyleBag *dx_resources_resolve_style(const DxResources *res, uint32_t style_res_id);

// Free a DxStyleBag returned by dx_resources_resolve_style
void dx_style_bag_free(DxStyleBag *bag);

// Resolve a ?attr/ reference through a theme style bag.
// Given a theme (resolved style bag) and an attribute resource ID,
// returns the concrete value entry from the theme, or NULL if not found.
const DxStyleEntry *dx_style_bag_find_attr(const DxStyleBag *bag, uint32_t attr_id);

// ============================================================
// Theme
// ============================================================

// A resolved theme: essentially a flattened style bag from the theme resource
typedef struct {
    uint32_t    theme_res_id;   // the style resource ID for this theme
    DxStyleBag *bag;            // resolved attribute bag
} DxTheme;

// Create a theme from a style resource ID. Caller must free with dx_theme_free().
DxTheme *dx_theme_create(const DxResources *res, uint32_t theme_res_id);
void     dx_theme_free(DxTheme *theme);

// Resolve a ?attr/ reference: given an attribute ID, look it up in the theme
// and return the concrete value. Returns NULL if not resolvable.
const DxStyleEntry *dx_theme_resolve_attr(const DxTheme *theme, uint32_t attr_id);

#endif // DX_RESOURCES_H

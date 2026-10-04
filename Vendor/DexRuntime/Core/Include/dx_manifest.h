#ifndef DX_MANIFEST_H
#define DX_MANIFEST_H

#include "dx_types.h"

// --- Intent filter data URI ---
typedef struct {
    char *scheme;       // e.g. "http", "https", "geo"
    char *host;         // e.g. "example.com"
    char *path;         // e.g. "/foo/bar"
    char *path_prefix;  // e.g. "/foo/"
    char *path_pattern; // e.g. "/foo/.*"
    char *mime_type;    // e.g. "image/*"
} DxIntentData;

// --- Intent filter ---
typedef struct {
    char     **actions;
    uint32_t   action_count;
    char     **categories;
    uint32_t   category_count;
    DxIntentData *data_entries;
    uint32_t   data_count;
} DxIntentFilter;

// --- Meta-data key/value ---
typedef struct {
    char *name;
    char *value;        // string value, or formatted resource ref "@0x..."
} DxMetaData;

// --- Uses-feature ---
typedef struct {
    char *name;
    bool  required;     // android:required (default true)
} DxUsesFeature;

// --- Uses-library ---
typedef struct {
    char *name;
    bool  required;     // android:required (default true)
} DxUsesLibrary;

// --- Instrumentation ---
typedef struct {
    char *name;            // android:name (fully qualified class)
    char *target_package;  // android:targetPackage
} DxInstrumentation;

// --- Component (activity/service/receiver/provider) ---
typedef struct {
    char            *name;          // fully qualified class name
    bool             exported;      // android:exported
    bool             exported_set;  // was the attribute present?
    DxIntentFilter  *intent_filters;
    uint32_t         intent_filter_count;
    DxMetaData      *meta_data;
    uint32_t         meta_data_count;
} DxComponent;

// Parsed AndroidManifest data
typedef struct {
    char    *package_name;
    char    *main_activity;     // fully qualified class name of launcher activity
    int32_t  min_sdk;
    int32_t  target_sdk;
    char    *app_label;
    char    *app_theme;        // android:theme resource reference

    // Component arrays (simple name strings kept for backward compat)
    char    **permissions;
    uint32_t  permission_count;
    char    **activities;
    uint32_t  activity_count;
    char    **services;
    uint32_t  service_count;
    char    **receivers;
    uint32_t  receiver_count;
    char    **providers;
    uint32_t  provider_count;

    // Rich component info (parallel to the name arrays above)
    DxComponent *activity_components;
    uint32_t     activity_component_count;
    DxComponent *service_components;
    uint32_t     service_component_count;
    DxComponent *receiver_components;
    uint32_t     receiver_component_count;
    DxComponent *provider_components;
    uint32_t     provider_component_count;

    // Application-level meta-data
    DxMetaData  *app_meta_data;
    uint32_t     app_meta_data_count;

    // Uses-feature list
    DxUsesFeature *features;
    uint32_t       feature_count;

    // Uses-library list
    DxUsesLibrary *libraries;
    uint32_t       library_count;

    // Instrumentation list
    DxInstrumentation *instrumentations;
    uint32_t           instrumentation_count;
} DxManifest;

// Parse Android Binary XML manifest from raw bytes
DxResult dx_manifest_parse(const uint8_t *data, uint32_t size, DxManifest **out);
void     dx_manifest_free(DxManifest *manifest);

// Lookup helpers
const DxComponent *dx_manifest_find_activity(const DxManifest *m, const char *name);
const DxComponent *dx_manifest_find_service(const DxManifest *m, const char *name);
const DxComponent *dx_manifest_find_receiver(const DxManifest *m, const char *name);

// AXML attribute with namespace tracking
typedef struct {
    const char *namespace_uri;  // namespace URI (e.g. "http://schemas.android.com/apk/res/android"), NULL if none
    const char *name;           // attribute local name
    uint32_t    name_idx;       // string pool index for the name
    uint32_t    ns_idx;         // string pool index for namespace URI (0xFFFFFFFF if none)
    uint32_t    resource_id;    // resolved resource ID (0 if none)
    uint32_t    value_type;     // ATTR_TYPE_* constant
    uint32_t    value_data;     // raw value data
} DxAxmlAttribute;

// AXML (Android Binary XML) low-level parser
typedef struct {
    // String pool
    char     **strings;
    uint32_t   string_count;

    // Resource ID map
    uint32_t  *res_ids;
    uint32_t   res_id_count;

    // Namespace map (active namespace prefix -> URI bindings)
    char     **ns_prefixes;     // prefix strings (owned copies)
    char     **ns_uris;         // URI strings (owned copies)
    uint32_t   ns_count;        // number of active bindings
    uint32_t   ns_capacity;     // allocated capacity
} DxAxmlParser;

DxResult dx_axml_parse(const uint8_t *data, uint32_t size, DxAxmlParser **out);
void     dx_axml_free(DxAxmlParser *parser);

#endif // DX_MANIFEST_H

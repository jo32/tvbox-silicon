#ifndef DX_VIEW_H
#define DX_VIEW_H

#include "dx_types.h"

// RelativeLayout positioning bit flags (stored in DxUINode.relative_flags)
#define DX_REL_ALIGN_PARENT_TOP      0x0001
#define DX_REL_ALIGN_PARENT_BOTTOM   0x0002
#define DX_REL_ALIGN_PARENT_LEFT     0x0004
#define DX_REL_ALIGN_PARENT_RIGHT    0x0008
#define DX_REL_CENTER_IN_PARENT      0x0010
#define DX_REL_CENTER_HORIZONTAL     0x0020
#define DX_REL_CENTER_VERTICAL       0x0040
#define DX_REL_ABOVE                 0x0080
#define DX_REL_BELOW                 0x0100
#define DX_REL_LEFT_OF               0x0200
#define DX_REL_RIGHT_OF              0x0400

// ConstraintLayout constraint target sentinel values
// 0 means "no constraint", 0xFFFFFFFF means "parent"
#define DX_CONSTRAINT_NONE   0
#define DX_CONSTRAINT_PARENT 0xFFFFFFFF

// ShapeDrawable parsed from compiled shape XML
typedef struct {
    uint8_t shape_type;     // 0=rectangle, 1=oval, 2=line, 3=ring
    uint32_t solid_color;   // ARGB
    float corner_radius;    // dp
    float stroke_width;     // dp
    uint32_t stroke_color;  // ARGB
    uint32_t gradient_start; // ARGB
    uint32_t gradient_end;   // ARGB
    uint8_t gradient_type;  // 0=linear, 1=radial, 2=sweep
    bool has_shape;
} DxShapeDrawable;

// Canvas draw command types
typedef enum {
    DX_DRAW_RECT = 0,
    DX_DRAW_CIRCLE,
    DX_DRAW_LINE,
    DX_DRAW_TEXT,
    DX_DRAW_ROUND_RECT,
    DX_DRAW_COLOR,
    DX_DRAW_SAVE,
    DX_DRAW_RESTORE,
    DX_DRAW_TRANSLATE,
    DX_DRAW_ROTATE,
    DX_DRAW_SCALE,
    DX_DRAW_ARC,
    DX_DRAW_OVAL,
} DxDrawCmdType;

// A single recorded Canvas draw command
typedef struct {
    DxDrawCmdType type;
    float         params[6];    // up to 6 float params (left,top,right,bottom,rx,ry etc.)
    uint32_t      color;        // ARGB paint color
    float         stroke_width; // paint stroke width
    int32_t       paint_style;  // 0=FILL, 1=STROKE, 2=FILL_AND_STROKE
    float         text_size;    // paint text size (for drawText)
    char         *text;         // text string (for drawText, owned)
} DxDrawCommand;

#define DX_MAX_DRAW_COMMANDS 256

// Chain style constants
#define DX_CHAIN_NONE          0
#define DX_CHAIN_SPREAD        1
#define DX_CHAIN_SPREAD_INSIDE 2
#define DX_CHAIN_PACKED        3

// Guideline orientation constants
#define DX_GUIDELINE_HORIZONTAL 0
#define DX_GUIDELINE_VERTICAL   1

// ConstraintLayout constraint anchors stored per child node
typedef struct DxConstraints {
    uint32_t left_to_left;     // view ID or DX_CONSTRAINT_PARENT
    uint32_t left_to_right;    // view ID or DX_CONSTRAINT_PARENT
    uint32_t right_to_right;   // view ID or DX_CONSTRAINT_PARENT
    uint32_t right_to_left;    // view ID or DX_CONSTRAINT_PARENT
    uint32_t top_to_top;       // view ID or DX_CONSTRAINT_PARENT
    uint32_t top_to_bottom;    // view ID or DX_CONSTRAINT_PARENT
    uint32_t bottom_to_bottom; // view ID or DX_CONSTRAINT_PARENT
    uint32_t bottom_to_top;    // view ID or DX_CONSTRAINT_PARENT
    float    horizontal_bias;  // 0.0-1.0, default 0.5
    float    vertical_bias;    // 0.0-1.0, default 0.5
    uint8_t  h_chain_style;    // 0=none, 1=spread, 2=spread_inside, 3=packed
    uint8_t  v_chain_style;    // 0=none, 1=spread, 2=spread_inside, 3=packed
} DxConstraints;

// UI tree node - represents an Android View in the internal UI tree
struct DxUINode {
    DxViewType   type;
    uint32_t     view_id;       // android:id resource ID
    DxVisibility visibility;

    // Text content (for TextView/Button/EditText)
    char        *text;
    char        *hint;          // hint text for EditText

    // Layout attributes
    DxOrientation orientation;  // for LinearLayout
    float         text_size;    // for TextView (default 16.0)
    float         weight;       // layout_weight (0 = none)
    int32_t       width;        // -1 = match_parent, -2 = wrap_content
    int32_t       height;
    int32_t       gravity;      // text/content gravity
    int32_t       padding[4];   // left, top, right, bottom
    int32_t       margin[4];    // left, top, right, bottom
    uint32_t      bg_color;     // background color (ARGB, 0 = none)
    uint32_t      text_color;   // text color (ARGB, 0 = default)
    bool          is_checked;   // for CheckBox/Switch
    uint32_t      input_type;   // android:inputType value (0x01=text, 0x81=password, 0x02=number, etc.)
    uint8_t       scale_type;   // android:scaleType (0=fitCenter, 1=center, 2=centerCrop, 3=centerInside, 4=fitXY, 5=fitStart, 6=fitEnd)

    // RelativeLayout positioning flags (bit field)
    uint16_t      relative_flags;
    // RelativeLayout sibling references (view IDs)
    uint32_t      rel_above;       // layout_above: view ID
    uint32_t      rel_below;       // layout_below: view ID
    uint32_t      rel_left_of;     // layout_toLeftOf: view ID
    uint32_t      rel_right_of;    // layout_toRightOf: view ID

    // ConstraintLayout constraints
    DxConstraints constraints;

    // ConstraintLayout guideline properties
    bool          is_guideline;
    uint8_t       guideline_orientation; // 0=horizontal, 1=vertical
    float         guideline_percent;     // 0.0-1.0, or -1 if using begin
    float         guideline_begin;       // dp offset from start, or -1

    // Image data (for ImageView - extracted from APK drawable resources)
    uint8_t     *image_data;       // PNG/JPEG bytes (owned, freed on destroy)
    uint32_t     image_data_len;   // length of image_data

    // 9-patch PNG metadata (parsed from npTc chunk in compiled APK resources)
    bool         is_nine_patch;
    int32_t      nine_patch_padding[4];    // left, top, right, bottom content padding
    int32_t      nine_patch_stretch_x[2];  // start, end of horizontal stretch region
    int32_t      nine_patch_stretch_y[2];  // start, end of vertical stretch region

    // Vector drawable data (for ImageView - parsed from AXML vector XML)
    char        *vector_path_data;  // SVG path data string (owned)
    uint32_t     vector_fill_color; // ARGB fill color
    uint32_t     vector_stroke_color; // ARGB stroke color
    float        vector_stroke_width; // stroke width in dp
    float        vector_width;      // viewport width
    float        vector_height;     // viewport height

    // Shape drawable background (parsed from compiled shape/selector/layer-list XML)
    DxShapeDrawable shape_bg;

    // WebView data
    char        *web_url;          // URL to load (owned, freed on destroy)
    char        *web_html;         // HTML content to load (owned, freed on destroy)

    // Click listener (reference to DxObject implementing OnClickListener)
    DxObject    *click_listener;

    // Long-click listener (reference to DxObject implementing OnLongClickListener)
    DxObject    *long_click_listener;

    // Touch listener (reference to DxObject implementing OnTouchListener)
    DxObject    *touch_listener;

    // Refresh listener (for SwipeRefreshLayout, implementing OnRefreshListener)
    DxObject    *refresh_listener;

    // Animation / transform properties
    float         alpha;           // 0.0-1.0 (default 1.0)
    float         rotation;        // degrees (default 0)
    float         scale_x;         // scale factor (default 1.0)
    float         scale_y;         // scale factor (default 1.0)
    float         translation_x;   // dp offset (default 0)
    float         translation_y;   // dp offset (default 0)

    // Back-reference to runtime object
    DxObject    *runtime_obj;

    // Measure/layout pass results
    float         measured_width;  // resolved width in dp (0 = not measured)
    float         measured_height; // resolved height in dp (0 = not measured)

    // Focus management
    bool          focusable;       // true if view can receive focus
    bool          focused;         // true if view currently has focus

    // Diff-based invalidation
    uint32_t     version;          // incremented on property changes
    bool         dirty;            // true if node needs re-render

    // Canvas draw commands (populated by View.onDraw dispatch)
    DxDrawCommand *draw_commands;
    uint32_t       draw_cmd_count;
    uint32_t       draw_cmd_capacity;

    // Tree structure
    DxUINode    *parent;
    DxUINode   **children;
    uint32_t     child_count;
    uint32_t     child_capacity;
};

// Render model node - serialized for Swift bridge consumption
typedef struct DxRenderNode {
    DxViewType   type;
    uint32_t     view_id;
    DxVisibility visibility;
    char        *text;
    char        *hint;
    DxOrientation orientation;
    float         text_size;
    int32_t       width;        // -1 = match_parent, -2 = wrap_content
    int32_t       height;       // -1 = match_parent, -2 = wrap_content
    float         weight;       // layout_weight (0 = none)
    int32_t       gravity;
    int32_t       padding[4];
    int32_t       margin[4];
    uint32_t      bg_color;
    uint32_t      text_color;
    bool          is_checked;
    uint32_t      input_type;   // android:inputType value
    uint8_t       scale_type;   // android:scaleType enum
    bool          has_click_listener;
    bool          has_long_click_listener;
    bool          has_refresh_listener;
    uint16_t      relative_flags;
    uint32_t      rel_above;
    uint32_t      rel_below;
    uint32_t      rel_left_of;
    uint32_t      rel_right_of;

    // ConstraintLayout constraints
    DxConstraints constraints;

    // ConstraintLayout guideline properties
    bool           is_guideline;
    uint8_t        guideline_orientation; // 0=horizontal, 1=vertical
    float          guideline_percent;     // 0.0-1.0, or -1 if using begin
    float          guideline_begin;       // dp offset from start, or -1

    // Image data (for ImageView)
    const uint8_t *image_data;     // PNG/JPEG bytes (NOT owned - points into DxUINode data)
    uint32_t       image_data_len;

    // 9-patch PNG metadata
    bool           is_nine_patch;
    int32_t        nine_patch_padding[4];    // left, top, right, bottom content padding
    int32_t        nine_patch_stretch_x[2];  // start, end of horizontal stretch region
    int32_t        nine_patch_stretch_y[2];  // start, end of vertical stretch region

    // Vector drawable data (for ImageView)
    char          *vector_path_data;   // SVG path data string (owned copy)
    uint32_t       vector_fill_color;  // ARGB fill color
    uint32_t       vector_stroke_color; // ARGB stroke color
    float          vector_stroke_width; // stroke width in dp
    float          vector_width;       // viewport width
    float          vector_height;      // viewport height

    // Shape drawable background
    DxShapeDrawable shape_bg;

    // WebView data
    char        *web_url;          // URL to load (owned copy)
    char        *web_html;         // HTML content to load (owned copy)

    // Animation / transform properties
    float          alpha;            // 0.0-1.0 (default 1.0)
    float          rotation;         // degrees (default 0)
    float          scale_x;          // scale factor (default 1.0)
    float          scale_y;          // scale factor (default 1.0)
    float          translation_x;    // dp offset (default 0)
    float          translation_y;    // dp offset (default 0)

    // Measure/layout pass results
    float          measured_width;  // resolved width in dp (0 = not measured)
    float          measured_height; // resolved height in dp (0 = not measured)

    // Focus management
    bool           focusable;       // true if view can receive focus
    bool           focused;         // true if view currently has focus

    // Diff-based invalidation
    uint32_t       version;        // snapshot of DxUINode version at serialization time
    bool           dirty;          // true if this node changed since last serialization

    // Canvas draw commands (owned copies)
    DxDrawCommand *draw_commands;
    uint32_t       draw_cmd_count;

    struct DxRenderNode *children;
    uint32_t     child_count;
    uint32_t     total_child_count;  // total children in source node (may be > child_count)
    bool         has_more_children;  // true if child_count < total_child_count (lazy expansion)
} DxRenderNode;

// Render model - complete UI snapshot for Swift
struct DxRenderModel {
    DxRenderNode *root;
    uint32_t      version;      // incremented on each update
};

// UI tree operations
DxUINode *dx_ui_node_create(DxViewType type, uint32_t view_id);
void      dx_ui_node_destroy(DxUINode *node);
void      dx_ui_node_add_child(DxUINode *parent, DxUINode *child);
DxUINode *dx_ui_node_find_by_id(DxUINode *root, uint32_t view_id);
void      dx_ui_node_set_text(DxUINode *node, const char *text);
uint32_t  dx_ui_node_count(const DxUINode *node);
uint32_t  dx_ui_node_score_layout(const DxUINode *root);

// Render model
DxRenderModel *dx_render_model_create(DxUINode *root);
void           dx_render_model_destroy(DxRenderModel *model);

// Layout XML parsing -> UI tree
DxResult dx_layout_parse(DxContext *ctx, const uint8_t *xml_data, uint32_t xml_size, DxUINode **out);

// Layout XML parsing with cache (resource_id used as cache key; 0 = no caching)
DxResult dx_layout_parse_cached(DxContext *ctx, uint32_t resource_id,
                                 const uint8_t *xml_data, uint32_t xml_size, DxUINode **out);

// Flush the layout parse cache
void dx_ui_cache_clear(void);

// Dimension unit conversion (dp/sp/px -> iOS points)
float dx_ui_dp_to_points(float dp);
float dx_ui_sp_to_points(float sp);

// UI tree inspector - returns a malloc'd string showing the tree hierarchy
char *dx_ui_tree_dump(DxUINode *root);

// Diff-based invalidation
void dx_ui_node_invalidate(DxUINode *node);
bool dx_ui_tree_has_changes(DxUINode *root);
void dx_ui_tree_clear_dirty(DxUINode *root);

// Measure/layout pass
void dx_ui_measure(DxUINode *root, float parent_width, float parent_height);

// Focus management
void dx_ui_set_focus(DxUINode *root, DxUINode *target);

#endif // DX_VIEW_H

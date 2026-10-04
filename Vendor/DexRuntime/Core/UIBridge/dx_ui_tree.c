#include "../Include/dx_view.h"
#include "../Include/dx_log.h"
#include "../Include/dx_context.h"
#include "../Include/dx_resources.h"
#include "../Include/dx_apk.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

#define TAG "UITree"

#include "../Include/dx_memory.h"

// ============================================================
// Layout parse cache (FIFO, 32 entries)
// ============================================================

#define DX_LAYOUT_CACHE_SIZE 32

typedef struct {
    uint32_t  resource_id;
    DxUINode *tree;       // cached parsed tree (owned)
} DxLayoutCacheEntry;

static DxLayoutCacheEntry s_layout_cache[DX_LAYOUT_CACHE_SIZE];
static uint32_t s_layout_cache_count = 0;
static uint32_t s_layout_cache_next  = 0;  // FIFO write index

// ── Hash index for O(1) resource-ID lookup into the FIFO cache ──
// Maps resource_id -> index in s_layout_cache[] via open-addressing.
// Sized at 2x cache to keep load factor ≤ 0.5.
#define DX_LAYOUT_HASH_SIZE 64
#define DX_LAYOUT_HASH_EMPTY UINT32_MAX

typedef struct {
    uint32_t resource_id;  // 0 = empty slot
    uint32_t cache_idx;    // index into s_layout_cache[]
} DxLayoutHashEntry;

static DxLayoutHashEntry s_layout_hash[DX_LAYOUT_HASH_SIZE];

static inline uint32_t dx_layout_hash_fn(uint32_t id) {
    // FNV-1a-style mix for uint32
    uint32_t h = 2166136261u;
    h ^= id & 0xFF;         h *= 16777619u;
    h ^= (id >> 8) & 0xFF;  h *= 16777619u;
    h ^= (id >> 16) & 0xFF; h *= 16777619u;
    h ^= (id >> 24) & 0xFF; h *= 16777619u;
    return h % DX_LAYOUT_HASH_SIZE;
}

// Insert or update the hash index for a given resource_id -> cache_idx mapping.
static void dx_layout_hash_put(uint32_t resource_id, uint32_t cache_idx) {
    if (resource_id == 0) return;
    uint32_t slot = dx_layout_hash_fn(resource_id);
    for (uint32_t probe = 0; probe < DX_LAYOUT_HASH_SIZE; probe++) {
        uint32_t idx = (slot + probe) % DX_LAYOUT_HASH_SIZE;
        if (s_layout_hash[idx].resource_id == 0 ||
            s_layout_hash[idx].resource_id == resource_id) {
            s_layout_hash[idx].resource_id = resource_id;
            s_layout_hash[idx].cache_idx   = cache_idx;
            return;
        }
    }
    // Table full (should never happen with load factor ≤ 0.5)
}

// Remove a resource_id from the hash index (called on eviction).
static void dx_layout_hash_remove(uint32_t resource_id) {
    if (resource_id == 0) return;
    uint32_t slot = dx_layout_hash_fn(resource_id);
    for (uint32_t probe = 0; probe < DX_LAYOUT_HASH_SIZE; probe++) {
        uint32_t idx = (slot + probe) % DX_LAYOUT_HASH_SIZE;
        if (s_layout_hash[idx].resource_id == resource_id) {
            s_layout_hash[idx].resource_id = 0;
            s_layout_hash[idx].cache_idx   = 0;
            return;
        }
        if (s_layout_hash[idx].resource_id == 0) return; // not found
    }
}

// Lookup in hash index. Returns cache index or DX_LAYOUT_HASH_EMPTY.
static uint32_t dx_layout_hash_find(uint32_t resource_id) {
    if (resource_id == 0) return DX_LAYOUT_HASH_EMPTY;
    uint32_t slot = dx_layout_hash_fn(resource_id);
    for (uint32_t probe = 0; probe < DX_LAYOUT_HASH_SIZE; probe++) {
        uint32_t idx = (slot + probe) % DX_LAYOUT_HASH_SIZE;
        if (s_layout_hash[idx].resource_id == resource_id) {
            return s_layout_hash[idx].cache_idx;
        }
        if (s_layout_hash[idx].resource_id == 0) return DX_LAYOUT_HASH_EMPTY;
    }
    return DX_LAYOUT_HASH_EMPTY;
}

// Deep-clone a DxUINode tree (no listener/runtime_obj references are copied)
static DxUINode *dx_ui_node_clone(const DxUINode *src) {
    if (!src) return NULL;

    DxUINode *dst = (DxUINode *)dx_malloc(sizeof(DxUINode));
    if (!dst) return NULL;

    // Copy all scalar/struct fields
    memcpy(dst, src, sizeof(DxUINode));

    // Null out pointers that must be independently owned or not cloned
    dst->parent = NULL;
    dst->children = NULL;
    dst->child_count = 0;
    dst->child_capacity = 0;
    dst->click_listener = NULL;
    dst->long_click_listener = NULL;
    dst->touch_listener = NULL;
    dst->refresh_listener = NULL;
    dst->runtime_obj = NULL;
    dst->draw_commands = NULL;
    dst->draw_cmd_count = 0;
    dst->draw_cmd_capacity = 0;

    // Deep-copy owned strings
    dst->text = src->text ? dx_strdup(src->text) : NULL;
    dst->hint = src->hint ? dx_strdup(src->hint) : NULL;
    dst->web_url = src->web_url ? dx_strdup(src->web_url) : NULL;
    dst->web_html = src->web_html ? dx_strdup(src->web_html) : NULL;
    dst->vector_path_data = src->vector_path_data ? dx_strdup(src->vector_path_data) : NULL;

    // Deep-copy image data
    if (src->image_data && src->image_data_len > 0) {
        dst->image_data = (uint8_t *)dx_malloc(src->image_data_len);
        if (dst->image_data) {
            memcpy(dst->image_data, src->image_data, src->image_data_len);
        }
        dst->image_data_len = src->image_data_len;
    } else {
        dst->image_data = NULL;
        dst->image_data_len = 0;
    }

    // Recursively clone children
    if (src->child_count > 0) {
        dst->children = (DxUINode **)dx_malloc(sizeof(DxUINode *) * src->child_count);
        if (dst->children) {
            dst->child_capacity = src->child_count;
            for (uint32_t i = 0; i < src->child_count; i++) {
                DxUINode *child_clone = dx_ui_node_clone(src->children[i]);
                if (child_clone) {
                    child_clone->parent = dst;
                    dst->children[dst->child_count++] = child_clone;
                }
            }
        }
    }

    return dst;
}

// Look up a cached layout tree by resource ID. Returns a deep clone on hit, NULL on miss.
// Uses hash index for O(1) lookup instead of linear scan.
static DxUINode *dx_layout_cache_get(uint32_t resource_id) {
    if (resource_id == 0) return NULL;

    uint32_t ci = dx_layout_hash_find(resource_id);
    if (ci != DX_LAYOUT_HASH_EMPTY && ci < s_layout_cache_count &&
        s_layout_cache[ci].resource_id == resource_id && s_layout_cache[ci].tree) {
        DX_DEBUG(TAG, "Layout cache hit for resource 0x%08x (hash)", resource_id);
        return dx_ui_node_clone(s_layout_cache[ci].tree);
    }
    return NULL;
}

// Insert a layout tree into the cache (stores a deep clone).
// Maintains hash index alongside FIFO cache for O(1) lookup.
static void dx_layout_cache_put(uint32_t resource_id, const DxUINode *tree) {
    if (resource_id == 0 || !tree) return;

    // Check for duplicate via hash - update in place
    uint32_t ci = dx_layout_hash_find(resource_id);
    if (ci != DX_LAYOUT_HASH_EMPTY && ci < s_layout_cache_count &&
        s_layout_cache[ci].resource_id == resource_id) {
        dx_ui_node_destroy(s_layout_cache[ci].tree);
        s_layout_cache[ci].tree = dx_ui_node_clone(tree);
        return;
    }

    // FIFO eviction if full
    if (s_layout_cache_count >= DX_LAYOUT_CACHE_SIZE) {
        // Remove evicted entry from hash index
        dx_layout_hash_remove(s_layout_cache[s_layout_cache_next].resource_id);
        // Evict at s_layout_cache_next
        dx_ui_node_destroy(s_layout_cache[s_layout_cache_next].tree);
        s_layout_cache[s_layout_cache_next].resource_id = resource_id;
        s_layout_cache[s_layout_cache_next].tree = dx_ui_node_clone(tree);
        // Update hash index
        dx_layout_hash_put(resource_id, s_layout_cache_next);
        s_layout_cache_next = (s_layout_cache_next + 1) % DX_LAYOUT_CACHE_SIZE;
    } else {
        // Still have room
        uint32_t idx = s_layout_cache_count;
        s_layout_cache[idx].resource_id = resource_id;
        s_layout_cache[idx].tree = dx_ui_node_clone(tree);
        // Update hash index
        dx_layout_hash_put(resource_id, idx);
        s_layout_cache_count++;
        s_layout_cache_next = s_layout_cache_count % DX_LAYOUT_CACHE_SIZE;
    }

    DX_DEBUG(TAG, "Layout cache store for resource 0x%08x (count=%u)", resource_id, s_layout_cache_count);
}

// Flush the entire layout parse cache (and hash index).
void dx_ui_cache_clear(void) {
    for (uint32_t i = 0; i < s_layout_cache_count; i++) {
        dx_ui_node_destroy(s_layout_cache[i].tree);
        s_layout_cache[i].tree = NULL;
        s_layout_cache[i].resource_id = 0;
    }
    s_layout_cache_count = 0;
    s_layout_cache_next = 0;
    memset(s_layout_hash, 0, sizeof(s_layout_hash));
    DX_DEBUG(TAG, "Layout cache cleared");
}

// ============================================================
// Dimension unit conversion
// ============================================================

// Screen density scale factor.
// On iOS, 1pt = 1dp for @2x retina displays (160dpi baseline × 2 = 320dpi).
// For @3x (e.g. Plus/Max models, 160 × 3 = 480dpi), dp values still map 1:1
// to iOS points because Apple's point system already accounts for density.
// Therefore the dp→pt factor is always 1.0 on iOS.
#define DX_DP_SCALE 1.0f

// Convert Android dp (density-independent pixels) to iOS points.
// On iOS @2x/3x, 1dp ≈ 1pt because both systems use 160dpi as baseline.
float dx_ui_dp_to_points(float dp) {
    return dp * DX_DP_SCALE;
}

// Convert Android sp (scale-independent pixels for text) to iOS points.
// At default user text scale, 1sp = 1dp = 1pt on iOS.
float dx_ui_sp_to_points(float sp) {
    return sp * DX_DP_SCALE;
}

// Convert Android px (raw pixels) to iOS points.
// Assuming source density of ~320dpi (mdpi × 2), divide by 2.0 to get points.
// This matches the common xxhdpi resource bucket (480dpi / 3 = 160 = mdpi baseline).
#define DX_PX_TO_PT_SCALE 0.5f
static float dx_ui_px_to_points(float px) {
    return px * DX_PX_TO_PT_SCALE;
}

// Decode a complex Android dimension attribute value and convert to iOS points.
// Uses the proper Android fixed-point format decoder from dx_resources.
static float dx_ui_decode_dimension(uint32_t attr_data) {
    uint8_t unit = 0;
    float value = dx_resources_decode_dimen(attr_data, &unit);

    switch (unit) {
        case DX_DIMEN_UNIT_PX:
            return dx_ui_px_to_points(value);
        case DX_DIMEN_UNIT_DIP: // dp
            return dx_ui_dp_to_points(value);
        case DX_DIMEN_UNIT_SP:
            return dx_ui_sp_to_points(value);
        case DX_DIMEN_UNIT_PT:
            return value; // pt → pt, 1:1
        case DX_DIMEN_UNIT_IN:
            return value * 72.0f; // 1 inch = 72 points
        case DX_DIMEN_UNIT_MM:
            return value * 72.0f / 25.4f; // mm → points
        default:
            return dx_ui_dp_to_points(value); // fallback: treat as dp
    }
}

// Convenience: decode a dimension attribute and return as int32_t (rounded).
static int32_t dx_ui_decode_dimension_int(uint32_t attr_data) {
    float pts = dx_ui_decode_dimension(attr_data);
    return (int32_t)(pts + 0.5f);
}

DxUINode *dx_ui_node_create(DxViewType type, uint32_t view_id) {
    DxUINode *node = (DxUINode *)dx_malloc(sizeof(DxUINode));
    if (!node) return NULL;

    node->type = type;
    node->view_id = view_id;
    node->visibility = DX_VISIBLE;
    node->orientation = DX_ORIENTATION_VERTICAL;
    node->text_size = 16.0f;
    node->width = -1;   // match_parent
    node->height = -2;  // wrap_content

    // Initialize ConstraintLayout constraints to "none"
    node->constraints.left_to_left = DX_CONSTRAINT_NONE;
    node->constraints.left_to_right = DX_CONSTRAINT_NONE;
    node->constraints.right_to_right = DX_CONSTRAINT_NONE;
    node->constraints.right_to_left = DX_CONSTRAINT_NONE;
    node->constraints.top_to_top = DX_CONSTRAINT_NONE;
    node->constraints.top_to_bottom = DX_CONSTRAINT_NONE;
    node->constraints.bottom_to_bottom = DX_CONSTRAINT_NONE;
    node->constraints.bottom_to_top = DX_CONSTRAINT_NONE;
    node->constraints.horizontal_bias = 0.5f;
    node->constraints.vertical_bias = 0.5f;
    node->constraints.h_chain_style = DX_CHAIN_NONE;
    node->constraints.v_chain_style = DX_CHAIN_NONE;

    // Animation / transform defaults
    node->alpha = 1.0f;
    node->rotation = 0.0f;
    node->scale_x = 1.0f;
    node->scale_y = 1.0f;
    node->translation_x = 0.0f;
    node->translation_y = 0.0f;

    // Guideline defaults
    node->is_guideline = false;
    node->guideline_orientation = DX_GUIDELINE_VERTICAL;
    node->guideline_percent = -1.0f;
    node->guideline_begin = -1.0f;

    // Measure/layout defaults
    node->measured_width = 0.0f;
    node->measured_height = 0.0f;

    // Focus defaults
    node->focusable = false;
    node->focused = false;

    // Diff-based invalidation defaults
    node->version = 0;
    node->dirty = true;  // new nodes are dirty by default

    return node;
}

void dx_ui_node_destroy(DxUINode *node) {
    if (!node) return;

    for (uint32_t i = 0; i < node->child_count; i++) {
        dx_ui_node_destroy(node->children[i]);
    }
    dx_free(node->children);
    dx_free(node->text);
    dx_free(node->hint);
    dx_free(node->image_data);
    dx_free(node->vector_path_data);
    dx_free(node->web_url);
    dx_free(node->web_html);
    if (node->draw_commands) {
        for (uint32_t i = 0; i < node->draw_cmd_count; i++) {
            dx_free(node->draw_commands[i].text);
        }
        dx_free(node->draw_commands);
    }
    dx_free(node);
}

void dx_ui_node_add_child(DxUINode *parent, DxUINode *child) {
    if (!parent || !child) return;

    if (parent->child_count >= parent->child_capacity) {
        uint32_t new_cap = parent->child_capacity == 0 ? 4 : parent->child_capacity * 2;
        DxUINode **new_children = (DxUINode **)dx_realloc(parent->children,
                                                           sizeof(DxUINode *) * new_cap);
        if (!new_children) return;
        parent->children = new_children;
        parent->child_capacity = new_cap;
    }

    child->parent = parent;
    parent->children[parent->child_count++] = child;
}

DxUINode *dx_ui_node_find_by_id(DxUINode *root, uint32_t view_id) {
    if (!root) return NULL;
    if (root->view_id == view_id && view_id != 0) return root;

    for (uint32_t i = 0; i < root->child_count; i++) {
        DxUINode *found = dx_ui_node_find_by_id(root->children[i], view_id);
        if (found) return found;
    }
    return NULL;
}

void dx_ui_node_set_text(DxUINode *node, const char *text) {
    if (!node) return;
    dx_free(node->text);
    node->text = text ? dx_strdup(text) : NULL;
    dx_ui_node_invalidate(node);
}

uint32_t dx_ui_node_count(const DxUINode *node) {
    if (!node) return 0;
    uint32_t count = 1;
    for (uint32_t i = 0; i < node->child_count; i++) {
        count += dx_ui_node_count(node->children[i]);
    }
    return count;
}

// Count nodes of specific view types (for heuristic layout selection)
static void count_view_types(const DxUINode *node, uint32_t *buttons, uint32_t *text_views) {
    if (!node) return;
    if (node->type == DX_VIEW_BUTTON) (*buttons)++;
    if (node->type == DX_VIEW_TEXT_VIEW) (*text_views)++;
    for (uint32_t i = 0; i < node->child_count; i++) {
        count_view_types(node->children[i], buttons, text_views);
    }
}

uint32_t dx_ui_node_score_layout(const DxUINode *root) {
    if (!root) return 0;
    // Primary metric: total node count. The main UI layout typically has
    // the most views. Custom view classes (parsed as VIEW_GROUP) are
    // counted equally since apps use custom views for their UIs.
    return dx_ui_node_count(root);
}

// ============================================================
// UI tree inspector
// ============================================================

static const char *view_type_name(DxViewType type) {
    switch (type) {
        case DX_VIEW_NONE:              return "None";
        case DX_VIEW_LINEAR_LAYOUT:     return "LinearLayout";
        case DX_VIEW_TEXT_VIEW:          return "TextView";
        case DX_VIEW_BUTTON:            return "Button";
        case DX_VIEW_IMAGE_VIEW:        return "ImageView";
        case DX_VIEW_EDIT_TEXT:          return "EditText";
        case DX_VIEW_FRAME_LAYOUT:      return "FrameLayout";
        case DX_VIEW_RELATIVE_LAYOUT:   return "RelativeLayout";
        case DX_VIEW_CONSTRAINT_LAYOUT: return "ConstraintLayout";
        case DX_VIEW_SCROLL_VIEW:       return "ScrollView";
        case DX_VIEW_RECYCLER_VIEW:     return "RecyclerView";
        case DX_VIEW_CARD_VIEW:         return "CardView";
        case DX_VIEW_SWITCH:            return "Switch";
        case DX_VIEW_CHECKBOX:          return "CheckBox";
        case DX_VIEW_PROGRESS_BAR:      return "ProgressBar";
        case DX_VIEW_TOOLBAR:           return "Toolbar";
        case DX_VIEW_VIEW:              return "View";
        case DX_VIEW_VIEW_GROUP:        return "ViewGroup";
        case DX_VIEW_LIST_VIEW:         return "ListView";
        case DX_VIEW_GRID_VIEW:         return "GridView";
        case DX_VIEW_SPINNER:           return "Spinner";
        case DX_VIEW_SEEK_BAR:          return "SeekBar";
        case DX_VIEW_RATING_BAR:        return "RatingBar";
        case DX_VIEW_RADIO_BUTTON:      return "RadioButton";
        case DX_VIEW_RADIO_GROUP:       return "RadioGroup";
        case DX_VIEW_FAB:               return "FAB";
        case DX_VIEW_TAB_LAYOUT:        return "TabLayout";
        case DX_VIEW_VIEW_PAGER:        return "ViewPager";
        case DX_VIEW_WEB_VIEW:          return "WebView";
        case DX_VIEW_CHIP:              return "Chip";
        case DX_VIEW_BOTTOM_NAV:        return "BottomNav";
        case DX_VIEW_SWIPE_REFRESH:     return "SwipeRefresh";
        default:                        return "Unknown";
    }
}

// Dynamic string buffer for tree dump
typedef struct {
    char    *data;
    uint32_t len;
    uint32_t cap;
} DxStrBuf;

static void strbuf_init(DxStrBuf *sb) {
    sb->cap = 1024;
    sb->data = (char *)dx_malloc(sb->cap);
    sb->len = 0;
    if (sb->data) sb->data[0] = '\0';
}

static void strbuf_appendf(DxStrBuf *sb, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void strbuf_appendf(DxStrBuf *sb, const char *fmt, ...) {
    if (!sb->data) return;
    va_list ap;
    va_start(ap, fmt);
    int needed = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (needed < 0) return;

    while (sb->len + (uint32_t)needed + 1 > sb->cap) {
        uint32_t new_cap = sb->cap * 2;
        char *new_data = (char *)dx_realloc(sb->data, new_cap);
        if (!new_data) return;
        sb->data = new_data;
        sb->cap = new_cap;
    }

    va_start(ap, fmt);
    vsnprintf(sb->data + sb->len, sb->cap - sb->len, fmt, ap);
    va_end(ap);
    sb->len += (uint32_t)needed;
}

static void dump_node(DxStrBuf *sb, DxUINode *node, int depth) {
    if (!node) return;

    // Indentation
    for (int i = 0; i < depth; i++) {
        strbuf_appendf(sb, "  ");
    }

    // Node info
    strbuf_appendf(sb, "%s", view_type_name(node->type));
    if (node->view_id != 0) {
        strbuf_appendf(sb, " id=0x%x", node->view_id);
    }
    if (node->text) {
        if (strlen(node->text) > 30) {
            strbuf_appendf(sb, " text=\"%.27s...\"", node->text);
        } else {
            strbuf_appendf(sb, " text=\"%s\"", node->text);
        }
    }
    strbuf_appendf(sb, " w=%d h=%d", node->width, node->height);
    if (node->child_count > 0) {
        strbuf_appendf(sb, " children=%u", node->child_count);
    }
    if (node->visibility == DX_GONE) {
        strbuf_appendf(sb, " [GONE]");
    } else if (node->visibility == DX_INVISIBLE) {
        strbuf_appendf(sb, " [INVISIBLE]");
    }
    strbuf_appendf(sb, "\n");

    for (uint32_t i = 0; i < node->child_count; i++) {
        dump_node(sb, node->children[i], depth + 1);
    }
}

char *dx_ui_tree_dump(DxUINode *root) {
    if (!root) {
        char *empty = dx_strdup("(no UI tree)\n");
        return empty;
    }

    DxStrBuf sb;
    strbuf_init(&sb);

    uint32_t total = dx_ui_node_count(root);
    strbuf_appendf(&sb, "UI Tree (%u nodes):\n", total);
    dump_node(&sb, root, 0);

    return sb.data;  // caller must free
}

// ============================================================
// Render model (serialized snapshot for Swift bridge)
// ============================================================

// ============================================================
// Measure/layout pass
// ============================================================

// Default intrinsic size for leaf views when wrap_content is used
#define DX_DEFAULT_TEXT_WIDTH  100.0f
#define DX_DEFAULT_TEXT_HEIGHT  20.0f
#define DX_DEFAULT_BUTTON_HEIGHT 48.0f
#define DX_DEFAULT_EDIT_HEIGHT   48.0f
#define DX_DEFAULT_IMAGE_SIZE    48.0f

static float dx_ui_intrinsic_width(DxUINode *node) {
    switch (node->type) {
        case DX_VIEW_TEXT_VIEW:
        case DX_VIEW_BUTTON:
        case DX_VIEW_EDIT_TEXT:
            return DX_DEFAULT_TEXT_WIDTH;
        case DX_VIEW_IMAGE_VIEW:
            return DX_DEFAULT_IMAGE_SIZE;
        case DX_VIEW_CHECKBOX:
        case DX_VIEW_SWITCH:
        case DX_VIEW_RADIO_BUTTON:
            return DX_DEFAULT_TEXT_WIDTH;
        default:
            return 0.0f;
    }
}

static float dx_ui_intrinsic_height(DxUINode *node) {
    switch (node->type) {
        case DX_VIEW_TEXT_VIEW:
            return node->text_size > 0 ? node->text_size * 1.4f : DX_DEFAULT_TEXT_HEIGHT;
        case DX_VIEW_BUTTON:
            return DX_DEFAULT_BUTTON_HEIGHT;
        case DX_VIEW_EDIT_TEXT:
            return DX_DEFAULT_EDIT_HEIGHT;
        case DX_VIEW_IMAGE_VIEW:
            return DX_DEFAULT_IMAGE_SIZE;
        case DX_VIEW_CHECKBOX:
        case DX_VIEW_SWITCH:
        case DX_VIEW_RADIO_BUTTON:
            return DX_DEFAULT_BUTTON_HEIGHT;
        case DX_VIEW_PROGRESS_BAR:
        case DX_VIEW_SEEK_BAR:
            return 24.0f;
        default:
            return 0.0f;
    }
}

void dx_ui_measure(DxUINode *root, float parent_width, float parent_height) {
    if (!root) return;

    // Resolve width
    if (root->width == -1) {
        // match_parent
        root->measured_width = parent_width;
    } else if (root->width == -2) {
        // wrap_content: will be computed from children or intrinsic size
        root->measured_width = 0.0f;
    } else if (root->width > 0) {
        // Fixed dp value
        root->measured_width = (float)root->width;
    }

    // Resolve height
    if (root->height == -1) {
        root->measured_height = parent_height;
    } else if (root->height == -2) {
        root->measured_height = 0.0f;
    } else if (root->height > 0) {
        root->measured_height = (float)root->height;
    }

    // Available space for children (account for padding)
    float avail_w = root->measured_width
                    - (float)root->padding[0] - (float)root->padding[2];
    float avail_h = root->measured_height
                    - (float)root->padding[1] - (float)root->padding[3];
    if (avail_w < 0) avail_w = parent_width;
    if (avail_h < 0) avail_h = parent_height;

    // Recurse into children
    bool is_vertical = (root->orientation == DX_ORIENTATION_VERTICAL);
    float children_sum_w = 0.0f;
    float children_sum_h = 0.0f;
    float children_max_w = 0.0f;
    float children_max_h = 0.0f;

    for (uint32_t i = 0; i < root->child_count; i++) {
        DxUINode *child = root->children[i];
        dx_ui_measure(child, avail_w, avail_h);

        float cw = child->measured_width + (float)child->margin[0] + (float)child->margin[2];
        float ch = child->measured_height + (float)child->margin[1] + (float)child->margin[3];

        children_sum_w += cw;
        children_sum_h += ch;
        if (cw > children_max_w) children_max_w = cw;
        if (ch > children_max_h) children_max_h = ch;
    }

    // For wrap_content, compute from children or intrinsic size
    if (root->width == -2) {
        if (root->child_count > 0) {
            if (is_vertical) {
                root->measured_width = children_max_w
                    + (float)root->padding[0] + (float)root->padding[2];
            } else {
                root->measured_width = children_sum_w
                    + (float)root->padding[0] + (float)root->padding[2];
            }
        } else {
            float intrinsic = dx_ui_intrinsic_width(root);
            root->measured_width = intrinsic
                + (float)root->padding[0] + (float)root->padding[2];
        }
    }

    if (root->height == -2) {
        if (root->child_count > 0) {
            if (is_vertical) {
                root->measured_height = children_sum_h
                    + (float)root->padding[1] + (float)root->padding[3];
            } else {
                root->measured_height = children_max_h
                    + (float)root->padding[1] + (float)root->padding[3];
            }
        } else {
            float intrinsic = dx_ui_intrinsic_height(root);
            root->measured_height = intrinsic
                + (float)root->padding[1] + (float)root->padding[3];
        }
    }
}

// ============================================================
// Focus management
// ============================================================

static void dx_ui_clear_focus_recursive(DxUINode *node) {
    if (!node) return;
    node->focused = false;
    for (uint32_t i = 0; i < node->child_count; i++) {
        dx_ui_clear_focus_recursive(node->children[i]);
    }
}

void dx_ui_set_focus(DxUINode *root, DxUINode *target) {
    if (!root) return;
    // Clear all focus in tree
    dx_ui_clear_focus_recursive(root);
    // Set focus on target if it's focusable
    if (target && target->focusable) {
        target->focused = true;
        dx_ui_node_invalidate(target);
    }
}

static DxRenderNode *serialize_node(DxUINode *node) {
    if (!node) return NULL;

    DxRenderNode *rn = (DxRenderNode *)dx_malloc(sizeof(DxRenderNode));
    if (!rn) return NULL;

    rn->type = node->type;
    rn->view_id = node->view_id;
    rn->visibility = node->visibility;
    rn->text = node->text ? dx_strdup(node->text) : NULL;
    rn->hint = node->hint ? dx_strdup(node->hint) : NULL;
    rn->orientation = node->orientation;
    rn->text_size = node->text_size;
    rn->width = node->width;
    rn->height = node->height;
    rn->weight = node->weight;
    rn->gravity = node->gravity;
    memcpy(rn->padding, node->padding, sizeof(rn->padding));
    memcpy(rn->margin, node->margin, sizeof(rn->margin));
    rn->bg_color = node->bg_color;
    rn->text_color = node->text_color;
    rn->is_checked = node->is_checked;
    rn->input_type = node->input_type;
    rn->scale_type = node->scale_type;
    rn->has_click_listener = (node->click_listener != NULL);
    rn->has_long_click_listener = (node->long_click_listener != NULL);
    rn->has_refresh_listener = (node->refresh_listener != NULL);
    rn->relative_flags = node->relative_flags;
    rn->rel_above = node->rel_above;
    rn->rel_below = node->rel_below;
    rn->rel_left_of = node->rel_left_of;
    rn->rel_right_of = node->rel_right_of;
    rn->constraints = node->constraints;
    rn->is_guideline = node->is_guideline;
    rn->guideline_orientation = node->guideline_orientation;
    rn->guideline_percent = node->guideline_percent;
    rn->guideline_begin = node->guideline_begin;
    rn->image_data = node->image_data;        // borrow pointer (DxUINode owns the data)
    rn->image_data_len = node->image_data_len;
    rn->is_nine_patch = node->is_nine_patch;
    memcpy(rn->nine_patch_padding, node->nine_patch_padding, sizeof(rn->nine_patch_padding));
    memcpy(rn->nine_patch_stretch_x, node->nine_patch_stretch_x, sizeof(rn->nine_patch_stretch_x));
    memcpy(rn->nine_patch_stretch_y, node->nine_patch_stretch_y, sizeof(rn->nine_patch_stretch_y));
    rn->vector_path_data = node->vector_path_data ? dx_strdup(node->vector_path_data) : NULL;
    rn->vector_fill_color = node->vector_fill_color;
    rn->vector_stroke_color = node->vector_stroke_color;
    rn->vector_stroke_width = node->vector_stroke_width;
    rn->vector_width = node->vector_width;
    rn->vector_height = node->vector_height;
    rn->shape_bg = node->shape_bg;
    rn->alpha = node->alpha;
    rn->rotation = node->rotation;
    rn->scale_x = node->scale_x;
    rn->scale_y = node->scale_y;
    rn->translation_x = node->translation_x;
    rn->translation_y = node->translation_y;
    rn->web_url = node->web_url ? dx_strdup(node->web_url) : NULL;
    rn->web_html = node->web_html ? dx_strdup(node->web_html) : NULL;

    // Measure/layout results
    rn->measured_width = node->measured_width;
    rn->measured_height = node->measured_height;

    // Focus state
    rn->focusable = node->focusable;
    rn->focused = node->focused;

    // Diff-based invalidation
    rn->version = node->version;
    rn->dirty = node->dirty;

    // Copy draw commands
    if (node->draw_cmd_count > 0 && node->draw_commands) {
        rn->draw_cmd_count = node->draw_cmd_count;
        rn->draw_commands = (DxDrawCommand *)dx_malloc(sizeof(DxDrawCommand) * node->draw_cmd_count);
        if (rn->draw_commands) {
            memcpy(rn->draw_commands, node->draw_commands, sizeof(DxDrawCommand) * node->draw_cmd_count);
            // Deep-copy text strings
            for (uint32_t i = 0; i < rn->draw_cmd_count; i++) {
                if (rn->draw_commands[i].text) {
                    rn->draw_commands[i].text = dx_strdup(rn->draw_commands[i].text);
                }
            }
        } else {
            rn->draw_cmd_count = 0;
        }
    } else {
        rn->draw_commands = NULL;
        rn->draw_cmd_count = 0;
    }

    if (node->child_count > 0) {
        // Lazy child expansion: limit serialized children to DX_SERIALIZE_MAX_CHILDREN
        // to avoid excessive memory/time on very large view hierarchies (>100 nodes)
        #define DX_SERIALIZE_MAX_CHILDREN 100
        uint32_t serialize_count = node->child_count;
        rn->total_child_count = node->child_count;
        if (serialize_count > DX_SERIALIZE_MAX_CHILDREN) {
            serialize_count = DX_SERIALIZE_MAX_CHILDREN;
            rn->has_more_children = true;
            DX_DEBUG(TAG, "Lazy expansion: node %u has %u children, serializing first %u",
                     node->view_id, node->child_count, serialize_count);
        } else {
            rn->has_more_children = false;
        }
        rn->children = (DxRenderNode *)dx_malloc(sizeof(DxRenderNode) * serialize_count);
        rn->child_count = serialize_count;
        for (uint32_t i = 0; i < serialize_count; i++) {
            DxRenderNode *child = serialize_node(node->children[i]);
            if (child) {
                rn->children[i] = *child;
                dx_free(child);
            }
        }
    } else {
        rn->total_child_count = 0;
        rn->has_more_children = false;
    }

    return rn;
}

DxRenderModel *dx_render_model_create(DxUINode *root) {
    if (!root) return NULL;

    DxRenderModel *model = (DxRenderModel *)dx_malloc(sizeof(DxRenderModel));
    if (!model) return NULL;

    // Run measure/layout pass before serialization
    // Use typical mobile screen dimensions as initial available space (390x844 dp)
    dx_ui_measure(root, 390.0f, 844.0f);

    static uint32_t version_counter = 0;
    model->version = ++version_counter;
    model->root = serialize_node(root);

    // Clear dirty flags after serialization snapshot
    dx_ui_tree_clear_dirty(root);

    DX_DEBUG(TAG, "Render model v%u created", model->version);
    return model;
}

static void free_render_node(DxRenderNode *node) {
    if (!node) return;
    dx_free(node->text);
    dx_free(node->hint);
    dx_free(node->vector_path_data);
    dx_free(node->web_url);
    dx_free(node->web_html);
    if (node->draw_commands) {
        for (uint32_t i = 0; i < node->draw_cmd_count; i++) {
            dx_free(node->draw_commands[i].text);
        }
        dx_free(node->draw_commands);
    }
    for (uint32_t i = 0; i < node->child_count; i++) {
        free_render_node(&node->children[i]);
    }
    dx_free(node->children);
}

void dx_render_model_destroy(DxRenderModel *model) {
    if (!model) return;
    if (model->root) {
        free_render_node(model->root);
        dx_free(model->root);
    }
    dx_free(model);
}

// ============================================================
// Diff-based invalidation
// ============================================================

void dx_ui_node_invalidate(DxUINode *node) {
    if (!node) return;
    node->dirty = true;
    node->version++;
}

bool dx_ui_tree_has_changes(DxUINode *root) {
    if (!root) return false;
    if (root->dirty) return true;
    for (uint32_t i = 0; i < root->child_count; i++) {
        if (dx_ui_tree_has_changes(root->children[i])) return true;
    }
    return false;
}

void dx_ui_tree_clear_dirty(DxUINode *root) {
    if (!root) return;
    root->dirty = false;
    for (uint32_t i = 0; i < root->child_count; i++) {
        dx_ui_tree_clear_dirty(root->children[i]);
    }
}

// ============================================================
// Layout XML parser -> UI tree
// ============================================================

// Minimal AXML parser for layout files
// Reuses the same binary XML format as AndroidManifest

#define AXML_FILE_MAGIC        0x00080003
#define AXML_CHUNK_STRINGPOOL  0x0001
#define AXML_CHUNK_RESOURCEMAP 0x0180
#define AXML_CHUNK_START_TAG   0x0102
#define AXML_CHUNK_END_TAG     0x0103
#define AXML_MAX_STRING_POOL   1000000  // 1M strings max
#define AXML_MAX_NESTING_DEPTH 100

// Well-known attribute resource IDs for layout
#define ATTR_ID          0x010100d0
#define ATTR_TEXT         0x01010014
#define ATTR_ORIENTATION  0x010100c4
#define ATTR_GRAVITY      0x010100af
#define ATTR_HINT         0x01010150
#define ATTR_TEXT_COLOR   0x01010098
#define ATTR_TEXT_SIZE    0x01010095
#define ATTR_BACKGROUND   0x010100d4
#define ATTR_PADDING      0x010100d5
#define ATTR_PADDING_L    0x010100d6
#define ATTR_PADDING_T    0x010100d7
#define ATTR_PADDING_R    0x010100d8
#define ATTR_PADDING_B    0x010100d9
#define ATTR_VISIBILITY   0x010100dc
#define ATTR_CHECKED      0x01010108
#define ATTR_LAYOUT_WIDTH  0x010100f4
#define ATTR_LAYOUT_HEIGHT 0x010100f5
#define ATTR_LAYOUT_MARGIN 0x010100f6
#define ATTR_LAYOUT_MARGIN_L 0x010100f7
#define ATTR_LAYOUT_MARGIN_T 0x010100f8
#define ATTR_LAYOUT_MARGIN_R 0x010100f9
#define ATTR_LAYOUT_MARGIN_B 0x010100fa
#define ATTR_PADDING_START 0x010103b3
#define ATTR_PADDING_END   0x010103b4
#define ATTR_LAYOUT_WEIGHT 0x01010181
#define ATTR_LAYOUT_MARGIN_START 0x010103b5
#define ATTR_LAYOUT_MARGIN_END   0x010103b6
#define ATTR_SRC           0x01010119  // android:src (ImageView drawable)
#define ATTR_INPUT_TYPE    0x01010006  // android:inputType
#define ATTR_SCALE_TYPE    0x0101011d  // android:scaleType
#define ATTR_ALPHA         0x0101031f  // android:alpha
#define ATTR_ROTATION      0x01010326  // android:rotation
#define ATTR_SCALE_X       0x01010324  // android:scaleX
#define ATTR_SCALE_Y       0x01010325  // android:scaleY
#define ATTR_TRANSLATION_X 0x01010322  // android:translationX
#define ATTR_TRANSLATION_Y 0x01010323  // android:translationY

// Style attribute
#define ATTR_STYLE         0x010100ba  // android:style (but style is often attr index 0xFFFFFFFF)

// Well-known theme attribute IDs (android.R.attr.*)
#define ATTR_COLOR_PRIMARY       0x01010433
#define ATTR_COLOR_PRIMARY_DARK  0x01010434
#define ATTR_COLOR_ACCENT        0x01010435
#define ATTR_COLOR_BACKGROUND    0x010100d4  // same as android:background
#define ATTR_TEXT_COLOR_PRIMARY   0x01010036
#define ATTR_WINDOW_BACKGROUND   0x01010054

// Attribute reference type (for ?attr/ values)
#define RES_VALUE_TYPE_ATTR  0x02

// RelativeLayout attributes
#define ATTR_LAYOUT_ABOVE            0x01010140
#define ATTR_LAYOUT_BELOW            0x01010141
#define ATTR_LAYOUT_TO_LEFT_OF       0x01010142
#define ATTR_LAYOUT_TO_RIGHT_OF      0x01010143
#define ATTR_LAYOUT_ALIGN_PARENT_TOP    0x01010130
#define ATTR_LAYOUT_ALIGN_PARENT_BOTTOM 0x01010131
#define ATTR_LAYOUT_ALIGN_PARENT_LEFT   0x01010132
#define ATTR_LAYOUT_ALIGN_PARENT_RIGHT  0x01010133
#define ATTR_LAYOUT_CENTER_IN_PARENT    0x01010134
#define ATTR_LAYOUT_CENTER_HORIZONTAL   0x01010135
#define ATTR_LAYOUT_CENTER_VERTICAL     0x01010136
#define ATTR_FOCUSABLE                  0x010100da  // android:focusable

static uint16_t read_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t read_u32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

// ============================================================
// Vector drawable AXML parser
// ============================================================

// Parse a vector drawable from compiled binary XML (AXML format).
// Extracts pathData, fillColor, strokeColor, strokeWidth, viewportWidth/Height.
// Concatenates all <path> elements' pathData into a single string.
// Returns true on success, populating the output parameters.
static bool dx_ui_parse_vector_drawable(const uint8_t *data, uint32_t size,
                                         char **out_path_data,
                                         uint32_t *out_fill_color,
                                         uint32_t *out_stroke_color,
                                         float *out_stroke_width,
                                         float *out_vp_width,
                                         float *out_vp_height) {
    if (!data || size < 12) return false;

    // Verify AXML magic
    uint32_t magic = read_u32(data);
    if (magic != AXML_FILE_MAGIC) return false;

    // Parse string pool
    uint32_t offset = 8;  // skip magic + file_size
    if (offset + 8 > size) return false;

    uint16_t sp_type = read_u16(data + offset);
    if (sp_type != AXML_CHUNK_STRINGPOOL) return false;

    uint32_t sp_size = read_u32(data + offset + 4);
    uint32_t sp_string_count = read_u32(data + offset + 8);
    if (sp_string_count > AXML_MAX_STRING_POOL || sp_string_count == 0) return false;

    uint32_t sp_flags = read_u32(data + offset + 16);
    bool is_utf8 = (sp_flags & (1u << 8)) != 0;
    uint32_t strings_start = read_u32(data + offset + 20);
    uint32_t sp_base = offset + 28;  // start of string offset table

    // Build string pool index (reuse same approach as layout parser)
    uint32_t max_strings = sp_string_count < 4096 ? sp_string_count : 4096;
    const char **string_pool = (const char **)dx_malloc(sizeof(char *) * max_strings);
    char **string_pool_alloc = (char **)dx_malloc(sizeof(char *) * max_strings);
    if (!string_pool || !string_pool_alloc) {
        dx_free(string_pool);
        dx_free(string_pool_alloc);
        return false;
    }
    memset(string_pool, 0, sizeof(char *) * max_strings);
    memset(string_pool_alloc, 0, sizeof(char *) * max_strings);

    for (uint32_t i = 0; i < max_strings; i++) {
        if (sp_base + i * 4 + 4 > offset + sp_size) break;
        uint32_t str_offset = read_u32(data + sp_base + i * 4);
        uint32_t abs_offset = offset + strings_start + str_offset;
        if (abs_offset + 2 > size) continue;

        if (is_utf8) {
            // UTF-8: skip char count (1-2 bytes), then byte length (1-2 bytes), then data
            uint32_t p = abs_offset;
            // Skip char count
            if (p >= size) continue;
            if (data[p] & 0x80) p += 2; else p += 1;
            if (p >= size) continue;
            // Read byte length
            uint32_t byte_len;
            if (data[p] & 0x80) {
                if (p + 1 >= size) continue;
                byte_len = ((data[p] & 0x7F) << 8) | data[p + 1];
                p += 2;
            } else {
                byte_len = data[p];
                p += 1;
            }
            if (p + byte_len > size) continue;
            char *s = (char *)dx_malloc(byte_len + 1);
            if (s) {
                memcpy(s, data + p, byte_len);
                s[byte_len] = '\0';
                string_pool[i] = s;
                string_pool_alloc[i] = s;
            }
        } else {
            // UTF-16LE
            if (abs_offset + 2 > size) continue;
            uint32_t char_count = read_u16(data + abs_offset);
            uint32_t p = abs_offset + 2;
            if (p + char_count * 2 > size) continue;
            // Simple ASCII extraction from UTF-16
            char *s = (char *)dx_malloc(char_count + 1);
            if (s) {
                for (uint32_t c = 0; c < char_count; c++) {
                    uint16_t ch = read_u16(data + p + c * 2);
                    s[c] = (ch < 128) ? (char)ch : '?';
                }
                s[char_count] = '\0';
                string_pool[i] = s;
                string_pool_alloc[i] = s;
            }
        }
    }

    // Parse resource ID map (skip it)
    uint32_t pos = offset + sp_size;
    uint32_t *res_ids = NULL;
    uint32_t res_id_count = 0;
    if (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        if (chunk_type == AXML_CHUNK_RESOURCEMAP) {
            uint32_t chunk_size = read_u32(data + pos + 4);
            res_id_count = (chunk_size - 8) / 4;
            if (res_id_count > 0 && pos + 8 + res_id_count * 4 <= size) {
                res_ids = (uint32_t *)dx_malloc(sizeof(uint32_t) * res_id_count);
                if (res_ids) {
                    for (uint32_t i = 0; i < res_id_count; i++) {
                        res_ids[i] = read_u32(data + pos + 8 + i * 4);
                    }
                }
            }
            pos += chunk_size;
        }
    }

    // Accumulate path data from all <path> elements
    // Use a dynamic buffer
    size_t path_buf_cap = 1024;
    size_t path_buf_len = 0;
    char *path_buf = (char *)dx_malloc(path_buf_cap);
    if (!path_buf) path_buf_cap = 0;

    // Default values
    uint32_t fill_color = 0xFF000000;   // opaque black
    uint32_t stroke_color = 0;
    float stroke_width = 0.0f;
    float vp_width = 24.0f;
    float vp_height = 24.0f;
    bool found_vector = false;
    bool found_path = false;

    // Well-known vector drawable attribute resource IDs
    #define VD_ATTR_VIEWPORT_WIDTH   0x01010489
    #define VD_ATTR_VIEWPORT_HEIGHT  0x0101048a
    #define VD_ATTR_PATH_DATA        0x01010405
    #define VD_ATTR_FILL_COLOR       0x0101031f
    #define VD_ATTR_STROKE_COLOR     0x01010321
    #define VD_ATTR_STROKE_WIDTH     0x01010322

    // Walk the AXML chunks looking for START_TAG events
    while (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        uint32_t chunk_size = read_u32(data + pos + 4);
        if (chunk_size < 8 || pos + chunk_size > size) break;

        if (chunk_type == AXML_CHUNK_START_TAG && chunk_size >= 36) {
            // Parse start tag
            uint32_t name_idx = read_u32(data + pos + 20);
            uint32_t attr_count = read_u16(data + pos + 28);
            uint32_t attr_start = pos + 36;

            const char *tag_name = NULL;
            if (name_idx < max_strings) tag_name = string_pool[name_idx];

            bool is_vector = (tag_name && strcmp(tag_name, "vector") == 0);
            bool is_path = (tag_name && strcmp(tag_name, "path") == 0);

            // Process attributes
            for (uint32_t a = 0; a < attr_count; a++) {
                uint32_t aoff = attr_start + a * 20;
                if (aoff + 20 > size) break;

                uint32_t attr_name_idx = read_u32(data + aoff + 4);
                uint8_t  attr_type = data[aoff + 11];
                uint32_t attr_data = read_u32(data + aoff + 16);

                // Determine attribute resource ID
                uint32_t attr_res_id = 0;
                if (attr_name_idx < res_id_count && res_ids) {
                    attr_res_id = res_ids[attr_name_idx];
                }

                const char *attr_name = NULL;
                if (attr_name_idx < max_strings) attr_name = string_pool[attr_name_idx];

                if (is_vector) {
                    found_vector = true;
                    if (attr_res_id == VD_ATTR_VIEWPORT_WIDTH ||
                        (attr_name && strcmp(attr_name, "viewportWidth") == 0)) {
                        // Float type (0x04)
                        if (attr_type == 0x04) {
                            float f;
                            memcpy(&f, &attr_data, sizeof(float));
                            vp_width = f;
                        } else {
                            vp_width = (float)attr_data;
                        }
                    }
                    else if (attr_res_id == VD_ATTR_VIEWPORT_HEIGHT ||
                             (attr_name && strcmp(attr_name, "viewportHeight") == 0)) {
                        if (attr_type == 0x04) {
                            float f;
                            memcpy(&f, &attr_data, sizeof(float));
                            vp_height = f;
                        } else {
                            vp_height = (float)attr_data;
                        }
                    }
                }
                else if (is_path) {
                    found_path = true;
                    if (attr_res_id == VD_ATTR_FILL_COLOR ||
                        (attr_name && strcmp(attr_name, "fillColor") == 0)) {
                        fill_color = attr_data;
                    }
                    else if (attr_res_id == VD_ATTR_STROKE_COLOR ||
                             (attr_name && strcmp(attr_name, "strokeColor") == 0)) {
                        stroke_color = attr_data;
                    }
                    else if (attr_res_id == VD_ATTR_STROKE_WIDTH ||
                             (attr_name && strcmp(attr_name, "strokeWidth") == 0)) {
                        if (attr_type == 0x04) {
                            memcpy(&stroke_width, &attr_data, sizeof(float));
                        } else {
                            stroke_width = (float)attr_data;
                        }
                    }
                    else if (attr_res_id == VD_ATTR_PATH_DATA ||
                             (attr_name && strcmp(attr_name, "pathData") == 0)) {
                        // pathData is a string reference (type 0x03)
                        const char *pd = NULL;
                        if (attr_type == 0x03 && attr_data < max_strings) {
                            pd = string_pool[attr_data];
                        }
                        // Also try raw_value (offset+12 in attribute)
                        if (!pd) {
                            uint32_t raw_val = read_u32(data + aoff + 8);
                            if (raw_val < max_strings) {
                                pd = string_pool[raw_val];
                            }
                        }
                        if (pd && path_buf) {
                            size_t pd_len = strlen(pd);
                            // If we already have data, add a space separator
                            if (path_buf_len > 0) {
                                if (path_buf_len + 1 >= path_buf_cap) {
                                    path_buf_cap *= 2;
                                    char *nb = (char *)dx_realloc(path_buf, path_buf_cap);
                                    if (!nb) { dx_free(path_buf); path_buf = NULL; path_buf_cap = 0; break; }
                                    path_buf = nb;
                                }
                                path_buf[path_buf_len++] = ' ';
                            }
                            while (path_buf_len + pd_len + 1 > path_buf_cap) {
                                path_buf_cap *= 2;
                                char *nb = (char *)dx_realloc(path_buf, path_buf_cap);
                                if (!nb) { dx_free(path_buf); path_buf = NULL; path_buf_cap = 0; break; }
                                path_buf = nb;
                            }
                            if (path_buf) {
                                memcpy(path_buf + path_buf_len, pd, pd_len);
                                path_buf_len += pd_len;
                                path_buf[path_buf_len] = '\0';
                            }
                        }
                    }
                }
            }
        }

        pos += chunk_size;
    }

    // Cleanup
    for (uint32_t i = 0; i < max_strings; i++) {
        dx_free(string_pool_alloc[i]);
    }
    dx_free(string_pool);
    dx_free(string_pool_alloc);
    dx_free(res_ids);

    if (found_vector && found_path && path_buf && path_buf_len > 0) {
        *out_path_data = path_buf;
        *out_fill_color = fill_color;
        *out_stroke_color = stroke_color;
        *out_stroke_width = stroke_width;
        *out_vp_width = vp_width;
        *out_vp_height = vp_height;
        DX_INFO(TAG, "Parsed vector drawable: viewport=%.0fx%.0f, fill=0x%08x, pathLen=%zu",
                vp_width, vp_height, fill_color, path_buf_len);
        return true;
    }

    dx_free(path_buf);
    return false;
}

// Well-known attribute resource IDs for shape/selector/layer-list drawables
#define SHAPE_ATTR_SHAPE       0x01010000  // android:shape
#define SHAPE_ATTR_COLOR       0x010101a5  // android:color (for <solid>)
#define SHAPE_ATTR_RADIUS      0x01010101  // android:radius (for <corners>)
#define SHAPE_ATTR_WIDTH       0x01010159  // android:width (for <stroke>/<size>)
#define SHAPE_ATTR_STROKE_CLR  0x010101a5  // android:color (for <stroke>)
#define SHAPE_ATTR_START_COLOR 0x0101019d  // android:startColor
#define SHAPE_ATTR_END_COLOR   0x0101019e  // android:endColor
#define SHAPE_ATTR_GRADIENT_TYPE 0x010101a0 // android:type (gradient)
#define SELECTOR_ATTR_DRAWABLE 0x01010199  // android:drawable
#define SELECTOR_ATTR_STATE_PRESSED  0x010100a7
#define SELECTOR_ATTR_STATE_FOCUSED  0x0101009c
#define SELECTOR_ATTR_STATE_ENABLED  0x0101009e
#define SELECTOR_ATTR_STATE_SELECTED 0x010100a1
#define SELECTOR_ATTR_STATE_CHECKED  0x010100a0

// Parse a compiled shape drawable AXML.
// Populates out_shape with the shape properties.
// Returns true if successfully parsed as a shape drawable.
static bool dx_ui_parse_shape_drawable(const uint8_t *data, uint32_t size,
                                        DxShapeDrawable *out_shape) {
    if (!data || size < 12 || !out_shape) return false;

    uint32_t magic = read_u32(data);
    if (magic != AXML_FILE_MAGIC) return false;

    // Parse string pool (same as vector drawable parser)
    uint32_t offset = 8;
    if (offset + 8 > size) return false;

    uint16_t sp_type = read_u16(data + offset);
    if (sp_type != AXML_CHUNK_STRINGPOOL) return false;

    uint32_t sp_size = read_u32(data + offset + 4);
    uint32_t sp_string_count = read_u32(data + offset + 8);
    if (sp_string_count > AXML_MAX_STRING_POOL || sp_string_count == 0) return false;

    uint32_t sp_flags = read_u32(data + offset + 16);
    bool is_utf8 = (sp_flags & (1u << 8)) != 0;
    uint32_t strings_start = read_u32(data + offset + 20);
    uint32_t sp_base = offset + 28;

    uint32_t max_strings = sp_string_count < 4096 ? sp_string_count : 4096;
    const char **string_pool = (const char **)dx_malloc(sizeof(char *) * max_strings);
    char **string_pool_alloc = (char **)dx_malloc(sizeof(char *) * max_strings);
    if (!string_pool || !string_pool_alloc) {
        dx_free(string_pool); dx_free(string_pool_alloc);
        return false;
    }
    memset(string_pool, 0, sizeof(char *) * max_strings);
    memset(string_pool_alloc, 0, sizeof(char *) * max_strings);

    for (uint32_t i = 0; i < max_strings; i++) {
        if (sp_base + i * 4 + 4 > offset + sp_size) break;
        uint32_t str_offset = read_u32(data + sp_base + i * 4);
        uint32_t abs_offset_s = offset + strings_start + str_offset;
        if (abs_offset_s + 2 > size) continue;

        if (is_utf8) {
            uint32_t p = abs_offset_s;
            if (p >= size) continue;
            if (data[p] & 0x80) p += 2; else p += 1;
            if (p >= size) continue;
            uint32_t byte_len;
            if (data[p] & 0x80) {
                if (p + 1 >= size) continue;
                byte_len = ((data[p] & 0x7F) << 8) | data[p + 1];
                p += 2;
            } else {
                byte_len = data[p]; p += 1;
            }
            if (p + byte_len > size) continue;
            char *s = (char *)dx_malloc(byte_len + 1);
            if (s) {
                memcpy(s, data + p, byte_len);
                s[byte_len] = '\0';
                string_pool[i] = s; string_pool_alloc[i] = s;
            }
        } else {
            uint32_t char_count = read_u16(data + abs_offset_s);
            uint32_t p = abs_offset_s + 2;
            if (p + char_count * 2 > size) continue;
            char *s = (char *)dx_malloc(char_count + 1);
            if (s) {
                for (uint32_t c = 0; c < char_count; c++) {
                    uint16_t ch = read_u16(data + p + c * 2);
                    s[c] = (ch < 128) ? (char)ch : '?';
                }
                s[char_count] = '\0';
                string_pool[i] = s; string_pool_alloc[i] = s;
            }
        }
    }

    // Parse resource ID map
    uint32_t pos = offset + sp_size;
    uint32_t *res_ids = NULL;
    uint32_t res_id_count = 0;
    if (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        if (chunk_type == AXML_CHUNK_RESOURCEMAP) {
            uint32_t chunk_size = read_u32(data + pos + 4);
            res_id_count = (chunk_size - 8) / 4;
            if (res_id_count > 0 && pos + 8 + res_id_count * 4 <= size) {
                res_ids = (uint32_t *)dx_malloc(sizeof(uint32_t) * res_id_count);
                if (res_ids) {
                    for (uint32_t i = 0; i < res_id_count; i++) {
                        res_ids[i] = read_u32(data + pos + 8 + i * 4);
                    }
                }
            }
            pos += chunk_size;
        }
    }

    // Initialize shape
    memset(out_shape, 0, sizeof(DxShapeDrawable));
    bool found_shape = false;

    // Walk AXML chunks
    while (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        uint32_t chunk_size = read_u32(data + pos + 4);
        if (chunk_size < 8 || pos + chunk_size > size) break;

        if (chunk_type == AXML_CHUNK_START_TAG && chunk_size >= 36) {
            uint32_t name_idx = read_u32(data + pos + 20);
            uint32_t attr_count = read_u16(data + pos + 28);
            uint32_t attr_start = pos + 36;

            const char *tag_name = NULL;
            if (name_idx < max_strings) tag_name = string_pool[name_idx];

            if (tag_name && strcmp(tag_name, "shape") == 0) {
                found_shape = true;
                out_shape->has_shape = true;
                // Parse shape type attribute
                for (uint32_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t attr_name_idx = read_u32(data + aoff + 4);
                    uint32_t attr_data_v = read_u32(data + aoff + 16);
                    uint32_t attr_res = 0;
                    if (attr_name_idx < res_id_count && res_ids) attr_res = res_ids[attr_name_idx];
                    const char *aname = (attr_name_idx < max_strings) ? string_pool[attr_name_idx] : NULL;
                    if (attr_res == SHAPE_ATTR_SHAPE || (aname && strcmp(aname, "shape") == 0)) {
                        out_shape->shape_type = (uint8_t)attr_data_v;
                    }
                }
            }
            else if (tag_name && strcmp(tag_name, "solid") == 0 && found_shape) {
                for (uint32_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t attr_name_idx = read_u32(data + aoff + 4);
                    uint8_t attr_type = data[aoff + 11];
                    uint32_t attr_data_v = read_u32(data + aoff + 16);
                    const char *aname = (attr_name_idx < max_strings) ? string_pool[attr_name_idx] : NULL;
                    if (aname && strcmp(aname, "color") == 0) {
                        if (attr_type == 0x1C || attr_type == 0x1D) {
                            out_shape->solid_color = attr_data_v;
                        }
                    }
                }
            }
            else if (tag_name && strcmp(tag_name, "corners") == 0 && found_shape) {
                for (uint32_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t attr_name_idx = read_u32(data + aoff + 4);
                    uint8_t attr_type = data[aoff + 11];
                    uint32_t attr_data_v = read_u32(data + aoff + 16);
                    const char *aname = (attr_name_idx < max_strings) ? string_pool[attr_name_idx] : NULL;
                    if (aname && strcmp(aname, "radius") == 0) {
                        if (attr_type == 0x05) {
                            out_shape->corner_radius = dx_ui_decode_dimension(attr_data_v);
                        } else if (attr_type == 0x04) {
                            float f; memcpy(&f, &attr_data_v, sizeof(float));
                            out_shape->corner_radius = f;
                        } else {
                            out_shape->corner_radius = (float)attr_data_v;
                        }
                    }
                }
            }
            else if (tag_name && strcmp(tag_name, "stroke") == 0 && found_shape) {
                for (uint32_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t attr_name_idx = read_u32(data + aoff + 4);
                    uint8_t attr_type = data[aoff + 11];
                    uint32_t attr_data_v = read_u32(data + aoff + 16);
                    const char *aname = (attr_name_idx < max_strings) ? string_pool[attr_name_idx] : NULL;
                    if (aname && strcmp(aname, "width") == 0) {
                        if (attr_type == 0x05) {
                            out_shape->stroke_width = dx_ui_decode_dimension(attr_data_v);
                        } else if (attr_type == 0x04) {
                            float f; memcpy(&f, &attr_data_v, sizeof(float));
                            out_shape->stroke_width = f;
                        } else {
                            out_shape->stroke_width = (float)attr_data_v;
                        }
                    }
                    else if (aname && strcmp(aname, "color") == 0) {
                        if (attr_type == 0x1C || attr_type == 0x1D) {
                            out_shape->stroke_color = attr_data_v;
                        }
                    }
                }
            }
            else if (tag_name && strcmp(tag_name, "gradient") == 0 && found_shape) {
                for (uint32_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t attr_name_idx = read_u32(data + aoff + 4);
                    uint8_t attr_type = data[aoff + 11];
                    uint32_t attr_data_v = read_u32(data + aoff + 16);
                    uint32_t attr_res = 0;
                    if (attr_name_idx < res_id_count && res_ids) attr_res = res_ids[attr_name_idx];
                    const char *aname = (attr_name_idx < max_strings) ? string_pool[attr_name_idx] : NULL;
                    if (aname && strcmp(aname, "startColor") == 0) {
                        if (attr_type == 0x1C || attr_type == 0x1D) {
                            out_shape->gradient_start = attr_data_v;
                        }
                    }
                    else if (aname && strcmp(aname, "endColor") == 0) {
                        if (attr_type == 0x1C || attr_type == 0x1D) {
                            out_shape->gradient_end = attr_data_v;
                        }
                    }
                    else if (aname && strcmp(aname, "type") == 0) {
                        out_shape->gradient_type = (uint8_t)attr_data_v;
                    }
                }
            }
        }
        pos += chunk_size;
    }

    // Cleanup
    for (uint32_t i = 0; i < max_strings; i++) dx_free(string_pool_alloc[i]);
    dx_free(string_pool);
    dx_free(string_pool_alloc);
    dx_free(res_ids);

    if (found_shape) {
        DX_INFO(TAG, "Parsed shape drawable: type=%d, solid=0x%08x, radius=%.1f, stroke=%.1f/0x%08x",
                out_shape->shape_type, out_shape->solid_color, out_shape->corner_radius,
                out_shape->stroke_width, out_shape->stroke_color);
    }
    return found_shape;
}

// Parse a compiled selector (StateListDrawable) AXML.
// Returns the default drawable resource ID (the <item> without state attributes).
// Returns 0 if no default item found.
static uint32_t dx_ui_parse_selector_drawable(const uint8_t *data, uint32_t size) {
    if (!data || size < 12) return 0;

    uint32_t magic = read_u32(data);
    if (magic != AXML_FILE_MAGIC) return 0;

    uint32_t offset = 8;
    if (offset + 8 > size) return 0;

    uint16_t sp_type = read_u16(data + offset);
    if (sp_type != AXML_CHUNK_STRINGPOOL) return 0;

    uint32_t sp_size = read_u32(data + offset + 4);
    uint32_t sp_string_count = read_u32(data + offset + 8);
    if (sp_string_count > AXML_MAX_STRING_POOL || sp_string_count == 0) return 0;

    uint32_t sp_flags = read_u32(data + offset + 16);
    bool is_utf8 = (sp_flags & (1u << 8)) != 0;
    uint32_t strings_start = read_u32(data + offset + 20);
    uint32_t sp_base = offset + 28;

    uint32_t max_strings = sp_string_count < 4096 ? sp_string_count : 4096;
    const char **string_pool = (const char **)dx_malloc(sizeof(char *) * max_strings);
    char **string_pool_alloc = (char **)dx_malloc(sizeof(char *) * max_strings);
    if (!string_pool || !string_pool_alloc) {
        dx_free(string_pool); dx_free(string_pool_alloc);
        return 0;
    }
    memset(string_pool, 0, sizeof(char *) * max_strings);
    memset(string_pool_alloc, 0, sizeof(char *) * max_strings);

    for (uint32_t i = 0; i < max_strings; i++) {
        if (sp_base + i * 4 + 4 > offset + sp_size) break;
        uint32_t str_offset = read_u32(data + sp_base + i * 4);
        uint32_t abs_offset_s = offset + strings_start + str_offset;
        if (abs_offset_s + 2 > size) continue;

        if (is_utf8) {
            uint32_t p = abs_offset_s;
            if (p >= size) continue;
            if (data[p] & 0x80) p += 2; else p += 1;
            if (p >= size) continue;
            uint32_t byte_len;
            if (data[p] & 0x80) {
                if (p + 1 >= size) continue;
                byte_len = ((data[p] & 0x7F) << 8) | data[p + 1];
                p += 2;
            } else {
                byte_len = data[p]; p += 1;
            }
            if (p + byte_len > size) continue;
            char *s = (char *)dx_malloc(byte_len + 1);
            if (s) {
                memcpy(s, data + p, byte_len);
                s[byte_len] = '\0';
                string_pool[i] = s; string_pool_alloc[i] = s;
            }
        } else {
            uint32_t char_count = read_u16(data + abs_offset_s);
            uint32_t p = abs_offset_s + 2;
            if (p + char_count * 2 > size) continue;
            char *s = (char *)dx_malloc(char_count + 1);
            if (s) {
                for (uint32_t c = 0; c < char_count; c++) {
                    uint16_t ch = read_u16(data + p + c * 2);
                    s[c] = (ch < 128) ? (char)ch : '?';
                }
                s[char_count] = '\0';
                string_pool[i] = s; string_pool_alloc[i] = s;
            }
        }
    }

    // Parse resource ID map
    uint32_t pos = offset + sp_size;
    uint32_t *res_ids = NULL;
    uint32_t res_id_count = 0;
    if (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        if (chunk_type == AXML_CHUNK_RESOURCEMAP) {
            uint32_t chunk_size = read_u32(data + pos + 4);
            res_id_count = (chunk_size - 8) / 4;
            if (res_id_count > 0 && pos + 8 + res_id_count * 4 <= size) {
                res_ids = (uint32_t *)dx_malloc(sizeof(uint32_t) * res_id_count);
                if (res_ids) {
                    for (uint32_t i = 0; i < res_id_count; i++) {
                        res_ids[i] = read_u32(data + pos + 8 + i * 4);
                    }
                }
            }
            pos += chunk_size;
        }
    }

    bool found_selector = false;
    uint32_t default_drawable_id = 0;
    uint32_t last_drawable_id = 0;  // fallback: use last item's drawable

    while (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        uint32_t chunk_size = read_u32(data + pos + 4);
        if (chunk_size < 8 || pos + chunk_size > size) break;

        if (chunk_type == AXML_CHUNK_START_TAG && chunk_size >= 36) {
            uint32_t name_idx = read_u32(data + pos + 20);
            uint32_t attr_count = read_u16(data + pos + 28);
            uint32_t attr_start = pos + 36;

            const char *tag_name = NULL;
            if (name_idx < max_strings) tag_name = string_pool[name_idx];

            if (tag_name && strcmp(tag_name, "selector") == 0) {
                found_selector = true;
            }
            else if (tag_name && strcmp(tag_name, "item") == 0 && found_selector) {
                // Check if this item has state attributes
                bool has_state = false;
                uint32_t drawable_id = 0;

                for (uint32_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t attr_name_idx = read_u32(data + aoff + 4);
                    uint8_t attr_type = data[aoff + 11];
                    uint32_t attr_data_v = read_u32(data + aoff + 16);
                    uint32_t attr_res = 0;
                    if (attr_name_idx < res_id_count && res_ids) attr_res = res_ids[attr_name_idx];
                    const char *aname = (attr_name_idx < max_strings) ? string_pool[attr_name_idx] : NULL;

                    // Check for state attributes
                    if (attr_res == SELECTOR_ATTR_STATE_PRESSED ||
                        attr_res == SELECTOR_ATTR_STATE_FOCUSED ||
                        attr_res == SELECTOR_ATTR_STATE_ENABLED ||
                        attr_res == SELECTOR_ATTR_STATE_SELECTED ||
                        attr_res == SELECTOR_ATTR_STATE_CHECKED ||
                        (aname && strncmp(aname, "state_", 6) == 0)) {
                        has_state = true;
                    }

                    // Extract drawable reference
                    if (attr_res == SELECTOR_ATTR_DRAWABLE ||
                        (aname && strcmp(aname, "drawable") == 0)) {
                        if (attr_type == 0x01) {  // resource reference
                            drawable_id = attr_data_v;
                        }
                    }

                    // Also check android:color for color state lists
                    if ((aname && strcmp(aname, "color") == 0)) {
                        if (attr_type == 0x1C || attr_type == 0x1D) {
                            // This is a color selector, not a drawable selector
                            // Store color as pseudo-resource
                        }
                    }
                }

                if (drawable_id != 0) {
                    last_drawable_id = drawable_id;
                    if (!has_state) {
                        // This is the default item (no state conditions)
                        default_drawable_id = drawable_id;
                    }
                }
            }
        }
        pos += chunk_size;
    }

    // Cleanup
    for (uint32_t i = 0; i < max_strings; i++) dx_free(string_pool_alloc[i]);
    dx_free(string_pool);
    dx_free(string_pool_alloc);
    dx_free(res_ids);

    // Use default item, or fall back to last item
    uint32_t result = default_drawable_id ? default_drawable_id : last_drawable_id;
    if (found_selector && result) {
        DX_INFO(TAG, "Parsed selector drawable: default_res=0x%08x", result);
    }
    return found_selector ? result : 0;
}

// Parse a compiled layer-list AXML.
// Returns the topmost (last) layer's drawable resource ID.
static uint32_t dx_ui_parse_layer_list_drawable(const uint8_t *data, uint32_t size) {
    if (!data || size < 12) return 0;

    uint32_t magic = read_u32(data);
    if (magic != AXML_FILE_MAGIC) return 0;

    uint32_t offset = 8;
    if (offset + 8 > size) return 0;

    uint16_t sp_type = read_u16(data + offset);
    if (sp_type != AXML_CHUNK_STRINGPOOL) return 0;

    uint32_t sp_size = read_u32(data + offset + 4);
    uint32_t sp_string_count = read_u32(data + offset + 8);
    if (sp_string_count > AXML_MAX_STRING_POOL || sp_string_count == 0) return 0;

    uint32_t sp_flags = read_u32(data + offset + 16);
    bool is_utf8 = (sp_flags & (1u << 8)) != 0;
    uint32_t strings_start = read_u32(data + offset + 20);
    uint32_t sp_base = offset + 28;

    uint32_t max_strings = sp_string_count < 4096 ? sp_string_count : 4096;
    const char **string_pool = (const char **)dx_malloc(sizeof(char *) * max_strings);
    char **string_pool_alloc = (char **)dx_malloc(sizeof(char *) * max_strings);
    if (!string_pool || !string_pool_alloc) {
        dx_free(string_pool); dx_free(string_pool_alloc);
        return 0;
    }
    memset(string_pool, 0, sizeof(char *) * max_strings);
    memset(string_pool_alloc, 0, sizeof(char *) * max_strings);

    for (uint32_t i = 0; i < max_strings; i++) {
        if (sp_base + i * 4 + 4 > offset + sp_size) break;
        uint32_t str_offset = read_u32(data + sp_base + i * 4);
        uint32_t abs_offset_s = offset + strings_start + str_offset;
        if (abs_offset_s + 2 > size) continue;

        if (is_utf8) {
            uint32_t p = abs_offset_s;
            if (p >= size) continue;
            if (data[p] & 0x80) p += 2; else p += 1;
            if (p >= size) continue;
            uint32_t byte_len;
            if (data[p] & 0x80) {
                if (p + 1 >= size) continue;
                byte_len = ((data[p] & 0x7F) << 8) | data[p + 1];
                p += 2;
            } else {
                byte_len = data[p]; p += 1;
            }
            if (p + byte_len > size) continue;
            char *s = (char *)dx_malloc(byte_len + 1);
            if (s) {
                memcpy(s, data + p, byte_len);
                s[byte_len] = '\0';
                string_pool[i] = s; string_pool_alloc[i] = s;
            }
        } else {
            uint32_t char_count = read_u16(data + abs_offset_s);
            uint32_t p = abs_offset_s + 2;
            if (p + char_count * 2 > size) continue;
            char *s = (char *)dx_malloc(char_count + 1);
            if (s) {
                for (uint32_t c = 0; c < char_count; c++) {
                    uint16_t ch = read_u16(data + p + c * 2);
                    s[c] = (ch < 128) ? (char)ch : '?';
                }
                s[char_count] = '\0';
                string_pool[i] = s; string_pool_alloc[i] = s;
            }
        }
    }

    // Parse resource ID map
    uint32_t pos = offset + sp_size;
    uint32_t *res_ids = NULL;
    uint32_t res_id_count = 0;
    if (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        if (chunk_type == AXML_CHUNK_RESOURCEMAP) {
            uint32_t chunk_size = read_u32(data + pos + 4);
            res_id_count = (chunk_size - 8) / 4;
            if (res_id_count > 0 && pos + 8 + res_id_count * 4 <= size) {
                res_ids = (uint32_t *)dx_malloc(sizeof(uint32_t) * res_id_count);
                if (res_ids) {
                    for (uint32_t i = 0; i < res_id_count; i++) {
                        res_ids[i] = read_u32(data + pos + 8 + i * 4);
                    }
                }
            }
            pos += chunk_size;
        }
    }

    bool found_layer_list = false;
    uint32_t last_drawable_id = 0;

    while (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        uint32_t chunk_size = read_u32(data + pos + 4);
        if (chunk_size < 8 || pos + chunk_size > size) break;

        if (chunk_type == AXML_CHUNK_START_TAG && chunk_size >= 36) {
            uint32_t name_idx = read_u32(data + pos + 20);
            uint32_t attr_count = read_u16(data + pos + 28);
            uint32_t attr_start = pos + 36;

            const char *tag_name = NULL;
            if (name_idx < max_strings) tag_name = string_pool[name_idx];

            if (tag_name && strcmp(tag_name, "layer-list") == 0) {
                found_layer_list = true;
            }
            else if (tag_name && strcmp(tag_name, "item") == 0 && found_layer_list) {
                for (uint32_t a = 0; a < attr_count; a++) {
                    uint32_t aoff = attr_start + a * 20;
                    if (aoff + 20 > size) break;
                    uint32_t attr_name_idx = read_u32(data + aoff + 4);
                    uint8_t attr_type = data[aoff + 11];
                    uint32_t attr_data_v = read_u32(data + aoff + 16);
                    const char *aname = (attr_name_idx < max_strings) ? string_pool[attr_name_idx] : NULL;

                    if ((aname && strcmp(aname, "drawable") == 0) ||
                        (attr_name_idx < res_id_count && res_ids && res_ids[attr_name_idx] == SELECTOR_ATTR_DRAWABLE)) {
                        if (attr_type == 0x01) {
                            last_drawable_id = attr_data_v;
                        }
                    }
                }
            }
        }
        pos += chunk_size;
    }

    // Cleanup
    for (uint32_t i = 0; i < max_strings; i++) dx_free(string_pool_alloc[i]);
    dx_free(string_pool);
    dx_free(string_pool_alloc);
    dx_free(res_ids);

    if (found_layer_list && last_drawable_id) {
        DX_INFO(TAG, "Parsed layer-list drawable: top_res=0x%08x", last_drawable_id);
    }
    return found_layer_list ? last_drawable_id : 0;
}

// Detect the root tag of an AXML binary XML file.
// Returns: "vector", "shape", "selector", "layer-list", or NULL for unknown.
static const char *dx_ui_detect_axml_root_tag(const uint8_t *data, uint32_t size) {
    if (!data || size < 12) return NULL;

    uint32_t magic = read_u32(data);
    if (magic != AXML_FILE_MAGIC) return NULL;

    uint32_t offset = 8;
    if (offset + 8 > size) return NULL;

    uint16_t sp_type = read_u16(data + offset);
    if (sp_type != AXML_CHUNK_STRINGPOOL) return NULL;

    uint32_t sp_size = read_u32(data + offset + 4);
    uint32_t sp_string_count = read_u32(data + offset + 8);
    if (sp_string_count > AXML_MAX_STRING_POOL || sp_string_count == 0) return NULL;

    uint32_t sp_flags = read_u32(data + offset + 16);
    bool is_utf8 = (sp_flags & (1u << 8)) != 0;
    uint32_t strings_start = read_u32(data + offset + 20);
    uint32_t sp_base = offset + 28;

    // We only need to decode the first few strings to find the root tag
    uint32_t max_strings = sp_string_count < 64 ? sp_string_count : 64;
    char *temp_strings[64];
    memset(temp_strings, 0, sizeof(temp_strings));

    for (uint32_t i = 0; i < max_strings; i++) {
        if (sp_base + i * 4 + 4 > offset + sp_size) break;
        uint32_t str_offset = read_u32(data + sp_base + i * 4);
        uint32_t abs_off = offset + strings_start + str_offset;
        if (abs_off + 2 > size) continue;

        if (is_utf8) {
            uint32_t p = abs_off;
            if (p >= size) continue;
            if (data[p] & 0x80) p += 2; else p += 1;
            if (p >= size) continue;
            uint32_t byte_len;
            if (data[p] & 0x80) {
                if (p + 1 >= size) continue;
                byte_len = ((data[p] & 0x7F) << 8) | data[p + 1]; p += 2;
            } else {
                byte_len = data[p]; p += 1;
            }
            if (p + byte_len > size) continue;
            char *s = (char *)dx_malloc(byte_len + 1);
            if (s) { memcpy(s, data + p, byte_len); s[byte_len] = '\0'; temp_strings[i] = s; }
        } else {
            uint32_t char_count = read_u16(data + abs_off);
            uint32_t p = abs_off + 2;
            if (p + char_count * 2 > size) continue;
            char *s = (char *)dx_malloc(char_count + 1);
            if (s) {
                for (uint32_t c = 0; c < char_count; c++) {
                    uint16_t ch = read_u16(data + p + c * 2);
                    s[c] = (ch < 128) ? (char)ch : '?';
                }
                s[char_count] = '\0'; temp_strings[i] = s;
            }
        }
    }

    // Skip past string pool and resource ID map to find first START_TAG
    uint32_t pos = offset + sp_size;
    if (pos + 8 <= size && read_u16(data + pos) == AXML_CHUNK_RESOURCEMAP) {
        uint32_t chunk_size = read_u32(data + pos + 4);
        pos += chunk_size;
    }

    // Find the first START_TAG chunk to determine root element
    const char *result = NULL;
    while (pos + 8 <= size) {
        uint16_t chunk_type = read_u16(data + pos);
        uint32_t chunk_size = read_u32(data + pos + 4);
        if (chunk_size < 8 || pos + chunk_size > size) break;

        if (chunk_type == AXML_CHUNK_START_TAG && chunk_size >= 36) {
            uint32_t name_idx = read_u32(data + pos + 20);
            if (name_idx < max_strings && temp_strings[name_idx]) {
                const char *tag = temp_strings[name_idx];
                if (strcmp(tag, "vector") == 0 ||
                    strcmp(tag, "shape") == 0 ||
                    strcmp(tag, "selector") == 0 ||
                    strcmp(tag, "layer-list") == 0) {
                    result = tag;
                }
            }
            break;  // only need first tag
        }
        pos += chunk_size;
    }

    // Copy result before freeing
    static char root_tag_buf[32];
    if (result) {
        size_t len = strlen(result);
        if (len >= sizeof(root_tag_buf)) len = sizeof(root_tag_buf) - 1;
        memcpy(root_tag_buf, result, len);
        root_tag_buf[len] = '\0';
    }

    for (uint32_t i = 0; i < max_strings; i++) dx_free(temp_strings[i]);

    return result ? root_tag_buf : NULL;
}

// ============================================================
// 9-patch PNG support
// ============================================================

// Check if PNG data contains an npTc chunk (compiled 9-patch).
// PNG chunks are: 4-byte length (big-endian), 4-byte type, data, 4-byte CRC.
static bool dx_is_nine_patch_png(const uint8_t *data, size_t size) {
    if (!data || size < 16) return false;
    // Skip PNG signature (8 bytes)
    for (size_t i = 8; i + 8 < size; ) {
        uint32_t chunk_len = ((uint32_t)data[i] << 24) | ((uint32_t)data[i+1] << 16) |
                             ((uint32_t)data[i+2] << 8) | (uint32_t)data[i+3];
        if (memcmp(data + i + 4, "npTc", 4) == 0) return true;
        // Advance past length(4) + type(4) + data(chunk_len) + crc(4)
        size_t next = i + 12 + chunk_len;
        if (next <= i) break;  // overflow guard
        i = next;
    }
    return false;
}

// Parse the npTc chunk from compiled 9-patch PNG data.
// Populates the node's nine_patch fields.  Returns true on success.
//
// npTc layout (Res_png_9patch, little-endian after deserialization):
//   offset 0: was_deserialized (1 byte)
//   offset 1: numXDivs (1 byte)
//   offset 2: numYDivs (1 byte)
//   offset 3: numColors (1 byte)
//   offset 4-7: padding (unused alignment)
//   offset 8-11: paddingLeft   (int32_t LE)
//   offset 12-15: paddingRight  (int32_t LE)
//   offset 16-19: paddingTop    (int32_t LE)
//   offset 20-23: paddingBottom (int32_t LE)
//   offset 24-27: padding (unused alignment)
//   offset 28+: xDivs[numXDivs] as int32_t LE, then yDivs[numYDivs]
//
static bool dx_parse_nine_patch(const uint8_t *png_data, size_t png_size, DxUINode *node) {
    if (!png_data || !node || png_size < 16) return false;

    // Locate the npTc chunk
    const uint8_t *chunk_data = NULL;
    uint32_t chunk_len = 0;
    for (size_t i = 8; i + 8 < png_size; ) {
        uint32_t clen = ((uint32_t)png_data[i] << 24) | ((uint32_t)png_data[i+1] << 16) |
                        ((uint32_t)png_data[i+2] << 8) | (uint32_t)png_data[i+3];
        if (memcmp(png_data + i + 4, "npTc", 4) == 0) {
            chunk_data = png_data + i + 8;
            chunk_len = clen;
            break;
        }
        size_t next = i + 12 + clen;
        if (next <= i) break;
        i = next;
    }
    if (!chunk_data || chunk_len < 32) return false;

    uint8_t num_x_divs = chunk_data[1];
    uint8_t num_y_divs = chunk_data[2];

    // Read padding (little-endian int32s at offsets 8,12,16,20)
    #define LE32(p, off) ((int32_t)((uint32_t)(p)[(off)] | ((uint32_t)(p)[(off)+1] << 8) | \
                          ((uint32_t)(p)[(off)+2] << 16) | ((uint32_t)(p)[(off)+3] << 24)))

    node->nine_patch_padding[0] = LE32(chunk_data, 8);   // left
    node->nine_patch_padding[1] = LE32(chunk_data, 16);  // top
    node->nine_patch_padding[2] = LE32(chunk_data, 12);  // right
    node->nine_patch_padding[3] = LE32(chunk_data, 20);  // bottom

    // xDivs start at offset 32 (after the 32-byte header)
    size_t divs_offset = 32;
    size_t needed = divs_offset + (num_x_divs + num_y_divs) * 4;
    if (chunk_len < needed) return false;

    // Read first pair of x divs (horizontal stretch region)
    if (num_x_divs >= 2) {
        node->nine_patch_stretch_x[0] = LE32(chunk_data, divs_offset);
        node->nine_patch_stretch_x[1] = LE32(chunk_data, divs_offset + 4);
    } else {
        node->nine_patch_stretch_x[0] = 0;
        node->nine_patch_stretch_x[1] = 0;
    }

    // Read first pair of y divs (vertical stretch region)
    size_t y_offset = divs_offset + num_x_divs * 4;
    if (num_y_divs >= 2) {
        node->nine_patch_stretch_y[0] = LE32(chunk_data, y_offset);
        node->nine_patch_stretch_y[1] = LE32(chunk_data, y_offset + 4);
    } else {
        node->nine_patch_stretch_y[0] = 0;
        node->nine_patch_stretch_y[1] = 0;
    }

    #undef LE32

    node->is_nine_patch = true;
    DX_INFO(TAG, "9-patch: pad=[%d,%d,%d,%d] stretchX=[%d,%d] stretchY=[%d,%d]",
            node->nine_patch_padding[0], node->nine_patch_padding[1],
            node->nine_patch_padding[2], node->nine_patch_padding[3],
            node->nine_patch_stretch_x[0], node->nine_patch_stretch_x[1],
            node->nine_patch_stretch_y[0], node->nine_patch_stretch_y[1]);
    return true;
}

// Try to extract a drawable resource from the APK for a given resource ID.
// First attempts to extract as a vector drawable (AXML). If not, tries as raster image.
// For vector drawables, populates the node's vector fields directly and returns NULL.
// For raster images, returns allocated image bytes (caller owns).
// The node parameter is used to store vector drawable data when found.
static uint8_t *dx_ui_extract_drawable_ex(DxContext *ctx, uint32_t res_id, uint32_t *out_len,
                                           DxUINode *node) {
    if (!ctx || !ctx->resources || !ctx->apk || !out_len) return NULL;

    if (!ctx || !ctx->resources || !ctx->apk || !out_len) return NULL;

    // Look up the resource entry to get the drawable file path
    const DxResourceEntry *entry = dx_resources_find_by_id(ctx->resources, res_id);
    if (!entry) return NULL;

    const char *path = NULL;
    if (entry->value_type == DX_RES_TYPE_STRING && entry->str_val) {
        path = entry->str_val;
    }
    if (!path) return NULL;

    // Check file extension
    size_t plen = strlen(path);
    bool is_image = false;
    bool is_xml = false;
    if (plen > 4) {
        const char *ext = path + plen - 4;
        if (strcmp(ext, ".png") == 0 || strcmp(ext, ".jpg") == 0 ||
            strcmp(ext, ".PNG") == 0 || strcmp(ext, ".JPG") == 0) {
            is_image = true;
        }
        if (strcmp(ext, ".xml") == 0 || strcmp(ext, ".XML") == 0) {
            is_xml = true;
        }
        if (plen > 5) {
            ext = path + plen - 5;
            if (strcmp(ext, ".jpeg") == 0 || strcmp(ext, ".JPEG") == 0 ||
                strcmp(ext, ".webp") == 0) {
                is_image = true;
            }
        }
    }

    // Find and extract the entry from the APK
    const DxZipEntry *zip_entry = NULL;
    if (dx_apk_find_entry(ctx->apk, path, &zip_entry) != DX_OK) {
        return NULL;
    }

    uint8_t *data = NULL;
    uint32_t data_size = 0;
    if (dx_apk_extract_entry(ctx->apk, zip_entry, &data, &data_size) != DX_OK) {
        return NULL;
    }

    // Check if the extracted data starts with AXML magic (compiled XML)
    // This handles the case where .xml extension drawable files are compiled binary XML
    if (data_size >= 8 && read_u32(data) == AXML_FILE_MAGIC) {
        // Detect root tag to dispatch to correct parser
        const char *root_tag = dx_ui_detect_axml_root_tag(data, data_size);

        if (root_tag && strcmp(root_tag, "vector") == 0) {
            // Vector drawable
            char *pd = NULL;
            uint32_t fc = 0, sc = 0;
            float sw = 0, vw = 0, vh = 0;
            if (node && dx_ui_parse_vector_drawable(data, data_size, &pd, &fc, &sc, &sw, &vw, &vh)) {
                dx_free(node->vector_path_data);
                node->vector_path_data = pd;
                node->vector_fill_color = fc;
                node->vector_stroke_color = sc;
                node->vector_stroke_width = sw;
                node->vector_width = vw;
                node->vector_height = vh;
                dx_free(data);
                return NULL;
            }
        }
        else if (root_tag && strcmp(root_tag, "shape") == 0) {
            // Shape drawable - parse and store on node
            if (node) {
                DxShapeDrawable shape;
                if (dx_ui_parse_shape_drawable(data, data_size, &shape)) {
                    node->shape_bg = shape;
                }
            }
            dx_free(data);
            return NULL;
        }
        else if (root_tag && strcmp(root_tag, "selector") == 0) {
            // Selector (StateListDrawable) - extract default drawable
            uint32_t default_res = dx_ui_parse_selector_drawable(data, data_size);
            dx_free(data);
            if (default_res != 0 && node && ctx) {
                // Recursively extract the default drawable
                return dx_ui_extract_drawable_ex(ctx, default_res, out_len, node);
            }
            return NULL;
        }
        else if (root_tag && strcmp(root_tag, "layer-list") == 0) {
            // Layer-list drawable - use topmost layer
            uint32_t top_res = dx_ui_parse_layer_list_drawable(data, data_size);
            dx_free(data);
            if (top_res != 0 && node && ctx) {
                // Recursively extract the top layer's drawable
                return dx_ui_extract_drawable_ex(ctx, top_res, out_len, node);
            }
            return NULL;
        }

        // Unknown XML drawable type
        if (!is_image) {
            dx_free(data);
            return NULL;
        }
    }

    if (!is_image && !is_xml) {
        dx_free(data);
        return NULL;
    }

    if (is_xml && !is_image) {
        // Non-AXML XML file we can't handle
        dx_free(data);
        return NULL;
    }

    // Check for compiled 9-patch PNG (npTc chunk) and parse metadata
    if (node && data_size > 16 && dx_is_nine_patch_png(data, data_size)) {
        dx_parse_nine_patch(data, data_size, node);
    }

    DX_INFO(TAG, "Extracted drawable: %s (%u bytes) for res 0x%08x", path, data_size, res_id);
    *out_len = data_size;
    return data;
}

// Legacy wrapper for backward compatibility
static uint8_t *dx_ui_extract_drawable(DxContext *ctx, uint32_t res_id, uint32_t *out_len) {
    return dx_ui_extract_drawable_ex(ctx, res_id, out_len, NULL);
}

// ============================================================
// Style / theme attribute application
// ============================================================

// Resolve a ?attr/ reference through the context's theme.
// If value_type is 0x02 (attribute reference), look up in the theme.
// Modifies value_type and value_data in-place to the resolved concrete value.
static void resolve_attr_reference(DxContext *ctx, uint8_t *value_type, uint32_t *value_data) {
    if (!ctx || !ctx->theme || *value_type != RES_VALUE_TYPE_ATTR) return;

    const DxStyleEntry *resolved = dx_theme_resolve_attr(ctx->theme, *value_data);
    if (resolved) {
        // If the resolved value is itself a reference, try one more level
        if (resolved->value_type == 0x01 && ctx->resources) {
            const DxResourceEntry *re = dx_resources_find_by_id(ctx->resources, resolved->value_data);
            if (re) {
                *value_type = re->value_type;
                *value_data = (re->value_type == 0x1C || re->value_type == 0x1D ||
                               re->value_type == 0x1E || re->value_type == 0x1F)
                              ? re->color_val
                              : (uint32_t)re->int_val;
                return;
            }
        }
        *value_type = resolved->value_type;
        *value_data = resolved->value_data;
    }
}

// Apply a single style/theme attribute to a UI node.
// Only applies if the node doesn't already have a non-default value for that attribute
// (direct attributes take precedence over style attributes).
static void apply_style_attr_to_node(DxUINode *node, DxContext *ctx,
                                      uint32_t attr_id, uint8_t val_type, uint32_t val_data,
                                      char **strings, uint32_t string_count) {
    // Resolve ?attr/ references before applying
    resolve_attr_reference(ctx, &val_type, &val_data);

    switch (attr_id) {
        case ATTR_TEXT_COLOR:
            if (node->text_color == 0) { // not already set
                if (val_type == 0x1C || val_type == 0x1D || val_type == 0x1E || val_type == 0x1F) {
                    node->text_color = val_data;
                }
            }
            break;

        case ATTR_TEXT_SIZE:
            if (node->text_size == 16.0f) { // still default
                if (val_type == 0x05) {
                    float val = dx_ui_decode_dimension(val_data);
                    if (val > 0 && val < 200) node->text_size = val;
                }
            }
            break;

        case ATTR_BACKGROUND:
            if (node->bg_color == 0) {
                if (val_type == 0x1C || val_type == 0x1D || val_type == 0x1E || val_type == 0x1F) {
                    node->bg_color = val_data;
                }
            }
            break;

        case ATTR_ORIENTATION:
            // Only apply if still default vertical
            if (node->orientation == DX_ORIENTATION_VERTICAL) {
                node->orientation = (val_data == 1) ? DX_ORIENTATION_VERTICAL :
                                                       DX_ORIENTATION_HORIZONTAL;
            }
            break;

        case ATTR_GRAVITY:
            if (node->gravity == 0) {
                node->gravity = (int32_t)val_data;
            }
            break;

        case ATTR_PADDING:
            if (node->padding[0] == 0 && node->padding[1] == 0 &&
                node->padding[2] == 0 && node->padding[3] == 0) {
                int32_t pts = (val_type == 0x05) ? dx_ui_decode_dimension_int(val_data) : (int32_t)val_data;
                node->padding[0] = node->padding[1] = node->padding[2] = node->padding[3] = pts;
            }
            break;

        case ATTR_PADDING_L:
            if (node->padding[0] == 0) {
                node->padding[0] = (val_type == 0x05) ? dx_ui_decode_dimension_int(val_data) : (int32_t)val_data;
            }
            break;
        case ATTR_PADDING_T:
            if (node->padding[1] == 0) {
                node->padding[1] = (val_type == 0x05) ? dx_ui_decode_dimension_int(val_data) : (int32_t)val_data;
            }
            break;
        case ATTR_PADDING_R:
            if (node->padding[2] == 0) {
                node->padding[2] = (val_type == 0x05) ? dx_ui_decode_dimension_int(val_data) : (int32_t)val_data;
            }
            break;
        case ATTR_PADDING_B:
            if (node->padding[3] == 0) {
                node->padding[3] = (val_type == 0x05) ? dx_ui_decode_dimension_int(val_data) : (int32_t)val_data;
            }
            break;

        case ATTR_LAYOUT_MARGIN:
            if (node->margin[0] == 0 && node->margin[1] == 0 &&
                node->margin[2] == 0 && node->margin[3] == 0) {
                int32_t pts = (val_type == 0x05) ? dx_ui_decode_dimension_int(val_data) : (int32_t)val_data;
                node->margin[0] = node->margin[1] = node->margin[2] = node->margin[3] = pts;
            }
            break;

        case ATTR_LAYOUT_WIDTH:
            // Don't override if already set to something explicit
            break;
        case ATTR_LAYOUT_HEIGHT:
            break;

        case ATTR_VISIBILITY:
            if (node->visibility == DX_VISIBLE) {
                if (val_data == 4) node->visibility = DX_INVISIBLE;
                else if (val_data == 8) node->visibility = DX_GONE;
            }
            break;

        default:
            // Ignore attributes we don't handle yet
            break;
    }
}

// Apply all attributes from a resolved style bag to a node (as defaults).
// Direct XML attributes that were already parsed take precedence.
static void apply_style_to_node(DxUINode *node, DxContext *ctx,
                                 const DxStyleBag *style,
                                 char **strings, uint32_t string_count) {
    if (!style || !node) return;
    for (uint32_t i = 0; i < style->entry_count; i++) {
        apply_style_attr_to_node(node, ctx,
                                  style->entries[i].attr_id,
                                  style->entries[i].value_type,
                                  style->entries[i].value_data,
                                  strings, string_count);
    }
}

DxResult dx_layout_parse(DxContext *ctx, const uint8_t *xml_data, uint32_t xml_size,
                           DxUINode **out) {
    if (!xml_data || !out) return DX_ERR_NULL_PTR;
    if (xml_size < 8) return DX_ERR_AXML_INVALID;

    uint32_t magic = read_u32(xml_data);
    if (magic != AXML_FILE_MAGIC) {
        DX_ERROR(TAG, "Invalid layout AXML magic");
        return DX_ERR_AXML_INVALID;
    }

    // Parse string pool
    uint32_t pos = 8;
    char **strings = NULL;
    uint32_t string_count = 0;
    uint32_t *res_ids = NULL;
    uint32_t res_id_count = 0;

    if (pos + 8 > xml_size) return DX_ERR_AXML_INVALID;

    uint16_t chunk_type = read_u16(xml_data + pos);
    uint32_t chunk_size = read_u32(xml_data + pos + 4);

    if (chunk_type == AXML_CHUNK_STRINGPOOL && pos + chunk_size <= xml_size) {
        string_count = read_u32(xml_data + pos + 8);
        if (string_count > AXML_MAX_STRING_POOL) {
            DX_WARN(TAG, "AXML string pool too large: %u strings (max %u)",
                    string_count, AXML_MAX_STRING_POOL);
            return DX_ERR_AXML_INVALID;
        }
        uint32_t flags = read_u32(xml_data + pos + 16);
        uint32_t strings_start = read_u32(xml_data + pos + 20);
        bool is_utf8 = (flags & (1 << 8)) != 0;

        strings = (char **)dx_malloc(sizeof(char *) * string_count);
        uint32_t offsets_start = pos + 28;
        uint32_t pool_data_start = pos + strings_start;

        for (uint32_t i = 0; i < string_count && strings; i++) {
            if (offsets_start + i * 4 + 4 > xml_size) break;
            uint32_t str_off = read_u32(xml_data + offsets_start + i * 4);
            const uint8_t *sp = xml_data + pool_data_start + str_off;
            if (is_utf8) {
                uint32_t char_count = *sp++;
                if (char_count > 0x7F) { char_count = ((char_count & 0x7F) << 8) | *sp++; }
                uint32_t byte_count = *sp++;
                if (byte_count > 0x7F) { byte_count = ((byte_count & 0x7F) << 8) | *sp++; }
                strings[i] = (char *)dx_malloc(byte_count + 1);
                if (strings[i]) { memcpy(strings[i], sp, byte_count); strings[i][byte_count] = 0; }
            } else {
                uint16_t cc = read_u16(sp); sp += 2;
                strings[i] = (char *)dx_malloc(cc + 1);
                if (strings[i]) {
                    for (uint32_t j = 0; j < cc; j++) {
                        uint16_t c = read_u16(sp + j * 2);
                        strings[i][j] = (c < 128) ? (char)c : '?';
                    }
                    strings[i][cc] = 0;
                }
            }
        }
        pos += chunk_size;
    }

    // Resource map
    if (pos + 8 <= xml_size && read_u16(xml_data + pos) == AXML_CHUNK_RESOURCEMAP) {
        chunk_size = read_u32(xml_data + pos + 4);
        res_id_count = (chunk_size - 8) / 4;
        res_ids = (uint32_t *)dx_malloc(sizeof(uint32_t) * res_id_count);
        for (uint32_t i = 0; i < res_id_count && res_ids; i++) {
            res_ids[i] = read_u32(xml_data + pos + 8 + i * 4);
        }
        pos += chunk_size;
    }

    // Walk XML tags to build UI tree
    DxUINode *root = NULL;
    DxUINode *stack[AXML_MAX_NESTING_DEPTH];
    int stack_depth = 0;

    while (pos + 8 <= xml_size) {
        chunk_type = read_u16(xml_data + pos);
        chunk_size = read_u32(xml_data + pos + 4);
        if (chunk_size < 8 || pos + chunk_size > xml_size) break;

        if (chunk_type == AXML_CHUNK_START_TAG) {
            if (pos + 36 > xml_size) break;
            uint32_t name_idx = read_u32(xml_data + pos + 20);
            uint16_t attr_count = read_u16(xml_data + pos + 28);

            const char *tag = (name_idx < string_count && strings) ? strings[name_idx] : "";

            DxViewType vtype = DX_VIEW_NONE;
            if (strcmp(tag, "LinearLayout") == 0) vtype = DX_VIEW_LINEAR_LAYOUT;
            else if (strcmp(tag, "TextView") == 0) vtype = DX_VIEW_TEXT_VIEW;
            else if (strcmp(tag, "Button") == 0) vtype = DX_VIEW_BUTTON;
            else if (strcmp(tag, "ImageView") == 0) vtype = DX_VIEW_IMAGE_VIEW;
            else if (strcmp(tag, "EditText") == 0) vtype = DX_VIEW_EDIT_TEXT;
            else if (strcmp(tag, "FrameLayout") == 0) vtype = DX_VIEW_FRAME_LAYOUT;
            else if (strcmp(tag, "RelativeLayout") == 0) vtype = DX_VIEW_RELATIVE_LAYOUT;
            else if (strcmp(tag, "ScrollView") == 0 ||
                     strcmp(tag, "HorizontalScrollView") == 0 ||
                     strcmp(tag, "NestedScrollView") == 0) vtype = DX_VIEW_SCROLL_VIEW;
            else if (strcmp(tag, "Switch") == 0 ||
                     strcmp(tag, "SwitchCompat") == 0) vtype = DX_VIEW_SWITCH;
            else if (strcmp(tag, "CheckBox") == 0) vtype = DX_VIEW_CHECKBOX;
            else if (strcmp(tag, "RadioButton") == 0) vtype = DX_VIEW_RADIO_BUTTON;
            else if (strcmp(tag, "ProgressBar") == 0) vtype = DX_VIEW_PROGRESS_BAR;
            else if (strcmp(tag, "Toolbar") == 0) vtype = DX_VIEW_TOOLBAR;
            else if (strcmp(tag, "Spinner") == 0) vtype = DX_VIEW_SPINNER;
            else if (strcmp(tag, "SeekBar") == 0) vtype = DX_VIEW_SEEK_BAR;
            else if (strcmp(tag, "RatingBar") == 0) vtype = DX_VIEW_RATING_BAR;
            else if (strcmp(tag, "WebView") == 0) vtype = DX_VIEW_WEB_VIEW;
            else if (strcmp(tag, "View") == 0 ||
                     strcmp(tag, "Space") == 0) vtype = DX_VIEW_VIEW;
            else if (strstr(tag, "RecyclerView") != NULL) vtype = DX_VIEW_RECYCLER_VIEW;
            else if (strstr(tag, "CardView") != NULL) vtype = DX_VIEW_CARD_VIEW;
            else if (strstr(tag, "ConstraintLayout") != NULL && strstr(tag, "Guideline") == NULL) vtype = DX_VIEW_CONSTRAINT_LAYOUT;
            else if (strstr(tag, "Guideline") != NULL) vtype = DX_VIEW_VIEW; // Guideline: invisible anchor, flagged below
            else if (strstr(tag, "FloatingActionButton") != NULL) vtype = DX_VIEW_FAB;
            else if (strstr(tag, "TabLayout") != NULL) vtype = DX_VIEW_TAB_LAYOUT;
            else if (strstr(tag, "ViewPager") != NULL) vtype = DX_VIEW_VIEW_PAGER;
            else if (strstr(tag, "Chip") != NULL && strstr(tag, "ChipGroup") == NULL) vtype = DX_VIEW_CHIP;
            else if (strstr(tag, "BottomNavigationView") != NULL) vtype = DX_VIEW_BOTTOM_NAV;
            else if (strstr(tag, "SwipeRefreshLayout") != NULL) vtype = DX_VIEW_SWIPE_REFRESH;
            else if (strstr(tag, "RadioGroup") != NULL) vtype = DX_VIEW_RADIO_GROUP;
            else if (strstr(tag, "CoordinatorLayout") != NULL ||
                     strstr(tag, "AppBarLayout") != NULL ||
                     strstr(tag, "CollapsingToolbarLayout") != NULL ||
                     strstr(tag, "DrawerLayout") != NULL ||
                     strstr(tag, "NavigationView") != NULL ||
                     strstr(tag, "Layout") != NULL) vtype = DX_VIEW_VIEW_GROUP;
            // Any remaining unrecognized tags: treat as generic container
            if (vtype == DX_VIEW_NONE) vtype = DX_VIEW_VIEW_GROUP;

            DxUINode *node = dx_ui_node_create(vtype, 0);
            if (!node) break;

            // Detect Guideline tags
            if (strstr(tag, "Guideline") != NULL) {
                node->is_guideline = true;
                node->visibility = DX_GONE; // Guidelines are invisible
            }

            // Track style resource ID for this element
            uint32_t style_res_id = 0;

            // Parse attributes
            uint32_t attr_start = pos + 36;
            for (uint16_t a = 0; a < attr_count; a++) {
                uint32_t aoff = attr_start + a * 20;
                if (aoff + 20 > xml_size) break;

                uint32_t attr_name_idx = read_u32(xml_data + aoff + 4);
                uint32_t attr_raw = read_u32(xml_data + aoff + 8);
                uint32_t attr_typed = read_u32(xml_data + aoff + 12);
                uint32_t attr_data = read_u32(xml_data + aoff + 16);
                uint32_t attr_type = attr_typed >> 24;

                uint32_t attr_res_id = 0;
                if (res_ids && attr_name_idx < res_id_count) {
                    attr_res_id = res_ids[attr_name_idx];
                }

                const char *attr_name = (attr_name_idx < string_count && strings) ?
                                          strings[attr_name_idx] : "";

                // Detect style="@style/..." attribute.
                // In binary AXML, the style attribute has namespace index 0xFFFFFFFF
                // and name "style", or attr_res_id == 0x010100ba.
                // The value is a resource reference (type 0x01) to the style.
                if (strcmp(attr_name, "style") == 0 || attr_res_id == ATTR_STYLE) {
                    if (attr_type == 0x01) { // resource reference
                        style_res_id = attr_data;
                    }
                    continue; // style is not a view attribute
                }

                // Resolve ?attr/ references (type 0x02) through the theme
                if (attr_type == RES_VALUE_TYPE_ATTR && ctx && ctx->theme) {
                    uint8_t resolved_type = (uint8_t)attr_type;
                    uint32_t resolved_data = attr_data;
                    resolve_attr_reference(ctx, &resolved_type, &resolved_data);
                    if (resolved_type != RES_VALUE_TYPE_ATTR) {
                        attr_type = resolved_type;
                        attr_data = resolved_data;
                    }
                }

                // android:id
                if (attr_res_id == ATTR_ID || strcmp(attr_name, "id") == 0) {
                    node->view_id = attr_data;
                }
                // android:text
                else if (attr_res_id == ATTR_TEXT || strcmp(attr_name, "text") == 0) {
                    if (attr_type == 0x03 && attr_raw < string_count && strings) {
                        // String pool reference
                        dx_ui_node_set_text(node, strings[attr_raw]);
                    } else if (attr_type == 0x01) {
                        // Resource reference - look up string from resources
                        const char *res_text = NULL;
                        if (ctx) {
                            uint32_t entry = attr_data & 0xFFFF;
                            if (entry < ctx->string_resource_count && ctx->string_resources) {
                                res_text = ctx->string_resources[entry];
                            }
                        }
                        if (res_text) {
                            dx_ui_node_set_text(node, res_text);
                        } else {
                            char buf[32];
                            snprintf(buf, sizeof(buf), "@0x%08x", attr_data);
                            dx_ui_node_set_text(node, buf);
                        }
                    }
                }
                // android:orientation
                else if (attr_res_id == ATTR_ORIENTATION || strcmp(attr_name, "orientation") == 0) {
                    node->orientation = (attr_data == 1) ? DX_ORIENTATION_VERTICAL :
                                                            DX_ORIENTATION_HORIZONTAL;
                }
                // android:gravity
                else if (attr_res_id == ATTR_GRAVITY || strcmp(attr_name, "gravity") == 0) {
                    node->gravity = (int32_t)attr_data;
                }
                // android:hint
                else if (attr_res_id == ATTR_HINT || strcmp(attr_name, "hint") == 0) {
                    if (attr_type == 0x03 && attr_raw < string_count && strings) {
                        if (node->hint) { dx_free(node->hint); node->hint = NULL; }
                        node->hint = dx_strdup(strings[attr_raw]);
                    }
                }
                // android:textColor
                else if (attr_res_id == ATTR_TEXT_COLOR || strcmp(attr_name, "textColor") == 0) {
                    if (attr_type == 0x1C || attr_type == 0x1D) { // color int
                        node->text_color = attr_data;
                    }
                }
                // android:textSize
                else if (attr_res_id == ATTR_TEXT_SIZE || strcmp(attr_name, "textSize") == 0) {
                    if (attr_type == 0x05) { // dimension
                        float val = dx_ui_decode_dimension(attr_data);
                        if (val > 0 && val < 200) node->text_size = val;
                    }
                }
                // android:background (color or drawable reference)
                else if (attr_res_id == ATTR_BACKGROUND || strcmp(attr_name, "background") == 0) {
                    if (attr_type == 0x1C || attr_type == 0x1D) {
                        node->bg_color = attr_data;
                    }
                    else if (attr_type == 0x01 && ctx) {
                        // Resource reference - could be a shape, selector, layer-list, or image drawable
                        uint32_t bg_img_len = 0;
                        uint8_t *bg_img = dx_ui_extract_drawable_ex(ctx, attr_data, &bg_img_len, node);
                        if (bg_img && bg_img_len > 0) {
                            // Raster image background - store as image data
                            dx_free(node->image_data);
                            node->image_data = bg_img;
                            node->image_data_len = bg_img_len;
                        }
                        // Shape/selector/layer-list data stored on node by extract_drawable_ex
                    }
                }
                // android:padding (all sides)
                else if (attr_res_id == ATTR_PADDING || strcmp(attr_name, "padding") == 0) {
                    int32_t pts = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                    node->padding[0] = node->padding[1] = node->padding[2] = node->padding[3] = pts;
                }
                // android:paddingLeft
                else if (attr_res_id == ATTR_PADDING_L || strcmp(attr_name, "paddingLeft") == 0) {
                    node->padding[0] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:paddingTop
                else if (attr_res_id == ATTR_PADDING_T || strcmp(attr_name, "paddingTop") == 0) {
                    node->padding[1] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:paddingRight
                else if (attr_res_id == ATTR_PADDING_R || strcmp(attr_name, "paddingRight") == 0) {
                    node->padding[2] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:paddingBottom
                else if (attr_res_id == ATTR_PADDING_B || strcmp(attr_name, "paddingBottom") == 0) {
                    node->padding[3] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:paddingStart (maps to left in LTR)
                else if (attr_res_id == ATTR_PADDING_START || strcmp(attr_name, "paddingStart") == 0) {
                    node->padding[0] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:paddingEnd (maps to right in LTR)
                else if (attr_res_id == ATTR_PADDING_END || strcmp(attr_name, "paddingEnd") == 0) {
                    node->padding[2] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:visibility
                else if (attr_res_id == ATTR_VISIBILITY || strcmp(attr_name, "visibility") == 0) {
                    if (attr_data == 0) node->visibility = DX_VISIBLE;
                    else if (attr_data == 4) node->visibility = DX_INVISIBLE;
                    else if (attr_data == 8) node->visibility = DX_GONE;
                }
                // android:checked
                else if (attr_res_id == ATTR_CHECKED || strcmp(attr_name, "checked") == 0) {
                    node->is_checked = (attr_data != 0);
                }
                // android:inputType (for EditText)
                else if (attr_res_id == ATTR_INPUT_TYPE || strcmp(attr_name, "inputType") == 0) {
                    node->input_type = attr_data;
                }
                // android:scaleType (for ImageView)
                else if (attr_res_id == ATTR_SCALE_TYPE || strcmp(attr_name, "scaleType") == 0) {
                    // Android enum: 0=matrix, 1=fitXY, 2=fitStart, 3=fitCenter, 4=fitEnd, 5=center, 6=centerCrop, 7=centerInside
                    // Map to our enum: 0=fitCenter(default), 1=center, 2=centerCrop, 3=centerInside, 4=fitXY, 5=fitStart, 6=fitEnd
                    switch (attr_data) {
                        case 1: node->scale_type = 4; break;  // fitXY
                        case 2: node->scale_type = 5; break;  // fitStart
                        case 3: node->scale_type = 0; break;  // fitCenter (default)
                        case 4: node->scale_type = 6; break;  // fitEnd
                        case 5: node->scale_type = 1; break;  // center
                        case 6: node->scale_type = 2; break;  // centerCrop
                        case 7: node->scale_type = 3; break;  // centerInside
                        default: node->scale_type = 0; break; // fitCenter fallback
                    }
                }
                // android:alpha (float, 0.0-1.0)
                else if (attr_res_id == ATTR_ALPHA || strcmp(attr_name, "alpha") == 0) {
                    if (attr_type == 0x04) { // TYPE_FLOAT
                        float fval;
                        memcpy(&fval, &attr_data, sizeof(float));
                        node->alpha = fval;
                    }
                }
                // android:rotation (float, degrees)
                else if (attr_res_id == ATTR_ROTATION || strcmp(attr_name, "rotation") == 0) {
                    if (attr_type == 0x04) {
                        float fval;
                        memcpy(&fval, &attr_data, sizeof(float));
                        node->rotation = fval;
                    }
                }
                // android:scaleX (float)
                else if (attr_res_id == ATTR_SCALE_X || strcmp(attr_name, "scaleX") == 0) {
                    if (attr_type == 0x04) {
                        float fval;
                        memcpy(&fval, &attr_data, sizeof(float));
                        node->scale_x = fval;
                    }
                }
                // android:scaleY (float)
                else if (attr_res_id == ATTR_SCALE_Y || strcmp(attr_name, "scaleY") == 0) {
                    if (attr_type == 0x04) {
                        float fval;
                        memcpy(&fval, &attr_data, sizeof(float));
                        node->scale_y = fval;
                    }
                }
                // android:translationX (dimension)
                else if (attr_res_id == ATTR_TRANSLATION_X || strcmp(attr_name, "translationX") == 0) {
                    if (attr_type == 0x05) {
                        node->translation_x = dx_ui_decode_dimension(attr_data);
                    } else if (attr_type == 0x04) {
                        float fval;
                        memcpy(&fval, &attr_data, sizeof(float));
                        node->translation_x = fval;
                    }
                }
                // android:translationY (dimension)
                else if (attr_res_id == ATTR_TRANSLATION_Y || strcmp(attr_name, "translationY") == 0) {
                    if (attr_type == 0x05) {
                        node->translation_y = dx_ui_decode_dimension(attr_data);
                    } else if (attr_type == 0x04) {
                        float fval;
                        memcpy(&fval, &attr_data, sizeof(float));
                        node->translation_y = fval;
                    }
                }
                // android:layout_width
                else if (attr_res_id == ATTR_LAYOUT_WIDTH || strcmp(attr_name, "layout_width") == 0) {
                    if (attr_type == 0x05) {
                        // Explicit dimension value (e.g., 200dp)
                        node->width = dx_ui_decode_dimension_int(attr_data);
                    } else {
                        // Special values: -1 match_parent, -2 wrap_content, or raw int
                        node->width = (int32_t)attr_data;
                    }
                }
                // android:layout_height
                else if (attr_res_id == ATTR_LAYOUT_HEIGHT || strcmp(attr_name, "layout_height") == 0) {
                    if (attr_type == 0x05) {
                        // Explicit dimension value (e.g., 48dp)
                        node->height = dx_ui_decode_dimension_int(attr_data);
                    } else {
                        // Special values: -1 match_parent, -2 wrap_content, or raw int
                        node->height = (int32_t)attr_data;
                    }
                }
                // android:layout_weight
                else if (attr_res_id == ATTR_LAYOUT_WEIGHT || strcmp(attr_name, "layout_weight") == 0) {
                    // attr_type 0x04 = float
                    if (attr_type == 0x04) {
                        // Reinterpret attr_data bits as float
                        union { uint32_t u; float f; } conv;
                        conv.u = attr_data;
                        node->weight = conv.f;
                    } else {
                        node->weight = (float)attr_data;
                    }
                }
                // android:layout_margin (all sides)
                else if (attr_res_id == ATTR_LAYOUT_MARGIN || strcmp(attr_name, "layout_margin") == 0) {
                    int32_t pts = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                    node->margin[0] = node->margin[1] = node->margin[2] = node->margin[3] = pts;
                }
                // android:layout_marginLeft
                else if (attr_res_id == ATTR_LAYOUT_MARGIN_L || strcmp(attr_name, "layout_marginLeft") == 0) {
                    node->margin[0] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:layout_marginTop
                else if (attr_res_id == ATTR_LAYOUT_MARGIN_T || strcmp(attr_name, "layout_marginTop") == 0) {
                    node->margin[1] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:layout_marginRight
                else if (attr_res_id == ATTR_LAYOUT_MARGIN_R || strcmp(attr_name, "layout_marginRight") == 0) {
                    node->margin[2] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:layout_marginBottom
                else if (attr_res_id == ATTR_LAYOUT_MARGIN_B || strcmp(attr_name, "layout_marginBottom") == 0) {
                    node->margin[3] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:layout_marginStart (maps to left in LTR)
                else if (attr_res_id == ATTR_LAYOUT_MARGIN_START || strcmp(attr_name, "layout_marginStart") == 0) {
                    node->margin[0] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:layout_marginEnd (maps to right in LTR)
                else if (attr_res_id == ATTR_LAYOUT_MARGIN_END || strcmp(attr_name, "layout_marginEnd") == 0) {
                    node->margin[2] = (attr_type == 0x05) ? dx_ui_decode_dimension_int(attr_data) : (int32_t)attr_data;
                }
                // android:src (ImageView drawable resource)
                else if (attr_res_id == ATTR_SRC || strcmp(attr_name, "src") == 0 ||
                         strcmp(attr_name, "srcCompat") == 0) {
                    if (attr_type == 0x01 && ctx) {
                        // Resource reference - extract drawable from APK
                        // Uses _ex variant which also detects vector drawables
                        uint32_t img_len = 0;
                        uint8_t *img_data = dx_ui_extract_drawable_ex(ctx, attr_data, &img_len, node);
                        if (img_data && img_len > 0) {
                            node->image_data = img_data;
                            node->image_data_len = img_len;
                        }
                        // If img_data is NULL, vector data may have been set on node directly
                    }
                }
                // RelativeLayout: parent alignment flags (boolean attrs: 0x12 = true/-1)
                else if (attr_res_id == ATTR_LAYOUT_ALIGN_PARENT_TOP ||
                         strcmp(attr_name, "layout_alignParentTop") == 0) {
                    if (attr_data != 0) node->relative_flags |= DX_REL_ALIGN_PARENT_TOP;
                }
                else if (attr_res_id == ATTR_LAYOUT_ALIGN_PARENT_BOTTOM ||
                         strcmp(attr_name, "layout_alignParentBottom") == 0) {
                    if (attr_data != 0) node->relative_flags |= DX_REL_ALIGN_PARENT_BOTTOM;
                }
                else if (attr_res_id == ATTR_LAYOUT_ALIGN_PARENT_LEFT ||
                         strcmp(attr_name, "layout_alignParentLeft") == 0) {
                    if (attr_data != 0) node->relative_flags |= DX_REL_ALIGN_PARENT_LEFT;
                }
                else if (attr_res_id == ATTR_LAYOUT_ALIGN_PARENT_RIGHT ||
                         strcmp(attr_name, "layout_alignParentRight") == 0) {
                    if (attr_data != 0) node->relative_flags |= DX_REL_ALIGN_PARENT_RIGHT;
                }
                else if (attr_res_id == ATTR_LAYOUT_CENTER_IN_PARENT ||
                         strcmp(attr_name, "layout_centerInParent") == 0) {
                    if (attr_data != 0) node->relative_flags |= DX_REL_CENTER_IN_PARENT;
                }
                else if (attr_res_id == ATTR_LAYOUT_CENTER_HORIZONTAL ||
                         strcmp(attr_name, "layout_centerHorizontal") == 0) {
                    if (attr_data != 0) node->relative_flags |= DX_REL_CENTER_HORIZONTAL;
                }
                else if (attr_res_id == ATTR_LAYOUT_CENTER_VERTICAL ||
                         strcmp(attr_name, "layout_centerVertical") == 0) {
                    if (attr_data != 0) node->relative_flags |= DX_REL_CENTER_VERTICAL;
                }
                // RelativeLayout: sibling reference attrs (value = view ID)
                else if (attr_res_id == ATTR_LAYOUT_ABOVE ||
                         strcmp(attr_name, "layout_above") == 0) {
                    node->relative_flags |= DX_REL_ABOVE;
                    node->rel_above = attr_data;
                }
                else if (attr_res_id == ATTR_LAYOUT_BELOW ||
                         strcmp(attr_name, "layout_below") == 0) {
                    node->relative_flags |= DX_REL_BELOW;
                    node->rel_below = attr_data;
                }
                else if (attr_res_id == ATTR_LAYOUT_TO_LEFT_OF ||
                         strcmp(attr_name, "layout_toLeftOf") == 0) {
                    node->relative_flags |= DX_REL_LEFT_OF;
                    node->rel_left_of = attr_data;
                }
                else if (attr_res_id == ATTR_LAYOUT_TO_RIGHT_OF ||
                         strcmp(attr_name, "layout_toRightOf") == 0) {
                    node->relative_flags |= DX_REL_RIGHT_OF;
                    node->rel_right_of = attr_data;
                }
                // android:focusable (boolean)
                else if (attr_res_id == ATTR_FOCUSABLE ||
                         strcmp(attr_name, "focusable") == 0) {
                    node->focusable = (attr_data != 0);
                }
                // ConstraintLayout constraint attributes (app: namespace, matched by name)
                // Value is either a view ID (resource reference) or "parent" (string 0x03 → look up)
                // For resource refs (type 0x01), attr_data is the view ID.
                // For "parent" string, we use DX_CONSTRAINT_PARENT sentinel.
                else if (strcmp(attr_name, "layout_constraintLeft_toLeftOf") == 0 ||
                         strcmp(attr_name, "layout_constraintStart_toStartOf") == 0) {
                    if (attr_type == 0x01) {
                        node->constraints.left_to_left = attr_data;
                    } else if (attr_type == 0x03 && attr_raw < string_count && strings &&
                               strcmp(strings[attr_raw], "parent") == 0) {
                        node->constraints.left_to_left = DX_CONSTRAINT_PARENT;
                    } else {
                        // Integer 0 often means "parent" in compiled AXML
                        node->constraints.left_to_left = (attr_data == 0) ? DX_CONSTRAINT_PARENT : attr_data;
                    }
                }
                else if (strcmp(attr_name, "layout_constraintRight_toRightOf") == 0 ||
                         strcmp(attr_name, "layout_constraintEnd_toEndOf") == 0) {
                    if (attr_type == 0x01) {
                        node->constraints.right_to_right = attr_data;
                    } else if (attr_type == 0x03 && attr_raw < string_count && strings &&
                               strcmp(strings[attr_raw], "parent") == 0) {
                        node->constraints.right_to_right = DX_CONSTRAINT_PARENT;
                    } else {
                        node->constraints.right_to_right = (attr_data == 0) ? DX_CONSTRAINT_PARENT : attr_data;
                    }
                }
                else if (strcmp(attr_name, "layout_constraintTop_toTopOf") == 0) {
                    if (attr_type == 0x01) {
                        node->constraints.top_to_top = attr_data;
                    } else if (attr_type == 0x03 && attr_raw < string_count && strings &&
                               strcmp(strings[attr_raw], "parent") == 0) {
                        node->constraints.top_to_top = DX_CONSTRAINT_PARENT;
                    } else {
                        node->constraints.top_to_top = (attr_data == 0) ? DX_CONSTRAINT_PARENT : attr_data;
                    }
                }
                else if (strcmp(attr_name, "layout_constraintBottom_toBottomOf") == 0) {
                    if (attr_type == 0x01) {
                        node->constraints.bottom_to_bottom = attr_data;
                    } else if (attr_type == 0x03 && attr_raw < string_count && strings &&
                               strcmp(strings[attr_raw], "parent") == 0) {
                        node->constraints.bottom_to_bottom = DX_CONSTRAINT_PARENT;
                    } else {
                        node->constraints.bottom_to_bottom = (attr_data == 0) ? DX_CONSTRAINT_PARENT : attr_data;
                    }
                }
                else if (strcmp(attr_name, "layout_constraintTop_toBottomOf") == 0) {
                    if (attr_type == 0x01) {
                        node->constraints.top_to_bottom = attr_data;
                    } else if (attr_type == 0x03 && attr_raw < string_count && strings &&
                               strcmp(strings[attr_raw], "parent") == 0) {
                        node->constraints.top_to_bottom = DX_CONSTRAINT_PARENT;
                    } else {
                        node->constraints.top_to_bottom = (attr_data == 0) ? DX_CONSTRAINT_PARENT : attr_data;
                    }
                }
                else if (strcmp(attr_name, "layout_constraintBottom_toTopOf") == 0) {
                    if (attr_type == 0x01) {
                        node->constraints.bottom_to_top = attr_data;
                    } else if (attr_type == 0x03 && attr_raw < string_count && strings &&
                               strcmp(strings[attr_raw], "parent") == 0) {
                        node->constraints.bottom_to_top = DX_CONSTRAINT_PARENT;
                    } else {
                        node->constraints.bottom_to_top = (attr_data == 0) ? DX_CONSTRAINT_PARENT : attr_data;
                    }
                }
                else if (strcmp(attr_name, "layout_constraintLeft_toRightOf") == 0 ||
                         strcmp(attr_name, "layout_constraintStart_toEndOf") == 0) {
                    if (attr_type == 0x01) {
                        node->constraints.left_to_right = attr_data;
                    } else if (attr_type == 0x03 && attr_raw < string_count && strings &&
                               strcmp(strings[attr_raw], "parent") == 0) {
                        node->constraints.left_to_right = DX_CONSTRAINT_PARENT;
                    } else {
                        node->constraints.left_to_right = (attr_data == 0) ? DX_CONSTRAINT_PARENT : attr_data;
                    }
                }
                else if (strcmp(attr_name, "layout_constraintRight_toLeftOf") == 0 ||
                         strcmp(attr_name, "layout_constraintEnd_toStartOf") == 0) {
                    if (attr_type == 0x01) {
                        node->constraints.right_to_left = attr_data;
                    } else if (attr_type == 0x03 && attr_raw < string_count && strings &&
                               strcmp(strings[attr_raw], "parent") == 0) {
                        node->constraints.right_to_left = DX_CONSTRAINT_PARENT;
                    } else {
                        node->constraints.right_to_left = (attr_data == 0) ? DX_CONSTRAINT_PARENT : attr_data;
                    }
                }
                else if (strcmp(attr_name, "layout_constraintHorizontal_bias") == 0) {
                    if (attr_type == 0x04) {
                        union { uint32_t u; float f; } conv;
                        conv.u = attr_data;
                        node->constraints.horizontal_bias = conv.f;
                    }
                }
                else if (strcmp(attr_name, "layout_constraintVertical_bias") == 0) {
                    if (attr_type == 0x04) {
                        union { uint32_t u; float f; } conv;
                        conv.u = attr_data;
                        node->constraints.vertical_bias = conv.f;
                    }
                }
                // Chain style attributes
                else if (strcmp(attr_name, "layout_constraintHorizontal_chainStyle") == 0) {
                    // 0=spread, 1=spread_inside, 2=packed (Android enum values)
                    if (attr_data == 0) node->constraints.h_chain_style = DX_CHAIN_SPREAD;
                    else if (attr_data == 1) node->constraints.h_chain_style = DX_CHAIN_SPREAD_INSIDE;
                    else if (attr_data == 2) node->constraints.h_chain_style = DX_CHAIN_PACKED;
                }
                else if (strcmp(attr_name, "layout_constraintVertical_chainStyle") == 0) {
                    if (attr_data == 0) node->constraints.v_chain_style = DX_CHAIN_SPREAD;
                    else if (attr_data == 1) node->constraints.v_chain_style = DX_CHAIN_SPREAD_INSIDE;
                    else if (attr_data == 2) node->constraints.v_chain_style = DX_CHAIN_PACKED;
                }
                // Guideline attributes
                else if (strcmp(attr_name, "orientation") == 0 && node->is_guideline) {
                    // 0=horizontal, 1=vertical
                    node->guideline_orientation = (attr_data == 1) ? DX_GUIDELINE_VERTICAL : DX_GUIDELINE_HORIZONTAL;
                }
                else if (strcmp(attr_name, "layout_constraintGuide_begin") == 0) {
                    if (node->is_guideline) {
                        if (attr_type == 0x05) {
                            // Dimension value: convert from Android encoded dp
                            node->guideline_begin = (float)(attr_data >> 8);
                        } else {
                            node->guideline_begin = (float)attr_data;
                        }
                    }
                }
                else if (strcmp(attr_name, "layout_constraintGuide_percent") == 0) {
                    if (node->is_guideline) {
                        if (attr_type == 0x04) {
                            union { uint32_t u; float f; } conv;
                            conv.u = attr_data;
                            node->guideline_percent = conv.f;
                        }
                    }
                }
            }

            // Apply style attributes as defaults (direct attrs take precedence)
            if (style_res_id != 0 && ctx && ctx->resources) {
                DxStyleBag *style = dx_resources_resolve_style(ctx->resources, style_res_id);
                if (style) {
                    apply_style_to_node(node, ctx, style, strings, string_count);
                    dx_style_bag_free(style);
                    DX_TRACE(TAG, "Applied style 0x%08x to <%s>", style_res_id, tag);
                }
            }

            // EditText views are focusable by default
            if (vtype == DX_VIEW_EDIT_TEXT && !node->focusable) {
                node->focusable = true;
            }

            // Add to tree
            if (stack_depth > 0) {
                dx_ui_node_add_child(stack[stack_depth - 1], node);
            } else {
                root = node;
            }

            if (stack_depth < AXML_MAX_NESTING_DEPTH) {
                stack[stack_depth++] = node;
            } else {
                DX_WARN(TAG, "AXML nesting depth exceeds %d levels", AXML_MAX_NESTING_DEPTH);
                // Clean up and bail out
                for (uint32_t si = 0; si < string_count; si++) {
                    dx_free(strings[si]);
                }
                dx_free(strings);
                dx_free(res_ids);
                if (root) dx_ui_node_destroy(root);
                return DX_ERR_AXML_INVALID;
            }

            DX_DEBUG(TAG, "Layout: <%s id=0x%x text=\"%s\">",
                     tag, node->view_id, node->text ? node->text : "");

        } else if (chunk_type == AXML_CHUNK_END_TAG) {
            if (stack_depth > 0) stack_depth--;
        }

        pos += chunk_size;
    }

    // Cleanup
    for (uint32_t i = 0; i < string_count; i++) {
        dx_free(strings[i]);
    }
    dx_free(strings);
    dx_free(res_ids);

    if (root) {
        DX_INFO(TAG, "Layout parsed: root type=%d, %u children",
                root->type, root->child_count);
        *out = root;
        return DX_OK;
    }

    return DX_ERR_AXML_INVALID;
}

DxResult dx_layout_parse_cached(DxContext *ctx, uint32_t resource_id,
                                 const uint8_t *xml_data, uint32_t xml_size, DxUINode **out) {
    if (!out) return DX_ERR_NULL_PTR;

    // Check cache first
    if (resource_id != 0) {
        DxUINode *cached = dx_layout_cache_get(resource_id);
        if (cached) {
            *out = cached;
            return DX_OK;
        }
    }

    // Cache miss - parse normally
    DxResult res = dx_layout_parse(ctx, xml_data, xml_size, out);
    if (res != DX_OK) return res;

    // Store in cache
    if (resource_id != 0 && *out) {
        dx_layout_cache_put(resource_id, *out);
    }

    return DX_OK;
}

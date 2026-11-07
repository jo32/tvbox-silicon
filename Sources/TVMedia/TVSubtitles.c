#include "TVSubtitles.h"

#include <ass/ass.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

struct TVSRenderer {
    ASS_Library *library;
    ASS_Renderer *renderer;
    ASS_Track *track;
    /// Fonts were added since libass last looked: it looks again before the next render.
    int fontsChanged;
    /// The last render's frame and picture sizes: a new size draws again even when the subtitles didn't change.
    int width, height, videoWidth, videoHeight;
    /// Whether the last render drew anything.
    int drew;
    uint8_t *pixels;
    size_t capacity;
};

/// libass's own messages are for its developers; a script's mistakes aren't the viewer's.
static void quiet(int level, const char *format, va_list arguments, void *data) {
    (void)level; (void)format; (void)arguments; (void)data;
}

TVSRenderer *tvs_ass_create(void) {
    TVSRenderer *renderer = calloc(1, sizeof *renderer);
    if (!renderer) return NULL;
    renderer->library = ass_library_init();
    if (!renderer->library) { free(renderer); return NULL; }
    ass_set_message_cb(renderer->library, quiet, NULL);
    // Fonts a script carries in its [Fonts] section.
    ass_set_extract_fonts(renderer->library, 1);
    renderer->renderer = ass_renderer_init(renderer->library);
    if (!renderer->renderer) { ass_library_done(renderer->library); free(renderer); return NULL; }
    // Hinting would move glyphs between frames of a scaled or moving line; the complex shaper handles Arabic,
    // Indic and the rest.
    ass_set_hinting(renderer->renderer, ASS_HINTING_NONE);
    ass_set_shaper(renderer->renderer, ASS_SHAPING_COMPLEX);
    // Glyphs and 64 MiB of bitmaps: enough for karaoke that redraws every line each frame.
    ass_set_cache_limits(renderer->renderer, 4096, 64);
    renderer->fontsChanged = 1;
    return renderer;
}

void tvs_ass_free(TVSRenderer *renderer) {
    if (!renderer) return;
    if (renderer->track) ass_free_track(renderer->track);
    ass_renderer_done(renderer->renderer);
    ass_library_done(renderer->library);
    free(renderer->pixels);
    free(renderer);
}

void tvs_ass_add_font(TVSRenderer *renderer, const char *name, const uint8_t *data, int size) {
    if (!renderer || !data || size <= 0) return;
    ass_add_font(renderer->library, name ? name : "attachment", (const char *)data, size);
    renderer->fontsChanged = 1;
}

int tvs_ass_load(TVSRenderer *renderer, const char *script, int size) {
    if (!renderer || !script || size <= 0) return -1;
    // libass may change the buffer it reads.
    char *copy = malloc((size_t)size + 1);
    if (!copy) return -1;
    memcpy(copy, script, (size_t)size);
    copy[size] = 0;
    ASS_Track *track = ass_read_memory(renderer->library, copy, (size_t)size, NULL);
    free(copy);
    if (!track) return -1;
    if (renderer->track) ass_free_track(renderer->track);
    renderer->track = track;
    renderer->drew = -1;
    // Fonts from the script's [Fonts] section.
    renderer->fontsChanged = 1;
    return 0;
}

int tvs_ass_begin(TVSRenderer *renderer, const char *header, int size) {
    if (!renderer) return -1;
    ASS_Track *track = ass_new_track(renderer->library);
    if (!track) return -1;
    if (header && size > 0) ass_process_codec_private(track, header, size);
    if (renderer->track) ass_free_track(renderer->track);
    renderer->track = track;
    renderer->drew = -1;
    renderer->fontsChanged = 1;
    return 0;
}

void tvs_ass_event(TVSRenderer *renderer, const char *data, int size, int64_t start, int64_t duration) {
    if (!renderer || !renderer->track || !data || size <= 0) return;
    ass_process_chunk(renderer->track, data, size, start, duration > 0 ? duration : 1);
}

int tvs_ass_event_count(const TVSRenderer *renderer) {
    return renderer && renderer->track ? renderer->track->n_events : 0;
}

/// Lays one libass bitmap (an alpha mask in one colour) over the premultiplied BGRA picture, whose top left is
/// `left`, `top` in the frame.
static void blend(const ASS_Image *image, int left, int top, uint8_t *pixels, int stride) {
    uint32_t color = image->color;
    unsigned red = color >> 24, green = (color >> 16) & 0xff, blue = (color >> 8) & 0xff;
    // The colour's alpha byte is transparency: 0 is opaque.
    unsigned opacity = 255 - (color & 0xff);
    if (!opacity) return;
    for (int y = 0; y < image->h; y++) {
        const uint8_t *mask = image->bitmap + (size_t)y * image->stride;
        uint8_t *row = pixels + (size_t)(image->dst_y - top + y) * stride + (size_t)(image->dst_x - left) * 4;
        for (int x = 0; x < image->w; x++) {
            unsigned coverage = mask[x];
            if (!coverage) continue;
            unsigned alpha = (coverage * opacity + 127) / 255, rest = 255 - alpha;
            uint8_t *pixel = row + x * 4;
            pixel[0] = (uint8_t)((blue * alpha + pixel[0] * rest + 127) / 255);
            pixel[1] = (uint8_t)((green * alpha + pixel[1] * rest + 127) / 255);
            pixel[2] = (uint8_t)((red * alpha + pixel[2] * rest + 127) / 255);
            pixel[3] = (uint8_t)(alpha + (pixel[3] * rest + 127) / 255);
        }
    }
}

int tvs_ass_render(TVSRenderer *renderer, int64_t time, int width, int height, int videoWidth, int videoHeight, TVSImage *out) {
    if (!renderer || !renderer->track || width <= 0 || height <= 0 || !out) return -1;
    if (videoWidth <= 0 || videoHeight <= 0) { videoWidth = width; videoHeight = height; }
    int resized = width != renderer->width || height != renderer->height || videoWidth != renderer->videoWidth || videoHeight != renderer->videoHeight;
    if (resized) {
        ass_set_frame_size(renderer->renderer, width, height);
        // The picture's own size: what ScaledBorderAndShadow and blur scale against.
        ass_set_storage_size(renderer->renderer, videoWidth, videoHeight);
        renderer->width = width; renderer->height = height;
        renderer->videoWidth = videoWidth; renderer->videoHeight = videoHeight;
    }
    if (renderer->fontsChanged) {
        // CoreText finds the system's fonts; Helvetica is on every Apple system, and a glyph it lacks (Chinese,
        // Japanese, Arabic...) comes from CoreText's fallback.
        ass_set_fonts(renderer->renderer, NULL, "Helvetica", ASS_FONTPROVIDER_AUTODETECT, NULL, 1);
        renderer->fontsChanged = 0;
        resized = 1;
    }
    int change = 0;
    ASS_Image *images = ass_render_frame(renderer->renderer, renderer->track, time, &change);
    if (!images) {
        // Nothing shows: a change only when something did.
        if (renderer->drew == 0 && !resized) return 0;
        renderer->drew = 0;
        memset(out, 0, sizeof *out);
        return 1;
    }
    if (!change && !resized && renderer->drew == 1) return 0;
    // Only the part of the frame the subtitles cover.
    int left = width, top = height, right = 0, bottom = 0;
    for (const ASS_Image *image = images; image; image = image->next) {
        if (image->w <= 0 || image->h <= 0) continue;
        if (image->dst_x < left) left = image->dst_x;
        if (image->dst_y < top) top = image->dst_y;
        if (image->dst_x + image->w > right) right = image->dst_x + image->w;
        if (image->dst_y + image->h > bottom) bottom = image->dst_y + image->h;
    }
    if (right <= left || bottom <= top) {
        if (renderer->drew == 0 && !resized) return 0;
        renderer->drew = 0;
        memset(out, 0, sizeof *out);
        return 1;
    }
    int boxWidth = right - left, boxHeight = bottom - top, stride = boxWidth * 4;
    size_t size = (size_t)stride * boxHeight;
    if (size > renderer->capacity) {
        uint8_t *pixels = realloc(renderer->pixels, size);
        if (!pixels) return -1;
        renderer->pixels = pixels;
        renderer->capacity = size;
    }
    memset(renderer->pixels, 0, size);
    for (const ASS_Image *image = images; image; image = image->next) {
        if (image->w > 0 && image->h > 0) blend(image, left, top, renderer->pixels, stride);
    }
    renderer->drew = 1;
    out->x = left; out->y = top; out->width = boxWidth; out->height = boxHeight; out->stride = stride;
    out->pixels = renderer->pixels;
    return 1;
}

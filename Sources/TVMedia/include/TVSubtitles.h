#ifndef TVSUBTITLES_H
#define TVSUBTITLES_H

#include <stdint.h>

/// Styled subtitles the app draws over the picture itself (#576 M3): ASS/SSA through libass, with the system's fonts
/// (CoreText) and a file's own. Times are milliseconds of the subtitle's clock. One renderer is used by one thread at
/// a time; separate renderers are independent.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TVSRenderer TVSRenderer;

/// What a render drew: premultiplied BGRA (32-bit little-endian, alpha first), `width` × `height` pixels at `x`, `y`
/// in the frame. `width` 0: nothing shows. `pixels` stays valid until the next render or `tvs_ass_free`.
typedef struct {
    int x, y, width, height, stride;
    const uint8_t *pixels;
} TVSImage;

/// A renderer, or NULL when libass can't start.
TVSRenderer *tvs_ass_create(void);
void tvs_ass_free(TVSRenderer *renderer);
/// A font the subtitles name (a Matroska attachment), before or after the script; libass keeps a copy.
void tvs_ass_add_font(TVSRenderer *renderer, const char *name, const uint8_t *data, int size);
/// A whole ASS/SSA file in UTF-8. Returns 0, or -1 when it isn't one.
int tvs_ass_load(TVSRenderer *renderer, const char *script, int size);
/// A Matroska ASS track's header (its codec private data), before its events. Returns 0, or -1.
int tvs_ass_begin(TVSRenderer *renderer, const char *header, int size);
/// One Matroska ASS event (ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text) and when it shows.
/// The same ReadOrder twice is kept once.
void tvs_ass_event(TVSRenderer *renderer, const char *data, int size, int64_t start, int64_t duration);
int tvs_ass_event_count(const TVSRenderer *renderer);
/// Draws what shows at `time` on a frame `width` × `height` pixels showing a picture `videoWidth` × `videoHeight`
/// big (0: the frame's). Returns 1 with `image` when it differs from the last render, 0 when it is the same (and
/// `image` is untouched), -1 on failure.
int tvs_ass_render(TVSRenderer *renderer, int64_t time, int width, int height, int videoWidth, int videoHeight, TVSImage *image);

#ifdef __cplusplus
}
#endif

#endif

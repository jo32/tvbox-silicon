#ifndef TVMEDIA_H
#define TVMEDIA_H

#include <stdint.h>
// The module's umbrella header: the styled subtitle renderer (libass) is part of it.
#include "TVSubtitles.h"

/// Repackages a media file AVPlayer can't open (MKV, AVI, FLV, WMV, RMVB, ...) into fragmented MP4, one HLS
/// segment at a time, with FFmpeg. Video and audio that Apple devices decode are copied as they are; only what
/// they can't decode is converted. See Docs/mkv-playback-plan.md. Times are microseconds of the file's own clock.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TVMInput TVMInput;
typedef struct TVMCursor TVMCursor;

/// Reads up to `size` bytes at `offset`. Returns the count, 0 at the end of the file, or a negative value on failure.
typedef int (*TVMReadFunction)(void *context, int64_t offset, uint8_t *buffer, int size);
/// Nonzero stops the work in progress (the file is closed or the segment no longer wanted).
typedef int (*TVMInterruptFunction)(void *context);
/// A track's output bytes, in order.
typedef void (*TVMWriteFunction)(void *context, int track, const uint8_t *bytes, int size);
/// A subtitle event: its raw packet text (SubRip, ASS event, WebVTT or tx3g) and when it shows.
typedef void (*TVMCueFunction)(void *context, int track, int64_t start, int64_t end, const uint8_t *text, int size);
/// FFmpeg's warnings and errors.
typedef void (*TVMLogFunction)(int level, const char *message);

enum { TVMKindVideo = 0, TVMKindAudio = 1, TVMKindSubtitle = 2, TVMKindOther = 3 };

typedef struct {
    int kind;
    /// FFmpeg's codec name: h264, hevc, av1, aac, ac3, eac3, dts, truehd, subrip, ass, hdmv_pgs_subtitle, ...
    char codec[32];
    int profile, level;
    int width, height;
    /// Bits per sample of the picture, and its chroma subsampling: 420, 422, 444 (0 unknown).
    int bitDepth, chroma;
    double frameRate;
    int sampleAspectNum, sampleAspectDen;
    /// FFmpeg's AVColorTransferCharacteristic and AVColorPrimaries.
    int colorTransfer, colorPrimaries;
    /// H.264 that x264 encoded with intra refresh: no keyframe a player can start at after the first.
    int intraRefresh;
    /// The picture is interlaced: each frame two fields, a moment apart (broadcast 1080i).
    int interlaced;
    /// Dolby Vision profile and level from the stream's configuration record, -1 when it has none.
    int doviProfile, doviLevel, doviCompatibility;
    int sampleRate, channels;
    int64_t bitRate;
    /// Microseconds, -1 when unknown.
    int64_t startTime, duration;
    char language[16];
    char title[160];
    int isDefault, isForced;
    /// A text subtitle (not a picture-based one such as PGS).
    int isText;
    /// The container's id for the stream: an MPEG transport stream's PID.
    int id;
    /// The codec's configuration bytes (avcC, hvcC, ...), valid while the input is open.
    const uint8_t *extradata;
    int extradataSize;
} TVMStream;

enum { TVMModeCopy = 0, TVMModeAAC = 1, TVMModeH264 = 2, TVMModeHEVC = 3 };
enum { TVMDolbyVisionDrop = 0, TVMDolbyVisionHVC1 = 1, TVMDolbyVisionDVH1 = 2 };

typedef struct {
    /// The input stream this track comes from.
    int stream;
    /// TVMModeCopy, or the codec it is converted to.
    int mode;
    /// Bits per second of a converted track.
    int bitRate;
    /// Channels of converted audio: 1, 2 or 6.
    int channels;
    /// How copied HEVC keeps a Dolby Vision configuration (TVMDolbyVision...).
    int dolbyVision;
    /// Non-zero: converted HDR video is tone mapped to 8-bit SDR (BT.709), for a device that doesn't show HDR.
    int toneMap;
    /// The size converted video is made at; 0 keeps the source's.
    int width, height;
    /// Non-zero: interlaced frames of converted video are deinterlaced first (`deinterlace`).
    int deinterlace;
} TVMTrack;

void tvm_set_log(TVMLogFunction log);

/// Opens a file of `size` bytes (-1 when unknown, which also makes it unseekable). On failure returns NULL and
/// writes FFmpeg's reason into `error`.
TVMInput *tvm_open(void *context, TVMReadFunction read, TVMInterruptFunction interrupted, int64_t size,
                   char *error, int errorSize);
void tvm_close(TVMInput *input);
/// The demuxer's name (matroska,webm / avi / flv / asf / rm / mpegts / mpeg / mov,mp4,... / ogg).
const char *tvm_format(const TVMInput *input);
/// Microseconds, -1 when unknown.
int64_t tvm_duration(const TVMInput *input);
/// When the file's clock begins, in microseconds (0 when unknown).
int64_t tvm_start_time(const TVMInput *input);
int tvm_stream_count(const TVMInput *input);
int tvm_stream(const TVMInput *input, int index, TVMStream *stream);
/// A metadata tag of a stream, such as an attachment's "filename" or "mimetype", into `out`. Returns its length, -1
/// when the stream has none.
int tvm_stream_tag(const TVMInput *input, int index, const char *key, char *out, int size);

// MARK: Bitmap subtitles (#576 M3)

/// A decoder of a bitmap subtitle stream (Blu-ray PGS, DVD VobSub) of an input.
typedef struct TVMBitmapDecoder TVMBitmapDecoder;
/// One picture of a bitmap subtitle at (x, y) of its canvas: premultiplied BGRA, `width * 4` bytes a row.
typedef struct {
    int x, y, width, height;
    uint8_t *pixels;
} TVMBitmapRect;
/// What one packet shows from `start` to `end` (microseconds of the file's clock; `end` -1 when the next one
/// ends it), on a `canvasWidth` × `canvasHeight` frame (0 when the stream doesn't say). No rects clears the screen.
typedef struct {
    int64_t start, end;
    int canvasWidth, canvasHeight;
    int count;
    TVMBitmapRect rects[8];
} TVMBitmapSubtitle;

/// Whether FFmpeg here decodes the bitmap subtitle codec FFmpeg names `codec`.
int tvm_bitmap_available(const char *codec);
/// A decoder for stream `index` of `input`; NULL when it isn't a bitmap subtitle FFmpeg here decodes.
TVMBitmapDecoder *tvm_bitmap_open(const TVMInput *input, int index);
/// Decodes one packet whose time is `time` (and length `duration`, or -1) in microseconds. Returns 1 when `out`
/// holds a subtitle (free it with `tvm_bitmap_clear`), 0 when the packet showed nothing, negative on error.
int tvm_bitmap_decode(TVMBitmapDecoder *decoder, const uint8_t *data, int size, int64_t time, int64_t duration,
                      TVMBitmapSubtitle *out);
void tvm_bitmap_clear(TVMBitmapSubtitle *subtitle);
void tvm_bitmap_close(TVMBitmapDecoder *decoder);
/// The stream's keyframes known from the file's index (Matroska Cues, AVI idx1, ...), ascending, in microseconds.
/// Returns how many there are, which may be more than `capacity`.
int tvm_keyframes(const TVMInput *input, int index, int64_t *times, int capacity);

/// A reader over the open input that writes `tracks` (at most one video track). `offset` is added to every
/// output timestamp, so none is negative. The input belongs to the cursor's thread while it is in use.
TVMCursor *tvm_cursor_create(TVMInput *input, const TVMTrack *tracks, int count, int64_t offset);
void tvm_cursor_free(TVMCursor *cursor);
/// The initialization segment (ftyp and moov) of an audio or video track.
int tvm_cursor_init(TVMCursor *cursor, int track, void *context, TVMWriteFunction write, char *error, int errorSize);
/// Writes the segment from the keyframe at `start` to the one at `end` (exclusive; `end` < 0: to the end of the
/// file) for the tracks whose `active` flag is set. A segment that begins where the previous one ended goes
/// on reading from there, so playing through never seeks. Returns 0, or FFmpeg's negative error code.
int tvm_cursor_segment(TVMCursor *cursor, int64_t start, int64_t end, const uint8_t *active, void *context,
                       TVMWriteFunction write, TVMCueFunction cue, char *error, int errorSize);

/// Opens a local file for reading, as `tvm_open` would with a reader over it.
TVMInput *tvm_open_file(const char *path, char *error, int errorSize);

/// Writes a text subtitle event's plain text (UTF-8, no markup) into `out`; returns its length, 0 to leave it out.
typedef int (*TVMTextFunction)(void *context, int track, const uint8_t *text, int size, uint8_t *out, int capacity);
/// How far the reader is (a byte position in the input); nonzero stops the work.
typedef int (*TVMProgressFunction)(void *context, int64_t position);

/// Copies `streams` (the input's stream indices; video and audio as they are, text subtitles as tx3g) from the
/// start of the input into a plain MP4 file at `path`, which AVPlayer opens by itself. `dolbyVision` says how copied
/// HEVC keeps a Dolby Vision configuration (TVMDolbyVision...). `track` in `text` is the stream's place in
/// `streams`. Returns 0, or FFmpeg's negative error code; a failed file is removed.
int tvm_rewrap(TVMInput *input, const int *streams, int count, int dolbyVision, const char *path, void *context,
               TVMTextFunction text, TVMProgressFunction progress, char *error, int errorSize);

#ifdef __cplusplus
}
#endif

#endif

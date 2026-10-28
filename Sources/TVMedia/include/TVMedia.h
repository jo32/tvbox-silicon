#ifndef TVMEDIA_H
#define TVMEDIA_H

#include <stdint.h>

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

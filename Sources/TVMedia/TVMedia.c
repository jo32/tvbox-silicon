#include "TVMedia.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <VideoToolbox/VideoToolbox.h>

/// How far before a keyframe's time a packet still counts as that keyframe (index times are rounded).
#define TOLERANCE 2000
/// A track with nothing past the segment's end stops being waited for once the reader is this far beyond it.
#define LOOKAHEAD 3000000
/// Each segment goes out in fragments of about this length, so its first bytes leave before it is finished.
#define FRAGMENT 1000000
/// Copied video ends its segment at the next keyframe; the reader gives up on one this far past the end.
#define MAXGOP 60000000
/// Beyond the keyframe index by this much, a seek guesses a byte position instead of reading up to the time.
#define UNINDEXED 30000000

static TVMLogFunction logger;

static void log_callback(void *object, int level, const char *format, va_list arguments) {
    if (!logger || level > AV_LOG_WARNING) return;
    char line[1024];
    int prefix = 1;
    av_log_format_line(object, level, format, arguments, line, sizeof line, &prefix);
    size_t length = strlen(line);
    while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) line[--length] = 0;
    if (length > 0) logger(level, line);
}

void tvm_set_log(TVMLogFunction log) {
    logger = log;
    av_log_set_level(AV_LOG_WARNING);
    av_log_set_callback(log_callback);
}

static int fail(char *error, int size, int code, const char *what) {
    if (error && size > 0) {
        char reason[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(code, reason, sizeof reason);
        snprintf(error, size, "%s: %s", what, reason);
    }
    return code;
}

// MARK: - Input

struct TVMInput {
    AVFormatContext *format;
    AVIOContext *io;
    void *context;
    TVMReadFunction read;
    TVMInterruptFunction interrupted;
    int64_t size, position;
    /// The file `tvm_open_file` opened, closed with the input; -1 otherwise.
    int descriptor;
    /// The H.264 stream x264 encoded with intra refresh, -1 when none.
    int intraRefresh;
};

static int input_read(void *opaque, uint8_t *buffer, int size) {
    TVMInput *input = opaque;
    if (input->size >= 0 && input->position >= input->size) return AVERROR_EOF;
    int count = input->read(input->context, input->position, buffer, size);
    if (count == 0) return AVERROR_EOF;
    if (count < 0) return input->interrupted && input->interrupted(input->context) ? AVERROR_EXIT : AVERROR(EIO);
    input->position += count;
    return count;
}

static int64_t input_seek(void *opaque, int64_t offset, int whence) {
    TVMInput *input = opaque;
    switch (whence & ~AVSEEK_FORCE) {
    case AVSEEK_SIZE: return input->size >= 0 ? input->size : AVERROR(ENOSYS);
    case SEEK_SET: input->position = offset; break;
    case SEEK_CUR: input->position += offset; break;
    case SEEK_END:
        if (input->size < 0) return AVERROR(ENOSYS);
        input->position = input->size + offset;
        break;
    default: return AVERROR(EINVAL);
    }
    return input->position;
}

static int input_interrupt(void *opaque) {
    TVMInput *input = opaque;
    return input->interrupted ? input->interrupted(input->context) : 0;
}

/// A picture whose container doesn't say how its colours are coded (an x265 encode in MKV, often) says it in
/// its frames: whether it is HDR10 or HLG must be known before the plan is made.
static void probe_colors(AVFormatContext *format) {
    for (unsigned index = 0; index < format->nb_streams; index++) {
        AVCodecParameters *par = format->streams[index]->codecpar;
        if (par->codec_type != AVMEDIA_TYPE_VIDEO || par->color_trc != AVCOL_TRC_UNSPECIFIED) continue;
        if (par->codec_id != AV_CODEC_ID_HEVC && par->codec_id != AV_CODEC_ID_H264 && par->codec_id != AV_CODEC_ID_AV1) return;
        const AVCodec *codec = avcodec_find_decoder(par->codec_id);
        AVCodecContext *decoder = codec ? avcodec_alloc_context3(codec) : NULL;
        AVPacket *packet = av_packet_alloc();
        AVFrame *frame = av_frame_alloc();
        if (decoder && packet && frame && avcodec_parameters_to_context(decoder, par) >= 0 && avcodec_open2(decoder, codec, NULL) >= 0) {
            for (int count = 0; count < 300 && av_read_frame(format, packet) >= 0; count++) {
                int sent = packet->stream_index == (int)index ? avcodec_send_packet(decoder, packet) : 0;
                av_packet_unref(packet);
                if (sent < 0 && sent != AVERROR(EAGAIN)) break;
                if (avcodec_receive_frame(decoder, frame) < 0) continue;
                par->color_trc = frame->color_trc; par->color_primaries = frame->color_primaries;
                par->color_space = frame->colorspace;
                break;
            }
        }
        av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&decoder);
        return;
    }
}

/// A Matroska file written as a stream (a recording, FFmpeg's `-live`, a pipe) has no Duration, and one FFmpeg wrote
/// from a clock that doesn't start at zero gives the time it ends there instead of its length. The packets at the
/// end of the file say how long it is: a few MB of it are read, more only when no cluster starts in them.
static void probe_end(TVMInput *input) {
    AVFormatContext *format = input->format;
    int64_t start = format->start_time == AV_NOPTS_VALUE ? 0 : format->start_time;
    int unknown = format->duration == AV_NOPTS_VALUE || format->duration <= 0;
    if (input->size <= 0 || strncmp(format->iformat->name, "matroska", 8) || (!unknown && start <= 500000)) return;
    AVPacket *packet = av_packet_alloc();
    if (!packet) return;
    int64_t end = AV_NOPTS_VALUE;
    for (int64_t window = 4 << 20; end == AV_NOPTS_VALUE; window *= 4) {
        if (av_seek_frame(format, -1, FFMAX(input->size - window, 0), AVSEEK_FLAG_BYTE) < 0) break;
        for (int count = 0; count < 200000 && av_read_frame(format, packet) >= 0; count++) {
            const AVStream *st = format->streams[packet->stream_index];
            int64_t time = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
            if (time != AV_NOPTS_VALUE) {
                int64_t at = av_rescale_q(time + FFMAX(packet->duration, 0), st->time_base, AV_TIME_BASE_Q);
                if (end == AV_NOPTS_VALUE || at > end) end = at;
            }
            av_packet_unref(packet);
        }
        if (window >= input->size || window >= (256 << 20)) break;
    }
    av_packet_free(&packet);
    av_seek_frame(format, -1, 0, AVSEEK_FLAG_BYTE);
    if (end == AV_NOPTS_VALUE || end <= start) return;
    // A Duration that is the end time runs past the last packet by the start; one that is the length doesn't.
    if (unknown || (start + format->duration > end + 2000000 && llabs(format->duration - end) < 2000000)) format->duration = end - start;
}

/// x264's intra refresh has no keyframe after the first: what it marks as keyframes are recovery points, where
/// AVPlayer can't start decoding, so a segment that starts there shows no picture. x264 writes its settings into
/// the first picture. Reads the first packets, and the caller goes back to the start; -2 when it read none.
static int probe_intra_refresh(AVFormatContext *format) {
    int video = -1;
    for (unsigned index = 0; index < format->nb_streams && video < 0; index++) {
        const AVStream *st = format->streams[index];
        if (st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !(st->disposition & AV_DISPOSITION_ATTACHED_PIC)) video = (int)index;
    }
    if (video < 0 || format->streams[video]->codecpar->codec_id != AV_CODEC_ID_H264) return -2;
    AVPacket *packet = av_packet_alloc();
    int found = -1;
    for (int count = 0; packet && count < 64 && av_read_frame(format, packet) >= 0; count++) {
        int first = packet->stream_index == video;
        if (first && packet->data && memmem(packet->data, packet->size, "intra_refresh=1", 15)) found = video;
        av_packet_unref(packet);
        if (first) break;
    }
    av_packet_free(&packet);
    return found;
}

/// `prepare`: probe the colours and go back to the first keyframe, as playing needs. Without it the reader stays
/// at the start of the file, with what finding the streams read still to come.
static TVMInput *open_input(void *context, TVMReadFunction read, TVMInterruptFunction interrupted, int64_t size, int prepare,
                            char *error, int errorSize) {
    TVMInput *input = av_mallocz(sizeof(TVMInput));
    if (!input) { fail(error, errorSize, AVERROR(ENOMEM), "open"); return NULL; }
    input->context = context; input->read = read; input->interrupted = interrupted; input->size = size;
    input->descriptor = -1;
    input->intraRefresh = -1;
    const int bufferSize = 256 << 10;
    uint8_t *buffer = av_malloc(bufferSize);
    input->io = buffer ? avio_alloc_context(buffer, bufferSize, 0, input, input_read, NULL, size >= 0 ? input_seek : NULL) : NULL;
    if (!input->io) { av_free(buffer); av_free(input); fail(error, errorSize, AVERROR(ENOMEM), "open"); return NULL; }
    input->io->seekable = size >= 0 ? AVIO_SEEKABLE_NORMAL : 0;
    AVFormatContext *format = avformat_alloc_context();
    if (!format) { tvm_close(input); fail(error, errorSize, AVERROR(ENOMEM), "open"); return NULL; }
    format->pb = input->io;
    // GENPTS: AVI and FLV store decode times only; the MP4 muxer needs presentation times as well.
    format->flags |= AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_GENPTS;
    format->interrupt_callback.callback = input_interrupt;
    format->interrupt_callback.opaque = input;
    // Enough to learn every stream's parameters without reading far into a remote file.
    format->probesize = 4 << 20;
    format->max_analyze_duration = 2 * AV_TIME_BASE;
    int status = avformat_open_input(&format, NULL, NULL, NULL);
    if (status < 0) { tvm_close(input); fail(error, errorSize, status, "open"); return NULL; }
    input->format = format;
    status = avformat_find_stream_info(format, NULL);
    if (status < 0) { tvm_close(input); fail(error, errorSize, status, "stream info"); return NULL; }
    if (!prepare) return input;
    if (size >= 0) probe_colors(format);
    if (size >= 0) probe_end(input);
    // Matroska reads its Cues (the keyframe index) at the first seek; back to the start does it now.
    int64_t first = format->start_time == AV_NOPTS_VALUE ? 0 : format->start_time;
    if (size >= 0) av_seek_frame(format, -1, first, AVSEEK_FLAG_BACKWARD);
    int intraRefresh = size >= 0 ? probe_intra_refresh(format) : -2;
    if (intraRefresh != -2) {
        input->intraRefresh = intraRefresh;
        av_seek_frame(format, -1, first, AVSEEK_FLAG_BACKWARD);
    }
    return input;
}

TVMInput *tvm_open(void *context, TVMReadFunction read, TVMInterruptFunction interrupted, int64_t size,
                   char *error, int errorSize) {
    return open_input(context, read, interrupted, size, 1, error, errorSize);
}

void tvm_close(TVMInput *input) {
    if (!input) return;
    if (input->format) avformat_close_input(&input->format);
    if (input->io) { av_freep(&input->io->buffer); avio_context_free(&input->io); }
    if (input->descriptor >= 0) close(input->descriptor);
    av_free(input);
}

const char *tvm_format(const TVMInput *input) { return input->format->iformat->name; }

int64_t tvm_duration(const TVMInput *input) {
    return input->format->duration == AV_NOPTS_VALUE ? -1 : input->format->duration;
}

int64_t tvm_start_time(const TVMInput *input) {
    return input->format->start_time == AV_NOPTS_VALUE ? 0 : input->format->start_time;
}

int tvm_stream_count(const TVMInput *input) { return (int)input->format->nb_streams; }

static int64_t microseconds(int64_t value, AVRational base) {
    return value == AV_NOPTS_VALUE ? -1 : av_rescale_q(value, base, AV_TIME_BASE_Q);
}

int tvm_stream(const TVMInput *input, int index, TVMStream *out) {
    if (index < 0 || index >= (int)input->format->nb_streams) return -1;
    const AVStream *st = input->format->streams[index];
    const AVCodecParameters *par = st->codecpar;
    memset(out, 0, sizeof *out);
    switch (par->codec_type) {
    case AVMEDIA_TYPE_VIDEO: out->kind = st->disposition & AV_DISPOSITION_ATTACHED_PIC ? TVMKindOther : TVMKindVideo; break;
    case AVMEDIA_TYPE_AUDIO: out->kind = TVMKindAudio; break;
    case AVMEDIA_TYPE_SUBTITLE: out->kind = TVMKindSubtitle; break;
    default: out->kind = TVMKindOther; break;
    }
    snprintf(out->codec, sizeof out->codec, "%s", avcodec_get_name(par->codec_id));
    out->profile = par->profile; out->level = par->level;
    out->width = par->width; out->height = par->height;
    if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
        const AVPixFmtDescriptor *pixels = av_pix_fmt_desc_get(par->format);
        if (pixels) {
            out->bitDepth = pixels->comp[0].depth;
            if (pixels->nb_components >= 3)
                out->chroma = pixels->log2_chroma_w == 1 ? (pixels->log2_chroma_h == 1 ? 420 : 422) : (pixels->log2_chroma_h == 0 ? 444 : 0);
        } else out->bitDepth = par->bits_per_raw_sample;
        AVRational rate = st->avg_frame_rate.num && st->avg_frame_rate.den ? st->avg_frame_rate : st->r_frame_rate;
        out->frameRate = rate.num && rate.den ? av_q2d(rate) : 0;
        AVRational aspect = par->sample_aspect_ratio.num ? par->sample_aspect_ratio : st->sample_aspect_ratio;
        out->sampleAspectNum = aspect.num; out->sampleAspectDen = aspect.den;
        out->colorTransfer = par->color_trc; out->colorPrimaries = par->color_primaries;
        out->intraRefresh = input->intraRefresh == index;
    }
    out->doviProfile = out->doviLevel = out->doviCompatibility = -1;
    const AVPacketSideData *dovi = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    if (dovi && dovi->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        const AVDOVIDecoderConfigurationRecord *record = (const AVDOVIDecoderConfigurationRecord *)dovi->data;
        out->doviProfile = record->dv_profile; out->doviLevel = record->dv_level;
        out->doviCompatibility = record->dv_bl_signal_compatibility_id;
    }
    out->sampleRate = par->sample_rate;
    out->channels = par->ch_layout.nb_channels;
    out->bitRate = par->bit_rate;
    out->startTime = microseconds(st->start_time, st->time_base);
    out->duration = microseconds(st->duration, st->time_base);
    const AVDictionaryEntry *language = av_dict_get(st->metadata, "language", NULL, 0);
    if (language) snprintf(out->language, sizeof out->language, "%s", language->value);
    const AVDictionaryEntry *title = av_dict_get(st->metadata, "title", NULL, 0);
    if (title) snprintf(out->title, sizeof out->title, "%s", title->value);
    out->isDefault = (st->disposition & AV_DISPOSITION_DEFAULT) != 0;
    out->isForced = (st->disposition & AV_DISPOSITION_FORCED) != 0;
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(par->codec_id);
    out->isText = descriptor && (descriptor->props & AV_CODEC_PROP_TEXT_SUB);
    out->extradata = par->extradata;
    out->extradataSize = par->extradata_size;
    return 0;
}

int tvm_keyframes(const TVMInput *input, int index, int64_t *times, int capacity) {
    if (index < 0 || index >= (int)input->format->nb_streams) return 0;
    AVStream *st = input->format->streams[index];
    int entries = avformat_index_get_entries_count(st), count = 0;
    int64_t last = INT64_MIN;
    for (int i = 0; i < entries; i++) {
        const AVIndexEntry *entry = avformat_index_get_entry(st, i);
        if (!entry || !(entry->flags & AVINDEX_KEYFRAME) || entry->timestamp == AV_NOPTS_VALUE) continue;
        int64_t time = av_rescale_q(entry->timestamp, st->time_base, AV_TIME_BASE_Q);
        if (time <= last) continue;
        if (count < capacity) times[count] = time;
        count++;
        last = time;
    }
    return count;
}

// MARK: - Cursor

typedef struct Track {
    struct TVMCursor *owner;
    int index;
    TVMTrack spec;
    AVStream *in;
    enum AVMediaType type;
    /// Output clock: 90 kHz for video, the sample rate for audio.
    AVRational outBase;
    int64_t outOffset;
    AVCodecContext *decoder, *encoder;
    SwrContext *resampler;
    AVChannelLayout resamplerLayout;
    int resamplerFormat, resamplerRate;
    AVAudioFifo *fifo;
    struct SwsContext *scaler;
    AVFrame *scaled;
    /// Tone mapping at a smaller size: the picture is shrunk first, in its own colors, which costs far less.
    struct SwsContext *shrinker;
    AVFrame *shrunk;
    /// Tone mapping on the media engine: VideoToolbox decodes, a pixel transfer shrinks and maps the picture, and
    /// the encoder takes it from a VideoToolbox frame pool, with no copy through memory.
    AVBufferRef *hwDevice, *hwFrames;
    VTPixelTransferSessionRef transfer;
    AVFrame *uploaded, *downloaded;
    /// Audio: the next sample's time (output clock, before the offset); AV_NOPTS_VALUE after a reset.
    int64_t nextSample;
    /// Audio conversion just restarted: the encoder's priming before the segment's start is dropped.
    int fresh;
    /// Video conversion: the next frame starts the segment, as a keyframe.
    int firstFrame;
    int64_t lastFramePts;
    /// Decoded video frames at or past the segment's end, for the segment after it.
    AVFrame **held;
    int heldCount, heldCapacity;
    AVFormatContext *mux;
    /// The writer's output passes through a filter of top-level boxes: an initialization segment keeps only
    /// ftyp and moov, a media segment everything else.
    int keepHeader, boxFill, boxPasses;
    uint8_t box[16];
    uint64_t boxLeft;
    /// The muxer needs a packet before its moov (AC-3 and E-AC-3 read their configuration from one): the
    /// track's first packet, kept for its initialization segment.
    int delayed;
    AVPacket *sample;
    int64_t fragmentStart, lastDts;
    /// The packet written last, held back until the next one gives its exact duration (container durations
    /// are often rounded, and the muxer takes a fragment's end from them).
    AVPacket *waiting;
    /// Copied video's decode times, rebuilt from presentation times (Matroska stores only those): the
    /// smallest of the last `reorder` + 1, in a sorted window. Each segment starts it afresh.
    int64_t window[17];
    int windowCount, reorder, decoded;
    int64_t frameDuration;
    int started, ended;
} Track;

struct TVMCursor {
    TVMInput *input;
    Track *tracks;
    int count;
    int *trackOf;
    int videoStream;
    int64_t offset;
    /// Where a segment begins that just goes on reading; INT64_MIN when the reader must seek first.
    int64_t nextStart;
    int untouched, eof;
    AVPacket **pending;
    int pendingHead, pendingCount, pendingCapacity;
    AVPacket *packet, *encoded;
    AVFrame *frame;
    int64_t start, end, readPosition;
    const uint8_t *active;
    void *context;
    TVMWriteFunction write;
    TVMCueFunction cue;
};

static int header_box(const uint8_t *type) { return !memcmp(type, "ftyp", 4) || !memcmp(type, "moov", 4); }

static int sink_write(void *opaque, const uint8_t *bytes, int size) {
    Track *track = opaque;
    TVMCursor *cursor = track->owner;
    int total = size;
    while (size > 0) {
        if (!track->boxLeft) {
            // A box header: its size, its type, and a 64-bit size when the first one says 1.
            int need = track->boxFill >= 8 && track->box[0] == 0 && track->box[1] == 0 && track->box[2] == 0 && track->box[3] == 1 ? 16 : 8;
            int take = FFMIN(need - track->boxFill, size);
            memcpy(track->box + track->boxFill, bytes, take);
            track->boxFill += take; bytes += take; size -= take;
            if (track->boxFill < need) continue;
            if (need == 8 && track->box[0] == 0 && track->box[1] == 0 && track->box[2] == 0 && track->box[3] == 1) continue;
            uint64_t length = need == 16 ? AV_RB64(track->box + 8) : AV_RB32(track->box);
            track->boxPasses = header_box(track->box + 4) == track->keepHeader;
            if (track->boxPasses && cursor->write) cursor->write(cursor->context, track->index, track->box, need);
            track->boxLeft = length == 0 ? UINT64_MAX : (length > (uint64_t)need ? length - need : 0);
            track->boxFill = 0;
            continue;
        }
        int take = (int)FFMIN((uint64_t)size, track->boxLeft);
        if (track->boxPasses && cursor->write) cursor->write(cursor->context, track->index, bytes, take);
        if (track->boxLeft != UINT64_MAX) track->boxLeft -= take;
        bytes += take; size -= take;
    }
    return total;
}

static void free_mux(AVFormatContext **mux) {
    if (!*mux) return;
    if ((*mux)->pb) { av_freep(&(*mux)->pb->buffer); avio_context_free(&(*mux)->pb); }
    avformat_free_context(*mux);
    *mux = NULL;
}

/// A fragmented-MP4 writer for one track. Every segment's writer starts with the same ftyp and moov; only the
/// initialization segment keeps them. frag_discont makes each fragment's decode time the packet's own.
static int open_mux(Track *track, AVCodecContext *encoder, int keepHeader) {
    int delayed = track->delayed && !encoder;
    AVFormatContext *mux = NULL;
    int status = avformat_alloc_output_context2(&mux, NULL, "mp4", NULL);
    if (status < 0) return status;
    AVStream *st = avformat_new_stream(mux, NULL);
    if (!st) { free_mux(&mux); return AVERROR(ENOMEM); }
    status = encoder ? avcodec_parameters_from_context(st->codecpar, encoder) : avcodec_parameters_copy(st->codecpar, track->in->codecpar);
    if (status < 0) { free_mux(&mux); return status; }
    st->codecpar->codec_tag = 0;
    if (st->codecpar->codec_id == AV_CODEC_ID_HEVC)
        st->codecpar->codec_tag = track->spec.dolbyVision == TVMDolbyVisionDVH1 ? MKTAG('d', 'v', 'h', '1') : MKTAG('h', 'v', 'c', '1');
    if (encoder || track->spec.dolbyVision == TVMDolbyVisionDrop)
        av_packet_side_data_remove(st->codecpar->coded_side_data, &st->codecpar->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    st->time_base = track->outBase;
    if (track->type == AVMEDIA_TYPE_AUDIO && !st->codecpar->frame_size) {
        switch (st->codecpar->codec_id) {
        case AV_CODEC_ID_AAC: st->codecpar->frame_size = 1024; break;
        case AV_CODEC_ID_AC3: case AV_CODEC_ID_EAC3: st->codecpar->frame_size = 1536; break;
        case AV_CODEC_ID_MP3: st->codecpar->frame_size = 1152; break;
        default: break;
        }
    }
    if (track->type == AVMEDIA_TYPE_VIDEO) {
        st->avg_frame_rate = track->in->avg_frame_rate;
        if (!st->codecpar->sample_aspect_ratio.num) st->codecpar->sample_aspect_ratio = track->in->sample_aspect_ratio;
    }
    const int bufferSize = 64 << 10;
    uint8_t *buffer = av_malloc(bufferSize);
    mux->pb = buffer ? avio_alloc_context(buffer, bufferSize, 1, track, NULL, sink_write, NULL) : NULL;
    if (!mux->pb) { av_free(buffer); free_mux(&mux); return AVERROR(ENOMEM); }
    // Dolby Vision's dvcC box is "unofficial" to FFmpeg; Apple players read it.
    mux->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
    mux->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    AVDictionary *options = NULL;
    av_dict_set(&options, "movflags", delayed ? "frag_custom+delay_moov+default_base_moof+frag_discont+skip_trailer"
                                               : "frag_custom+empty_moov+default_base_moof+frag_discont+skip_trailer", 0);
    av_dict_set(&options, "use_editlist", "0", 0);
    track->keepHeader = keepHeader;
    track->boxFill = 0; track->boxLeft = 0; track->boxPasses = 0;
    status = avformat_write_header(mux, &options);
    av_dict_free(&options);
    if (status >= 0) avio_flush(mux->pb);
    if (status < 0) { free_mux(&mux); return status; }
    track->mux = mux;
    track->fragmentStart = track->lastDts = AV_NOPTS_VALUE;
    if (track->waiting) av_packet_unref(track->waiting);
    return 0;
}

static int emit(Track *track) {
    AVPacket *packet = track->waiting;
    if (!packet || !packet->data) return 0;
    if (track->fragmentStart == AV_NOPTS_VALUE) track->fragmentStart = packet->dts;
    else if (av_rescale_q(packet->dts - track->fragmentStart, track->outBase, AV_TIME_BASE_Q) >= FRAGMENT) {
        int status = av_write_frame(track->mux, NULL);
        if (status < 0) { av_packet_unref(packet); return status; }
        avio_flush(track->mux->pb);
        track->fragmentStart = packet->dts;
    }
    int status = av_write_frame(track->mux, packet);
    av_packet_unref(packet);
    return status;
}

static int close_mux(Track *track) {
    if (!track->mux) return 0;
    int status = emit(track);
    if (status >= 0) status = av_write_frame(track->mux, NULL);
    if (status >= 0) status = av_write_trailer(track->mux);
    avio_flush(track->mux->pb);
    free_mux(&track->mux);
    return status < 0 ? status : 0;
}

/// Writes a packet already on the output clock (before the offset), in fragments of about a second.
static int write_out(Track *track, AVPacket *packet) {
    if (!track->mux) return 0;
    if (packet->pts != AV_NOPTS_VALUE) packet->pts += track->outOffset;
    if (packet->dts != AV_NOPTS_VALUE) packet->dts += track->outOffset;
    if (packet->dts == AV_NOPTS_VALUE) packet->dts = packet->pts;
    if (packet->pts == AV_NOPTS_VALUE) packet->pts = packet->dts;
    if (packet->dts == AV_NOPTS_VALUE) return 0;
    if (track->lastDts != AV_NOPTS_VALUE && packet->dts <= track->lastDts) packet->dts = track->lastDts + 1;
    if (packet->pts < packet->dts) packet->pts = packet->dts;
    track->lastDts = packet->dts;
    packet->stream_index = 0;
    if (!track->waiting && !(track->waiting = av_packet_alloc())) return AVERROR(ENOMEM);
    if (track->waiting->data) track->waiting->duration = packet->dts - track->waiting->dts;
    int status = emit(track);
    if (status < 0) return status;
    return av_packet_ref(track->waiting, packet);
}

static AVBufferRef *hardware_device(Track *track) {
    if (!track->hwDevice) av_hwdevice_ctx_create(&track->hwDevice, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
    return track->hwDevice;
}

static enum AVPixelFormat hardware_format(AVCodecContext *decoder, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++)
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) return *format;
    return avcodec_default_get_format(decoder, formats);
}

/// The VideoToolbox frame pool the encoder takes tone-mapped pictures from: 8-bit 4:2:0 at its size.
static int hardware_frames(Track *track, int width, int height) {
    if (track->hwFrames) return 0;
    if (!hardware_device(track)) return AVERROR(ENOSYS);
    AVBufferRef *frames = av_hwframe_ctx_alloc(track->hwDevice);
    if (!frames) return AVERROR(ENOMEM);
    AVHWFramesContext *context = (AVHWFramesContext *)frames->data;
    context->format = AV_PIX_FMT_VIDEOTOOLBOX;
    context->sw_format = AV_PIX_FMT_NV12;
    context->width = width;
    context->height = height;
    int status = av_hwframe_ctx_init(frames);
    if (status >= 0 && !(track->uploaded = av_frame_alloc())) status = AVERROR(ENOMEM);
    if (status < 0) { av_buffer_unref(&frames); return status; }
    track->hwFrames = frames;
    return 0;
}

/// Shrinks a decoded HDR picture and maps it to SDR BT.709 (VideoToolbox's own tone mapping) into `out`.
static int transfer_picture(Track *track, const AVFrame *frame, AVFrame *out) {
    if (!track->transfer) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &track->transfer) != noErr) { track->transfer = NULL; return AVERROR_EXTERNAL; }
        VTSessionSetProperty(track->transfer, kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
        VTSessionSetProperty(track->transfer, kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
        VTSessionSetProperty(track->transfer, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    }
    CVPixelBufferRef source = (CVPixelBufferRef)frame->data[3], target = (CVPixelBufferRef)out->data[3];
    if (av_vt_pixbuf_set_attachments(NULL, source, frame) < 0 || av_vt_pixbuf_set_attachments(NULL, target, out) < 0) return AVERROR_EXTERNAL;
    OSStatus result = VTPixelTransferSessionTransferImage(track->transfer, source, target);
    if (result != noErr) av_log(NULL, AV_LOG_WARNING, "pixel transfer failed: %d\n", (int)result);
    return result == noErr ? 0 : AVERROR_EXTERNAL;
}

static int open_decoder(Track *track) {
    const AVCodec *codec = avcodec_find_decoder(track->in->codecpar->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    AVCodecContext *decoder = avcodec_alloc_context3(codec);
    if (!decoder) return AVERROR(ENOMEM);
    int status = avcodec_parameters_to_context(decoder, track->in->codecpar);
    if (status < 0) { avcodec_free_context(&decoder); return status; }
    decoder->pkt_timebase = track->in->time_base;
    decoder->thread_count = 0;
    decoder->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    // A picture tone mapped on the media engine is decoded there too; FFmpeg decodes it itself when it can't.
    if (track->spec.toneMap && hardware_device(track)) {
        decoder->hw_device_ctx = av_buffer_ref(track->hwDevice);
        decoder->get_format = hardware_format;
    }
    status = avcodec_open2(decoder, codec, NULL);
    if (status < 0) { avcodec_free_context(&decoder); return status; }
    track->decoder = decoder;
    return 0;
}

static int source_depth(const Track *track) {
    const AVPixFmtDescriptor *pixels = av_pix_fmt_desc_get(track->in->codecpar->format);
    return pixels ? pixels->comp[0].depth : 8;
}

static int open_video_encoder(Track *track, AVCodecContext **out) {
    const AVCodecParameters *par = track->in->codecpar;
    int hevc = track->spec.mode == TVMModeHEVC, deep = hevc && source_depth(track) > 8 && !track->spec.toneMap;
    const AVCodec *codec = avcodec_find_encoder_by_name(hevc ? "hevc_videotoolbox" : "h264_videotoolbox");
    if (!codec) return AVERROR_ENCODER_NOT_FOUND;
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    if (!encoder) return AVERROR(ENOMEM);
    encoder->width = track->spec.width > 0 ? track->spec.width : par->width;
    encoder->height = track->spec.height > 0 ? track->spec.height : par->height;
    // 8-bit 4:2:0 goes to VideoToolbox as it is; anything else is converted once, on the way in.
    encoder->pix_fmt = deep ? AV_PIX_FMT_P010LE : par->format == AV_PIX_FMT_YUV420P ? AV_PIX_FMT_YUV420P : AV_PIX_FMT_NV12;
    encoder->time_base = track->outBase;
    AVRational rate = track->in->avg_frame_rate.num && track->in->avg_frame_rate.den ? track->in->avg_frame_rate : track->in->r_frame_rate;
    if (rate.num && rate.den) encoder->framerate = rate;
    encoder->gop_size = rate.num && rate.den ? (int)(2 * av_q2d(rate) + 0.5) : 48;
    encoder->max_b_frames = 0;
    encoder->bit_rate = track->spec.bitRate > 0 ? track->spec.bitRate : 6000000;
    encoder->sample_aspect_ratio = par->sample_aspect_ratio.num ? par->sample_aspect_ratio : track->in->sample_aspect_ratio;
    encoder->color_range = par->color_range == AVCOL_RANGE_UNSPECIFIED ? AVCOL_RANGE_MPEG : par->color_range;
    encoder->color_primaries = par->color_primaries;
    encoder->color_trc = par->color_trc;
    encoder->colorspace = par->color_space;
    if (track->spec.toneMap) {
        encoder->color_range = AVCOL_RANGE_MPEG;
        encoder->color_primaries = AVCOL_PRI_BT709;
        encoder->color_trc = AVCOL_TRC_BT709;
        encoder->colorspace = AVCOL_SPC_BT709;
        // On the media engine the picture reaches the encoder as VideoToolbox frames; otherwise as above.
        if (hardware_frames(track, encoder->width, encoder->height) == 0) {
            encoder->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
            encoder->hw_frames_ctx = av_buffer_ref(track->hwFrames);
        }
    }
    encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    av_opt_set_int(encoder->priv_data, "allow_sw", 1, 0);
    av_opt_set_int(encoder->priv_data, "prio_speed", 1, 0);
    av_opt_set(encoder->priv_data, "profile", hevc ? (deep ? "main10" : "main") : "high", 0);
    int status = avcodec_open2(encoder, codec, NULL);
    if (status < 0) { avcodec_free_context(&encoder); return status; }
    *out = encoder;
    return 0;
}

static int audio_rate(const Track *track) {
    int rate = track->in->codecpar->sample_rate;
    return rate >= 8000 && rate <= 48000 ? rate : 48000;
}

static int open_audio_encoder(Track *track, AVCodecContext **out) {
    const AVCodec *codec = avcodec_find_encoder_by_name("aac_at");
    if (!codec) return AVERROR_ENCODER_NOT_FOUND;
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    if (!encoder) return AVERROR(ENOMEM);
    encoder->sample_rate = audio_rate(track);
    // AudioToolbox takes 5.1 with side surrounds, not FFmpeg's default 5.1 (back).
    if (track->spec.channels == 6) encoder->ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1;
    else av_channel_layout_default(&encoder->ch_layout, track->spec.channels == 1 ? 1 : 2);
    encoder->sample_fmt = AV_SAMPLE_FMT_S16;
    encoder->bit_rate = track->spec.bitRate > 0 ? track->spec.bitRate : 192000;
    encoder->time_base = (AVRational){1, encoder->sample_rate};
    encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    int status = avcodec_open2(encoder, codec, NULL);
    if (status < 0) { avcodec_free_context(&encoder); return status; }
    *out = encoder;
    return 0;
}

static void drop_held(Track *track) {
    for (int i = 0; i < track->heldCount; i++) av_frame_free(&track->held[i]);
    track->heldCount = 0;
}

static int hold(Track *track, const AVFrame *frame) {
    if (track->heldCount == track->heldCapacity) {
        int capacity = track->heldCapacity ? track->heldCapacity * 2 : 8;
        AVFrame **held = av_realloc_array(track->held, capacity, sizeof(AVFrame *));
        if (!held) return AVERROR(ENOMEM);
        track->held = held; track->heldCapacity = capacity;
    }
    AVFrame *copy = av_frame_clone(frame);
    if (!copy) return AVERROR(ENOMEM);
    track->held[track->heldCount++] = copy;
    return 0;
}

/// Forgets the reader's state after a seek: codecs restart and nothing carries over.
static void reset_track(Track *track) {
    track->started = track->ended = 0;
    if (track->decoder) avcodec_flush_buffers(track->decoder);
    if (track->type == AVMEDIA_TYPE_AUDIO) avcodec_free_context(&track->encoder);
    swr_free(&track->resampler);
    if (track->fifo) { av_audio_fifo_free(track->fifo); track->fifo = NULL; }
    drop_held(track);
    track->nextSample = AV_NOPTS_VALUE;
    track->fresh = 1;
    track->lastFramePts = AV_NOPTS_VALUE;
}

/// MPEG-TS carries AAC in ADTS frames and no configuration record, which an MP4 needs. FFmpeg's muxer would strip
/// the frame headers with a filter that fragmented output turns off, so the record is made from the stream's
/// parameters (what an ADTS header holds) and `copy_audio` drops each frame's header.
static void aac_configuration(AVCodecParameters *par) {
    static const int rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};
    int sbr = par->profile == AV_PROFILE_AAC_HE || par->profile == AV_PROFILE_AAC_HE_V2;
    int rate = sbr ? par->sample_rate / 2 : par->sample_rate, index = -1;
    for (int i = 0; i < 13; i++) if (rates[i] == rate) index = i;
    int channels = par->ch_layout.nb_channels;
    if (par->profile == AV_PROFILE_AAC_HE_V2 && channels == 2) channels = 1;
    if (channels == 8) channels = 7;
    int object = par->profile >= AV_PROFILE_AAC_MAIN && par->profile <= AV_PROFILE_AAC_LTP ? par->profile + 1 : 2;
    if (index < 0 || channels < 1 || channels > 7) return;
    uint8_t *record = av_mallocz(2 + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!record) return;
    record[0] = (uint8_t)(object << 3 | index >> 1);
    record[1] = (uint8_t)((index & 1) << 7 | channels << 3);
    par->extradata = record;
    par->extradata_size = 2;
}

static void strip_adts(AVPacket *packet) {
    if (packet->size < 7 || packet->data[0] != 0xFF || (packet->data[1] & 0xF6) != 0xF0) return;
    int header = packet->data[1] & 1 ? 7 : 9;
    if (packet->size <= header) return;
    packet->data += header;
    packet->size -= header;
}

TVMCursor *tvm_cursor_create(TVMInput *input, const TVMTrack *tracks, int count, int64_t offset) {
    if (count <= 0 || count > 64) return NULL;
    TVMCursor *cursor = av_mallocz(sizeof(TVMCursor));
    if (!cursor) return NULL;
    int streams = (int)input->format->nb_streams;
    cursor->input = input;
    cursor->tracks = av_calloc(count, sizeof(Track));
    cursor->trackOf = av_malloc_array(streams, sizeof(int));
    cursor->packet = av_packet_alloc();
    cursor->encoded = av_packet_alloc();
    cursor->frame = av_frame_alloc();
    if (!cursor->tracks || !cursor->trackOf || !cursor->packet || !cursor->encoded || !cursor->frame) { tvm_cursor_free(cursor); return NULL; }
    cursor->count = count;
    cursor->offset = offset;
    cursor->videoStream = -1;
    cursor->nextStart = INT64_MIN;
    cursor->untouched = 1;
    for (int i = 0; i < streams; i++) cursor->trackOf[i] = -1;
    for (int i = 0; i < count; i++) {
        Track *track = &cursor->tracks[i];
        track->owner = cursor;
        track->index = i;
        track->spec = tracks[i];
        if (tracks[i].stream < 0 || tracks[i].stream >= streams || cursor->trackOf[tracks[i].stream] >= 0) { tvm_cursor_free(cursor); return NULL; }
        track->in = input->format->streams[tracks[i].stream];
        track->type = track->in->codecpar->codec_type;
        cursor->trackOf[tracks[i].stream] = i;
        if (track->type == AVMEDIA_TYPE_VIDEO) {
            cursor->videoStream = tracks[i].stream;
            track->outBase = (AVRational){1, 90000};
        } else if (track->type == AVMEDIA_TYPE_AUDIO) {
            track->outBase = (AVRational){1, track->spec.mode == TVMModeAAC ? audio_rate(track) : (track->in->codecpar->sample_rate > 0 ? track->in->codecpar->sample_rate : 48000)};
        } else track->outBase = AV_TIME_BASE_Q;
        track->outOffset = av_rescale_q(offset, AV_TIME_BASE_Q, track->outBase);
        track->nextSample = track->lastFramePts = AV_NOPTS_VALUE;
        track->fresh = 1;
        AVCodecParameters *par = track->in->codecpar;
        enum AVCodecID codec = par->codec_id;
        if (track->spec.mode == TVMModeCopy && codec == AV_CODEC_ID_AAC && !par->extradata_size) aac_configuration(par);
        track->delayed = track->spec.mode == TVMModeCopy &&
            (codec == AV_CODEC_ID_AC3 || codec == AV_CODEC_ID_EAC3 || codec == AV_CODEC_ID_TRUEHD ||
             (!par->extradata_size && (codec == AV_CODEC_ID_AAC || codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC)));
    }
    // The demuxer skips what isn't written: other audio languages, cover art, fonts.
    for (int i = 0; i < streams; i++)
        input->format->streams[i]->discard = cursor->trackOf[i] >= 0 ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    return cursor;
}

static void clear_pending(TVMCursor *cursor) {
    for (int i = 0; i < cursor->pendingCount; i++)
        av_packet_free(&cursor->pending[(cursor->pendingHead + i) % cursor->pendingCapacity]);
    cursor->pendingHead = cursor->pendingCount = 0;
}

void tvm_cursor_free(TVMCursor *cursor) {
    if (!cursor) return;
    if (cursor->pending) clear_pending(cursor);
    av_free(cursor->pending);
    for (int i = 0; cursor->tracks && i < cursor->count; i++) {
        Track *track = &cursor->tracks[i];
        free_mux(&track->mux);
        avcodec_free_context(&track->decoder);
        avcodec_free_context(&track->encoder);
        swr_free(&track->resampler);
        av_channel_layout_uninit(&track->resamplerLayout);
        if (track->fifo) av_audio_fifo_free(track->fifo);
        sws_freeContext(track->scaler);
        av_frame_free(&track->scaled);
        sws_freeContext(track->shrinker);
        av_frame_free(&track->shrunk);
        av_frame_free(&track->uploaded);
        av_frame_free(&track->downloaded);
        if (track->transfer) { VTPixelTransferSessionInvalidate(track->transfer); CFRelease(track->transfer); }
        av_buffer_unref(&track->hwFrames);
        av_buffer_unref(&track->hwDevice);
        drop_held(track);
        av_free(track->held);
        av_packet_free(&track->sample);
        av_packet_free(&track->waiting);
    }
    av_free(cursor->tracks);
    av_free(cursor->trackOf);
    av_packet_free(&cursor->packet);
    av_packet_free(&cursor->encoded);
    av_frame_free(&cursor->frame);
    av_free(cursor);
}

/// Moves the packet's data to the end of the queue the next segment reads first.
static int push_pending(TVMCursor *cursor, AVPacket *packet) {
    if (cursor->pendingCount == cursor->pendingCapacity) {
        int capacity = cursor->pendingCapacity ? cursor->pendingCapacity * 2 : 64;
        AVPacket **queue = av_malloc_array(capacity, sizeof(AVPacket *));
        if (!queue) return AVERROR(ENOMEM);
        for (int i = 0; i < cursor->pendingCount; i++)
            queue[i] = cursor->pending[(cursor->pendingHead + i) % cursor->pendingCapacity];
        av_free(cursor->pending);
        cursor->pending = queue; cursor->pendingCapacity = capacity; cursor->pendingHead = 0;
    }
    AVPacket *copy = av_packet_alloc();
    if (!copy) return AVERROR(ENOMEM);
    av_packet_move_ref(copy, packet);
    cursor->pending[(cursor->pendingHead + cursor->pendingCount) % cursor->pendingCapacity] = copy;
    cursor->pendingCount++;
    return 0;
}

static AVPacket *pop_pending(TVMCursor *cursor) {
    if (!cursor->pendingCount) return NULL;
    AVPacket *packet = cursor->pending[cursor->pendingHead];
    cursor->pendingHead = (cursor->pendingHead + 1) % cursor->pendingCapacity;
    cursor->pendingCount--;
    return packet;
}

// MARK: Audio

static int encode_audio(TVMCursor *cursor, Track *track, AVFrame *frame) {
    int status = avcodec_send_frame(track->encoder, frame);
    if (status < 0 && status != AVERROR_EOF) return status;
    while ((status = avcodec_receive_packet(track->encoder, cursor->encoded)) >= 0) {
        AVPacket *packet = cursor->encoded;
        // The encoder times its packets back by its delay (FFmpeg's frame queue), so a restarted one begins
        // with priming before the segment's start, which was played already.
        if (track->fresh && packet->pts != AV_NOPTS_VALUE &&
            av_rescale_q(packet->pts + packet->duration, track->outBase, AV_TIME_BASE_Q) <= cursor->start) {
            av_packet_unref(packet);
            continue;
        }
        track->fresh = 0;
        status = write_out(track, packet);
        av_packet_unref(packet);
        if (status < 0) return status;
    }
    return status == AVERROR(EAGAIN) || status == AVERROR_EOF ? 0 : status;
}

static int drain_audio(TVMCursor *cursor, Track *track, int final) {
    AVCodecContext *encoder = track->encoder;
    if (!encoder || !track->fifo) return 0;
    while (av_audio_fifo_size(track->fifo) >= encoder->frame_size || (final && av_audio_fifo_size(track->fifo) > 0)) {
        AVFrame *frame = av_frame_alloc();
        if (!frame) return AVERROR(ENOMEM);
        frame->nb_samples = encoder->frame_size;
        frame->format = encoder->sample_fmt;
        frame->sample_rate = encoder->sample_rate;
        av_channel_layout_copy(&frame->ch_layout, &encoder->ch_layout);
        int status = av_frame_get_buffer(frame, 0);
        if (status < 0) { av_frame_free(&frame); return status; }
        int got = av_audio_fifo_read(track->fifo, (void **)frame->data, encoder->frame_size);
        if (got < encoder->frame_size)
            av_samples_set_silence(frame->data, got, encoder->frame_size - got, encoder->ch_layout.nb_channels, encoder->sample_fmt);
        frame->pts = track->nextSample;
        track->nextSample += encoder->frame_size;
        status = encode_audio(cursor, track, frame);
        av_frame_free(&frame);
        if (status < 0) return status;
    }
    return final ? encode_audio(cursor, track, NULL) : 0;
}

static int feed_audio(TVMCursor *cursor, Track *track, AVFrame *frame) {
    int status;
    if (!track->encoder && (status = open_audio_encoder(track, &track->encoder)) < 0) return status;
    AVCodecContext *encoder = track->encoder;
    if (track->resampler && (frame->format != track->resamplerFormat || frame->sample_rate != track->resamplerRate ||
                             av_channel_layout_compare(&frame->ch_layout, &track->resamplerLayout)))
        swr_free(&track->resampler);
    if (!track->resampler) {
        // More than two channels become 5.1 (DTS and TrueHD 7.1 fold their back channels in); fewer stay.
        status = swr_alloc_set_opts2(&track->resampler, &encoder->ch_layout, encoder->sample_fmt, encoder->sample_rate,
                                     &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL);
        if (status < 0 || (status = swr_init(track->resampler)) < 0) { swr_free(&track->resampler); return status; }
        track->resamplerFormat = frame->format;
        track->resamplerRate = frame->sample_rate;
        av_channel_layout_uninit(&track->resamplerLayout);
        av_channel_layout_copy(&track->resamplerLayout, &frame->ch_layout);
    }
    if (!track->fifo && !(track->fifo = av_audio_fifo_alloc(encoder->sample_fmt, encoder->ch_layout.nb_channels, encoder->frame_size * 4)))
        return AVERROR(ENOMEM);
    if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
        int64_t at = av_rescale_q(frame->best_effort_timestamp, track->in->time_base, track->outBase);
        int64_t expected = track->nextSample == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : track->nextSample + av_audio_fifo_size(track->fifo);
        // The first frame, or a jump in the file's clock: samples count on from here.
        if (expected == AV_NOPTS_VALUE || llabs(at - expected) > encoder->sample_rate / 5) {
            av_audio_fifo_reset(track->fifo);
            track->nextSample = at;
        }
    } else if (track->nextSample == AV_NOPTS_VALUE) return 0;
    int capacity = swr_get_out_samples(track->resampler, frame->nb_samples);
    if (capacity <= 0) return 0;
    uint8_t **samples = NULL;
    status = av_samples_alloc_array_and_samples(&samples, NULL, encoder->ch_layout.nb_channels, capacity, encoder->sample_fmt, 0);
    if (status < 0) return status;
    int converted = swr_convert(track->resampler, samples, capacity, (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (converted > 0) av_audio_fifo_write(track->fifo, (void **)samples, converted);
    av_freep(&samples[0]);
    av_freep(&samples);
    if (converted < 0) return converted;
    return drain_audio(cursor, track, 0);
}

static int convert_audio(TVMCursor *cursor, Track *track, AVPacket *packet) {
    int status;
    if (!track->decoder && (status = open_decoder(track)) < 0) return status;
    status = avcodec_send_packet(track->decoder, packet);
    // A damaged packet is skipped, like a player would.
    if (status < 0 && status != AVERROR(EAGAIN) && status != AVERROR_EOF) return 0;
    while ((status = avcodec_receive_frame(track->decoder, cursor->frame)) >= 0) {
        status = feed_audio(cursor, track, cursor->frame);
        av_frame_unref(cursor->frame);
        if (status < 0) return status;
    }
    if (!packet) return drain_audio(cursor, track, 1);
    return status == AVERROR(EAGAIN) || status == AVERROR_EOF ? 0 : status;
}

/// Copied audio is retimed by its sample count: Matroska's millisecond clock would otherwise make every
/// frame's duration jitter.
static int copy_audio(Track *track, AVPacket *packet) {
    if (track->in->codecpar->codec_id == AV_CODEC_ID_AAC) strip_adts(packet);
    av_packet_rescale_ts(packet, track->in->time_base, track->outBase);
    int64_t samples = packet->duration > 0 ? packet->duration : av_get_audio_frame_duration2(track->in->codecpar, packet->size);
    if (packet->pts == AV_NOPTS_VALUE) packet->pts = packet->dts;
    if (track->nextSample != AV_NOPTS_VALUE &&
        (packet->pts == AV_NOPTS_VALUE || llabs(packet->pts - track->nextSample) <= track->outBase.den / 50))
        packet->pts = track->nextSample;
    if (packet->pts == AV_NOPTS_VALUE) return 0;
    packet->dts = packet->pts;
    if (samples > 0) packet->duration = samples;
    track->nextSample = packet->pts + (samples > 0 ? samples : 0);
    return write_out(track, packet);
}

// MARK: Video

static int receive_video(TVMCursor *cursor, Track *track) {
    int status;
    while ((status = avcodec_receive_packet(track->encoder, cursor->encoded)) >= 0) {
        status = write_out(track, cursor->encoded);
        av_packet_unref(cursor->encoded);
        if (status < 0) return status;
    }
    return status == AVERROR(EAGAIN) || status == AVERROR_EOF ? 0 : status;
}

/// HDR to SDR in software, into `track->scaled`.
static int tone_map_software(Track *track, const AVFrame *frame, enum AVPixelFormat format, int width, int height) {
    int status;
    // HDR to SDR: swscale's color management maps PQ or HLG BT.2020 to BT.709 (perceptual tone mapping, from
    // the frame's own mastering metadata) on the way to the encoder's 8-bit format.
    const AVFrame *source = frame;
    if (frame->width != width || frame->height != height) {
        if (!track->shrinker) {
            if (!(track->shrinker = sws_alloc_context())) return AVERROR(ENOMEM);
            track->shrinker->flags = SWS_BILINEAR;
            track->shrinker->threads = 0;
        }
        if (!track->shrunk) {
            if (!(track->shrunk = av_frame_alloc())) return AVERROR(ENOMEM);
            track->shrunk->format = frame->format;
            track->shrunk->width = width;
            track->shrunk->height = height;
            if ((status = av_frame_get_buffer(track->shrunk, 0)) < 0) return status;
        }
        if ((status = av_frame_make_writable(track->shrunk)) < 0) return status;
        // Same colors and metadata (the mastering display the tone mapping reads), smaller picture.
        if ((status = av_frame_copy_props(track->shrunk, frame)) < 0) return status;
        if ((status = sws_scale_frame(track->shrinker, track->shrunk, frame)) < 0) return status;
        source = track->shrunk;
    }
    if (!track->scaler) {
        if (!(track->scaler = sws_alloc_context())) return AVERROR(ENOMEM);
        track->scaler->flags = SWS_BILINEAR;
        track->scaler->intent = SWS_INTENT_PERCEPTUAL;
        track->scaler->threads = 0;
    }
    if (!track->scaled) {
        if (!(track->scaled = av_frame_alloc())) return AVERROR(ENOMEM);
        track->scaled->format = format;
        track->scaled->width = width;
        track->scaled->height = height;
        if ((status = av_frame_get_buffer(track->scaled, 0)) < 0) return status;
    }
    if ((status = av_frame_make_writable(track->scaled)) < 0) return status;
    track->scaled->color_range = AVCOL_RANGE_MPEG;
    track->scaled->color_primaries = AVCOL_PRI_BT709;
    track->scaled->color_trc = AVCOL_TRC_BT709;
    track->scaled->colorspace = AVCOL_SPC_BT709;
    track->scaled->sample_aspect_ratio = frame->sample_aspect_ratio;
    if ((status = sws_scale_frame(track->scaler, track->scaled, source)) < 0) return status;
    return 0;
}

static int encode_video(TVMCursor *cursor, Track *track, AVFrame *frame) {
    int status;
    if (!track->encoder) {
        if ((status = open_video_encoder(track, &track->encoder)) < 0) return status;
        track->firstFrame = 1;
        track->lastFramePts = AV_NOPTS_VALUE;
    }
    AVCodecContext *encoder = track->encoder;
    AVFrame *input = frame;
    if (track->spec.toneMap) {
        if (track->hwFrames) {
            av_frame_unref(track->uploaded);
            if ((status = av_hwframe_get_buffer(track->hwFrames, track->uploaded, 0)) < 0) return status;
            track->uploaded->color_range = AVCOL_RANGE_MPEG;
            track->uploaded->color_primaries = AVCOL_PRI_BT709;
            track->uploaded->color_trc = AVCOL_TRC_BT709;
            track->uploaded->colorspace = AVCOL_SPC_BT709;
            track->uploaded->sample_aspect_ratio = frame->sample_aspect_ratio;
            input = track->uploaded;
        }
        if (!(track->hwFrames && frame->format == AV_PIX_FMT_VIDEOTOOLBOX && transfer_picture(track, frame, track->uploaded) == 0)) {
            const AVFrame *source = frame;
            if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                if (!track->downloaded && !(track->downloaded = av_frame_alloc())) return AVERROR(ENOMEM);
                av_frame_unref(track->downloaded);
                if ((status = av_hwframe_transfer_data(track->downloaded, frame, 0)) < 0) return status;
                if ((status = av_frame_copy_props(track->downloaded, frame)) < 0) return status;
                source = track->downloaded;
            }
            if ((status = tone_map_software(track, source, track->hwFrames ? AV_PIX_FMT_NV12 : encoder->pix_fmt, encoder->width, encoder->height)) < 0) return status;
            if (track->hwFrames) { if ((status = av_hwframe_transfer_data(track->uploaded, track->scaled, 0)) < 0) return status; }
            else input = track->scaled;
        }
    } else if (frame->format != encoder->pix_fmt || frame->width != encoder->width || frame->height != encoder->height) {
        track->scaler = sws_getCachedContext(track->scaler, frame->width, frame->height, frame->format,
                                             encoder->width, encoder->height, encoder->pix_fmt, SWS_BILINEAR, NULL, NULL, NULL);
        if (!track->scaler) return AVERROR(EINVAL);
        if (!track->scaled) {
            track->scaled = av_frame_alloc();
            if (!track->scaled) return AVERROR(ENOMEM);
            track->scaled->format = encoder->pix_fmt;
            track->scaled->width = encoder->width;
            track->scaled->height = encoder->height;
            if ((status = av_frame_get_buffer(track->scaled, 0)) < 0) return status;
        }
        if ((status = av_frame_make_writable(track->scaled)) < 0) return status;
        sws_scale(track->scaler, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height,
                  track->scaled->data, track->scaled->linesize);
        av_frame_copy_props(track->scaled, frame);
        input = track->scaled;
    }
    int64_t pts = av_rescale_q(frame->best_effort_timestamp, track->in->time_base, encoder->time_base);
    if (track->lastFramePts != AV_NOPTS_VALUE && pts <= track->lastFramePts) pts = track->lastFramePts + 1;
    track->lastFramePts = pts;
    input->pts = pts;
    input->duration = frame->duration > 0 ? av_rescale_q(frame->duration, track->in->time_base, encoder->time_base) : 0;
    // Every segment opens with a keyframe of its own.
    input->pict_type = track->firstFrame ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
    track->firstFrame = 0;
    if ((status = avcodec_send_frame(encoder, input)) < 0) return status;
    return receive_video(cursor, track);
}

static int take_frame(TVMCursor *cursor, Track *track, AVFrame *frame) {
    if (frame->best_effort_timestamp == AV_NOPTS_VALUE) return 0;
    int64_t time = av_rescale_q(frame->best_effort_timestamp, track->in->time_base, AV_TIME_BASE_Q);
    if (time < cursor->start - TOLERANCE) return 0;
    if (cursor->end >= 0 && time >= cursor->end - TOLERANCE) {
        track->ended = 1;
        return hold(track, frame);
    }
    return encode_video(cursor, track, frame);
}

static int convert_video(TVMCursor *cursor, Track *track, AVPacket *packet) {
    int status;
    if (!track->decoder && (status = open_decoder(track)) < 0) return status;
    status = avcodec_send_packet(track->decoder, packet);
    if (status < 0 && status != AVERROR(EAGAIN) && status != AVERROR_EOF) return 0;
    while ((status = avcodec_receive_frame(track->decoder, cursor->frame)) >= 0) {
        status = take_frame(cursor, track, cursor->frame);
        av_frame_unref(cursor->frame);
        if (status < 0) return status;
    }
    return status == AVERROR(EAGAIN) || status == AVERROR_EOF ? 0 : status;
}

static int finish_video(TVMCursor *cursor, Track *track) {
    if (!track->encoder) return 0;
    int status = avcodec_send_frame(track->encoder, NULL);
    if (status >= 0) status = receive_video(cursor, track);
    avcodec_free_context(&track->encoder);
    return status;
}

// MARK: Segments

/// The decode time of the next copied video packet in decode order: packet i decodes at the (i - reorder)-th
/// smallest presentation time, which no later packet can undercut; the first ones count back from the segment's
/// keyframe one frame at a time. Never earlier than the previous packet's.
static int64_t decode_time(Track *track, int64_t pts) {
    int count = track->windowCount, at = count;
    while (at > 0 && track->window[at - 1] > pts) { track->window[at] = track->window[at - 1]; at--; }
    track->window[at] = pts;
    track->windowCount = ++count;
    int64_t dts;
    if (count > track->reorder) {
        dts = track->window[0];
        memmove(track->window, track->window + 1, (count - 1) * sizeof(int64_t));
        track->windowCount--;
    } else dts = track->window[0] - (int64_t)(track->reorder - track->decoded) * track->frameDuration;
    track->decoded++;
    if (track->lastDts != AV_NOPTS_VALUE && dts + track->outOffset <= track->lastDts) dts = track->lastDts - track->outOffset + 1;
    return dts;
}

static int64_t packet_time(const Track *track, const AVPacket *packet) {
    int64_t value = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    return value == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(value, track->in->time_base, AV_TIME_BASE_Q);
}

/// Sends a packet where it belongs: this segment's output, the queue for the next one, or nowhere.
/// The packet is left empty either way.
static int route(TVMCursor *cursor, AVPacket *packet) {
    int index = packet->stream_index < (int)cursor->input->format->nb_streams ? cursor->trackOf[packet->stream_index] : -1;
    if (index < 0) { av_packet_unref(packet); return 0; }
    Track *track = &cursor->tracks[index];
    int64_t time = packet_time(track, packet);
    if (time != AV_NOPTS_VALUE && time > cursor->readPosition) cursor->readPosition = time;
    int past = cursor->end >= 0 && time != AV_NOPTS_VALUE && time >= cursor->end;
    int status = 0;
    if (!cursor->active[index] || track->type == AVMEDIA_TYPE_SUBTITLE) {
        if (past) return push_pending(cursor, packet);
        if (cursor->active[index] && time != AV_NOPTS_VALUE && time >= cursor->start - TOLERANCE && cursor->cue) {
            int64_t length = packet->duration > 0 ? av_rescale_q(packet->duration, track->in->time_base, AV_TIME_BASE_Q) : -1;
            cursor->cue(cursor->context, index, time, length >= 0 ? time + length : -1, packet->data, packet->size);
        }
        // An inactive converted video track restarts at a keyframe when it is wanted again.
        if (!cursor->active[index]) track->started = 0;
        av_packet_unref(packet);
        return 0;
    }
    if (track->ended) return push_pending(cursor, packet);
    if (track->type == AVMEDIA_TYPE_VIDEO) {
        int key = (packet->flags & AV_PKT_FLAG_KEY) != 0;
        if (track->spec.mode == TVMModeCopy) {
            if (!track->started) {
                if (!key || time == AV_NOPTS_VALUE || time < cursor->start - TOLERANCE) { av_packet_unref(packet); return 0; }
                if (cursor->end >= 0 && time >= cursor->end - TOLERANCE) {
                    // No keyframe in the whole segment (a long GOP in a file without an index): it shows the
                    // next one, which also begins the next segment, rather than coming out empty.
                    track->ended = 1;
                    AVPacket *frame = av_packet_clone(packet);
                    if (!frame) { av_packet_unref(packet); return AVERROR(ENOMEM); }
                    av_packet_rescale_ts(frame, track->in->time_base, track->outBase);
                    if (frame->pts != AV_NOPTS_VALUE) frame->dts = decode_time(track, frame->pts);
                    status = write_out(track, frame);
                    av_packet_free(&frame);
                    if (status < 0) { av_packet_unref(packet); return status; }
                    return push_pending(cursor, packet);
                }
                track->started = 1;
            } else if (key && cursor->end >= 0 && time != AV_NOPTS_VALUE && time >= cursor->end - TOLERANCE) {
                track->ended = 1;
                return push_pending(cursor, packet);
            }
            av_packet_rescale_ts(packet, track->in->time_base, track->outBase);
            if (packet->pts != AV_NOPTS_VALUE) packet->dts = decode_time(track, packet->pts);
            status = write_out(track, packet);
        } else {
            if (!track->started) {
                if (!key) { av_packet_unref(packet); return 0; }
                if (track->decoder) avcodec_flush_buffers(track->decoder);
                track->started = 1;
            }
            status = convert_video(cursor, track, packet);
        }
    } else if (track->type == AVMEDIA_TYPE_AUDIO) {
        if (past) { track->ended = 1; return push_pending(cursor, packet); }
        if (time != AV_NOPTS_VALUE && time < cursor->start) { av_packet_unref(packet); return 0; }
        track->started = 1;
        status = track->spec.mode == TVMModeCopy ? copy_audio(track, packet) : convert_audio(cursor, track, packet);
    }
    av_packet_unref(packet);
    return status;
}

/// Whether every active track has reached the segment's end. Subtitles have no packet at each boundary:
/// theirs is reached once the reader is past it.
static int finished(TVMCursor *cursor) {
    if (cursor->end < 0) return 0;
    int reached = cursor->readPosition != INT64_MIN && cursor->readPosition >= cursor->end;
    for (int i = 0; i < cursor->count; i++) {
        Track *track = &cursor->tracks[i];
        if (!cursor->active[i] || track->ended) continue;
        if (track->type == AVMEDIA_TYPE_SUBTITLE) { if (!reached) return 0; continue; }
        // A track can pause (an audio gap, or audio that stops early): don't read on forever for it.
        // Copied video that has begun must reach its next keyframe, or the next segment would lose the frames between.
        int64_t wait = track->type == AVMEDIA_TYPE_VIDEO && track->spec.mode == TVMModeCopy && track->started ? MAXGOP : LOOKAHEAD;
        if (cursor->readPosition != INT64_MIN && cursor->readPosition >= cursor->end + wait) continue;
        return 0;
    }
    return 1;
}

static int64_t indexed_until(AVStream *st) {
    int count = avformat_index_get_entries_count(st);
    const AVIndexEntry *entry = count > 0 ? avformat_index_get_entry(st, count - 1) : NULL;
    return entry ? av_rescale_q(entry->timestamp, st->time_base, AV_TIME_BASE_Q) : INT64_MIN;
}

/// Without an index that reaches the time, FFmpeg would read every packet up to it (a whole download for a
/// remote FLV). A byte position from the average bit rate, corrected until the reader lands a little before
/// the time, costs a few short reads. MPEG streams search by timestamp on their own.
static int seek_by_bytes(TVMCursor *cursor, int64_t start) {
    AVFormatContext *format = cursor->input->format;
    int64_t size = cursor->input->size, duration = format->duration;
    const char *name = format->iformat->name;
    if (size <= 0 || duration <= 0 || !strcmp(name, "mpegts") || !strcmp(name, "mpeg")) return AVERROR(ENOSYS);
    if (cursor->videoStream < 0 || start <= indexed_until(format->streams[cursor->videoStream]) + UNINDEXED) return AVERROR(ENOSYS);
    int64_t first = format->start_time == AV_NOPTS_VALUE ? 0 : format->start_time;
    int64_t target = start - 15000000;
    for (int attempt = 0; attempt < 6; attempt++) {
        int64_t position = av_rescale(FFMAX(target - first, 0), size, duration);
        int status = av_seek_frame(format, -1, FFMIN(position, size - 1), AVSEEK_FLAG_BYTE);
        if (status < 0) return status;
        int64_t time = AV_NOPTS_VALUE;
        for (int read = 0; read < 2000 && time == AV_NOPTS_VALUE; read++) {
            if ((status = av_read_frame(format, cursor->packet)) < 0) return status;
            int index = cursor->packet->stream_index < (int)format->nb_streams ? cursor->trackOf[cursor->packet->stream_index] : -1;
            if (index >= 0) time = packet_time(&cursor->tracks[index], cursor->packet);
            if (time == AV_NOPTS_VALUE) av_packet_unref(cursor->packet);
        }
        if (time == AV_NOPTS_VALUE) return AVERROR_INVALIDDATA;
        // Landed after the time, or far before it: move by the miss, and a margin when too late.
        if ((time > start || time < start - 60000000) && position > 0 && attempt < 5) {
            av_packet_unref(cursor->packet);
            target -= time > start ? time - start + 15000000 : time - (start - 15000000);
            continue;
        }
        return push_pending(cursor, cursor->packet);
    }
    return AVERROR(ENOSYS);
}

static int reposition(TVMCursor *cursor, int64_t start) {
    clear_pending(cursor);
    for (int i = 0; i < cursor->count; i++) reset_track(&cursor->tracks[i]);
    cursor->eof = 0;
    AVFormatContext *format = cursor->input->format;
    // The first segment starts where the reader already is: nothing to seek.
    int64_t first = format->start_time == AV_NOPTS_VALUE ? 0 : format->start_time;
    if (cursor->untouched && start <= first + 500000) return 0;
    int status = seek_by_bytes(cursor, start);
    if (status >= 0) return status;
    clear_pending(cursor);
    if (cursor->videoStream >= 0) {
        AVStream *st = format->streams[cursor->videoStream];
        status = av_seek_frame(format, cursor->videoStream, av_rescale_q(start + TOLERANCE, AV_TIME_BASE_Q, st->time_base), AVSEEK_FLAG_BACKWARD);
    } else status = av_seek_frame(format, -1, start + TOLERANCE, AVSEEK_FLAG_BACKWARD);
    if (status < 0) status = avformat_seek_file(format, -1, INT64_MIN, start, start, 0);
    if (status < 0 && start <= first + 500000) status = avformat_seek_file(format, -1, INT64_MIN, INT64_MIN, INT64_MAX, AVSEEK_FLAG_BYTE);
    return status;
}

/// Reads from the start to the track's first packet. The reader is left there, so the next segment seeks.
static int load_sample(TVMCursor *cursor, Track *track) {
    if (track->sample) return 0;
    AVFormatContext *format = cursor->input->format;
    clear_pending(cursor);
    cursor->nextStart = INT64_MIN;
    cursor->untouched = 0;
    int status = avformat_seek_file(format, -1, INT64_MIN, format->start_time == AV_NOPTS_VALUE ? 0 : format->start_time, INT64_MAX, 0);
    if (status < 0) status = av_seek_frame(format, -1, 0, AVSEEK_FLAG_BYTE);
    if (status < 0) return status;
    for (int read = 0; read < 10000; read++) {
        if ((status = av_read_frame(format, cursor->packet)) < 0) return status;
        if (cursor->packet->stream_index == track->in->index && cursor->packet->size > 0) {
            track->sample = av_packet_alloc();
            if (!track->sample) { av_packet_unref(cursor->packet); return AVERROR(ENOMEM); }
            av_packet_move_ref(track->sample, cursor->packet);
            return 0;
        }
        av_packet_unref(cursor->packet);
    }
    return AVERROR_STREAM_NOT_FOUND;
}

int tvm_cursor_init(TVMCursor *cursor, int index, void *context, TVMWriteFunction write, char *error, int errorSize) {
    if (index < 0 || index >= cursor->count) return fail(error, errorSize, AVERROR(EINVAL), "init");
    Track *track = &cursor->tracks[index];
    if (track->type != AVMEDIA_TYPE_VIDEO && track->type != AVMEDIA_TYPE_AUDIO) return fail(error, errorSize, AVERROR(EINVAL), "init");
    AVCodecContext *encoder = NULL;
    int status = 0;
    if (track->spec.mode == TVMModeAAC) status = open_audio_encoder(track, &encoder);
    else if (track->spec.mode == TVMModeH264 || track->spec.mode == TVMModeHEVC) status = open_video_encoder(track, &encoder);
    if (status < 0) return fail(error, errorSize, status, "encoder");
    if (track->delayed && !encoder && (status = load_sample(cursor, track)) < 0) return fail(error, errorSize, status, "first packet");
    cursor->context = context;
    cursor->write = write;
    AVFormatContext *saved = track->mux;
    int64_t fragmentStart = track->fragmentStart, lastDts = track->lastDts, nextSample = track->nextSample;
    track->mux = NULL;
    status = open_mux(track, encoder, 1);
    if (status >= 0 && track->delayed && !encoder) {
        // The moov comes out with the first fragment; the box filter keeps it and drops the fragment.
        AVPacket *packet = av_packet_clone(track->sample);
        if (!packet) status = AVERROR(ENOMEM);
        else {
            av_packet_rescale_ts(packet, track->in->time_base, track->outBase);
            if (packet->dts == AV_NOPTS_VALUE) packet->dts = packet->pts;
            status = write_out(track, packet);
            av_packet_free(&packet);
        }
        if (status >= 0) status = close_mux(track);
    }
    if (track->mux) { avio_flush(track->mux->pb); free_mux(&track->mux); }
    track->mux = saved;
    track->fragmentStart = fragmentStart; track->lastDts = lastDts; track->nextSample = nextSample;
    avcodec_free_context(&encoder);
    cursor->write = NULL;
    return status < 0 ? fail(error, errorSize, status, "header") : 0;
}

int tvm_cursor_segment(TVMCursor *cursor, int64_t start, int64_t end, const uint8_t *active, void *context,
                       TVMWriteFunction write, TVMCueFunction cue, char *error, int errorSize) {
    cursor->context = context; cursor->write = write; cursor->cue = cue; cursor->active = active;
    cursor->start = start; cursor->end = end;
    cursor->readPosition = INT64_MIN;
    int status = 0;
    if (cursor->nextStart == INT64_MIN || start != cursor->nextStart) {
        if ((status = reposition(cursor, start)) < 0) { fail(error, errorSize, status, "seek"); goto done; }
    } else {
        // Going on from the previous segment: its packets and frames past the end begin this one.
        for (int i = 0; i < cursor->count; i++) {
            Track *track = &cursor->tracks[i];
            track->ended = 0;
            if (track->type == AVMEDIA_TYPE_VIDEO && track->spec.mode == TVMModeCopy) track->started = 0;
        }
    }
    cursor->untouched = 0;
    for (int i = 0; i < cursor->count; i++) {
        Track *track = &cursor->tracks[i];
        if (!active[i] || (track->type != AVMEDIA_TYPE_VIDEO && track->type != AVMEDIA_TYPE_AUDIO)) continue;
        // A converted track's writer takes its parameters from the encoder: audio keeps one across
        // segments (its priming would otherwise gap every segment), video opens one per segment.
        if (track->spec.mode == TVMModeAAC && !track->encoder) status = open_audio_encoder(track, &track->encoder);
        else if (track->type == AVMEDIA_TYPE_VIDEO && track->spec.mode != TVMModeCopy) {
            avcodec_free_context(&track->encoder);
            status = open_video_encoder(track, &track->encoder);
            track->firstFrame = 1;
            track->lastFramePts = AV_NOPTS_VALUE;
        }
        if (status >= 0) status = open_mux(track, track->spec.mode == TVMModeCopy ? NULL : track->encoder, 0);
        if (status < 0) { fail(error, errorSize, status, "writer"); goto done; }
        if (track->type == AVMEDIA_TYPE_VIDEO && track->spec.mode == TVMModeCopy) {
            // One frame more than the stream says it reorders: a later decode time costs nothing.
            track->reorder = FFMIN(16, FFMAX(track->in->codecpar->video_delay, 0) + 1);
            AVRational rate = track->in->avg_frame_rate.num && track->in->avg_frame_rate.den ? track->in->avg_frame_rate : track->in->r_frame_rate;
            track->frameDuration = rate.num && rate.den ? av_rescale_q(1, av_inv_q(rate), track->outBase) : track->outBase.den / 24;
            track->windowCount = track->decoded = 0;
        }
    }
    // Converted frames decoded past the previous segment's end begin this one.
    for (int i = 0; i < cursor->count; i++) {
        Track *track = &cursor->tracks[i];
        if (!active[i] || track->type != AVMEDIA_TYPE_VIDEO || track->spec.mode == TVMModeCopy || !track->heldCount) continue;
        int count = track->heldCount;
        AVFrame **frames = av_malloc_array(count, sizeof(AVFrame *));
        if (!frames) { status = fail(error, errorSize, AVERROR(ENOMEM), "video"); goto done; }
        memcpy(frames, track->held, count * sizeof(AVFrame *));
        track->heldCount = 0;
        for (int j = 0; j < count; j++) {
            if (status >= 0) status = take_frame(cursor, track, frames[j]);
            av_frame_free(&frames[j]);
        }
        av_free(frames);
        if (status < 0) { fail(error, errorSize, status, "video"); goto done; }
    }
    // Only what the previous segment queued is replayed; what this one queues is for the next.
    int replay = cursor->pendingCount;
    while (!finished(cursor)) {
        AVPacket *queued = replay > 0 ? (replay--, pop_pending(cursor)) : NULL;
        if (!queued) {
            if (cursor->eof) break;
            status = av_read_frame(cursor->input->format, cursor->packet);
            if (status == AVERROR_EOF) { cursor->eof = 1; status = 0; break; }
            if (status < 0) { fail(error, errorSize, status, "read"); goto done; }
        }
        status = route(cursor, queued ? queued : cursor->packet);
        av_packet_free(&queued);
        if (status < 0) { fail(error, errorSize, status, "write"); goto done; }
    }
    if (cursor->eof && !cursor->pendingCount) {
        // The end of the file: what the converters still hold belongs to this, the last segment.
        for (int i = 0; i < cursor->count; i++) {
            Track *track = &cursor->tracks[i];
            if (!active[i] || track->spec.mode == TVMModeCopy || !track->decoder) continue;
            status = track->type == AVMEDIA_TYPE_VIDEO ? convert_video(cursor, track, NULL) : convert_audio(cursor, track, NULL);
            if (status < 0) { fail(error, errorSize, status, "flush"); goto done; }
        }
    }
    for (int i = 0; i < cursor->count; i++) {
        Track *track = &cursor->tracks[i];
        if (!active[i] || track->type != AVMEDIA_TYPE_VIDEO || track->spec.mode == TVMModeCopy) continue;
        if ((status = finish_video(cursor, track)) < 0) { fail(error, errorSize, status, "encode"); goto done; }
    }
    for (int i = 0; i < cursor->count; i++) {
        if ((status = close_mux(&cursor->tracks[i])) < 0) { fail(error, errorSize, status, "finish"); goto done; }
    }
    cursor->nextStart = end >= 0 && !(cursor->eof && !cursor->pendingCount) ? end : INT64_MIN;
    cursor->write = NULL; cursor->cue = NULL; cursor->context = NULL;
    return 0;
done:
    for (int i = 0; i < cursor->count; i++) {
        Track *track = &cursor->tracks[i];
        free_mux(&track->mux);
        if (track->type == AVMEDIA_TYPE_VIDEO) avcodec_free_context(&track->encoder);
    }
    cursor->nextStart = INT64_MIN;
    cursor->write = NULL; cursor->cue = NULL; cursor->context = NULL;
    return status < 0 ? status : AVERROR_UNKNOWN;
}

// MARK: - Rewrap

/// tx3g's sample description, as FFmpeg's mov_text encoder writes it: centred at the bottom, white text.
static const uint8_t text_sample_entry[] = {
    0x00, 0x00, 0x00, 0x00,                         // displayFlags
    0x01, 0xFF,                                     // horizontal and vertical justification
    0x00, 0x00, 0x00, 0x00,                         // background colour
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // default text box
    0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x12, // style: characters, font 1, plain, 18
    0xFF, 0xFF, 0xFF, 0xFF,                         // text colour
    0x00, 0x00, 0x00, 0x12, 'f', 't', 'a', 'b',     // font table: one font, Serif
    0x00, 0x01, 0x00, 0x01, 0x05, 'S', 'e', 'r', 'i', 'f',
};

static int file_read(void *context, int64_t offset, uint8_t *buffer, int size) {
    ssize_t count = pread((int)(intptr_t)context, buffer, size, offset);
    return count < 0 ? -1 : (int)count;
}

TVMInput *tvm_open_file(const char *path, char *error, int errorSize) {
    int descriptor = open(path, O_RDONLY);
    if (descriptor < 0) { fail(error, errorSize, AVERROR(errno), "open"); return NULL; }
    struct stat info;
    if (fstat(descriptor, &info) != 0) { fail(error, errorSize, AVERROR(errno), "open"); close(descriptor); return NULL; }
    TVMInput *input = tvm_open((void *)(intptr_t)descriptor, file_read, NULL, info.st_size, error, errorSize);
    if (!input) { close(descriptor); return NULL; }
    input->descriptor = descriptor;
    return input;
}

static int output_write(void *opaque, const uint8_t *bytes, int size) {
    return fwrite(bytes, 1, size, opaque) == (size_t)size ? size : AVERROR(EIO);
}

static int64_t output_seek(void *opaque, int64_t offset, int whence) {
    if (whence & AVSEEK_SIZE) return AVERROR(ENOSYS);
    return fseeko(opaque, offset, whence & ~AVSEEK_FORCE) == 0 ? ftello(opaque) : AVERROR(EIO);
}

int tvm_rewrap(TVMInput *input, const int *streams, int count, int dolbyVision, const char *path, void *context,
               TVMTextFunction text, TVMProgressFunction progress, char *error, int errorSize) {
    // A reader of its own from the very start: going back to the first keyframe, as the input did, would leave out
    // the sound and subtitles before it (a picture often starts seconds after them).
    TVMInput *reader = open_input(input->context, input->read, input->interrupted, input->size, 0, error, errorSize);
    if (!reader) return AVERROR(EIO);
    if (reader->format->nb_streams != input->format->nb_streams) {
        tvm_close(reader);
        return fail(error, errorSize, AVERROR(EINVAL), "streams");
    }
    AVFormatContext *format = reader->format, *mux = NULL;
    FILE *file = NULL;
    AVPacket *packet = av_packet_alloc(), *sample = av_packet_alloc();
    int *outOf = av_malloc_array(format->nb_streams, sizeof(int));
    int64_t *lastDts = av_malloc_array(count > 0 ? count : 1, sizeof(int64_t));
    uint8_t *line = av_malloc(4096);
    // Copied video's decode times, rebuilt from presentation times as the cursor does (Matroska stores only those).
    int64_t window[17];
    int windowCount = 0, reorder = 1, decoded = 0, video = -1;
    int64_t frameDuration = 1;
    int status = packet && sample && outOf && lastDts && line ? 0 : AVERROR(ENOMEM);
    if (status < 0) { fail(error, errorSize, status, "rewrap"); goto done; }
    for (unsigned i = 0; i < format->nb_streams; i++) outOf[i] = -1;
    if ((status = avformat_alloc_output_context2(&mux, NULL, "mp4", NULL)) < 0) { fail(error, errorSize, status, "writer"); goto done; }
    for (int i = 0; i < count; i++) {
        if (streams[i] < 0 || streams[i] >= (int)format->nb_streams) { status = fail(error, errorSize, AVERROR(EINVAL), "stream"); goto done; }
        AVStream *in = format->streams[streams[i]], *st = avformat_new_stream(mux, NULL);
        if (!st) { status = fail(error, errorSize, AVERROR(ENOMEM), "stream"); goto done; }
        if (in->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            // Text subtitles become tx3g, which an MP4 carries and AVPlayer lists; `text` gives each cue's plain text.
            st->codecpar->codec_type = AVMEDIA_TYPE_SUBTITLE;
            st->codecpar->codec_id = AV_CODEC_ID_MOV_TEXT;
            st->codecpar->extradata = av_mallocz(sizeof text_sample_entry + AV_INPUT_BUFFER_PADDING_SIZE);
            if (!st->codecpar->extradata) { status = fail(error, errorSize, AVERROR(ENOMEM), "stream"); goto done; }
            memcpy(st->codecpar->extradata, text_sample_entry, sizeof text_sample_entry);
            st->codecpar->extradata_size = sizeof text_sample_entry;
            st->time_base = (AVRational){1, 1000};
        } else {
            if ((status = avcodec_parameters_copy(st->codecpar, in->codecpar)) < 0) { fail(error, errorSize, status, "stream"); goto done; }
            st->codecpar->codec_tag = 0;
            st->time_base = in->time_base;
            if (in->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                if (st->codecpar->codec_id == AV_CODEC_ID_HEVC)
                    st->codecpar->codec_tag = dolbyVision == TVMDolbyVisionDVH1 ? MKTAG('d', 'v', 'h', '1') : MKTAG('h', 'v', 'c', '1');
                if (dolbyVision == TVMDolbyVisionDrop)
                    av_packet_side_data_remove(st->codecpar->coded_side_data, &st->codecpar->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
                st->avg_frame_rate = in->avg_frame_rate;
                if (!st->codecpar->sample_aspect_ratio.num) st->codecpar->sample_aspect_ratio = in->sample_aspect_ratio;
                // The colours the input found in the picture when its container named none.
                const AVCodecParameters *probed = input->format->streams[streams[i]]->codecpar;
                if (st->codecpar->color_trc == AVCOL_TRC_UNSPECIFIED) {
                    st->codecpar->color_trc = probed->color_trc;
                    st->codecpar->color_primaries = probed->color_primaries;
                    st->codecpar->color_space = probed->color_space;
                }
                video = i;
                reorder = FFMIN(16, FFMAX(in->codecpar->video_delay, 0) + 1);
                AVRational rate = in->avg_frame_rate.num && in->avg_frame_rate.den ? in->avg_frame_rate : in->r_frame_rate;
                frameDuration = FFMAX(1, rate.num && rate.den ? av_rescale_q(1, av_inv_q(rate), in->time_base) : av_rescale_q(1, (AVRational){1, 24}, in->time_base));
            } else if (!st->codecpar->frame_size) {
                switch (st->codecpar->codec_id) {
                case AV_CODEC_ID_AAC: st->codecpar->frame_size = 1024; break;
                case AV_CODEC_ID_AC3: case AV_CODEC_ID_EAC3: st->codecpar->frame_size = 1536; break;
                default: break;
                }
            }
        }
        av_dict_copy(&st->metadata, in->metadata, 0);
        st->disposition = in->disposition & (AV_DISPOSITION_DEFAULT | AV_DISPOSITION_FORCED);
        outOf[streams[i]] = i;
        lastDts[i] = AV_NOPTS_VALUE;
    }
    if (!(file = fopen(path, "wb"))) { status = fail(error, errorSize, AVERROR(errno), "create"); goto done; }
    const int bufferSize = 1 << 20;
    uint8_t *buffer = av_malloc(bufferSize);
    mux->pb = buffer ? avio_alloc_context(buffer, bufferSize, 1, file, NULL, output_write, output_seek) : NULL;
    if (!mux->pb) { av_free(buffer); status = fail(error, errorSize, AVERROR(ENOMEM), "writer"); goto done; }
    mux->pb->seekable = AVIO_SEEKABLE_NORMAL;
    // Dolby Vision's dvcC box is "unofficial" to FFmpeg; Apple players read it.
    mux->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
    if ((status = avformat_write_header(mux, NULL)) < 0) { fail(error, errorSize, status, "header"); goto done; }
    for (int64_t packets = 0;; packets++) {
        if (progress && packets % 256 == 0 && progress(context, reader->position)) { status = fail(error, errorSize, AVERROR_EXIT, "cancelled"); goto done; }
        status = av_read_frame(format, packet);
        if (status == AVERROR_EOF) { status = 0; break; }
        if (status < 0) { fail(error, errorSize, status, "read"); goto done; }
        int out = packet->stream_index < (int)format->nb_streams ? outOf[packet->stream_index] : -1;
        if (out < 0) { av_packet_unref(packet); continue; }
        AVStream *in = format->streams[packet->stream_index], *st = mux->streams[out];
        AVPacket *write = packet;
        if (st->codecpar->codec_id == AV_CODEC_ID_MOV_TEXT) {
            int64_t start = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
            int size = start == AV_NOPTS_VALUE || !text ? 0 : text(context, out, packet->data, packet->size, line + 2, 4096 - 2);
            if (size <= 0) { av_packet_unref(packet); continue; }
            if ((status = av_new_packet(sample, size + 2)) < 0) { fail(error, errorSize, status, "subtitle"); goto done; }
            AV_WB16(sample->data, size);
            memcpy(sample->data + 2, line + 2, size);
            sample->pts = sample->dts = start;
            // A cue with no end shows for four seconds, as in the repackager.
            sample->duration = packet->duration > 0 ? packet->duration : av_rescale_q(4000000, AV_TIME_BASE_Q, in->time_base);
            av_packet_unref(packet);
            write = sample;
        } else if (out == video && packet->pts != AV_NOPTS_VALUE) {
            int at = windowCount;
            while (at > 0 && window[at - 1] > packet->pts) { window[at] = window[at - 1]; at--; }
            window[at] = packet->pts;
            windowCount++;
            if (windowCount > reorder) {
                packet->dts = window[0];
                memmove(window, window + 1, (windowCount - 1) * sizeof(int64_t));
                windowCount--;
            } else packet->dts = window[0] - (int64_t)(reorder - decoded) * frameDuration;
            decoded++;
        }
        if (write->dts == AV_NOPTS_VALUE) write->dts = write->pts;
        if (write->pts == AV_NOPTS_VALUE) write->pts = write->dts;
        if (write->dts == AV_NOPTS_VALUE) { av_packet_unref(write); continue; }
        if (lastDts[out] != AV_NOPTS_VALUE && write->dts <= lastDts[out]) write->dts = lastDts[out] + 1;
        if (write->pts < write->dts) write->pts = write->dts;
        lastDts[out] = write->dts;
        av_packet_rescale_ts(write, in->time_base, st->time_base);
        write->stream_index = out;
        write->pos = -1;
        status = av_write_frame(mux, write);
        av_packet_unref(write);
        if (status < 0) { fail(error, errorSize, status, "write"); goto done; }
    }
    if ((status = av_write_trailer(mux)) < 0) { fail(error, errorSize, status, "finish"); goto done; }
    avio_flush(mux->pb);
    if (fflush(file) != 0) status = fail(error, errorSize, AVERROR(EIO), "finish");
done:
    if (mux) {
        if (mux->pb) { av_freep(&mux->pb->buffer); avio_context_free(&mux->pb); }
        avformat_free_context(mux);
    }
    if (file && fclose(file) != 0 && status >= 0) status = fail(error, errorSize, AVERROR(EIO), "finish");
    if (status < 0 && file) remove(path);
    av_packet_free(&packet); av_packet_free(&sample);
    av_free(outOf); av_free(lastDts); av_free(line);
    tvm_close(reader);
    return status < 0 ? status : 0;
}

#!/bin/bash
# Builds the MKV compatibility matrix of issue #273 (codecs, audio, subtitles, file layouts) in <folder>/files.
# All audio is silent. Needs Homebrew ffmpeg (x264, x265, svt-av1, vpx, opus, vorbis, lame) and mkvtoolnix.
# Then: COMPAT_DIR=<folder>/files COMPAT_LOG=<folder>/results.txt swift test --filter ZZCompat273Tests
# (ZZCompat273Tests.swift does nothing without COMPAT_DIR.)
set -u
mkdir -p "${1:?usage: make-files.sh <folder>}" && cd "$1"
mkdir -p files tmp
D=12
V="-f lavfi -i testsrc2=s=640x360:r=24:d=$D"
A2="-f lavfi -t $D -i anullsrc=r=48000:cl=stereo"
A51="-f lavfi -t $D -i anullsrc=r=48000:cl=5.1"
A71="-f lavfi -t $D -i anullsrc=r=48000:cl=7.1"
X264="-c:v libx264 -preset veryfast -g 48 -pix_fmt yuv420p"
X265P="keyint=48:min-keyint=48:log-level=error"
AAC="-c:a aac -b:a 128k"
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
ok() { if [ -s "files/$1.mkv" ]; then echo "made $1"; else echo "FAILED $1"; fi; }
v() { local name=$1; shift; [ -s "files/$name.mkv" ] && { echo "have $name"; return; }; ff "$@" "files/$name.mkv"; ok "$name"; }

cat > tmp/sub.srt <<'EOF'
1
00:00:00,500 --> 00:00:03,000
<i>Hello</i> & welcome

2
00:00:05,000 --> 00:00:08,000
第二句字幕

3
00:00:09,000 --> 00:00:11,000
Third line
EOF
cat > tmp/sub.ass <<'EOF'
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Source Han Sans,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.50,0:00:03.00,Default,,0,0,0,,{\an8\fs30}上方字幕\Nsecond line
Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,{\p1}m 0 0 l 100 0 100 100 0 100{\p0}
Dialogue: 0,0:00:05.00,0:00:08.00,Default,,0,0,0,,Plain {\i1}italic{\i0}
EOF

# --- video codecs (stereo AAC) ---
v v01_h264_8bit $V $A2 $X264 $AAC
v v02_h264_hi10 $V $A2 -c:v libx264 -preset veryfast -g 48 -pix_fmt yuv420p10le -profile:v high10 $AAC
v v03_h264_422 $V $A2 -c:v libx264 -preset veryfast -g 48 -pix_fmt yuv422p $AAC
v v04_h264_444 $V $A2 -c:v libx264 -preset veryfast -g 48 -pix_fmt yuv444p $AAC
v v05_h264_interlaced -f lavfi -i testsrc2=s=720x576:r=25:d=$D $A2 -c:v libx264 -preset veryfast -g 50 -pix_fmt yuv420p -flags +ildct+ilme -x264-params interlaced=1:tff=1 $AAC
v v06_h264_intra_refresh $V $A2 -c:v libx264 -preset veryfast -pix_fmt yuv420p -x264-params keyint=48:intra-refresh=1 $AAC
v v07_h264_1080p_l51 -f lavfi -i testsrc2=s=1920x1080:r=24:d=$D $A2 -c:v libx264 -preset ultrafast -g 48 -pix_fmt yuv420p -level 5.1 -refs 16 -bf 8 $AAC
v v08_hevc_8bit $V $A2 -c:v libx265 -preset fast -pix_fmt yuv420p -x265-params $X265P $AAC
v v09_hevc_main10 $V $A2 -c:v libx265 -preset fast -pix_fmt yuv420p10le -x265-params $X265P $AAC
v v10_hevc_hdr10 $V $A2 -c:v libx265 -preset fast -pix_fmt yuv420p10le -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -x265-params "$X265P:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" $AAC
v v11_hevc_hlg $V $A2 -c:v libx265 -preset fast -pix_fmt yuv420p10le -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -x265-params "$X265P:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" $AAC
v v12_hevc_422_10 $V $A2 -c:v libx265 -preset fast -pix_fmt yuv422p10le -x265-params $X265P $AAC
v v13_hevc_12bit $V $A2 -c:v libx265 -preset fast -pix_fmt yuv420p12le -x265-params $X265P $AAC
v v14_hevc_long_gop $V $A2 -c:v libx265 -preset fast -pix_fmt yuv420p10le -x265-params keyint=240:min-keyint=24:scenecut=0:log-level=error $AAC
v v15_hevc_1080p_main10 -f lavfi -i testsrc2=s=1920x1080:r=24:d=$D $A2 -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params $X265P $AAC
v v16_av1_8bit $V $A2 -c:v libsvtav1 -preset 10 -g 48 -pix_fmt yuv420p $AAC
v v17_av1_10bit $V $A2 -c:v libsvtav1 -preset 10 -g 48 -pix_fmt yuv420p10le $AAC
v v18_vp9 $V $A2 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -g 48 -b:v 1M $AAC
v v19_vp8 $V $A2 -c:v libvpx -deadline realtime -cpu-used 8 -g 48 -b:v 1M $AAC
v v20_mpeg2 $V $A2 -c:v mpeg2video -b:v 3M -g 12 -c:a ac3
v v21_mpeg4_xvid $V $A2 -c:v mpeg4 -vtag XVID -b:v 2M -g 48 -c:a libmp3lame
v v22_h264_anamorphic -f lavfi -i testsrc2=s=720x480:r=30000/1001:d=$D $A2 -vf setsar=32/27 $X264 $AAC
v v23_h264_scope_1920x800 -f lavfi -i testsrc2=s=1920x800:r=24:d=$D $A2 -c:v libx264 -preset ultrafast -g 48 -pix_fmt yuv420p $AAC
v v24_h264_vfr $V $A2 -vf "select='lt(t,4)+not(mod(n,3))'" -fps_mode vfr $X264 $AAC
v v25_h264_60fps -f lavfi -i testsrc2=s=1280x720:r=60:d=$D $A2 -c:v libx264 -preset ultrafast -g 120 -pix_fmt yuv420p $AAC

# --- audio codecs (H.264 picture) ---
v a01_aac_51 $V $A51 $X264 -c:a aac -b:a 384k
v a02_aac_71 $V $A71 $X264 -c:a aac -b:a 512k
v a03_ac3_51 $V $A51 $X264 -c:a ac3
v a04_eac3_51 $V $A51 $X264 -c:a eac3
v a05_dts_51 $V $A51 $X264 -strict -2 -c:a dca
v a06_truehd_51 $V $A51 $X264 -strict -2 -c:a truehd
v a07_flac_24bit_71 $V $A71 $X264 -c:a flac -sample_fmt s32
v a08_flac_96k -f lavfi -i testsrc2=s=640x360:r=24:d=$D -f lavfi -t $D -i anullsrc=r=96000:cl=stereo $X264 -c:a flac
v a09_opus_51 $V $A51 $X264 -c:a libopus -b:a 256k
v a10_vorbis $V $A2 $X264 -c:a libvorbis
v a11_mp3 $V $A2 $X264 -c:a libmp3lame
v a12_mp2 $V $A2 $X264 -c:a mp2
v a13_pcm_s16 $V $A2 $X264 -c:a pcm_s16le
v a14_pcm_s24_51 $V $A51 $X264 -c:a pcm_s24le
v a15_alac $V $A2 $X264 -c:a alac
v a16_aac_44k_mono $V -f lavfi -t $D -i anullsrc=r=44100:cl=mono $X264 -c:a aac
v a17_no_audio $V $X264
v a18_multi_audio $V $A2 $A51 $A51 -map 0:v -map 1:a -map 2:a -map 3:a $X264 -c:a:0 aac -c:a:1 ac3 -strict -2 -c:a:2 dca -metadata:s:a:0 language=chi -metadata:s:a:0 title=国语 -metadata:s:a:1 language=eng -metadata:s:a:1 'title=English "Original"' -metadata:s:a:2 language=jpn -disposition:a:0 0 -disposition:a:1 default
v a19_audio_first $V $A2 -map 1:a -map 0:v $X264 $AAC
v a20_dts_default_aac_second $V $A51 $A2 -map 0:v -map 1:a -map 2:a $X264 -strict -2 -c:a:0 dca -c:a:1 aac -disposition:a:0 default

# --- subtitles ---
v s01_srt $V $A2 -i tmp/sub.srt -map 0 -map 1 -map 2 $X264 $AAC -c:s srt -metadata:s:s:0 language=chi
v s02_ass $V $A2 -i tmp/sub.ass -map 0 -map 1 -map 2 $X264 $AAC -c:s ass -metadata:s:s:0 language=chs
v s03_webvtt $V $A2 -i tmp/sub.srt -map 0 -map 1 -map 2 $X264 $AAC -c:s webvtt
args=(); maps=(); for i in $(seq 0 19); do args+=(-i tmp/sub.srt); maps+=(-map $((i+2))); done
v s04_twenty_subs $V $A2 "${args[@]}" -map 0 -map 1 "${maps[@]}" $X264 $AAC -c:s srt
v s05_forced_sub $V $A2 -i tmp/sub.srt -i tmp/sub.srt -map 0 -map 1 -map 2 -map 3 $X264 $AAC -c:s srt -disposition:s:0 forced -disposition:s:1 default -metadata:s:s:0 'title=Signs & "Songs"'

# --- file layout ---
v c01_cues_at_front $V $A2 $X264 $AAC -reserve_index_space 65536
if [ ! -s files/c02_no_cues_streamed.mkv ]; then ff $V $A2 $X264 $AAC -f matroska pipe:1 > files/c02_no_cues_streamed.mkv; ok c02_no_cues_streamed; fi
v c03_start_at_10s $V $A2 $X264 $AAC -output_ts_offset 10
v c04_audio_starts_late $V -itsoffset 1.5 $A2 $X264 $AAC
v c05_video_starts_late -itsoffset 0.7 $V $A2 $X264 $AAC
v c06_live_mode $V $A2 $X264 $AAC -live 1
v c07_webm_vp9_opus $V $A2 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -g 48 -b:v 1M -c:a libopus

# mkvmerge, which most releases are muxed with.
mm() { local name=$1; shift; [ -s "files/$name.mkv" ] && { echo "have $name"; return; }; mkvmerge -q -o "files/$name.mkv" "$@" >/dev/null 2>tmp/$name.err; ok "$name"; }
mm m01_mkvmerge_h264 files/s01_srt.mkv
mm m02_mkvmerge_hevc10 files/v09_hevc_main10.mkv
mm m03_mkvmerge_no_cues --no-cues files/v01_h264_8bit.mkv
mm m05_zlib_subs --compression 2:zlib files/s01_srt.mkv
mm m06_zlib_video --compression 0:zlib files/v01_h264_8bit.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=red:s=600x900 -frames:v 1 tmp/cover.jpg
mm m07_cover_attachment --attachment-mime-type image/jpeg --attachment-name cover.jpg --attach-file tmp/cover.jpg files/v01_h264_8bit.mkv
[ -s tmp/fonts.bin ] || head -c 40000000 /dev/urandom > tmp/fonts.bin
mm m08_40mb_font_attachments --attachment-mime-type font/ttf --attachment-name SourceHanSans.ttf --attach-file tmp/fonts.bin files/s02_ass.mkv
mm m09_lacing_none --disable-lacing files/a03_ac3_51.mkv
mm m10_cluster_long --cluster-length 20000ms files/v01_h264_8bit.mkv
mm m11_default_duration_23976 --default-duration 0:24000/1001p --fix-bitstream-timing-information 0:1 files/v08_hevc_8bit.mkv
mm m12_track_order_sub_audio_video --track-order 0:2,0:1,0:0 files/s01_srt.mkv
mm c08_mkvmerge_start_10s files/c03_start_at_10s.mkv

# A full-length episode at a small size: 24 minutes.
v l01_24min_h264 -f lavfi -i testsrc2=s=320x180:r=24:d=1440 -f lavfi -t 1440 -i anullsrc=r=48000:cl=stereo -c:v libx264 -preset ultrafast -g 48 -pix_fmt yuv420p -c:a aac -b:a 64k
v l02_24min_hevc10_ac3 -f lavfi -i testsrc2=s=320x180:r=24:d=1440 -f lavfi -t 1440 -i anullsrc=r=48000:cl=5.1 -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params keyint=48:log-level=error -c:a ac3
echo done
ls files | wc -l

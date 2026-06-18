#!/usr/bin/env bash
#
# video-sound-normalize.sh <input> [output]
#
# Normalizes a video's audio to -16 LUFS (EBU R128, streaming level) using the
# loudnorm filter in two passes for maximum accuracy.
#
# - The VIDEO stream is copied untouched (no video re-encoding).
# - Only the audio is re-encoded, in the SAME codec as the source when
#   possible (opus, aac, mp3, vorbis, ac3, eac3, flac, alac, pcm), otherwise
#   it falls back to aac.
# - The source audio bitrate is detected and reused. If the bitrate cannot be
#   read from the stream, a sensible per-codec default is used.
# - Works with any input container/encoding.
#
# Usage: ./video-sound-normalize.sh <input> [output]
#   <output> defaults to <input>_normalized.<ext> if omitted

set -euo pipefail

# ---------------------------------------------------------------------------
# loudnorm targets (edit if needed)
# ---------------------------------------------------------------------------
TARGET_I="-16"      # Integrated loudness target (LUFS). Use -23 for broadcast.
TARGET_TP="-1.5"    # True peak ceiling (dBTP).
TARGET_LRA="11"     # Target loudness range (LU).

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <input> [output]" >&2
    exit 1
fi

input_file="$1"

if [[ ! -f "$input_file" ]]; then
    echo "Error: file not found: $input_file" >&2
    exit 1
fi

# Make sure ffmpeg/ffprobe are available
for tool in ffmpeg ffprobe; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: $tool is not installed or not in PATH." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Work out the output filename
# ---------------------------------------------------------------------------
if [[ $# -eq 2 ]]; then
    output_file="$2"
else
    dir="$(dirname -- "$input_file")"
    base="$(basename -- "$input_file")"
    ext="${base##*.}"
    name="${base%.*}"
    # No extension detected: fall back to .mkv (flexible container)
    if [[ "$name" == "$ext" ]]; then
        output_file="${dir}/${base}_normalized.mkv"
    else
        output_file="${dir}/${name}_normalized.${ext}"
    fi
fi

# ---------------------------------------------------------------------------
# Detect the source audio codec
# ---------------------------------------------------------------------------
audio_codec="$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 \
    "$input_file" || true)"

if [[ -z "$audio_codec" ]]; then
    echo "Error: no audio stream detected in $input_file." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect the source audio bitrate
#   1) try the stream-level bit_rate
#   2) estimate from audio packets (bit_rate computed over the whole stream)
# Result is left empty if nothing usable is found.
# ---------------------------------------------------------------------------
detect_bitrate() {
    local br

    # 1) stream-level bit_rate
    br="$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=bit_rate -of default=nokey=1:noprint_wrappers=1 \
        "$input_file" 2>/dev/null || true)"
    if [[ "$br" =~ ^[0-9]+$ ]] && [[ "$br" -gt 0 ]]; then
        echo "$br"; return
    fi

    # 2) estimate from the audio stream's packets
    br="$(ffprobe -v error -select_streams a:0 -count_packets \
        -show_entries stream=bit_rate -of default=nokey=1:noprint_wrappers=1 \
        "$input_file" 2>/dev/null || true)"
    if [[ "$br" =~ ^[0-9]+$ ]] && [[ "$br" -gt 0 ]]; then
        echo "$br"; return
    fi

    echo ""   # nothing found
}

src_bitrate_bps="$(detect_bitrate)"

# Round a bits-per-second value to a tidy "<n>k" string for the encoder.
to_k() {
    local bps="$1"
    local k=$(( (bps + 500) / 1000 ))   # round to nearest 1000
    echo "${k}k"
}

# ---------------------------------------------------------------------------
# Pick the audio encoder: stay in the same codec when possible.
# default_br is used only if the source bitrate cannot be detected.
# ---------------------------------------------------------------------------
lossless=0
case "$audio_codec" in
    opus)         audio_encoder="libopus";    default_br="128k" ;;
    aac)          audio_encoder="aac";        default_br="192k" ;;
    mp3)          audio_encoder="libmp3lame"; default_br="192k" ;;
    vorbis)       audio_encoder="libvorbis";  default_br="192k" ;;
    ac3)          audio_encoder="ac3";        default_br="448k" ;;
    eac3)         audio_encoder="eac3";       default_br="448k" ;;
    flac)         audio_encoder="flac";       default_br="";     lossless=1 ;;
    alac)         audio_encoder="alac";       default_br="";     lossless=1 ;;
    pcm_s16le|pcm_s24le|pcm_s32le|pcm_f32le|pcm_u8)
                  audio_encoder="$audio_codec"; default_br="";   lossless=1 ;;
    *)            audio_encoder="aac";        default_br="192k"
                  echo "Codec '$audio_codec' not recognized: falling back to AAC 192k." >&2 ;;
esac

# Decide the bitrate to actually use.
if [[ "$lossless" -eq 1 ]]; then
    bitrate=""                                 # lossless: no bitrate flag
elif [[ -n "$src_bitrate_bps" ]]; then
    bitrate="$(to_k "$src_bitrate_bps")"       # reuse detected source bitrate
else
    bitrate="$default_br"                      # detection failed: default
fi

echo "==> Input file   : $input_file"
echo "==> Output file  : $output_file"
if [[ "$lossless" -eq 1 ]]; then
    echo "==> Audio codec  : $audio_codec -> $audio_encoder (lossless, no bitrate)"
elif [[ -n "$src_bitrate_bps" ]]; then
    echo "==> Audio codec  : $audio_codec -> $audio_encoder (reusing source bitrate ~$bitrate)"
else
    echo "==> Audio codec  : $audio_codec -> $audio_encoder (source bitrate unknown, default $bitrate)"
fi
echo "==> loudnorm     : I=$TARGET_I  TP=$TARGET_TP  LRA=$TARGET_LRA"
echo

# ---------------------------------------------------------------------------
# PASS 1: measure loudness (capture the JSON output)
# ---------------------------------------------------------------------------
echo "==> Pass 1/2: analyzing loudness..."

measure_out="$(ffmpeg -hide_banner -nostats -i "$input_file" \
    -map a:0 \
    -af "loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:print_format=json" \
    -f null - 2>&1 || true)"

# Pull out the JSON block (the trailing {...} that loudnorm prints)
json="$(echo "$measure_out" | awk '/^\{/{c=1} c{print} /^\}/{c=0}')"

get_val() {
    # $1 = key name; prints the quoted value
    echo "$json" | grep "\"$1\"" | sed -E 's/.*: *"([^"]*)".*/\1/'
}

measured_i="$(get_val input_i)"
measured_tp="$(get_val input_tp)"
measured_lra="$(get_val input_lra)"
measured_thresh="$(get_val input_thresh)"
offset="$(get_val target_offset)"

if [[ -z "$measured_i" || -z "$offset" ]]; then
    echo "Error: could not read measurements from pass 1." >&2
    echo "ffmpeg output:" >&2
    echo "$measure_out" >&2
    exit 1
fi

echo "    measured: I=$measured_i  TP=$measured_tp  LRA=$measured_lra  thresh=$measured_thresh  offset=$offset"
echo

# ---------------------------------------------------------------------------
# PASS 2: apply the correction
# ---------------------------------------------------------------------------
echo "==> Pass 2/2: applying normalization..."

loudnorm_filter="loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}"
loudnorm_filter+=":measured_I=${measured_i}:measured_TP=${measured_tp}"
loudnorm_filter+=":measured_LRA=${measured_lra}:measured_thresh=${measured_thresh}"
loudnorm_filter+=":offset=${offset}"

# Build the bitrate option (empty for lossless codecs)
bitrate_opt=()
if [[ -n "$bitrate" ]]; then
    bitrate_opt=(-b:a "$bitrate")
fi

ffmpeg -hide_banner -i "$input_file" \
    -map 0:v -map 0:a \
    -c:v copy \
    -c:a "$audio_encoder" "${bitrate_opt[@]}" \
    -af "$loudnorm_filter" \
    -c:s copy -c:d copy \
    -map_metadata 0 \
    "$output_file"

echo
echo "==> Done: $output_file"

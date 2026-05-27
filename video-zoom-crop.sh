#!/usr/bin/env bash
#
# video-zoom-crop.sh
#
# Crop & upscale a video to a region, preserving aspect ratio and quality
#
# Behaviour:
#   - The crop region is expanded (never shrunk) so its aspect ratio matches
#     the original video, keeping the same centre point.
#   - The expanded crop is then scaled back up to the original resolution using Lanczos.
#   - Video is re-encoded with CRF-based quality targeting matching the source codec.
#   - Audio streams and metadata are copied without re-encoding.
#
# Usage: ./video-zoom-crop.sh <x> <y> <w> <h> <input> [output]
#   <x> <y>        Top-left corner of the region of interest
#   <w> <h>        Width and height of the region of interest
#   <output> defaults to <input>_zoomed.<ext> if omitted

set -euo pipefail

# ── helpers ───────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" &>/dev/null || die "'$1' not found – please install it."; }

need ffmpeg
need ffprobe
need bc

# ── arguments ─────────────────────────────────────────────────────────────────

[[ $# -lt 5 ]] && {
    echo "Usage: $0 <x> <y> <w> <h> <input> [output]"
    exit 1
}

X="$1"; Y="$2"; W="$3"; H="$4"; INPUT="$5"
EXT="${INPUT##*.}"
OUTPUT="${6:-${INPUT%.*}_zoomed.${EXT}}"

[[ -f "$INPUT" ]] || die "Input file not found: $INPUT"

# ── validate input coordinates ────────────────────────────────────────────────

for VAR in X Y W H; do
    VAL="${!VAR}"
    [[ "$VAL" =~ ^[0-9]+$ ]] || die "$VAR must be a non-negative integer (got '$VAL')"
done
(( W > 0 )) || die "w must be positive"
(( H > 0 )) || die "h must be positive"

# ── probe source ─────────────────────────────────────────────────────────────

echo "→ Probing source: $INPUT"

probe() { ffprobe -v error -select_streams v:0 -show_entries "stream=$1" -of csv=p=0 "$INPUT"; }

read -r VID_W VID_H < <(probe width,height | tr ',' ' ')
[[ -n "$VID_W" && -n "$VID_H" ]] || die "Could not read video dimensions."

SRC_CODEC=$(probe codec_name)
SRC_PIX_FMT=$(probe pix_fmt)

echo "  Resolution: ${VID_W}×${VID_H} | Codec: $SRC_CODEC | Pixel format: $SRC_PIX_FMT"

# ── bounds check ──────────────────────────────────────────────────────────────

X2=$(( X + W ))
Y2=$(( Y + H ))
(( X >= 0 && Y >= 0 && X2 <= VID_W && Y2 <= VID_H )) || \
    die "Coordinates out of bounds (video is ${VID_W}×${VID_H})"

echo "→ Region of interest: ${W}×${H}  (top-left ${X},${Y})"

# ── expand crop to match original aspect ratio ────────────────────────────────

CX=$(( (X + X2) / 2 ))
CY=$(( (Y + Y2) / 2 ))

ASPECT=$(echo "scale=10; $VID_W / $VID_H" | bc -l)
ROI_WIDER=$(echo "$W / $H > $ASPECT" | bc -l)

if (( ROI_WIDER )); then
    CROP_W=$W
    CROP_H=$(echo "$W / $ASPECT" | bc -l | cut -d. -f1)
else
    CROP_H=$H
    CROP_W=$(echo "$H * $ASPECT" | bc -l | cut -d. -f1)
fi

# Round up to even dimensions (required by most codecs)
CROP_W=$(( (CROP_W + 1) / 2 * 2 ))
CROP_H=$(( (CROP_H + 1) / 2 * 2 ))

# Clamp dimensions to frame size (extreme aspect ratios near borders)
(( CROP_W > VID_W )) && CROP_W=$VID_W
(( CROP_H > VID_H )) && CROP_H=$VID_H

# Top-left of the expanded crop, clamped to frame
CROP_X=$(( CX - CROP_W / 2 ))
CROP_Y=$(( CY - CROP_H / 2 ))
(( CROP_X < 0 )) && CROP_X=0
(( CROP_Y < 0 )) && CROP_Y=0
(( CROP_X + CROP_W > VID_W )) && CROP_X=$(( VID_W - CROP_W ))
(( CROP_Y + CROP_H > VID_H )) && CROP_Y=$(( VID_H - CROP_H ))

echo "  Expanded crop: ${CROP_W}×${CROP_H}  (top-left ${CROP_X},${CROP_Y})"

(( X >= CROP_X && X2 <= CROP_X + CROP_W && Y >= CROP_Y && Y2 <= CROP_Y + CROP_H )) || \
    die "Expanded crop does not fully contain the ROI – frame too small?"

# ── encoder and pixel format ──────────────────────────────────────────────────

case "$SRC_CODEC" in
    h264)        ENCODER="libx264" ;;
    hevc|h265)   ENCODER="libx265" ;;
    vp8)         ENCODER="libvpx" ;;
    vp9)         ENCODER="libvpx-vp9" ;;
    av1)         ENCODER="libaom-av1" ;;
    mpeg4)       ENCODER="mpeg4" ;;
    mpeg2video)  ENCODER="mpeg2video" ;;
    *)           ENCODER="libx264" ;;
esac

# Map pixel format to what each encoder actually supports.
# Prefer preserving bit depth where the encoder supports it.
case "$ENCODER" in
    libx264)
        # x264 supports yuv420p and yuv444p; 10-bit via High10/Hi444pp profiles
        case "$SRC_PIX_FMT" in
            yuv420p10le|yuv420p12le) PIX_FMT="yuv420p10le" ;;
            yuv444p*)                PIX_FMT="yuv444p" ;;
            *)                       PIX_FMT="yuv420p" ;;
        esac ;;
    libx265)
        # x265 supports 8/10/12-bit 420/422/444
        case "$SRC_PIX_FMT" in
            *10le) PIX_FMT="yuv420p10le" ;;
            *12le) PIX_FMT="yuv420p12le" ;;
            *)     PIX_FMT="yuv420p" ;;
        esac ;;
    *)
        # For everything else fall back to the source format and let ffmpeg validate
        PIX_FMT="$SRC_PIX_FMT" ;;
esac

echo "  Encoder: $ENCODER | Output pixel format: $PIX_FMT"

case "$ENCODER" in
    libx264)  QUALITY_FLAGS=(-preset slow -crf 18) ;;
    libx265)  QUALITY_FLAGS=(-preset slow -crf 20) ;;
    libvpx*)  QUALITY_FLAGS=(-quality good -cpu-used 2) ;;
    libaom*)  QUALITY_FLAGS=(-cpu-used 4 -crf 23) ;;
    *)        QUALITY_FLAGS=() ;;
esac

# ── encode ────────────────────────────────────────────────────────────────────

echo "→ Encoding: $OUTPUT"

ffmpeg -hide_banner -loglevel info \
    -i "$INPUT" \
    -vf "crop=${CROP_W}:${CROP_H}:${CROP_X}:${CROP_Y},scale=${VID_W}:${VID_H}:flags=lanczos" \
    -c:v "$ENCODER" \
    "${QUALITY_FLAGS[@]}" \
    -pix_fmt "$PIX_FMT" \
    -c:a copy \
    -movflags +faststart \
    -map_metadata 0 \
    -y \
    "$OUTPUT"

echo ""
echo "✓ Done: $OUTPUT"
echo "  Cropped ${CROP_W}×${CROP_H} → scaled to ${VID_W}×${VID_H}"

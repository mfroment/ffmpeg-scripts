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

x="$1"; y="$2"; w="$3"; h="$4"; input_file="$5"
ext="${input_file##*.}"
output_file="${6:-${input_file%.*}_zoomed.${ext}}"

[[ -f "$input_file" ]] || die "Input file not found: $input_file"

# ── validate input coordinates ────────────────────────────────────────────────

for var in x y w h; do
    val="${!var}"
    [[ "$val" =~ ^[0-9]+$ ]] || die "$var must be a non-negative integer (got '$val')"
done
(( w > 0 )) || die "w must be positive"
(( h > 0 )) || die "h must be positive"

# ── probe source ─────────────────────────────────────────────────────────────

echo "→ Probing source: $input_file"

probe() { ffprobe -v error -select_streams v:0 -show_entries "stream=$1" -of csv=p=0 "$input_file"; }

read -r vid_w vid_h < <(probe width,height | tr ',' ' ')
[[ -n "$vid_w" && -n "$vid_h" ]] || die "Could not read video dimensions."

src_codec=$(probe codec_name)
src_pix_fmt=$(probe pix_fmt)

echo "  Resolution: ${vid_w}×${vid_h} | Codec: $src_codec | Pixel format: $src_pix_fmt"

# ── bounds check ──────────────────────────────────────────────────────────────

x2=$(( x + w ))
y2=$(( y + h ))
(( x >= 0 && y >= 0 && x2 <= vid_w && y2 <= vid_h )) || \
    die "Coordinates out of bounds (video is ${vid_w}×${vid_h})"

echo "→ Region of interest: ${w}×${h}  (top-left ${x},${y})"

# ── expand crop to match original aspect ratio ────────────────────────────────

cx=$(( (x + x2) / 2 ))
cy=$(( (y + y2) / 2 ))

aspect=$(echo "scale=10; $vid_w / $vid_h" | bc -l)
roi_wider=$(echo "$w / $h > $aspect" | bc -l)

if (( roi_wider )); then
    crop_w=$w
    crop_h=$(echo "$w / $aspect" | bc -l | cut -d. -f1)
else
    crop_h=$h
    crop_w=$(echo "$h * $aspect" | bc -l | cut -d. -f1)
fi

# Round up to even dimensions (required by most codecs)
crop_w=$(( (crop_w + 1) / 2 * 2 ))
crop_h=$(( (crop_h + 1) / 2 * 2 ))

# Clamp dimensions to frame size (extreme aspect ratios near borders)
(( crop_w > vid_w )) && crop_w=$vid_w
(( crop_h > vid_h )) && crop_h=$vid_h

# Top-left of the expanded crop, clamped to frame
crop_x=$(( cx - crop_w / 2 ))
crop_y=$(( cy - crop_h / 2 ))
(( crop_x < 0 )) && crop_x=0
(( crop_y < 0 )) && crop_y=0
(( crop_x + crop_w > vid_w )) && crop_x=$(( vid_w - crop_w ))
(( crop_y + crop_h > vid_h )) && crop_y=$(( vid_h - crop_h ))

echo "  Expanded crop: ${crop_w}×${crop_h}  (top-left ${crop_x},${crop_y})"

(( x >= crop_x && x2 <= crop_x + crop_w && y >= crop_y && y2 <= crop_y + crop_h )) || \
    die "Expanded crop does not fully contain the ROI – frame too small?"

# ── encoder and pixel format ──────────────────────────────────────────────────

case "$src_codec" in
    h264)        video_encoder="libx264" ;;
    hevc|h265)   video_encoder="libx265" ;;
    vp8)         video_encoder="libvpx" ;;
    vp9)         video_encoder="libvpx-vp9" ;;
    av1)         video_encoder="libaom-av1" ;;
    mpeg4)       video_encoder="mpeg4" ;;
    mpeg2video)  video_encoder="mpeg2video" ;;
    *)           video_encoder="libx264" ;;
esac

# Map pixel format to what each encoder actually supports.
# Prefer preserving bit depth where the encoder supports it.
case "$video_encoder" in
    libx264)
        # x264 supports yuv420p and yuv444p; 10-bit via High10/Hi444pp profiles
        case "$src_pix_fmt" in
            yuv420p10le|yuv420p12le) pix_fmt="yuv420p10le" ;;
            yuv444p*)                pix_fmt="yuv444p" ;;
            *)                       pix_fmt="yuv420p" ;;
        esac ;;
    libx265)
        # x265 supports 8/10/12-bit 420/422/444
        case "$src_pix_fmt" in
            *10le) pix_fmt="yuv420p10le" ;;
            *12le) pix_fmt="yuv420p12le" ;;
            *)     pix_fmt="yuv420p" ;;
        esac ;;
    *)
        # For everything else fall back to the source format and let ffmpeg validate
        pix_fmt="$src_pix_fmt" ;;
esac

echo "  Encoder: $video_encoder | Output pixel format: $pix_fmt"

case "$video_encoder" in
    libx264)  quality_flags=(-preset slow -crf 18) ;;
    libx265)  quality_flags=(-preset slow -crf 20) ;;
    libvpx*)  quality_flags=(-quality good -cpu-used 2) ;;
    libaom*)  quality_flags=(-cpu-used 4 -crf 23) ;;
    *)        quality_flags=() ;;
esac

# ── encode ────────────────────────────────────────────────────────────────────

echo "→ Encoding: $output_file"

ffmpeg -hide_banner -loglevel info \
    -i "$input_file" \
    -vf "crop=${crop_w}:${crop_h}:${crop_x}:${crop_y},scale=${vid_w}:${vid_h}:flags=lanczos" \
    -c:v "$video_encoder" \
    "${quality_flags[@]}" \
    -pix_fmt "$pix_fmt" \
    -c:a copy \
    -movflags +faststart \
    -map_metadata 0 \
    -y \
    "$output_file"

echo ""
echo "✓ Done: $output_file"
echo "  Cropped ${crop_w}×${crop_h} → scaled to ${vid_w}×${vid_h}"

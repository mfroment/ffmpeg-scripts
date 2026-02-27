#!/bin/bash

# video-frame-burn.sh
#
# Creates a video copy with frame number and timestamps burned onto each frame.
# Burned info: frame number (0-indexed), decimal seconds, and hh:mm:ss.ms time.
#
# Usage: ./video-frame-burn.sh <input_video> [output_video]

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <input_video> [output_video]"
    echo "Example: $0 video.mp4"
    echo "         $0 video.mp4 custom_output.mp4"
    exit 1
fi

INPUT_VIDEO="$1"

if [ ! -f "$INPUT_VIDEO" ]; then
    echo "Error: File '$INPUT_VIDEO' does not exist"
    exit 1
fi

# If output file is not specified, generate filename with _frameinfo suffix
if [ "$#" -eq 2 ]; then
    OUTPUT_VIDEO="$2"
else
    INPUT_DIR=$(dirname "$INPUT_VIDEO")
    FILENAME=$(basename "$INPUT_VIDEO")
    STEM="${FILENAME%.*}"
    EXT="${FILENAME##*.}"
    OUTPUT_VIDEO="${INPUT_DIR}/${STEM}_frameinfo.${EXT}"
fi

echo "Analyzing video..."

# Get video framerate as a fraction (e.g. "30000/1001"), then compute decimal with bc.
# bc is used (not awk) for consistency with video-cut.sh; fix_leading_zero handles
# the case where bc outputs ".333" instead of "0.333" (rejected by some tools).
fix_leading_zero() { sed 's/^\./0./;s/^-\./-0./'; }

FPS_FRAC=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT_VIDEO")
FPS_NUM="${FPS_FRAC%%/*}"
FPS_DEN="${FPS_FRAC##*/}"
if [[ -z "$FPS_DEN" || "$FPS_DEN" == "$FPS_FRAC" ]]; then FPS_DEN=1; fi
FPS_DECIMAL=$(echo "scale=10; $FPS_NUM / $FPS_DEN" | bc | fix_leading_zero)

echo "Detected framerate: $FPS_FRAC ($FPS_DECIMAL fps)"

# Get total number of frames
TOTAL_FRAMES=$(ffprobe -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT_VIDEO")

echo "Total frames: $TOTAL_FRAMES"
echo "Creating video with burned-in frame info..."
echo "Output: $OUTPUT_VIDEO"

# Two drawtext filters chained with a comma:
#   Top-left:  per-frame info — Frame, Time, Dec
#   Top-right: fixed fps fraction (e.g. "fps: 30000/1001"), baked in at encode time
#
# %{n}         = frame number (0-indexed)
# %{pts\:hms}  = PTS as HH:MM:SS.mmm
# %{pts\:flt}  = PTS as floating-point seconds
# w and w-tw are used to right-align the fps label (w=video width, tw=text width)
ffmpeg -i "$INPUT_VIDEO" \
    -vf "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf:\
text='Frame\: %{n}  |  Time\: %{pts\:hms}  |  Dec\: %{pts\:flt}':fontcolor=white:fontsize=24:\
box=1:boxcolor=black@0.7:boxborderw=5:x=10:y=10,\
drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf:\
text='fps\: ${FPS_FRAC}':fontcolor=white:fontsize=24:\
box=1:boxcolor=black@0.7:boxborderw=5:x=w-tw-10:y=10" \
    -c:v libx264 \
    -preset ultrafast \
    -crf 23 \
    -c:a copy \
    "$OUTPUT_VIDEO"

echo ""
echo "Done: $OUTPUT_VIDEO"

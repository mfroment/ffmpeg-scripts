#!/usr/bin/env bash

# video-frame-burn.sh
#
# Creates a video copy with frame number and timestamps burned onto each frame.
# Burned info: frame number (0-indexed), decimal seconds, and hh:mm:ss.ms time.
#
# Usage: ./video-frame-burn.sh <input> [output]
#   <output> defaults to <input>_frameinfo.<ext> if omitted

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <input_video> [output_video]"
    echo "Example: $0 video.mp4"
    echo "         $0 video.mp4 custom_output.mp4"
    exit 1
fi

input_file="$1"

if [ ! -f "$input_file" ]; then
    echo "Error: File '$input_file' does not exist"
    exit 1
fi

# If output file is not specified, generate filename with _frameinfo suffix
if [ "$#" -eq 2 ]; then
    output_file="$2"
else
    dir=$(dirname "$input_file")
    filename=$(basename "$input_file")
    name="${filename%.*}"
    ext="${filename##*.}"
    output_file="${dir}/${name}_frameinfo.${ext}"
fi

echo "Analyzing video..."

# Get video framerate as a fraction (e.g. "30000/1001"), then compute decimal with bc.
# bc is used (not awk) for consistency with video-cut.sh; fix_leading_zero handles
# the case where bc outputs ".333" instead of "0.333" (rejected by some tools).
fix_leading_zero() { sed 's/^\./0./;s/^-\./-0./'; }

fps_frac=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$input_file")
fps_num="${fps_frac%%/*}"
fps_den="${fps_frac##*/}"
if [[ -z "$fps_den" || "$fps_den" == "$fps_frac" ]]; then fps_den=1; fi
fps_decimal=$(echo "scale=10; $fps_num / $fps_den" | bc | fix_leading_zero)

echo "Detected framerate: $fps_frac ($fps_decimal fps)"

# Get total number of frames
total_frames=$(ffprobe -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames \
    -of default=noprint_wrappers=1:nokey=1 "$input_file")

echo "Total frames: $total_frames"
echo "Creating video with burned-in frame info..."
echo "Output: $output_file"

# Two drawtext filters chained with a comma:
#   Top-left:  per-frame info — Frame, Time, Dec
#   Top-right: fixed fps fraction (e.g. "fps: 30000/1001"), baked in at encode time
#
# %{n}         = frame number (0-indexed)
# %{pts\:hms}  = PTS as HH:MM:SS.mmm
# %{pts\:flt}  = PTS as floating-point seconds
# w and w-tw are used to right-align the fps label (w=video width, tw=text width)
ffmpeg -i "$input_file" \
    -vf "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf:\
text='Frame\: %{n}  |  Time\: %{pts\:hms}  |  Dec\: %{pts\:flt}':fontcolor=white:fontsize=24:\
box=1:boxcolor=black@0.7:boxborderw=5:x=10:y=10,\
drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf:\
text='fps\: ${fps_frac}':fontcolor=white:fontsize=24:\
box=1:boxcolor=black@0.7:boxborderw=5:x=w-tw-10:y=10" \
    -c:v libx264 \
    -preset ultrafast \
    -crf 23 \
    -c:a copy \
    "$output_file"

echo ""
echo "Done: $output_file"

#!/bin/bash

# video-frame-burn.sh

# Script to create a video copy with frame number and timestamp burned onto each frame
# Usage: ./video-frame-burn.sh input_video.mp4 [output_video.mp4]

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <input_video> [output_video]"
    echo "Example: $0 video.mp4"
    echo "         $0 video.mp4 custom_output.mp4"
    exit 1
fi

INPUT_VIDEO="$1"

# If output file is not specified, generate filename with _frameinfo suffix
if [ "$#" -eq 2 ]; then
    OUTPUT_VIDEO="$2"
else
    # Extract directory, filename and extension
    INPUT_DIR=$(dirname "$INPUT_VIDEO")
    FILENAME=$(basename "$INPUT_VIDEO")
    STEM="${FILENAME%.*}"
    EXT="${FILENAME##*.}"
    OUTPUT_VIDEO="${INPUT_DIR}/${STEM}_frameinfo.${EXT}"
fi

# Check that input file exists
if [ ! -f "$INPUT_VIDEO" ]; then
    echo "Error: File '$INPUT_VIDEO' does not exist"
    exit 1
fi

echo "Analyzing video..."

# Get video framerate
FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT_VIDEO")
FPS_DECIMAL=$(echo "scale=10; $FPS" | bc)

echo "Detected framerate: $FPS ($FPS_DECIMAL fps)"

# Get total number of frames
TOTAL_FRAMES=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 "$INPUT_VIDEO")

echo "Total frames: $TOTAL_FRAMES"
echo "Creating video with burned-in frame info..."
echo "Output file: $OUTPUT_VIDEO"

# Use ffmpeg to burn frame info onto video
# drawtext filter displays frame number and timestamp
# Using fast encoding preset for speed, keeping audio intact
ffmpeg -i "$INPUT_VIDEO" \
    -vf "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf:\
text='Frame\: %{n} | Time\: %{pts\:hms}':fontcolor=white:fontsize=24:\
box=1:boxcolor=black@0.7:boxborderw=5:x=10:y=10" \
    -c:v libx264 \
    -preset ultrafast \
    -crf 23 \
    -c:a copy \
    "$OUTPUT_VIDEO"

echo ""  # New line after ffmpeg output
echo "Done! Video with frame info created: $OUTPUT_VIDEO"
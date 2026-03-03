#!/bin/bash

# video-cut.sh
#
# Usage: ./video-cut.sh <start> <end> <input> <output>
#
# Time formats accepted for <start> and <end>:
#   123        plain seconds (integer or decimal, e.g. 88, 3.14)
#   mm:ss      minutes and seconds (e.g. 1:30)
#   hh:mm:ss   hours, minutes, seconds (e.g. 0:01:30)
#   p/q        exact rational seconds (e.g. 30000/1001)
#   fN         frame number, 0-indexed (e.g. f120)

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 start_time end_time input_file output_file"
    exit 1
fi

startArg=$1
endArg=$2
inputFile=$3
outputFile=$4

# Ensure bc output always has a leading zero before the decimal point.
# bc outputs ".333" for values < 1; ffmpeg 6.x rejects that format.
fix_leading_zero() {
    sed 's/^\./0./;s/^-\./-0./'
}

# Get fps as a raw fraction string "num/den" (e.g. "30000/1001" or "25/1").
get_fps_fraction() {
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of default=nw=1:nokey=1 "$1"
}

# Convert a time argument to decimal seconds.
convert_to_seconds() {
    local input="$1"

    # ---- fN: frame number ----
    if [[ "$input" =~ ^f([0-9]+)$ ]]; then
        local frame="${BASH_REMATCH[1]}"
        local fps_frac fps_num fps_den
        fps_frac=$(get_fps_fraction "$inputFile")
        fps_num="${fps_frac%%/*}"
        fps_den="${fps_frac##*/}"
        if [[ -z "$fps_den" || "$fps_den" == "$fps_frac" ]]; then fps_den=1; fi
        echo "scale=10; $frame * $fps_den / $fps_num" | bc | fix_leading_zero
        return
    fi

    # ---- p/q: exact rational seconds ----
    if [[ "$input" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        local p="${BASH_REMATCH[1]}" q="${BASH_REMATCH[2]}"
        echo "scale=10; $p / $q" | bc | fix_leading_zero
        return
    fi

    # ---- hh:mm:ss, mm:ss, or plain seconds ----
    IFS=: read -r -a parts <<< "$input"
    case "${#parts[@]}" in
        1) echo "${parts[0]}" ;;
        2) echo "${parts[0]} * 60 + ${parts[1]}" | bc ;;
        3) echo "${parts[0]} * 3600 + ${parts[1]} * 60 + ${parts[2]}" | bc ;;
        *) echo "Invalid time format: '$input'" >&2; exit 1 ;;
    esac
}

# Parse start/end times
startTime=$(convert_to_seconds "$startArg")
endTime=$(convert_to_seconds "$endArg")

# Guard against empty or inverted range
isEmpty=$(echo "$endTime <= $startTime" | bc -l)
if [ "$isEmpty" -eq 1 ]; then
    echo "Error: end time ($endArg) must be strictly greater than start time ($startArg)." >&2
    exit 1
fi

# Get the video codec name, bit rate, and time base from the original video
video_info=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,bit_rate,time_base -of default=nw=1 "$inputFile")
video_codec=$(echo "$video_info" | grep -oP 'codec_name=\K.*')
time_base=$(echo "$video_info" | grep -oP 'time_base=\K.*' | cut -d'/' -f2)

# Find the next keyframe time after the provided start time
keyframeTime=$(ffprobe -select_streams v -show_frames -skip_frame nokey -show_entries "frame=pkt_dts_time,pict_type" -of csv -v quiet -i "$inputFile" | grep ",I" | awk -F',' -v st="$startTime" '$2 > st {print $2; exit}')

if [ -z "$keyframeTime" ]; then
    echo "No keyframe found."
    exit 1
fi

# Intermediate files need to be created with the same container (= extension) otherwise there can
# be glitches when concatenating them later
fileExtension="${inputFile##*.}"

# Create temp files names with the appropriate extension
temp1="___temp1_$$.$fileExtension"
temp2="___temp2_$$.$fileExtension"
temp_video="___temp_video_$$.$fileExtension"
temp_audio="___temp_audio_$$.$fileExtension"
temp_list="___temp_list_$$.txt"

# Re-encode the small portion from the start time to the nearest keyframe
ffmpeg -y -ss "$startTime" -to "$keyframeTime" -i "$inputFile" -c:v "$video_codec" -an -strict -2 -video_track_timescale "$time_base" "$temp1"

# Cut using the original codec from nearest keyframe to the end
ffmpeg -y -i "$inputFile" -ss "$keyframeTime" -to "$endTime" -c:v copy -an "$temp2"

# Concatenate the video parts
echo -e "file '$temp1'\nfile '$temp2'" > "$temp_list"
ffmpeg -y -f concat -safe 0 -i "$temp_list" -c copy -copyts "$temp_video"

# Cut the audio (exactly at start with exact duration)
videoDuration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$temp_video")
ffmpeg -y -i "$inputFile" -ss "$startTime" -t "$videoDuration" -vn -c:a copy "$temp_audio"

# Add the cut audio to the final video
ffmpeg -y -i "$temp_video" -i "$temp_audio" -c:v copy -c:a copy "$outputFile"

# Cleanup
rm "$temp1" "$temp2" "$temp_audio" "$temp_video" "$temp_list"

#!/bin/bash

# video-cut.sh

# Usage: ./video-cut.sh 88 188 input.webm output.webm

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 start_time end_time input_file output_file"
    exit 1
fi

startTime=$1
endTime=$2
inputFile=$3
outputFile=$4

# Utility function to convert time to seconds
convert_to_seconds() {
    local timeString="$1"
    IFS=: read -r -a parts <<< "$timeString"
    local seconds=0

    if [[ ${#parts[@]} -eq 1 ]]; then
        # Single value (seconds with possible decimal)
        seconds="${parts[0]}"
    elif [[ ${#parts[@]} -eq 2 ]]; then
        # Two values (minutes:seconds)
        seconds=$(echo "${parts[0]} * 60 + ${parts[1]}" | bc)
    elif [[ ${#parts[@]} -eq 3 ]]; then
        # Three values (hours:minutes:seconds)
        seconds=$(echo "${parts[0]} * 3600 + ${parts[1]} * 60 + ${parts[2]}" | bc)
    else
        echo "Invalid time format. Too many parts."
        exit 1
    fi

    echo "$seconds"
}

# Parse start/end times
startTime=$(convert_to_seconds "$startTime")
endTime=$(convert_to_seconds "$endTime")

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
temp1="___temp1.$fileExtension"
temp2="___temp2.$fileExtension"
temp_video="___temp_video.$fileExtension"
temp_audio="___temp_audio.$fileExtension"
temp_list="___temp_list.txt"

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

#!/usr/bin/env bash

# video-cut.sh
#
# Cuts a segment from a video between specified start and end times,
# re-encoding only the portion from the start time to the nearest keyframe
# (if needed) for accurate cutting, then stream-copying the rest for speed.
# The audio is cut exactly to match the final video duration.
#
# Usage: ./video-cut.sh <start> <end> <input> [<output>]
#   <output> defaults to <input>_cut.<ext> if omitted
#
# Time formats accepted for <start> and <end>:
#   123        plain seconds (integer or decimal, e.g. 88, 3.14)
#   mm:ss      minutes and seconds (e.g. 1:30)
#   hh:mm:ss   hours, minutes, seconds (e.g. 0:01:30)
#   p/q        exact rational seconds (e.g. 30000/1001)
#   fN         frame number, 0-indexed (e.g. f120). Note: for CFR videos only

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 start_time end_time input [output]"
    exit 1
fi

start_arg=$1
end_arg=$2
input_file=$3
if [ "$#" -eq 4 ]; then
    output_file=$4
else
    base="${input_file%.*}"
    ext="${input_file##*.}"
    output_file="${base}_cut.${ext}"
fi

# Ensure bc output always has a leading zero before the decimal point.
# bc outputs ".333" for values < 1; ffmpeg 6.x rejects that format.
fix_leading_zero() {
    sed 's/^\./0./;s/^-\./-0./'
}

# Evaluate a bc expression and round the result to the nearest millisecond.
calc_ms() {
    echo "scale=3; ($(echo "scale=10; $1" | bc) + 0.0005) / 1" | bc | fix_leading_zero
}

# Get fps as a raw fraction string "num/den" (e.g. "30000/1001" or "25/1").
get_fps_fraction() {
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of default=nw=1:nokey=1 "$1"
}

# Cache fps fraction upfront — used by convert_to_seconds for fN inputs.
# Only fetched once even if both start and end are frame numbers.
fps_frac=$(get_fps_fraction "$input_file")
fps_num="${fps_frac%%/*}"
fps_den="${fps_frac##*/}"
if [[ -z "$fps_den" || "$fps_den" == "$fps_frac" ]]; then fps_den=1; fi

# Convert a time argument to decimal seconds.
convert_to_seconds() {
    local input="$1"

    # ---- fN: frame number ----
    if [[ "$input" =~ ^f([0-9]+)$ ]]; then
        local frame="${BASH_REMATCH[1]}"
        if [[ -z "$fps_frac" ]]; then
            echo "Error: could not read frame rate from '$input_file'." >&2; exit 1
        fi
        calc_ms "$frame * $fps_den / $fps_num"
        return
    fi

    # ---- p/q: exact rational seconds ----
    if [[ "$input" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        local p="${BASH_REMATCH[1]}" q="${BASH_REMATCH[2]}"
        calc_ms "$p / $q"
        return
    fi

    # ---- hh:mm:ss, mm:ss, or plain seconds ----
    local -a parts
    IFS=: read -r -a parts <<< "$input"
    case "${#parts[@]}" in
        1) echo "${parts[0]}" ;;
        2) echo "${parts[0]} * 60 + ${parts[1]}" | bc ;;
        3) echo "${parts[0]} * 3600 + ${parts[1]} * 60 + ${parts[2]}" | bc ;;
        *) echo "Invalid time format: '$input'" >&2; exit 1 ;;
    esac
}

# Parse start/end times
start_time=$(convert_to_seconds "$start_arg")
end_time=$(convert_to_seconds "$end_arg")

# Guard against empty or inverted range
is_empty=$(echo "$end_time <= $start_time" | bc -l)
if [ "$is_empty" -eq 1 ]; then
    echo "Error: end time ($end_arg) must be strictly greater than start time ($start_arg)." >&2
    exit 1
fi

# Get the video codec name, bit rate, and time base from the original video
video_info=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,bit_rate,time_base -of default=nw=1 "$input_file")
src_codec=$(echo "$video_info" | grep -oP 'codec_name=\K.*')
time_base=$(echo "$video_info" | grep -oP 'time_base=\K.*' | cut -d'/' -f2)

# libaom-av1 is the reference encoder and extremely slow; prefer libsvtav1 for re-encode steps
case "$src_codec" in
    av1) video_encoder="libsvtav1" ;;
    *) video_encoder="$src_codec" ;;
esac

# Find the next keyframe time after the provided start time.
# pkt_dts_time returns N/A for some containers (e.g. mkv/Constrained Baseline),
# so fall back to best_effort_timestamp_time if needed.
keyframe_time=$(ffprobe -read_intervals "${start_time}%+60" -select_streams v -show_frames -skip_frame nokey -show_entries "frame=pkt_dts_time,pict_type" -of csv -v quiet -i "$input_file" | grep ",I" | awk -F',' -v st="$start_time" '$2 != "N/A" && $2 > st {print $2; exit}')

if [ -z "$keyframe_time" ]; then
    keyframe_time=$(ffprobe -read_intervals "${start_time}%+60" -select_streams v -show_frames -skip_frame nokey -show_entries "frame=best_effort_timestamp_time,pict_type" -of csv -v quiet -i "$input_file" | grep ",I" | awk -F',' -v st="$start_time" '$2 > st {print $2; exit}')
fi

if [ -z "$keyframe_time" ]; then
    echo "No keyframe found."
    exit 1
fi

# Intermediate files need to be created with the same container (= extension) otherwise there can
# be glitches when concatenating them later
ext="${input_file##*.}"

# Create temp files names with the appropriate extension
temp1="___temp1_$$.$ext"
temp2="___temp2_$$.$ext"
temp_video="___temp_video_$$.$ext"
temp_audio="___temp_audio_$$.$ext"
temp_list="___temp_list_$$.txt"

# Re-encode the small portion from the start time to the nearest keyframe,
# then stream-copy the rest. If the end time falls before the keyframe,
# re-encode the whole range in one pass instead.
if [ "$(echo "$end_time <= $keyframe_time" | bc -l)" -eq 1 ]; then
    # Entire range is within one GOP: re-encode from start to end.
    ffmpeg -y -ss "$start_time" -to "$end_time" -i "$input_file" -c:v "$video_encoder" -crf 18 -an -strict -2 -video_track_timescale "$time_base" "$temp_video"
else
    # General case: re-encode start→(just before keyframe), stream-copy keyframe→end, concat.
    # The keyframe is the first frame of the stream-copied part, so the re-encoded stub must
    # stop one frame short of it — otherwise the keyframe lands in both halves and is duplicated
    # at the join. Trim by half a frame to drop the keyframe while keeping the frame before it.
    half_frame=$(echo "scale=10; $fps_den / ($fps_num * 2)" | bc | fix_leading_zero)
    stub_end=$(echo "$keyframe_time - $half_frame" | bc -l | fix_leading_zero)

    # Fast input seek (-ss before -i) lands exactly on the keyframe. Bound the copy with -t
    # (duration) rather than -to/-copyts so temp2 stays zero-based — timestamp-identical to the
    # original output-seek version, which keeps the concat join glitch-free.
    seg_duration=$(echo "$end_time - $keyframe_time" | bc -l | fix_leading_zero)

    if [ "$(echo "$stub_end <= $start_time" | bc -l)" -eq 1 ]; then
        # start_time is within one frame of the keyframe: the desired first frame *is* the
        # keyframe, so skip the re-encoded stub and stream-copy straight from it.
        ffmpeg -y -ss "$keyframe_time" -i "$input_file" -t "$seg_duration" -c:v copy -an "$temp_video"
    else
        ffmpeg -y -ss "$start_time" -to "$stub_end" -i "$input_file" -c:v "$video_encoder" -crf 18 -an -strict -2 -video_track_timescale "$time_base" "$temp1"
        ffmpeg -y -ss "$keyframe_time" -i "$input_file" -t "$seg_duration" -c:v copy -an "$temp2"
        echo -e "file '$temp1'\nfile '$temp2'" > "$temp_list"
        ffmpeg -y -f concat -safe 0 -i "$temp_list" -c copy -copyts "$temp_video"
        rm "$temp1" "$temp2" "$temp_list"
    fi
fi

# Cut the audio (exactly at start with exact duration)
video_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$temp_video")
ffmpeg -y -i "$input_file" -ss "$start_time" -t "$video_duration" -vn -c:a copy "$temp_audio"

# Add the cut audio to the final video
ffmpeg -y -i "$temp_video" -i "$temp_audio" -c:v copy -c:a copy "$output_file"

# Cleanup
rm "$temp_audio" "$temp_video"

#!/bin/bash

# video-cut.sh
#
# Cuts a video with minimal re-encoding: only the frames between the start
# point and the next keyframe are re-encoded; the rest is stream-copied.
#
# Semantics: [start, end[ (start inclusive, end exclusive)
#
# Usage: ./video-cut.sh <start> <end> <input> <o>
#
# Time formats accepted for <start> and <end>:
#   123        plain seconds (integer or decimal, e.g. 88, 3.14)
#   p/q        exact rational seconds (e.g. 30000/1001) — immune to rounding errors
#   mm:ss      minutes and seconds (e.g. 1:30)
#   hh:mm:ss   hours, minutes, seconds (e.g. 0:01:30)
#   fN         frame number, 0-indexed (e.g. f120)
#
# Notes:
#   - All formats can be mixed (e.g. start=f120 end=1:30)
#   - Out-of-bounds end times are clamped to the video duration
#   - Concurrent runs are safe: all temp files are tagged with the process ID

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <start> <end> <input> <o>"
    echo "  Times: plain seconds, p/q rational, mm:ss, hh:mm:ss, or fN (frame number)"
    exit 1
fi

startArg=$1
endArg=$2
inputFile=$3
outputFile=$4

if [ ! -f "$inputFile" ]; then
    echo "Error: '$inputFile' does not exist." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

# Get video duration in seconds (decimal string from ffprobe).
get_duration() {
    ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$1"
}

# ---------------------------------------------------------------------------
# Parse a time argument into an exact decimal seconds string for ffmpeg.
#
# For fN inputs, also writes a 1/3-frame epsilon to $_epsilon_file, which
# the caller uses to adjust boundaries for muxer timestamp quantization.
# For all other input formats, $_epsilon_file is left empty.
# ---------------------------------------------------------------------------
_epsilon_file="___epsilon_$$.tmp"

parse_arg() {
    local input="$1"
    echo "" > "$_epsilon_file"

    # ---- fN: frame number ----
    if [[ "$input" =~ ^f([0-9]+)$ ]]; then
        local frame="${BASH_REMATCH[1]}"
        local fps_frac fps_num fps_den
        fps_frac=$(get_fps_fraction "$inputFile")
        if [[ -z "$fps_frac" ]]; then
            echo "Error: could not read frame rate from '$inputFile'." >&2; exit 1
        fi
        fps_num="${fps_frac%%/*}"
        fps_den="${fps_frac##*/}"
        if [[ -z "$fps_den" || "$fps_den" == "$fps_frac" ]]; then fps_den=1; fi
        # Exact rational: frame_time = frame * fps_den / fps_num (seconds)
        echo "scale=10; $frame * $fps_den / $fps_num" | bc | fix_leading_zero
        # Epsilon = 1/3 frame, large enough to absorb 1ms muxer quantization
        # (valid for fps < 666), small enough to never cross an adjacent frame.
        echo "scale=10; $fps_den / (3 * $fps_num)" | bc | fix_leading_zero > "$_epsilon_file"
        return
    fi

    # ---- p/q: exact rational seconds (e.g. 30000/1001) ----
    if [[ "$input" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        local p="${BASH_REMATCH[1]}" q="${BASH_REMATCH[2]}"
        echo "scale=10; $p / $q" | bc | fix_leading_zero
        return
    fi

    # ---- hh:mm:ss, mm:ss, or plain seconds ----
    IFS=: read -r -a parts <<< "$input"
    case "${#parts[@]}" in
        1) echo "scale=10; ${parts[0]} / 1" | bc | fix_leading_zero ;;
        2) echo "scale=10; ${parts[0]} * 60 + ${parts[1]}" | bc | fix_leading_zero ;;
        3) echo "scale=10; ${parts[0]} * 3600 + ${parts[1]} * 60 + ${parts[2]}" | bc | fix_leading_zero ;;
        *) echo "Invalid time format: '$input'" >&2; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Parse start and end arguments
# ---------------------------------------------------------------------------

startTime=$(parse_arg "$startArg")
startEpsilon=$(cat "$_epsilon_file")

endTime=$(parse_arg "$endArg")
endEpsilon=$(cat "$_epsilon_file")

rm "$_epsilon_file"

# startTimeRaw: nominal frame timestamp, used as the actual ffmpeg -ss value.
# startTime:    startTimeRaw minus epsilon, used only for the keyframe search
#               to robustly find the right keyframe even if the muxer rounded
#               the stored timestamp slightly upward.
startTimeRaw="$startTime"

if [[ -n "$startEpsilon" ]]; then
    startTime=$(echo "scale=10; $startTime - $startEpsilon" | bc | fix_leading_zero)
fi

# endTime has epsilon subtracted so that if the muxer rounded the stored
# timestamp of frame N slightly downward, our -to still excludes frame N,
# honouring [start, end[ semantics.
if [[ -n "$endEpsilon" ]]; then
    endTime=$(echo "scale=10; $endTime - $endEpsilon" | bc | fix_leading_zero)
fi

# Clamp to [0, duration]
videoDuration=$(get_duration "$inputFile")
startTimeRaw=$(echo "scale=10; t=$startTimeRaw; d=$videoDuration; if (t < 0) 0 else if (t > d) d else t" | bc | fix_leading_zero)
startTime=$(   echo "scale=10; t=$startTime;    d=$videoDuration; if (t < 0) 0 else if (t > d) d else t" | bc | fix_leading_zero)
endTime=$(     echo "scale=10; t=$endTime;      d=$videoDuration; if (t > d) d else t"                    | bc | fix_leading_zero)

# Guard against empty or inverted range (e.g. fN fN)
isEmpty=$(echo "$endTime <= $startTime" | bc -l)
if [ "$isEmpty" -eq 1 ]; then
    echo "Error: empty range — end ($endArg) must be strictly greater than start ($startArg)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Codec info and global frame epsilon
# ---------------------------------------------------------------------------

video_info=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,bit_rate,time_base \
    -of default=nw=1 "$inputFile")
video_codec=$(echo "$video_info" | grep -oP 'codec_name=\K.*')
time_base=$(echo "$video_info"   | grep -oP 'time_base=\K.*' | cut -d'/' -f2)

# frameEpsilon: 1/3-frame tolerance used for keyframe boundary comparisons.
fps_frac=$(get_fps_fraction "$inputFile")
fps_num="${fps_frac%%/*}"
fps_den="${fps_frac##*/}"
if [[ -z "$fps_den" || "$fps_den" == "$fps_frac" ]]; then fps_den=1; fi
frameEpsilon=$(echo "scale=10; $fps_den / (3 * $fps_num)" | bc | fix_leading_zero)

# ---------------------------------------------------------------------------
# Find the first keyframe at or after startTime, and the last one before it.
#
# best_effort_timestamp_time is used instead of pkt_dts_time because the
# latter returns N/A for many containers (e.g. mkv/h264).
#
# prevKeyframeTime is used as the fast input-seek point for re-encode steps:
# ffmpeg jumps directly to it (it's a keyframe), then a short output-seek
# covers the remaining gap to startTime. This avoids decoding from frame 0
# on large files while preserving absolute PTS values for accurate -to.
# ---------------------------------------------------------------------------

keyframeData=$(ffprobe -select_streams v -show_frames -skip_frame nokey \
    -show_entries "frame=best_effort_timestamp_time,pict_type" \
    -of csv -v quiet -i "$inputFile" \
    | awk -F',' -v st="$startTime" '
        $2 >= st { print prev "\n" $2; exit }
        { prev = $2 }
    ')

prevKeyframeTime=$(echo "$keyframeData" | head -1)
keyframeTime=$(echo "$keyframeData" | tail -1)

# If startTime is before the first keyframe, there is no previous keyframe
if [ -z "$prevKeyframeTime" ]; then prevKeyframeTime="0"; fi

if [ -z "$keyframeTime" ]; then
    echo "Error: no keyframe found at or after ${startTime}s." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Temp files — PID-tagged so concurrent runs don't collide
# ---------------------------------------------------------------------------

fileExtension="${inputFile##*.}"
temp1="___temp1_$$.$fileExtension"
temp2="___temp2_$$.$fileExtension"
temp_video="___temp_video_$$.$fileExtension"
temp_audio="___temp_audio_$$.$fileExtension"
temp_list="___temp_list_$$.txt"

# ---------------------------------------------------------------------------
# Cut video (audio is handled separately and muxed at the end)
# ---------------------------------------------------------------------------

# isOnKeyframe uses a tolerance because startTimeRaw (exact rational) and
# keyframeTime (ffprobe string) may differ slightly for the same frame.
isOnKeyframe=$(echo "define abs(x) { if (x<0) return -x; return x; }; abs($keyframeTime - $startTimeRaw) < $frameEpsilon" | bc)
endBeforeKeyframe=$(echo "$endTime <= $keyframeTime" | bc -l)

if [ "$isOnKeyframe" -eq 1 ]; then
    # Start is on a keyframe: pure stream-copy, no re-encode needed.
    ffmpeg -y -i "$inputFile" -ss "$keyframeTime" -to "$endTime" -c:v copy -an "$temp_video"

elif [ "$endBeforeKeyframe" -eq 1 ]; then
    # The entire range falls within one GOP: re-encode from start to end.
    # Two-stage seek: input-seek to prevKeyframeTime (fast), then output-seek
    # to startTimeRaw (accurate, preserves absolute PTS for correct -to).
    startOffset=$(echo "scale=10; $startTimeRaw - $prevKeyframeTime" | bc | fix_leading_zero)
    endOffset=$(echo "scale=10; $endTime - $prevKeyframeTime" | bc | fix_leading_zero)
    ffmpeg -y -ss "$prevKeyframeTime" -i "$inputFile" \
        -ss "$startOffset" -to "$endOffset" \
        -c:v "$video_codec" -an -strict -2 \
        -video_track_timescale "$time_base" "$temp_video"

else
    # General case: re-encode from startTimeRaw to keyframeTime (temp1),
    # stream-copy from keyframeTime to endTime (temp2), then concatenate.
    #
    # frameEpsilon is subtracted from keyframeOffset so that the encoder does
    # not include the keyframe itself in temp1 (it will be the first frame of
    # temp2). The guard ensures this subtraction never makes the range empty.
    startOffset=$(echo "scale=10; $startTimeRaw - $prevKeyframeTime" | bc | fix_leading_zero)
    keyframeOffset=$(echo "scale=10; $keyframeTime - $prevKeyframeTime - $frameEpsilon" | bc | fix_leading_zero)
    isKeyframeOffsetValid=$(echo "$keyframeOffset > $startOffset" | bc -l)
    if [ "$isKeyframeOffsetValid" -eq 0 ]; then
        keyframeOffset=$(echo "scale=10; $keyframeTime - $prevKeyframeTime" | bc | fix_leading_zero)
    fi

    ffmpeg -y -ss "$prevKeyframeTime" -i "$inputFile" \
        -ss "$startOffset" -to "$keyframeOffset" \
        -c:v "$video_codec" -an -strict -2 \
        -video_track_timescale "$time_base" "$temp1"

    ffmpeg -y -i "$inputFile" -ss "$keyframeTime" -to "$endTime" -c:v copy -an "$temp2"

    echo -e "file '$temp1'\nfile '$temp2'" > "$temp_list"
    ffmpeg -y -f concat -safe 0 -i "$temp_list" -c copy -copyts "$temp_video"

    rm "$temp1" "$temp2" "$temp_list"
fi

# ---------------------------------------------------------------------------
# Cut audio to match video duration exactly, then mux
# ---------------------------------------------------------------------------

tempVideoDuration=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$temp_video")

ffmpeg -y -i "$inputFile" -ss "$startTimeRaw" -t "$tempVideoDuration" -vn -c:a copy "$temp_audio"
ffmpeg -y -i "$temp_video" -i "$temp_audio" -c:v copy -c:a copy "$outputFile"

rm "$temp_audio" "$temp_video"

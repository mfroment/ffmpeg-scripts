# video-cut.ps1

# When specifying start and end times with ffmpeg for cutting a video
# without reencoding, ffmpeg looks for the nearest keyframe and starts
# there. In order to start at the exact start time, the part between
# the start time and the first keyframe is reencoded with the same
# codec as the input video, then is concatenated with the rest of the
# video (not reencoded). The audio is cut separately and recombined with
# the video.
#
# Note: this works for webm containing VP9+opus but it's possible that some
#       other combinations require additional tweaks.

# Prerequisite: portable installation of ffmpeg, e.g. in C:\Portable\ffmpeg
# Script installation: put in the scripts folder in the ffmped installation folder, e.g. in C:\Portable\ffmpeg\scripts
# Running: You may need to bypass the policy disabling script execution
#    powershell -ExecutionPolicy Bypass -File C:\Portable\ffmpeg\scripts\video-cut.ps1 88 188 input.webm output.webm
#    (or use the bat file)

param (
    [string]$startTime,
    [string]$endTime,
    [string]$inputFile,
    [string]$outputFile
)

# Utility function
function Convert-ToSeconds {
    param (
        [string]$timeString
    )
    # Split the string by colons and reverse the array
    $parts = $timeString -split ":"
    [Array]::Reverse($parts)
    # Throw if more than 3 parts, otherwise pad with zeroes if needed
    if ($parts.Length -gt 3) {
        throw "Invalid time format. Too many parts."
    }
    while ($parts.Length -lt 3) {
        $parts += 0
    }
    $seconds = [double]$parts[0]
    $minutes = [double]$parts[1]
    $hours = [double]$parts[2]
    return ($hours * 3600) + ($minutes * 60) + $seconds
}

# parse start/end times:
$startTime = [double](Convert-ToSeconds $startTime)
$endTime = [double](Convert-ToSeconds $endTime)

# Define paths to ffmpeg and ffprobe based on the script's location
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$ffmpegPath = "$scriptDir\..\bin\ffmpeg.exe"
$ffprobePath = "$scriptDir\..\bin\ffprobe.exe"

# Get the video codec name, bit rate and time base from the original video
$video_info = & $ffprobePath -v error -select_streams v:0 -show_entries stream=codec_name,bit_rate,time_base -of default=nw=1 $inputFile
$video_codec = ($video_info -match "codec_name=(.*)")[0].Split("=")[1]
$time_base = (($video_info -match "time_base=(.*)")[0].Split("=")[1] -split "/")[1]

# Get the audio codec name from the original video (unused)
# $audio_info = & $ffprobePath -v error -select_streams a:0 -show_entries stream=codec_name,bit_rate -of default=nw=1 $inputFile
# $audio_codec = ($audio_info -match "codec_name=(.*)")[0].Split("=")[1]

# Find the next keyframe time after the provided start time
# Note: use -skip_frame nokey for speed/correctness (some videos return the incorrect timestamps otherwise)
$keyframeTime = $null
$ffprobeOutput = & $ffprobePath -select_streams v -show_frames -skip_frame nokey -show_entries "frame=pkt_dts_time,pict_type" -of csv -v quiet -i $inputFile 2>&1
foreach ($line in $ffprobeOutput) {
    if ($line -match ",I") {
        $fields = $line -split ","
        $thisKeyframeTime = [double]$fields[1]
        if ($thisKeyframeTime -gt $startTime) {
            $keyframeTime = $thisKeyframeTime
            break
        }
    }
}

if ($null -eq $keyframeTime) {
    Write-Host "No keyframe found."
    exit 1
}

# Intermediate files need to be created with the same container (= extension) otherwise there can
# be glitches when concataining them later
$fileExtension = [System.IO.Path]::GetExtension($inputFile)

# Create temp files names with the appropriate extension
$temp1 = "___temp1$fileExtension"
$temp2 = "___temp2$fileExtension"
$temp_video = "___temp_video$fileExtension"
$temp_audio = "___temp_audio$fileExtension"
$temp_list = "___temp_list.txt"

# Re-encode the small portion from the start time to the nearest keyframe
& $ffmpegPath -ss $startTime -to $keyframeTime -i $inputFile -c:v $video_codec -an -strict -2 -video_track_timescale $time_base $temp1

# Cut using the original codec from nearest keyframe to the end
& $ffmpegPath -i $inputFile -ss $keyframeTime -to $endTime -c:v copy -an $temp2

# Concatenate the video parts
@"
file '$temp1'
file '$temp2'
"@ | Out-File -FilePath $temp_list -Encoding ascii

& $ffmpegPath -f concat -safe 0 -i $temp_list -c copy -copyts $temp_video

# Cut the audio (exactly at start with exact duration)
$videoDuration = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $temp_video
& $ffmpegPath -i $inputFile -ss $startTime -t $videoDuration -vn -c:a copy $temp_audio

# Add the cut audio to the final video
& $ffmpegPath -i $temp_video -i $temp_audio -c:v copy -c:a copy $outputFile

# Cleanup
Remove-Item $temp1, $temp2, $temp_audio, $temp_video, $temp_list

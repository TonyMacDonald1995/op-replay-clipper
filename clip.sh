#!/usr/bin/bash

set -ex

# Cleanup processes for easy fast testing.
# Rely on Docker to clean up containers processes in production though
function cleanup() {
    tmux list-panes -s -t clipper -F "#{pane_pid} #{pane_current_command}" \
    | grep -v tmux | awk '{print $1}' | xargs kill -9 || true
}

function ctrl_c() {
    cleanup
    pkill -P $$ || true
}
# trap ctrl-c and call ctrl_c()
trap ctrl_c INT

# Cleanup stale stuff from last run
cleanup

STARTING_SEC=${1:-60}
# Sometimes it takes a bit of time for openpilot drawing to settle in.
SMEAR_AMOUNT=30
SMEARED_STARTING_SEC=$(($STARTING_SEC - $SMEAR_AMOUNT))
RECORDING_LENGTH=${7:-30}
ROUTE=${2:-4cf7a6ad03080c90|2021-09-29--13-46-36}
JWT_AUTH=${3:-false}
VIDEO_CWD=${4:-/shared}
VIDEO_RAW_OUTPUT=${5:-$VIDEO_CWD/clip.mkv}
VIDEO_OUTPUT=${6:-$VIDEO_CWD/clip.mp4}

# Starting seconds must be greater than 30
if [ "$STARTING_SEC" -lt $SMEAR_AMOUNT ]; then
    echo "Starting seconds must be greater than $SMEAR_AMOUNT"
    exit 1
fi

pushd /home/batman/openpilot

if [ "$JWT_AUTH" != "false" ]; then
    mkdir -p "$HOME"/.comma/
    echo "{\"access_token\": \"$JWT_AUTH\"}" > "$HOME"/.comma/auth.json
fi

# Start processes
tmux new-session -d -s clipper -n x11 "Xtigervnc :0 -geometry 1920x1080 -SecurityTypes None"
tmux new-window -n replay -t clipper: "TERM=xterm-256color faketime -m -f \"+0 x0.5\" ./tools/replay/replay -s \"$SMEARED_STARTING_SEC\" \"$ROUTE\""
tmux new-window -n ui -t clipper: 'faketime -m -f "+0 x0.5" ./selfdrive/ui/ui'

# Pause replay and let it download the route
tmux send-keys -t clipper:replay Space
sleep 3

tmux send-keys -t clipper:replay Enter "$SMEARED_STARTING_SEC" Enter
tmux send-keys -t clipper:replay Space
sleep 1
tmux send-keys -t clipper:replay Space

# Generate and start overlay
echo "Route: $ROUTE , Starting Second: $STARTING_SEC" > /tmp/overlay.txt
overlay /tmp/overlay.txt &

# Record with ffmpeg
mkdir -p "$VIDEO_CWD"
pushd "$VIDEO_CWD"
ffmpeg -framerate 10 -video_size 1920x1080 -f x11grab -draw_mouse 0 -i :0.0 -ss "$SMEAR_AMOUNT" -vcodec libx264rgb -crf 0 -preset ultrafast -r 20 -filter:v "setpts=0.5*PTS,scale=1920:1080" -y -t "$RECORDING_LENGTH" "$VIDEO_RAW_OUTPUT"
# The setup is no longer needed. Just transcode now.
cleanup
ffmpeg -y -i "$VIDEO_RAW_OUTPUT" -c:v libx264 -b:v 2060k -pix_fmt yuv420p -preset medium -pass 1 -an -f MP4 /dev/null
ffmpeg -y -i "$VIDEO_RAW_OUTPUT" -c:v libx264 -b:v 2060k -pix_fmt yuv420p -preset medium -pass 2 -movflags +faststart -f MP4 "$VIDEO_OUTPUT"

ctrl_c

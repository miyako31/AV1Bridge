#!/bin/sh
# Benchmarks raw AV1-decode + H.264-encode throughput on this VPS,
# completely bypassing OBS, the network, and MediaMTX/RTSP. This isolates
# the question "can this CPU do the transcode in real time at all" from
# network jitter, RTSP read-blocking, and OBS-side variables.
#
# Method: generate a short synthetic AV1 clip locally (motion pattern,
# not real gameplay -- treat this as a rough capability signal, not a
# guarantee real footage behaves identically), then run it through the
# exact same dav1d-decode -> libx264-encode command used in
# mediamtx.yml's runOnAvailable, with NO real-time pacing on the input
# (no -re) so ffmpeg processes flat out. The final speed= is the
# sustained multiple of real-time this CPU can do for that
# resolution/fps -- e.g. speed=1.4x means it could keep up with margin
# to spare; speed=0.6x means it would fall behind exactly like the
# live run did.
#
# Runs inside the relay container so it uses the exact same ffmpeg
# binary/build as production.
set -e

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No .env found -- copy .env.example to .env first."
  exit 1
fi
# shellcheck disable=SC1091
. ./.env

X264_PRESET="${X264_PRESET:-veryfast}"
CLIP_SECONDS=12

# WIDTHxHEIGHT@FPS:BITRATE -- covers the 360p60 to 1080p30 range this
# project targets. Edit this list to test other combinations.
RESOLUTIONS="
640x360@60:2500k
854x480@30:2500k
1280x720@30:4000k
1920x1080@30:5000k
"

echo "Benchmarking with X264_PRESET=${X264_PRESET} (from .env), ${CLIP_SECONDS}s clips."
echo "No -re on the input -- ffmpeg runs flat out, so speed= directly reflects"
echo "the sustained multiple of real-time this CPU can do at each setting."
echo

printf "%-16s %-10s %s\n" "RESOLUTION@FPS" "BITRATE" "RESULT"
printf "%-16s %-10s %s\n" "--------------" "-------" "------"

for entry in $RESOLUTIONS; do
  res_fps="${entry%%:*}"
  bitrate="${entry##*:}"
  res="${res_fps%%@*}"
  fps="${res_fps##*@}"
  width="${res%%x*}"
  height="${res##*x}"

  # 1. Generate a synthetic AV1 test clip at this resolution/fps.
  #    SVT-AV1 preset 10 (fast) is used purely to build the fixture
  #    quickly -- it has no bearing on the actual benchmark, which
  #    exercises dav1d (decode) + libx264 (encode) only.
  docker compose exec -T relay ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=${width}x${height}:rate=${fps}" \
    -t "$CLIP_SECONDS" \
    -c:v libsvtav1 -preset 10 \
    -f matroska /tmp/bench.mkv

  # 2. Run the actual transcode pipeline, flat out, and capture the
  #    final speed= value.
  result=$(docker compose exec -T relay ffmpeg -hide_banner -nostdin \
    -i /tmp/bench.mkv \
    -c:v libx264 -preset "$X264_PRESET" -threads 0 \
    -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$((${bitrate%k} * 2))k" \
    -g "$fps" -keyint_min "$fps" -sc_threshold 0 \
    -an -f null - 2>&1 | grep -o 'speed=[0-9.]*x' | tail -1)

  printf "%-16s %-10s %s\n" "${res}@${fps}" "$bitrate" "${result:-FAILED}"
done

echo
echo "speed= >= 1.0x means this CPU can sustain that resolution/fps in real"
echo "time with software encoding alone. Below 1.0x means it can't, and"
echo "no amount of network/RTSP tuning will fix that -- only a lower"
echo "resolution/fps, a faster X264_PRESET, or more/faster CPU will."

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
# Also runs a DECODE-ONLY pass on the same clip (dav1d only, no
# encoder at all -- `ffmpeg -i ... -f null -` with no -c:v, the
# standard technique for isolating decode cost) so you can see how much
# of the total cost is decode vs encode. In practice libx264 is almost
# always the dominant cost; a DECODE speed= far above the DECODE+ENCODE
# speed= confirms encoding is what's actually limiting you, not dav1d.
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

# Figure out which relay container (if any) is already running --
# production, no-tls, or local all use the same ffmpeg build, so any of
# them works for this benchmark. Detection is by container_name (fixed
# in each compose file), not "docker compose ps", since relay-local/
# relay-no-tls live in separate compose files this script isn't
# otherwise pointed at.
if docker ps --format '{{.Names}}' | grep -qx 'av1-relay'; then
  COMPOSE_ARGS=""
  SERVICE="relay"
elif docker ps --format '{{.Names}}' | grep -qx 'av1-relay-no-tls'; then
  COMPOSE_ARGS="-f docker-compose.no-tls.yml"
  SERVICE="relay-no-tls"
elif docker ps --format '{{.Names}}' | grep -qx 'av1-relay-local'; then
  COMPOSE_ARGS="-f docker-compose.local.yml"
  SERVICE="relay-local"
else
  # Default to the local variant when auto-starting: it needs no certs,
  # DuckDNS, or auth setup (just .env), so it's the one most likely to
  # actually start successfully on a fresh checkout. Production has
  # more prerequisites (issued cert, DuckDNS configured) and will fail
  # to start without them -- start it explicitly yourself first if
  # that's the one you want benchmarked.
  echo "No relay container is running -- starting the local variant (docker compose -f docker-compose.local.yml up -d)..."
  docker compose -f docker-compose.local.yml up -d
  COMPOSE_ARGS="-f docker-compose.local.yml"
  SERVICE="relay-local"

  # Give the container a moment to actually be ready for `exec` before
  # the first real command below fails on a race.
  tries=0
  until docker compose $COMPOSE_ARGS exec -T "$SERVICE" true 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 15 ]; then
      echo "Container did not become ready in time. Check 'docker compose -f docker-compose.local.yml logs relay-local'."
      exit 1
    fi
    sleep 1
  done
fi
echo "Using service: $SERVICE"
echo

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

printf "%-16s %-10s %-14s %s\n" "RESOLUTION@FPS" "BITRATE" "DECODE ONLY" "DECODE+ENCODE"
printf "%-16s %-10s %-14s %s\n" "--------------" "-------" "-----------" "-------------"

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
  docker compose $COMPOSE_ARGS exec -T "$SERVICE" ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=${width}x${height}:rate=${fps}" \
    -t "$CLIP_SECONDS" \
    -c:v libsvtav1 -preset 10 \
    -f matroska /tmp/bench.mkv

  # 2. Decode-only pass: no -c:v at all, so ffmpeg decodes every frame
  #    with dav1d and immediately discards it into the null muxer --
  #    no encoder CPU cost included at all.
  decode_result=$(docker compose $COMPOSE_ARGS exec -T "$SERVICE" ffmpeg -hide_banner -nostdin \
    -i /tmp/bench.mkv \
    -an -f null - 2>&1 | grep -o 'speed=[0-9.]*x' | tail -1)

  # 3. Full pipeline: decode + libx264 encode, same as production.
  full_result=$(docker compose $COMPOSE_ARGS exec -T "$SERVICE" ffmpeg -hide_banner -nostdin \
    -i /tmp/bench.mkv \
    -c:v libx264 -preset "$X264_PRESET" -threads 0 \
    -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$((${bitrate%k} * 2))k" \
    -g "$fps" -keyint_min "$fps" -sc_threshold 0 \
    -an -f null - 2>&1 | grep -o 'speed=[0-9.]*x' | tail -1)

  printf "%-16s %-10s %-14s %s\n" "${res}@${fps}" "$bitrate" "${decode_result:-FAILED}" "${full_result:-FAILED}"
done

echo
echo "speed= >= 1.0x means this CPU can sustain that resolution/fps in real"
echo "time. Below 1.0x means it can't, and no amount of network/RTSP tuning"
echo "will fix that -- only a lower resolution/fps, a faster X264_PRESET, or"
echo "more/faster CPU will."
echo
echo "If DECODE ONLY is much higher than DECODE+ENCODE, libx264 (encoding) is"
echo "the bottleneck, not dav1d (decoding) -- this is the case for almost"
echo "every real-world setup, since encoding does far more computational work"
echo "(motion search, mode decisions, rate control) than decoding does."

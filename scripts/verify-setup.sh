#!/bin/sh
# Sanity checks to run after `docker compose up -d --build`, before
# spending time tuning bitrates.
set -e

cd "$(dirname "$0")/.."

echo "== 1. Codec support inside the built image =="
echo "(expect to see 'dav1d' decoder for AV1 and 'libx264' encoder for H.264)"
docker compose exec relay ffmpeg -hide_banner -decoders 2>/dev/null | grep -i av1 || echo "  !! no AV1 decoder found"
docker compose exec relay ffmpeg -hide_banner -encoders 2>/dev/null | grep -i libx264 || echo "  !! libx264 encoder not found"
echo

echo "== 2. Enhanced RTMP / FLV support (need FFmpeg >= 6.1) =="
docker compose exec relay ffmpeg -version 2>/dev/null | head -n1
echo

echo "== 3. Container status =="
docker compose ps
echo

echo "== 4. Is OBS currently publishing to /home? =="
echo "(queried via the loopback-only API from inside the container)"
docker compose exec relay wget -qO- http://127.0.0.1:9997/v3/paths/list 2>/dev/null \
  || echo "  No response -- either the container isn't up yet, or nothing has published yet."
echo

echo "== 5. Live ffmpeg transcode speed (Ctrl+C to stop watching) =="
echo "Look for 'speed=' in the tail below -- it must stay >= 1.0x to keep up in real time."
docker compose logs -f --tail=20 relay

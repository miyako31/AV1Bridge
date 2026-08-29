# Stage 1: grab the official MediaMTX binary (its own image is a scratch
# image with no shell/package manager, so we only copy the binary out of it).
FROM bluenviron/mediamtx:1 AS mediamtx

# Stage 2: fetch a recent static FFmpeg build.
#
# Alpine's packaged ffmpeg (6.1.2 as of Alpine 3.22) predates FFmpeg's
# AV1 RTP depacketizer, which only landed upstream in December 2024.
# Without it, ffmpeg cannot read the AV1 track back out of MediaMTX over
# RTSP at all -- it shows up as "Video: none, none: unknown codec" even
# though MediaMTX is serving it correctly. (MediaMTX can only serve AV1
# read-out over RTSP/WebRTC/HLS, not RTMP, which is why this project
# uses RTSP for that internal hop in the first place -- see mediamtx.yml.)
#
# BtbN's "master-latest" build is a statically-linked Linux binary that
# tracks current FFmpeg git and is rebuilt daily, so it always has
# whatever's newest upstream -- including AV1 RTP support, and libdav1d
# (AV1 decode) / libx264 (H.264 encode) which it also ships with.
# The "latest" tag is a stable, permanent URL (not a version number).
FROM debian:13-slim AS ffmpeg-fetch
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl xz-utils ca-certificates \
    && curl -fsSL \
      https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz \
      -o /tmp/ffmpeg.tar.xz \
    && mkdir -p /tmp/ffmpeg \
    && tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ffmpeg --strip-components=1 \
    && rm -rf /var/lib/apt/lists/* /tmp/ffmpeg.tar.xz

FROM alpine:3.22

RUN apk add --no-cache ca-certificates

COPY --from=mediamtx /mediamtx /mediamtx
COPY --from=ffmpeg-fetch /tmp/ffmpeg/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-fetch /tmp/ffmpeg/bin/ffprobe /usr/local/bin/ffprobe
COPY mediamtx.yml /mediamtx.yml

ENTRYPOINT ["/mediamtx"]
CMD ["/mediamtx.yml"]

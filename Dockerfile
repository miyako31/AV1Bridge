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
#
# The full archive also contains ffplay, docs, man pages, static libs,
# and headers we don't need (several hundred MB once extracted) -- only
# bin/ffmpeg and bin/ffprobe are pulled out of it. The archive's
# top-level directory name changes on every build (it embeds a git
# commit hash), so it's read from the archive itself rather than
# hardcoded. This matters on small-disk VPS instances.
FROM alpine:3.22 AS ffmpeg-fetch
RUN apk add --no-cache curl tar xz \
    && curl -fsSL \
      https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz \
      -o /tmp/ffmpeg.tar.xz \
    && TOPDIR="$(tar -tf /tmp/ffmpeg.tar.xz | head -1 | cut -d/ -f1)" \
    && mkdir -p /tmp/ffmpeg \
    && tar -xf /tmp/ffmpeg.tar.xz -C /tmp/ffmpeg "$TOPDIR/bin/ffmpeg" "$TOPDIR/bin/ffprobe" \
    && mv "/tmp/ffmpeg/$TOPDIR/bin/ffmpeg" /tmp/ffmpeg/ffmpeg \
    && mv "/tmp/ffmpeg/$TOPDIR/bin/ffprobe" /tmp/ffmpeg/ffprobe \
    && rm -rf "/tmp/ffmpeg/$TOPDIR" /tmp/ffmpeg.tar.xz

FROM debian:13-slim

# ffmpeg's codec libraries (libx264, libdav1d, etc.) are statically
# linked into the binary itself, but the binary still dynamically links
# against the base C library at runtime (confirmed via `ldd`: only
# libc/libm/libpthread/libgcc_s -- nothing codec-related). Alpine uses
# musl instead of glibc and has no compatible dynamic linker for this
# binary at all, so the final image needs to be glibc-based. Debian's
# own -slim variant already ships everything ffmpeg needs here with no
# extra packages required.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=mediamtx /mediamtx /mediamtx
COPY --from=ffmpeg-fetch /tmp/ffmpeg/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-fetch /tmp/ffmpeg/ffprobe /usr/local/bin/ffprobe
COPY mediamtx.yml /mediamtx.yml

ENTRYPOINT ["/mediamtx"]
CMD ["/mediamtx.yml"]

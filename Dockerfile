# Stage 1: grab the official MediaMTX binary (its own image is a scratch
# image with no shell/package manager, so we only copy the binary out of it).
FROM bluenviron/mediamtx:1 AS mediamtx

# Stage 2: Alpine's ffmpeg package already includes libdav1d (AV1 decode)
# and libx264 (H.264 encode) out of the box, so a plain `apk add ffmpeg`
# is enough -- no need to build ffmpeg from source.
#
# NOTE: Enhanced RTMP (the extension that allows AV1 over RTMP/FLV at all)
# requires FFmpeg >= 6.1. Alpine 3.22 ships a much newer version than that,
# so this is safe. If you ever change the base image, re-check with:
#   docker run --rm <image> ffmpeg -version
FROM alpine:3.22

RUN apk add --no-cache ffmpeg ca-certificates openssl

COPY --from=mediamtx /mediamtx /mediamtx
COPY mediamtx.yml /mediamtx.yml

ENTRYPOINT ["/mediamtx"]
CMD ["/mediamtx.yml"]

# linuxserver.io Docker Mod: Vulkan/libplacebo HDR tone mapping for Plex on AMD.
#
# Builds Plex's own GPL source with --enable-vulkan --enable-libplacebo, then bundles the
# binary with its libplacebo/Vulkan/RADV stack. Bundling is what makes the mod portable:
# the container's Ubuntu version no longer has to match the build.
#
# 24.04 rather than the container's 26.04 on purpose -- glibc is forward-compatible, so an
# older build runs on newer containers but not the reverse.
FROM --platform=linux/amd64 ubuntu:24.04 AS build

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential curl ca-certificates pkg-config nasm \
        libplacebo-dev libvulkan-dev libshaderc-dev libva-dev libdrm-dev \
        ocl-icd-opencl-dev libass-dev libdav1d-dev libopus-dev \
        libvorbis-dev libxml2-dev libssl-dev libzvbi-dev \
        mesa-vulkan-drivers mesa-va-drivers libdrm-common \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY build.sh collect-libs.sh ./
RUN bash build.sh
RUN bash collect-libs.sh "/src/dist/Plex Transcoder" /source/plex-placebo \
    && install -Dm755 "/src/dist/Plex Transcoder" /source/plex-placebo/bin/Plex-Transcoder-placebo \
    && cp /src/dist/PLEX_SOURCE_SHA /source/plex-placebo/

COPY plex-transcoder-wrapper.sh /source/plex-placebo/bin/wrapper.sh
COPY root/ /source/
RUN chmod +x /source/plex-placebo/bin/wrapper.sh \
    && find /source/etc/s6-overlay -name run -exec chmod +x {} +

FROM scratch
COPY --from=build /source/ /

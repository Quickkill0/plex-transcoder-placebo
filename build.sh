#!/bin/bash
# Builds Plex Transcoder from Plex's published GPL source with Vulkan + libplacebo enabled.
#
# Plex ships ffmpeg 6.1.3, which already contains vf_libplacebo and the whole Vulkan stack;
# they simply omit the flags at build time. So this is a flag flip, not a patch series.
set -euo pipefail

SRC_URL="${SRC_URL:-https://downloads.plex.tv/ffmpeg-source/}"
WORK="${WORK:-$(pwd)/work}"
OUT="${OUT:-$(pwd)/dist}"

mkdir -p "$WORK" "$OUT"

echo "==> Fetching Plex transcoder source"
curl -sSL --compressed --max-time 600 "$SRC_URL" -o "$WORK/plex-ffmpeg.tar.gz"
gunzip -c "$WORK/plex-ffmpeg.tar.gz" > "$WORK/plex-ffmpeg.tar"

# sed rather than `head -1`: head exits early, tar takes SIGPIPE, pipefail kills the build.
SRCDIR=$(tar -tf "$WORK/plex-ffmpeg.tar" | sed -n '1{s|/.*||;p;}')
# Tarball dir is plexinc-plex-media-server-ffmpeg-gpl-<sha>; the sha prefix also names the
# Codecs/ dir of the matching PMS build, which is how you confirm source matches your server.
PLEX_SHA="${SRCDIR##*-}"
echo "==> Source: $SRCDIR (sha ${PLEX_SHA:0:7})"

# Plex serves only "latest", so what arrives can differ from what the caller resolved
# earlier. Fail loudly rather than publishing an image tagged with a sha it isn't.
EXPECT_SHA="${EXPECT_SHA:-unpinned}"
if [ "$EXPECT_SHA" != unpinned ] && [ "$EXPECT_SHA" != "$PLEX_SHA" ]; then
    echo "ERROR: expected source sha $EXPECT_SHA but got $PLEX_SHA"
    exit 1
fi

rm -rf "${WORK:?}/$SRCDIR"
tar -xf "$WORK/plex-ffmpeg.tar" -C "$WORK"
cd "$WORK/$SRCDIR"

# Sanity: bail loudly if Plex ever drops to a base without libplacebo, rather than
# silently producing a transcoder that can't tone map.
test -f libavfilter/vf_libplacebo.c || { echo "ERROR: vf_libplacebo.c absent; base changed"; exit 1; }

echo "==> Configuring"
# Deviations from Plex's own configure, and why:
#  - no --enable-gpl: Plex builds LGPL (--enable-openssl would conflict). libplacebo is LGPL.
#  - decoders/encoders left at ffmpeg defaults instead of Plex's hand-picked minimal set.
#    Plex externalises h264/hevc as dlopen'd musl-linked blobs for patent reasons; compiling
#    them in avoids that ABI mess entirely (wrapper must unset FFMPEG_EXTERNAL_LIBS).
#  - no --fatal-warnings: their clang/musl toolchain is clean, gcc/glibc is not.
#  - static (ffmpeg default) rather than their --enable-shared + XORIGIN rpath dance.
# Explicitly bash: Plex's "Fix hwaccel autodetection" block uses ${var/pat/sub}, which dash
# (Ubuntu's /bin/sh) rejects with "Bad substitution".
bash ./configure \
  --prefix="$OUT" \
  --enable-vulkan \
  --enable-libplacebo \
  --enable-libshaderc \
  --enable-vaapi \
  --enable-libdrm \
  --enable-libass \
  --enable-libdav1d \
  --enable-libopus \
  --enable-libvorbis \
  --enable-libxml2 \
  --enable-openssl \
  --enable-eae \
  --disable-doc \
  --disable-ffplay \
  --disable-debug

echo "==> Building"
make -j"$(nproc)"

install -Dm755 ffmpeg "$OUT/Plex Transcoder"

# Write to a file rather than piping: `grep -q` exits on first match, the binary takes
# SIGPIPE, and pipefail reports that as a failed build.
"$OUT/Plex Transcoder" -hide_banner -filters > "$WORK/filters.txt"
grep -q libplacebo "$WORK/filters.txt" \
  || { echo "ERROR: built binary has no libplacebo filter"; exit 1; }

echo "$PLEX_SHA" > "$OUT/PLEX_SOURCE_SHA"

# LGPL: a binary must be accompanied by its corresponding source. Plex's URL only ever
# serves "latest", so linking to it would rot the moment they publish again -- ship the
# exact tarball this was built from instead, and let it travel with the binary.
cp "$WORK/plex-ffmpeg.tar.gz" "$OUT/plex-ffmpeg-source-$PLEX_SHA.tar.gz"
TARBALL_SHA256=$(sha256sum "$WORK/plex-ffmpeg.tar.gz" | cut -d' ' -f1)
install -Dm644 LICENSE.md "$OUT/licenses/ffmpeg-LICENSE.md"
install -Dm644 COPYING.LGPLv2.1 "$OUT/licenses/COPYING.LGPLv2.1"
cat > "$OUT/licenses/SOURCE.txt" <<EOF
This binary is a build of Plex's published GPL/LGPL ffmpeg source, unmodified except for
the configure flags in build.sh (notably --enable-vulkan --enable-libplacebo).

Upstream source sha : $PLEX_SHA
Obtained from       : $SRC_URL
Tarball sha256      : $TARBALL_SHA256
Corresponding source: plex-ffmpeg-source-$PLEX_SHA.tar.gz, alongside this file.

ffmpeg is licensed LGPL v2.1 or later; see COPYING.LGPLv2.1 and ffmpeg-LICENSE.md.
This build does not enable --enable-gpl.
EOF
echo "==> Done: $OUT/Plex Transcoder (source sha ${PLEX_SHA:0:7})"

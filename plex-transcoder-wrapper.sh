#!/bin/sh
# Swaps Plex's software tone mapping for GPU libplacebo, and chains to whatever binary was
# at this path before us for everything else.
set -eu

DIR=$(dirname "$0")
CHAINED="$DIR/Plex Transcoder.preplacebo"
CUSTOM="${PLACEBO_TRANSCODER:-/plex-placebo/bin/Plex-Transcoder-placebo}"

# bt.2390 is the ITU reference curve; Plex's default `hable` is a film-emulation
# approximation that crushes highlights by comparison.
PLACEBO='libplacebo=tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=nv12'

log() { [ -n "${PLACEBO_DEBUG:-}" ] && printf '%s\n' "$*" >> /tmp/plex-placebo.log || true; }

# Non-tonemapping jobs stay on the chained binary: it has the EAE audio path and Plex's
# codec blobs, and there's nothing for us to improve there anyway.
case " $* " in
    *" -filter_complex "*) ;;
    *) exec "$CHAINED" "$@" ;;
esac
case "$*" in
    *tonemap=*) ;;
    *) exec "$CHAINED" "$@" ;;
esac
[ -x "$CUSTOM" ] || { log "custom binary missing, chaining"; exec "$CHAINED" "$@"; }

# Rebuild argv, rewriting the filter graph in place.
matched=
n=$#
while [ "$n" -gt 0 ]; do
    a=$1; shift
    n=$((n - 1))
    case $a in
        *tonemap=*)
            # `format=p010,` only exists to feed the software tonemap filter; libplacebo
            # takes the 10-bit frames directly. Trailing `format=pix_fmts=nv12` is left
            # alone -- it becomes a no-op passthrough.
            new=$(printf '%s' "$a" | sed -E "s/(format=p010,)?tonemap=[a-zA-Z0-9._]+/$PLACEBO/g")
            [ "$new" != "$a" ] && matched=1
            a=$new
            ;;
    esac
    set -- "$@" "$a"
done

[ -n "$matched" ] || { log "no rewrite applied, chaining"; exec "$CHAINED" "$@"; }

# Bundled libplacebo/Vulkan first, so we get the versions this binary was built against
# rather than whatever the container happens to ship. Any LD_LIBRARY_PATH already set
# (e.g. by the vaapi-amdgpu mod) is preserved after ours -- we need its libva to encode.
export LD_LIBRARY_PATH="/plex-placebo/lib:${LD_LIBRARY_PATH:-}"
export VK_DRIVER_FILES="/plex-placebo/icd.d/radeon_icd.x86_64.json"
export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
export MESA_SHADER_CACHE_DIR="${MESA_SHADER_CACHE_DIR:-/config/cache/placebo}"

# Our build compiles h264/hevc in natively; Plex's codec blobs are musl-linked and
# would fail to dlopen against a glibc binary.
unset FFMPEG_EXTERNAL_LIBS

log "rewrote: $*"
exec "$CUSTOM" "$@"

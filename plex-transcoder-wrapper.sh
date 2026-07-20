#!/bin/sh
# Swaps Plex's software tone mapping for GPU libplacebo, and chains to whatever binary was
# at this path before us for everything else.
set -u

# ${0%/*} rather than $(dirname "$0"): a command substitution here runs before every path
# through this script, so a broken PATH would kill all transcoding, not just tone mapping.
DIR=${0%/*}
CHAINED="$DIR/Plex Transcoder.preplacebo"
CUSTOM="${PLACEBO_TRANSCODER:-/plex-placebo/bin/Plex-Transcoder-placebo}"

# Every curve Plex's UI offers (linear/gamma/clip/reinhard/hable/mobius) exists in
# libplacebo under the same name, so the setting is carried across rather than overridden --
# the mod's job is to move tone mapping onto the GPU, not to second-guess the user's look.
# PLACEBO_TONEMAP forces a curve Plex can't select, e.g. bt.2390 or spline.
PLACEBO_CURVES='auto clip st2094-40 st2094-10 bt.2390 bt.2446a spline reinhard mobius hable gamma linear'

log() { [ -n "${PLACEBO_DEBUG:-}" ] && printf '%s\n' "$*" >> /tmp/plex-placebo.log; return 0; }

exec_custom() {
    # Bundled libplacebo/Vulkan/VA first, so we get the versions this binary was built
    # against rather than whatever the container ships. Any existing LD_LIBRARY_PATH (e.g.
    # from the vaapi-amdgpu mod) is kept after ours as a fallback.
    #
    # Ours does shadow that mod's libva. That's deliberate: its stack is musl-built and our
    # binary is glibc, so they can't be mixed -- we carry a matching glibc libva and VA
    # driver instead. If VAAPI encoding ever breaks after a container bump, look here first.
    export LD_LIBRARY_PATH="/plex-placebo/lib:${LD_LIBRARY_PATH:-}"
    export LIBVA_DRIVERS_PATH="/plex-placebo/lib/dri"
    export VK_DRIVER_FILES="/plex-placebo/icd.d/radeon_icd.x86_64.json"
    export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
    # Additive, so it can't hide the container's own layers. Only does anything when the
    # user sets MESA_VK_DEVICE_SELECT to pick between multiple AMD GPUs; ignored by loaders
    # too old to know the variable.
    export VK_ADD_IMPLICIT_LAYER_PATH="/plex-placebo/layer.d"
    export MESA_SHADER_CACHE_DIR="${MESA_SHADER_CACHE_DIR:-/config/cache/placebo}"
    # Our build compiles h264/hevc in natively; Plex's codec blobs are musl-linked and
    # would fail to dlopen against a glibc binary.
    unset FFMPEG_EXTERNAL_LIBS
    # Terminal by design: once exec'd we cannot fall back, and a runtime failure (GPU busy,
    # /dev/dri perms, driver mismatch after a container bump) surfaces to Plex as a failed
    # transcode. Retrying via the chain would mean buffering output to know whether the
    # first attempt produced any, which is not worth the complexity for a case that means
    # the mod is misconfigured anyway.
    exec "$CUSTOM" "$@"
}

# Every fallback goes through here, so a missing chain target can't take out all
# transcoding: our own build is a complete ffmpeg and is a better last resort than exiting.
chain() {
    [ -x "$CHAINED" ] && exec "$CHAINED" "$@"
    log "chain target missing: $CHAINED"
    [ -x "$CUSTOM" ] && exec_custom "$@"
    echo "plex-transcoder-placebo: no usable transcoder found" >&2
    exit 127
}

case "$*" in
    *tonemap=*) ;;
    *) chain "$@" ;;
esac
[ -x "$CUSTOM" ] || { log "custom binary missing, chaining"; chain "$@"; }

# Find the filter graph up front. Everything below inspects it before any rewriting, so an
# unsuitable job can still chain with the original argv intact. Getting that ordering wrong
# is expensive: a bad graph only fails once libplacebo initialises, by which point we have
# exec'd and can no longer fall back.
graph=
prev=
for a in "$@"; do
    case $prev in
        -filter_complex|-vf|-filter:v|-filter:0)
            case $a in
                *tonemap=*) graph=$a; break ;;
            esac
            ;;
    esac
    prev=$a
done
[ -n "$graph" ] || { log "no tone map in a filter graph, chaining"; chain "$@"; }

# Plex encodes the output resolution as scale filters in the graph. Tone mapping at 4K is
# heavy shader work -- on a small iGPU it runs well under realtime and is slower than Plex's
# software path -- while at 1080p it is comfortably faster and far cheaper on CPU. Clients
# that can actually play 4K direct stream it, so a 4K-output transcode is rare and not worth
# taking over. Only step in when we are downscaling to the threshold or below.
max_h=0
for h in $(printf '%s' "$graph" | grep -oE 'scale[^,;]*h=[0-9]+' | grep -oE '[0-9]+$') \
         $(printf '%s' "$graph" | grep -oE 'scale=[0-9]+:[0-9]+' | cut -d: -f2); do
    [ "$h" -gt "$max_h" ] && max_h=$h
done
if [ "$max_h" -eq 0 ]; then
    # No scale filter means the output is the source resolution, which argv doesn't tell us.
    # Chaining is the safe read: assuming 1080p would hand 4K jobs to the slow path.
    log "no scale filter, cannot determine output height, chaining"
    chain "$@"
fi
if [ "$max_h" -gt "${PLACEBO_MAX_HEIGHT:-1080}" ]; then
    log "output height $max_h above threshold ${PLACEBO_MAX_HEIGHT:-1080}, chaining"
    chain "$@"
fi

curve="${PLACEBO_TONEMAP:-}"
if [ -z "$curve" ]; then
    # Handles `tonemap=hable`, `tonemap=hable:desat=0` and Plex's
    # `tonemap=tonemap=hable:param=1.0` spelling.
    curve=$(printf '%s' "$graph" \
        | sed -nE 's/.*tonemap=(tonemap=)?([a-zA-Z0-9._-]+).*/\2/p')
fi

case " $PLACEBO_CURVES " in
    *" $curve "*) ;;
    *) log "curve '$curve' not supported by libplacebo, chaining"; chain "$@" ;;
esac

PLACEBO="libplacebo=tonemapping=$curve:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=nv12"

# Rebuild argv, rewriting only the value that follows a filter-graph flag. Rewriting any arg
# containing `tonemap=` would corrupt e.g. a title or a filename that happened to contain it.
matched=
prev=
n=$#
while [ "$n" -gt 0 ]; do
    a=$1; shift
    n=$((n - 1))
    case $prev in
        -filter_complex|-vf|-filter:v|-filter:0)
            case $a in
                *tonemap=*)
                    # [^,[;]* consumes the filter's own options too. Matching only the
                    # algorithm name would strip `tonemap=hable:desat=0` down to `hable`
                    # and leave `:desat=0` dangling on libplacebo, which rejects it and
                    # kills the job -- and by then `matched` has disabled the fallback.
                    new=$(printf '%s' "$a" \
                        | sed -E "s/(format=(pix_fmts=)?p010,)?tonemap=[^],;[]+/$PLACEBO/g") || new=$a
                    [ "$new" != "$a" ] && matched=1
                    a=$new
                    ;;
            esac
            ;;
    esac
    prev=$a
    set -- "$@" "$a"
done

[ -n "$matched" ] || { log "no rewrite applied, chaining"; chain "$@"; }

log "rewrote: $*"
exec_custom "$@"

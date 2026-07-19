#!/bin/sh
# MITM wrapper: installed at Plex's transcoder path, swaps software tone mapping for
# GPU libplacebo, and execs the real binary for everything else.
#
# Install:
#   mv "Plex Transcoder" "Plex Transcoder.orig"
#   install -m755 plex-transcoder-wrapper.sh "Plex Transcoder"
set -eu

DIR=$(dirname "$0")
REAL="$DIR/Plex Transcoder.orig"
CUSTOM="${PLACEBO_TRANSCODER:-$DIR/Plex Transcoder.placebo}"

# bt.2390 is the ITU reference curve; Plex's default `hable` is a film-emulation
# approximation that crushes highlights by comparison.
PLACEBO='libplacebo=tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=nv12'

log() { [ -n "${PLACEBO_DEBUG:-}" ] && printf '%s\n' "$*" >> /tmp/plex-placebo.log || true; }

# Non-tonemapping jobs stay on Plex's own binary: it has the EAE audio path and the
# dlopen'd codec blobs, and there's nothing for us to improve there anyway.
case " $* " in
    *" -filter_complex "*) ;;
    *) exec "$REAL" "$@" ;;
esac
case "$*" in
    *tonemap=*) ;;
    *) exec "$REAL" "$@" ;;
esac
[ -x "$CUSTOM" ] || { log "custom binary missing, falling back"; exec "$REAL" "$@"; }

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

[ -n "$matched" ] || { log "no rewrite applied, falling back"; exec "$REAL" "$@"; }
log "rewrote: $*"

# Our build compiles h264/hevc in natively; Plex's codec blobs are musl-linked and
# would fail to dlopen against a glibc binary.
unset FFMPEG_EXTERNAL_LIBS

exec "$CUSTOM" "$@"

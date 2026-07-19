#!/bin/sh
# Installs the placebo transcoder + wrapper into a running Plex container.
# Idempotent: safe to run on every container start.
#
# For linuxserver/plex, drop this at /custom-cont-init.d/99-placebo so it survives
# container recreation and Plex package updates (both restore the stock binary).
set -eu

PLEX_DIR="${PLEX_DIR:-/usr/lib/plexmediaserver}"
REPO="${REPO:?set REPO to <user>/<repo>}"
TAG="${TAG:-latest}"

cd "$PLEX_DIR"

if [ "$TAG" = latest ]; then
    url=$(curl -sSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -o 'https://[^"]*plex-transcoder-placebo-[^"]*\.tar\.gz' | head -1)
else
    url="https://github.com/$REPO/releases/download/$TAG/plex-transcoder-placebo-$TAG.tar.gz"
fi
[ -n "$url" ] || { echo "no release asset found for $REPO"; exit 1; }

tmp=$(mktemp -d)
curl -sSL "$url" | tar -xz -C "$tmp"
install -m755 "$tmp/Plex Transcoder" "$PLEX_DIR/Plex Transcoder.placebo"
rm -rf "$tmp"

# A Plex update replaces "Plex Transcoder" with the stock binary, so re-stash it --
# but never overwrite a good .orig with our own wrapper on a second run.
if ! head -c2 "Plex Transcoder" | grep -q '#!'; then
    mv -f "Plex Transcoder" "Plex Transcoder.orig"
fi

install -m755 "${WRAPPER:-/config/plex-transcoder-wrapper.sh}" "$PLEX_DIR/Plex Transcoder"
echo "installed: placebo transcoder + wrapper in $PLEX_DIR"

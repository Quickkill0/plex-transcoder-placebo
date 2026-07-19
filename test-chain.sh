#!/bin/bash
# Regression tests for the install guard in the s6 init script.
#
# The guard is fiddly because plex-vaapi-amdgpu-mod wraps the same path, s6 gives no
# ordering guarantee between two independent oneshots, and a `docker restart` re-runs init
# against an already-modified filesystem. Getting it wrong is destructive: moving a wrapper
# over a chain target that holds the real binary loses it permanently.
set -uo pipefail
REPO=$(cd "$(dirname "$0")" && pwd)
fail=0

setup() {
    SIM=$(mktemp -d)
    PLEXDIR="$SIM/plexdir"; MOD="$SIM/mod"
    mkdir -p "$PLEXDIR" "$MOD/bin" "$SIM/init"
    # A genuine ELF stands in for the real transcoder, so the script-detection guard sees a
    # binary; echoing its args makes "did the chain reach it" observable.
    cp /bin/echo "$PLEXDIR/Plex Transcoder"
    cp /bin/echo "$SIM/real_reference"
    install -m755 "$REPO/plex-transcoder-wrapper.sh" "$MOD/bin/wrapper.sh"
    sed -e "s|/plex-placebo|$MOD|g" -e '1s|.*|#!/bin/bash|' \
        "$REPO/root/etc/s6-overlay/s6-rc.d/init-mod-plex-placebo/run" > "$SIM/init/placebo"
    chmod +x "$SIM/init/placebo"
    # Stand-in for plex-vaapi-amdgpu-mod: wraps the same path, guards on its own backup.
    cat > "$SIM/init/vaapi" <<EOF
#!/bin/bash
set -eu
T="$PLEXDIR/Plex Transcoder"; O="$PLEXDIR/Plex Transcoder.orig"
if [ ! -f "\$O" ]; then
    mv "\$T" "\$O"
    printf '#!/bin/sh\nexec "%s" "\$@"\n' "\$O" > "\$T"
    chmod +x "\$T"
fi
EOF
    chmod +x "$SIM/init/vaapi"
}

boot() { for m in "$@"; do PLEX_MEDIA_SERVER_HOME="$PLEXDIR" "$SIM/init/$m" >/dev/null 2>&1; done; }

check() {
    local label=$1
    grep -rqs 'libplacebo' "$PLEXDIR" \
        || { echo "FAIL [$label]: placebo wrapper not installed (mod silently inert)"; fail=1; return; }
    local intact=0
    for f in "$PLEXDIR"/*; do cmp -s "$f" "$SIM/real_reference" && intact=1; done
    [ "$intact" = 1 ] || { echo "FAIL [$label]: real binary destroyed"; fail=1; return; }
    local out; out=$(timeout 5 "$PLEXDIR/Plex Transcoder" -i movie.mkv -c copy 2>&1)
    if [ $? -eq 124 ]; then
        echo "FAIL [$label]: infinite exec loop"; fail=1
    elif [ "$out" != "-i movie.mkv -c copy" ]; then
        echo "FAIL [$label]: chain did not reach real binary (got: $out)"; fail=1
    else
        echo "  ok: $label"
    fi
}

for order in "placebo vaapi" "vaapi placebo"; do
    setup; boot $order;            check "fresh boot, $order";           rm -rf "$SIM"
    setup; boot $order; boot $order; check "restart, $order";            rm -rf "$SIM"
done

# Plex updating in place drops a fresh stock binary over our wrapper; we must re-wrap it
# rather than sit inert, and the stale chain target must be replaced with the new binary.
setup
boot placebo vaapi
cp /bin/echo "$PLEXDIR/Plex Transcoder"
boot placebo vaapi
check "plex updated in place"
rm -rf "$SIM"

[ "$fail" = 0 ] && echo "PASS: all install-guard scenarios"
exit "$fail"

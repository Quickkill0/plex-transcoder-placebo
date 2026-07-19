#!/bin/bash
# Regression tests for the install guard and the wrapper chain.
#
# The guard is fiddly because plex-vaapi-amdgpu-mod wraps the same path, s6 gives no
# ordering guarantee between two independent oneshots, and a `docker restart` re-runs init
# against an already-modified filesystem. Getting it wrong is destructive: moving a wrapper
# over a chain target that holds the real binary loses it permanently.
set -uo pipefail
REPO=$(cd "$(dirname "$0")" && pwd)
fail=0

GRAPH='[0:0]scale=w=3840:h=2160[1];[1]format=p010,tonemap=hable[2];[2]format=pix_fmts=nv12[3];[3][0]overlay[4];[4]hwupload[5]'

setup() {
    SIM=$(mktemp -d)
    PLEXDIR="$SIM/plexdir"; MOD="$SIM/mod"
    mkdir -p "$PLEXDIR" "$MOD/bin" "$SIM/init"
    # A genuine ELF stands in for the real transcoder, so the script-detection guard sees a
    # binary; echoing its args makes "did the chain reach it" observable.
    cp /bin/echo "$PLEXDIR/Plex Transcoder"
    cp /bin/echo "$SIM/real_reference"
    install -m755 "$REPO/plex-transcoder-wrapper.sh" "$MOD/bin/wrapper.sh"
    # Stands in for the custom ffmpeg build; echoes the argv it was handed so the test can
    # assert the rewrite actually happened.
    printf '#!/bin/sh\necho "CUSTOM: $*"\n' > "$SIM/custom"; chmod +x "$SIM/custom"
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

# Drives the installed chain for real rather than inspecting the directory: a wrapper
# sitting on disk outside the chain would otherwise look like a pass.
check() {
    local label=$1 out rc

    out=$(timeout 5 env PLACEBO_TRANSCODER="$SIM/custom" \
          "$PLEXDIR/Plex Transcoder" -filter_complex "$GRAPH" 2>&1); rc=$?
    if [ $rc -eq 124 ]; then
        echo "FAIL [$label]: infinite exec loop on tonemap job"; fail=1; return
    fi
    case $out in
        *libplacebo=*) ;;
        *) echo "FAIL [$label]: tonemap job not rewritten (got: ${out:0:70})"; fail=1; return;;
    esac

    out=$(timeout 5 "$PLEXDIR/Plex Transcoder" -i movie.mkv -c copy 2>&1); rc=$?
    if [ $rc -eq 124 ]; then
        echo "FAIL [$label]: infinite exec loop on passthrough"; fail=1; return
    elif [ "$out" != "-i movie.mkv -c copy" ]; then
        echo "FAIL [$label]: passthrough did not reach real binary (got: $out)"; fail=1; return
    fi

    local intact=0
    for f in "$PLEXDIR"/*; do cmp -s "$f" "$SIM/real_reference" && intact=1; done
    [ "$intact" = 1 ] || { echo "FAIL [$label]: real binary destroyed"; fail=1; return; }
    echo "  ok: $label"
}

# Word splitting on $order is the point: each string names the two mods to run, in order.
# shellcheck disable=SC2086
for order in "placebo vaapi" "vaapi placebo"; do
    setup; boot $order;              check "fresh boot, $order"; rm -rf "$SIM"
    setup; boot $order; boot $order; check "restart, $order";    rm -rf "$SIM"
done

# Plex updating in place drops a fresh stock binary over our wrapper; we must re-wrap it
# rather than sit inert, and the stale chain target must be replaced.
setup; boot placebo vaapi
cp /bin/echo "$PLEXDIR/Plex Transcoder"
boot placebo vaapi
check "plex updated in place"
rm -rf "$SIM"

# Chain target deleted with the wrapper left installed: init must refuse rather than stash
# the wrapper as its own chain target and spin forever.
setup; boot placebo
rm -f "$PLEXDIR/Plex Transcoder.preplacebo"
boot placebo
out=$(timeout 5 "$PLEXDIR/Plex Transcoder" -i movie.mkv 2>&1)
[ $? -eq 124 ] && { echo "FAIL [chain target deleted]: infinite exec loop"; fail=1; } \
               || echo "  ok: chain target deleted, no self-chain"
rm -rf "$SIM"

# A failed install must leave a working transcoder at the path, never a half-installed
# state with nothing there. Read-only plex dir makes the mv fail for real.
setup
chmod 555 "$PLEXDIR"
boot placebo
chmod 755 "$PLEXDIR"
if ! cmp -s "$PLEXDIR/Plex Transcoder" "$SIM/real_reference"; then
    echo "FAIL [readonly install]: original transcoder not intact after failed install"; fail=1
else
    echo "  ok: failed install leaves the original in place"
fi
rm -rf "$SIM"

[ "$fail" = 0 ] && echo "PASS: all chain scenarios"
exit "$fail"

#!/bin/bash
# Regression test for the wrapper chain surviving a container restart while composed with
# another mod that wraps the same binary (plex-vaapi-amdgpu-mod does).
#
# Guarding on "is this file a script" rather than "does it carry our marker" is load-bearing:
# with a marker guard, a restart moves the peer mod's wrapper over Plex Transcoder.preplacebo,
# destroying the real binary and leaving two wrappers exec'ing each other forever.
set -uo pipefail
REPO=$(cd "$(dirname "$0")" && pwd)
SIM=$(mktemp -d)
trap 'rm -rf "$SIM"' EXIT

PLEXDIR="$SIM/plexdir"; MOD="$SIM/mod"
mkdir -p "$PLEXDIR" "$MOD/bin" "$SIM/init"

# A genuine ELF stands in for the real transcoder, so the script-detection guard sees a
# binary, and echoing its args makes "did we reach it" observable.
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

# Placebo first is the destructive order; the safe order never exercised the bug.
for _ in 1 2; do
    PLEX_MEDIA_SERVER_HOME="$PLEXDIR" "$SIM/init/placebo" >/dev/null
    "$SIM/init/vaapi"
done

fail=0
intact=0
for f in "$PLEXDIR"/*; do
    cmp -s "$f" "$SIM/real_reference" && intact=1
done
[ "$intact" = 1 ] || { echo "FAIL: real binary destroyed across restart"; fail=1; }

out=$(timeout 5 "$PLEXDIR/Plex Transcoder" -i movie.mkv -c copy 2>&1)
if [ $? -eq 124 ]; then
    echo "FAIL: infinite exec loop in wrapper chain"; fail=1
elif [ "$out" != "-i movie.mkv -c copy" ]; then
    echo "FAIL: chain did not reach real binary (got: $out)"; fail=1
fi

[ "$fail" = 0 ] && echo "PASS: chain survives restart, real binary intact"
exit "$fail"

#!/bin/bash
# Flattens the transcoder's dynamic deps + the RADV Vulkan driver into one directory,
# so the mod ships the exact libplacebo/Vulkan the binary was built against and the
# host container's Ubuntu version stops mattering.
set -euo pipefail

BIN="${1:?usage: collect-libs.sh <binary> <outdir>}"
OUT="${2:?usage: collect-libs.sh <binary> <outdir>}"

mkdir -p "$OUT/lib" "$OUT/lib/dri" "$OUT/icd.d" "$OUT/share/libdrm"

# Core glibc is deliberately NOT bundled: LD_LIBRARY_PATH can't sanely mix a bundled
# libc with the container's ld.so. Everything above libc is fair game, and shipping a
# build from an older Ubuntu keeps us forward-compatible with newer containers.
EXCLUDE='^(libc|libm|libdl|librt|libpthread|ld-linux-x86-64|libresolv)\.so'

copy_deps() {
    ldd "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | sort -u |
    while read -r lib; do
        base=$(basename "$lib")
        echo "$base" | grep -qE "$EXCLUDE" && continue
        [ -f "$lib" ] && cp -nL "$lib" "$OUT/lib/" 2>/dev/null || true
    done
}

copy_deps "$BIN"

# RADV is dlopen'd by the Vulkan loader, so it never shows up in ldd of the binary.
RADV=$(find /usr/lib -name 'libvulkan_radeon.so' -print -quit)
[ -n "$RADV" ] || { echo "ERROR: libvulkan_radeon.so not found (mesa-vulkan-drivers missing?)"; exit 1; }
cp -L "$RADV" "$OUT/lib/"
copy_deps "$RADV"

# Same story for VAAPI, which the encoder needs: libva dlopens the driver, so it never
# appears in ldd. We can't reuse Plex's or the vaapi-amdgpu mod's copy -- both are
# musl-built and this binary is glibc -- so carry a matching glibc one.
VADRV=$(find /usr/lib -name 'radeonsi_drv_video.so' -print -quit)
[ -n "$VADRV" ] || { echo "ERROR: radeonsi_drv_video.so not found (mesa-va-drivers missing?)"; exit 1; }
cp -L "$VADRV" "$OUT/lib/dri/"
copy_deps "$VADRV"

# libdrm reads this to identify the GPU; without it amdgpu init is unreliable. The
# vaapi-amdgpu mod ships it for the same reason.
[ -f /usr/share/libdrm/amdgpu.ids ] && cp /usr/share/libdrm/amdgpu.ids "$OUT/share/libdrm/"

# Rewrite the ICD manifest to point at our bundled copy; the stock one uses a path
# that won't exist in the target container.
cat > "$OUT/icd.d/radeon_icd.x86_64.json" <<EOF
{
    "ICD": {
        "api_version": "1.3.275",
        "library_path": "/plex-placebo/lib/libvulkan_radeon.so"
    },
    "file_format_version": "1.0.0"
}
EOF

echo "collected $(ls -1 "$OUT/lib" | wc -l) libs"

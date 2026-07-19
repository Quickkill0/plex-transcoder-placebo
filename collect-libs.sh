#!/bin/bash
# Flattens the transcoder's dynamic deps + the RADV Vulkan driver into one directory,
# so the mod ships the exact libplacebo/Vulkan the binary was built against and the
# host container's Ubuntu version stops mattering.
set -euo pipefail

BIN="${1:?usage: collect-libs.sh <binary> <outdir>}"
OUT="${2:?usage: collect-libs.sh <binary> <outdir>}"

mkdir -p "$OUT/lib" "$OUT/lib/dri" "$OUT/icd.d" "$OUT/layer.d"

# Core glibc is deliberately NOT bundled: LD_LIBRARY_PATH can't sanely mix a bundled
# libc with the container's ld.so. Everything above libc is fair game, and shipping a
# build from an older Ubuntu keeps us forward-compatible with newer containers.
EXCLUDE='^(libc|libm|libdl|librt|libpthread|ld-linux-x86-64|libresolv)\.so'

copy_deps() {
    local out
    out=$(ldd "$1" 2>/dev/null) || { echo "ERROR: ldd failed on $1"; exit 1; }
    # An unresolved dep prints "libfoo.so => not found", which has no /-prefixed field and
    # would otherwise vanish silently -- shipping a bundle that dies at runtime instead.
    if printf '%s\n' "$out" | grep -q 'not found'; then
        echo "ERROR: unresolved dependency for $1:"
        printf '%s\n' "$out" | grep 'not found'
        exit 1
    fi
    printf '%s\n' "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | sort -u |
    while read -r lib; do
        base=$(basename "$lib")
        echo "$base" | grep -qE "$EXCLUDE" && continue
        [ -f "$lib" ] || continue
        cp -nL "$lib" "$OUT/lib/" || { echo "ERROR: failed to bundle $lib"; exit 1; }
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

# Copy mesa's own ICD manifest and rewrite only the driver path, rather than hand-writing
# one: a hardcoded api_version drifts from whatever mesa we actually bundled. Relative path
# resolves against the manifest's own directory, which keeps the bundle relocatable.
STOCK_ICD=$(find /usr/share/vulkan/icd.d -name 'radeon_icd*.json' -print -quit)
[ -n "$STOCK_ICD" ] || { echo "ERROR: stock RADV ICD manifest not found"; exit 1; }
sed -E 's#("library_path"[[:space:]]*:[[:space:]]*")[^"]*#\1../lib/libvulkan_radeon.so#' \
    "$STOCK_ICD" > "$OUT/icd.d/radeon_icd.x86_64.json"
grep -q '\.\./lib/libvulkan_radeon\.so' "$OUT/icd.d/radeon_icd.x86_64.json" \
    || { echo "ERROR: ICD manifest rewrite failed"; exit 1; }

# Mesa's device-select layer. Only matters on machines with more than one AMD GPU, where
# libplacebo would otherwise just take device 0 -- possibly not the one Plex was pointed at.
# With this bundled, MESA_VK_DEVICE_SELECT=vendorid:deviceid works.
SELECT_LAYER=$(find /usr/lib -name 'libVkLayer_MESA_device_select.so' -print -quit)
SELECT_JSON=$(find /usr/share/vulkan -name 'VkLayer_MESA_device_select.json' -print -quit)
if [ -n "$SELECT_LAYER" ] && [ -n "$SELECT_JSON" ]; then
    cp -L "$SELECT_LAYER" "$OUT/lib/"
    copy_deps "$SELECT_LAYER"
    sed -E 's#("library_path"[[:space:]]*:[[:space:]]*")[^"]*#\1../lib/libVkLayer_MESA_device_select.so#' \
        "$SELECT_JSON" > "$OUT/layer.d/VkLayer_MESA_device_select.json"
    grep -q '\.\./lib/libVkLayer_MESA_device_select\.so' "$OUT/layer.d/VkLayer_MESA_device_select.json" \
        || { echo "ERROR: device-select layer manifest rewrite failed"; exit 1; }
else
    echo "WARNING: mesa device-select layer not found; multi-GPU selection unavailable"
fi

echo "collected $(find "$OUT/lib" -maxdepth 1 -type f | wc -l) libs"

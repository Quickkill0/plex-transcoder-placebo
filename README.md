# plex-transcoder-placebo

Rebuilds Plex Transcoder from Plex's own published source with **Vulkan + libplacebo** enabled,
so HDR tone mapping runs on the GPU instead of the CPU. Aimed at AMD, where neither of the
other hardware paths works.

Not affiliated with or endorsed by Plex.

## Why

Plex tone maps HDR **in software**. A typical 4K HDR transcode looks like:

```
hw decode (vaapi) -> download to RAM -> sw scale -> sw tonemap=hable -> sw overlay -> hwupload -> h264_vaapi
```

On AMD there's no hardware alternative in the stock binary:

| Path | Status on AMD |
|---|---|
| `tonemap_vaapi` | Fails: *"VAAPI driver doesn't support HDR"*. Mesa radeonsi has no HDR VPP; Intel iHD only. |
| `tonemap_opencl` | Filter is compiled in, but there's no AMD OpenCL runtime (ROCm doesn't support most iGPUs). |
| `libplacebo` (Vulkan) | Works, but Plex doesn't enable it at build time. |

## How

Plex's transcoder is based on **ffmpeg 6.1.3**, which already ships `vf_libplacebo` and the entire
Vulkan stack. Plex simply omits `--enable-vulkan --enable-libplacebo` from their configure.

So this is a **build flag flip, not a patch series**; there's nothing to rebase and no upstream
delta to maintain. `build.sh` fetches Plex's current GPL source, rebuilds it with the flags on,
and a wrapper script rewrites the filter graph at call time.

Two deliberate deviations from Plex's own configure:

- **Decoders compiled in.** Plex externalises h264/hevc into `dlopen`'d, musl-linked `.so` blobs
  (patent reasons). A glibc build can't load those, so the native decoders are built in instead
  and the wrapper unsets `FFMPEG_EXTERNAL_LIBS`.
- **No `--enable-gpl`.** Plex builds LGPL (`--enable-openssl` would conflict). libplacebo is LGPL,
  so nothing here needs GPL.

## Setup

### 1. Vulkan drivers in the container

RADV has to exist at runtime. For linuxserver/plex:

```yaml
environment:
  - DOCKER_MODS=linuxserver/mods:universal-package-install
  - INSTALL_PACKAGES=mesa-vulkan-drivers|libvulkan1|libplacebo338
devices:
  - /dev/dri:/dev/dri
```

Verify inside the container: `vulkaninfo --summary` should list your GPU under RADV,
not just `llvmpipe`.

### 2. Build

The release binary must be built against **the same base image your Plex container uses**
(`ubuntu:26.04` for current linuxserver/plex), libplacebo, Vulkan and libva stay dynamically
linked, so a soname mismatch means the binary won't load. Run the `build` workflow, overriding
`base_image` if yours differs.

### 3. Install

```sh
REPO=<user>/<repo> ./install.sh
```

For linuxserver/plex, put `install.sh` at `/custom-cont-init.d/99-placebo` and
`plex-transcoder-wrapper.sh` at `/config/`. Both a container recreate and a Plex update restore
the stock binary, so it needs to re-run on every start.

## Verifying it works

`PLACEBO_DEBUG=1` makes the wrapper log every rewrite to `/tmp/plex-placebo.log`. Play an HDR
file that forces a transcode; you should see the graph with `tonemap=hable` replaced by
`libplacebo=...`, and CPU use during the transcode should drop sharply.

The wrapper falls back to the stock binary whenever it can't help, no `-filter_complex`, no
software tone map in the graph, the custom binary missing, or the rewrite not matching. Worst
case is Plex's normal behaviour.

## Matching source to your server

Release tags carry Plex's source sha. It should match the directory under
`Plex Media Server/Codecs/<sha>-<hash>-linux-x86_64/` on your server. If it doesn't, Plex has
shipped a new transcoder, re-run the workflow.

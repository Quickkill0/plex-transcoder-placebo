# plex-transcoder-placebo

A [linuxserver.io Docker Mod](https://github.com/linuxserver/docker-mods) that gives Plex
**GPU HDR tone mapping via Vulkan/libplacebo**, for AMD hardware where no other hardware path works.

```yaml
environment:
  - DOCKER_MODS=ghcr.io/<user>/plex-transcoder-placebo:latest
devices:
  - /dev/dri:/dev/dri
```

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

So this is a **build flag flip, not a patch series**; nothing to rebase, no upstream delta to
maintain. The mod rebuilds Plex's published GPL source with the flags on, bundles the result with
its Vulkan stack, and installs a wrapper that rewrites the filter graph at call time:

```
[1]format=p010,tonemap=hable[2]   ->   [1]libplacebo=tonemapping=bt.2390:...[2]
```

Three deliberate deviations from Plex's own build:

- **Decoders compiled in.** Plex externalises h264/hevc into `dlopen`'d, musl-linked `.so` blobs
  (patent reasons). A glibc build can't load those, so native decoders are built in instead and the
  wrapper unsets `FFMPEG_EXTERNAL_LIBS`.
- **No `--enable-gpl`.** Plex builds LGPL (`--enable-openssl` would conflict). libplacebo is LGPL.
- **Libraries bundled.** libplacebo, Vulkan and RADV ship inside the mod, built on Ubuntu 24.04.
  glibc is forward-compatible, so this runs on newer containers without matching their version.

## Composing with other mods

The wrapper **chains** rather than assuming it owns the transcoder path: on install it moves
whatever is currently there to `Plex Transcoder.preplacebo` and calls that for anything it doesn't
handle. This matters because
[plex-vaapi-amdgpu-mod](https://github.com/justinappler/plex-vaapi-amdgpu-mod) also wraps the
transcoder to inject its libva stack. Both orders work:

```yaml
- DOCKER_MODS=ghcr.io/justinappler/plex-vaapi-amdgpu-mod:latest|ghcr.io/<user>/plex-transcoder-placebo:latest
```

Whatever `LD_LIBRARY_PATH` is already set is preserved after ours, since the custom binary still
needs that libva stack to run `h264_vaapi` encoding.

## Verifying

`PLACEBO_DEBUG=1` logs every rewrite to `/tmp/plex-placebo.log`. Play an HDR file that forces a
transcode; you should see `tonemap=hable` replaced by `libplacebo=...`, and CPU use drop sharply.

The wrapper falls back to the chained binary whenever it can't help, no `-filter_complex`, no
software tone map, custom binary missing, or the rewrite not matching. Worst case is Plex's
normal behaviour.

**Check RADV is actually in use.** If the Vulkan driver isn't found, libplacebo falls back to
`llvmpipe` (software Vulkan) and will be *slower* than stock. The mod bundles RADV and points
`VK_DRIVER_FILES` at it, so this should be handled, but it's the first thing to check if results
disappoint.

## Matching source to your server

Image tags carry Plex's source sha (`:plex-<sha>`). It should match the directory under
`Plex Media Server/Codecs/<sha>-<hash>-linux-x86_64/`. If it doesn't, Plex shipped a new
transcoder, the weekly build will pick it up, or run the workflow manually.

## Building locally

```sh
docker build -t plex-placebo-mod .    # full mod image
./build.sh                            # just the transcoder, into ./dist
./setup-branches.sh                   # research: upstream n6.1.3 vs Plex's delta as a git diff
```

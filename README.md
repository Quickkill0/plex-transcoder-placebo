# plex-transcoder-placebo

A [linuxserver.io Docker Mod](https://github.com/linuxserver/docker-mods) that gives Plex
**GPU HDR tone mapping via Vulkan/libplacebo**, for AMD hardware where no other hardware path works.

```yaml
environment:
  - DOCKER_MODS=ghcr.io/bitnimble/plex-transcoder-placebo:latest
devices:
  - /dev/dri:/dev/dri
```

Not affiliated with or endorsed by Plex.

The mod's own scripts are MIT (see `LICENSE`). The transcoder it builds is Plex's published
GPL/LGPL ffmpeg source, unchanged apart from configure flags, and stays LGPL v2.1+: the image
carries its licence texts and the exact source tarball it was built from under
`/plex-placebo/licenses/`. The two don't conflict.

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
[1]format=p010,tonemap=hable[2]   ->   [1]libplacebo=tonemapping=hable:...[2]
```

## When the mod steps in

Only when the transcode **downscales to 1080p or lower**. Everything else chains straight
through to stock Plex.

Tone mapping is shader work and its cost scales with the pixels libplacebo is handed, so the
mod also moves the downscale onto the GPU and *ahead* of the tone map. Measured on a Ryzen 7
7800X3D's 2-CU Raphael iGPU, 335 frames of 4K HDR to 1080p SDR:

| | wall | CPU |
|---|---|---|
| Plex today: sw scale + sw tonemap | 17.6s | 32.9s |
| in-place swap: sw scale + libplacebo | 17.6s | 18.0s |
| libplacebo scales, from 4K sw frames | 28.0s | 13.5s |
| libplacebo scales, no download | 18.2s | 4.9s |
| **`scale_vaapi` first, libplacebo at 1080p** | **11.6s** | **4.2s** |

**34% faster than Plex and 8x less CPU**, comfortably above realtime. Note it is the scale
ordering that pays, not skipping the download: avoiding the copy while leaving the scale to
libplacebo still took 18.2s, because it was then tone mapping at 4K.

At 4K *output* there is no downscale to exploit, and libplacebo runs ~60% slower than Plex's
software path and well below realtime, so those jobs are left alone. Anything that can play
4K generally direct streams it anyway. Raise `PLACEBO_MAX_HEIGHT` if your GPU is bigger than
a 2-CU display adapter.

Only the video chain becomes `scale_vaapi`; the subtitle scale works on software ARGB and
would fail. The video chain is found by following the label that feeds the tone map, and a
video segment carrying anything other than a bare scale falls back to swapping the tone map
in place. `PLACEBO_NO_ZEROCOPY=1` disables the restructure entirely.

If the graph has no scale filter the output resolution isn't knowable from argv, so the mod
chains rather than guess.

## Tone mapping curves

**Your Plex setting is carried across, not overridden.** Every curve the Plex UI offers
(`linear`, `gamma`, `clip`, `reinhard`, `hable`, `mobius`) exists in libplacebo under the same
name, so the mod moves tone mapping onto the GPU without changing your chosen look.

The quality gain comes from libplacebo's *implementation* rather than from the curve: dynamic
peak detection, proper gamut mapping and contrast recovery, none of which ffmpeg's software
`tonemap` does. So the same curve genuinely looks better, and HLG finally tone maps at all
(Plex's filter ignores its own arguments and assumes PQ, so it silently doesn't).

libplacebo also has curves Plex can't select. Set `PLACEBO_TONEMAP` to use one:

| Curve | Notes |
|---|---|
| `bt.2390` | ITU-R reference EETF, designed for exactly this conversion and hue-preserving. Noticeably brighter than `hable`: mean luma 147 vs 107 on the same clip. |
| `spline` | libplacebo's own default; generally the best general-purpose choice. |
| `bt.2446a` | ITU-R Method A, an alternative reference approach. |
| `st2094-40` / `st2094-10` | Use HDR10+ dynamic metadata when the source carries it. |
| `auto` | Let libplacebo pick based on the source. |

`hable` is a filmic *look* curve from Uncharted 2, not a conversion standard; it crushes
highlights and darkens by design. `bt.2390` and `spline` are more faithful to the source, but
"better" is partly taste here, and some people read the reference curves as flat next to hable's
punch. It's a one-line env change, so try both.

An unrecognised curve makes the wrapper fall back to stock Plex, rather than emit a graph that
would only fail after exec.

### Highlight clipping

libplacebo's dynamic peak detection maps the *measured* frame peak to white, which uses the
output range far better than Plex's static mapping but puts the brightest speculars at or
above nominal white. Measured on an HDR10 disc (4000-nit mastering peak, MaxCLL 729), as a
percentage of pixels at Y>=235 over an 80s clip:

| | clipped | mean luma |
|---|---|---|
| Plex software `hable` | 0.0002% | 41.10 |
| libplacebo `bt.2390` | 0.0812% | 39.21 |
| `bt.2390` + `contrast_recovery=0` | 0.0581% | 39.19 |
| `bt.2390` + `percentile=100:contrast_recovery=0` | 0.0461% | 39.28 |
| `spline` | 0.0460% | 39.06 |
| `bt.2390` + `peak_detect=0` | 0.0001% | 40.06 |

Worth knowing that mean luma barely moves: `bt.2390` is *higher contrast*, not brighter, and
its average is actually below Plex's. Deeper blacks and lifted speculars read as "more HDR".

`peak_detect=0` is the only setting that removes clipping outright, because it falls back to
the disc's declared mastering peak and compresses hard enough that nothing reaches white,
which is also why it looks flat. `tonemapping_param` (the bt.2390 knee) does not help; it
made clipping slightly worse at every value tried.

Pass any of these through with `PLACEBO_OPTS`:

```yaml
- PLACEBO_OPTS=contrast_recovery=0
```

Values are restricted to option characters, since the string is substituted into the filter
graph. An option libplacebo rejects will still kill the transcode, because that only
surfaces after the wrapper has exec'd and can no longer fall back.

Three deliberate deviations from Plex's own build:

- **Decoders compiled in.** Plex externalises h264/hevc into `dlopen`'d, musl-linked `.so` blobs
  (patent reasons). A glibc build can't load those, so native decoders are built in instead and the
  wrapper unsets `FFMPEG_EXTERNAL_LIBS`.
- **No `--enable-gpl`.** Plex builds LGPL (`--enable-openssl` would conflict). libplacebo is LGPL.
- **Libraries bundled.** libplacebo, Vulkan and RADV ship inside the mod, built on Ubuntu 24.04.
  glibc is forward-compatible, so this runs on newer containers without matching their version.

## Requirements

No specific GPU model is baked in; the Mesa stack is discovered at build time, not pinned; but the bundle does imply some floors:

| | |
|---|---|
| GPU | Any AMD supported by Mesa's `radeonsi` + RADV, i.e. GCN 1.0 and newer (~2012+). Both the Vulkan and VA drivers come from the bundle, so the host container needs no Mesa of its own. |
| Encoding | VAAPI H.264/HEVC encode needs VCE/VCN, present on GCN 1.0+. APUs and dGPUs both work. |
| Container | **glibc >= 2.38.** Bundled libraries are built on Ubuntu 24.04; glibc is forward- but not backward-compatible, so Ubuntu 22.04-based images will *not* work. Current linuxserver/plex (26.04) is fine. |
| Arch | x86_64 |
| Base | linuxserver.io, or anything else running s6-overlay v3 with the mod loader |

**More than one AMD GPU?** libplacebo takes the first RADV device, which may not be the one
Plex's `-hwaccel_device` points at. The mod bundles Mesa's device-select layer, so
`MESA_VK_DEVICE_SELECT=1002:xxxx` (vendor:device, from `lspci -nn`) forces the choice.
Single-GPU systems need nothing.

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

**If the Vulkan driver can't be found, tone mapping fails loudly** (`Failed creating Vulkan
device!`) rather than silently falling back to software rendering, the bundle deliberately ships
only RADV, no `llvmpipe`. A dead transcode is easier to diagnose than one that quietly runs at a
tenth the speed.

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

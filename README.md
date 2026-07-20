# plex-transcoder-placebo

A [linuxserver.io Docker Mod](https://github.com/linuxserver/docker-mods) that gives Plex
**GPU HDR tone mapping on AMD**, via Vulkan/libplacebo.

Plex tone maps HDR in software, which is expensive, and on AMD there is no hardware
alternative in the stock transcoder: `tonemap_vaapi` needs a HDR VPP that Mesa doesn't have
(Intel only), and `tonemap_opencl` needs an OpenCL runtime most AMD iGPUs don't get. Plex's
ffmpeg already contains `vf_libplacebo` and the whole Vulkan stack, it just isn't compiled in.
This mod rebuilds Plex's published source with those flags on and swaps the tone map at
call time.

On a 4K→1080p HDR transcode that measured **~35% faster and ~8x less CPU** than Plex's
software path.

Not affiliated with or endorsed by Plex.

## Install

```yaml
environment:
  - DOCKER_MODS=ghcr.io/bitnimble/plex-transcoder-placebo:latest
devices:
  - /dev/dri:/dev/dri
```

Already using [plex-vaapi-amdgpu-mod](https://github.com/justinappler/plex-vaapi-amdgpu-mod)?
Add this one alongside it. Both wrap the same binary and chain correctly in either order:

```yaml
  - DOCKER_MODS=ghcr.io/justinappler/plex-vaapi-amdgpu-mod:latest|ghcr.io/<user>/plex-transcoder-placebo:latest
```

Nothing else to configure. Your existing **Tonemapping Algorithm** setting in Plex is used
as-is.

## Requirements

| | |
|---|---|
| GPU | Any AMD supported by Mesa `radeonsi` + RADV, i.e. GCN 1.0 and newer (~2012+). Drivers ship inside the mod, so the container needs no Mesa of its own. |
| Encoding | VAAPI H.264/HEVC encode (VCE/VCN), present on GCN 1.0+. APUs and dGPUs both fine. |
| Container | **glibc >= 2.38.** Ubuntu 22.04-based images will not work; current linuxserver/plex is fine. |
| Arch | x86_64, s6-overlay v3 |

## Configuration

All optional. By default the mod handles every HDR transcode at any resolution.

| Variable | Default | Effect |
|---|---|---|
| `PLACEBO_TONEMAP` | your Plex setting | Force a tone-mapping curve (see below). |
| `PLACEBO_MAX_HEIGHT` | unset (no limit) | Cap the output height the mod will handle; taller jobs pass through to stock Plex. |
| `PLACEBO_OPTS` | – | Extra libplacebo options, e.g. `contrast_recovery=0` or `peak_detect=0` to reduce highlight clipping. |
| `PLACEBO_DEBUG` | – | Log every decision to `/tmp/plex-placebo.log`. |
| `PLACEBO_NO_ZEROCOPY` | – | Keep Plex's software scale instead of moving it to the GPU. |

**`PLACEBO_MAX_HEIGHT`** exists because tone mapping cost scales with resolution. On a
dedicated GPU, leave it unset and 4K→4K is handled too. On a small iGPU, tone mapping at 4K
is slower on the GPU than Plex's software path, so set e.g. `PLACEBO_MAX_HEIGHT=1080` to keep
4K jobs on the CPU while still accelerating everything at 1080p and below (clients that can
play 4K normally direct stream it anyway).

**`PLACEBO_TONEMAP`**, your Plex *Tonemapping Algorithm* setting is used by default and every
curve the Plex UI lists works. libplacebo also offers curves Plex can't select: `bt.2390`
(ITU reference, higher contrast, clips bright speculars more), `spline` (libplacebo's own
default, a good general-purpose look), `bt.2446a`, `st2094-40`/`st2094-10` (HDR10+ dynamic
metadata), and `auto`.

## Troubleshooting

Set `PLACEBO_DEBUG=1`, play an HDR file that forces a transcode, then check
`/tmp/plex-placebo.log`. A working rewrite shows `tonemap=<curve>` replaced by
`libplacebo=...`.

An empty log means the mod decided it couldn't help and passed the job to stock Plex: there's
no software tone map in the graph, the graph isn't a shape it can safely rewrite, or the
output exceeds `PLACEBO_MAX_HEIGHT` if you've set one. That's the designed failure mode: worst
case is Plex's normal behaviour.

If the Vulkan driver can't be found, tone mapping fails loudly (`Failed creating Vulkan
device!`) rather than silently dropping to software rendering.

**Multiple AMD GPUs:** libplacebo takes the first RADV device, which may not be the one Plex
is pointed at. `MESA_VK_DEVICE_SELECT=1002:xxxx` (vendor:device, from `lspci -nn`) forces it.

**Matching your server:** image tags carry Plex's source sha (`:plex-<sha>`), which should
match the directory under `Plex Media Server/Codecs/<sha>-<hash>-linux-x86_64/`. A mismatch
means Plex shipped a new transcoder; the scheduled build picks that up automatically.

## Licence

The mod's own scripts are MIT (see `LICENSE`). The transcoder it builds is Plex's published
GPL/LGPL ffmpeg source, unchanged apart from configure flags, and stays LGPL v2.1+. The image
ships its licence texts and the exact source tarball it was built from under
`/plex-placebo/licenses/`.

## Building locally

```sh
docker build -t plex-placebo-mod .   # the mod image
./build.sh                           # just the transcoder, into ./dist
./test-chain.sh && ./test-rewrite.sh # tests
```

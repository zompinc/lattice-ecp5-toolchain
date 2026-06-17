# lattice-ecp5-toolchain

Public Docker image bundling the open-source Lattice ECP5 development
toolchain — published to
[`ghcr.io/zompinc/lattice-ecp5-toolchain`](https://github.com/zompinc/lattice-ecp5-toolchain/pkgs/container/lattice-ecp5-toolchain)
on every Dockerfile change and rebuilt weekly to track upstream LiteX
and migen updates.

Maintained by [Zomp](https://zomp.com) for use across our ECP5
projects, but published publicly so anyone can pull it without GitHub
authentication.

## What's inside

Built on `mcr.microsoft.com/devcontainers/base:trixie`, the image
adds:

| Tool | Source | Version |
| --- | --- | --- |
| yosys | apt (trixie) | distro |
| nextpnr-ecp5 | apt (trixie) | distro |
| fpga-trellis | apt (trixie) | distro |
| openocd | apt (trixie) | distro |
| openFPGALoader | source | pinned tag (`v1.1.1` at time of writing) |
| prjtrellis | source | pinned tag |
| ecpprog | source | pinned commit |
| openocd-vexriscv | source (SpinalHDL fork) | pinned commit, installed at `/opt/openocd-vexriscv` |
| RISC-V cross-compiler | apt (`gcc-riscv64-unknown-elf`) | distro |
| LiteX + migen + litedram | pip (git HEAD) | tracking upstream |
| `pythondata-cpu-vexriscv` + `compiler_rt` + `picolibc` | pip (git) | tracking upstream |

All pinned via Dockerfile `ARG`s so version bumps are intent-only.
Run the weekly cron or push a Dockerfile change to refresh `latest`.

## Usage

### As a devcontainer base image

In any project's `.devcontainer/devcontainer.json`:

```json
{
  "name": "ECP5 development",
  "image": "ghcr.io/zompinc/lattice-ecp5-toolchain:latest"
}
```

### As a one-shot run target (e.g. flashing a bitstream)

In a VS Code `tasks.json` or shell script:

```bash
docker run --rm --privileged \
  -v "$(pwd)/build:/bit:ro" \
  ghcr.io/zompinc/lattice-ecp5-toolchain:latest \
  openFPGALoader -b ecp5_evn /bit/top.bit
```

`--privileged` is required so a USB-forwarded FT2232H (via `usbipd` on
Windows or `--device` on Linux) is reachable inside the container.

## Compatibility

- Image is `linux/amd64` only at present. Apple Silicon hosts pull it
  under QEMU emulation; if that becomes a pain point we'll add native
  arm64 builds.
- Built against Debian Trixie's GCC 14 and Python 3.13 — both currently
  drive some pin choices documented inline in the Dockerfile.

## License

Apache 2.0. See [LICENSE](LICENSE). All bundled toolchain components
retain their own upstream licenses — this repo's licence covers only
the Dockerfile and workflow.

# Pre-built Lattice ECP5 open-source toolchain image.
#
# Built and published by .github/workflows/build.yml to
# ghcr.io/zompinc/lattice-ecp5-toolchain:latest. Consumed by Zomp
# projects targeting the Lattice ECP5 family — either as a devcontainer
# base image (zompinc/ecp5-multiboot-bringup) or as a one-shot run
# target for VS Code tasks that flash a bitstream (zompinc/fw-pig8d-next).
#
# Public image — no Zomp/client IP inside, just compiled open-source
# binaries. Pulls without auth.
#
# Layer order is deliberate — slower-changing layers first so apt cache
# survives most edits:
#   1. apt — open-source FPGA toolchain, JTAG plumbing, RISC-V GCC,
#      meson/ninja for LiteX's BIOS build, build deps for the source
#      builds below.
#   2. prjtrellis — pure git clone, no build.
#   3. ecpprog — small ~30 s source build (libftdi1, libusb).
#   4. openFPGALoader — ~2 min source build, pinned to the latest stable
#      release. Trixie's apt ships v0.13.1 (Dec 2024); upstream is much
#      newer and our host bench has v1.1.1, so we build from source to
#      stay at parity.
#   5. openocd-vexriscv — ~5 min source build with --enable-dummy +
#      vexriscv target driver. Bundled into /opt to keep apt's openocd
#      usable for `litex_term jtag`.
#   6. pip — LiteX family from git HEAD. Reasoning in the inline
#      comment below; tl;dr trixie Python 3.13 + PyPI migen don't agree.

FROM mcr.microsoft.com/devcontainers/base:trixie

# --- 1. apt -------------------------------------------------------------------

# Grouped roles:
#   yosys + nextpnr-ecp5 + fpga-trellis: open-source ECP5 synth/PnR/pack.
#   openocd: JTAG driver for `litex_term jtag`. openFPGALoader is built
#     from source in step 4 (apt's is too old).
#   gcc-riscv64-unknown-elf + meson + ninja-build: cross-compile the
#     LiteX BIOS for the VexRiscv soft CPU.
#   cmake + libftdi1-dev + pkg-config + build-essential +
#     libusb-1.0-0-dev + libyaml-dev + zlib1g-dev + libudev-dev:
#     ecpprog, openFPGALoader, and openocd-vexriscv source builds.
#   autoconf + automake + libtool: openocd-vexriscv ./bootstrap.
#   tcl: openocd-vexriscv pulls a jimtcl submodule at the pinned tag
#     whose `./configure.gnu` script first looks for an installed jimsh
#     or tclsh; if neither is present it falls back to building a
#     minimal `jimsh0` bootstrap, and that bootstrap's compiler probe
#     fails inside buildkit's sandbox. Having tcl installed lets the
#     configure short-circuit before the bootstrap path runs.
#   gdb-multiarch: rv32 GDB for the .vscode/launch.json step-debug flow.
#   python3-pip + python3-venv: pip install in step 6. trixie defaults
#     to PEP 668; --break-system-packages later because the container
#     IS the dev env.
#   usbutils: lsusb for diagnosing USB pass-through.
#   srecord: srec_cat for the upstream prjtrellis multiboot Makefile
#     (our wrapper skips it but the upstream example uses it).
#   git + curl + sudo: general dev hygiene.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    yosys \
    nextpnr-ecp5 \
    fpga-trellis \
    openocd \
    make \
    cmake \
    usbutils \
    gcc-riscv64-unknown-elf \
    python3-pip \
    python3-venv \
    libftdi1-dev \
    libusb-1.0-0-dev \
    libudev-dev \
    libyaml-dev \
    zlib1g-dev \
    pkg-config \
    build-essential \
    meson \
    ninja-build \
    srecord \
    git \
    curl \
    sudo \
    gdb-multiarch \
    autoconf \
    automake \
    libtool \
    tcl \
    && rm -rf /var/lib/apt/lists/*

# --- 2. prjtrellis ------------------------------------------------------------

# Shallow clone — we only need the verilog + LPF in
# examples/ecp5_evn_multiboot. The multiboot/Makefile reads $PRJTRELLIS_DIR
# (set in devcontainer.json containerEnv) to find this. Pinned to a tag
# so the weekly cron picks up upstream drift on a bump-commit, not
# silently via HEAD changes.
ARG PRJTRELLIS_VERSION=1.4
RUN git clone --depth=1 --branch ${PRJTRELLIS_VERSION} \
        https://github.com/YosysHQ/prjtrellis.git /opt/prjtrellis

# --- 3. ecpprog --------------------------------------------------------------

# Not packaged in trixie apt. Small ~30 s build. Used by the multiboot
# Makefile and advanced LiteX flows as an openfpgaloader alternative.
# ecpprog has no upstream tags, so pin a commit SHA. Bump on intent.
ARG ECPPROG_COMMIT=1931c3e121f682536a9d80ca1ce1b651c11aef76
RUN git clone https://github.com/gregdavill/ecpprog.git /tmp/ecpprog \
    && git -C /tmp/ecpprog checkout ${ECPPROG_COMMIT} \
    && make -C /tmp/ecpprog/ecpprog \
    && install -m 755 /tmp/ecpprog/ecpprog/ecpprog /usr/local/bin/ecpprog \
    && rm -rf /tmp/ecpprog

# --- 4. openFPGALoader -------------------------------------------------------

# Trixie's apt ships v0.13.1 (Dec 2024). Upstream is at v1.1.1 (Mar 2026)
# at time of writing, with bug fixes around JTAG init and ECP5 board
# presets. Building from source keeps the container at parity with what
# Zomp bench machines run natively. Pinned to a tag for reproducible
# builds — bump on intent. ~2 min build.
ARG OPENFPGALOADER_VERSION=v1.1.1
RUN git clone --depth=1 --branch ${OPENFPGALOADER_VERSION} \
        https://github.com/trabucayre/openFPGALoader.git /tmp/openfpgaloader \
    && cmake -S /tmp/openfpgaloader -B /tmp/openfpgaloader/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /tmp/openfpgaloader/build --parallel "$(nproc)" \
    && cmake --install /tmp/openfpgaloader/build \
    && rm -rf /tmp/openfpgaloader

# --- 5. openocd-vexriscv ------------------------------------------------------

# Standard openocd doesn't have the VexRiscv target driver — needed for
# the step-debug launch.json in consumer repos. The SpinalHDL fork
# adds it. ~5 min build.
#
# --enable-dummy gives us the `dummy` adapter driver, which is what
# `interface dummy` resolves to in .vscode/openocd-vexriscv-ecp5.cfg.
# Without it openocd exits with "Debug Adapter has to be specified"
# before our vexriscv target can register.
#
# Bundled at /opt/openocd-vexriscv so it doesn't shadow apt's standard
# openocd (which consumer projects still use for `litex_term jtag`).
#
# Pinned to a commit SHA rather than the `v0.9.0` release tag. v0.9.0
# carries two regressions against modern toolchains:
#   1. its jimtcl submodule's `./configure.gnu` runs a bootstrap-jimsh0
#      compiler probe that fails inside buildkit's sandbox (worked
#      around by installing `tcl` in step 1 so the configure
#      short-circuits before bootstrap), and
#   2. `bitbang.h` declares `bitbang_swd` at file scope without `static`
#      or `extern`, which Trixie's GCC 14 rejects under its default
#      `-fno-common` with `multiple definition of bitbang_swd`. Fixed
#      post-tag upstream.
# Pin to the current master HEAD SHA — bump on intent.
ARG OPENOCD_VEXRISCV_COMMIT=a0220ad302589de0e9ed41344ccf5a87118cf54b
RUN git clone https://github.com/SpinalHDL/openocd_riscv.git /tmp/ocd-src \
    && git -C /tmp/ocd-src checkout ${OPENOCD_VEXRISCV_COMMIT} \
    && cd /tmp/ocd-src \
    && ./bootstrap \
    && ./configure --prefix=/opt/openocd-vexriscv --enable-dummy --disable-werror \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf /tmp/ocd-src

# --- 6. pip (LiteX family from git HEAD) -------------------------------------

# Pulled from git, not PyPI, because Debian trixie ships Python 3.13 and
# PyPI's pinned migen release predates the bytecode-tracer fix that
# handles 3.13's CALL opcode (LiteX's `self.cd_sys = ClockDomain()`
# pattern fails with "Cannot extract clock domain name from code").
# Mixing git-HEAD migen with pip-released LiteX hits a different
# TypeError in the verilog generator (signal-NoneType from a memory
# port). Pulling the whole family from git keeps the ABI in sync.
#
# pythondata-cpu-vexriscv: required for --cpu-type=vexriscv synthesis.
# pythondata-software-compiler_rt + picolibc: BIOS runtime + libc for the
# RISC-V cross-compile.
RUN pip install --break-system-packages --upgrade \
    git+https://github.com/m-labs/migen.git \
    git+https://github.com/enjoy-digital/litex.git \
    git+https://github.com/litex-hub/litex-boards.git \
    git+https://github.com/enjoy-digital/litedram.git \
    git+https://github.com/litex-hub/pythondata-cpu-vexriscv.git \
    git+https://github.com/litex-hub/pythondata-software-compiler_rt.git \
    git+https://github.com/litex-hub/pythondata-software-picolibc.git

# --- 7. sanity check --------------------------------------------------------

# Fail the build if anything didn't install — better to find out at image
# build time than at first F5. Existence checks rather than `tool -V`
# because nextpnr-ecp5 -V exits non-zero ("no design loaded") even though
# it prints the version line.
RUN set -e; \
    command -v yosys; \
    command -v nextpnr-ecp5; \
    command -v openFPGALoader; \
    command -v ecpprog; \
    command -v riscv64-unknown-elf-gcc; \
    command -v gdb-multiarch; \
    test -x /opt/openocd-vexriscv/bin/openocd; \
    test -d /opt/prjtrellis/examples; \
    python3 -c 'import litex, litex_boards, migen, litedram, pythondata_cpu_vexriscv'; \
    echo 'sanity check passed'

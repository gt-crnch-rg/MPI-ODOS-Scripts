# syntax=docker/dockerfile:1
#
# Builds the x86_64 *host* side of the ODOS-MPI framework following the
# top-level README steps (setup -> compile), up to but not including the
# application compile & run stage in apps/.
#
# Compile script call order (from compile.sh -> compile_host.sh):
#   compile_1_ucx.sh                  -- build UCX transport layer (x86_64)
#   compile_2_odos.sh                 -- build ODOS LLVM/clang + OpenMP runtime
#   compile_3_ompi.sh                 -- build Open MPI + DOCA MCA plugins (x86_64)
#   compile_4_pnetcdf.sh              -- build Parallel NetCDF
#   dpu_scripts/compile_dpu.sh        -- DPU (aarch64) orchestrator, OUT OF SCOPE
#   dpu_scripts/compile_5_service.sh  -- DPU service (aarch64 / armclang only), OUT OF SCOPE
#
# Intentionally OUT OF SCOPE on a plain x86_64 Ubuntu container:
#   * aarch64 / BlueField-DPU cross builds  (dpu_scripts/compile_dpu.sh)
#   * doca-omp-service                       (hard-codes the `armclang` aarch64 compiler)
#   * the SLURM run stage                    (sbatch / squeue / scancel)
#
# DOCA: the image does NOT contain the NVIDIA DOCA SDK. The build bind-mounts
#       it read-only from an external build context named `doca` for the steps
#       that compile or check against it; at runtime, mount the host's copy at
#       ${DOCA_PATH} (default /opt/mellanox/doca). Use the same DOCA release on
#       the host as at build time -- the image's rdma-core is matched to it.
#
# Build:   docker buildx build --build-context doca=/opt/mellanox/doca -t odos-mpi .
# Run:     docker run -it -v /opt/mellanox/doca:/opt/mellanox/doca:ro odos-mpi
# (compile_2_odos.sh builds LLVM/clang: allow plenty of RAM/CPU/time.)

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG DOCA_PATH=/opt/mellanox/doca

# The cluster scripts hard-code these Rocky-9 module paths; we alias them to
# real container locations so the scripts run unmodified.
ARG ROCKY_DOCA=/global/software/rocky-9.x86_64/modules/tools/doca/2.0.2/opt/mellanox/doca
ARG ROCKY_CMAKE=/global/software/rocky-9.x86_64/modules/tools/cmake/3.26.4/bin/cmake

ENV APP_ROOT=/opt/odos-mpi
ENV DOCA_PATH=${DOCA_PATH}

# ---------------------------------------------------------------------------
# 0) Toolchain & build dependencies
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc g++ make \
        autoconf automake libtool libtool-bin m4 \
        flex bison perl \
        git wget curl ca-certificates gnupg \
        python3 python3-dev python3-pip \
        pkg-config \
        zlib1g-dev libnuma-dev libffi-dev libelf-dev \
        libibverbs-dev librdmacm-dev rdma-core \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Recent CMake (cluster used 3.26.4; Ubuntu 22.04 ships 3.22) from Kitware.
RUN wget -qO- https://apt.kitware.com/keys/kitware-archive-latest.asc \
        | gpg --dearmor -o /usr/share/keyrings/kitware-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ jammy main" \
        > /etc/apt/sources.list.d/kitware.list \
    && apt-get update && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 1) `module` (Lmod) shim — scripts call `module load ...`; make it a no-op.
# ---------------------------------------------------------------------------
RUN printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/module \
    && chmod +x /usr/local/bin/module

# ---------------------------------------------------------------------------
# 2) DOCA's rdma-core. The DOCA SDK itself is never copied into the image:
#     RUN steps that need it bind-mount the `doca` build context at ${DOCA_PATH}.
#     DOCA >= 3.x libraries need newer libibverbs/libmlx5 symbol versions
#     (e.g. MLX5_1.25) than Ubuntu 22.04's rdma-core 39, so install the
#     rdma-core that ships with that DOCA release (open source), from
#     NVIDIA's DOCA apt repo. DOCA_REPO_VERSION defaults to <major>.<minor>.0
#     of ${DOCA_PATH}/VERSION (e.g. 3.5.0098 -> 3.5.0). Newer repos ship a binary
#     doca_keyring.gpg, older ones (3.3.0) an ASCII GPG-KEY-Mellanox.pub.
#     The DOCA version built against is recorded in /etc/odos-doca-version.
# ---------------------------------------------------------------------------
ARG DOCA_REPO_VERSION=
RUN --mount=type=bind,from=doca,target=${DOCA_PATH} \
    test -f "$DOCA_PATH/VERSION" \
        || { echo "no DOCA SDK in the 'doca' build context: pass --build-context doca=<DOCA install dir>" >&2; exit 1; } \
    && cp "$DOCA_PATH/VERSION" /etc/odos-doca-version \
    && V="${DOCA_REPO_VERSION:-$(cut -d. -f1,2 "$DOCA_PATH/VERSION").0}" \
    && R="https://linux.mellanox.com/public/repo/doca/$V/ubuntu22.04/x86_64" \
    && { wget -qO /tmp/doca-key "$R/doca_keyring.gpg" && mv /tmp/doca-key /usr/share/keyrings/doca.gpg; } \
       || { wget -qO- "$R/GPG-KEY-Mellanox.pub" | gpg --batch --yes --dearmor -o /usr/share/keyrings/doca.gpg; } \
    && echo "deb [signed-by=/usr/share/keyrings/doca.gpg] $R/ ./" > /etc/apt/sources.list.d/doca.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        libibverbs1 ibverbs-providers librdmacm1 rdma-core libibverbs-dev librdmacm-dev \
    && rm -rf /var/lib/apt/lists/* \
    && ! LD_LIBRARY_PATH="$DOCA_PATH/lib/x86_64-linux-gnu" \
         ldd "$DOCA_PATH/lib/x86_64-linux-gnu/libdoca_comch.so" 2>&1 | grep "not found"

# ---------------------------------------------------------------------------
# 3) Path aliases so hard-coded cluster paths resolve in this container:
#       <rocky DOCA path>  -> ${DOCA_PATH}
#       <rocky cmake path> -> system cmake
#
#    The DOCA alias dangles until the SDK is mounted at ${DOCA_PATH} (during
#    the build, and from the host at runtime). The DOCA 2.0 Comm Channel ->
#    Comch source port is in patches/, applied by setup.sh (apply_patches.sh).
# ---------------------------------------------------------------------------
RUN mkdir -p "$(dirname "$ROCKY_DOCA")" "$(dirname "$ROCKY_CMAKE")" \
    && ln -sfn "$DOCA_PATH" "$ROCKY_DOCA" \
    && ln -sf "$(command -v cmake)" "$ROCKY_CMAKE"

# ---------------------------------------------------------------------------
# 4) Project scripts
# ---------------------------------------------------------------------------
WORKDIR ${APP_ROOT}
COPY . ${APP_ROOT}/

# ---------------------------------------------------------------------------
# 5) install_odos_prereqs.sh — repo-provided prerequisites
# ---------------------------------------------------------------------------
RUN bash install_odos_prereqs.sh

# Make freshly built Open MPI / ODOS-clang visible to later compile steps
# (compile_4_pnetcdf.sh needs mpicc; non-existent paths on PATH are harmless).
ENV PATH=${APP_ROOT}/build/ompi/x86_64/install/bin:${APP_ROOT}/build/odos/install/bin:${APP_ROOT}/build/ucx/x86_64/install/bin:${PATH}
ENV LD_LIBRARY_PATH=${APP_ROOT}/build/ompi/x86_64/install/lib:${APP_ROOT}/build/ucx/x86_64/install/lib:${APP_ROOT}/build/odos/install/lib:${APP_ROOT}/build/pnetcdf/install/lib:${DOCA_PATH}/lib/x86_64-linux-gnu
ENV OPAL_PREFIX=${APP_ROOT}/build/ompi/x86_64/install

# ---------------------------------------------------------------------------
# 6) setup.sh: clone_repos.sh (git clone) + setup_dirs.sh (build/ layout)
# ---------------------------------------------------------------------------
RUN sh setup.sh

# ---------------------------------------------------------------------------
# 7) compile_1_ucx.sh — UCX transport layer (x86_64)
# ---------------------------------------------------------------------------
RUN sh compile_1_ucx.sh ./build/ucx/x86_64

# ---------------------------------------------------------------------------
# 8) compile_2_odos.sh — ODOS LLVM/clang + OpenMP offload runtime
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=doca,target=${DOCA_PATH} \
    sh compile_2_odos.sh \
        "$(pwd)/repos/ODOS" \
        "$(pwd)/build/odos/build" \
        "$(pwd)/build/odos/install"

# ---------------------------------------------------------------------------
# 9) compile_3_ompi.sh — Open MPI (x86_64) + DOCA MCA plugins
# ---------------------------------------------------------------------------
RUN --mount=type=bind,from=doca,target=${DOCA_PATH} \
    sh compile_3_ompi.sh \
        ./build/ompi/x86_64 \
        "$(pwd)/build/ucx/x86_64/install" \
        "$ROCKY_DOCA" \
        "$ROCKY_CMAKE"

# ---------------------------------------------------------------------------
# 10) compile_4_pnetcdf.sh — Parallel NetCDF
# ---------------------------------------------------------------------------
RUN sh compile_4_pnetcdf.sh ./build/pnetcdf

# ---------------------------------------------------------------------------
# 11) verify_build.sh — the compile scripts have no `set -e`, so without this
#     a failed build step still produces a "successful" image.
#     REQUIRE_DOCA=1 (the default) also requires the ODOS/DOCA components;
#     pass --build-arg REQUIRE_DOCA=0 to accept a stock-only build.
# ---------------------------------------------------------------------------
ARG REQUIRE_DOCA=1
RUN --mount=type=bind,from=doca,target=${DOCA_PATH} \
    REQUIRE_DOCA=${REQUIRE_DOCA} sh verify_build.sh ./build

# Applications (apps/) and the SLURM run stage are left to the user;
# see apps/README.md.
CMD ["/bin/bash"]

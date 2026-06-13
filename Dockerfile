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
# DOCA: this image ASSUMES NVIDIA DOCA 3.3 is present at ${DOCA_PATH}
#       (default /opt/mellanox/doca). DOCA is *not* installed here — provide it
#       via a DOCA base image, a bind mount, or a COPY before the compile steps.
#
# Build:   docker build -t odos-mpi .
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
# 2) Path aliases so hard-coded cluster paths resolve in this container:
#       <rocky DOCA path>  -> ${DOCA_PATH}
#       ${DOCA_PATH}/lib64 -> DOCA 3.3 Ubuntu lib dir
#       <rocky cmake path> -> system cmake
#
#    NOTE: DOCA 3.3 renamed libdoca_comm_channel -> libdoca_comch and uses
#    lib/x86_64-linux-gnu instead of lib64. compile_3_ompi.sh (DOCA MCA) and
#    compile_2_odos.sh (OpenMP-offload) link against the old names and may need
#    source updates for 3.3. compile_1_ucx.sh and compile_4_pnetcdf.sh are
#    unaffected.
# ---------------------------------------------------------------------------
RUN mkdir -p "$(dirname "$ROCKY_DOCA")" "$(dirname "$ROCKY_CMAKE")" \
    && ln -sfn "$DOCA_PATH" "$ROCKY_DOCA" \
    && ln -sf "$(command -v cmake)" "$ROCKY_CMAKE" \
    && if [ -d "$DOCA_PATH/lib/x86_64-linux-gnu" ] && [ ! -e "$DOCA_PATH/lib64" ]; then \
           ln -sfn lib/x86_64-linux-gnu "$DOCA_PATH/lib64"; \
       fi

# ---------------------------------------------------------------------------
# 3) Project scripts
# ---------------------------------------------------------------------------
WORKDIR ${APP_ROOT}
COPY . ${APP_ROOT}/

# Make freshly built Open MPI / ODOS-clang visible to later compile steps
# (compile_4_pnetcdf.sh needs mpicc; non-existent paths on PATH are harmless).
ENV PATH=${APP_ROOT}/build/ompi/x86_64/install/bin:${APP_ROOT}/build/odos/install/bin:${PATH}
ENV LD_LIBRARY_PATH=${APP_ROOT}/build/ompi/x86_64/install/lib:${APP_ROOT}/build/ucx/x86_64/install/lib:${APP_ROOT}/build/odos/install/lib:${DOCA_PATH}/lib64:${LD_LIBRARY_PATH}
ENV OPAL_PREFIX=${APP_ROOT}/build/ompi/x86_64/install

# ---------------------------------------------------------------------------
# 4) setup.sh: clone_repos.sh (git clone) + setup_dirs.sh (build/ layout)
# ---------------------------------------------------------------------------
RUN sh setup.sh

# ---------------------------------------------------------------------------
# 5) compile_1_ucx.sh — UCX transport layer (x86_64)
# ---------------------------------------------------------------------------
RUN sh compile_1_ucx.sh ./build/ucx/x86_64

# ---------------------------------------------------------------------------
# 6) compile_2_odos.sh — ODOS LLVM/clang + OpenMP offload runtime
# ---------------------------------------------------------------------------
RUN sh compile_2_odos.sh \
        "$(pwd)/repos/ODOS" \
        "$(pwd)/build/odos/build" \
        "$(pwd)/build/odos/install"

# ---------------------------------------------------------------------------
# 7) compile_3_ompi.sh — Open MPI (x86_64) + DOCA MCA plugins
# ---------------------------------------------------------------------------
RUN sh compile_3_ompi.sh \
        ./build/ompi/x86_64 \
        "$(pwd)/build/ucx/x86_64/install" \
        "$ROCKY_DOCA" \
        "$ROCKY_CMAKE"

# ---------------------------------------------------------------------------
# 8) compile_4_pnetcdf.sh — Parallel NetCDF
# ---------------------------------------------------------------------------
RUN sh compile_4_pnetcdf.sh ./build/pnetcdf

# Applications (apps/) and the SLURM run stage are left to the user;
# see apps/README.md.
CMD ["/bin/bash"]

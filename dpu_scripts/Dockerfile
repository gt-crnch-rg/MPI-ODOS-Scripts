# syntax=docker/dockerfile:1
#
# Builds the aarch64 *DPU* side of the ODOS-MPI framework on an aarch64 host.
#
# Compile script call order:
#   setup.sh                           -- clone repos + create build layout
#   dpu_scripts/compile_dpu.sh         -- orchestrates DPU build flow
#      -> compile_1_ucx.sh             -- UCX transport layer (aarch64)
#      -> compile_3_ompi.sh            -- Open MPI + DOCA MCA plugins (aarch64)
#      -> dpu_scripts/compile_5_service.sh -- doca-omp-service (expects armclang)
#
# DOCA: this image pulls NVIDIA DOCA from an external build context named
#       doca into ${DOCA_PATH} (default /opt/mellanox/doca).
#
# Example build (run on an aarch64 host):
#   export HOST_DOCA_PATH=/opt/mellanox/doca
#   docker buildx build --platform linux/arm64 \
#       --build-context doca="${HOST_DOCA_PATH}" \
#       -f dpu_scripts/Dockerfile -t odos-mpi-dpu .

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG DOCA_PATH=/opt/mellanox/doca

# The DPU scripts hard-code these Rocky aarch64 module paths.
ARG ROCKY_DOCA=/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/doca
ARG ROCKY_CMAKE=/global/software/rocky-9.aarch64/modules/tools/cmake/3.26.4/bin/cmake
ARG ROCKY_ARM_BIN=/global/software/rocky-9.aarch64/modules/langs/arm/23.04/arm-linux-compiler-23.04.1_RHEL-9/bin

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
    && apt-get update && apt-get install -y --no-install-recommends cmake clang \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 1) `module` (Lmod) shim — scripts call `module load ...`; make it a no-op.
# ---------------------------------------------------------------------------
RUN printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/module \
    && chmod +x /usr/local/bin/module

# ---------------------------------------------------------------------------
# 2) Import DOCA from external build context (`doca`) into ${DOCA_PATH}
# ---------------------------------------------------------------------------
COPY --from=doca . ${DOCA_PATH}/

# ---------------------------------------------------------------------------
# 3) Path aliases so hard-coded cluster paths resolve in this container.
# ---------------------------------------------------------------------------
RUN mkdir -p "$(dirname "$ROCKY_DOCA")" "$(dirname "$ROCKY_CMAKE")" "$ROCKY_ARM_BIN" \
    && ln -sfn "$DOCA_PATH" "$ROCKY_DOCA" \
    && ln -sf "$(command -v cmake)" "$ROCKY_CMAKE" \
    && ln -sf "$(command -v clang)" "$ROCKY_ARM_BIN/armclang" \
    && test -d "$DOCA_PATH" \
    && if [ -d "$DOCA_PATH/lib/aarch64-linux-gnu" ] && [ ! -e "$DOCA_PATH/lib64" ]; then \
           ln -sfn lib/aarch64-linux-gnu "$DOCA_PATH/lib64"; \
       fi

# ---------------------------------------------------------------------------
# 4) Project scripts
# ---------------------------------------------------------------------------
WORKDIR ${APP_ROOT}
COPY . ${APP_ROOT}/

# ---------------------------------------------------------------------------
# 5) setup + DPU compile flow
# ---------------------------------------------------------------------------
RUN sh setup.sh
RUN sh dpu_scripts/compile_dpu.sh

CMD ["/bin/bash"]

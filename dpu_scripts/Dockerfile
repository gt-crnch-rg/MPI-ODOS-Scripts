# syntax=docker/dockerfile:1
#
# Builds the aarch64 *DPU* side of the ODOS-MPI framework (DOCA >= 3.3) as an
# image to push to a registry and run on a BlueField DPU. See
# dpu_scripts/DPU_README.md.
#
# Two stages:
#   builder  dpu_scripts/setup_dpu.sh       -- clone + patch (DOCA Comch) + layout
#            dpu_scripts/compile_dpu.sh     -- orchestrates the DPU build:
#              -> compile_1_ucx.sh          -- UCX (aarch64)
#              -> compile_3_ompi.sh         -- Open MPI + ODOS pml/osc plugins
#              -> dpu_scripts/compile_5_service.sh -- doca-omp-service (clang)
#            dpu_scripts/verify_build.sh    -- fail on a silently broken build
#            dpu_scripts/install_dpu.sh     -- runtime tree in /opt/odos-dpu
#   runtime  /opt/odos-dpu + runtime libraries only; starts the service.
#
# DOCA: the image does NOT contain the NVIDIA DOCA SDK. The build bind-mounts
#       an aarch64 DOCA SDK read-only from a build context named `doca`; at
#       runtime the DPU's own /opt/mellanox/doca is mounted at ${DOCA_PATH}.
#       Use the same DOCA release as the DPU runs -- the image's rdma-core
#       comes from that release's DOCA apt repo.
#
# Build (on an arm64 host, or on x86_64 with QEMU binfmt -- slower):
#   docker buildx build --platform linux/arm64 \
#       --build-context doca=<aarch64 DOCA SDK dir> \
#       -f dpu_scripts/Dockerfile -t odos-mpi-dpu .
# Run (on the DPU):
#   docker run --rm -it --privileged --network host \
#       -v /opt/mellanox/doca:/opt/mellanox/doca:ro odos-mpi-dpu

ARG BASE_IMAGE=ubuntu:24.04
ARG DOCA_PATH=/opt/mellanox/doca
ARG ODOS_PREFIX=/opt/odos-dpu

FROM ${BASE_IMAGE} AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG DOCA_PATH
ARG ODOS_PREFIX

ENV APP_ROOT=/opt/odos-mpi
ENV DOCA_PATH=${DOCA_PATH}

# ---------------------------------------------------------------------------
# 0) Toolchain & build dependencies. clang + libomp build the service (the
#    cluster used armclang, also LLVM); Ubuntu 24.04's cmake (3.28) suffices.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc g++ make cmake \
        clang libomp-dev \
        autoconf automake libtool libtool-bin m4 \
        flex bison perl \
        git wget curl ca-certificates gnupg \
        python3 pkg-config \
        zlib1g-dev libnuma-dev libffi-dev libelf-dev \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 1) DOCA's rdma-core. The DOCA SDK itself is never copied into the image:
#     RUN steps that need it bind-mount the `doca` build context at
#     ${DOCA_PATH}. DOCA 3.x needs newer libibverbs/libmlx5 symbol versions
#     than the distro's rdma-core, so install the rdma-core of that DOCA
#     release from NVIDIA's arm64-dpu apt repo (the one the BlueField OS
#     uses). DOCA_REPO_VERSION defaults to <major>.<minor>.0 of
#     ${DOCA_PATH}/VERSION (e.g. 3.5.0098 -> 3.5.0); DOCA_REPO_DIST to this
#     image's OS (e.g. ubuntu24.04). Recorded in /etc/odos-doca-version.
# ---------------------------------------------------------------------------
ARG DOCA_REPO_VERSION=
ARG DOCA_REPO_DIST=
RUN --mount=type=bind,from=doca,target=${DOCA_PATH} \
    test -f "$DOCA_PATH/VERSION" \
        || { echo "no DOCA SDK in the 'doca' build context: pass --build-context doca=<aarch64 DOCA install dir>" >&2; exit 1; } \
    && ls "$DOCA_PATH"/lib/aarch64-linux-gnu/libdoca_comch.so >/dev/null \
    && cp "$DOCA_PATH/VERSION" /etc/odos-doca-version \
    && V="${DOCA_REPO_VERSION:-$(cut -d. -f1,2 "$DOCA_PATH/VERSION").0}" \
    && D="${DOCA_REPO_DIST:-$(. /etc/os-release && echo "$ID$VERSION_ID")}" \
    && R="https://linux.mellanox.com/public/repo/doca/$V/$D/arm64-dpu" \
    && { wget -qO- "$R/nvidia-doca-debian-gpg-public-key.asc" | gpg --batch --yes --dearmor -o /usr/share/keyrings/doca.gpg \
         && test -s /usr/share/keyrings/doca.gpg; } \
    && echo "deb [signed-by=/usr/share/keyrings/doca.gpg] $R/ ./" > /etc/apt/sources.list.d/doca.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        libibverbs1 ibverbs-providers librdmacm1 rdma-core libibverbs-dev librdmacm-dev \
    && rm -rf /var/lib/apt/lists/* \
    && ! LD_LIBRARY_PATH="$DOCA_PATH/lib/aarch64-linux-gnu" \
         ldd "$DOCA_PATH/lib/aarch64-linux-gnu/libdoca_comch.so" 2>&1 | grep "not found"

# ---------------------------------------------------------------------------
# 2) clone + patch + layout of UCX and ompi-bf (the service comes later).
#    Each script and patch is copied in just before the step that uses it, and
#    nothing else from the repo is: editing docs, host scripts, the service
#    patch, or a later step's script does not invalidate the (long) cached
#    UCX/Open MPI layers.
# ---------------------------------------------------------------------------
WORKDIR ${APP_ROOT}
COPY clone_repos.sh apply_patches.sh ${APP_ROOT}/
COPY patches/odos_comch.h ${APP_ROOT}/patches/
COPY patches/ompi-bf/ ${APP_ROOT}/patches/ompi-bf/
COPY dpu_scripts/setup_dpu.sh ${APP_ROOT}/dpu_scripts/
RUN sh dpu_scripts/setup_dpu.sh ucx ompi-bf

# ---------------------------------------------------------------------------
# 3) DPU compile flow, as separate layers (compile_dpu.sh runs the same three)
# ---------------------------------------------------------------------------
COPY compile_1_ucx.sh ${APP_ROOT}/
RUN sh compile_1_ucx.sh ./build/ucx/aarch64

COPY compile_3_ompi.sh ${APP_ROOT}/
RUN --mount=type=bind,from=doca,target=${DOCA_PATH} \
    sh compile_3_ompi.sh ./build/ompi/aarch64 \
        "$(pwd)/build/ucx/aarch64/install" "$DOCA_PATH" cmake

COPY patches/doca-omp-service/ ${APP_ROOT}/patches/doca-omp-service/
RUN sh dpu_scripts/setup_dpu.sh doca-omp-service
COPY dpu_scripts/compile_5_service.sh ${APP_ROOT}/dpu_scripts/
RUN --mount=type=bind,from=doca,target=${DOCA_PATH} \
    sh dpu_scripts/compile_5_service.sh ./build/service \
        "$DOCA_PATH" "$(pwd)/build/ompi/aarch64/install" cmake

# ---------------------------------------------------------------------------
# 4) verify + install. The compile scripts have no `set -e`; fail here rather
#    than ship an empty image. REQUIRE_DOCA=1 (the default) also requires the
#    ODOS/DOCA components; --build-arg REQUIRE_DOCA=0 accepts stock-only.
# ---------------------------------------------------------------------------
COPY dpu_scripts/verify_build.sh dpu_scripts/install_dpu.sh dpu_scripts/odos_dpu_service.sh \
     ${APP_ROOT}/dpu_scripts/
ARG REQUIRE_DOCA=1
RUN --mount=type=bind,from=doca,target=${DOCA_PATH} \
    REQUIRE_DOCA=${REQUIRE_DOCA} sh dpu_scripts/verify_build.sh ./build \
    && sh dpu_scripts/install_dpu.sh ./build ${ODOS_PREFIX} \
    && cp dpu_scripts/verify_build.sh ${ODOS_PREFIX}/bin/verify_build.sh

# ===========================================================================
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG DOCA_PATH
ARG ODOS_PREFIX

ENV DOCA_PATH=${DOCA_PATH}
ENV ODOS_PREFIX=${ODOS_PREFIX}

# Runtime dependencies only: libomp5 for the service (and the offload code
# it loads), libgomp1 for UCX's OpenMP tools, openssh-client for mpirun's
# rsh launcher across DPUs.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates openssh-client \
        libgomp1 libnuma1 libffi8 libelf1t64 zlib1g \
        "$(apt-cache depends libomp-dev | sed -n 's/.*Depends: \(libomp-[0-9]*-dev\)$/\1/p' | sed 's/-dev$//; s/libomp-/libomp5-/')" \
    && rm -rf /var/lib/apt/lists/*

# DOCA's rdma-core, from the repo the builder stage set up (see there).
COPY --from=builder /etc/odos-doca-version /etc/odos-doca-version
COPY --from=builder /usr/share/keyrings/doca.gpg /usr/share/keyrings/doca.gpg
COPY --from=builder /etc/apt/sources.list.d/doca.list /etc/apt/sources.list.d/doca.list
RUN apt-get update && apt-get install -y --no-install-recommends \
        libibverbs1 ibverbs-providers librdmacm1 rdma-core \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder ${ODOS_PREFIX} ${ODOS_PREFIX}

ENV PATH=${ODOS_PREFIX}/bin:${PATH}
# The service runs as root in a DPU pod; let mpirun do so too.
ENV OMPI_ALLOW_RUN_AS_ROOT=1
ENV OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

# Re-verify in the runtime stage: catches artifacts or libraries that did not
# make it across from the builder stage.
ARG REQUIRE_DOCA=1
RUN --mount=type=bind,from=doca,target=${DOCA_PATH} \
    REQUIRE_DOCA=${REQUIRE_DOCA} sh ${ODOS_PREFIX}/bin/verify_build.sh ${ODOS_PREFIX}

# Starts doca-omp-service; configure with ODOS_SERVICE / ODOS_MPI_VARIANT /
# ODOS_MPIRUN_ARGS / ODOS_COMCH_REP_PCI (see dpu_scripts/odos_dpu_service.sh).
CMD ["odos-dpu-service"]

# Docker Build Guide

This guide covers building the x86_64 **host** side of the ODOS-MPI framework
inside a Docker container using the provided `Dockerfile`.

## Prerequisites

- Docker Engine 20.10+ (BuildKit enabled by default)
- NVIDIA DOCA 3.3 or later installed on the host at `/opt/mellanox/doca`
  (the SDK: `doca-sdk-*` and `libdoca-sdk-*-dev` packages). It is needed both
  to build the image and to run it — the image does not contain DOCA.
- Network access to `linux.mellanox.com` (DOCA's rdma-core, see below)
- ~50 GB free disk space (LLVM/clang build is large)
- 16+ GB RAM recommended for the LLVM compile step

## What the build does

The Dockerfile mirrors the two README steps — `setup.sh` then `compile.sh` —
for the x86_64 host, running each compile script as a separate Docker layer:

| Layer | Script | What it builds |
|-------|--------|----------------|
| 4 | `setup.sh` | Clone repos (pinned commits), apply `patches/`, lay out `build/` tree |
| 5 | `compile_1_ucx.sh` | UCX transport library (x86_64) |
| 6 | `compile_2_odos.sh` | ODOS LLVM/clang + OpenMP offload runtime |
| 7 | `compile_3_ompi.sh` | Open MPI + DOCA MCA plugins (x86_64) |
| 8 | `compile_4_pnetcdf.sh` | Parallel NetCDF |
| 9 | `verify_build.sh` | Asserts the artifacts above actually exist |

**Out of scope** for this image:
- The DPU side (aarch64 UCX + Open MPI, `doca-omp-service`). It has its own
  image, `dpu_scripts/Dockerfile`; see
  [dpu_scripts/DPU_README.md](dpu_scripts/DPU_README.md).
- The SLURM run stage (`sbatch` / `squeue`)

## Build

The images do **not** contain the NVIDIA DOCA SDK. The build bind-mounts the
host's DOCA install read-only, from a build context named `doca`, only for the
steps that compile or check against it; nothing from it is written into a
layer. At runtime the host's DOCA is mounted into the container the same way
(see [Run](#run)). Inside the image DOCA always lives at `/opt/mellanox/doca`
(`--build-arg DOCA_PATH=<path>` changes that, rarely needed).

The image also installs the rdma-core user-space libraries that ship with
that DOCA release, from NVIDIA's DOCA apt repo: DOCA 3.x needs newer
`libibverbs`/`libmlx5` symbol versions than Ubuntu 22.04's rdma-core, and
without them none of DOCA's libraries load. The repo version is derived from
`<doca>/VERSION` (e.g. `3.5.0098` → `3.5.0`); override it with
`--build-arg DOCA_REPO_VERSION=<x.y.z>`.

**Option A — DOCA installed on the Docker host at the default path:**

```bash
export HOST_DOCA_PATH=/opt/mellanox/doca
docker buildx build --build-context doca="${HOST_DOCA_PATH}" -t odos-mpi .
```

**Option B — DOCA installed somewhere else on the host:** point the build
context at it; inside the image it is still `/opt/mellanox/doca`.

```bash
docker buildx build --build-context doca=/path/to/doca -t odos-mpi .
```

**Option C — Rebuild from a specific layer without rerunning earlier steps**
(Docker layer caching makes this free if the earlier layers are unchanged):

```bash
# Force re-run from compile_3_ompi.sh onward, e.g. after patching ompi-bf:
docker build --no-cache-filter "7" -t odos-mpi .
```

**Option D — two-stage build for a smaller distributable image:**

```bash
docker buildx build -f Dockerfile.two-stage --build-context doca="${HOST_DOCA_PATH}" -t odos-mpi:two-stage .
```

This drops the source and build trees and keeps only the install trees, taking
the image from ~16 GB to ~4.6 GB.

It is **not** a drop-in replacement for the single-stage image: the runtime
stage carries no compilers or `make`/`cmake`, so `mpicc` and `clang` cannot
link anything inside it. Use it to ship or run prebuilt binaries; use the
single-stage image to build applications. Note also that its builder stage does
not reliably reuse the single-stage image's layers, so expect a full LLVM
rebuild when switching.

> **Note on build time:** `compile_2_odos.sh` builds LLVM/clang from source.
> Expect 30–90+ minutes depending on CPU count. Subsequent rebuilds reuse the
> cached layer unless the ODOS source or script changes.

## Verify the build

The `compile_*.sh` scripts do not use `set -e`, so a failed configure or make
still exits 0 and the Docker layer still caches as successful. The build
therefore ends with an explicit check:

```bash
sh verify_build.sh ./build
```

A component counts as present only if its file exists **and** `ldd` resolves
all of its shared libraries, including symbol versions — so a DOCA-linked
plugin sitting on a too-old rdma-core is reported as `BROKEN`, not `ok`.

The Dockerfiles run it with `REQUIRE_DOCA=1`, so the build fails if any core
component (UCX, ODOS clang, Open MPI with a ucx pml/osc component, PnetCDF) *or*
any ODOS/DOCA component (OpenMP runtime, BlueField offload plugin, ODOS pml/osc
plugins) is missing. To accept a stock-only build, pass
`--build-arg REQUIRE_DOCA=0`; the ODOS/DOCA components then only warn.

## Run

Mount the host's DOCA install read-only at `/opt/mellanox/doca`:

```bash
docker run --rm -it -v /opt/mellanox/doca:/opt/mellanox/doca:ro odos-mpi
```

- Use the **same DOCA release** on the host as the image was built against;
  the image's rdma-core is matched to it. The build version is recorded in
  `/etc/odos-doca-version`, and `verify_build.sh` warns on a mismatch.
- Without the mount, everything except the ODOS/DOCA components still works
  (UCX, Open MPI, ODOS clang, PnetCDF); `verify_build.sh` says DOCA is missing.
- Talking to the DPU over Comch also needs the RDMA devices in the container,
  typically `--device=/dev/infiniband` (or `--privileged`).

Check the install from inside the container:

```bash
cd /opt/odos-mpi && REQUIRE_DOCA=1 sh verify_build.sh ./build
```

## Inspect the build

Installed components are under `/opt/odos-mpi/build/`:

```
build/
├── ucx/x86_64/install/      # UCX headers + libs
├── odos/install/            # ODOS clang, OpenMP runtime
├── ompi/x86_64/install/     # Open MPI + DOCA MCA plugins
└── pnetcdf/install/         # Parallel NetCDF
```

Check that key binaries exist:

```bash
ls /opt/odos-mpi/build/ompi/x86_64/install/bin/mpicc
ls /opt/odos-mpi/build/odos/install/bin/clang
ls /opt/odos-mpi/build/ucx/x86_64/install/lib/libucx*
```

## Extract build artifacts

Copy the compiled output out of the container without running it interactively:

```bash
# Create a temporary container
docker create --name odos-mpi-tmp odos-mpi

# Copy the entire build tree to the host
docker cp odos-mpi-tmp:/opt/odos-mpi/build ./build

# Clean up
docker rm odos-mpi-tmp
```

## Sharing a Docker image via DockerHub

The images contain no DOCA SDK, so they can be shared without redistributing
it. (They do contain rdma-core from NVIDIA's DOCA apt repo, which is open
source, and that repo's apt configuration.) Whoever runs the image needs DOCA
installed on their host — the same release the image was built against — and
mounts it as shown under [Run](#run); say which release in the tag or
description.

To share this image via a DockerHub repository, you can do the following steps:
```
docker login ## enter your DockerHub username
docker tag odos-mpi <username>/odos-smartnic:odos-mpi-host-v1
docker push <username>/odos-smartnic:odos-mpi-host-v1
```

## Known limitations

### DOCA 3.x port (`patches/`)

The ODOS sources were written against DOCA 2.0.2, whose Comm Channel API
(`doca_comm_channel.h`) DOCA 3.x removed in favour of Comch (`doca_comch.h`).
`setup.sh` therefore runs `apply_patches.sh` after cloning, which ports all
three DOCA users:

| Repo | Patched | Runs on |
|------|---------|---------|
| ODOS | `openmp/libomptarget/plugins/bf` (BlueField offload plugin) | host |
| ompi-bf | `ompi/mca/{pml,osc}/ucx/*_doca.c` (ODOS MCA plugins) | host and DPU |
| doca-omp-service | `ref/`, `mpi/` | DPU |

The send/receive path goes through one shared header, `patches/odos_comch.h`,
which rebuilds the old blocking one-message semantics on top of Comch's
asynchronous tasks and receive callbacks, so the ODOS wire protocol (2 KB
messages, an ack every 64 KB) is unchanged. Host and DPU must both run the
ported code: a DOCA 2.0 build on one side cannot talk to a Comch build on the
other.

The patches target the commits `clone_repos.sh` now pins. Patch-specific
behaviour, configurable through the environment:

- `ODOS_COMCH_REP_PCI` (DPU) — PCI address of the representor the server
  listens on. Default: the first network representor that is not an uplink
  (DOCA 2.0 code used `rep[0]`, which in DOCA 3.x is the uplink).
- `ODOS_COMCH_CONNECT_TIMEOUT` (host) — seconds to keep retrying the
  connection to the DPU service; `-1` retries forever. The offload plugin
  defaults to 30 s, the MPI plugins retry forever (as before).

What has been verified, and what has not:

- All five components build and link against DOCA 3.3.0109 and 3.5.0098,
  with no unresolved symbols (`ldd -r`).
- `patches/test/test_odos_comch.c` runs the ODOS protocol through
  `odos_comch.h` against a mock of the Comch API (asynchronous sends, few
  send slots, reconnects), under ASan/UBSan.
- The DPU side builds against DOCA ≥ 3.3 with `dpu_scripts/`. Its binaries
  load and resolve against a real BlueField-3's DOCA 3.5. The DPU service has
  to run as root, which this testing did not have (see "What has been tested"
  in [dpu_scripts/DPU_README.md](dpu_scripts/DPU_README.md)).
- **Not yet run end to end.** A host ↔ DPU round trip still needs to be tested
  on a BlueField, with the DPU service running as root.

`compile_3_ompi.sh` builds each ODOS plugin *before* renaming the stock
component to `orig.mca_*_ucx.so`, so a failed plugin build leaves working stock
UCX components in place. It also gives the plugin `cmake` invocation:

- the in-tree libevent/hwloc include paths, which the plugin `CMakeLists.txt`
  assumes are already on the include path (true on the cluster via hpcx, not
  on a plain distro);
- Open MPI's own machine flags (`-m*`, i.e. `-mcx16` on x86_64). The plugins
  compile Open MPI's 128-bit atomics; without `-mcx16` gcc emits a
  `__sync_val_compare_and_swap_16` call that no library provides, which only
  fails once that code path runs.

### App submodules and the `pkg/` tree

`apps/omb-odos` and `apps/miniweather` are git submodules (public, on GitHub —
see `.gitmodules`) and are excluded from the build context by `.dockerignore`,
so the application compile stage is not part of this Dockerfile.

`apps/compile.sh` also reads from a `pkg/` tree produced by `prepare_pkg.sh`,
which the image does not create: `prepare_pkg.sh` requires the aarch64 UCX and
Open MPI builds and the DPU service, all out of scope for an x86_64 host image.
Building the applications therefore needs either a DPU-side build as well, or a
host-only variant of `prepare_pkg.sh`. Refer to `apps/README.md`.

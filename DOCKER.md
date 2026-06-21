# Docker Build Guide

This guide covers building the x86_64 **host** side of the ODOS-MPI framework
inside a Docker container using the provided `Dockerfile`.

## Prerequisites

- Docker Engine 20.10+ (BuildKit enabled by default)
- NVIDIA DOCA 3.3 installed on the host at `/opt/mellanox/doca`
- ~50 GB free disk space (LLVM/clang build is large)
- 16+ GB RAM recommended for the LLVM compile step

## What the build does

The Dockerfile mirrors the two README steps — `setup.sh` then `compile.sh` —
for the x86_64 host, running each compile script as a separate Docker layer:

| Layer | Script | What it builds |
|-------|--------|----------------|
| 4 | `setup.sh` | Clone repos, lay out `build/` tree |
| 5 | `compile_1_ucx.sh` | UCX transport library (x86_64) |
| 6 | `compile_2_odos.sh` | ODOS LLVM/clang + OpenMP offload runtime |
| 7 | `compile_3_ompi.sh` | Open MPI + DOCA MCA plugins (x86_64) |
| 8 | `compile_4_pnetcdf.sh` | Parallel NetCDF |

**Out of scope** (requires an aarch64/BlueField host):
- `dpu_scripts/compile_dpu.sh` — aarch64 UCX + Open MPI
- `dpu_scripts/compile_5_service.sh` — DPU service (`armclang` only)
- The SLURM run stage (`sbatch` / `squeue`)

## Build

DOCA must be present inside the build context or bind-mounted. The default
path is `/opt/mellanox/doca`; override with `--build-arg DOCA_PATH=<path>`.

**Option A — DOCA already installed on the Docker host at the default path:**

```bash
export HOST_DOCA_PATH=/opt/mellanox/doca
docker buildx build --build-context doca="${HOST_DOCA_PATH}" -t odos-mpi .
```

**Option B — DOCA at a non-standard path:**

```bash
docker build \
  --build-arg DOCA_PATH=/path/to/doca \
  -t odos-mpi .
```

**Option C — Rebuild from a specific layer without rerunning earlier steps**
(Docker layer caching makes this free if the earlier layers are unchanged):

```bash
# Force re-run from compile_3_ompi.sh onward, e.g. after patching ompi-bf:
docker build --no-cache-filter "7" -t odos-mpi .
```

You can also use the two-stage build to create a smaller compressed image once the build is complete.
```bash
docker buildx build -f Dockerfile.two-stage --build-context doca="${HOST_DOCA_PATH}" -t odos-mpi:two-stage .
```

> **Note on build time:** `compile_2_odos.sh` builds LLVM/clang from source.
> Expect 30–90+ minutes depending on CPU count. Subsequent rebuilds reuse the
> cached layer unless the ODOS source or script changes.

## Inspect the build

Drop into a shell inside the finished image:

```bash
docker run --rm -it odos-mpi
```

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

To share this image via a DockerHub repository, you can do the following steps:
```
docker login ## enter your DockerHub username
docker tag odos-mpi <username>/odos-smartnic:odos-mpi-host-v1
docker push <username>/odos-smartnic:odos-mpi-host-v1
```

## Known limitations

### DOCA 3.3 API changes

The scripts were written against DOCA 2.0.2 (Rocky Linux). DOCA 3.3 renamed
`libdoca_comm_channel` → `libdoca_comch` and changed the library path from
`lib64/` to `lib/x86_64-linux-gnu/`. This affects:

- **`compile_3_ompi.sh`** — Open MPI DOCA MCA plugins link against
  `libdoca_comm_channel.so`, `libdoca_dma.so`, `libdoca_common.so`
- **`compile_2_odos.sh`** — ODOS OpenMP offload runtime uses DOCA Comm Channel

`compile_1_ucx.sh` and `compile_4_pnetcdf.sh` are unaffected.

If the DOCA-linked steps fail, the build log will show the linker error. The
scripts use `set -x` but not `set -e`, so the build continues past failures —
check which install directories were actually populated.

### Private app submodules

`apps/omb-odos` and `apps/miniweather` are private GitLab submodules with no
public mirror. The application compile stage (`apps/compile.sh`) is therefore
not included in this Dockerfile. Refer to `apps/README.md` for those steps.

# DPU (BlueField) build and container

This directory builds the aarch64 **DPU** side of ODOS-MPI against
**DOCA 3.3 or later** and packages it as a container image. You push the image
to a registry and run it on a BlueField DPU. The host side is covered in
[../DOCKER.md](../DOCKER.md).

What runs on the DPU:

| Component | What it is |
|-----------|-----------|
| `doca-omp-service` | ODOS OpenMP offload service (`ref/`) |
| `doca-omp-service-mpi` | the same service built against MPI (`mpi/`), used by the ODOS MPI apps |
| UCX, Open MPI (`ompi-bf`) | the MPI stack for the service, in three variants: `ref` (stock), `pt2pt` (ODOS pml), `one-sided` (ODOS osc) |

The sources were written for DOCA 2.0's Comm Channel API, which DOCA 3.x
removed. The DPU build applies the same `patches/` as the host build. The
patches port the service and the ompi-bf plugins to DOCA Comch (see
"DOCA 3.x port" in [../DOCKER.md](../DOCKER.md)). Host and DPU must both run
the ported code.

## DOCA

DOCA is expected at **`/opt/mellanox/doca`** on the build machine and on the
DPU. The BlueField OS (BFB) already installs it there. **The image does not
contain DOCA:**

- The build bind-mounts an **aarch64** DOCA SDK read-only from a build context
  named `doca`. The SDK needs `VERSION`, `include/` and `lib/aarch64-linux-gnu/`.
- At run time, the container mounts the DPU's own `/opt/mellanox/doca`.

The image does contain the rdma-core user-space libraries that ship with that
DOCA release. They come from NVIDIA's `arm64-dpu` apt repo, the same repo the
BlueField OS uses: DOCA 3.x needs newer `libibverbs`/`libmlx5` symbol versions
than Ubuntu's. The repo version comes from `<doca>/VERSION`
(e.g. `3.5.0098` → `3.5.0`). Override it with
`--build-arg DOCA_REPO_VERSION=x.y.z`, and the OS with
`--build-arg DOCA_REPO_DIST=ubuntu22.04`. **Build against the same DOCA
release the DPU runs.** The image records the build-time DOCA release in
`/etc/odos-doca-version`, and `verify_build.sh` warns on a mismatch.

The base image is `ubuntu:24.04`, which matches the BlueField OS for DOCA
3.x. Change it with `--build-arg BASE_IMAGE=...`.

## Build the image

The build runs on an arm64 machine, or on x86_64 through QEMU emulation
(`docker buildx` with `qemu-aarch64` binfmt, which `docker buildx ls` shows as
`linux/arm64`). The DPU itself usually has no Docker daemon. Under QEMU,
expect a few hours, mostly Open MPI. On an arm64 host it is much faster.

**DOCA installed on the build machine at `/opt/mellanox/doca`** (an arm64
build host with DOCA, or a DPU with Docker):

```bash
docker buildx build --platform linux/arm64 \
  --build-context doca=/opt/mellanox/doca \
  -f dpu_scripts/Dockerfile -t odos-mpi-dpu .
```

**Building on an x86_64 host:** its `/opt/mellanox/doca`, if any, is the
x86_64 SDK and will not work. Copy the aarch64 SDK from the target DPU, which
is about 270 MB:

```bash
mkdir -p ~/doca-arm64
ssh <dpu> 'tar -C /opt/mellanox/doca -cf - VERSION include lib' | tar -C ~/doca-arm64 -xf -
docker buildx build --platform linux/arm64 \
  --build-context doca=$HOME/doca-arm64 \
  -f dpu_scripts/Dockerfile -t odos-mpi-dpu .
```

The build steps (separate layers, so they can be rerun individually):

| Step | Script | What it does |
|------|--------|--------------|
| 1 | (Dockerfile) | DOCA's rdma-core from the arm64-dpu repo |
| 2 | `setup_dpu.sh ucx ompi-bf` | clones UCX and ompi-bf at their pinned commits (not the ODOS LLVM tree), applies `patches/`, lays out `build/` |
| 3 | `../compile_1_ucx.sh` | UCX |
| 4 | `../compile_3_ompi.sh` | Open MPI + ODOS pml/osc plugins |
| 5 | `setup_dpu.sh doca-omp-service` | clones and patches the service |
| 6 | `compile_5_service.sh` | `doca-omp-service` (ref and mpi), with clang + libomp |
| 7 | `verify_build.sh`, `install_dpu.sh` | checks the build, installs it into `/opt/odos-dpu` |
| 8 | runtime stage | runtime libraries + `/opt/odos-dpu` only; re-runs `verify_build.sh` |

Each step copies in only the scripts and patches it uses. Docker's cache
therefore reuses UCX and Open MPI, the slow part, unless their scripts or
`patches/ompi-bf` / `patches/odos_comch.h` change. A change to the service
patch or to a later script rebuilds only from that step onward.

`REQUIRE_DOCA=1` (the default) fails the build if any ODOS/DOCA component is
missing. `--build-arg REQUIRE_DOCA=0` accepts a stock-only build.

## Push

The image contains no DOCA SDK, so you can push it to a registry without
redistributing DOCA. Put the DOCA release in the tag:

```bash
docker login
docker tag odos-mpi-dpu <username>/odos-smartnic:odos-mpi-dpu-doca3.5
docker push <username>/odos-smartnic:odos-mpi-dpu-doca3.5
```

## Deploy on the DPU

BlueField runs DOCA services as **kubelet static pods** on containerd: any
pod manifest in `/etc/kubelet.d/` is started and kept running. You need root
on the DPU.

```bash
# edit `image:` in odos-dpu-service.yaml to the tag you pushed, then on the DPU:
sudo cp dpu_scripts/odos-dpu-service.yaml /etc/kubelet.d/
sudo crictl pods --name odos-dpu-service     # running?
sudo crictl logs $(sudo crictl ps -q --name odos-dpu-service)
sudo rm /etc/kubelet.d/odos-dpu-service.yaml   # stop
```

kubelet pulls the image itself. For a private registry, or a DPU that has no
access to one, load the image into containerd's `k8s.io` namespace first:

```bash
# on the build machine
docker save odos-mpi-dpu | gzip > odos-mpi-dpu.tar.gz
# on the DPU
sudo ctr -n k8s.io images import odos-mpi-dpu.tar.gz
```

The manifest ([odos-dpu-service.yaml](odos-dpu-service.yaml)) runs the pod
as root, privileged, on the host network, with the DPU's `/opt/mellanox/doca`
mounted read-only.

**The service must run as root on the DPU.** The Comch server listens on a
representor, and listing representors fails for an unprivileged user. As a
non-root user, DOCA reports every representor filter as unsupported. NVIDIA's
own `comch_ctrl_path_server` sample fails the same way. In that case the
service prints, once:

```
doca-omp-service: initialisation failed: no DOCA device usable as a Comch server with network representors (on the DPU this needs root); retrying every second
```

It then keeps retrying. Containers run as root by default, so the manifest and
the `docker run` line below meet this requirement.

With Docker on the DPU instead:

```bash
docker run --rm -it --privileged --network host \
  -v /opt/mellanox/doca:/opt/mellanox/doca:ro odos-mpi-dpu
```

### Configuring the service

The entrypoint, `odos-dpu-service` ([odos_dpu_service.sh](odos_dpu_service.sh)),
is configured through the environment (`env:` in the manifest):

| Variable | Values | Meaning |
|----------|--------|---------|
| `ODOS_SERVICE` | `ref` (default), `mpi` | which service binary to run |
| `ODOS_MPI_VARIANT` | `ref` (default), `pt2pt`, `one-sided` | Open MPI variant for `mpi`; must match the variant the host application runs with (see [apps/README.md](../apps/README.md#running)) |
| `ODOS_MPIRUN_ARGS` | e.g. `-np 2 -H dpu1,dpu2` | run `mpi` under `mpirun` across DPUs (needs ssh between the DPU containers); unset = one process |
| `ODOS_COMCH_REP_PCI` | PCI address | representor the service listens on; default the first non-uplink network representor |

Run `bash` instead of the service, e.g. to check the install:

```bash
docker run --rm -it --privileged -v /opt/mellanox/doca:/opt/mellanox/doca:ro \
  odos-mpi-dpu bash -c 'verify_build.sh $ODOS_PREFIX'
```

## Building without Docker, on the DPU

The same scripts work directly on a DPU. You need the build tools from the
Dockerfile's builder stage (`cmake`, `clang`, `libomp-dev`, `flex`, autotools
and so on). Run from the repo root:

```bash
sh dpu_scripts/setup_dpu.sh                  # clone + patch + build/ layout
sh dpu_scripts/compile_dpu.sh                # UCX, Open MPI + plugins, service
sh dpu_scripts/verify_build.sh ./build       # REQUIRE_DOCA=1 to fail on missing ODOS parts
sh dpu_scripts/install_dpu.sh ./build $HOME/odos-dpu   # optional runtime tree
```

`compile_dpu.sh` reads `DOCA_PATH` (default `/opt/mellanox/doca`), `CMAKE`
(default `cmake`) and `SERVICE_CC` (default `clang`, else `cc`). It refuses
to run on anything but aarch64, or against DOCA older than 3.3.

## What has been tested

All of the following was done on a BlueField-3 (Ubuntu 24.04, DOCA 3.5.0098,
rdma-core 2607), first as an unprivileged user:

- The image builds under QEMU. `verify_build.sh` passes in both stages with
  `REQUIRE_DOCA=1`.
- `/opt/odos-dpu` copied out of the image passes `verify_build.sh` on the DPU
  itself, against the DPU's own DOCA and rdma-core. Every component resolves
  all of its symbols.
- Both services start, find the two Comch-capable PFs (`mlx5_0`, `mlx5_1`) and
  open the device. They then stop at the representor, because the test was not
  run as root (see above). Under ASan/UBSan, the failure path reports cleanly,
  retries without leaking file descriptors, and exits on SIGTERM.

Then as root:

- The service listens (`[server] listening as omp_test0`). By default it
  uses the representor of the host PF, `0000:27:00.0` on the test host, so
  `ODOS_COMCH_REP_PCI` was not needed.
- A host ↔ DPU round trip passed using the [round-trip test](#round-trip-test),
  run from the BlueField's host in the host image. Over two sessions, buffers of 8 B to
  16 MB were submitted, retrieved and compared byte for byte. The service
  returned to listening after each disconnect. The service under test was an
  ASan/UBSan build, which reported no errors.

- The image was deployed as a kubelet static pod, imported with
  `ctr -n k8s.io images import` and started from
  [odos-dpu-service.yaml](odos-dpu-service.yaml). The round-trip test against
  the pod passed at about 1 GB/s for 16 MB buffers. `crictl logs` shows
  `[server] listening as omp_test0` at start and after each reconnect.
  Removing the manifest stops the pod in under a second: the launcher passes
  the kubelet's SIGTERM on to the service.

- ODOS OpenMP offload works end to end. The four tasks in
  [apps/simple_tasks](../apps/simple_tasks/README.md) ran from the host dev
  image against this image, deployed as a kubelet static pod and pulled from
  Docker Hub. The host had two BlueField-3 DPUs, so task d's TCP ping-pong ran
  between them.

**Not yet tested:** an ODOS MPI application across host and DPU.

## Round-trip test

[test/run_roundtrip.sh](test/run_roundtrip.sh) is a smoke test of the
host ↔ DPU link. It builds [test/rt_client.c](test/rt_client.c), which speaks
the service's own protocol over `patches/odos_comch.h`. The client connects to
the running service, then sends and retrieves buffers from 8 B to 16 MB and
compares every byte. It runs two sessions, so it also checks that the service
accepts a new host after one disconnects.

Start the service on the DPU (as root, see above). Then, on the x86_64 host of
that BlueField, from the repo root:

```bash
# host PF of the BlueField: lspci | grep BlueField  (e.g. 27:00.0)
sh dpu_scripts/test/run_roundtrip.sh 0000:27:00.0
```

The script needs a C compiler and the host's DOCA at `/opt/mellanox/doca`
(override with `DOCA_PATH`). Running it in the single-stage host image works
too; the two-stage image has no compiler:

```bash
docker run --rm --device=/dev/infiniband --ulimit memlock=-1 \
  -v /opt/mellanox/doca:/opt/mellanox/doca:ro -v "$PWD":/w -w /w \
  odos-mpi sh dpu_scripts/test/run_roundtrip.sh 0000:27:00.0
```

It ends with `OK: all round trips passed` (exit 0), or `FAIL` and a non-zero
exit.

## Verify a build

`verify_build.sh` is the DPU counterpart of the top-level `verify_build.sh`.
It accepts either a build tree (`./build`) or an installed tree
(`/opt/odos-dpu`) and detects which one it was given. A component passes only
if it exists and `ldd` resolves all of its libraries, including symbol
versions. The ODOS/DOCA components, i.e. the ODOS pml and osc plugins and both
services, must also resolve every symbol (`ldd -r`) and link
`libdoca_comch`, which shows they are the DOCA Comch port.

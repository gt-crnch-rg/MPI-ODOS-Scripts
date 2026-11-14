# ODOS Simple Tasks: OpenMP Offload to BlueField DPUs

These four tasks offload OpenMP `target` regions from an x86_64 host to its
BlueField DPU with ODOS. Both sides run in containers built by
[MPI-ODOS-Scripts](https://github.com/gt-crnch-rg/MPI-ODOS-Scripts) for
**DOCA 3.5 on BlueField-3**.

| Task | What runs on the DPU |
|---|---|
| a | a `puts` inside a `target` region |
| b | an OpenMP `parallel` region across the DPU's Arm cores |
| c | a call into a shared library built for the DPU |
| d | a TCP ping-pong between two DPUs |

The OSU Micro-Benchmarks and miniWeather are covered in
[apps/README.md](../README.md).

> **Status.** All four tasks build in the `odos-mpi-dev` image. They have been
> run against the containerized DPU service on a host with two BlueField-3
> DPUs (DOCA 3.5.0098). [Results](#results) shows that output.

# Table of Contents
1. [How it fits together](#how-it-fits-together)
2. [Setup](#setup)
3. [Compiling](#compiling)
4. [Running](#running)
5. [Testing](#testing)
6. [Results](#results)
7. [Old cluster scripts](#old-cluster-scripts)

# How it fits together

Each node pairs an x86_64 host with a BlueField DPU. Each side runs its own
container:

| | Host (x86_64) | DPU (BlueField, aarch64) |
|---|---|---|
| Image | `odos-mpi-dev`, built [below](#build-the-host-image) | `dfjrt321/odos-mpi:dpu-doca-3.5` |
| Runs | your program, compiled with ODOS clang | `odos-dpu-service`, which receives the program's `target` regions and runs them |
| DOCA | the host's `/opt/mellanox/doca`, mounted read-only | the DPU's `/opt/mellanox/doca`, mounted read-only |

Host and DPU talk over DOCA Comch. **Start the service on the DPU first, then
run the program on the host.** Output from code that runs on the DPU, such as
`puts` in a `target` region, appears in the **service's** log, not on the host.

The scripts in this folder all run on the host:

| Script | What it does |
|---|---|
| `docker_compile.sh` | builds tasks a–d into `out/tasks/`, in the host container |
| `dpu_service.sh <dpu> start\|status\|logs\|stop` | runs the ODOS service on a DPU, over ssh |
| `docker_run_task.sh <binary> [args]` | runs a task on the host side, in the host container |
| `docker_host.sh [command]` | a shell, or any command, in the host container |
| `docker_test.sh <dpu> ...` | builds and runs all tasks and checks the DPU output |
| `docker_env.sh` | settings for the scripts above: image names, DOCA path, RDMA devices |

# Setup

## Requirements

- A node with an x86_64 host and a BlueField-3 DPU, both with **DOCA 3.5**
  installed at `/opt/mellanox/doca`. The images were built against DOCA
  3.5.0098; use the same release.
- Docker on the host.
- ssh from the host to the DPU, and sudo on the DPU. The service has to run as
  root.
- For task d, a second DPU: either in a second node, or a second BlueField in
  the same host.

For the SC26 tutorial, the testbed login instructions are linked from the
[tutorial README](https://github.com/gt-crnch-rg/smartnic-tutorial-sc26#hands-on-examples).

## Get the code

```bash
git clone https://github.com/gt-crnch-rg/MPI-ODOS-Scripts.git
cd MPI-ODOS-Scripts
```

The simple tasks do not need the `apps/` submodules.

## Build the host image

The published host image `dfjrt321/odos-mpi:host-doca-3.5` is the slim
two-stage build. It can run binaries that are already compiled, but it has no
C library headers or build tools, so it **cannot compile** these tasks. Build
the full image instead, then add the DPU cross-compiler on top of it. Run both
steps from the root of MPI-ODOS-Scripts.

**1. `odos-mpi`**, the full host image. Build it once per DOCA release. The
build needs about 50 GB of disk and 16 GB of RAM. The LLVM step takes 30–90
minutes; it took 17 minutes on a 192-core machine. See [DOCKER.md](../../DOCKER.md)
for details.

```bash
docker buildx build --build-context doca=/opt/mellanox/doca -t odos-mpi .
```

**2. `odos-mpi-dev`** adds the aarch64 cross toolchain, which ODOS clang uses
to link the DPU half of every offload binary. It also adds the Open MPI
variants the MPI apps in `apps/` use; the simple tasks do not need those.

```bash
docker build -t odos-mpi-dev - <<'EOF'
FROM odos-mpi
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
    && rm -rf /var/lib/apt/lists/*
# Open MPI variants for the MPI apps: /opt/ompi/ref = stock pml + osc,
# pt2pt = ODOS pml, one-sided = ODOS osc
RUN set -e; src=/opt/odos-mpi/build/ompi/x86_64/install; \
    for v in "ref orig orig" "pt2pt odos orig" "one-sided orig odos"; do \
        set -- $v; d=/opt/ompi/$1; mkdir -p /opt/ompi; cp -a $src $d; \
        cp $d/lib/openmpi/$2.mca_pml_ucx.so $d/lib/openmpi/mca_pml_ucx.so; \
        cp $d/lib/openmpi/$3.mca_osc_ucx.so $d/lib/openmpi/mca_osc_ucx.so; \
    done
ENV OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
EOF
```

If you name the image differently, or your DOCA is not in
`/opt/mellanox/doca`, set `HOST_IMAGE` or `DOCA_PATH` in the environment or in
`docker_env.sh`.

## The host container

`./docker_host.sh` opens a shell in the host container, and
`./docker_host.sh <command>` runs one command there. The other `docker_*.sh`
scripts go through it. It runs:

```bash
docker run --rm -it --network host --user "$(id -u):$(id -g)" \
  --device=/dev/infiniband --ulimit memlock=-1 \
  -v /opt/mellanox/doca:/opt/mellanox/doca:ro \
  -v "$PWD":/work -w /work \
  odos-mpi-dev
```

This folder is mounted at `/work`. `--user` runs the container as you, so the
files the build writes into this folder are not owned by root. Without a DOCA
install, `docker_host.sh` warns and leaves out the DOCA mount: compiling still
works, but running against the DPU does not. To check that the image sees
DOCA and all ODOS components, run the image's `verify_build.sh` as root. The
repo scripts in the image may be readable only by root.

```bash
docker run --rm -v /opt/mellanox/doca:/opt/mellanox/doca:ro odos-mpi-dev \
  bash -c 'cd /opt/odos-mpi && REQUIRE_DOCA=1 sh verify_build.sh ./build'
```

## Start the DPU service

From the host:

```bash
./dpu_service.sh <dpu> start     # waits until the service is listening
./dpu_service.sh <dpu> status    # pod state and the last lines of output
./dpu_service.sh <dpu> logs      # follow the output (Ctrl-C to quit)
./dpu_service.sh <dpu> stop      # remove the service and task c's library
```

`<dpu>` is any name or address ssh accepts. The script runs the service the
standard BlueField way: as a kubelet static pod, from
`dfjrt321/odos-mpi:dpu-doca-3.5`, in the service's default `ref` mode, which
the tasks need. `start` needs sudo on the DPU. In a terminal sudo can ask for a
password; when another script calls it, sudo must be passwordless. The first
`start` on a DPU pulls the image. `start` is safe to run again: it also copies
task c's library (see [Running Tasks](#running-tasks)).

The service is ready when it prints `[server] listening as omp_test0`. After a
program disconnects, the service goes back to listening, so several runs can
share one service.

**By hand.** Without ssh from the host, start the service on the DPU itself,
as root. With the pod manifest
[`dpu_scripts/odos-dpu-service.yaml`](../../dpu_scripts/odos-dpu-service.yaml):

```bash
sed -i 's|image: .*|image: docker.io/dfjrt321/odos-mpi:dpu-doca-3.5|' odos-dpu-service.yaml
cp odos-dpu-service.yaml /etc/kubelet.d/                  # start
crictl logs -f $(crictl ps -q --name odos-dpu-service)    # service output
rm /etc/kubelet.d/odos-dpu-service.yaml                   # stop
```

Or with Docker on the DPU, if it is installed there:

```bash
docker run --rm -it --privileged --network host \
  -v /opt/mellanox/doca:/opt/mellanox/doca:ro \
  dfjrt321/odos-mpi:dpu-doca-3.5
```

For task c, the service also needs the task's library; see
[Running Tasks](#running-tasks). The service listens on the first non-uplink
network representor. To pick another, set `ODOS_COMCH_REP_PCI` to its PCI
address; that is rarely needed. More detail is in
[DPU_README.md](../../dpu_scripts/DPU_README.md).

# Compiling

```bash
./docker_compile.sh
```

This leaves `a_hello`, `b_omp_parallel`, `c_shared`, `d_net_accel`,
`liblog_x86.so` and `liblog_aarch64.so` in `out/tasks/`. In the host
container, it runs:

```bash
CLANG_PATH=/opt/odos-mpi/build/odos/install
mkdir -p out/tasks
(cd task_a/build && cmake .. -DCLANG_PATH=$CLANG_PATH && make && cp hello        ../../out/tasks/a_hello)
(cd task_b/build && cmake .. -DCLANG_PATH=$CLANG_PATH && make && cp omp_parallel ../../out/tasks/b_omp_parallel)
(cd task_c && sh compile.sh $CLANG_PATH && cp build/liblog_*.so ../out/tasks/ && cp build/shared ../out/tasks/c_shared)
(cd task_d/build && cmake .. -DCLANG_PATH=$CLANG_PATH && make && cp net_accel    ../../out/tasks/d_net_accel)
```

`sh clean.sh` removes the build output.

# Running

`docker_run_task.sh` runs a task's host side in the host container, with
`out/tasks` on the library path. Start the DPU service first. If the service
is not up yet, the host keeps retrying the connection for 30 seconds and then
fails. Set `ODOS_COMCH_CONNECT_TIMEOUT=-1` to make it wait indefinitely.

## Running Tasks

```bash
./dpu_service.sh <dpu> start
./docker_run_task.sh out/tasks/a_hello          # service prints: Hi Folks!
./docker_run_task.sh out/tasks/b_omp_parallel   # service prints one line per DPU OpenMP thread
./docker_run_task.sh out/tasks/c_shared         # service prints: Hello from the other side ...
```

Watch the output with `./dpu_service.sh <dpu> logs` in a second terminal.

**Task c** calls into a shared library, `liblog_aarch64.so`, from the DPU.
`dpu_service.sh start` copies it to `/tmp/odos-tasks` on the DPU and puts that
directory on the service's library path. Run `start` after compiling, and
again whenever you rebuild task c; the service does not need a restart.

If you start the service by hand, copy the library yourself and add the
directory to the service. For Docker, add
`-v /tmp/odos-tasks:/tasks:ro -e LD_LIBRARY_PATH=/tasks`. For the pod, add
these entries to the manifest's existing `env:`, `volumeMounts:` and
`volumes:` lists:

```yaml
      env:
        - name: LD_LIBRARY_PATH
          value: /tasks
      volumeMounts:
        - name: tasks
          mountPath: /tasks
          readOnly: true
  volumes:
    - name: tasks
      hostPath:
        path: /tmp/odos-tasks
        type: Directory
```

**Task d** opens a TCP connection between two DPUs and plays ping-pong over
it. It needs two DPUs, each running the service. They can be on two nodes, or
both in one host that has two BlueFields. The service uses the DPU's host
network, so the server listens on the DPU's own interfaces, on TCP port 3310.
The client needs an address of the server DPU that the client DPU can reach,
such as its out-of-band address:
`ssh <server dpu> ip -4 -br addr show oob_net0`.

Start the server first. On two nodes, run one command on each host:

```bash
# node A, the server
./docker_run_task.sh out/tasks/d_net_accel
# node B, the client: give the IP address of node A's DPU
./docker_run_task.sh out/tasks/d_net_accel c <server DPU IP>
```

Each DPU's service log shows its side of the ping-pong (see
[Results](#task-d)). If the client cannot connect, its service logs
`failed to connect socket ... Connection refused` and `init failed.`, then
keeps running. Start the server and run the client again.

*One host with two BlueFields.* The ODOS host plugin always offloads to the
first BlueField it finds and ignores the OpenMP device number, so
`OMP_DEFAULT_DEVICE` does not help. Instead, set `ODOS_UVERBS` to one card's
RDMA devices, and the host container sees only that card.
`ls -l /sys/class/infiniband_verbs/` shows which `uverbsN` belongs to which
PCI address. To find which DPU a set of devices reaches, run task a with only
those devices and check which DPU's service prints `Hi Folks!`. Say
`uverbs0`/`uverbs1` reach `<dpu-1>` and `uverbs2`/`uverbs3` reach `<dpu-2>`:

```bash
./dpu_service.sh <dpu-1> start
./dpu_service.sh <dpu-2> start
# server on <dpu-1>, in one terminal
ODOS_UVERBS="uverbs0 uverbs1" ./docker_run_task.sh out/tasks/d_net_accel
# client on <dpu-2>, in a second terminal
ODOS_UVERBS="uverbs2 uverbs3" ./docker_run_task.sh out/tasks/d_net_accel c <dpu-1 IP>
```

Look in the task folders for more on what each task demonstrates.

# Testing

`docker_test.sh` builds the tasks and starts the service. It then runs each
task and checks the DPU's service log for the task's output: each task's
`puts` text, and the last ping-pong line for task d. The service is left
running.

```bash
./docker_test.sh <dpu>                         # tasks a-c
UVERBS_A="uverbs0 uverbs1" UVERBS_B="uverbs2 uverbs3" \
    ./docker_test.sh <dpu-1> <dpu-2> <dpu-1 IP>   # and task d
```

Task d is tested only on a host with two BlueFields, because the script runs
both sides from one host. The script reads the service logs over ssh, so it
needs passwordless sudo on the DPUs. It ends with `ALL PASSED`, or lists each
`FAIL`.

# Results

Service logs from a host with two BlueField-3 DPUs (DOCA 3.5.0098). The host
programs print only the `cmd : ...` line from
`docker_run_task.sh`, and exit 0. After each run the service also prints
`[server] listening as omp_test0` again.

## Task a
```
Hi Folks!
```

## Task b
```
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
Hey! OpenMP also works on the DPU...
```

## Task c
```
Hello from the other side (from a shared object..)
```

## Task d
### Server DPU
```
connection established.
to   client > 01
to   client > 03
to   client > 05
to   client > 07
to   client > 09
to   client > 11
to   client > 13
to   client > 15
to   client > 17
to   client > 19
```
### Client DPU
```
connection established.
to   server > 00
to   server > 02
to   server > 04
to   server > 06
to   server > 08
to   server > 10
to   server > 12
to   server > 14
to   server > 16
to   server > 18
```

# Old cluster scripts

`compile.sh` and `run_task.sh` are left over from the SLURM workflow on the
original DOCA 2.0.2 cluster. They source `env.sh`, which has been removed
along with that workflow's `run_service.sh`, so they **no longer run**. The
last line of `clean.sh`, which deletes SLURM output files, is left over too and
fails harmlessly.

| Old script | Container version |
|---|---|
| `compile.sh` | `docker_compile.sh` |
| `run_service.sh` (removed) | `dpu_service.sh <dpu> start` |
| `run_task.sh` | `docker_run_task.sh` |

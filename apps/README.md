Please refer to the [openmp-offload-dpu.pdf](./openmp-offload-dpu.pdf) handout for more details.

These apps run ODOS-MPI in the containers: the host image from
[DOCKER.md](../DOCKER.md) and the DPU image from
[DPU_README.md](../dpu_scripts/DPU_README.md). The OpenMP-only examples are in
[simple_tasks](simple_tasks/README.md), whose README also covers building the
`odos-mpi-dev` host image and running the DPU service.

> **Status.** The OSU benchmarks and miniWeather compile in the `odos-mpi-dev`
> image with the steps below. They have **not** yet been run across nodes in
> the containers (see [Launching across nodes](#launching-across-nodes)). The
> example output in [Results](#results) was recorded on the original DOCA 2.0
> cluster.

# Table of Contents
1. [Setup](#setup)
2. [Compiling](#compiling)
3. [Running](#running)
4. [Results](#results)

# Setup

The OSU benchmarks and miniWeather are git submodules:

```bash
git submodule update --init omb-odos miniweather
```

Build the `odos-mpi-dev` host image as described in
[simple_tasks/README.md](simple_tasks/README.md#build-the-host-image). Then
start a host container from `apps/`:

```bash
docker run --rm -it --network host --user "$(id -u):$(id -g)" \
  --device=/dev/infiniband --ulimit memlock=-1 \
  -v /opt/mellanox/doca:/opt/mellanox/doca:ro \
  -v "$PWD":/work -w /work \
  odos-mpi-dev
```

# Compiling

Run this in the host container. The compile scripts set `BLUEFIELD_SYSROOT`
and `BLUEFIELD_GCC_TOOLCHAIN` to paths on the old cluster, and the DPU-side
link fails with those set. So the first line deletes those lines, and ODOS
clang uses the image's cross toolchain instead. This edits the submodules'
working trees; `git submodule foreach git checkout .` undoes it.

```bash
sed -i '/BLUEFIELD_/d' omb-odos/mpi_odos/*/compile*.sh miniweather/odos/compile_omp.sh

CLANG_PATH=/opt/odos-mpi/build/odos/install
MPI_PATH=/opt/ompi/ref
PNETCDF_PATH=/opt/odos-mpi/build/pnetcdf/install
export OPAL_PREFIX=$MPI_PATH

(cd omb-odos/mpi_odos/pt2pt      && . ./compile.sh $CLANG_PATH $MPI_PATH && mv b* l* m* ../../../out/omb/pt2pt/)
(cd omb-odos/mpi_odos/one-sided  && . ./compile.sh $CLANG_PATH $MPI_PATH && mv a* f* cas* g* p* ../../../out/omb/one-sided/)
(cd omb-odos/mpi_odos/collective && . ./compile.sh $CLANG_PATH $MPI_PATH && mv a* s* r* i* g* ../../../out/omb/collective/)
(cd miniweather/odos && . ./compile_omp.sh $CLANG_PATH $MPI_PATH $PNETCDF_PATH \
    && mv miniWeather_mpi_omp miniWeather_mpi_odos_omp ../../out/miniweather/)
```

The binaries land in `out/omb/{pt2pt,one-sided,collective}/` and
`out/miniweather/`. The tables under [Running](#running) list them.

# Running

Every run has two parts, and their Open MPI variants must match:

- **DPU:** the ODOS service in `mpi` mode, running as one MPI job across the
  DPUs. Start it from the pod manifest
  [`dpu_scripts/odos-dpu-service.yaml`](../dpu_scripts/odos-dpu-service.yaml),
  setting `ODOS_SERVICE=mpi`, `ODOS_MPI_VARIANT` and `ODOS_MPIRUN_ARGS` under
  `env:`. [DPU_README.md](../dpu_scripts/DPU_README.md#configuring-the-service)
  describes these settings.
- **Host:** the program, as one MPI job across the hosts, launched with the
  matching Open MPI in `/opt/ompi/<variant>` of the host container. Define:

```bash
odos_mpirun() {   # odos_mpirun <ref|pt2pt|one-sided> <mpirun arguments...>
    local MPI=/opt/ompi/$1; shift
    OPAL_PREFIX=$MPI $MPI/bin/mpirun -x OPAL_PREFIX=$MPI \
        -x LD_LIBRARY_PATH=$MPI/lib:$LD_LIBRARY_PATH "$@"
}
```

Start the DPU service first, and wait until it is listening.

## Launching across nodes

`mpirun` starts ranks on the other nodes over ssh and expects the same install
paths there. Neither image runs an ssh server, so an `mpirun` inside one
container cannot yet start ranks in the containers on other nodes. This is
true for the host side and for `ODOS_MPIRUN_ARGS` on the DPU side. Until there
is a way to do that, such as an ssh server in the containers, the commands
below show the settings each run needs but cannot be launched across nodes.

## Running OSU Microbenchmarks

### Point-to-Point

DPU: `ODOS_SERVICE=mpi`, `ODOS_MPI_VARIANT=pt2pt`,
`ODOS_MPIRUN_ARGS="-np 2 -H <dpu1>,<dpu2>"`

```bash
odos_mpirun pt2pt -np 2 -H <host1>,<host2> out/omb/pt2pt/bw_h2d
```
Further point-to-point communication binaries are present in `out/omb/pt2pt/`. All these binaries are enlisted in the following table.

| Metric Name               | host-to-device   | device-to-host   | device-to-device | host-to-host     |
|---------------------------|------------------|------------------|------------------|------------------|
| Bidirectional Bandwidth   | bibw_h2d         | bibw_d2h         | bibw_d2d         | bibw_h2h         |
| Bandwidth                 | bw_h2d           | bw_d2h           | bw_d2d           | bw_h2h           |
| Latency                   | latency_h2d      | latency_d2h      | latency_d2d      | latency_h2h      |
| Multi-threaded Latency    | latency_mt_h2d   | latency_mt_d2h   | latency_mt_d2d   | latency_mt_h2h   |
| Max Bandwidth (MR)        | mbw_mr_h2d       | mbw_mr_d2h       | mbw_mr_d2d       | mbw_mr_h2h       |
| Multi-Process Latency     | multi_lat_h2d    | multi_lat_d2h    | multi_lat_d2d    | multi_lat_h2h    |

### Remote Memory Access / One-Sided Communication

DPU: `ODOS_SERVICE=mpi`, `ODOS_MPI_VARIANT=one-sided`,
`ODOS_MPIRUN_ARGS="-np 2 -H <dpu1>,<dpu2>"`

```bash
odos_mpirun one-sided -np 2 -H <host1>,<host2> out/omb/one-sided/get_bw_h2d
```
Further one-sided communication binaries are present in `out/omb/one-sided/`. All these binaries are enlisted in the following table.

| Metric Name               | host-to-device   | device-to-host   | device-to-device | host-to-host     |
|----------------------------|------------------------|------------------------|------------------------|------------------------|
| Accumulate Latency         | acc_latency_h2d        | acc_latency_d2h        | acc_latency_d2d        | acc_latency_h2h        |
| Compare-And-Swap Latency   | cas_latency_h2d        | cas_latency_d2h        | cas_latency_d2d        | cas_latency_h2h        |
| Fetch-and-Op Latency       | fop_latency_h2d        | fop_latency_d2h        | fop_latency_d2d        | fop_latency_h2h        |
| Get Accumulate Latency     | get_acc_latency_h2d    | get_acc_latency_d2h    | get_acc_latency_d2d    | get_acc_latency_h2h    |
| Get Bandwidth              | get_bw_h2d             | get_bw_d2h             | get_bw_d2d             | get_bw_h2h             |
| Get Latency                | get_latency_h2d        | get_latency_d2h        | get_latency_d2d        | get_latency_h2h        |
| Put Bidirectional Bandwidth| put_bibw_h2d           | put_bibw_d2h           | put_bibw_d2d           | put_bibw_h2h           |
| Put Bandwidth              | put_bw_h2d             | put_bw_d2h             | put_bw_d2d             | put_bw_h2h             |
| Put Latency                | put_latency_h2d        | put_latency_d2h        | put_latency_d2d        | put_latency_h2h        |

### Collective

DPU: `ODOS_SERVICE=mpi`, `ODOS_MPI_VARIANT=ref`,
`ODOS_MPIRUN_ARGS="-np 4 -H <dpu1>,<dpu2>,<dpu3>,<dpu4>"`

```bash
odos_mpirun ref -np 4 -H <host1>,<host2>,<host3>,<host4> out/omb/collective/ialltoall
```

Further collective communication binaries are present in `out/omb/collective/`. All these binaries are enlisted in the following table.

| Collective Operation      | Blocking         | Non-Blocking       |
|---------------------------|------------------|--------------------|
| Allgather                 | allgather        | iallgather         |
| Allgatherv                | allgatherv       | -                  |
| Allreduce                 | allreduce        | -                  |
| Alltoall                  | alltoall         | ialltoall          |
| Alltoallv                 | alltoallv        | ialltoallv         |
| Alltoallw                 | -                | ialltoallw         |
| Barrier                   | -                | ibarrier           |
| Broadcast                 | -                | ibcast             |
| Gather                    | gather           | igather            |
| Gatherv                   | -                | igatherv           |
| Scatter                   | scatter          | iscatter           |
| Scatterv                  | scatterv         | iscatterv          |
| Reduce                    | reduce           | -                  |
| Reduce-Scatter            | reduce_scatter   | -                  |

## Running miniWeather

DPU: `ODOS_SERVICE=mpi`, `ODOS_MPI_VARIANT=ref`,
`ODOS_MPIRUN_ARGS="-np 4 -H <dpu1>,<dpu2>,<dpu3>,<dpu4>"`. Set
`OMP_NUM_THREADS` to the number of OpenMP threads per host rank. The runs
under [Results](#results) used 55.

### Reference Run
```bash
odos_mpirun ref -np 4 -H <host1>,<host2>,<host3>,<host4> -x OMP_NUM_THREADS=55 \
    out/miniweather/miniWeather_mpi_omp
```
### ODOS Accelerated Run
```bash
odos_mpirun ref -np 4 -H <host1>,<host2>,<host3>,<host4> -x OMP_NUM_THREADS=55 \
    out/miniweather/miniWeather_mpi_odos_omp 0.325
```
The number `0.325` in command represents the ratio of region whose compute is offloaded to the DPU. 32.5% in DPU and 67.5% in host. We can change this number to offload more or less region to SmartNIC.

# Results

This output was recorded on the original DOCA 2.0.2 cluster with its SLURM
scripts, which have since been removed. The containers print a few lines
differently:

- The `cmd : ...` lines came from the SLURM task scripts.
- The ported DPU service prints `[server] listening as omp_test0` where these
  logs show `[server] server name: omp_test`.
- The ported MPI plugins no longer print `going to connect....`.

## OSU Mircobenchmark Run
### Point-to-Point Communication
#### Task Output
```
cmd : out/omb/pt2pt/bw_h2d
going to connect....
connected [OMPI_PML]
going to connect....
connected [OMPI_PML]
# OSU MPI ODOS-H2D Bandwidth Test
# Size        Bandwidth (MB/s)
1                         2.09
2                         4.41
4                         8.64
8                        16.95
16                       35.03
32                       69.85
64                      132.98
128                     275.50
256                     519.90
512                     995.54
1024                   1992.96
2048                   4075.89
4096                   5828.46
8192                   8802.57
16384                 17287.07
32768                 19598.01
65536                 20720.76
131072                21563.68
262144                21305.41
524288                22132.76
1048576               22106.51
2097152               22267.81
4194304               22559.20
```
#### Service Output
```
dpu is listening... [OMPI_PML]
dpu is listening... [OMPI_PML]
[server] server name: omp_test
[server] server name: omp_test
```

### Remote Memory Access / One-Sided Communication
#### Task Output
```
cmd : out/omb/one-sided/get_bw_h2d
# OSU MPI_Get Bandwidth Test
# Window creation: MPI_Win_create
# Synchronization: MPI_Win_lock/unlock
# Size        Bandwidth (MB/s)
going to connect....
connected [OMPI_OSC]
going to connect....
connected [OMPI_OSC]
1                         1.62
2                         3.25
4                         6.52
8                        12.85
16                       26.00
32                       51.91
64                      102.05
128                     190.62
256                     376.15
512                     809.28
1024                   1947.21
2048                   3852.83
4096                   7467.16
8192                  12606.91
16384                 16783.95
32768                 20132.50
65536                 22220.69
131072                23538.41
262144                24095.57
524288                24404.54
1048576               24532.79
2097152               24600.13
4194304               24643.03
```
#### Service Output
```
[server] server name: omp_test
[server] server name: omp_test
dpu is listening... [OMPI_OSC]
dpu is listening... [OMPI_OSC]
```
### Collectives
#### Task Output
```
cmd : out/omb/collective/ialltoall

# OSU MPI Non-blocking All-to-All Latency Test
# Overall = Coll. Init + Compute + MPI_Test + MPI_Wait

# Size             Overall(us)         Compute(us)      Pure Comm.(us)          Overlap(%)
1                        66.88               64.32               61.70               95.85
2                        48.40               45.69               43.38               93.75
4                        48.34               45.69               43.34               93.89
8                        48.90               45.61               43.25               92.40
16                       48.24               45.61               43.20               93.91
32                       48.79               46.19               43.56               94.04
64                       48.92               46.22               43.71               93.82
128                      48.89               46.17               43.65               93.78
256                      49.24               46.45               44.58               93.73
512                      49.92               47.12               44.94               93.77
1024                     50.60               47.69               45.47               93.60
2048                     51.78               48.80               46.08               93.55
4096                     51.77               49.02               47.48               94.21
8192                     57.04               54.33               51.76               94.77
16384                    59.81               56.93               54.59               94.72
32768                    65.07               61.70               58.93               94.28
65536                    75.57               72.10               69.67               95.02
131072                   95.74               92.70               90.18               96.62
262144                  127.14              123.68              120.62               97.13
524288                  186.42              182.57              178.33               97.84
1048576                 302.82              298.75              292.44               98.61
2097152                 549.93              540.72              530.57               98.26
4194304                1060.45             1048.20             1029.94               98.81
```
#### Service Output
```
[server] server name: omp_test
[server] server name: omp_test
[server] server name: omp_test
[server] server name: omp_test
```

## miniWeather
### Refernce
#### Task Output
```
cmd : out/miniweather/miniWeather_mpi_omp
----------------------------------------
nx_glob, nz_glob:  4096  2048
nx,nz           :  1024  2048
dt              : 0.01628
----------------------------------------
>> time: 32.747 seconds
----------------------------------------
Profile
-------
  halo x mpi  :      0.201 seconds
  halo x omp  :      0.000 seconds
  tend x      :      9.286 seconds
    launch        :      0.000 seconds
    host          :      9.285 seconds
    wait          :      0.000 seconds
  halo tend z :      9.306 seconds
    launch        :      0.000 seconds
    host          :      9.306 seconds
    wait          :      0.000 seconds
  compute     :     13.955 seconds
    launch        :      0.000 seconds
    host          :     13.954 seconds
    wait          :      0.000 seconds
----------------------------------------
```
#### Service Output
```
[server] server name: omp_test
[server] server name: omp_test
[server] server name: omp_test
[server] server name: omp_test
```
### ODOS Accelerated
#### Task Output
```
cmd : out/miniweather/miniWeather_mpi_odos_omp 0.325
----------------------------------------
nx_glob, nz_glob:  4096  2048
nx,nz           :  1024  2048
nxh,nxd         :   691   332 [166,166]
dx,dz           : 4.883 4.883
dt              : 0.01628
----------------------------------------
ratio      :  0.32500
state      :  1028 [ 1024+2*2] x  2052 [ 2048+2*2] x 4
state host :   695 [  691+2*2] x  2052 [ 2048+2*2] x 4
state  dpu :   170 [  166+2*2] x  2052 [ 2048+2*2] x 4 x 2
----------------------------------------
>> time: 24.068 seconds
----------------------------------------
Profile
-------
  halo x mpi  :      0.528 seconds
  halo x omp  :      0.367 seconds
  tend x      :      6.653 seconds
    launch        :      0.001 seconds
    host          :      6.476 seconds
    wait          :      0.175 seconds
  halo tend z :      7.140 seconds
    launch        :      0.019 seconds
    host          :      6.701 seconds
    wait          :      0.420 seconds
  compute     :      9.379 seconds
    launch        :      0.042 seconds
    host          :      9.333 seconds
    wait          :      0.004 seconds
----------------------------------------
```
#### Service Output
```
[server] server name: omp_test
[server] server name: omp_test
[server] server name: omp_test
[server] server name: omp_test
```

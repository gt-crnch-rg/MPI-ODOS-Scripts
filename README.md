# ODOS-MPI Scripts

Scripts to setup and run ODOS-MPI framework and applications for SC25 paper.

## Setup

Clone and setup build directory

```
. setup.sh
```

## Compile

Compile UCX, ODOS, ODOS-MPI, OSU Microbenchmarks, Parallel NetCDF and MiniWeather

```
. compile.sh
```

Wait for commands to complete. Check if done in `squeue`.

## Docker (DOCA 3.3+)

- Host (x86_64): see [DOCKER.md](DOCKER.md).
- DPU (BlueField, aarch64): see [dpu_scripts/DPU_README.md](dpu_scripts/DPU_README.md).

## Prepare Package

```
. prepare_pkg.sh
```

## Run Applications

Refer to `README.md` in `apps` to run applications


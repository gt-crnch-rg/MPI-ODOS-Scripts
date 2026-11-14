# Task c: A shared library on the DPU

[`shared.c`](shared.c) calls `printify()` inside `#pragma omp target`.
`printify()` lives in a shared library, [`log.c`](log.c), built twice:
`liblog_x86.so` for the host and `liblog_aarch64.so` for the DPU. The program
links the DPU half against `liblog_aarch64.so` (`-Wl,--device-linker=...`), so
the call runs on the DPU and loads the library there.

## Compilation

[`compile.sh`](compile.sh) builds both libraries and the program into
`build/`:

```bash
sh compile.sh <ODOS clang install>
```

`./docker_compile.sh` runs it in the host container with
`/opt/odos-mpi/build/odos/install` and copies the results to `out/tasks/`.

## Run

From `apps/simple_tasks`, after `./docker_compile.sh` (see the
[README](../README.md)):

```bash
./dpu_service.sh <dpu> start
./docker_run_task.sh out/tasks/c_shared
```

`dpu_service.sh start` copies `liblog_aarch64.so` to the DPU and puts it on the
service's library path. Run `start` again after rebuilding the library.
`docker_run_task.sh` puts `out/tasks` on the host's library path for
`liblog_x86.so`.

## Output

Host:
```
cmd : out/tasks/c_shared
```

DPU service (`./dpu_service.sh <dpu> logs`):
```
Hello from the other side (from a shared object..)
```

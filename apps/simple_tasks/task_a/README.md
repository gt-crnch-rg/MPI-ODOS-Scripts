# Task a: Hello from the DPU

[`hello.c`](hello.c) puts a single `puts` inside `#pragma omp target`. ODOS
ships that region to the DPU, so the text is printed by the ODOS service on
the DPU, not by the host program.

## Run

From `apps/simple_tasks`, after `./docker_compile.sh` (see the
[README](../README.md)):

```bash
./dpu_service.sh <dpu> start
./docker_run_task.sh out/tasks/a_hello
```

## Output

Host:
```
cmd : out/tasks/a_hello
```

DPU service (`./dpu_service.sh <dpu> logs`):
```
Hi Folks!
```

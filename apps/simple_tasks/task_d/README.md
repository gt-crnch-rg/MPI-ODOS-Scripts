# Task d: Networking from the DPU

[`net_accel.c`](net_accel.c) opens a TCP connection inside
`#pragma omp target`, so the socket lives on the DPU, not on the host. With no
arguments it is the server: it listens on port 3310 on the DPU. With
`c <IP>` it is the client and connects to that address. The two sides then
play ten rounds of ping-pong with a counter.

The target region runs inside the long-running ODOS service. So it reports
errors with `warn()` instead of `err()`, which would `exit()` the service, and
closes every socket it opens.

## Run

This needs two DPUs, each running the service: on two nodes, or two
BlueFields in one host. From `apps/simple_tasks`, after `./docker_compile.sh`
(see the [README](../README.md)):

```bash
./dpu_service.sh <server dpu> start
./dpu_service.sh <client dpu> start
# on the server DPU's host: start this first
./docker_run_task.sh out/tasks/d_net_accel
# on the client DPU's host: an address of the server DPU the client DPU can reach
./docker_run_task.sh out/tasks/d_net_accel c <server DPU IP>
```

The DPU's out-of-band address works:
`ssh <server dpu> ip -4 -br addr show oob_net0`. For two BlueFields in one
host, choose each side's card with `ODOS_UVERBS`; the
[README](../README.md#running-tasks) explains how.

## Output

Server DPU service:
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

Client DPU service:
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

If the client cannot connect, its service logs
`failed to connect socket ... Connection refused` and `init failed.`, and keeps
running. Start the server, then run the client again.

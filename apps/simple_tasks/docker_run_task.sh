#!/bin/bash
#
# Runs a task binary on the host side, in the ODOS host container -- the
# container version of run_task.sh. out/tasks is on the library path, which
# task c needs for liblog_x86.so. The DPU service must already be running
# (dpu_service.sh); what the task prints on the DPU shows up in its log.
#
#   ./docker_run_task.sh out/tasks/a_hello
#   ./docker_run_task.sh out/tasks/d_net_accel c <server DPU IP>
#
# On a host with two BlueFields, ODOS_UVERBS picks the DPU, e.g.
#   ODOS_UVERBS="uverbs2 uverbs3" ./docker_run_task.sh out/tasks/a_hello

HERE=$(cd "$(dirname "$0")" && pwd)

if [ $# -lt 1 ]; then
	echo "usage: $0 <task binary> [arguments...]" >&2
	exit 2
fi

echo "cmd : $*"
exec "$HERE/docker_host.sh" bash -c \
	'LD_LIBRARY_PATH=/work/out/tasks:$LD_LIBRARY_PATH exec "$@"' task "$@"

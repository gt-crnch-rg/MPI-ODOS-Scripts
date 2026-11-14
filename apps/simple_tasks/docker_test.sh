#!/bin/bash
#
# Builds tasks a-d, starts the ODOS service, runs the tasks, and checks each
# DPU's service log for the task's output. Leaves the service running; stop it
# with ./dpu_service.sh <dpu> stop.
#
#   ./docker_test.sh <dpu-a>                      # tasks a-c on dpu-a
#   ./docker_test.sh <dpu-a> <dpu-b> <dpu-a IP>   # and task d: server on dpu-a,
#                                                 # client on dpu-b
#
# Task d runs both sides from this host, so it needs a host with two
# BlueFields. Set UVERBS_A and UVERBS_B to each card's RDMA devices (see the
# README), e.g.
#   UVERBS_A="uverbs0 uverbs1" UVERBS_B="uverbs2 uverbs3" \
#       ./docker_test.sh <dpu-a> <dpu-b> <dpu-a IP>
#
# Needs ssh and passwordless sudo on the DPUs: it reads the service logs.

HERE=$(cd "$(dirname "$0")" && pwd)
DPU_A=$1 DPU_B=$2 DPU_A_IP=$3
POD=odos-dpu-service
export ODOS_COMCH_CONNECT_TIMEOUT=${ODOS_COMCH_CONNECT_TIMEOUT:-20}

if [ -z "$DPU_A" ] || { [ -n "$DPU_B" ] && [ -z "$DPU_A_IP" ]; }; then
	echo "usage: $0 <dpu-a> [<dpu-b> <dpu-a IP>]" >&2
	exit 2
fi
if [ -n "$DPU_B" ] && { [ -z "$UVERBS_A" ] || [ -z "$UVERBS_B" ]; }; then
	echo "$0: task d needs UVERBS_A and UVERBS_B (each BlueField's uverbs devices)" >&2
	exit 2
fi

fail=0
svc_log()   { ssh "$1" "sudo -n crictl logs \$(sudo -n crictl ps -q --name $POD) 2>&1"; }
svc_lines() { svc_log "$1" | wc -l; }
svc_since() { svc_log "$1" | tail -n +$(($2 + 1)); }
msg()       { sed -n 's/.*puts("\(.*\)");.*/\1/p' "$HERE/$1" | head -1; }  # a task's puts() text
run_on()    { ODOS_UVERBS=$1 "$HERE/docker_run_task.sh" "${@:2}"; }      # run_on <uverbs> <task...>
check() {   # check <name> <host exit> <service output> <expected line> <expected count>
	n=$(printf '%s\n' "$3" | grep -cxF "$4")
	if [ "$2" = 0 ] && [ "$n" -ge "$5" ]; then
		echo "PASS  $1"
	else
		echo "FAIL  $1 (host exit $2; '$4' seen $n times, want $5)"; fail=1
	fi
}

echo "=== build"
log=$(mktemp)
if ! "$HERE/docker_compile.sh" > "$log" 2>&1; then
	tail -20 "$log"; rm -f "$log"; echo "FAIL  build"; exit 1
fi
tail -1 "$log"; rm -f "$log"

echo "=== start the service"
for d in $DPU_A $DPU_B; do
	"$HERE/dpu_service.sh" "$d" start > /dev/null || { echo "FAIL  service on $d"; exit 1; }
	echo "service running on $d"
done

echo "=== run"
b=$(svc_lines "$DPU_A"); run_on "$UVERBS_A" out/tasks/a_hello >/dev/null; rc=$?
check "task a" $rc "$(svc_since "$DPU_A" "$b")" "$(msg task_a/hello.c)" 1

b=$(svc_lines "$DPU_A"); run_on "$UVERBS_A" out/tasks/b_omp_parallel >/dev/null; rc=$?
check "task b" $rc "$(svc_since "$DPU_A" "$b")" "$(msg task_b/omp_parallel.c)" 16

b=$(svc_lines "$DPU_A"); run_on "$UVERBS_A" out/tasks/c_shared >/dev/null; rc=$?
check "task c" $rc "$(svc_since "$DPU_A" "$b")" "$(msg task_c/log.c)" 1

if [ -n "$DPU_B" ]; then
	a=$(svc_lines "$DPU_A"); b=$(svc_lines "$DPU_B")
	run_on "$UVERBS_A" timeout 60 out/tasks/d_net_accel >/dev/null & server=$!
	sleep 4
	run_on "$UVERBS_B" timeout 60 out/tasks/d_net_accel c "$DPU_A_IP" >/dev/null; crc=$?
	wait $server; src=$?
	check "task d server on $DPU_A" $src "$(svc_since "$DPU_A" "$a")" "to   client > 19" 1
	check "task d client on $DPU_B" $crc "$(svc_since "$DPU_B" "$b")" "to   server > 18" 1
fi

if [ $fail = 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; exit 1; fi

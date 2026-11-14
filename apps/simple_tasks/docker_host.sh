#!/bin/bash
#
# Runs a command in the ODOS host container, or an interactive shell if none is
# given. This folder is mounted at /work, the working directory, and the
# container runs as you, so files it writes here are yours.
#
#   ./docker_host.sh                      # shell
#   ./docker_host.sh out/tasks/a_hello    # one command
#
# Settings (HOST_IMAGE, DOCA_PATH, ODOS_UVERBS) are in docker_env.sh.
# ODOS_COMCH_CONNECT_TIMEOUT is passed through when set.

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/docker_env.sh"

if [ -n "$ODOS_UVERBS" ]; then
	devs=()
	for d in $ODOS_UVERBS; do devs+=(--device="/dev/infiniband/$d"); done
else
	devs=(--device=/dev/infiniband)
fi

# Without DOCA the tasks still compile, but cannot reach the DPU. Mounting a
# missing path would make Docker create it as root, so leave it out instead.
doca=()
if [ -f "$DOCA_PATH/VERSION" ]; then
	doca=(-v "$DOCA_PATH:/opt/mellanox/doca:ro")
else
	echo "docker_host.sh: no DOCA at $DOCA_PATH (set DOCA_PATH);" \
	     "compiling works, running on the DPU does not" >&2
fi

env=(-e HOME=/tmp)
[ -n "$ODOS_COMCH_CONNECT_TIMEOUT" ] && env+=(-e ODOS_COMCH_CONNECT_TIMEOUT)

tty=()
[ -t 0 ] && [ -t 1 ] && tty=(-it)

[ $# -eq 0 ] && set -- bash

exec docker run --rm "${tty[@]}" --network host --user "$(id -u):$(id -g)" \
	"${devs[@]}" --ulimit memlock=-1 "${doca[@]}" "${env[@]}" \
	-v "$HERE:/work" -w /work \
	"$HOST_IMAGE" "$@"

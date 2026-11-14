#!/bin/bash
#
# Starts, stops and shows the ODOS service on a BlueField DPU, run from the
# host. It replaces the old SLURM run_service.sh. The service runs as a
# kubelet static pod (the way BlueField runs DOCA services) from DPU_IMAGE, in
# its default `ref` mode, which tasks a-d need.
#
#   ./dpu_service.sh <dpu> start    # start, or update; waits until it listens
#   ./dpu_service.sh <dpu> status   # pod state and the last lines of output
#   ./dpu_service.sh <dpu> logs     # follow the output (Ctrl-C to quit)
#   ./dpu_service.sh <dpu> stop     # remove the pod and the copied library
#
# <dpu> is anything ssh accepts. start also copies task c's
# out/tasks/liblog_aarch64.so to DPU_TASKS_DIR on the DPU when it is built, and
# can be run again at any time, e.g. after recompiling task c.
#
# The service must run as root, so you need sudo on the DPU. Run from a
# terminal, sudo can ask for a password; from a script it must be passwordless.

POD=odos-dpu-service
MANIFEST=/etc/kubelet.d/$POD.yaml

# ---------------------------------------------------------------------------
# On the DPU, as root: `dpu_service.sh --on-dpu <start|stop> <stage> <tasks>`
# ---------------------------------------------------------------------------
pod_gone() {
	for _ in $(seq 1 60); do
		[ -z "$(crictl pods -q --name "$POD" 2>/dev/null)" ] && return 0
		sleep 1
	done
	return 1
}

if [ "$1" = --on-dpu ]; then
	action=$2 stage=$3 tasks=$4
	case $action in
	start)
		mkdir -p "$tasks"
		for f in "$stage"/*.so; do [ -e "$f" ] && cp "$f" "$tasks"/; done
		if ! cmp -s "$stage/$POD.yaml" "$MANIFEST"; then
			# A changed manifest: let the old pod go first, so that its
			# "listening" line is not mistaken for the new one's.
			[ -e "$MANIFEST" ] && { rm -f "$MANIFEST"; pod_gone; }
			install -m 644 "$stage/$POD.yaml" "$MANIFEST"
			echo "starting the service (the first start on a DPU pulls the image)..."
		fi
		for _ in $(seq 1 300); do
			id=$(crictl ps -q --name "$POD" 2>/dev/null)
			if [ -n "$id" ] && crictl logs "$id" 2>&1 | grep -q "listening as"; then
				crictl logs --tail 3 "$id" 2>&1
				exit 0
			fi
			sleep 1
		done
		echo "dpu_service.sh: the service did not start in 5 minutes;" \
		     "check 'crictl pods' and 'crictl logs' on the DPU" >&2
		exit 1
		;;
	stop)
		rm -f "$MANIFEST"
		pod_gone || echo "dpu_service.sh: the pod is still shutting down" >&2
		rm -rf "$tasks"
		echo "stopped"
		;;
	esac
	exit
fi

# ---------------------------------------------------------------------------
# On the host
# ---------------------------------------------------------------------------
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/docker_env.sh"

DPU=$1 ACTION=$2
if [ -z "$DPU" ] || [ -z "$ACTION" ]; then
	echo "usage: $0 <dpu> start|status|logs|stop" >&2
	exit 2
fi

tty=()
[ -t 0 ] && [ -t 1 ] && tty=(-t)

manifest() {
	cat <<EOF
# Written by apps/simple_tasks/dpu_service.sh: the ODOS service for tasks a-d.
apiVersion: v1
kind: Pod
metadata:
  name: $POD
spec:
  hostNetwork: true
  restartPolicy: Always
  containers:
    - name: $POD
      image: $DPU_IMAGE
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: true          # RDMA devices for DOCA Comch
      env:
        - name: ODOS_SERVICE
          value: "ref"
        - name: LD_LIBRARY_PATH   # task c's liblog_aarch64.so
          value: /tasks
      volumeMounts:
        - name: doca
          mountPath: /opt/mellanox/doca
          readOnly: true
        - name: tasks
          mountPath: /tasks
          readOnly: true
  volumes:
    - name: doca
      hostPath:
        path: /opt/mellanox/doca
        type: Directory
    - name: tasks
      hostPath:
        path: $DPU_TASKS_DIR
        type: DirectoryOrCreate
EOF
}

case $ACTION in
start|stop)
	# Ship this script, the manifest and task c's library in one tarball, then
	# run the root part in a single ssh session (one sudo prompt at most).
	tmp=$(mktemp -d) || exit 1
	trap 'rm -rf "$tmp" "$tmp.tar"' EXIT
	cp "$HERE/dpu_service.sh" "$tmp/"
	manifest > "$tmp/$POD.yaml"
	if [ "$ACTION" = start ] && [ -f "$HERE/out/tasks/liblog_aarch64.so" ]; then
		cp "$HERE/out/tasks/liblog_aarch64.so" "$tmp/"
	fi
	stage=/tmp/odos-dpu-service.$(id -un)
	tar -C "$tmp" -cf "$tmp.tar" . && scp -q "$tmp.tar" "$DPU:$stage.tar" || exit 1
	rm -f "$tmp.tar"
	ssh "${tty[@]}" "$DPU" "rm -rf $stage && mkdir -p $stage && tar -xf $stage.tar -C $stage &&
		sudo bash $stage/dpu_service.sh --on-dpu $ACTION $stage $DPU_TASKS_DIR;
		rc=\$?; rm -rf $stage $stage.tar; exit \$rc"
	;;
status)
	ssh "${tty[@]}" "$DPU" "sudo crictl pods --name $POD; id=\$(sudo crictl ps -q --name $POD);
		if [ -n \"\$id\" ]; then sudo crictl logs --tail 10 \$id 2>&1; else echo 'service not running'; fi"
	;;
logs)
	exec ssh "${tty[@]}" "$DPU" "sudo crictl logs -f \$(sudo crictl ps -q --name $POD)"
	;;
*)
	echo "usage: $0 <dpu> start|status|logs|stop" >&2
	exit 2
	;;
esac

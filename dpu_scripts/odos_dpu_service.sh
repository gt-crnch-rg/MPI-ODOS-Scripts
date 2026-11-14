#!/bin/sh
#
# Starts doca-omp-service on the DPU -- the entrypoint of the DPU image
# (installed as <prefix>/bin/odos-dpu-service by install_dpu.sh).
#
# Environment:
#   ODOS_SERVICE       ref   -- doca-omp-service (OpenMP offload only; default)
#                      mpi   -- doca-omp-service-mpi (also used by ODOS MPI)
#   ODOS_MPI_VARIANT   Open MPI build for ODOS_SERVICE=mpi, matching the
#                      host application (apps/run_service_mpi*.sh):
#                      ref (default) | pt2pt | one-sided
#   ODOS_MPIRUN_ARGS   if set, ODOS_SERVICE=mpi runs under
#                      `mpirun $ODOS_MPIRUN_ARGS`, e.g. "-np 2 -H dpu1,dpu2";
#                      otherwise it runs as a single process
#   ODOS_COMCH_REP_PCI representor the service listens on (see odos_comch.h)
#   ODOS_PREFIX        install prefix (default: this script's ../)
#   DOCA_PATH          DOCA SDK, mounted from the DPU (default /opt/mellanox/doca)
#
# Any arguments are passed to the service.

ODOS_PREFIX=${ODOS_PREFIX:-$(dirname "$(dirname "$(readlink -f "$0")")")}
DOCA_PATH=${DOCA_PATH:-/opt/mellanox/doca}
ODOS_SERVICE=${ODOS_SERVICE:-ref}
ODOS_MPI_VARIANT=${ODOS_MPI_VARIANT:-ref}

if ! ls "$DOCA_PATH"/lib/*/libdoca_comch.so* >/dev/null 2>&1; then
	echo "odos-dpu-service: no DOCA SDK at $DOCA_PATH -- mount the DPU's:" \
	     "-v $DOCA_PATH:$DOCA_PATH:ro" >&2
	exit 1
fi

MPI=$ODOS_PREFIX/ompi/$ODOS_MPI_VARIANT
if [ ! -d "$MPI" ]; then
	echo "odos-dpu-service: unknown ODOS_MPI_VARIANT '$ODOS_MPI_VARIANT'" \
	     "(ref, pt2pt or one-sided)" >&2
	exit 1
fi
export OPAL_PREFIX=$MPI
LD_LIBRARY_PATH=$MPI/lib:$ODOS_PREFIX/ucx/lib:$DOCA_PATH/lib/`uname -m`-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export LD_LIBRARY_PATH

case $ODOS_SERVICE in
ref)
	exec "$ODOS_PREFIX/service/doca-omp-service" "$@"
	;;
mpi)
	if [ -n "$ODOS_MPIRUN_ARGS" ]; then
		# word splitting of ODOS_MPIRUN_ARGS is intended
		exec "$MPI/bin/mpirun" -x OPAL_PREFIX -x LD_LIBRARY_PATH $ODOS_MPIRUN_ARGS \
			"$ODOS_PREFIX/service/doca-omp-service-mpi" "$@"
	fi
	exec "$ODOS_PREFIX/service/doca-omp-service-mpi" "$@"
	;;
*)
	echo "odos-dpu-service: unknown ODOS_SERVICE '$ODOS_SERVICE' (ref or mpi)" >&2
	exit 1
	;;
esac

#!/bin/sh
#
# DPU counterpart of setup.sh -- run from the repo root. Clones only what the
# DPU build needs (not the ODOS LLVM tree or PnetCDF), applies the DOCA Comch
# patches, and lays out the build tree:
#
#   usage: sh dpu_scripts/setup_dpu.sh [component...]
#          components: ucx ompi-bf doca-omp-service (default: all three)
#
#   ucx               -> build/ucx/aarch64
#   ompi-bf           -> build/ompi/aarch64
#   doca-omp-service  -> build/service
#
# Components can be set up in separate calls (dpu_scripts/Dockerfile sets up
# the service last, so changing its patch does not rebuild UCX/Open MPI).

set -e

WANT=${*:-ucx ompi-bf doca-omp-service}

sh clone_repos.sh $WANT
sh apply_patches.sh          # patches what is cloned; skips what is applied

mkdir -p build/ucx build/ompi
set -x
for c in $WANT; do
	case $c in
	ucx)
		rm -rf build/ucx/aarch64
		cp -r repos/ucx build/ucx/aarch64 ;;
	ompi-bf)
		rm -rf build/ompi/aarch64
		cp -r repos/ompi-bf build/ompi/aarch64 ;;
	doca-omp-service)
		rm -rf build/service
		cp -r repos/doca-omp-service build/service ;;
	*)
		echo "setup_dpu.sh: unknown component '$c'" >&2
		exit 1 ;;
	esac
done
set +x

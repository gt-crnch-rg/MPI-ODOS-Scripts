#!/bin/sh
#
# Ports the cloned sources from the DOCA 2.0 Comm Channel API to DOCA >= 3.0
# Comch (the Comm Channel API was removed in DOCA 3.x). Run from the repo root
# after clone_repos.sh and before setup_dirs.sh; setup.sh does this.
#
#   * applies patches/<repo>/*.patch to repos/<repo>
#   * copies patches/odos_comch.h -- the shared Comch send/recv layer -- next
#     to every source file that includes it
#
# The patches are made against the commits clone_repos.sh pins. Patches that
# are already applied are skipped, so rerunning is safe. Repos that were not
# cloned (e.g. ODOS for the DPU build) are skipped.

set -e

P=`pwd`/patches

for repo in ODOS ompi-bf doca-omp-service; do
	if [ ! -d "repos/$repo" ]; then
		echo "not cloned, skipped: $repo"
		continue
	fi
	for patch in "$P/$repo"/*.patch; do
		name="$repo/`basename "$patch"`"
		if git -C "repos/$repo" apply --reverse --check "$patch" 2>/dev/null; then
			echo "already applied: $name"
		else
			git -C "repos/$repo" apply "$patch"
			echo "applied: $name"
		fi
	done
done

for dir in repos/ODOS/openmp/libomptarget/plugins/bf/src \
           repos/ompi-bf/ompi/mca/pml/ucx \
           repos/ompi-bf/ompi/mca/osc/ucx \
           repos/doca-omp-service/ref \
           repos/doca-omp-service/mpi; do
	[ -d "$dir" ] || continue
	cp "$P/odos_comch.h" "$dir/"
done

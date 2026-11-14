#!/bin/sh
#
# Installs the DPU build into a self-contained runtime tree -- the DPU half of
# prepare_pkg.sh. Used by dpu_scripts/Dockerfile; also works on a DPU directly.
#
# usage: sh dpu_scripts/install_dpu.sh [build root] [prefix]
#        (defaults: ./build  /opt/odos-dpu)
#
# Layout:
#   <prefix>/ucx/                       UCX
#   <prefix>/ompi/ref/                  Open MPI, stock pml + osc
#   <prefix>/ompi/pt2pt/                Open MPI, ODOS pml + stock osc
#   <prefix>/ompi/one-sided/            Open MPI, stock pml + ODOS osc
#   <prefix>/service/doca-omp-service       (ref/ build)
#   <prefix>/service/doca-omp-service-mpi   (mpi/ build)
#   <prefix>/bin/odos-dpu-service       launcher (odos_dpu_service.sh)
#
# The three Open MPI variants differ only in which ucx pml/osc component is
# named mca_*_ucx.so; they are hard-linked copies where the filesystem allows,
# so they cost little more than one.

set -e

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
BUILD=${1:-./build}
PREFIX=${2:-/opt/odos-dpu}

OMPI=$BUILD/ompi/aarch64/install

mkdir -p "$PREFIX/ompi" "$PREFIX/service" "$PREFIX/bin"
rm -rf "$PREFIX/ucx" "$PREFIX/ompi/ref" "$PREFIX/ompi/pt2pt" "$PREFIX/ompi/one-sided"

cp -a "$BUILD/ucx/aarch64/install" "$PREFIX/ucx"
cp -a "$OMPI" "$PREFIX/ompi/ref"
for v in pt2pt one-sided; do
	cp -al "$PREFIX/ompi/ref" "$PREFIX/ompi/$v" 2>/dev/null \
		|| { rm -rf "$PREFIX/ompi/$v"; cp -a "$PREFIX/ompi/ref" "$PREFIX/ompi/$v"; }
done

# select <variant> <pml: orig|odos> <osc: orig|odos>
select_components() {
	d=$PREFIX/ompi/$1/lib/openmpi
	mv "$d/$2.mca_pml_ucx.so" "$d/mca_pml_ucx.so"
	mv "$d/$3.mca_osc_ucx.so" "$d/mca_osc_ucx.so"
	rm -f "$d"/orig.mca_*_ucx.so "$d"/odos.mca_*_ucx.so
}
select_components ref       orig orig
select_components pt2pt     odos orig
select_components one-sided orig odos

cp "$BUILD/service/ref/build/doca-omp-service" "$PREFIX/service/doca-omp-service"
cp "$BUILD/service/mpi/build/doca-omp-service" "$PREFIX/service/doca-omp-service-mpi"
cp "$SCRIPT_DIR/odos_dpu_service.sh" "$PREFIX/bin/odos-dpu-service"
chmod +x "$PREFIX/bin/odos-dpu-service"

echo "installed DPU runtime tree in $PREFIX"

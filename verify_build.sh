#!/bin/sh
#
# Verifies that a host build actually produced its artifacts.
#
# The compile_*.sh scripts do not use `set -e`, so a failed configure or make
# still exits 0 and a Docker layer still caches "successfully". This script is
# the explicit check.
#
# usage: sh verify_build.sh [build root]      (default: ./build)
#
# A component counts as present only if its file exists *and* its shared
# libraries resolve (ldd reports nothing "not found" -- including symbol
# versions, e.g. DOCA >= 3.x on top of a too-old rdma-core). The ODOS/DOCA
# components must also have no undefined symbols (ldd -r).
#
# Required components fail the script. The ODOS/DOCA components only warn
# unless REQUIRE_DOCA=1 (the Dockerfiles set it by default).

BUILD=${1:-./build}
REQUIRE_DOCA=${REQUIRE_DOCA:-0}
DOCA_PATH=${DOCA_PATH:-/opt/mellanox/doca}

OMPI_LIB=$BUILD/ompi/x86_64/install/lib/openmpi

# Resolve against this build's own libraries, as the run scripts do.
LD_LIBRARY_PATH=$BUILD/ompi/x86_64/install/lib:$BUILD/ucx/x86_64/install/lib:$BUILD/odos/install/lib:$BUILD/pnetcdf/install/lib:$DOCA_PATH/lib/`uname -m`-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export LD_LIBRARY_PATH
missing_req=0
missing_doca=0

check() {
    # $1 = required|odos, $2 = description, $3... = paths (any one suffices)
    kind=$1; desc=$2; shift 2
    for p in "$@"; do
        if [ -e "$p" ]; then
            # The ODOS/DOCA artifacts link all their dependencies, so for
            # them also require every symbol to resolve (ldd -r).
            if [ "$kind" = odos ]; then ldd_r=-r; else ldd_r=; fi
            unresolved=`ldd $ldd_r "$p" 2>&1 | grep -E "not found|undefined symbol" | head -1 | sed 's/^[[:space:]]*//'`
            if [ -z "$unresolved" ]; then
                echo "  ok      $desc  ($p)"
                return 0
            fi
            echo "  BROKEN  $desc  ($p): $unresolved"
            if [ "$kind" = required ]; then
                missing_req=`expr $missing_req + 1`
            else
                missing_doca=`expr $missing_doca + 1`
            fi
            return 1
        fi
    done
    if [ "$kind" = required ]; then
        echo "  MISSING $desc  ($*)"
        missing_req=`expr $missing_req + 1`
    else
        echo "  absent  $desc  ($*)"
        missing_doca=`expr $missing_doca + 1`
    fi
    return 1
}

echo "Verifying build artifacts under $BUILD"
echo

# The Docker images do not contain DOCA; it is mounted from the host.
if ! ls "$DOCA_PATH"/lib/*/libdoca_common.so* >/dev/null 2>&1; then
    echo "NOTE: no DOCA SDK at $DOCA_PATH, so the ODOS/DOCA components cannot load."
    echo "      In the Docker image, mount the host's: docker run -v $DOCA_PATH:$DOCA_PATH:ro ..."
    echo
elif [ -f /etc/odos-doca-version ] && [ -f "$DOCA_PATH/VERSION" ] \
     && [ "`cat /etc/odos-doca-version`" != "`cat "$DOCA_PATH/VERSION"`" ]; then
    echo "WARNING: built against DOCA `cat /etc/odos-doca-version`, but $DOCA_PATH is DOCA `cat "$DOCA_PATH/VERSION"`."
    echo
fi
echo "Core components:"
check required "UCX libucp"          "$BUILD/ucx/x86_64/install/lib/libucp.so"
check required "UCX ucx_info"        "$BUILD/ucx/x86_64/install/bin/ucx_info"
check required "ODOS clang"          "$BUILD/odos/install/bin/clang"
check required "Open MPI mpicc"      "$BUILD/ompi/x86_64/install/bin/mpicc"
check required "Open MPI mpirun"     "$BUILD/ompi/x86_64/install/bin/mpirun"
check required "a ucx pml component" "$OMPI_LIB/mca_pml_ucx.so" "$OMPI_LIB/odos.mca_pml_ucx.so"
check required "a ucx osc component" "$OMPI_LIB/mca_osc_ucx.so" "$OMPI_LIB/odos.mca_osc_ucx.so"
check required "PnetCDF libpnetcdf"  "$BUILD/pnetcdf/install/lib/libpnetcdf.a"
check required "PnetCDF ncmpidump"   "$BUILD/pnetcdf/install/bin/ncmpidump"

echo
echo "ODOS/DOCA components:"
check odos "OpenMP runtime libomp"     "$BUILD/odos/install/lib/libomp.so"
check odos "OpenMP offload libomptarget" "$BUILD/odos/install/lib/libomptarget.so"
check odos "BlueField offload plugin"  "$BUILD/odos/install/lib/libomptarget.rtl.bf.so"
check odos "ODOS pml plugin"           "$OMPI_LIB/odos.mca_pml_ucx.so"
check odos "ODOS osc plugin"           "$OMPI_LIB/odos.mca_osc_ucx.so"

echo
if [ "$missing_req" -gt 0 ]; then
    echo "FAIL: $missing_req required component(s) missing." >&2
    exit 1
fi
if [ "$missing_doca" -gt 0 ]; then
    echo "WARNING: $missing_doca ODOS/DOCA component(s) missing or broken -- this build"
    echo "         provides stock Open MPI/UCX/clang only, with no ODOS offload."
    if [ "$REQUIRE_DOCA" = 1 ]; then
        echo "FAIL: REQUIRE_DOCA=1 and ODOS/DOCA components are missing." >&2
        exit 1
    fi
    exit 0
fi
echo "OK: all components present."

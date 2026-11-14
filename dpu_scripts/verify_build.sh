#!/bin/sh
#
# Verifies that a DPU (aarch64) build actually produced its artifacts -- the
# DPU counterpart of the top-level verify_build.sh.
#
# The compile_*.sh scripts do not use `set -e`, so a failed configure or make
# still exits 0 and a Docker layer still caches "successfully". This script is
# the explicit check.
#
# usage: sh dpu_scripts/verify_build.sh [root]
#
#   root  either a build tree (default ./build; layout of compile_dpu.sh) or
#         an installed tree (layout of install_dpu.sh, e.g. /opt/odos-dpu);
#         the layout is detected.
#
# A component counts as present only if its file exists *and* its shared
# libraries resolve (ldd reports nothing "not found" -- including symbol
# versions, e.g. DOCA >= 3.x on top of a too-old rdma-core). The ODOS/DOCA
# components must also have no undefined symbols (ldd -r) and must link
# DOCA Comch (libdoca_comch), i.e. be the DOCA >= 3.3 port.
#
# Required components fail the script. The ODOS/DOCA components only warn
# unless REQUIRE_DOCA=1 (dpu_scripts/Dockerfile sets it by default).

ROOT=${1:-./build}
REQUIRE_DOCA=${REQUIRE_DOCA:-0}
DOCA_PATH=${DOCA_PATH:-/opt/mellanox/doca}
DOCA_LIB=$DOCA_PATH/lib/`uname -m`-linux-gnu

if [ -d "$ROOT/ompi/ref/lib" ]; then
    LAYOUT=installed
    UCX=$ROOT/ucx
    MPI_LIB=$ROOT/ompi/ref/lib
else
    LAYOUT=build
    UCX=$ROOT/ucx/aarch64/install
    MPI_LIB=$ROOT/ompi/aarch64/install/lib
fi

# Resolve against this tree's own libraries, as the launcher does.
LD_LIBRARY_PATH=$MPI_LIB:$UCX/lib:$DOCA_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export LD_LIBRARY_PATH
missing_req=0
missing_doca=0

fail() {
    # $1 = required|odos
    if [ "$1" = required ]; then
        missing_req=`expr $missing_req + 1`
    else
        missing_doca=`expr $missing_doca + 1`
    fi
}

check() {
    # $1 = required|odos, $2 = description, $3... = paths (any one suffices)
    kind=$1; desc=$2; shift 2
    for p in "$@"; do
        if [ -e "$p" ] && [ "`head -c 4 "$p" | tail -c 3`" != ELF ]; then
            # not an ELF file (e.g. the launcher script): no libraries to resolve
            if [ -x "$p" ]; then
                echo "  ok      $desc  ($p)"
                return 0
            fi
            echo "  BROKEN  $desc  ($p): not executable"
            fail $kind
            return 1
        fi
        if [ -e "$p" ]; then
            if [ "$kind" = odos ]; then ldd_r=-r; else ldd_r=; fi
            out=`ldd $ldd_r "$p" 2>&1`
            unresolved=`echo "$out" | grep -E "not found|undefined symbol|not a dynamic" | head -1 | sed 's/^[[:space:]]*//'`
            if [ -z "$unresolved" ] && [ "$kind" = odos ] \
               && ! echo "$out" | grep -q "libdoca_comch\.so"; then
                unresolved="does not link libdoca_comch (not the DOCA Comch port)"
            fi
            if [ -z "$unresolved" ]; then
                echo "  ok      $desc  ($p)"
                return 0
            fi
            echo "  BROKEN  $desc  ($p): $unresolved"
            fail $kind
            return 1
        fi
    done
    if [ "$kind" = required ]; then
        echo "  MISSING $desc  ($*)"
    else
        echo "  absent  $desc  ($*)"
    fi
    fail $kind
    return 1
}

echo "Verifying DPU $LAYOUT tree under $ROOT"
echo

if [ "`uname -m`" != aarch64 ]; then
    echo "NOTE: this machine is `uname -m`; DPU binaries are aarch64 and cannot be checked here."
    echo
fi

# The Docker image does not contain DOCA; it is mounted from the DPU.
if ! ls "$DOCA_LIB"/libdoca_comch.so* >/dev/null 2>&1; then
    echo "NOTE: no DOCA SDK at $DOCA_PATH, so the ODOS/DOCA components cannot load."
    echo "      In the Docker image, mount the DPU's: docker run -v $DOCA_PATH:$DOCA_PATH:ro ..."
    echo
else
    v=`cat "$DOCA_PATH/VERSION" 2>/dev/null`
    major=`echo "$v" | cut -d. -f1`
    minor=`echo "$v" | cut -d. -f2`
    if [ -z "$v" ] || [ "${major:-0}" -lt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -lt 3 ]; }; then
        echo "WARNING: DOCA at $DOCA_PATH is '${v:-unknown}'; DOCA >= 3.3 is required."
        echo
    elif [ -f /etc/odos-doca-version ] && [ "`cat /etc/odos-doca-version`" != "$v" ]; then
        echo "WARNING: built against DOCA `cat /etc/odos-doca-version`, but $DOCA_PATH is DOCA $v."
        echo
    fi
fi

if [ $LAYOUT = build ]; then
    OMPI=$ROOT/ompi/aarch64/install
    OMPI_LIB=$OMPI/lib/openmpi
    SVC_REF=$ROOT/service/ref/build/doca-omp-service
    SVC_MPI=$ROOT/service/mpi/build/doca-omp-service

    echo "Core components:"
    check required "UCX libucp"           "$UCX/lib/libucp.so"
    check required "UCX ucx_info"         "$UCX/bin/ucx_info"
    check required "Open MPI mpicc"       "$OMPI/bin/mpicc"
    check required "Open MPI mpirun"      "$OMPI/bin/mpirun"
    check required "a ucx pml component" "$OMPI_LIB/mca_pml_ucx.so" "$OMPI_LIB/orig.mca_pml_ucx.so"
    check required "a ucx osc component" "$OMPI_LIB/mca_osc_ucx.so" "$OMPI_LIB/orig.mca_osc_ucx.so"

    echo
    echo "ODOS/DOCA components:"
    check odos "ODOS pml plugin"          "$OMPI_LIB/odos.mca_pml_ucx.so"
    check odos "ODOS osc plugin"          "$OMPI_LIB/odos.mca_osc_ucx.so"
    check odos "doca-omp-service"         "$SVC_REF"
    check odos "doca-omp-service-mpi"     "$SVC_MPI"
else
    echo "Core components:"
    check required "UCX libucp"           "$UCX/lib/libucp.so"
    check required "UCX ucx_info"         "$UCX/bin/ucx_info"
    for v in ref pt2pt one-sided; do
        check required "Open MPI ($v) mpirun" "$ROOT/ompi/$v/bin/mpirun"
    done
    for v in ref one-sided; do
        check required "stock pml ($v)"   "$ROOT/ompi/$v/lib/openmpi/mca_pml_ucx.so"
    done
    for v in ref pt2pt; do
        check required "stock osc ($v)"   "$ROOT/ompi/$v/lib/openmpi/mca_osc_ucx.so"
    done
    check required "launcher"             "$ROOT/bin/odos-dpu-service"

    echo
    echo "ODOS/DOCA components:"
    check odos "ODOS pml plugin (pt2pt)"     "$ROOT/ompi/pt2pt/lib/openmpi/mca_pml_ucx.so"
    check odos "ODOS osc plugin (one-sided)" "$ROOT/ompi/one-sided/lib/openmpi/mca_osc_ucx.so"
    check odos "doca-omp-service"            "$ROOT/service/doca-omp-service"
    check odos "doca-omp-service-mpi"        "$ROOT/service/doca-omp-service-mpi"
fi

echo
if [ "$missing_req" -gt 0 ]; then
    echo "FAIL: $missing_req required component(s) missing." >&2
    exit 1
fi
if [ "$missing_doca" -gt 0 ]; then
    echo "WARNING: $missing_doca ODOS/DOCA component(s) missing or broken -- this build"
    echo "         provides stock Open MPI/UCX only, with no ODOS service or plugins."
    if [ "$REQUIRE_DOCA" = 1 ]; then
        echo "FAIL: REQUIRE_DOCA=1 and ODOS/DOCA components are missing." >&2
        exit 1
    fi
    exit 0
fi
echo "OK: all components present."

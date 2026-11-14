#!/bin/sh
#
# Host <-> DPU round-trip smoke test for doca-omp-service. Run on the x86_64
# host of the BlueField, from the repo root, while the service is running
# (as root) on the DPU.
#
# usage: sh dpu_scripts/test/run_roundtrip.sh [host PF PCI address] [sessions]
#        (defaults: 0000:27:00.0, 2)
#
# The PCI address is the host-side PF of the BlueField whose DPU runs the
# service (`lspci | grep BlueField`; e.g. 27:00.0 -> 0000:27:00.0).
#
# Builds rt_client against the host's DOCA (DOCA_PATH, default
# /opt/mellanox/doca) and patches/odos_comch.h, then connects to the service
# and, per session, sends and retrieves buffers of 8 B .. 16 MB, comparing
# every byte. Exits non-zero on any failure.
#
# Environment: DOCA_PATH, CC (default cc), OUT (build dir, default ./build/test)

DIR=$(dirname "$(readlink -f "$0")")
REPO=$(dirname "$(dirname "$DIR")")
DOCA_PATH=${DOCA_PATH:-/opt/mellanox/doca}
OUT=${OUT:-./build/test}
DOCA_LIB=$DOCA_PATH/lib/`uname -m`-linux-gnu

if [ ! -f "$DOCA_PATH/VERSION" ]; then
    echo "run_roundtrip.sh: no DOCA SDK at $DOCA_PATH (set DOCA_PATH)." >&2
    exit 2
fi

mkdir -p "$OUT" || exit 2
${CC:-cc} -O2 -g -Wall -Wno-unused-function -DDOCA_ALLOW_EXPERIMENTAL_API \
    -I"$DOCA_PATH/include" -I"$REPO/patches" \
    "$DIR/rt_client.c" -o "$OUT/rt_client" \
    -L"$DOCA_LIB" -ldoca_common -ldoca_comch || exit 2

LD_LIBRARY_PATH=$DOCA_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} \
    "$OUT/rt_client" "${1:-0000:27:00.0}" "${2:-2}"

#!/bin/sh
# DPU (aarch64 / BlueField) build — run from the repo root.
# Shared scripts (compile_1_ucx.sh, compile_3_ompi.sh) are in the repo root.
# DPU-specific scripts are in dpu_scripts/ (this file's directory).

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

rm -rf ./build/ucx/aarch64/build
rm -rf ./build/ucx/x86_64/build

set -x
sh compile_1_ucx.sh  ./build/ucx/aarch64
sh compile_3_ompi.sh ./build/ompi/aarch64 `pwd`/./build/ucx/aarch64/install "/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/doca" /global/software/rocky-9.aarch64/modules/tools/cmake/3.26.4/bin/cmake
sh "$SCRIPT_DIR/compile_5_service.sh" ./build/service/ "/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/doca/" `pwd`/build/ompi/aarch64/install/ /global/software/rocky-9.aarch64/modules/tools/cmake/3.26.4/bin/cmake
set +x

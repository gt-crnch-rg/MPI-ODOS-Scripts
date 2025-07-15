#!/bin/sh

rm -rf ./build/ucx/aarch64/build
rm -rf ./build/ucx/x86_64/build

set -x
sh compile_ucx.sh  ./build/ucx/aarch64
sh compile_ompi.sh ./build/ompi/aarch64 `pwd`/./build/ucx/aarch64/install "/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/doca" /global/software/rocky-9.aarch64/modules/tools/cmake/3.26.4/bin/cmake
sh compile_service.sh ./build/service/ "/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/doca/" `pwd`/build/ompi/aarch64/install/ /global/software/rocky-9.aarch64/modules/tools/cmake/3.26.4/bin/cmake
set +x


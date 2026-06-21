#!/bin/sh

rm -rf ./build/ucx/x86_64/build
rm -rf ./build/odos/build
rm -rf ./build/odos/install

set -x
sh compile_1_ucx.sh ./build/ucx/x86_64
sh compile_2_odos.sh `pwd`/repos/ODOS `pwd`/build/odos/build `pwd`/build/odos/install
sh compile_3_ompi.sh ./build/ompi/x86_64 `pwd`/./build/ucx/x86_64/install "/global/software/rocky-9.x86_64/modules/tools/doca/2.0.2/opt/mellanox/doca" /global/software/rocky-9.x86_64/modules/tools/cmake/3.26.4/bin/cmake
sh compile_4_pnetcdf.sh ./build/pnetcdf
set +x

#!/bin/sh

# arg 1 : path to service
# arg 2 : path to doca
# arg 3 : path to mpi
# arg 3 : cmake

ROOT=`pwd`
SERVICEDIR=$1
DOCAPATH=$2
MPIPATH=$3
CMAKE=$4

set -x
module load doca/2.0.2 cmake arm

# armclang
export PATH=$PATH:/global/software/rocky-9.aarch64/modules/langs/arm/23.04/arm-linux-compiler-23.04.1_RHEL-9/bin/
LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/usr/lib64:/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/spdk/lib:/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/grpc/lib64:/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/grpc/lib:/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/flexio/lib:/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/dpdk/lib64:/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/collectx/lib:/global/software/rocky-9.aarch64/modules/tools/doca/2.0.2/opt/mellanox/doca/lib64
cd $SERVICEDIR

cd ref
rm -rf build && mkdir build && cd build
$CMAKE ../ -DDOCA_PATH=$DOCAPATH && make -j4

cd ../../mpi
rm -rf build && mkdir build && cd build
$CMAKE ../ -DDOCA_PATH=$DOCAPATH -DMPI_PATH=$MPIPATH && make -j4
set +x

cd $ROOT

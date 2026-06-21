#!/bin/sh

# arg 1 : path to ompi cloned repo
# arg 2 : path to ucx install
# arg 3 : doca path
# arg 4 : cmake path


#TYPE=pml
#TYPE=osc
#UCX=`pwd`/../ucx/install
OMPIDIR=$1
UCX=$2
#DOCA="/global/software/rocky-9.x86_64/modules/tools/doca/2.0.2/opt/mellanox/doca"
DOCA=$3
CMAKE=$4

set -x

ROOT=`pwd`
cd $OMPIDIR

./autogen.pl
./configure --prefix=`pwd`/install/ --with-ucx=$UCX --disable-fortran

make -j16 install


TYPE=pml
mv install/lib/openmpi/mca_${TYPE}_ucx.so install/lib/openmpi/orig.mca_${TYPE}_ucx.so

cd ompi/mca/${TYPE}/ucx

rm -rf build && mkdir build && cd build

$CMAKE ../ -DDOCA_ENABLED=1 -DUCX_PATH=$UCX -DDOCA_PATH=$DOCA
make -j8

cp libmca_${TYPE}_ucx.so ../../../../../install/lib/openmpi/odos.mca_${TYPE}_ucx.so

cd $ROOT
cd $OMPIDIR 

TYPE=osc
mv install/lib/openmpi/mca_${TYPE}_ucx.so install/lib/openmpi/orig.mca_${TYPE}_ucx.so

cd ompi/mca/${TYPE}/ucx

rm -rf build && mkdir build && cd build

$CMAKE ../ -DDOCA_ENABLED=1 -DUCX_PATH=$UCX -DDOCA_PATH=$DOCA
make -j8

cp libmca_${TYPE}_ucx.so ../../../../../install/lib/openmpi/odos.mca_${TYPE}_ucx.so

cd $ROOT 

set +x


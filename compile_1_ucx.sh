#!/bin/sh

# give directory of ucx repo as argument

UCXDIR=$1
ROOT=`pwd`
#cd ./ucx/x86_64
cd $UCXDIR

./autogen.sh

rm -rf build
mkdir build && cd build

../configure --prefix=`pwd`/../install/

make -j`nproc` install

cd ../../
cd $ROOT

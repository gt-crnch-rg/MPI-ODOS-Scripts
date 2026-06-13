#!/bin/sh

# args 1 : path to cloned pnetcdf repo

DIR=$1
ROOT=`pwd`

cd $DIR

set -x
module load gcc hpcx
./configure --prefix=`pwd`/install
make -j32 install
set +x

cd $ROOT

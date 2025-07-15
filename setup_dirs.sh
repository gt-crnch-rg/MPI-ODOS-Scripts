#!/bin/sh

mkdir build
cd build
mkdir ucx ompi

set -x

mkdir odos

cp -r ../repos/ucx/ ./ucx/x86_64
cp -r ../repos/ucx/ ./ucx/aarch64

cp -r ../repos/ompi-bf/ ./ompi/x86_64
cp -r ../repos/ompi-bf/ ./ompi/aarch64

cp -r ../repos/doca-omp-service ./service

cp -r ../repos/pnetcdf-1.14.0 ./pnetcdf

set +x

cd ../

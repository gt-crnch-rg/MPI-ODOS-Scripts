#!/bin/sh

set -x
ROOT=`pwd`

rm -rf pkg && mkdir pkg


cp -r ./build/odos/install ./pkg/odos

mkdir pkg/ucx
cp -r ./build/ucx/x86_64/install  ./pkg/ucx/x86_64
cp -r ./build/ucx/aarch64/install ./pkg/ucx/aarch64

mkdir pkg/ompi
mkdir -p pkg/ompi/ref pkg/ompi/pt2pt pkg/ompi/one-sided

cp -r ./build/ompi/x86_64/install ./pkg/ompi/ref/x86_64
cp -r ./build/ompi/x86_64/install ./pkg/ompi/pt2pt/x86_64
cp -r ./build/ompi/x86_64/install ./pkg/ompi/one-sided/x86_64

cd ./pkg/ompi/ref/x86_64/lib/openmpi
mv orig.mca_pml_ucx.so mca_pml_ucx.so
mv orig.mca_osc_ucx.so mca_osc_ucx.so
cd ../../../../pt2pt/x86_64/lib/openmpi
mv odos.mca_pml_ucx.so mca_pml_ucx.so
mv orig.mca_osc_ucx.so mca_osc_ucx.so
cd ../../../../one-sided/x86_64/lib/openmpi
mv orig.mca_pml_ucx.so mca_pml_ucx.so
mv odos.mca_osc_ucx.so mca_osc_ucx.so
cd $ROOT


cp -r ./build/ompi/aarch64/install ./pkg/ompi/ref/aarch64
cp -r ./build/ompi/aarch64/install ./pkg/ompi/pt2pt/aarch64
cp -r ./build/ompi/aarch64/install ./pkg/ompi/one-sided/aarch64

cd ./pkg/ompi/ref/aarch64/lib/openmpi
mv orig.mca_pml_ucx.so mca_pml_ucx.so
mv orig.mca_osc_ucx.so mca_osc_ucx.so
cd ../../../../pt2pt/aarch64/lib/openmpi
mv odos.mca_pml_ucx.so mca_pml_ucx.so
mv orig.mca_osc_ucx.so mca_osc_ucx.so
cd ../../../../one-sided/aarch64/lib/openmpi
mv orig.mca_pml_ucx.so mca_pml_ucx.so
mv odos.mca_osc_ucx.so mca_osc_ucx.so

cd $ROOT
cp -r ./build/pnetcdf/install/ ./pkg/pnetcdf

mkdir ./pkg/odos/service
cp ./build/service/ref/build/doca-omp-service ./pkg/odos/service/doca-omp-service
cp ./build/service/mpi/build/doca-omp-service ./pkg/odos/service/doca-omp-service-mpi
cd $ROOT

set +x

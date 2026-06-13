#!/bin/sh

mkdir repos && cd repos 

git clone https://github.com/openucx/ucx.git
cd ucx && git checkout v1.16.0 && cd ../
git clone -b bf --single-branch https://github.com/openucx/ODOS.git
git clone https://github.com/usman0xff/doca-omp-service.git
git clone https://github.com/usman0xff/ompi-bf.git
wget https://parallel-netcdf.github.io/Release/pnetcdf-1.14.0.tar.gz
tar xvzf pnetcdf-1.14.0.tar.gz

cd ../



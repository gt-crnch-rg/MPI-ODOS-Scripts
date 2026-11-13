#!/bin/sh

mkdir repos && cd repos 

git clone https://github.com/openucx/ucx.git
cd ucx && git checkout v1.16.0 && cd ../
# patches/ (see apply_patches.sh) are made against these commits.
git clone -b bf --single-branch https://github.com/openucx/ODOS.git
cd ODOS && git checkout 6b725556ee26f208dd65db9140511fe704047694 && cd ../
git clone https://github.com/usman0xff/doca-omp-service.git
cd doca-omp-service && git checkout 655b3b555abc7800d336f6eb9f4aaf5335552eaf && cd ../
git clone https://github.com/usman0xff/ompi-bf.git
cd ompi-bf && git checkout 62cef93ea961d587ec41cdb54a4d775fe0a70bda && cd ../
wget https://parallel-netcdf.github.io/Release/pnetcdf-1.14.0.tar.gz
tar xvzf pnetcdf-1.14.0.tar.gz

cd ../



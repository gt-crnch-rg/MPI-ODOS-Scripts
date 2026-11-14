#!/bin/sh
#
# usage: ./clone_repos.sh [component...]
#   components: ucx ODOS doca-omp-service ompi-bf pnetcdf (default: all)
#   e.g. the DPU build (dpu_scripts/setup_dpu.sh) needs only
#        ucx ompi-bf doca-omp-service.

WANT=${*:-ucx ODOS doca-omp-service ompi-bf pnetcdf}
want() { case " $WANT " in *" $1 "*) return 0 ;; esac; return 1; }

mkdir -p repos && cd repos || exit 1

if want ucx; then
git clone https://github.com/openucx/ucx.git
cd ucx && git checkout v1.16.0 && cd ../
fi
# patches/ (see apply_patches.sh) are made against these commits.
if want ODOS; then
git clone -b bf --single-branch https://github.com/openucx/ODOS.git
cd ODOS && git checkout 6b725556ee26f208dd65db9140511fe704047694 && cd ../
fi
if want doca-omp-service; then
git clone https://github.com/usman0xff/doca-omp-service.git
cd doca-omp-service && git checkout 655b3b555abc7800d336f6eb9f4aaf5335552eaf && cd ../
fi
if want ompi-bf; then
git clone https://github.com/usman0xff/ompi-bf.git
cd ompi-bf && git checkout 62cef93ea961d587ec41cdb54a4d775fe0a70bda && cd ../
fi
if want pnetcdf; then
wget https://parallel-netcdf.github.io/Release/pnetcdf-1.14.0.tar.gz
tar xvzf pnetcdf-1.14.0.tar.gz
fi

cd ../

#!/bin/sh

. env.sh

CLANG_PATH=$PKG/odos/
MPI_PATH=$PKG/ompi/ref/x86_64
PNETCDF_PATH=$PKG/pnetcdf

. env.sh

export LD_LIBRARY_PATH=$MPI_PATH/lib:$LD_LIBRARY_PATH
export OPAL_PREFIX=$MPI_PATH

cd omb-odos/mpi_odos/

cd pt2pt/      && . compile.sh $CLANG_PATH $MPI_PATH
mv b* l* m* ../../../out/omb/pt2pt/ && cd ../

cd one-sided/  && . compile.sh $CLANG_PATH $MPI_PATH
mv a* f* cas* g* p* ../../../out/omb/one-sided/ && cd ../

cd collective/ && . compile.sh $CLANG_PATH $MPI_PATH
mv a* s* r* i* g* ../../../out/omb/collective/ && cd ../../../


cd miniweather/odos/ && . compile_omp.sh $CLANG_PATH $MPI_PATH $PNETCDF_PATH
mv miniWeather_mpi_omp miniWeather_mpi_odos_omp ../../out/miniweather && cd ../../


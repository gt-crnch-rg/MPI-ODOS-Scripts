#!/bin/sh

. env.sh

CLANG_PATH=$PKG/odos/
MPI_PATH=$PKG/ompi/ref/x86_64

. env.sh

export LD_LIBRARY_PATH=$MPI_PATH/lib:$LD_LIBRARY_PATH
export OPAL_PREFIX=$MPI_PATH

cd task_a && cd build && cmake .. -DCLANG_PATH=$CLANG_PATH && make 
cp ./hello ../../out/tasks/a_hello && cd ../../
cd task_b && cd build && cmake .. -DCLANG_PATH=$CLANG_PATH && make 
cp ./omp_parallel ../../out/tasks/b_omp_parallel && cd ../../
cd task_c && sh compile.sh $CLANG_PATH
cp ./build/lib* ../out/tasks/  && cp ./build/shared ../out/tasks/c_shared && cd ../
cd task_d && cd build && cmake .. -DCLANG_PATH=$CLANG_PATH && make
cp ./net_accel ../../out/tasks/d_net_accel && cd ../../

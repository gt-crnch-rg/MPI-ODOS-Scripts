#!/bin/bash
#
# Builds tasks a-d in the ODOS host container -- the container version of
# compile.sh. The binaries, and task c's two libraries, end up in out/tasks/.
#
#   ./docker_compile.sh

HERE=$(cd "$(dirname "$0")" && pwd)

exec "$HERE/docker_host.sh" bash -ec '
CLANG_PATH=/opt/odos-mpi/build/odos/install
mkdir -p out/tasks
(cd task_a/build && cmake .. -DCLANG_PATH=$CLANG_PATH && make && cp hello        ../../out/tasks/a_hello)
(cd task_b/build && cmake .. -DCLANG_PATH=$CLANG_PATH && make && cp omp_parallel ../../out/tasks/b_omp_parallel)
(cd task_c && sh compile.sh $CLANG_PATH && cp build/liblog_*.so ../out/tasks/ && cp build/shared ../out/tasks/c_shared)
(cd task_d/build && cmake .. -DCLANG_PATH=$CLANG_PATH && make && cp net_accel    ../../out/tasks/d_net_accel)
echo "built in out/tasks: $(ls out/tasks | tr "\n" " ")"
'

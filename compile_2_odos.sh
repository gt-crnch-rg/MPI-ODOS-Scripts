#!/bin/sh

module load cmake

# arg 1 : path to cloned ODOS dir
# arg 2 : path to build dir
# arg 3 : path to install dir

ODOSDIR=$1
BUILD=$2
INSTALL=$3
#cd ODOS
ROOT=`pwd`
cd $ODOSDIR

DOCA=/global/software/rocky-9.x86_64/modules/tools/doca/2.0.2/opt/mellanox/doca/

PREFIX=$INSTALL
BUILDDIR=$BUILD/clang

cmake -S llvm                                       \
      -B $BUILDDIR                                  \
      -DCMAKE_INSTALL_PREFIX="$PREFIX"              \
      -DCMAKE_BUILD_TYPE=Release                    \
      -DCMAKE_C_COMPILER="`which gcc`"              \
      -DCMAKE_CXX_COMPILER="`which g++`"            \
      -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"           \
      -DLLVM_BUILD_UTILS=OFF                        \
      -DLLVM_ENABLE_PROJECTS="clang"                \
      -DGCC_INSTALL_PREFIX="/usr"                   \
      -DCLANG_ENABLE_ARCMT=OFF                      \
      -DCLANG_ENABLE_STATIC_ANALYZER=OFF

cd $BUILDDIR && make -j16 install
cd $ODOSDIR 


BUILDDIR=$BUILD/openmp

cmake -S openmp                                     \
      -B $BUILDDIR                                  \
      -DLLVM_ROOT="$PREFIX"                         \
      -DCMAKE_INSTALL_PREFIX="$PREFIX"              \
      -DCMAKE_BUILD_TYPE=Release                    \
      -DCMAKE_C_COMPILER="$PREFIX/bin/clang"        \
      -DCMAKE_CXX_COMPILER="$PREFIX/bin/clang++"    \
      -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"           \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON            \
      -DOPENMP_ENABLE_LIBOMPTARGET_PROFILING=OFF    \
      -DLIBOMP_HAVE_OMPT_SUPPORT=OFF                \
      -DLIBOMP_INSTALL_ALIASES=OFF                  \
      -DLIBOMPTARGET_ENABLE_DEBUG=OFF               \
      -DLLVM_BUILD_TOOLS=ON                         \
      -DLLVM_ENABLE_RUNTIMES=openmp                 \
      -DDOCA_PATH=$DOCA

cd $BUILDDIR && make -j16 install
cd $ROOT 

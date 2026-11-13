#!/bin/sh

# arg 1 : path to ompi cloned repo
# arg 2 : path to ucx install
# arg 3 : doca path
# arg 4 : cmake path


#TYPE=pml
#TYPE=osc
#UCX=`pwd`/../ucx/install
OMPIDIR=$1
UCX=$2
#DOCA="/global/software/rocky-9.x86_64/modules/tools/doca/2.0.2/opt/mellanox/doca"
DOCA=$3
CMAKE=$4

set -x

ROOT=`pwd`
cd $OMPIDIR
OMPISRC=`pwd`

./autogen.pl
./configure --prefix=`pwd`/install/ --with-ucx=$UCX --disable-fortran

make -j16 install

# The DOCA plugin CMakeLists assume the embedded libevent/hwloc headers are
# already on the include path (true on the cluster via hpcx, not on a plain
# distro). Point at the in-tree copies; -I of a missing dir is harmless when
# ompi is configured against external libevent/hwloc instead.
EVENT=$OMPISRC/opal/mca/event/libevent2022
HWLOC=$OMPISRC/opal/mca/hwloc/hwloc201/hwloc/include
EXTRA_CFLAGS="-I$EVENT -I$EVENT/libevent -I$EVENT/libevent/include -I$HWLOC"

# The plugins compile Open MPI's opal atomics, so they need the machine flags
# Open MPI was built with: on x86_64 that is -mcx16, without which gcc turns
# the 128-bit CAS into a __sync_val_compare_and_swap_16 call nothing provides.
# (Only the -m* flags -- the rest, e.g. -Werror-implicit-function-declaration,
# would break the ODOS sources.)
for f in `sed -n 's/^CFLAGS = //p' $OMPISRC/opal/Makefile`; do
    case $f in -m*) EXTRA_CFLAGS="$EXTRA_CFLAGS $f" ;; esac
done

for TYPE in pml osc; do
    cd $OMPISRC/ompi/mca/${TYPE}/ucx

    rm -rf build && mkdir build && cd build

    $CMAKE ../ -DDOCA_ENABLED=1 -DUCX_PATH=$UCX -DDOCA_PATH=$DOCA \
        -DCMAKE_C_FLAGS="$EXTRA_CFLAGS"
    make -j8

    # Only displace the stock component once the ODOS one actually built --
    # otherwise the install is left with no ucx ${TYPE} component at all.
    if [ -f libmca_${TYPE}_ucx.so ]; then
        mv $OMPISRC/install/lib/openmpi/mca_${TYPE}_ucx.so \
           $OMPISRC/install/lib/openmpi/orig.mca_${TYPE}_ucx.so
        cp libmca_${TYPE}_ucx.so \
           $OMPISRC/install/lib/openmpi/odos.mca_${TYPE}_ucx.so
    else
        echo "compile_3_ompi.sh: ODOS ${TYPE} plugin FAILED to build;" \
             "keeping stock mca_${TYPE}_ucx.so" >&2
    fi

    cd $OMPISRC
done

cd $ROOT

set +x

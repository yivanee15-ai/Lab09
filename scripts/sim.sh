#!/bin/bash
# usage: scripts/sim.sh <rtl_file> <patdir> [plusargs...]   (builds into /tmp/qme_build/<tag>)
set -e
RTL=$(readlink -f "$1"); PAT=$(readlink -f "$2"); shift 2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=$(basename "$RTL" .sv)
VFLAGS="--x-assign 0 --x-initial 0"
if [ -n "$RAND_INIT" ]; then TAG=${TAG}_rand; VFLAGS="--x-assign unique --x-initial unique"; fi
BUILD=/tmp/qme_build/$TAG
mkdir -p $BUILD
if [ ! -x $BUILD/Vtb ] || [ "$RTL" -nt $BUILD/Vtb ] || [ $ROOT/00_TESTBED/PATTERN.sv -nt $BUILD/Vtb ] || [ $ROOT/00_TESTBED/pseudo_DRAM.sv -nt $BUILD/Vtb ]; then
  mkdir -p $BUILD/inc && cp $ROOT/00_TESTBED/*.sv $BUILD/inc/ && cp "$RTL" $BUILD/inc/QME.sv
  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module TESTBED -Mdir $BUILD/obj \
     -I$BUILD/inc $BUILD/inc/TESTBED.sv -o ../Vtb $VFLAGS >$BUILD/build.log 2>&1 || { tail -40 $BUILD/build.log; exit 1; }
fi
RFLAGS=""
[ -n "$RAND_INIT" ] && RFLAGS="+verilator+rand+reset+2 +verilator+seed+$RAND_INIT"
$BUILD/Vtb +PAT_DIR=$PAT +DRAM_FILE=$PAT/dram.dat $RFLAGS "$@"

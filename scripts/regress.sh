#!/bin/bash
# usage: scripts/regress.sh <rtl.sv> [nseeds=12] [ncmds=250]
# Runs every seed with 4 DRAM parameter sets; prints one line per run + a summary.
RTL=$(readlink -f "$1"); NS=${2:-12}; NC=${3:-250}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p /tmp/pat
# build once (sim.sh builds on first call)
python3 $ROOT/model/gen_pattern.py /tmp/pat/warm 1 20 4 >/dev/null
$ROOT/scripts/sim.sh $RTL /tmp/pat/warm >/dev/null 2>&1
PARAMS=("+DRAM_REORDER=0" \
 "+DRAM_R_LATENCY=100 +DRAM_B_LATENCY=100 +DRAM_W_STALL=20 +DRAM_AR_AW_STALL=20 +DRAM_GAP=5 +DRAM_REORDER=1" \
 "+DRAM_R_LATENCY=7 +DRAM_B_LATENCY=5 +DRAM_W_STALL=3 +DRAM_AR_AW_STALL=2 +DRAM_GAP=2 +DRAM_REORDER=1" \
 "+DRAM_R_LATENCY=1 +DRAM_B_LATENCY=1 +DRAM_W_STALL=0 +DRAM_AR_AW_STALL=0 +DRAM_GAP=0 +DRAM_REORDER=1")
run_one() {
  RTL=$1; ROOT=$2; seed=$3; pi=$4; NC=$5; shift 5; P="$*"
  mode=$((seed % 6)); d=/tmp/pat/s${seed}
  [ -f $d/ncmds.txt ] || python3 $ROOT/model/gen_pattern.py $d $seed $NC $mode >/dev/null
  out=$($ROOT/scripts/sim.sh $RTL $d $P +DRAM_SEED=$seed +PAT_SEED=$seed 2>&1 | grep -E "RESULT|DRAM-CHECK|PATTERN\]" | head -4)
  echo "seed=$seed mode=$mode p$pi: $out"
}
export -f run_one
for ((s=1; s<=NS; s++)); do for pi in 0 1 2 3; do echo "$RTL $ROOT $s $pi $NC ${PARAMS[$pi]}"; done; done | \
  xargs -P $(nproc) -L1 bash -c 'run_one "$@"' _ > /tmp/pat/regress.log
sort -V /tmp/pat/regress.log | cut -c1-230
echo "--- runs: $(grep -c RESULT /tmp/pat/regress.log)  PASS: $(grep -cE 'RESULT +PASS' /tmp/pat/regress.log)  not-pass: $(grep -vcE 'RESULT +PASS' /tmp/pat/regress.log)"

#!/bin/bash
# usage: scripts/fuzz.sh <rtl.sv> [runs=40] [ncmds=200] [rand_init=1]
# random pattern seed, random profile style, random DRAM parameters (full demo range), optional random initial state
RTL=$(readlink -f "$1"); N=${2:-40}; NC=${3:-200}; RI=${4:-1}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p /tmp/fuzz
python3 $ROOT/model/gen_pattern.py /tmp/fuzz/warm 1 10 4 >/dev/null
if [ "$RI" = "1" ]; then RAND_INIT=1 $ROOT/scripts/sim.sh $RTL /tmp/fuzz/warm >/dev/null 2>&1; else $ROOT/scripts/sim.sh $RTL /tmp/fuzz/warm >/dev/null 2>&1; fi
one() {
  RTL=$1; ROOT=$2; i=$3; NC=$4; RI=$5
  RANDOM=$((i * 7919 + 13))
  seed=$((1000 + i)); mode=$((RANDOM % 6))
  R=$((1 + RANDOM % 100)); B=$((1 + RANDOM % 100)); W=$((RANDOM % 21)); A=$((RANDOM % 21)); G=$((RANDOM % 6)); O=$((RANDOM % 2))
  [ $((RANDOM % 4)) = 0 ] && { R=$((1 + RANDOM % 3)); B=$((1 + RANDOM % 3)); W=0; A=0; G=0; }
  d=/tmp/fuzz/f$i
  python3 $ROOT/model/gen_pattern.py $d $seed $NC $mode >/dev/null
  P="+DRAM_R_LATENCY=$R +DRAM_B_LATENCY=$B +DRAM_W_STALL=$W +DRAM_AR_AW_STALL=$A +DRAM_GAP=$G +DRAM_REORDER=$O +DRAM_SEED=$seed +PAT_SEED=$seed"
  if [ "$RI" = "1" ]; then out=$(RAND_INIT=$i $ROOT/scripts/sim.sh $RTL $d $P 2>&1 | grep -E "RESULT|DRAM-CHECK|PATTERN\]" | head -3)
  else out=$($ROOT/scripts/sim.sh $RTL $d $P 2>&1 | grep -E "RESULT|DRAM-CHECK|PATTERN\]" | head -3); fi
  echo "i=$i mode=$mode R=$R B=$B W=$W A=$A G=$G O=$O: $out"
}
export -f one
seq 1 $N | xargs -P $(nproc) -I{} bash -c 'one '"$RTL $ROOT"' {} '"$NC $RI" > /tmp/fuzz/fuzz.log
sort -V /tmp/fuzz/fuzz.log | grep -vE "RESULT +PASS" | head -20
echo "--- fuzz runs: $(grep -c RESULT /tmp/fuzz/fuzz.log)  PASS: $(grep -cE 'RESULT +PASS' /tmp/fuzz/fuzz.log)  of $N"

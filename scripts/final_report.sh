#!/bin/bash
# Re-runs everything for the comparison table: regression, fuzz, benchmark, area/timing proxy for v1..v5
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd $ROOT
OUT=docs/RESULTS_raw.txt; : > $OUT
for v in v1 v2 v3 v4 v5; do
  F=01_RTL/QME_$v.sv
  echo "##### $v" >> $OUT
  echo "[regress 12 seeds x 4 DRAM configs]" >> $OUT; scripts/regress.sh $F 12 250 2>&1 | tail -1 >> $OUT
  echo "[fuzz]" >> $OUT; scripts/fuzz.sh $F 60 250 1 2>&1 | tail -1 >> $OUT
  echo "[directed]" >> $OUT; scripts/sim.sh $F /tmp/dir1 2>&1 | grep RESULT >> $OUT
  echo "[bench]" >> $OUT; scripts/bench.sh $F 2>&1 | grep -E "^(min|mid|max)" >> $OUT
  echo "[synth]" >> $OUT; STA_TOP=1 scripts/synth_lib.sh $F ${v}final 800 2>&1 | grep -E "toy45|T_min|reg2reg|in2reg|reg2out" >> $OUT
done
echo done >> $OUT

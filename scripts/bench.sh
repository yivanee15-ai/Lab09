#!/bin/bash
# usage: scripts/bench.sh <rtl.sv> [label]  -- fixed benchmark (seeds 21..24, 250 cmds each) under 3 DRAM configs.
# Prints functional status and average latency (cycles/command) per action for each config.
RTL=$(readlink -f "$1"); ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p /tmp/bench
for s in 21 22 23 24; do [ -f /tmp/bench/s$s/ncmds.txt ] || python3 $ROOT/model/gen_pattern.py /tmp/bench/s$s $s 250 4 >/dev/null; done
$ROOT/scripts/sim.sh $RTL /tmp/bench/s21 >/dev/null 2>&1   # build once
declare -A CFG
CFG[min]="+DRAM_R_LATENCY=1 +DRAM_B_LATENCY=1 +DRAM_W_STALL=0 +DRAM_AR_AW_STALL=0 +DRAM_GAP=0 +DRAM_REORDER=0"
CFG[mid]="+DRAM_R_LATENCY=10 +DRAM_B_LATENCY=10 +DRAM_W_STALL=2 +DRAM_AR_AW_STALL=2 +DRAM_GAP=1 +DRAM_REORDER=1"
CFG[max]="+DRAM_R_LATENCY=100 +DRAM_B_LATENCY=100 +DRAM_W_STALL=20 +DRAM_AR_AW_STALL=20 +DRAM_GAP=5 +DRAM_REORDER=1"
for c in min mid max; do
  for s in 21 22 23 24; do
    ( $ROOT/scripts/sim.sh $RTL /tmp/bench/s$s ${CFG[$c]} +DRAM_SEED=$s +PAT_SEED=$s 2>&1 | grep -E "RESULT|DRAM-CHECK|PATTERN\]" | head -3 > /tmp/bench/out_${c}_$s.txt ) &
  done
  wait
done
python3 - <<'PY'
import re, glob
for c in ("min", "mid", "max"):
    tot = {k: [0, 0] for k in ("build", "train", "match", "query")}; ok = True; allsum = 0; n = 0
    for f in sorted(glob.glob("/tmp/bench/out_%s_*.txt" % c)):
        t = open(f).read()
        m = re.search(r"RESULT\s+(\w+).*?total_latency=(\d+).*?build=(\d+)/(\d+) train=(\d+)/(\d+) match=(\d+)/(\d+) query=(\d+)/(\d+)", t)
        if not m or m.group(1) != "PASS": ok = False; print(t); continue
        allsum += int(m.group(2)); n += 250
        for i, k in enumerate(tot): tot[k][0] += int(m.group(3 + 2 * i)); tot[k][1] += int(m.group(4 + 2 * i))
    print("%-4s %s total_latency=%d (avg %.2f/cmd)  build %.1f  train %.1f  match %.1f  query %.1f" % (
        c, "PASS" if ok else "FAIL", allsum, allsum / max(n, 1), *[tot[k][0] / max(tot[k][1], 1) for k in tot]))
PY

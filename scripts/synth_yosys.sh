#!/bin/bash
# usage: scripts/synth_yosys.sh <rtl.sv> [tag]   -> prints flops / GE / logic levels (relative metrics only)
RTL=$(readlink -f "$1"); TAG=${2:-$(basename "$RTL" .sv)}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=/tmp/synth/$TAG; mkdir -p $W
python3 $ROOT/scripts/flatten_inf.py $RTL $W/flat.v
cat > $W/run.ys <<YS
read_verilog -sv $W/flat.v
hierarchy -top QME
proc; flatten; opt_clean
synth -top QME -flatten
dfflegalize -cell \$_DFF_P_ 01 -cell \$_DFF_PN0_ 01 -cell \$_DFF_PN1_ 01 -cell \$_DFFE_PP_ 01 -cell \$_DFFE_PN0P_ 01 -cell \$_DFFE_PN1P_ 01 -cell \$_SDFF_PN0_ 01
abc -g AND,NAND,OR,NOR,XOR,XNOR,ANDNOT,ORNOT,MUX
opt_clean
tee -o $W/stat.txt stat
ltp -noff
YS
yosys -q -l $W/yosys.log $W/run.ys >/dev/null 2>&1 || { echo "yosys failed, see $W/yosys.log"; tail -15 $W/yosys.log; exit 1; }
python3 - $W <<'PY'
import re, sys
W = sys.argv[1]
st = open(W + "/stat.txt").read()
cnt = {}
for m in re.finditer(r"^\s+(\$_\w+_)\s+(\d+)\s*$", st, re.M):
    cnt[m.group(1)] = int(m.group(2))
w = {"$_NOT_": 0.67, "$_AND_": 1.33, "$_NAND_": 1.0, "$_OR_": 1.33, "$_NOR_": 1.0, "$_XOR_": 2.0, "$_XNOR_": 2.0,
     "$_ANDNOT_": 1.33, "$_ORNOT_": 1.33, "$_MUX_": 2.33}
dff = sum(v for k, v in cnt.items() if "DFF" in k)
dffe = sum(v for k, v in cnt.items() if "DFFE" in k)
ge_logic = sum(cnt.get(k, 0) * x for k, x in w.items())
ge_ff = sum(v * (6.7 if ("PN0" in k or "PN1" in k) else 5.7) + (v * 2.3 if "DFFE" in k else 0) for k, v in cnt.items() if "DFF" in k)
log = open(W + "/yosys.log").read()
m = re.findall(r"Longest topological path in \S+ \(length=(\d+)\)", log)
lv = int(m[-1]) if m else -1
print("flops=%d (enable-type=%d)  logic_GE=%.0f  flop_GE=%.0f  TOTAL_GE=%.0f  logic_levels=%d" % (dff, dffe, ge_logic, ge_ff, ge_logic + ge_ff, lv))
PY

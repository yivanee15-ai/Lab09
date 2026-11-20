#!/bin/bash
# usage: scripts/ablate.sh <rtl.sv> : area when individual features are tied off (rough area breakdown)
RTL=$(readlink -f "$1"); ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=/tmp/synth/abl; mkdir -p $W
python3 $ROOT/scripts/flatten_inf.py $RTL $W/flat0.v
run() {  # name sed-expression
  sed -E "$2" $W/flat0.v > $W/flat.v
  cat > $W/lib.ys <<YS
read_verilog -sv $W/flat.v
hierarchy -top QME
proc; flatten; opt_clean
synth -top QME -flatten -run :fine
opt -fast -full
memory_map
opt -full
techmap -map +/techmap.v -map $ROOT/scripts/ks_lcu.v
opt -fast
abc -fast
opt -fast
dfflegalize -cell \$_DFF_P_ 01 -cell \$_DFF_PN0_ 01 -cell \$_DFF_PN1_ 01
dfflibmap -liberty $ROOT/scripts/toy45.lib
opt_clean
abc -liberty $ROOT/scripts/toy45.lib
opt_clean
tee -o $W/stat.txt stat -liberty $ROOT/scripts/toy45.lib
YS
  yosys -q $W/lib.ys >/dev/null 2>&1
  A=$(grep "Chip area" $W/stat.txt | tail -1 | awk '{print $NF}')
  F=$(grep -E "DFF" $W/stat.txt | awk '{s+=$2} END {print s}')
  printf "%-34s area=%9.1f  flops=%d\n" "$1" "$A" "$F"
}
run "baseline" 's/XXXX_NONE/x/'
run "no Build  (l_bld=0)"      's/^(\s*wire\s+l_bld\s*=).*;/\1 1'"'"'b0;/'
run "no Query  (l_pair=0)"     's/^(\s*wire\s+l_pair\s*=).*;/\1 1'"'"'b0;/'
run "no Training (l_proft=0)"  's/^(\s*wire\s+l_proft\s*=).*;/\1 1'"'"'b0;/'
run "no Match profiles"        's/^(\s*wire\s+\[13:0\]\s+oh_cur\s*=).*;/\1 14'"'"'d0;/'

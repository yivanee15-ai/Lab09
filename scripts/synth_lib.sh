#!/bin/bash
# usage: scripts/synth_lib.sh <rtl.sv> [tag] [clock_ps=2500]
# yosys + abc timing-driven mapping onto scripts/toy45.lib.  Reports area (um^2, toy library) and the longest
# register-to-register/IO combinational delay found by abc.  Relative comparison between versions only.
RTL=$(readlink -f "$1"); TAG=${2:-$(basename "$RTL" .sv)}; DPS=${3:-2500}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=/tmp/synth/$TAG; mkdir -p $W
python3 $ROOT/scripts/flatten_inf.py $RTL $W/flat.v
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
abc -liberty $ROOT/scripts/toy45.lib -D $DPS
opt_clean
tee -o $W/stat_lib.txt stat -liberty $ROOT/scripts/toy45.lib
write_verilog -noattr -noexpr $W/mapped.v
YS
yosys -l $W/yosys_lib.log $W/lib.ys >/dev/null 2>&1 || { echo "yosys failed, see $W/yosys_lib.log"; tail -15 $W/yosys_lib.log; exit 1; }
AREA=$(grep -E "Chip area" $W/stat_lib.txt | tail -1 | awk '{print $NF}')
NFF=$(grep -E "DFF" $W/stat_lib.txt | awk '{s+=$2} END {print s}')
DELAY=$(grep -oE "Delay = +[0-9.]+ ps" $W/yosys_lib.log | tail -1 | grep -oE "[0-9.]+")
echo "toy45: area=${AREA} um2  flops=${NFF}"
python3 $ROOT/scripts/sta.py $W/mapped.v ${STA_TOP:-2}

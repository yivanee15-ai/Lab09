#!/usr/bin/env python3
"""Turn a QME.sv written against INF.QME into a flat-port Verilog file that yosys can read.
usage: flatten_inf.py in.sv out.v"""
import re, sys
src = open(sys.argv[1]).read()
ins = ["rst_n", "in_valid_action", "in_valid_date", "in_valid_team", "in_valid_option", "[8:0] D",
       "AR_READY", "[1:0] R_ID", "[127:0] R_DATA", "[1:0] R_RESP", "R_LAST", "R_VALID",
       "AW_READY", "W_READY", "[1:0] B_ID", "[1:0] B_RESP", "B_VALID"]
outs = ["out_valid", "complete", "[2:0] warn_msg", "[127:0] out_info",
        "[1:0] AR_ID", "[16:0] AR_ADDR", "[7:0] AR_LEN", "[2:0] AR_SIZE", "[1:0] AR_BURST", "AR_VALID", "R_READY",
        "[1:0] AW_ID", "[16:0] AW_ADDR", "[7:0] AW_LEN", "[2:0] AW_SIZE", "[1:0] AW_BURST", "AW_VALID",
        "[127:0] W_DATA", "[15:0] W_STRB", "W_LAST", "W_VALID", "B_READY"]
hdr = "module QME (input clk,\n" + ",\n".join("  input  " + i for i in ins) + ",\n" + \
      ",\n".join("  output reg " + o for o in outs) + ");\n"
src = re.sub(r"module\s+QME\s*\(.*?\);\s*\n", lambda m: hdr, src, count=1, flags=re.S)
src = src.replace("inf.", "")
# remove translate-off style content
open(sys.argv[2], "w").write(src)

# Template Design Compiler script (NOT run here: no DC / cell library in the development container).
# Constraints follow the spec: input/output delay 0.5 x clock period, output load 0.05, async active-low reset.
set CYCLE 15.0                      ;# <- put the period you pass to ./01_submit
set DESIGN QME
read_sverilog -rtl ../01_RTL/QME.sv   ;# interface INF comes from ../00_TESTBED/INF.sv
analyze -format sverilog {../00_TESTBED/INF.sv ../01_RTL/QME.sv}
elaborate $DESIGN
current_design $DESIGN
link
create_clock -name clk -period $CYCLE [get_ports clk]
set_dont_touch_network [get_clocks clk]
set_ideal_network [get_ports clk]
set_input_delay  [expr $CYCLE * 0.5] -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay [expr $CYCLE * 0.5] -clock clk [all_outputs]
set_load 0.05 [all_outputs]
set_max_delay $CYCLE -from [all_inputs] -to [all_outputs]
compile_ultra            ;# or: compile -map_effort high
report_area  > Report/$DESIGN.area
report_timing > Report/$DESIGN.timing
write -format verilog -hierarchy -output ../02_SYN/Netlist/${DESIGN}_SYN.v
write_sdf -version 3.0 ../02_SYN/Netlist/${DESIGN}_SYN.sdf

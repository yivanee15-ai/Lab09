`timescale 1ns/1ps
`include "INF.sv"
`include "Usertype.sv"
`include "pseudo_DRAM.sv"
`include "PATTERN.sv"
`ifdef GATE
  `include "QME_SYN.v"
`else
  `include "QME.sv"
`endif

module TESTBED;
  parameter real CYCLE = 15.0;
  logic clk;
  INF inf();
  initial clk = 0;
  always #(CYCLE/2.0) clk = ~clk;

  QME      u_qme  (.clk(clk), .inf(inf.QME));
  pseudo_DRAM u_dram (.clk(clk), .inf(inf.DRAM));
  PATTERN  u_pat  (.clk(clk), .inf(inf.PATTERN));
endmodule

`ifndef INF_SV
`define INF_SV
// Stand-in for the TA-provided INF.sv (same signal list as the spec).
interface INF;
  logic        rst_n;
  logic        in_valid_action, in_valid_date, in_valid_team, in_valid_option;
  logic [8:0]  D;
  logic        out_valid, complete;
  logic [2:0]  warn_msg;
  logic [127:0] out_info;
  // AXI4 read address
  logic [1:0]  AR_ID;  logic [16:0] AR_ADDR; logic [7:0] AR_LEN; logic [2:0] AR_SIZE; logic [1:0] AR_BURST;
  logic        AR_VALID, AR_READY;
  // AXI4 read data
  logic [1:0]  R_ID;   logic [127:0] R_DATA; logic [1:0] R_RESP; logic R_LAST, R_VALID, R_READY;
  // AXI4 write address
  logic [1:0]  AW_ID;  logic [16:0] AW_ADDR; logic [7:0] AW_LEN; logic [2:0] AW_SIZE; logic [1:0] AW_BURST;
  logic        AW_VALID, AW_READY;
  // AXI4 write data
  logic [127:0] W_DATA; logic [15:0] W_STRB; logic W_LAST, W_VALID, W_READY;
  // AXI4 write response
  logic [1:0]  B_ID, B_RESP; logic B_VALID, B_READY;

  modport QME (
    input  rst_n, in_valid_action, in_valid_date, in_valid_team, in_valid_option, D,
    output out_valid, complete, warn_msg, out_info,
    output AR_ID, AR_ADDR, AR_LEN, AR_SIZE, AR_BURST, AR_VALID, input AR_READY,
    input  R_ID, R_DATA, R_RESP, R_LAST, R_VALID, output R_READY,
    output AW_ID, AW_ADDR, AW_LEN, AW_SIZE, AW_BURST, AW_VALID, input AW_READY,
    output W_DATA, W_STRB, W_LAST, W_VALID, input W_READY,
    input  B_ID, B_RESP, B_VALID, output B_READY);

  modport DRAM (
    input  rst_n,
    input  AR_ID, AR_ADDR, AR_LEN, AR_SIZE, AR_BURST, AR_VALID, output AR_READY,
    output R_ID, R_DATA, R_RESP, R_LAST, R_VALID, input R_READY,
    input  AW_ID, AW_ADDR, AW_LEN, AW_SIZE, AW_BURST, AW_VALID, output AW_READY,
    input  W_DATA, W_STRB, W_LAST, W_VALID, output W_READY,
    output B_ID, B_RESP, B_VALID, input B_READY);

  modport PATTERN (
    output rst_n, in_valid_action, in_valid_date, in_valid_team, in_valid_option, D,
    input  out_valid, complete, warn_msg, out_info,
    input  AR_ID, AR_ADDR, AR_LEN, AR_SIZE, AR_BURST, AR_VALID, AR_READY,
    input  R_ID, R_DATA, R_RESP, R_LAST, R_VALID, R_READY,
    input  AW_ID, AW_ADDR, AW_LEN, AW_SIZE, AW_BURST, AW_VALID, AW_READY,
    input  W_DATA, W_STRB, W_LAST, W_VALID, W_READY,
    input  B_ID, B_RESP, B_VALID, B_READY);
endinterface
`endif

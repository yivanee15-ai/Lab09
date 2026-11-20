`ifndef USERTYPE_SV
`define USERTYPE_SV
// Stand-in for the TA-provided Usertype.sv.
package usertype;
  typedef enum logic [1:0] {Build_Team = 2'd0, Training = 2'd1, Match = 2'd2, Query = 2'd3} Action;
  typedef enum logic [2:0] {No_Warn = 3'b000, Date_Warn = 3'b001, Team_Warn = 3'b010,
                            Roster_Warn = 3'b011, Option_Warn = 3'b100, Exp_Warn = 3'b101,
                            Saturation_Warn = 3'b111} Warn_Msg;
  typedef logic [8:0] Data;
endpackage
`endif

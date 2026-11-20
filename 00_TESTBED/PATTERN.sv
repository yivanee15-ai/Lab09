`ifndef PATTERN_SV
`define PATTERN_SV
// Self-checking pattern.  Reads <PAT_DIR>/{cmd.txt,exp.txt,golden_dram.dat} made by model/gen_pattern.py.
// Drives inputs and samples outputs on the falling edge (values are stable between rising edges, so a
// falling-edge sample equals the value the rising edge would see, without any race).
module PATTERN (input logic clk, INF.PATTERN inf);
  string pat_dir = ".";
  int ncmd, nerr = 0, ncyc = 0, verbose = 0;
  int fc, fe;
  // expected data of current command
  int e_act, e_complete, e_warn, e_nr, e_nw, e_haspair;
  logic [127:0] e_info;
  int e_rd [0:31]; int e_wr [0:31]; int e_pair;
  // observed AXI beats of the current command
  int o_rd [0:63]; int o_wr [0:63]; int n_ord, n_owr;
  bit inputs_done = 0, got_out = 0;
  int n_last = 0, lat_cur = 0;
  longint lat_sum [0:3]; int lat_cnt [0:3]; int lat_max = 0; longint lat_total = 0;
  logic [31:0] prs = 32'hC0FFEE11;

  function automatic int unsigned prnd(); prs = prs ^ (prs << 13); prs = prs ^ (prs >> 17); prs = prs ^ (prs << 5); return prs; endfunction
  task automatic err(input string s);
    nerr++;
    if (nerr < 30) $display("[PATTERN] cmd#%0d (act %0d) t=%0d : %s", cmd_i, e_act, ncyc, s);
  endtask
  int cmd_i = 0;

  task automatic check_outputs_cmd();
    int used [0:63];
    int n_exp_rd, n_exp_wr, k;
    bit found;
    // ---------- all AXI must be finished
    if (TESTBED.u_dram.nrd != 0 || TESTBED.u_dram.nwr != 0 || TESTBED.u_dram.awq_n != 0)
      err("out_valid raised while AXI transactions still outstanding");
    // ---------- results
    if (inf.complete !== e_complete[0]) err($sformatf("complete %b expected %0d", inf.complete, e_complete));
    if (inf.warn_msg !== e_warn[2:0])   err($sformatf("warn_msg %0d expected %0d", inf.warn_msg, e_warn));
    if (inf.out_info !== e_info)        err($sformatf("out_info %h expected %h", inf.out_info, e_info));
    // ---------- AXI request set: reads
    n_exp_rd = 0;
    for (int i = 0; i < e_nr; i++) begin
      if (e_act == 0) n_exp_rd += 1; // build: expected list holds 4 base addrs; expanded below
      else n_exp_rd += 1;
    end
    // expand expected reads (build: 4 base addrs of 4 beats -> 16 beats; others single beats)
    begin
      int er [0:63]; int ne = 0;
      for (int i = 0; i < e_nr; i++) begin
        if (e_act == 0) for (int b = 0; b < 4; b++) begin er[ne] = e_rd[i] + 16 * b; ne++; end
        else begin er[ne] = e_rd[i]; ne++; end
      end
      if (ne != n_ord) err($sformatf("read beats observed %0d expected %0d", n_ord, ne));
      if (verbose > 1) begin $write("   obs_rd:"); for (int i = 0; i < n_ord; i++) $write(" %h", o_rd[i]); $write("\n   exp_rd:"); for (int i = 0; i < ne; i++) $write(" %h", er[i]); $write("\n"); end
      else begin
        for (int i = 0; i < 64; i++) used[i] = 0;
        for (int i = 0; i < ne; i++) begin
          found = 0;
          for (int j = 0; j < n_ord; j++) if (!used[j] && !found && o_rd[j] == er[i]) begin used[j] = 1; found = 1; end
          if (!found) err($sformatf("expected read of %h never issued", er[i]));
        end
        if (e_act == 2) begin // fixed profile order: Home slot0..6 then Away slot0..6
          k = 0;
          for (int j = 0; j < n_ord; j++) if (o_rd[j] < 'h10400) begin
            if (k < 14 && o_rd[j] != er[2 + k]) err($sformatf("profile read #%0d is %h expected %h", k, o_rd[j], er[2 + k]));
            k++;
          end
        end
      end
    end
    // ---------- writes
    begin
      int ew [0:63]; int ne = 0;
      for (int i = 0; i < e_nw; i++) begin ew[ne] = e_wr[i]; ne++; end
      if (e_haspair) begin ew[ne] = e_pair; ne++; end
      if (ne != n_owr) err($sformatf("write beats observed %0d expected %0d", n_owr, ne));
      else begin
        for (int i = 0; i < 64; i++) used[i] = 0;
        for (int i = 0; i < ne; i++) begin
          found = 0;
          for (int j = 0; j < n_owr; j++) if (!used[j] && !found && o_wr[j] == ew[i]) begin used[j] = 1; found = 1; end
          if (!found) err($sformatf("expected write of %h never issued", ew[i]));
        end
        if (e_act == 2) begin
          k = 0;
          for (int j = 0; j < n_owr; j++) if (o_wr[j] < 'h10400) begin
            if (k < 14 && o_wr[j] != e_wr[k]) err($sformatf("profile write #%0d is %h expected %h", k, o_wr[j], e_wr[k]));
            k++;
          end
        end
      end
    end
  endtask

  // ------------------------------------------------------------------ per-negedge monitor
  bit mon_en = 0;
  task automatic monitor();
    if (!mon_en) return;
    if (!inf.out_valid && (inf.complete !== 0 || inf.warn_msg !== 0 || inf.out_info !== 0))
      err("complete/warn_msg/out_info not zero while out_valid is low");
    if (!inputs_done && (inf.AR_VALID || inf.AW_VALID || inf.W_VALID))
      err("AXI VALID asserted although the last input of the command has not been received (or command is over)");
    if (inputs_done && inf.AR_VALID && inf.AR_READY)
      for (int b = 0; b <= inf.AR_LEN; b++) begin if (n_ord < 64) o_rd[n_ord] = inf.AR_ADDR + 16 * b; n_ord++; end
    if (inputs_done && inf.AW_VALID && inf.AW_READY)
      for (int b = 0; b <= inf.AW_LEN; b++) begin if (n_owr < 64) o_wr[n_owr] = inf.AW_ADDR + 16 * b; n_owr++; end
    if (inf.out_valid) begin
      if (!inputs_done) err("out_valid raised with no command pending (or longer than one cycle)");
      else begin
        lat_cur = ncyc - n_last;
        got_out = 1; inputs_done = 0;
        check_outputs_cmd();
        lat_sum[e_act] += lat_cur; lat_cnt[e_act]++; lat_total += lat_cur;
        if (lat_cur > lat_max) lat_max = lat_cur;
        if (lat_cur > 2500) err("latency over 2500");
        if (verbose) $display("  cmd#%0d act=%0d latency=%0d warn=%0d", cmd_i, e_act, lat_cur, inf.warn_msg);
      end
    end
  endtask

  task automatic tick();
    @(negedge clk);
    ncyc++;
    monitor();
  endtask

  task automatic idle(input int n); for (int i = 0; i < n; i++) tick(); endtask
  task automatic gap25(); idle(2 + prnd() % 4); endtask

  // one valid pulse
  task automatic pulse_action(input logic [1:0] a);  inf.in_valid_action = 1; inf.D = {7'b0, a}; tick(); inf.in_valid_action = 0; inf.D = 0; endtask
  task automatic pulse_date(input logic [8:0] d);    inf.in_valid_date = 1;   inf.D = d;          tick(); inf.in_valid_date = 0;   inf.D = 0; endtask
  task automatic pulse_team(input logic [1:0] t);    inf.in_valid_team = 1;   inf.D = {7'b0, t};  tick(); inf.in_valid_team = 0;   inf.D = 0; endtask
  task automatic pulse_option(input logic [6:0] o);  inf.in_valid_option = 1; inf.D = {2'b0, o};  tick(); inf.in_valid_option = 0; inf.D = 0; endtask

  // last pulse: remember the cycle in which it is driven (sampled by the DUT at the next rising edge)
  task automatic last_mark(); n_last = ncyc; inputs_done = 1; got_out = 0; n_ord = 0; n_owr = 0; endtask

  int a_i, date_i, t1_i, t2_i, opt_i, rr;
  string tok;
  logic [31:0] hx;

  initial begin
    for (int i = 0; i < 4; i++) begin lat_sum[i] = 0; lat_cnt[i] = 0; end
    void'($value$plusargs("PAT_DIR=%s", pat_dir));
    void'($value$plusargs("VERBOSE=%d", verbose));
    begin int sd; if ($value$plusargs("PAT_SEED=%d", sd)) prs = prs ^ (sd * 32'h85EBCA6B); if (prs == 0) prs = 1; end
    fc = $fopen({pat_dir, "/cmd.txt"}, "r");
    fe = $fopen({pat_dir, "/exp.txt"}, "r");
    begin int fn = $fopen({pat_dir, "/ncmds.txt"}, "r"); rr = $fscanf(fn, "%d", ncmd); $fclose(fn); end
    inf.rst_n = 1; inf.in_valid_action = 0; inf.in_valid_date = 0; inf.in_valid_team = 0; inf.in_valid_option = 0; inf.D = 0;
    #1; inf.rst_n = 0;
    #20; inf.rst_n = 1;
    @(negedge clk); ncyc++;
    // outputs must be zero after reset
    if (inf.out_valid || inf.complete || inf.warn_msg || inf.out_info || inf.AR_VALID || inf.AW_VALID || inf.W_VALID)
      err("outputs not zero after reset");
    mon_en = 1;
    idle(3);
    for (cmd_i = 0; cmd_i < ncmd; cmd_i++) begin
      rr = $fscanf(fc, "%d %h %d %d %h", a_i, date_i, t1_i, t2_i, opt_i);
      rr = $fscanf(fe, "%d %d %h %d", e_complete, e_warn, e_info, e_nr);
      if (e_nr > 0) for (int i = 0; i < e_nr; i++) rr = $fscanf(fe, "%h", e_rd[i]); else rr = $fscanf(fe, "%s", tok);
      rr = $fscanf(fe, "%d", e_nw);
      if (e_nw > 0) for (int i = 0; i < e_nw; i++) rr = $fscanf(fe, "%h", e_wr[i]); else rr = $fscanf(fe, "%s", tok);
      rr = $fscanf(fe, "%d %h", e_haspair, e_pair);
      e_act = a_i;
      gap25();
      case (a_i)
        0: begin pulse_action(2'd0); gap25(); last_mark(); pulse_team(t1_i[1:0]); end
        1: begin pulse_action(2'd1); gap25(); pulse_team(t1_i[1:0]); gap25(); last_mark(); pulse_option(opt_i[6:0]); end
        default: begin
          pulse_action(a_i[1:0]); gap25(); pulse_date(date_i[8:0]); gap25(); pulse_team(t1_i[1:0]); gap25();
          last_mark(); pulse_team(t2_i[1:0]);
        end
      endcase
      // wait for the response (monitor() handles everything)
      while (!got_out) begin
        tick();
        if (ncyc - n_last > 2600) begin err("timeout waiting for out_valid"); got_out = 1; inputs_done = 0; end
      end
      if (nerr > 0 && nerr >= 30) begin $display("too many mismatches, abort"); break; end
    end
    idle(20);
    check_dram();
    $display("RESULT %s errors=%0d cmds=%0d total_latency=%0d avg=%0.2f max=%0d | build=%0d/%0d train=%0d/%0d match=%0d/%0d query=%0d/%0d",
             (nerr == 0 && TESTBED.u_dram.errors == 0) ? "PASS" : "FAILED", nerr + TESTBED.u_dram.errors, ncmd, lat_total,
             real'(lat_total) / real'(ncmd > 0 ? ncmd : 1), lat_max,
             lat_sum[0], lat_cnt[0], lat_sum[1], lat_cnt[1], lat_sum[2], lat_cnt[2], lat_sum[3], lat_cnt[3]);
    $finish;
  end

  // ------------------------------------------------------------------ final DRAM image check
  task automatic check_dram();
    int fg, a, nbad = 0;
    logic [127:0] g, v;
    fg = $fopen({pat_dir, "/golden_dram.dat"}, "r");
    while (!$feof(fg)) begin
      rr = $fscanf(fg, "%h %h", a, g);
      if (rr == 2) begin
        for (int i = 0; i < 16; i++) v[8*i +: 8] = TESTBED.u_dram.mem[a + i];
        if (v !== g) begin nbad++; if (nbad < 5) $display("[PATTERN] DRAM mismatch @%05h got %h exp %h", a, v, g); end
      end
    end
    $fclose(fg);
    for (int i = 0; i < 131072; i++) if ((i < 'h10000 || (i >= 'h10400 && i < 'h10500) || (i >= 'h10540 && i < 'h10800) || i >= 'h108C0) && TESTBED.u_dram.mem[i] !== 8'h00) begin
      nbad++; if (nbad < 5) $display("[PATTERN] DRAM byte outside legal ranges modified @%05h", i);
    end
    if (nbad) err($sformatf("final DRAM compare: %0d mismatches", nbad));
  endtask
endmodule
`endif

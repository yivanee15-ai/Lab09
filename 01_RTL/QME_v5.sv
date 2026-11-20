// QME v5 : v4 + polish (Query in 2 compute stages, out_info driven from existing registers, data regs without reset).
// QME v4 : area oriented.  v3 micro-architecture, but every per-command scratch register file
//          (Build lists / capture / selection, Training delta+sum stages, Query record + date math)
//          now lives inside the 14 x 64 bit Match profile store 'pm', which is idle in those commands.
// (v3 header follows)
// QME v3 : cycle-time oriented (same architecture as v2, restructured for short logic depth)
//  * one-hot command flags, state cleared while idle (no big fan-out from the last input valid)
//  * input side paths (R_*, B_*, *_READY) only go through a few gates: one-hot entry tag per ID,
//    registered "last read" / "last write" predictors, no same-cycle ID re-use
//  * AW trigger comes from registered events (Match/Training) or from a guaranteed-valid test (Build)
//  * Match derived values : 3-stage free-running pipeline, result stage released by a countdown that
//    knows how deep each profile slot is (E = last landing + 2 for the usual in-order case)
//  * Training : 3 compute stages, Query : 3 compute stages
module QME (input logic clk, INF.QME inf);

  localparam [2:0] W_NONE = 3'b000, W_DATE = 3'b001, W_TEAM = 3'b010, W_ROSTER = 3'b011,
                   W_OPT = 3'b100, W_EXP = 3'b101, W_SAT = 3'b111;

  // =============================================================== helper functions
  function automatic [3:0] nib(input [27:0] c, input [2:0] s);
    nib = c[27 - 4*s -: 4];
  endfunction
  function automatic [3:0] pairidx(input [1:0] h, input [1:0] a);
    pairidx = {2'b00, h} * 4'd3 + ((a < h) ? {2'b00, a} : ({2'b00, a} - 4'd1));
  endfunction
  function automatic [8:0] cum_f(input [3:0] m);          // days before month m (non leap year)
    logic [8:0] a;
    logic [4:0] sub;
    begin
      a   = ({5'd0, m} - 9'd1) * 9'd31;
      sub = (m <= 4'd2) ? 5'd0 : (m <= 4'd8) ? ({1'b0, m} + 5'd3) >> 1 : ({1'b0, m} + 5'd2) >> 1;
      cum_f = a - {4'd0, sub};
    end
  endfunction
  function automatic [7:0] lfsr(input [7:0] x);
    lfsr = {x[6:0], x[7] ^ x[5] ^ x[4] ^ x[3]};
  endfunction
  function automatic [16:0] inc2048(input [15:0] v);
    inc2048 = (&v[15:11]) ? {1'b1, 16'hFFFF} : {1'b0, v[15:11] + 5'd1, v[10:0]};
  endfunction
  function automatic [16:0] dec2048(input [15:0] v);
    dec2048 = (~|v[15:11]) ? {1'b1, 16'h0000} : {1'b0, v[15:11] - 5'd1, v[10:0]};
  endfunction
  function automatic [16:0] dec1024(input [15:0] v);
    dec1024 = (~|v[15:10]) ? {1'b1, 16'h0000} : {1'b0, v[15:10] - 6'd1, v[9:0]};
  endfunction

  // =============================================================== input capture
  logic       is_build, is_train, is_match, is_query;      // one-hot action
  logic [1:0] tm1, tm2;
  logic [3:0] month;
  logic [4:0] day;
  logic [6:0] opt;
  logic       got_t1;
  wire        is_tm = is_train | is_match;
  wire        is_mq = is_match | is_query;

  wire lastv_team   = inf.in_valid_team && (is_build || (got_t1 && is_mq));
  wire lastv_option = inf.in_valid_option;
  wire early_team   = lastv_team && is_mq && (inf.D[1:0] == tm1);
  wire early_opt    = lastv_option && ((inf.D[6:4] == 3'd7) || (inf.D[1:0] == 2'd3));
  wire early        = early_team | early_opt;
  wire start        = (lastv_team | lastv_option) & ~early;

  always_ff @(posedge clk or negedge inf.rst_n) begin
    if (!inf.rst_n) begin
      is_build <= 1'b1; is_train <= 1'b0; is_match <= 1'b0; is_query <= 1'b0;
      tm1 <= '0; tm2 <= '0; month <= '0; day <= '0; opt <= '0; got_t1 <= 1'b0;
    end else begin
      if (inf.in_valid_action) begin
        is_build <= (inf.D[1:0] == 2'd0); is_train <= (inf.D[1:0] == 2'd1);
        is_match <= (inf.D[1:0] == 2'd2); is_query <= (inf.D[1:0] == 2'd3);
        got_t1 <= 1'b0;
      end
      if (inf.in_valid_date) begin month <= inf.D[8:5]; day <= inf.D[4:0]; end
      if (inf.in_valid_team) begin
        if (!got_t1) tm1 <= inf.D[1:0]; else tm2 <= inf.D[1:0];
        got_t1 <= ~got_t1;
      end
      if (inf.in_valid_option) opt <= inf.D[6:0];
    end
  end

  // free-running date derived values (static long before they are needed)
  logic [8:0] doy_t, cum_t;
  logic [7:0] r1r, r2r;
  logic [9:0] d365_r;
  logic [7:0] seed_c;
  always_comb begin
    logic [7:0] s0;
    s0 = doy_t[7:0] ^ {6'b0, tm1} ^ {4'b0, tm2, 2'b0};
    seed_c = (s0 == 8'd0) ? 8'd1 : s0;
  end
  always_ff @(posedge clk) begin
    cum_t  <= cum_f(month);
    doy_t  <= cum_t + {4'd0, day};
    r1r    <= lfsr(seed_c);
    r2r    <= lfsr(lfsr(seed_c));
    d365_r <= {1'b0, doy_t} + 10'd365;
  end

  // =============================================================== run control
  logic        run;
  logic [4:0]  ri;                           // next read to issue
  wire  [4:0]  nrd = is_build ? 5'd4 : is_train ? 5'd2 : is_match ? 5'd16 : 5'd1;
  wire  [4:0]  nwr = is_match ? 5'd15 : 5'd1;

  // ---- read side
  logic        ar_valid;
  logic [1:0]  ar_id;
  logic [16:0] ar_addr;
  logic [3:0]  rbusy;
  logic [7:0]  rtag_b;                       // Build : burst number per ID
  logic [55:0] ohr;                          // one-hot profile entry per ID
  logic [1:0]  rbeat;
  logic        rdy;
  logic [27:0] cH, cA;
  logic        hH, hA;
  logic [4:0]  rleft;                        // reads still to land
  logic        lp;                           // rleft == 1
  logic        rd_all;

  wire         r_last = inf.R_VALID & inf.R_LAST;
  wire         drained_now = r_last & lp;
  wire [13:0]  oh_cur = ohr[14*inf.R_ID +: 14];
  wire         l_ctxH = inf.R_VALID & is_tm & (inf.R_ID == 2'd0) & ~hH;
  wire         l_ctxA = inf.R_VALID & is_match & (inf.R_ID == 2'd1) & ~hA;
  wire         l_proft = inf.R_VALID & is_train & hH;
  wire         l_pair  = inf.R_VALID & is_query;
  wire         l_bld   = inf.R_VALID & is_build;
  wire         l_profm = inf.R_VALID & (|oh_cur);       // a profile lands (entry one-hot is non zero)

  wire [3:0]  rfree   = ~rbusy;
  wire        r_any_r = |rfree;
  wire        r_any   = r_any_r | r_last;                 // an ID that is released by this very beat may be re-used
  wire [1:0]  r_newid = r_any_r ? (rfree[0] ? 2'd0 : rfree[1] ? 2'd1 : rfree[2] ? 2'd2 : 2'd3) : inf.R_ID;

  // dependency of the next read on a context beat, pid from registers or from the beat that lands now
  wire        need_H  = is_train | (is_match & (ri >= 5'd2) & (ri < 5'd9));
  wire        need_A  = is_match & (ri >= 5'd9);
  wire        dep_reg = (~need_H | hH) & (~need_A | hA);
  wire [2:0]  idxH = is_train ? opt[6:4] : (ri[2:0] - 3'd2);
  wire [2:0]  idxA = ri[2:0] - 3'd1;
  logic [16:0] addr_reg;
  logic [13:0] n_oh;
  always_comb begin
    logic [3:0] pidr;
    logic [1:0] tmr;
    pidr = need_A ? nib(cA, idxA) : nib(cH, idxH);
    tmr  = need_A ? tm2 : tm1;
    case (1'b1)
      is_build: addr_reg = {7'b1000000, tm1, ri[1:0], 6'd0};
      is_train: addr_reg = {7'b1000000, tm1, pidr, 4'd0};
      is_match: begin
        if (ri == 5'd1) addr_reg = {1'b1, 5'd0, 1'b1, 1'b0, 1'b1, 2'b00, tm2, 4'd0};
        else addr_reg = {7'b1000000, tmr, pidr, 4'd0};
      end
      default:  addr_reg = {1'b1, 4'd0, 1'b1, 3'd0, pairidx(tm1, tm2), 4'd0};
    endcase
    n_oh = is_train ? 14'd1 : is_build ? (14'd1 << 13) : is_query ? (14'd1 << 12) :
           (is_match && ri >= 5'd2) ? (14'd1 << (ri[3:0] - 4'd2)) : 14'd0;
  end
  // address of read #0 : taken in the cycle of the last input valid
  wire [16:0] addr0 = is_build ? {7'b1000000, inf.D[1:0], 2'b00, 6'd0} :
                      is_query ? {1'b1, 4'd0, 1'b1, 3'd0, pairidx(tm1, inf.D[1:0]), 4'd0} :
                                 {1'b1, 5'd0, 1'b1, 1'b0, 1'b1, 2'b00, tm1, 4'd0};

  wire ar_base     = run & (ri < nrd) & (~ar_valid | inf.AR_READY) & r_any;
  wire ar_load_run = ar_base & dep_reg;

  // =============================================================== storage
  // pm : unified scratch store, 14 entries x 64 bit.  Entry layout (MSB..LSB) {A, D, S, E} of a profile beat.
  //   Match    : entry e holds profile slot e (Home 0..6, Away 0..6)
  //   Training : entry 0 holds the profile; Δ / sum pipeline registers live at TD / TX
  //   Query    : entry 12 holds the pair record beat; date math registers live at QC / QR / QR2
  //   Build    : entry 13 holds the beat that just landed; top-N lists at LD_*/LS_*/LA_*; selection regs at T1R.. / FREG
  localparam LD_VAL = 64,  LD_ID = 128, LS_VAL = 144, LS_ID = 176, LA_VAL = 184, LA_ID = 296,
             T1R = 324, T2R = 341, FREG = 358;
  localparam TD = 448, TX = 496;
  localparam QC = 448, QB = 457, QB2 = 467, QR = 477, QR2 = 487;
  logic [895:0] pm;
  wire  [223:0] pmA, pmD, pmS, pmE;
  genvar ge;
  generate
    for (ge = 0; ge < 14; ge++) begin : g_pm
      assign pmA[16*ge +: 16] = pm[64*ge+48 +: 16];
      assign pmD[16*ge +: 16] = pm[64*ge+32 +: 16];
      assign pmS[16*ge +: 16] = pm[64*ge+16 +: 16];
      assign pmE[16*ge +: 16] = pm[64*ge    +: 16];
    end
  endgenerate

  // Query record = pm entry 12 (top 64 bits of the beat), date math registers at QC / QR / QR2
  wire [63:0] qrec   = pm[64*12 +: 64];
  wire [1:0]  pr_res = qrec[63:62];
  wire [3:0]  pr_mon = qrec[61:58];
  wire [4:0]  pr_day = qrec[57:53];
  wire [8:0]  pr_sh  = qrec[52:44];
  wire [8:0]  pr_sa  = qrec[43:35];
  logic       qg1, qg2;
  wire [8:0]  cum_r   = pm[QC  +: 9];
  wire [9:0]  base_r  = pm[QB  +: 10];
  wire [9:0]  base2_r = pm[QB2 +: 10];
  wire [9:0]  raw_r   = pm[QR  +: 10];
  wire [9:0]  raw2_r  = pm[QR2 +: 10];

  // Build capture + lists
  wire  [15:0] bc_a = pm[64*13+48 +: 16];
  wire  [15:0] bc_d = pm[64*13+32 +: 16];
  wire  [15:0] bc_s = pm[64*13+16 +: 16];
  logic [3:0]  bc_pid;
  logic        bc_vld;
  logic [4:0]  bsh;
  logic [3:0]  ld_v;  wire [63:0] ld_val = pm[LD_VAL +: 64];  wire [15:0] ld_id = pm[LD_ID +: 16];
  logic [1:0]  ls_v;  wire [31:0] ls_val = pm[LS_VAL +: 32];  wire [7:0]  ls_id = pm[LS_ID +: 8];
  logic [6:0]  la_v;  wire [111:0] la_val = pm[LA_VAL +: 112]; wire [27:0] la_id = pm[LA_ID +: 28];

  // =============================================================== Build : list insertion
  wire ins_d = bc_vld & (|bc_d[15:12]);
  wire ins_s = bc_vld & (|bc_s[15:12]);
  wire ins_a = bc_vld & (|bc_a[15:12]);
  logic [3:0]  ld_b;  logic [3:0]  ld_v_n;  logic [63:0] ld_val_n;  logic [15:0] ld_id_n;
  logic [1:0]  ls_b;  logic [1:0]  ls_v_n;  logic [31:0] ls_val_n;  logic [7:0]  ls_id_n;
  logic [6:0]  la_b;  logic [6:0]  la_v_n;  logic [111:0] la_val_n; logic [27:0] la_id_n;
  always_comb begin
    for (int i = 0; i < 4; i++)
      ld_b[i] = ins_d & (~ld_v[i] | (bc_d > ld_val[16*i +: 16]) | ((bc_d == ld_val[16*i +: 16]) & (bc_pid < ld_id[4*i +: 4])));
    for (int i = 0; i < 4; i++) begin
      if (!ld_b[i]) begin ld_v_n[i] = ld_v[i]; ld_val_n[16*i +: 16] = ld_val[16*i +: 16]; ld_id_n[4*i +: 4] = ld_id[4*i +: 4]; end
      else if (i == 0 || !ld_b[(i == 0) ? 0 : i - 1]) begin ld_v_n[i] = 1'b1; ld_val_n[16*i +: 16] = bc_d; ld_id_n[4*i +: 4] = bc_pid; end
      else begin ld_v_n[i] = ld_v[(i == 0) ? 0 : i - 1]; ld_val_n[16*i +: 16] = ld_val[16*((i == 0) ? 0 : i - 1) +: 16]; ld_id_n[4*i +: 4] = ld_id[4*((i == 0) ? 0 : i - 1) +: 4]; end
    end
    for (int i = 0; i < 2; i++)
      ls_b[i] = ins_s & (~ls_v[i] | (bc_s > ls_val[16*i +: 16]) | ((bc_s == ls_val[16*i +: 16]) & (bc_pid < ls_id[4*i +: 4])));
    for (int i = 0; i < 2; i++) begin
      if (!ls_b[i]) begin ls_v_n[i] = ls_v[i]; ls_val_n[16*i +: 16] = ls_val[16*i +: 16]; ls_id_n[4*i +: 4] = ls_id[4*i +: 4]; end
      else if (i == 0 || !ls_b[(i == 0) ? 0 : i - 1]) begin ls_v_n[i] = 1'b1; ls_val_n[16*i +: 16] = bc_s; ls_id_n[4*i +: 4] = bc_pid; end
      else begin ls_v_n[i] = ls_v[(i == 0) ? 0 : i - 1]; ls_val_n[16*i +: 16] = ls_val[16*((i == 0) ? 0 : i - 1) +: 16]; ls_id_n[4*i +: 4] = ls_id[4*((i == 0) ? 0 : i - 1) +: 4]; end
    end
    for (int i = 0; i < 7; i++)
      la_b[i] = ins_a & (~la_v[i] | (bc_a > la_val[16*i +: 16]) | ((bc_a == la_val[16*i +: 16]) & (bc_pid < la_id[4*i +: 4])));
    for (int i = 0; i < 7; i++) begin
      if (!la_b[i]) begin la_v_n[i] = la_v[i]; la_val_n[16*i +: 16] = la_val[16*i +: 16]; la_id_n[4*i +: 4] = la_id[4*i +: 4]; end
      else if (i == 0 || !la_b[(i == 0) ? 0 : i - 1]) begin la_v_n[i] = 1'b1; la_val_n[16*i +: 16] = bc_a; la_id_n[4*i +: 4] = bc_pid; end
      else begin la_v_n[i] = la_v[(i == 0) ? 0 : i - 1]; la_val_n[16*i +: 16] = la_val[16*((i == 0) ? 0 : i - 1) +: 16]; la_id_n[4*i +: 4] = la_id[4*((i == 0) ? 0 : i - 1) +: 4]; end
    end
  end

  // =============================================================== Build : selection stages F1..F4
  wire  [16:0] t1r = pm[T1R +: 17];
  wire  [16:0] t2r = pm[T2R +: 17];
  wire  [3:0]  rK  = pm[FREG +: 4],     rS  = pm[FREG+4 +: 4],  rB0 = pm[FREG+8 +: 4], rB1 = pm[FREG+12 +: 4];
  wire  [3:0]  rC0 = pm[FREG+16 +: 4],  rC1 = pm[FREG+20 +: 4], rC2 = pm[FREG+24 +: 4];
  logic        ksok, bok;
  wire  [16:0] t1_n = {1'b0, ld_val[15:0]}  + {1'b0, ls_val[31:16]};   // option 1 : (X, S2)
  wire  [16:0] t2_n = {1'b0, ld_val[31:16]} + {1'b0, ls_val[15:0]};    // option 2 : (K2, X)
  logic       ksok_n;
  logic [3:0] rK_n, rS_n;
  always_comb begin
    logic eq, o1, o2, pick1;
    eq    = (ld_id[3:0] == ls_id[3:0]);
    o1    = ls_v[1];
    o2    = ld_v[1];
    pick1 = o1 & (~o2 | (t1r > t2r) | ((t1r == t2r) & (ld_id[3:0] < ld_id[7:4])));
    ksok_n = ld_v[0] & ls_v[0] & (~eq | o1 | o2);
    if (!eq) begin rK_n = ld_id[3:0]; rS_n = ls_id[3:0]; end
    else if (pick1) begin rK_n = ld_id[3:0]; rS_n = ls_id[7:4]; end
    else begin rK_n = ld_id[7:4]; rS_n = ls_id[3:0]; end
  end
  always_ff @(posedge clk) ksok <= ksok_n;
  logic [3:0] av_d;
  always_comb begin
    for (int i = 0; i < 4; i++) av_d[i] = ld_v[i] & (ld_id[4*i +: 4] != rK) & (ld_id[4*i +: 4] != rS);
  end
  logic [3:0] rB0_n, rB1_n;
  always_ff @(posedge clk) bok <= (av_d[0] + av_d[1] + av_d[2] + av_d[3]) >= 3'd2;
  always_comb begin
    if (av_d[0]) begin
      rB0_n = ld_id[3:0];
      rB1_n = av_d[1] ? ld_id[7:4] : av_d[2] ? ld_id[11:8] : ld_id[15:12];
    end else if (av_d[1]) begin
      rB0_n = ld_id[7:4];
      rB1_n = av_d[2] ? ld_id[11:8] : ld_id[15:12];
    end else begin
      rB0_n = ld_id[11:8]; rB1_n = ld_id[15:12];
    end
  end
  logic [6:0] av_a;
  logic       cok_c;
  logic [3:0] c0n, c1n, c2n;
  always_comb begin
    logic [2:0] k;
    for (int i = 0; i < 7; i++)
      av_a[i] = la_v[i] & (la_id[4*i +: 4] != rK) & (la_id[4*i +: 4] != rS) &
                (la_id[4*i +: 4] != rB0) & (la_id[4*i +: 4] != rB1);
    c0n = 4'd0; c1n = 4'd0; c2n = 4'd0; k = 3'd0;
    for (int i = 0; i < 7; i++) begin
      if (av_a[i]) begin
        if (k == 3'd0) c0n = la_id[4*i +: 4];
        else if (k == 3'd1) c1n = la_id[4*i +: 4];
        else if (k == 3'd2) c2n = la_id[4*i +: 4];
        k = k + 3'd1;
      end
    end
    cok_c = (k >= 3'd3);
  end
  wire bld_valid_c = ksok & bok & cok_c;
  always_ff @(posedge clk) bld_valid_r <= bld_valid_c;
  wire ev_f2 = bsh[2];
  wire ev_f4 = bsh[4];
  wire aw_fast = ev_f2 & ksok_n & ld_v[3] & la_v[6];    // roster is guaranteed to exist: AW may go now
  logic fast_taken, bld_ok, f5, bld_valid_r;

  // =============================================================== Match derived pipeline
  // S0
  logic [16:0] pAH, pDH, pAA, pDA, pre_r;
  // S1
  logic [5:0]  qaH6, qaA6;
  logic [3:0]  qdH4, qdA4;
  logic        c0_r, c1_r, ca_r;
  // S2
  logic [3:0]  gH_r, gA_r;
  always_ff @(posedge clk) begin
    logic [17:0] sAH, sDH, sAA, sDA, y0, y1, ya;
    pAH <= {1'b0, pmA[16*1 +: 16]} + {1'b0, pmA[16*2 +: 16]};
    pDH <= {1'b0, pmD[16*0 +: 16]} + {1'b0, pmD[16*4 +: 16]};
    pAA <= {1'b0, pmA[16*8 +: 16]} + {1'b0, pmA[16*9 +: 16]};
    pDA <= {1'b0, pmD[16*7 +: 16]} + {1'b0, pmD[16*11 +: 16]};
    pre_r <= {2'b0, pmS[16*6+1 +: 15]} + {1'b0, r1r, 8'd0};
    sAH = {1'b0, pAH} + {2'b0, pmA[16*3 +: 16]};
    sDH = {1'b0, pDH} + {2'b0, pmD[16*5 +: 16]};
    sAA = {1'b0, pAA} + {2'b0, pmA[16*10 +: 16]};
    sDA = {1'b0, pDA} + {2'b0, pmD[16*12 +: 16]};
    qaH6 <= sAH[17:12]; qdH4 <= sDH[17:14]; qaA6 <= sAA[17:12]; qdA4 <= sDA[17:14];
    y0 = {1'b0, pre_r} - {4'b0, pmS[16*11+2 +: 14]};
    y1 = {1'b0, pre_r} - {4'b0, pmS[16*12+2 +: 14]};
    c0_r <= ~y0[17] & y0[16];
    c1_r <= ~y1[17] & y1[16];
    ya = {3'b0, pmS[16*13+1 +: 15]} + {2'b0, r2r, 8'd0};
    ca_r <= ya[16];
  end
  logic [3:0] qaH, qaA;
  logic [1:0] qdH, qdA;
  always_comb begin
    logic [10:0] m1, m2;
    logic [8:0]  m3, m4;
    m1 = {5'd0, qaH6} * 11'd43; qaH = m1[10:7];
    m2 = {5'd0, qaA6} * 11'd43; qaA = m2[10:7];
    m3 = {5'd0, qdH4} * 9'd43;  qdH = m3[8:7];
    m4 = {5'd0, qdA4} * 9'd43;  qdA = m4[8:7];
  end
  always_ff @(posedge clk) begin
    gH_r <= (qaH > {2'b0, qdA}) ? qaH - {2'b0, qdA} : 4'd0;
    gA_r <= (qaA > {2'b0, qdH}) ? qaA - {2'b0, qdH} : 4'd0;
  end
  wire ch_c = c0_r & c1_r;
  logic [1:0] res_c;
  logic [8:0] sH_c, sA_c;
  logic [7:0] g10H, g10A;
  always_comb begin
    res_c = ch_c ? 2'd0 : ca_r ? 2'd1 : (gH_r > gA_r) ? 2'd0 : (gH_r < gA_r) ? 2'd1 : 2'd2;
    g10H = {1'b0, gH_r, 3'b0} + {3'b0, gH_r, 1'b0};
    g10A = {1'b0, gA_r, 3'b0} + {3'b0, gA_r, 1'b0};
    sH_c = {1'b0, g10H} + (ch_c ? 9'd150 : 9'd0);
    sA_c = {1'b0, g10A} + ((ca_r & ~ch_c) ? 9'd150 : 9'd0);
  end
  logic [1:0] pres;
  logic [8:0] psH, psA;
  // result release countdown (depth of the slot that just landed: 4 / 3 / 2 cycles)
  logic [2:0] cd;
  wire  [2:0] dm1 = (oh_cur[13]) ? 3'd1 :
                    ((oh_cur[3] | oh_cur[5] | oh_cur[6] | oh_cur[10] | oh_cur[12])) ? 3'd2 : 3'd3;
  wire        res_ok = rd_all & (cd == 3'd0);

  // =============================================================== Training pipeline
  wire  [15:0] dA = pm[TD +: 16],    dD = pm[TD+16 +: 16], dS = pm[TD+32 +: 16];
  wire  [17:0] xa = pm[TX +: 18],    xd = pm[TX+18 +: 18], xs = pm[TX+36 +: 18];
  logic [15:0] dA_n, dD_n, dS_n;
  logic [17:0] xa_n, xd_n, xs_n;
  logic        tg1, tg2, t_ok;
  // 3-operand carry-save addition followed by one carry propagate adder
  function automatic [17:0] add3(input [17:0] x, input [17:0] y, input [17:0] z, input cin);
    logic [17:0] sm, cr;
    sm = x ^ y ^ z;
    cr = {(x[16:0] & y[16:0]) | (x[16:0] & z[16:0]) | (y[16:0] & z[16:0]), cin};
    add3 = sm + cr;
  endfunction
  always_comb begin
    logic [15:0] a, d, s;
    logic [17:0] sum;
    logic        c_ad, c_as, c_ds;
    logic [15:0] fad, fda, fas, fsa, fds, fsd;
    a = pmA[15:0]; d = pmD[15:0]; s = pmS[15:0];
    sum = add3({2'b0, a}, {2'b0, d}, {2'b0, s}, 1'b0);
    c_ad = (a <= d); c_as = (a <= s); c_ds = (d <= s);          // "x precedes y" in the stable ascending order A, D, S
    fad = d - a; fda = a - d; fas = s - a; fsa = a - s; fds = s - d; fsd = d - s;
    case (opt[3:2])
      2'd0: begin dA_n = sum[17:3]; dD_n = sum[17:3]; dS_n = sum[17:3]; end
      2'd1: begin
        // delta(x) = (next higher attribute) - x ; the highest one gets 0
        dA_n = (c_ad & c_as) ? (c_ds ? fad : fas) : (~c_ad & ~c_as) ? 16'd0 : (c_ad ? fad : fas);
        dD_n = (~c_ad & c_ds) ? (c_as ? fda : fds) : (c_ad & ~c_ds) ? 16'd0 : (c_ad ? fds : fda);
        dS_n = (~c_as & ~c_ds) ? (c_ad ? fsa : fsd) : (c_as & c_ds) ? 16'd0 : (c_as ? fsd : fsa);
      end
      2'd2: begin
        dA_n = (a[15:14] == 2'b00) ? {2'b00, ~a[13:0]} : 16'd0;
        dD_n = (d[15:14] == 2'b00) ? {2'b00, ~d[13:0]} : 16'd0;
        dS_n = (s[15:14] == 2'b00) ? {2'b00, ~s[13:0]} : 16'd0;
      end
      default: begin
        dA_n = ((~a[15:4]) >= 12'd2047) ? 16'd5047 : 16'd3000 + {4'b0, ~a[15:4]};
        dD_n = ((~d[15:4]) >= 12'd2047) ? 16'd5047 : 16'd3000 + {4'b0, ~d[15:4]};
        dS_n = ((~s[15:4]) >= 12'd2047) ? 16'd5047 : 16'd3000 + {4'b0, ~s[15:4]};
      end
    endcase
  end
  // T2 : value + delta + scale correction (easy: -(delta>>2), hard: +(delta>>2))
  always_comb begin
    logic [17:0] ea, ed, es;
    logic        cin;
    cin = (opt[1:0] == 2'd0);
    ea = (opt[1:0] == 2'd0) ? ~{4'b0, dA[15:2]} : (opt[1:0] == 2'd2) ? {4'b0, dA[15:2]} : 18'd0;
    ed = (opt[1:0] == 2'd0) ? ~{4'b0, dD[15:2]} : (opt[1:0] == 2'd2) ? {4'b0, dD[15:2]} : 18'd0;
    es = (opt[1:0] == 2'd0) ? ~{4'b0, dS[15:2]} : (opt[1:0] == 2'd2) ? {4'b0, dS[15:2]} : 18'd0;
    xa_n = add3({2'b0, pmA[15:0]}, {2'b0, dA}, ea, cin);
    xd_n = add3({2'b0, pmD[15:0]}, {2'b0, dD}, ed, cin);
    xs_n = add3({2'b0, pmS[15:0]}, {2'b0, dS}, es, cin);
  end
  wire [15:0] nA = (|xa[17:16]) ? 16'hFFFF : xa[15:0];
  wire [15:0] nD = (|xd[17:16]) ? 16'hFFFF : xd[15:0];
  wire [15:0] nS = (|xs[17:16]) ? 16'hFFFF : xs[15:0];
  wire        tsat_c = (|xa[17:16]) | (|xd[17:16]) | (|xs[17:16]);
  wire exp_ok_c = (opt[1:0] == 2'd0) ? (|inf.R_DATA[79:75]) :
                  (opt[1:0] == 2'd1) ? (|inf.R_DATA[79:77]) : (|inf.R_DATA[79:78]);

  // =============================================================== Match write data path
  logic [3:0]  wsel;                          // profile entry of the next Match profile beat
  logic [63:0] ud;
  logic        usat_c;
  always_comb begin
    logic win, los, u_home;
    logic [15:0] uA, uD, uS, uE;
    logic [16:0] ra, rd_, rs, re;
    uA = pmA[16*wsel +: 16]; uD = pmD[16*wsel +: 16]; uS = pmS[16*wsel +: 16]; uE = pmE[16*wsel +: 16];
    u_home = ~(wsel[3] | (&wsel[2:0]));
    win = u_home ? (pres == 2'd0) : (pres == 2'd1);
    los = u_home ? (pres == 2'd1) : (pres == 2'd0);
    ra  = win ? inc2048(uA) : los ? dec2048(uA) : dec1024(uA);
    rd_ = win ? inc2048(uD) : los ? dec2048(uD) : dec1024(uD);
    rs  = win ? inc2048(uS) : los ? dec2048(uS) : dec1024(uS);
    re  = win ? inc2048(uE) : los ? dec2048(uE) : {1'b0, uE};
    ud     = {ra[15:0], rd_[15:0], rs[15:0], re[15:0]};
    usat_c = ra[16] | rd_[16] | rs[16] | re[16];
  end

  // =============================================================== AW / W / B engines
  logic        aw_valid;
  logic [1:0]  aw_id;
  logic [16:0] aw_addr;
  logic [3:0]  wbusy;
  logic        w_valid;
  logic [63:0] wd;
  logic [4:0]  wi, wcnt, ahs, bleft;
  logic        blp;
  logic        aw_en, sat_acc;
  logic        ov, cmp_r, oki;
  logic [2:0]  warn_r;

  wire  [3:0]  wfree   = ~wbusy;
  wire         w_any_r = |wfree;
  wire         w_any   = w_any_r | inf.B_VALID;
  wire  [1:0]  w_newid = w_any_r ? (wfree[0] ? 2'd0 : wfree[1] ? 2'd1 : wfree[2] ? 2'd2 : 2'd3) : inf.B_ID;
  wire  [3:0]  wj      = wi[3:0] - 4'd1;
  logic [16:0] aw_addr_n;
  always_comb begin
    case (1'b1)
      is_build: aw_addr_n = {1'b1, 5'd0, 1'b1, 1'b0, 1'b1, 2'b00, tm1, 4'd0};
      is_train: aw_addr_n = {7'b1000000, tm1, nib(cH, opt[6:4]), 4'd0};
      default: begin
        if (wi == 5'd0) aw_addr_n = {1'b1, 4'd0, 1'b1, 3'd0, pairidx(tm1, tm2), 4'd0};
        else if (wj < 4'd7) aw_addr_n = {7'b1000000, tm1, nib(cH, wj[2:0]), 4'd0};
        else aw_addr_n = {7'b1000000, tm2, nib(cA, wj[2:0] + 3'd1), 4'd0};
      end
    endcase
  end
  wire aw_en_now = (is_train & l_proft & exp_ok_c) | (is_match & drained_now);
  wire aw_load = run & (aw_en | aw_en_now) & (~aw_valid | inf.AW_READY) & (wi < nwr) & w_any;
  wire ahs_now = inf.AW_VALID & inf.AW_READY;
  logic beat_rdy;
  always_comb begin
    case (1'b1)
      is_build: beat_rdy = bld_ok;
      is_train: beat_rdy = t_ok;
      default:  beat_rdy = (wcnt == 5'd0) ? res_ok : 1'b1;
    endcase
  end
  wire wl_pre = run & beat_rdy & (wcnt < nwr);                  // register only part
  wire cov_r  = (ahs > wcnt);
  wire w_load = wl_pre & (~w_valid | inf.W_READY) & cov_r;

  logic [63:0] wd_n;
  logic        sat_n;
  always_comb begin
    sat_n = 1'b0;
    case (1'b1)
      is_build: wd_n = {rK, rC0, rC1, rC2, rB0, rB1, rS, 36'd0};
      is_train: begin wd_n = {nA, nD, nS, pmE[15:0]}; sat_n = tsat_c; end
      default: begin
        if (wcnt == 5'd0) wd_n = {res_c, month, day, sH_c, sA_c, 35'd0};
        else begin wd_n = ud; sat_n = usat_c; end
      end
    endcase
  end

  wire b_last = inf.B_VALID & blp;

  // =============================================================== events
  wire ev_exp    = run & l_proft & ~exp_ok_c;
  wire ev_roster = run & f5 & ~fast_taken & ~bld_valid_r;
  wire ev_q      = run & qg2;
  wire ev_done   = run & b_last;

  // Query stage Q3 (combinational from raw_r / raw2_r)
  wire q_ok = (~raw_n[9] & (raw_n <= 10'd90)) | (raw_n[9] & ($signed(raw_n) <= -10'sd275));
  wire [6:0] qdel7 = raw_r[9] ? raw2_r[6:0] : raw_r[6:0];

  // =============================================================== data registers without reset
  always_ff @(posedge clk) begin
    if (!run) begin
      rtag_b[1:0] <= 2'd0;
      ohr[13:0]   <= is_build ? (14'd1 << 13) : is_query ? (14'd1 << 12) : 14'd0;
    end
    if (ar_load_run) begin
      rtag_b[2*r_newid +: 2] <= ri[1:0];
      ohr[14*r_newid +: 14]  <= n_oh;
    end
    if (l_ctxH) cH <= inf.R_DATA[127:100];
    if (l_ctxA) cA <= inf.R_DATA[127:100];
    if (l_bld)  bc_pid <= {rtag_b[2*inf.R_ID +: 2], rbeat};
    if (w_load && is_match && wcnt == 5'd0) begin pres <= res_c; psH <= sH_c; psA <= sA_c; end
  end

  // =============================================================== scratch store writer
  wire [8:0]  cum_n   = cum_f(pr_mon);
  wire [9:0]  base_n  = {1'b0, doy_t} - {5'd0, pr_day};      // doy(today) - day(record)
  wire [9:0]  base2_n = d365_r - {5'd0, pr_day};
  wire [9:0]  raw_n   = base_r - {1'b0, cum_r};              // doy(today) - doy(record)
  wire [9:0]  raw2_n  = base2_r - {1'b0, cum_r};             // the same + 365
  always_ff @(posedge clk) begin
    if (bc_vld) begin                                          // Build : top-N list update
      pm[LD_VAL +: 64] <= ld_val_n;  pm[LD_ID +: 16] <= ld_id_n;
      pm[LS_VAL +: 32] <= ls_val_n;  pm[LS_ID +: 8]  <= ls_id_n;
      pm[LA_VAL +: 112] <= la_val_n; pm[LA_ID +: 28] <= la_id_n;
    end
    if (is_build) begin                                        // Build : selection stages
      pm[T1R +: 17] <= t1_n; pm[T2R +: 17] <= t2_n;
      pm[FREG +: 28] <= {c2n, c1n, c0n, rB1_n, rB0_n, rS_n, rK_n};
    end
    if (is_train) begin                                        // Training : delta and sum stages
      pm[TD +: 48] <= {dS_n, dD_n, dA_n};
      pm[TX +: 54] <= {xs_n, xd_n, xa_n};
    end
    if (is_query) begin                                        // Query : date math
      pm[QC  +: 9]  <= cum_n;
      pm[QB  +: 10] <= base_n;
      pm[QB2 +: 10] <= base2_n;
      pm[QR  +: 10] <= raw_n;
      pm[QR2 +: 10] <= raw2_n;
    end
    for (int e = 0; e < 14; e++) begin                       // landing (late arriving select: kept as the last mux level)
      if (inf.R_VALID & oh_cur[e]) begin
        pm[64*e+48 +: 16] <= inf.R_DATA[127:112]; pm[64*e+32 +: 16] <= inf.R_DATA[111:96];
        pm[64*e+16 +: 16] <= inf.R_DATA[95:80];   pm[64*e    +: 16] <= inf.R_DATA[79:64];
      end
    end
  end

  // =============================================================== main sequential block
  always_ff @(posedge clk or negedge inf.rst_n) begin
    if (!inf.rst_n) begin
      run <= 1'b0; ri <= 5'd1; ar_valid <= 1'b0; ar_id <= '0; ar_addr <= '0; rbusy <= '0;
      rbeat <= '0; rdy <= 1'b0; hH <= 1'b0; hA <= 1'b0; rleft <= '0; lp <= 1'b0; rd_all <= 1'b0;
      qg1 <= 1'b0; qg2 <= 1'b0;
      bc_vld <= 1'b0; bsh <= '0;
      ld_v <= '0; ls_v <= '0; la_v <= '0;
      tg1 <= 1'b0; tg2 <= 1'b0; t_ok <= 1'b0; cd <= '0;
      wsel <= '0;
      aw_valid <= 1'b0; aw_id <= '0; aw_addr <= '0; wbusy <= '0; w_valid <= 1'b0; wd <= '0;
      wi <= '0; wcnt <= '0; ahs <= '0; bleft <= '0; blp <= 1'b0; aw_en <= 1'b0; sat_acc <= 1'b0;
      fast_taken <= 1'b0; bld_ok <= 1'b0; f5 <= 1'b0;
      ov <= 1'b0; cmp_r <= 1'b0; warn_r <= '0; oki <= 1'b0;
    end else begin
      rdy <= 1'b1;
      ov <= 1'b0; cmp_r <= 1'b0; warn_r <= '0; oki <= 1'b0;

      // ------------------------------------------------ idle initialisation (state is rebuilt while no command runs)
      if (!run) begin
        ri <= 5'd1; hH <= 1'b0; hA <= 1'b0; rd_all <= 1'b0; rbeat <= '0;
        rleft <= nrd; lp <= (nrd == 5'd1);
        qg1 <= 1'b0; qg2 <= 1'b0; bsh <= '0; bc_vld <= 1'b0;
        ld_v <= '0; ls_v <= '0; la_v <= '0;
        tg1 <= 1'b0; tg2 <= 1'b0; t_ok <= 1'b0; wsel <= '0; cd <= '0;
        wi <= '0; wcnt <= '0; ahs <= '0; bleft <= nwr; blp <= (nwr == 5'd1); aw_en <= 1'b0; sat_acc <= 1'b0;
        fast_taken <= 1'b0; bld_ok <= 1'b0; f5 <= 1'b0;
      end

      // ------------------------------------------------ start of a command
      if (start) begin run <= 1'b1; end

      // ------------------------------------------------ AR channel
      if (ar_valid & inf.AR_READY) ar_valid <= 1'b0;
      if (start) begin
        ar_valid <= 1'b1; ar_id <= 2'd0; ar_addr <= addr0;
      end else if (ar_load_run) begin
        ar_valid <= 1'b1; ar_id <= r_newid; ar_addr <= addr_reg;
      end
      if (ar_load_run) begin          // never true in the cycle of 'start' (run is still 0)
        ri <= ri + 5'd1;
      end
      if (r_last) rbusy[inf.R_ID] <= 1'b0;
      if (ar_load_run) rbusy[r_newid] <= 1'b1;
      if (start) rbusy[0] <= 1'b1;

      // ------------------------------------------------ R channel / landing
      if (inf.R_VALID) rbeat <= inf.R_LAST ? 2'd0 : rbeat + 2'd1;
      if (run) begin
        if (r_last) rleft <= rleft - 5'd1;
        lp <= r_last ? (rleft == 5'd2) : (rleft == 5'd1);
      end
      if (l_ctxH) hH <= 1'b1;
      if (l_ctxA) hA <= 1'b1;
      if (drained_now) rd_all <= 1'b1;

      // ------------------------------------------------ Build : capture, insert, finalise
      bc_vld <= l_bld;
      if (bc_vld) begin ld_v <= ld_v_n; ls_v <= ls_v_n; la_v <= la_v_n; end
      bsh <= {bsh[3:0], drained_now & is_build};
      if (aw_en_now | aw_fast) aw_en <= 1'b1;
      if (aw_fast) fast_taken <= 1'b1;
      f5 <= ev_f4;
      if (ev_f4 & fast_taken) bld_ok <= 1'b1;
      if (f5 & ~fast_taken & bld_valid_r) begin bld_ok <= 1'b1; aw_en <= 1'b1; end

      // ------------------------------------------------ Training / Query / Match flags
      tg1 <= l_proft & exp_ok_c;
      tg2 <= tg1;
      if (tg2) t_ok <= 1'b1;
      qg1 <= l_pair; qg2 <= qg1;
      begin
        logic [2:0] cdd;
        cdd = (cd != 3'd0) ? cd - 3'd1 : 3'd0;
        cd <= (l_profm && is_match && dm1 > cdd) ? dm1 : cdd;
      end

      // ------------------------------------------------ AW channel
      if (ahs_now) begin aw_valid <= 1'b0; ahs <= ahs + 5'd1; end
      if (aw_load) begin
        aw_valid <= 1'b1; aw_id <= w_newid; aw_addr <= aw_addr_n; wi <= wi + 5'd1;
      end
      if (inf.B_VALID) wbusy[inf.B_ID] <= 1'b0;
      if (aw_load) wbusy[w_newid] <= 1'b1;
      if (run & inf.B_VALID) begin
        bleft <= bleft - 5'd1;
        blp <= (bleft == 5'd2);
      end

      // ------------------------------------------------ W channel
      if (w_valid & inf.W_READY) w_valid <= 1'b0;
      if (w_load) begin
        w_valid <= 1'b1; wd <= wd_n; wcnt <= wcnt + 5'd1;
        if (is_match && wcnt != 5'd0) wsel <= wsel + 4'd1;
        if (sat_n) sat_acc <= 1'b1;
      end

      // ------------------------------------------------ results
      if (early) begin
        ov <= 1'b1; warn_r <= early_opt ? W_OPT : W_TEAM;
      end
      if (ev_exp) begin ov <= 1'b1; warn_r <= W_EXP; run <= 1'b0; end
      if (ev_roster) begin ov <= 1'b1; warn_r <= W_ROSTER; run <= 1'b0; end
      if (ev_q) begin
        run <= 1'b0; ov <= 1'b1;
        if (q_ok) begin cmp_r <= 1'b1; oki <= 1'b1; end
        else warn_r <= W_DATE;
      end
      if (ev_done) begin
        run <= 1'b0; ov <= 1'b1; cmp_r <= 1'b1; oki <= 1'b1;
        warn_r <= sat_acc ? W_SAT : W_NONE;
      end
    end
  end

  // =============================================================== constant / registered AXI outputs
  // out_info : the registers that already hold the result are gated by the one-cycle 'oki' flag
  wire [63:0] out_src = is_match ? {pres, month, day, psH, psA, 35'd0} :
                        is_query ? {month, day, pr_mon, pr_day, qdel7, pr_res, pr_sh, pr_sa, 19'd0} : wd;
  assign inf.out_valid = ov;
  assign inf.complete  = cmp_r;
  assign inf.warn_msg  = warn_r;
  assign inf.out_info  = {{64{oki}} & out_src, 64'd0};
  assign inf.AR_VALID = ar_valid;
  assign inf.AR_ID    = ar_id;
  assign inf.AR_ADDR  = ar_addr;
  assign inf.AR_LEN   = {6'd0, is_build, is_build};
  assign inf.AR_SIZE  = 3'b100;
  assign inf.AR_BURST = 2'b01;
  assign inf.R_READY  = rdy;
  assign inf.AW_VALID = aw_valid;
  assign inf.AW_ID    = aw_id;
  assign inf.AW_ADDR  = aw_addr;
  assign inf.AW_LEN   = 8'd0;
  assign inf.AW_SIZE  = 3'b100;
  assign inf.AW_BURST = 2'b01;
  assign inf.W_VALID  = w_valid;
  assign inf.W_DATA   = {wd, 64'd0};
  assign inf.W_STRB   = 16'hFFFF;
  assign inf.W_LAST   = 1'b1;
  assign inf.B_READY  = rdy;
endmodule

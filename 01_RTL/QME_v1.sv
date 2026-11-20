// QME v1 : straightforward, correctness-first baseline.
//  * all 16 candidate profiles / 14 match profiles are stored in plain register arrays
//  * reads and writes are issued by simple counters (4 outstanding, lowest free ID)
//  * every algorithm step is a separate multi-cycle state with big combinational logic
module QME (input logic clk, INF.QME inf);

  // ------------------------------------------------------------------ constants
  localparam [2:0] W_NONE = 3'b000, W_DATE = 3'b001, W_TEAM = 3'b010, W_ROSTER = 3'b011,
                   W_OPT = 3'b100, W_EXP = 3'b101, W_SAT = 3'b111;
  localparam [1:0] A_BUILD = 2'd0, A_TRAIN = 2'd1, A_MATCH = 2'd2, A_QUERY = 2'd3;

  typedef enum logic [4:0] {
    S_IDLE, S_RD, S_B1, S_B2, S_B3, S_T1, S_M1, S_M2, S_M3, S_Q1, S_WR, S_OUT
  } state_t;
  state_t st;

  // ------------------------------------------------------------------ input capture
  logic [1:0] act;
  logic [3:0] month;
  logic [4:0] day;
  logic [1:0] tm1, tm2;
  logic [6:0] opt;
  logic       got_t1;

  wire lastv_team   = inf.in_valid_team && ((act == A_BUILD) || (got_t1 && act[1]));
  wire lastv_option = inf.in_valid_option;
  wire lastv        = lastv_team || lastv_option;
  wire early_team   = lastv_team && act[1] && (inf.D[1:0] == tm1);
  wire early_opt    = lastv_option && ((inf.D[6:4] == 3'd7) || (inf.D[1:0] == 2'd3));

  // ------------------------------------------------------------------ storage
  logic [255:0] vA, vD, vS, vE;       // 16 x 16 bit: attack / defense / speed / exp, index = slot or PlayerID
  logic [27:0]  ctxH, ctxA;           // 7 x 4 bit PlayerIDs  [27:24] = slot 0
  logic [1:0]   pr_res;               // pair record read by Query
  logic [3:0]   pr_mon;
  logic [4:0]   pr_day;
  logic [8:0]   pr_sh, pr_sa;

  // ------------------------------------------------------------------ read engine
  logic        ph;                    // read phase
  logic [4:0]  ar_cnt, ar_tot, rd_done;
  logic [3:0]  rbusy;
  logic [15:0] rslot;                 // 4 x 4-bit slot index, one per ID
  logic [1:0]  rbeat;

  // ------------------------------------------------------------------ write engine
  logic [4:0]  nw, aw_cnt, aw_hs, w_cnt, b_cnt;
  logic [3:0]  wbusy;

  // ------------------------------------------------------------------ results
  logic [127:0] res_info;
  logic [2:0]   res_warn;
  logic         res_cmplt;
  logic [3:0]   gH, gA;
  logic [13:0]  interf;
  logic         catchH, catchA;
  logic [1:0]   mres;
  logic [8:0]   msH, msA;
  logic         msat;
  logic [127:0] pair_beat;

  // ------------------------------------------------------------------ helper functions
  function automatic [8:0] doy_f(input [3:0] m, input [4:0] d);
    logic [12:0] t;
    logic [12:0] q;
    begin
      t = 13'd367 * {9'd0, m} - 13'd362;
      q = t / 13'd12;
      doy_f = q[8:0] - ((m > 4'd2) ? 9'd2 : 9'd0) + {4'd0, d};
    end
  endfunction

  function automatic [15:0] fld(input [255:0] v, input [3:0] i);
    fld = v[16*i +: 16];
  endfunction

  function automatic [3:0] nib(input [27:0] c, input [2:0] s);
    nib = c[27 - 4*s -: 4];
  endfunction

  function automatic [3:0] pairidx(input [1:0] h, input [1:0] a);
    // index = home*3 + (away < home ? away : away-1)
    pairidx = {2'b00, h} * 4'd3 + ((a < h) ? {2'b00, a} : {2'b00, a} - 4'd1);
  endfunction

  // 8-bit LFSR step
  function automatic [7:0] lfsr(input [7:0] x);
    lfsr = {x[6:0], x[7] ^ x[5] ^ x[4] ^ x[3]};
  endfunction

  // ---- Build Team selection helpers (combinational scans over 16 candidates)
  // returns {found, id[3:0]} of the largest value among eligible, smallest ID on ties
  function automatic [4:0] pick_max(input [255:0] v, input [15:0] elig);
    logic        found;
    logic [15:0] best;
    logic [3:0]  bid;
    begin
      found = 1'b0; best = 16'd0; bid = 4'd0;
      for (int i = 0; i < 16; i++) begin
        if (elig[i] && (!found || v[16*i +: 16] > best)) begin
          found = 1'b1; best = v[16*i +: 16]; bid = i[3:0];
        end
      end
      pick_max = {found, bid};
    end
  endfunction

  // ---- Training delta
  function automatic [16:0] tdelta(input [1:0] ttype, input [1:0] mode, input [1:0] which,
                                   input [15:0] a, input [15:0] d, input [15:0] s);
    logic [15:0] v, q0, q1, q2;
    logic [17:0] sum;
    logic [1:0]  rank;
    logic [16:0] dl;
    logic [15:0] t;
    begin
      v = (which == 2'd0) ? a : (which == 2'd1) ? d : s;
      sum = {2'b0, a} + {2'b0, d} + {2'b0, s};
      case (which)
        2'd0: rank = {1'b0, (d < a)} + {1'b0, (s < a)};
        2'd1: rank = {1'b0, (a <= d)} + {1'b0, (s < d)};
        default: rank = {1'b0, (a <= s)} + {1'b0, (d <= s)};
      endcase
      // sorted values q0 <= q1 <= q2
      q0 = (a <= d && a <= s) ? a : (d < a && d <= s) ? d : s;
      q2 = (a > d && a > s) ? a : (d >= a && d > s) ? d : s;
      q1 = a + d + s - q0 - q2;   // median = sum - min - max (mod 2^16 is exact)
      case (ttype)
        2'd0: dl = {2'b0, sum[17:3]};
        2'd1: dl = (rank == 2'd0) ? {1'b0, q1 - q0} : (rank == 2'd1) ? {1'b0, q2 - q1} : 17'd0;
        2'd2: dl = (v < 16'd16383) ? {1'b0, 16'd16383 - v} : 17'd0;
        default: begin
          t = 16'd3000 + {4'b0, (16'hFFFF - v) >> 4};
          dl = {1'b0, (t < 16'd5047) ? t : 16'd5047};
        end
      endcase
      case (mode)
        2'd0: tdelta = dl - {2'b0, dl[16:2]};
        2'd2: tdelta = dl + {2'b0, dl[16:2]};
        default: tdelta = dl;
      endcase
    end
  endfunction

  // ---- Match player update.  kind: 0 winner(+2048) 1 loser(-2048) 2 draw (-1024, exp unchanged)
  function automatic [16:0] chg(input [15:0] v, input [1:0] k);
    case (k)
      2'd0: chg = {1'b0, v} + 17'd2048;
      2'd1: chg = {1'b0, v} - 17'd2048;
      default: chg = {1'b0, v} - 17'd1024;
    endcase
  endfunction
  function automatic [64:0] pupd(input [1:0] kind, input [15:0] a, input [15:0] d, input [15:0] s, input [15:0] e);
    logic [16:0] ra, rd, rs, re;
    logic [15:0] clampv;
    begin
      clampv = (kind == 2'd0) ? 16'hFFFF : 16'h0000;
      ra = chg(a, kind); rd = chg(d, kind); rs = chg(s, kind);
      re = (kind == 2'd2) ? {1'b0, e} : chg(e, kind);
      pupd = {ra[16] | rd[16] | rs[16] | re[16],
              ra[16] ? clampv : ra[15:0], rd[16] ? clampv : rd[15:0],
              rs[16] ? clampv : rs[15:0], re[16] ? clampv : re[15:0]};
    end
  endfunction

  // ------------------------------------------------------------------ Build selection (combinational)
  logic [15:0] qd, qs, qa;
  always_comb begin
    for (int i = 0; i < 16; i++) begin
      qd[i] = (vD[16*i +: 16] >= 16'd4096);
      qs[i] = (vS[16*i +: 16] >= 16'd4096);
      qa[i] = (vA[16*i +: 16] >= 16'd4096);
    end
  end
  // stage B1 : keeper / seeker
  logic [4:0] kstar, sstar, k2, s2;
  logic [3:0] selK, selS;
  logic       ksok;
  always_comb begin
    logic        o1, o2;
    logic [16:0] t1, t2;
    kstar = pick_max(vD, qd);
    sstar = pick_max(vS, qs);
    k2 = pick_max(vD, qd & ~(16'd1 << kstar[3:0]));
    s2 = pick_max(vS, qs & ~(16'd1 << sstar[3:0]));
    ksok = 1'b0; selK = 4'd0; selS = 4'd0;
    o1 = 1'b0; o2 = 1'b0; t1 = 17'd0; t2 = 17'd0;
    if (kstar[4] && sstar[4]) begin
      if (kstar[3:0] != sstar[3:0]) begin
        ksok = 1'b1; selK = kstar[3:0]; selS = sstar[3:0];
      end else begin
        // option 1 : (X, S2)   option 2 : (K2, X)
        o1 = s2[4]; o2 = k2[4];
        t1 = {1'b0, fld(vD, kstar[3:0])} + {1'b0, fld(vS, s2[3:0])};
        t2 = {1'b0, fld(vD, k2[3:0])} + {1'b0, fld(vS, sstar[3:0])};
        if (o1 && (!o2 || t1 > t2 || (t1 == t2 && kstar[3:0] < k2[3:0]))) begin
          ksok = 1'b1; selK = kstar[3:0]; selS = s2[3:0];
        end else if (o2) begin
          ksok = 1'b1; selK = k2[3:0]; selS = sstar[3:0];
        end
      end
    end
  end

  logic [3:0] rK, rS, rB0, rB1, rC0, rC1, rC2;
  // stage B2 : beaters
  logic [4:0] pb0, pb1;
  always_comb begin
    logic [15:0] ex;
    ex = (16'd1 << rK) | (16'd1 << rS);
    pb0 = pick_max(vD, qd & ~ex);
    pb1 = pick_max(vD, qd & ~(ex | (16'd1 << pb0[3:0])));
  end
  // stage B3 : chasers
  logic [4:0] pc0, pc1, pc2;
  always_comb begin
    logic [15:0] ex;
    ex = (16'd1 << rK) | (16'd1 << rS) | (16'd1 << rB0) | (16'd1 << rB1);
    pc0 = pick_max(vA, qa & ~ex);
    pc1 = pick_max(vA, qa & ~(ex | (16'd1 << pc0[3:0])));
    pc2 = pick_max(vA, qa & ~(ex | (16'd1 << pc0[3:0]) | (16'd1 << pc1[3:0])));
  end

  // ------------------------------------------------------------------ Match combinational blocks
  logic [17:0] sAH, dAH, sAA, dAA;
  logic [15:0] taH, tdH, taA, tdA;
  always_comb begin
    sAH = {2'b0, fld(vA, 4'd1)} + {2'b0, fld(vA, 4'd2)} + {2'b0, fld(vA, 4'd3)};
    dAH = {2'b0, fld(vD, 4'd0)} + {2'b0, fld(vD, 4'd4)} + {2'b0, fld(vD, 4'd5)};
    sAA = {2'b0, fld(vA, 4'd8)} + {2'b0, fld(vA, 4'd9)} + {2'b0, fld(vA, 4'd10)};
    dAA = {2'b0, fld(vD, 4'd7)} + {2'b0, fld(vD, 4'd11)} + {2'b0, fld(vD, 4'd12)};
    taH = sAH / 18'd3; tdH = dAH / 18'd3; taA = sAA / 18'd3; tdA = dAA / 18'd3;
  end

  // seed / random numbers / catch
  logic [8:0]  dayofyear;
  logic [7:0]  seed, rn1, rn2;
  logic [17:0] cH, cA;
  always_comb begin
    logic [7:0] s0;
    dayofyear = doy_f(month, day);
    s0 = dayofyear[7:0] ^ {6'b0, tm1} ^ {4'b0, tm2, 2'b0};
    seed = (s0 == 8'd0) ? 8'd1 : s0;
    rn1 = lfsr(seed);
    rn2 = lfsr(rn1);
    cH = {3'b0, fld(vS, 4'd6) >> 1} + {2'b0, rn1, 8'd0} - {4'b0, interf};
    cA = {3'b0, fld(vS, 4'd13) >> 1} + {2'b0, rn2, 8'd0};
  end

  // Match result / scores (stage M3 inputs)
  logic [1:0] mres_c;
  logic       catchH_c, catchA_c;
  always_comb begin
    catchH_c = (cH >= 18'd65536) && !cH[17];
    catchA_c = !catchH && (cA >= 18'd65536);
    if (catchH) mres_c = 2'd0;
    else if (catchA_c) mres_c = 2'd1;
    else mres_c = (gH > gA) ? 2'd0 : (gH < gA) ? 2'd1 : 2'd2;
  end

  // saturation scan for all 14 players once mres is known
  logic msat_c;
  always_comb begin
    logic [64:0] u;
    logic [1:0]  kh, ka;
    msat_c = 1'b0;
    kh = (mres == 2'd0) ? 2'd0 : (mres == 2'd1) ? 2'd1 : 2'd2;
    ka = (mres == 2'd0) ? 2'd1 : (mres == 2'd1) ? 2'd0 : 2'd2;
    for (int j = 0; j < 14; j++) begin
      u = pupd((j < 7) ? kh : ka, fld(vA, j[3:0]), fld(vD, j[3:0]), fld(vS, j[3:0]), fld(vE, j[3:0]));
      msat_c |= u[64];
    end
  end

  // ------------------------------------------------------------------ AR address of the next read
  logic [16:0] nxt_ar_addr;
  logic [7:0]  nxt_ar_len;
  logic [3:0]  nxt_ar_slot;
  logic [3:0]  ar_pid;
  logic [1:0]  ar_team;
  always_comb begin
    nxt_ar_len = 8'd0; nxt_ar_slot = ar_cnt[3:0]; ar_pid = 4'd0; ar_team = tm1;
    nxt_ar_addr = 17'd0;
    case (act)
      A_BUILD: begin
        nxt_ar_addr = {7'b1000000, tm1, ar_cnt[1:0], 6'd0}; // 0x10000 | team<<8 | idx<<6
        nxt_ar_len  = 8'd3;
      end
      A_TRAIN: begin
        if (!ph) nxt_ar_addr = 17'h10500 | {11'd0, tm1, 4'd0};
        else begin
          ar_pid = nib(ctxH, opt[6:4]);
          nxt_ar_addr = 17'h10000 | {7'd0, tm1, ar_pid, 4'd0};
        end
      end
      A_MATCH: begin
        if (!ph) begin
          nxt_ar_addr = 17'h10500 | {11'd0, ((ar_cnt[0]) ? tm2 : tm1), 4'd0};
        end else begin
          ar_team = (ar_cnt < 5'd7) ? tm1 : tm2;
          ar_pid  = (ar_cnt < 5'd7) ? nib(ctxH, ar_cnt[2:0]) : nib(ctxA, ar_cnt[2:0] - 3'd7);
          nxt_ar_addr = 17'h10000 | {7'd0, ar_team, ar_pid, 4'd0};
        end
      end
      default: begin // Query
        nxt_ar_addr = 17'h10800 | {9'd0, pairidx(tm1, tm2), 4'd0};
      end
    endcase
  end

  wire [3:0] rfree_id = !rbusy[0] ? 4'd0 : !rbusy[1] ? 4'd1 : !rbusy[2] ? 4'd2 : 4'd3;
  wire       rany     = ~&rbusy;
  wire [3:0] wfree_id = !wbusy[0] ? 4'd0 : !wbusy[1] ? 4'd1 : !wbusy[2] ? 4'd2 : 4'd3;
  wire       wany     = ~&wbusy;

  wire [3:0] rslot_cur = rslot[4*inf.R_ID +: 4];
  wire ar_hs = inf.AR_VALID && inf.AR_READY;
  wire aw_hs_now = inf.AW_VALID && inf.AW_READY;
  wire w_hs  = inf.W_VALID && inf.W_READY;
  wire ar_load = (st == S_RD) && (ar_cnt < ar_tot) && (!inf.AR_VALID || inf.AR_READY) && rany;
  wire aw_load = (st == S_WR) && (aw_cnt < nw) && (!inf.AW_VALID || inf.AW_READY) && wany;
  wire w_load  = (st == S_WR) && (w_cnt < aw_hs) && (!inf.W_VALID || inf.W_READY);

  // ------------------------------------------------------------------ write address / data of write #k
  logic [16:0]  nxt_aw_addr;
  logic [127:0] nxt_w_data;
  logic [3:0]   wj;
  logic [3:0]   wpid;
  logic [1:0]   wteam;
  always_comb begin
    nxt_aw_addr = 17'd0; wj = 4'd0; wpid = 4'd0; wteam = tm1;
    case (act)
      A_BUILD: nxt_aw_addr = 17'h10500 | {11'd0, tm1, 4'd0};
      A_TRAIN: nxt_aw_addr = 17'h10000 | {7'd0, tm1, nib(ctxH, opt[6:4]), 4'd0};
      default: begin
        if (aw_cnt == 5'd0) nxt_aw_addr = 17'h10800 | {9'd0, pairidx(tm1, tm2), 4'd0};
        else begin
          wj = aw_cnt[3:0] - 4'd1;
          wteam = (wj < 4'd7) ? tm1 : tm2;
          wpid  = (wj < 4'd7) ? nib(ctxH, wj[2:0]) : nib(ctxA, wj[2:0] - 3'd7);
          nxt_aw_addr = 17'h10000 | {7'd0, wteam, wpid, 4'd0};
        end
      end
    endcase
  end
  always_comb begin
    logic [64:0] u;
    logic [1:0]  kind;
    logic [3:0]  j;
    nxt_w_data = res_info; // Build / Training
    u = 65'd0; kind = 2'd0; j = 4'd0;
    if (act == A_MATCH) begin
      if (w_cnt == 5'd0) nxt_w_data = pair_beat;
      else begin
        j = w_cnt[3:0] - 4'd1;
        if (mres == 2'd2) kind = 2'd2;
        else if (j < 4'd7) kind = (mres == 2'd0) ? 2'd0 : 2'd1;
        else kind = (mres == 2'd1) ? 2'd0 : 2'd1;
        u = pupd(kind, fld(vA, j), fld(vD, j), fld(vS, j), fld(vE, j));
        nxt_w_data = {u[63:48], u[47:32], u[31:16], u[15:0], 64'd0};
      end
    end
  end

  // ------------------------------------------------------------------ main sequential block
  always_ff @(posedge clk or negedge inf.rst_n) begin
    if (!inf.rst_n) begin
      st <= S_IDLE; act <= '0; month <= '0; day <= '0; tm1 <= '0; tm2 <= '0; opt <= '0; got_t1 <= 1'b0;
      vA <= '0; vD <= '0; vS <= '0; vE <= '0; ctxH <= '0; ctxA <= '0;
      pr_res <= '0; pr_mon <= '0; pr_day <= '0; pr_sh <= '0; pr_sa <= '0;
      ph <= 1'b0; ar_cnt <= '0; ar_tot <= '0; rd_done <= '0; rbusy <= '0; rbeat <= '0;
      rslot <= '0;
      nw <= '0; aw_cnt <= '0; aw_hs <= '0; w_cnt <= '0; b_cnt <= '0; wbusy <= '0;
      res_info <= '0; res_warn <= '0; res_cmplt <= 1'b0;
      gH <= '0; gA <= '0; interf <= '0; catchH <= 1'b0; catchA <= 1'b0; mres <= '0; msH <= '0; msA <= '0; msat <= 1'b0;
      pair_beat <= '0;
      inf.out_valid <= 1'b0; inf.complete <= 1'b0; inf.warn_msg <= '0; inf.out_info <= '0;
      inf.AR_VALID <= 1'b0; inf.AR_ID <= '0; inf.AR_ADDR <= '0; inf.AR_LEN <= '0; inf.AR_SIZE <= 3'b100; inf.AR_BURST <= 2'b01;
      inf.R_READY <= 1'b0;
      inf.AW_VALID <= 1'b0; inf.AW_ID <= '0; inf.AW_ADDR <= '0; inf.AW_LEN <= '0; inf.AW_SIZE <= 3'b100; inf.AW_BURST <= 2'b01;
      inf.W_VALID <= 1'b0; inf.W_DATA <= '0; inf.W_STRB <= 16'hFFFF; inf.W_LAST <= 1'b0;
      inf.B_READY <= 1'b0;
    end else begin
      // ---- defaults
      inf.out_valid <= 1'b0; inf.complete <= 1'b0; inf.warn_msg <= '0; inf.out_info <= '0;
      inf.R_READY <= 1'b1; inf.B_READY <= 1'b1;

      // ---- input capture
      if (inf.in_valid_action) begin act <= inf.D[1:0]; got_t1 <= 1'b0; end
      if (inf.in_valid_date) begin month <= inf.D[8:5]; day <= inf.D[4:0]; end
      if (inf.in_valid_team) begin
        if (!got_t1) tm1 <= inf.D[1:0]; else tm2 <= inf.D[1:0];
        got_t1 <= ~got_t1;
      end
      if (inf.in_valid_option) opt <= inf.D[6:0];

      // ---- AR channel
      if (ar_hs) inf.AR_VALID <= 1'b0;
      if (ar_load) begin
        inf.AR_VALID <= 1'b1; inf.AR_ID <= rfree_id[1:0]; inf.AR_ADDR <= nxt_ar_addr; inf.AR_LEN <= nxt_ar_len;
        rbusy[rfree_id[1:0]] <= 1'b1; rslot[4*rfree_id[1:0] +: 4] <= nxt_ar_slot;
        ar_cnt <= ar_cnt + 5'd1;
      end
      // ---- R channel
      if (inf.R_VALID) begin
        rbeat <= inf.R_LAST ? 2'd0 : rbeat + 2'd1;
        if (inf.R_LAST) begin
          rbusy[inf.R_ID] <= 1'b0; rd_done <= rd_done + 5'd1;
        end
        case (act)
          A_BUILD: begin
            vA[16*{rslot_cur[1:0], rbeat} +: 16] <= inf.R_DATA[127:112];
            vD[16*{rslot_cur[1:0], rbeat} +: 16] <= inf.R_DATA[111:96];
            vS[16*{rslot_cur[1:0], rbeat} +: 16] <= inf.R_DATA[95:80];
          end
          A_TRAIN: begin
            if (!ph) ctxH <= inf.R_DATA[127:100];
            else begin
              vA[15:0] <= inf.R_DATA[127:112]; vD[15:0] <= inf.R_DATA[111:96];
              vS[15:0] <= inf.R_DATA[95:80];   vE[15:0] <= inf.R_DATA[79:64];
            end
          end
          A_MATCH: begin
            if (!ph) begin
              if (rslot_cur[0]) ctxA <= inf.R_DATA[127:100]; else ctxH <= inf.R_DATA[127:100];
            end else begin
              vA[16*rslot_cur +: 16] <= inf.R_DATA[127:112];
              vD[16*rslot_cur +: 16] <= inf.R_DATA[111:96];
              vS[16*rslot_cur +: 16] <= inf.R_DATA[95:80];
              vE[16*rslot_cur +: 16] <= inf.R_DATA[79:64];
            end
          end
          default: begin
            pr_res <= inf.R_DATA[127:126]; pr_mon <= inf.R_DATA[125:122]; pr_day <= inf.R_DATA[121:117];
            pr_sh <= inf.R_DATA[116:108]; pr_sa <= inf.R_DATA[107:99];
          end
        endcase
      end

      // ---- AW / W / B channels
      if (aw_hs_now) begin inf.AW_VALID <= 1'b0; aw_hs <= aw_hs + 5'd1; end
      if (aw_load) begin
        inf.AW_VALID <= 1'b1; inf.AW_ID <= wfree_id[1:0]; inf.AW_ADDR <= nxt_aw_addr; inf.AW_LEN <= 8'd0;
        wbusy[wfree_id[1:0]] <= 1'b1; aw_cnt <= aw_cnt + 5'd1;
      end
      if (w_hs) inf.W_VALID <= 1'b0;
      if (w_load) begin
        inf.W_VALID <= 1'b1; inf.W_DATA <= nxt_w_data; inf.W_LAST <= 1'b1; w_cnt <= w_cnt + 5'd1;
      end
      if (inf.B_VALID) begin wbusy[inf.B_ID] <= 1'b0; b_cnt <= b_cnt + 5'd1; end

      // ---- FSM
      case (st)
        S_IDLE: begin
          if (lastv) begin
            ph <= 1'b0; ar_cnt <= '0; rd_done <= '0; aw_cnt <= '0; aw_hs <= '0; w_cnt <= '0; b_cnt <= '0;
            if (early_team || early_opt) begin
              inf.out_valid <= 1'b1; inf.complete <= 1'b0;
              inf.warn_msg <= early_opt ? W_OPT : W_TEAM; inf.out_info <= '0;
            end else begin
              st <= S_RD;
              case (act)
                A_BUILD: ar_tot <= 5'd4;
                A_TRAIN: ar_tot <= 5'd1;
                A_MATCH: ar_tot <= 5'd2;
                default: ar_tot <= 5'd1;
              endcase
            end
          end
        end
        S_RD: begin
          if (ar_cnt == ar_tot && rd_done == ar_tot) begin
            rd_done <= '0; ar_cnt <= '0;
            case (act)
              A_BUILD: st <= S_B1;
              A_TRAIN: if (!ph) begin ph <= 1'b1; ar_tot <= 5'd1; end else st <= S_T1;
              A_MATCH: if (!ph) begin ph <= 1'b1; ar_tot <= 5'd14; end else st <= S_M1;
              default: st <= S_Q1;
            endcase
          end
        end
        // ---------------- Build Team
        S_B1: begin
          if (!ksok) begin
            inf.out_valid <= 1'b1; inf.warn_msg <= W_ROSTER; st <= S_IDLE;
          end else begin
            rK <= selK; rS <= selS; st <= S_B2;
          end
        end
        S_B2: begin
          if (!pb0[4] || !pb1[4]) begin
            inf.out_valid <= 1'b1; inf.warn_msg <= W_ROSTER; st <= S_IDLE;
          end else begin
            rB0 <= pb0[3:0]; rB1 <= pb1[3:0]; st <= S_B3;
          end
        end
        S_B3: begin
          if (!pc0[4] || !pc1[4] || !pc2[4]) begin
            inf.out_valid <= 1'b1; inf.warn_msg <= W_ROSTER; st <= S_IDLE;
          end else begin
            res_info <= {rK, pc0[3:0], pc1[3:0], pc2[3:0], rB0, rB1, rS, 100'd0};
            res_warn <= W_NONE; res_cmplt <= 1'b1; nw <= 5'd1; st <= S_WR;
          end
        end
        // ---------------- Training
        S_T1: begin
          logic [16:0] da, dd, ds;
          logic [17:0] xa, xd, xs;
          logic        ova, ovd, ovs;
          logic [15:0] need;
          need = (opt[1:0] == 2'd0) ? 16'd2048 : (opt[1:0] == 2'd1) ? 16'd8192 : 16'd16384;
          if (vE[15:0] < need) begin
            inf.out_valid <= 1'b1; inf.warn_msg <= W_EXP; st <= S_IDLE;
          end else begin
            da = tdelta(opt[3:2], opt[1:0], 2'd0, vA[15:0], vD[15:0], vS[15:0]);
            dd = tdelta(opt[3:2], opt[1:0], 2'd1, vA[15:0], vD[15:0], vS[15:0]);
            ds = tdelta(opt[3:2], opt[1:0], 2'd2, vA[15:0], vD[15:0], vS[15:0]);
            xa = {2'b0, vA[15:0]} + {1'b0, da}; xd = {2'b0, vD[15:0]} + {1'b0, dd}; xs = {2'b0, vS[15:0]} + {1'b0, ds};
            ova = (xa > 18'd65535); ovd = (xd > 18'd65535); ovs = (xs > 18'd65535);
            st <= S_WR; nw <= 5'd1;
            res_info <= {ova ? 16'hFFFF : xa[15:0], ovd ? 16'hFFFF : xd[15:0], ovs ? 16'hFFFF : xs[15:0], vE[15:0], 64'd0};
            res_warn <= (ova | ovd | ovs) ? W_SAT : W_NONE;
            res_cmplt <= 1'b1;
          end
        end
        // ---------------- Match
        S_M1: begin
          gH <= (taH[15:12] > tdA[15:14] ? taH[15:12] - {2'b0, tdA[15:14]} : 4'd0);
          gA <= (taA[15:12] > tdH[15:14] ? taA[15:12] - {2'b0, tdH[15:14]} : 4'd0);
          interf <= ((fld(vS, 4'd11) > fld(vS, 4'd12)) ? fld(vS, 4'd11) : fld(vS, 4'd12)) >> 2;
          st <= S_M2;
        end
        S_M2: begin
          catchH <= catchH_c; // note: catchH_c uses interf (registered in M1)
          st <= S_M3;
        end
        S_M3: begin
          mres <= mres_c; catchA <= catchA_c;
          msH <= gH * 4'd10 + (catchH ? 9'd150 : 9'd0);
          msA <= gA * 4'd10 + (catchA_c ? 9'd150 : 9'd0);
          st <= S_WR;      // pair beat and saturation flag are registered in S_WR prologue via nw==0 trick
          nw <= 5'd0;
        end
        // ---------------- Query
        S_Q1: begin
          logic signed [10:0] dd;
          logic [9:0] delta;
          dd = $signed({2'b0, doy_f(month, day)}) - $signed({2'b0, doy_f(pr_mon, pr_day)});
          delta = (dd < 0) ? (dd + 11'sd365) : dd[9:0];
          if (delta > 10'd90) begin
            inf.out_valid <= 1'b1; inf.warn_msg <= W_DATE; st <= S_IDLE;
          end else begin
            inf.out_valid <= 1'b1; inf.complete <= 1'b1; inf.warn_msg <= W_NONE;
            inf.out_info <= {month, day, pr_mon, pr_day, delta[6:0], pr_res, pr_sh, pr_sa, 83'd0};
            st <= S_IDLE;
          end
        end
        // ---------------- write phase / output
        S_WR: begin
          if (act == A_MATCH && nw == 5'd0) begin
            // prologue: finalise pair record, sat flag, number of writes
            pair_beat <= {mres, month, day, msH, msA, 99'd0};
            res_info  <= {mres, month, day, msH, msA, 99'd0};
            res_warn  <= msat_c ? W_SAT : W_NONE; res_cmplt <= 1'b1;
            nw <= 5'd15;
          end else if (b_cnt == nw && nw != 5'd0) begin
            inf.out_valid <= 1'b1; inf.complete <= res_cmplt; inf.warn_msg <= res_warn; inf.out_info <= res_info;
            st <= S_IDLE;
            nw <= '0;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule

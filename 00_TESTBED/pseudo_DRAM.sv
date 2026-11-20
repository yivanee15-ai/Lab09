`ifndef PSEUDO_DRAM_SV
`define PSEUDO_DRAM_SV
// Stand-in AXI4 slave model for Lab09 with protocol checkers.
// Latency convention: L=1 means the response is visible in the cycle right after the handshake.
module pseudo_DRAM (input logic clk, INF.DRAM inf);
  // ---------------- parameters (released = smallest values); every one is also a plusarg
  int DRAM_R_LATENCY   = 1;
  int DRAM_B_LATENCY   = 1;
  int DRAM_W_STALL     = 0;
  int DRAM_AR_AW_STALL = 0;
  int DRAM_GAP         = 0;
  int DRAM_REORDER     = 0;
  int DRAM_SEED        = 0;
  int trace            = 0;
  string dram_file     = "dram.dat";

  logic [7:0] mem [0:131071];
  int errors = 0;
  int nrd = 0, nwr = 0;               // outstanding transactions (visible to PATTERN)
  longint cyc = 0, seq_ctr = 0;
  logic [31:0] rs;

  function automatic int unsigned rnd();
    rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5);
    return rs;
  endfunction

  task automatic err(input string s);
    errors++;
    $display("[DRAM-CHECK] cyc=%0d %s", cyc, s);
  endtask

  function automatic bit legal_beat(input int a);
    return (a >= 'h10000 && a <= 'h108BF) && (a[3:0] == 0) &&
           ((a < 'h10400) || (a >= 'h10500 && a < 'h10540) || (a >= 'h10800));
  endfunction
  function automatic bit legal_burst(input int a, input int len);
    bit ok = 1;
    for (int i = 0; i <= len; i++) ok &= legal_beat(a + 16 * i);
    return ok;
  endfunction
  function automatic bit overlap(input int a1, input int l1, input int a2, input int l2);
    return (a1 < a2 + 16 * (l2 + 1)) && (a2 < a1 + 16 * (l1 + 1));
  endfunction
  function automatic logic [127:0] beat_at(input int a);
    logic [127:0] v;
    for (int i = 0; i < 16; i++) v[8*i +: 8] = mem[a + i];
    return v;
  endfunction

  // ---------------- state
  logic        rd_act [4]; int rd_addr [4]; int rd_len [4]; longint rd_due [4]; longint rd_seq [4];
  logic        wr_act [4]; int wr_addr [4]; int wr_len [4]; logic wr_done [4]; longint wr_due [4]; longint wr_seq [4];
  logic [1:0]  awq [4]; int awq_n = 0; int w_beat = 0;
  logic        r_busy = 0; logic [1:0] r_cur; int r_beat; int r_gap = 0;
  logic        b_busy = 0; logic [1:0] b_cur; int b_gap = 0;
  int ar_wait = 0, aw_wait = 0, w_wait = 0;
  // stability tracking of DUT-driven valid channels
  logic ar_pend = 0, aw_pend = 0, w_pend = 0;
  logic [1:0] ar_id_q; logic [16:0] ar_addr_q; logic [7:0] ar_len_q;
  logic [1:0] aw_id_q; logic [16:0] aw_addr_q; logic [7:0] aw_len_q;
  logic [127:0] w_data_q; logic w_last_q;
  int nrd_pre;

  initial begin
    for (int i = 0; i < 131072; i++) mem[i] = 8'h00;
    void'($value$plusargs("DRAM_R_LATENCY=%d", DRAM_R_LATENCY));
    void'($value$plusargs("DRAM_B_LATENCY=%d", DRAM_B_LATENCY));
    void'($value$plusargs("DRAM_W_STALL=%d", DRAM_W_STALL));
    void'($value$plusargs("DRAM_AR_AW_STALL=%d", DRAM_AR_AW_STALL));
    void'($value$plusargs("DRAM_GAP=%d", DRAM_GAP));
    void'($value$plusargs("DRAM_REORDER=%d", DRAM_REORDER));
    void'($value$plusargs("DRAM_SEED=%d", DRAM_SEED));
    void'($value$plusargs("DRAM_FILE=%s", dram_file));
    void'($value$plusargs("TRACE=%d", trace));
    $readmemh(dram_file, mem);
    rs = 32'h2545F491 ^ (DRAM_SEED * 32'h9E3779B1);
    if (rs == 0) rs = 1;
    for (int i = 0; i < 4; i++) begin rd_act[i] = 0; wr_act[i] = 0; end
    inf.AR_READY = 0; inf.R_VALID = 0; inf.R_ID = 0; inf.R_DATA = 0; inf.R_RESP = 0; inf.R_LAST = 0;
    inf.AW_READY = 0; inf.W_READY = 0; inf.B_VALID = 0; inf.B_ID = 0; inf.B_RESP = 0;
  end

  int sel, best;
  longint bseq;

  always @(posedge clk or negedge inf.rst_n) begin
    if (!inf.rst_n) begin
      for (int i = 0; i < 4; i++) begin rd_act[i] = 0; wr_act[i] = 0; end
      nrd = 0; nwr = 0; awq_n = 0; w_beat = 0; r_busy = 0; b_busy = 0; r_gap = 0; b_gap = 0;
      ar_pend = 0; aw_pend = 0; w_pend = 0; ar_wait = 0; aw_wait = 0; w_wait = 0;
      inf.AR_READY <= 0; inf.AW_READY <= 0; inf.W_READY <= 0;
      inf.R_VALID <= 0; inf.R_ID <= 0; inf.R_DATA <= 0; inf.R_RESP <= 0; inf.R_LAST <= 0;
      inf.B_VALID <= 0; inf.B_ID <= 0; inf.B_RESP <= 0;
    end else begin
      cyc++;
      nrd_pre = nrd;
      // ---------- payload stability of DUT-driven channels
      if (ar_pend && !(inf.AR_VALID && inf.AR_ID == ar_id_q && inf.AR_ADDR == ar_addr_q && inf.AR_LEN == ar_len_q))
        err("AR payload/valid changed before AR_READY");
      if (aw_pend && !(inf.AW_VALID && inf.AW_ID == aw_id_q && inf.AW_ADDR == aw_addr_q && inf.AW_LEN == aw_len_q))
        err("AW payload/valid changed before AW_READY");
      if (w_pend && !(inf.W_VALID && inf.W_DATA == w_data_q && inf.W_LAST == w_last_q))
        err("W payload/valid changed before W_READY");
      if (inf.AR_VALID && (inf.AR_SIZE !== 3'b100 || inf.AR_BURST !== 2'b01)) err("AR_SIZE/AR_BURST not constant");
      if (inf.AW_VALID && (inf.AW_SIZE !== 3'b100 || inf.AW_BURST !== 2'b01)) err("AW_SIZE/AW_BURST not constant");
      if (inf.W_VALID && inf.W_STRB !== 16'hFFFF) err("W_STRB not FFFF");
      ar_pend = inf.AR_VALID && !inf.AR_READY; ar_id_q = inf.AR_ID; ar_addr_q = inf.AR_ADDR; ar_len_q = inf.AR_LEN;
      aw_pend = inf.AW_VALID && !inf.AW_READY; aw_id_q = inf.AW_ID; aw_addr_q = inf.AW_ADDR; aw_len_q = inf.AW_LEN;
      w_pend  = inf.W_VALID && !inf.W_READY;   w_data_q = inf.W_DATA; w_last_q = inf.W_LAST;

      // ---------- W channel (checked against the AW state *before* this edge)
      if (inf.W_VALID && awq_n == 0) err("W_VALID presented before its AW handshake");
      if (inf.W_VALID && inf.W_READY && awq_n > 0) begin
        sel = awq[0];
        if (inf.W_LAST !== (w_beat == wr_len[sel])) err("W_LAST wrong");
        for (int i = 0; i < 16; i++) mem[wr_addr[sel] + 16 * w_beat + i] = inf.W_DATA[8*i +: 8];
        if (w_beat == wr_len[sel]) begin
          wr_done[sel] = 1; wr_due[sel] = cyc + (1 + rnd() % DRAM_B_LATENCY) - 1;
          for (int i = 0; i < 3; i++) awq[i] = awq[i+1];
          awq_n--; w_beat = 0;
        end else w_beat++;
        w_wait = rnd() % (DRAM_W_STALL + 1);
      end else if (!inf.W_READY && inf.W_VALID && w_wait > 0) w_wait--;
      inf.W_READY <= (w_wait == 0);

      if (trace) begin
        if (inf.AW_VALID && inf.AW_READY) $display("[%0d] AW id%0d addr %h len %0d", cyc, inf.AW_ID, inf.AW_ADDR, inf.AW_LEN);
        if (inf.AR_VALID && inf.AR_READY) $display("[%0d] AR id%0d addr %h len %0d", cyc, inf.AR_ID, inf.AR_ADDR, inf.AR_LEN);
        if (inf.R_VALID && inf.R_READY) $display("[%0d]   R id%0d last%b data %h", cyc, inf.R_ID, inf.R_LAST, inf.R_DATA);
        if (inf.W_VALID && inf.W_READY) $display("[%0d]   W data %h last%b", cyc, inf.W_DATA, inf.W_LAST);
        if (inf.B_VALID && inf.B_READY) $display("[%0d]   B id%0d", cyc, inf.B_ID);
      end
      // ---------- AW capture
      if (inf.AW_VALID && inf.AW_READY) begin
        if (wr_act[inf.AW_ID]) err("AWID reused while active");
        if (nwr >= 4) err("more than 4 outstanding writes");
        if (nrd_pre != 0) err("AW handshake while reads still outstanding");
        if (!legal_burst(inf.AW_ADDR, inf.AW_LEN) || inf.AW_LEN > 3) err($sformatf("illegal write address %h len %0d", inf.AW_ADDR, inf.AW_LEN));
        for (int i = 0; i < 4; i++) begin
          if (rd_act[i] && overlap(inf.AW_ADDR, inf.AW_LEN, rd_addr[i], rd_len[i])) err("write address matches outstanding read");
          if (wr_act[i] && overlap(inf.AW_ADDR, inf.AW_LEN, wr_addr[i], wr_len[i])) err("two outstanding writes to the same address");
        end
        wr_act[inf.AW_ID] = 1; wr_addr[inf.AW_ID] = inf.AW_ADDR; wr_len[inf.AW_ID] = inf.AW_LEN;
        wr_done[inf.AW_ID] = 0; wr_seq[inf.AW_ID] = seq_ctr++;
        awq[awq_n] = inf.AW_ID; awq_n++; nwr++;
        aw_wait = rnd() % (DRAM_AR_AW_STALL + 1);
      end else if (!inf.AW_READY && inf.AW_VALID && aw_wait > 0) aw_wait--;
      inf.AW_READY <= (aw_wait == 0);

      // ---------- AR capture
      if (inf.AR_VALID && inf.AR_READY) begin
        if (rd_act[inf.AR_ID]) err("ARID reused while active");
        if (nrd >= 4) err("more than 4 outstanding reads");
        if (!legal_burst(inf.AR_ADDR, inf.AR_LEN) || inf.AR_LEN > 3) err($sformatf("illegal read address %h len %0d", inf.AR_ADDR, inf.AR_LEN));
        for (int i = 0; i < 4; i++)
          if (wr_act[i] && overlap(inf.AR_ADDR, inf.AR_LEN, wr_addr[i], wr_len[i])) err("read address matches outstanding write");
        rd_act[inf.AR_ID] = 1; rd_addr[inf.AR_ID] = inf.AR_ADDR; rd_len[inf.AR_ID] = inf.AR_LEN;
        rd_due[inf.AR_ID] = cyc + (1 + rnd() % DRAM_R_LATENCY) - 1; rd_seq[inf.AR_ID] = seq_ctr++;
        nrd++;
        ar_wait = rnd() % (DRAM_AR_AW_STALL + 1);
      end else if (!inf.AR_READY && inf.AR_VALID && ar_wait > 0) ar_wait--;
      inf.AR_READY <= (ar_wait == 0);

      // ---------- R channel
      if (r_busy && inf.R_VALID && inf.R_READY) begin
        if (r_beat == rd_len[r_cur]) begin
          rd_act[r_cur] = 0; nrd--; r_busy = 0; r_gap = rnd() % (DRAM_GAP + 1);
          inf.R_VALID <= 0; inf.R_LAST <= 0; inf.R_DATA <= 0; inf.R_ID <= 0;
        end else begin
          r_beat++;
          inf.R_DATA <= beat_at(rd_addr[r_cur] + 16 * r_beat);
          inf.R_LAST <= (r_beat == rd_len[r_cur]);
        end
      end else if (!r_busy && r_gap > 0) r_gap--;
      if (!r_busy && r_gap == 0) begin
        sel = -1; bseq = 64'h7FFF_FFFF_FFFF_FFFF; best = 0;
        for (int i = 0; i < 4; i++) begin
          if (rd_act[i]) begin
            if (DRAM_REORDER == 0) begin
              if (rd_seq[i] < bseq) begin bseq = rd_seq[i]; sel = (rd_due[i] <= cyc) ? i : -1; end
            end else if (rd_due[i] <= cyc) begin
              best++;
              if (rnd() % best == 0) sel = i;
            end
          end
        end
        if (sel >= 0) begin
          r_busy = 1; r_cur = sel; r_beat = 0;
          inf.R_VALID <= 1; inf.R_ID <= sel[1:0]; inf.R_RESP <= 0;
          inf.R_DATA <= beat_at(rd_addr[sel]); inf.R_LAST <= (rd_len[sel] == 0);
        end
      end

      // ---------- B channel
      if (b_busy && inf.B_VALID && inf.B_READY) begin
        wr_act[b_cur] = 0; nwr--; b_busy = 0; b_gap = rnd() % (DRAM_GAP + 1);
        inf.B_VALID <= 0; inf.B_ID <= 0;
      end else if (!b_busy && b_gap > 0) b_gap--;
      if (!b_busy && b_gap == 0) begin
        sel = -1; bseq = 64'h7FFF_FFFF_FFFF_FFFF; best = 0;
        for (int i = 0; i < 4; i++) begin
          if (wr_act[i]) begin
            if (DRAM_REORDER == 0) begin
              if (wr_seq[i] < bseq) begin bseq = wr_seq[i]; sel = (wr_done[i] && wr_due[i] <= cyc) ? i : -1; end
            end else if (wr_done[i] && wr_due[i] <= cyc) begin
              best++;
              if (rnd() % best == 0) sel = i;
            end
          end
        end
        if (sel >= 0) begin
          b_busy = 1; b_cur = sel; inf.B_VALID <= 1; inf.B_ID <= sel[1:0]; inf.B_RESP <= 0;
        end
      end
    end
  end
endmodule
`endif

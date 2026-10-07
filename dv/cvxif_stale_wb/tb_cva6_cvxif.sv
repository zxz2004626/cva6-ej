// -----------------------------------------------------------------------------
// tb_cva6_cvxif.sv -- CVA6 CV-X-IF stale-result PoC testbench
//
// Top level: flat 64-bit memory behind CVA6's NoC (AXI4) port, the `cva6` core
// DUT, and a CV-X-IF coprocessor stub that
//   * accepts every offload (multi-outstanding, like a pipelined coprocessor),
//   * returns each result N cycles later tagged with the id it was issued with,
//   * returns a *unique* value per execution (an execution counter), so the
//     first and the second execution of the same instruction are
//     distinguishable.
//
// Nothing inside the core is forced.  The testbench only observes the CVXIF
// request/response buses and the RVFI retirement trace.
//
// The AXI slave can inject a read bus error: any read whose address matches
// +err_addr is held for +err_lat cycles and then answered with rresp=SLVERR.
// This is the flush source of the bus-error PoC (an older load raises a
// precise HARDWARE_ERROR exception at commit, long after the offload behind
// it was issued).
//
// Plusargs:
//   +mem=<file>       $readmemh word image (64-bit words)
//   +max_cycles=<n>   simulation timeout
//   +trace=<0|1>      print the RVFI retirement trace
//   +dump=<file>      write the result words here
//   +wave=<file>      fsdb dump
//   +err_addr=<hex>   read address to answer with SLVERR (default: none)
//   +err_lat=<n>      cycles to hold the error response (default 0)
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

`include "cvxif_types.svh"

module cvxif_copro_stub #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned IDW  = 4,
    parameter int unsigned LAT  = 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic issue_valid_i,
    output logic issue_ready_o,
    input  logic [31:0] issue_instr_i,
    input  logic [IDW-1:0] issue_id_i,
    input  logic result_ready_i,
    output logic result_valid_o,
    output logic [IDW-1:0] result_id_o,
    output logic [4:0] result_rd_o,
    output logic [XLEN-1:0] result_data_o,
    output logic result_we_o
);
  assign issue_ready_o = 1'b1;

  // latency pipeline of pending results
  localparam int unsigned DEPTH = LAT + 4;
  logic              v_q   [0:DEPTH-1];
  logic [IDW-1:0]    id_q  [0:DEPTH-1];
  logic [4:0]        rd_q  [0:DEPTH-1];
  logic [XLEN-1:0]   dat_q [0:DEPTH-1];
  logic [XLEN-1:0]   exec_cnt_q;

  wire shift = (result_valid_o && result_ready_i) || !v_q[0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      exec_cnt_q <= '0;
      for (int i = 0; i < DEPTH; i++) begin
        v_q[i]   <= 1'b0;
        id_q[i]  <= '0;
        rd_q[i]  <= '0;
        dat_q[i] <= '0;
      end
    end else begin
      if (shift) begin
        for (int i = 0; i < DEPTH - 1; i++) begin
          v_q[i]   <= v_q[i+1];
          id_q[i]  <= id_q[i+1];
          rd_q[i]  <= rd_q[i+1];
          dat_q[i] <= dat_q[i+1];
        end
        v_q[DEPTH-1] <= 1'b0;
      end
      if (issue_valid_i && issue_ready_o) begin
        v_q[LAT]   <= 1'b1;
        id_q[LAT]  <= issue_id_i;
        rd_q[LAT]  <= issue_instr_i[11:7];
        dat_q[LAT] <= exec_cnt_q + 1;
        $display("  COPRO OFFLOAD cyc=%0t id=%0d instr=%08x rd=x%0d -> result %0d",
                 $time, issue_id_i, issue_instr_i, issue_instr_i[11:7], exec_cnt_q + 1);
      end
      if (issue_valid_i && issue_ready_o) exec_cnt_q <= exec_cnt_q + 1;
    end
  end

  assign result_valid_o = v_q[0];
  assign result_id_o    = id_q[0];
  assign result_rd_o    = rd_q[0];
  assign result_data_o  = dat_q[0];
  assign result_we_o    = 1'b1;

endmodule


module tb_cva6_cvxif;

  import config_pkg::*;
  import ariane_pkg::*;
  import axi_pkg::*;

  localparam config_pkg::cva6_cfg_t C = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  localparam int unsigned XLEN  = C.XLEN;
  localparam int unsigned ADDRW = C.AxiAddrWidth;
  localparam int unsigned DATAW = C.AxiDataWidth;
  localparam int unsigned IDW   = C.AxiIdWidth;
  localparam int unsigned USRW  = C.AxiUserWidth;

  localparam logic [63:0] BASE      = 64'h8000_0000;
  localparam int unsigned MEM_WORDS = 1 << 14;
  localparam logic [63:0] DONE_ADDR = 64'h8000_1000;
  localparam logic [63:0] R_A0      = 64'h8000_1000 + 8;

  localparam type readregflags_t  = `READREGFLAGS_T(C);
  localparam type writeregflags_t = `WRITEREGFLAGS_T(C);
  localparam type id_t            = `ID_T(C);
  localparam type hartid_t        = `HARTID_T(C);
  localparam type x_compressed_req_t  = `X_COMPRESSED_REQ_T(C, hartid_t);
  localparam type x_compressed_resp_t = `X_COMPRESSED_RESP_T(C);
  localparam type x_issue_req_t   = `X_ISSUE_REQ_T(C, hartid_t, id_t);
  localparam type x_issue_resp_t  = `X_ISSUE_RESP_T(C, writeregflags_t, readregflags_t);
  localparam type x_register_t    = `X_REGISTER_T(C, hartid_t, id_t, readregflags_t);
  localparam type x_commit_t      = `X_COMMIT_T(C, hartid_t, id_t);
  localparam type x_result_t      = `X_RESULT_T(C, hartid_t, id_t, writeregflags_t);
  localparam type cvxif_req_t     = `CVXIF_REQ_T(C, x_compressed_req_t, x_issue_req_t, x_register_t, x_commit_t);
  localparam type cvxif_resp_t    = `CVXIF_RESP_T(C, x_compressed_resp_t, x_issue_resp_t, x_result_t);

  // ---------------------------------------------------------------- AXI types
  typedef struct packed {
    logic [IDW-1:0] id; logic [ADDRW-1:0] addr;
    axi_pkg::len_t len; axi_pkg::size_t size; axi_pkg::burst_t burst;
    logic lock; axi_pkg::cache_t cache; axi_pkg::prot_t prot;
    axi_pkg::qos_t qos; axi_pkg::region_t region; logic [USRW-1:0] user;
  } ar_t;
  typedef struct packed {
    logic [IDW-1:0] id; logic [ADDRW-1:0] addr;
    axi_pkg::len_t len; axi_pkg::size_t size; axi_pkg::burst_t burst;
    logic lock; axi_pkg::cache_t cache; axi_pkg::prot_t prot;
    axi_pkg::qos_t qos; axi_pkg::region_t region; axi_pkg::atop_t atop; logic [USRW-1:0] user;
  } aw_t;
  typedef struct packed { logic [DATAW-1:0] data; logic [DATAW/8-1:0] strb; logic last; logic [USRW-1:0] user; } w_t;
  typedef struct packed { logic [IDW-1:0] id; axi_pkg::resp_t resp; logic [USRW-1:0] user; } b_t;
  typedef struct packed { logic [IDW-1:0] id; logic [DATAW-1:0] data; axi_pkg::resp_t resp; logic last; logic [USRW-1:0] user; } r_t;
  typedef struct packed { aw_t aw; logic aw_valid; w_t w; logic w_valid; logic b_ready; ar_t ar; logic ar_valid; logic r_ready; } noc_req_t;
  typedef struct packed { logic aw_ready; logic ar_ready; logic w_ready; logic b_valid; b_t b; logic r_valid; r_t r; } noc_resp_t;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // bus-error injection: reads to err_addr are held err_lat cycles, then
  // answered with rresp=SLVERR
  logic [63:0] err_addr = '0;
  int unsigned err_lat  = 0;
  wire        err_en    = (err_addr != 64'b0);

  logic [DATAW-1:0] mem [0:MEM_WORDS-1];
  function automatic bit in_mem(input logic [63:0] a);
    return (a >= BASE) && (a < (BASE + MEM_WORDS*(DATAW/8)));
  endfunction
  function automatic int unsigned widx(input logic [63:0] a);
    return int'((a - BASE) >> 3);
  endfunction
  function automatic logic [DATAW-1:0] rdata(input logic [63:0] a);
    return in_mem(a) ? mem[widx(a)] : {DATAW{1'b0}};
  endfunction

  noc_req_t noc_req; noc_resp_t noc_resp;
  typedef enum logic [1:0] {R_IDLE, R_WAIT, R_DATA} rstate_e;
  rstate_e rstate, rstate_d;
  logic [63:0] r_addr_q; logic [IDW-1:0] r_id_q; logic [7:0] r_len_q, r_cnt_q;
  logic [63:0] r_data_q;
  logic        r_err_q;
  int unsigned r_wait_q;
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_B} wstate_e;
  wstate_e wstate, wstate_d;
  logic [63:0] w_addr_q; logic [IDW-1:0] w_id_q;

  always_comb begin
    rstate_d = rstate;
    noc_resp.ar_ready = 1'b0; noc_resp.r_valid = 1'b0;
    noc_resp.r.data = r_data_q;
    noc_resp.r.resp = r_err_q ? axi_pkg::RESP_SLVERR : axi_pkg::RESP_OKAY;
    noc_resp.r.id = r_id_q; noc_resp.r.last = (r_cnt_q == r_len_q); noc_resp.r.user = '0;
    case (rstate)
      R_IDLE: begin
        noc_resp.ar_ready = 1'b1;
        if (noc_req.ar_valid) rstate_d = (err_en && (noc_req.ar.addr == err_addr)) ? R_WAIT : R_DATA;
      end
      R_WAIT: if (r_wait_q == 0) rstate_d = R_DATA;
      R_DATA: begin noc_resp.r_valid = 1'b1; if (noc_req.r_ready) rstate_d = (r_cnt_q == r_len_q) ? R_IDLE : R_DATA; end
      default: rstate_d = R_IDLE;
    endcase
    wstate_d = wstate;
    noc_resp.aw_ready = 1'b0; noc_resp.w_ready = 1'b0; noc_resp.b_valid = 1'b0;
    noc_resp.b.id = w_id_q; noc_resp.b.resp = axi_pkg::RESP_OKAY; noc_resp.b.user = '0;
    case (wstate)
      W_IDLE: begin noc_resp.aw_ready = 1'b1; if (noc_req.aw_valid) wstate_d = W_DATA; end
      W_DATA: begin noc_resp.w_ready = 1'b1; if (noc_req.w_valid && noc_req.w.last) wstate_d = W_B; end
      W_B:    begin noc_resp.b_valid = 1'b1; if (noc_req.b_ready) wstate_d = W_IDLE; end
      default: wstate_d = W_IDLE;
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; r_addr_q <= '0; r_id_q <= '0; r_len_q <= '0; r_cnt_q <= '0; r_data_q <= '0;
      r_err_q <= 1'b0; r_wait_q <= 0;
      wstate <= W_IDLE; w_addr_q <= '0; w_id_q <= '0;
    end else begin
      rstate <= rstate_d; wstate <= wstate_d;
      if (rstate == R_IDLE && noc_req.ar_valid) begin
        r_addr_q <= noc_req.ar.addr; r_id_q <= noc_req.ar.id; r_len_q <= 8'(noc_req.ar.len); r_cnt_q <= '0;
        r_err_q  <= err_en && (noc_req.ar.addr == err_addr);
        r_wait_q <= err_lat;
      end
      if (rstate == R_WAIT && r_wait_q != 0) r_wait_q <= r_wait_q - 1;
      if (rstate == R_WAIT && r_wait_q == 0 && r_cnt_q == '0)
        $display("BUSERR RESP   cyc=%0d addr=%08x (held %0d cycles)", cycle_cnt, r_addr_q, err_lat);
      if (rstate == R_DATA && noc_req.r_ready) begin
        r_data_q <= rdata(r_addr_q + 8*(64'(r_cnt_q) + 64'd1));
        if (r_cnt_q != r_len_q) r_cnt_q <= r_cnt_q + 1;
      end
      if (rstate == R_IDLE && rstate_d == R_DATA) r_data_q <= rdata(noc_req.ar.addr);
      if (wstate == W_IDLE && noc_req.aw_valid) begin w_addr_q <= noc_req.aw.addr; w_id_q <= noc_req.aw.id; end
      if (wstate == W_DATA && noc_req.w_valid) begin
        for (int i = 0; i < DATAW/8; i++)
          if (noc_req.w.strb[i]) begin
            automatic logic [63:0] ba = w_addr_q + 64'(i);
            if (in_mem(ba)) mem[widx(ba)][8*i +: 8] <= noc_req.w.data[8*i +: 8];
          end
      end
    end
  end

  // --------------------------------------------------------------- CVXIF stub
  cvxif_req_t  cvxif_req;
  cvxif_resp_t cvxif_resp;

  cvxif_copro_stub #(.XLEN(C.XLEN), .IDW(C.X_ID_WIDTH), .LAT(40)) copro_i (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .issue_valid_i  (cvxif_req.issue_valid),
      .issue_ready_o  (cvxif_resp.issue_ready),
      .issue_instr_i  (cvxif_req.issue_req.instr),
      .issue_id_i     (cvxif_req.issue_req.id),
      .result_ready_i (cvxif_req.result_ready),
      .result_valid_o (cvxif_resp.result_valid),
      .result_id_o    (cvxif_resp.result.id),
      .result_rd_o    (cvxif_resp.result.rd),
      .result_data_o  (cvxif_resp.result.data),
      .result_we_o    (cvxif_resp.result.we)
  );
  assign cvxif_resp.compressed_ready           = 1'b1;
  assign cvxif_resp.compressed_resp            = '0;
  assign cvxif_resp.issue_resp.accept          = 1'b1;
  assign cvxif_resp.issue_resp.writeback       = '1;
  assign cvxif_resp.issue_resp.register_read   = '1;
  assign cvxif_resp.register_ready             = 1'b1;
  assign cvxif_resp.result.hartid              = cvxif_req.issue_req.hartid;

  // --------------------------------------------------------------- core DUT
  cva6 #(
      .axi_ar_chan_t(ar_t), .axi_aw_chan_t(aw_t), .axi_w_chan_t(w_t),
      .b_chan_t(b_t), .r_chan_t(r_t), .noc_req_t(noc_req_t), .noc_resp_t(noc_resp_t),
      .cvxif_req_t(cvxif_req_t), .cvxif_resp_t(cvxif_resp_t)
  ) dut (
      .clk_i      (clk),
      .rst_ni     (rst_n),
      .boot_addr_i(BASE),
      .hart_id_i  ('0),
      .irq_i      ('0),
      .ipi_i      (1'b0),
      .time_irq_i (1'b0),
      .debug_req_i(1'b0),
      .rvfi_probes_o(),
      .cvxif_req_o (cvxif_req),
      .cvxif_resp_i(cvxif_resp),
      .noc_req_o   (noc_req),
      .noc_resp_i  (noc_resp)
  );

  // --------------------------------------------------------------- tracing
  int unsigned cycle_cnt = 0;
  int unsigned trace_n = 0;
  bit          trace_on = 1'b0;
  string       dump_file = "dump.txt";
  string       mem_file  = "prog.hex";
  string       wave_file = "";
  int          max_cycles = 20000;

  always @(posedge clk) if (rst_n) begin
    cycle_cnt <= cycle_cnt + 1;

    if (cvxif_req.issue_valid && cvxif_resp.issue_ready)
      $display("CVXIF ISSUE   cyc=%0d id=%0d instr=%08x", cycle_cnt, cvxif_req.issue_req.id, cvxif_req.issue_req.instr);
    if (cvxif_req.commit_valid)
      $display("CVXIF COMMIT  cyc=%0d id=%0d kill=%b", cycle_cnt, cvxif_req.commit.id, cvxif_req.commit.commit_kill);
    if (cvxif_resp.result_valid && cvxif_req.result_ready)
      $display("CVXIF RESULT  cyc=%0d id=%0d rd=x%0d data=%0d we=%b", cycle_cnt,
               cvxif_resp.result.id, cvxif_resp.result.rd, cvxif_resp.result.data, cvxif_resp.result.we);

    if (dut.issue_stage_i.issue_instr_valid_sb_iro[0])
      $display("ISSUE_PRESENT cyc=%0d pc=%08x fu=%s", cycle_cnt,
               dut.issue_stage_i.issue_instr_sb_iro[0].pc, dut.issue_stage_i.issue_instr_sb_iro[0].fu.name());
    // does the write-back bus deliver a CVXIF result for an id whose slot is
    // currently issued (i.e. will the scoreboard accept it)?
    for (int w = 0; w < C.NrWbPorts; w++)
      if (dut.issue_stage_i.i_scoreboard.wt_valid_i[w] && (w == ariane_pkg::X_WB) &&
          !dut.issue_stage_i.i_scoreboard.mem_q[dut.issue_stage_i.i_scoreboard.trans_id_i[w]].issued)
        $display("WB DROPPED    cyc=%0d port=%0d id=%0d (slot not issued)", cycle_cnt, w,
                 dut.issue_stage_i.i_scoreboard.trans_id_i[w]);
    for (int w = 0; w < C.NrWbPorts; w++)
      if (dut.issue_stage_i.i_scoreboard.wt_valid_i[w] &&
          dut.issue_stage_i.i_scoreboard.mem_q[dut.issue_stage_i.i_scoreboard.trans_id_i[w]].issued)
        $display("WB ACCEPT     cyc=%0d port=%0d id=%0d slot_fu=%s slot_pc=%08x", cycle_cnt, w,
                 dut.issue_stage_i.i_scoreboard.trans_id_i[w],
                 dut.issue_stage_i.i_scoreboard.mem_q[dut.issue_stage_i.i_scoreboard.trans_id_i[w]].sbe.fu.name(),
                 dut.issue_stage_i.i_scoreboard.mem_q[dut.issue_stage_i.i_scoreboard.trans_id_i[w]].sbe.pc);

    if (dut.flush_ctrl_ex) $display("FLUSH_EX      cyc=%0d", cycle_cnt);
    if (dut.flush_unissued_instr_ctrl_id) $display("FLUSH_UNISSUED cyc=%0d", cycle_cnt);
    if (dut.commit_stage_i.commit_ack_o[0])
      $display("COMMIT        cyc=%0d pc=%08x fu=%s", cycle_cnt,
               dut.commit_stage_i.commit_instr_i[0].pc, dut.commit_stage_i.commit_instr_i[0].fu.name());

    if (trace_on && dut.rvfi_probes_o.instr.commit_ack[0])
      $display("RVFI %0d cyc=%0d pc=%08x insn=%08x priv=%0d trap=%b",
               trace_n, cycle_cnt, dut.rvfi_probes_o.instr.commit_instr_pc[0],
               dut.rvfi_probes_o.instr.instruction[0], dut.rvfi_probes_o.instr.priv_lvl,
               dut.rvfi_probes_o.instr.ex_commit_valid);
  end

  int fh;
  always @(posedge clk) if (rst_n) begin
    if (in_mem(DONE_ADDR) && mem[widx(DONE_ADDR)] == 64'h00000000DEADBEEF) begin
      fh = $fopen(dump_file, "w");
      $fwrite(fh, "RESULT      COMPLETED\n");
      $fwrite(fh, "R_A0    %08x   // CV-X-IF destination register\n", mem[widx(BASE+64'h1008)][31:0]);
      $fwrite(fh, "R_S3    %08x   // addi s3,t1,300 : 306 correct\n", mem[widx(BASE+64'h1010)][31:0]);
      $fwrite(fh, "R_S2    %08x   // addi s2,t1,200 : 206 correct, 1 = stale CVXIF result\n", mem[widx(BASE+64'h1018)][31:0]);
      $fwrite(fh, "R_S1    %08x   // addi s1,t1,100 : 106 correct\n", mem[widx(BASE+64'h1020)][31:0]);      $fclose(fh);
      $display("DONE cycles=%0d R_A0=%08x R_S3=%08x R_S2=%08x R_S1=%08x", cycle_cnt,
               mem[widx(BASE+64'h1008)][31:0], mem[widx(BASE+64'h1010)][31:0],
               mem[widx(BASE+64'h1018)][31:0], mem[widx(BASE+64'h1020)][31:0]);
      $finish;
    end
    if (cycle_cnt > max_cycles) begin
      fh = $fopen(dump_file, "w");
      $fwrite(fh, "RESULT      TIMEOUT\n");
      $fwrite(fh, "R_A0    %08x\n", mem[widx(R_A0)][31:0]);
      $fclose(fh);
      $display("TIMEOUT cycles=%0d R_A0=%08x", cycle_cnt, mem[widx(R_A0)][31:0]);
      $finish;
    end
  end

  initial begin
    if (!$value$plusargs("mem=%s",   mem_file)) mem_file = "prog.hex";
    if (!$value$plusargs("dump=%s",  dump_file)) dump_file = "dump.txt";
    void'($value$plusargs("trace=%d", trace_on));
    void'($value$plusargs("max_cycles=%d", max_cycles));
    void'($value$plusargs("err_addr=%h", err_addr));
    void'($value$plusargs("err_lat=%d", err_lat));
    if (!$value$plusargs("wave=%s",  wave_file)) wave_file = "";

    for (int i = 0; i < MEM_WORDS; i++) mem[i] = 64'h0000000000000013;
    $readmemh(mem_file, mem);

    $display("CFG XLEN=%0d CvxifEn=%b X_ID_WIDTH=%0d X_NUM_RS=%0d X_DUALREAD=%0d",
             C.XLEN, C.CvxifEn, C.X_ID_WIDTH, C.X_NUM_RS, C.X_DUALREAD);
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    if (wave_file != "") begin
      $fsdbDumpfile(wave_file);
      $fsdbDumpvars(0, tb_cva6_cvxif);
    end
  end

endmodule

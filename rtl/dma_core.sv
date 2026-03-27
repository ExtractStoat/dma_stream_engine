module dma_core #(
  parameter int W  = 16,
  parameter int AW = 10,
  parameter int FIFO_DEPTH = 64,
  parameter int FIFO_SYNC_STAGES = 2
) (
  // clocks/resets
  input  logic              cfg_clk,
  input  logic              cfg_rst_n,
  input  logic              dat_clk,
  input  logic              dat_rst_n,

  // simple cfg bus
  input  logic              cfg_wr_en,
  input  logic [7:0]        cfg_wr_addr,
  input  logic [31:0]       cfg_wr_data,
  input  logic              cfg_rd_en,
  input  logic [7:0]        cfg_rd_addr,
  output logic [31:0]       cfg_rd_data,

  // destination stream (cfg_clk)
  output logic              dst_valid,
  output logic [W-1:0]      dst_data,
  output logic              dst_last,
  input  logic              dst_ready,

  // RAM read interface (dat_clk) - external RAM provides data
  output logic              ram_rd_en,
  output logic [AW-1:0]     ram_rd_addr,
  input  logic [W-1:0]      ram_rd_data,

  // optional interrupt
  output logic              irq
);

  // ---------- cfg regs outputs ----------
  logic [AW-1:0] src_addr_cfg;
  logic [31:0]   len_cfg;
  logic          irq_en_cfg;
  logic          cmd_toggle_cfg;

  // ---------- status back into cfg ----------
  logic busy_cfg;
  logic done_pulse_cfg, err_pulse_cfg, fifo_ovf_pulse_cfg, dst_stall_pulse_cfg;

  // ---------- cmd into dat ----------
  logic start_pulse_dat;
  logic [AW-1:0] src_addr_dat;
  logic [31:0]   len_dat;

  // ---------- dat side status/events ----------
  logic busy_dat;
  logic done_event_dat, err_event_dat, fifo_ovf_event_dat;

  // ---------- FIFO wires ----------
  localparam int FIFO_W = W + 1; // {last,data}

  logic              fifo_wr_en;
  logic [FIFO_W-1:0] fifo_wr_data;
  logic              fifo_full;

  logic              fifo_rd_en;
  logic [FIFO_W-1:0] fifo_rd_data;
  logic              fifo_empty;

  // ---------- stream-out stall event (cfg) ----------
  logic dst_stall_event_cfg;

  // ========== cfg domain regs ==========
  dma_regs #(
    .AW(AW)
  ) u_regs (
    .cfg_clk(cfg_clk),
    .cfg_rst_n(cfg_rst_n),

    .cfg_wr_en(cfg_wr_en),
    .cfg_wr_addr(cfg_wr_addr),
    .cfg_wr_data(cfg_wr_data),
    .cfg_rd_en(cfg_rd_en),
    .cfg_rd_addr(cfg_rd_addr),
    .cfg_rd_data(cfg_rd_data),

    .src_addr_cfg(src_addr_cfg),
    .len_cfg(len_cfg),
    .irq_en_cfg(irq_en_cfg),
    .cmd_toggle_cfg(cmd_toggle_cfg),

    .busy_cfg(busy_cfg),
    .done_pulse_cfg(done_pulse_cfg),
    .err_pulse_cfg(err_pulse_cfg),
    .fifo_ovf_pulse_cfg(fifo_ovf_pulse_cfg),
    .dst_stall_pulse_cfg(dst_stall_pulse_cfg),

    .irq(irq)
  );

  // ========== cmd CDC cfg->dat ==========
  dma_cmd_cdc #(
    .AW(AW)
  ) u_cmd_cdc (
    .cfg_clk(cfg_clk),
    .cfg_rst_n(cfg_rst_n),
    .dat_clk(dat_clk),
    .dat_rst_n(dat_rst_n),

    .cmd_toggle_cfg(cmd_toggle_cfg),
    .src_addr_cfg(src_addr_cfg),
    .len_cfg(len_cfg),

    .start_pulse_dat(start_pulse_dat),
    .src_addr_dat(src_addr_dat),
    .len_dat(len_dat)
  );

  // ========== dat controller ==========
  dma_ctrl_dat #(
    .W(W),
    .AW(AW)
  ) u_ctrl_dat (
    .dat_clk(dat_clk),
    .dat_rst_n(dat_rst_n),

    .start_pulse_dat(start_pulse_dat),
    .src_addr_dat(src_addr_dat),
    .len_dat(len_dat),

    .busy_dat(busy_dat),
    .done_event_dat(done_event_dat),
    .err_event_dat(err_event_dat),
    .fifo_ovf_event_dat(fifo_ovf_event_dat),

    .ram_rd_en(ram_rd_en),
    .ram_rd_addr(ram_rd_addr),
    .ram_rd_data(ram_rd_data),

    .fifo_full(fifo_full),
    .fifo_wr_en(fifo_wr_en),
    .fifo_wr_data(fifo_wr_data)
  );

  // ========== async FIFO ==========
  async_fifo #(
    .DATA_W(FIFO_W),
    .DEPTH(FIFO_DEPTH),
    .SYNC_STAGES(FIFO_SYNC_STAGES)
  ) u_fifo (
    .wr_clk(dat_clk),
    .wr_rst_n(dat_rst_n),
    .wr_en(fifo_wr_en),
    .wr_data(fifo_wr_data),
    .wr_full(fifo_full),

    .rd_clk(cfg_clk),
    .rd_rst_n(cfg_rst_n),
    .rd_en(fifo_rd_en),
    .rd_data(fifo_rd_data),
    .rd_empty(fifo_empty)
  );

  // ========== stream out (cfg domain) ==========
  dma_stream_out #(
    .W(W),
    .STALL_TIMEOUT_CYCLES(0)
  ) u_stream_out (
    .cfg_clk(cfg_clk),
    .cfg_rst_n(cfg_rst_n),

    .fifo_empty(fifo_empty),
    .fifo_rd_data(fifo_rd_data),
    .fifo_rd_en(fifo_rd_en),

    .dst_valid(dst_valid),
    .dst_data(dst_data),
    .dst_last(dst_last),
    .dst_ready(dst_ready),

    .dst_stall_event(dst_stall_event_cfg)
  );

  assign dst_stall_pulse_cfg = dst_stall_event_cfg;

  // ========== status CDC dat->cfg ==========
  dma_status_cdc u_status_cdc (
    .dat_clk(dat_clk),
    .dat_rst_n(dat_rst_n),
    .cfg_clk(cfg_clk),
    .cfg_rst_n(cfg_rst_n),

    .busy_dat(busy_dat),
    .done_event_dat(done_event_dat),
    .err_event_dat(err_event_dat),
    .fifo_ovf_event_dat(fifo_ovf_event_dat),

    .busy_cfg(busy_cfg),
    .done_pulse_cfg(done_pulse_cfg),
    .err_pulse_cfg(err_pulse_cfg),
    .fifo_ovf_pulse_cfg(fifo_ovf_pulse_cfg)
  );

endmodule
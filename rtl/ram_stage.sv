// Integration layer for RAM IP to keep dma_core portable
module ram_stage #(
  parameter int W  = 16,
  parameter int AW = 10
) (
  input  logic              cfg_clk,
  input  logic              cfg_rst_n,
  input  logic              dat_clk,
  input  logic              dat_rst_n,

  // cfg bus
  input  logic              cfg_wr_en,
  input  logic [7:0]        cfg_wr_addr,
  input  logic [31:0]       cfg_wr_data,
  input  logic              cfg_rd_en,
  input  logic [7:0]        cfg_rd_addr,
  output logic [31:0]       cfg_rd_data,

  // stream out
  output logic              dst_valid,
  output logic [W-1:0]      dst_data,
  output logic              dst_last,
  input  logic              dst_ready,

  output logic              irq,

  // External RAM write port 
  input  logic              ram_wr_en,
  input  logic [AW-1:0]     ram_wr_addr,
  input  logic [W-1:0]      ram_wr_data
);

  // DMA -> RAM read signals
  logic              ram_rd_en;
  logic [AW-1:0]     ram_rd_addr;
  logic [W-1:0]      ram_rd_data;

  // DMA core
  dma_core #(
    .W(W),
    .AW(AW)
  ) u_dma (
    .cfg_clk(cfg_clk),
    .cfg_rst_n(cfg_rst_n),
    .dat_clk(dat_clk),
    .dat_rst_n(dat_rst_n),

    .cfg_wr_en(cfg_wr_en),
    .cfg_wr_addr(cfg_wr_addr),
    .cfg_wr_data(cfg_wr_data),
    .cfg_rd_en(cfg_rd_en),
    .cfg_rd_addr(cfg_rd_addr),
    .cfg_rd_data(cfg_rd_data),

    .dst_valid(dst_valid),
    .dst_data(dst_data),
    .dst_last(dst_last),
    .dst_ready(dst_ready),

    .ram_rd_en(ram_rd_en),
    .ram_rd_addr(ram_rd_addr),
    .ram_rd_data(ram_rd_data),

    .irq(irq)
  );

  // Altera dual-port RAM IP
  ram_dual u_ram (
    .data      (ram_wr_data),
    .rdaddress (ram_rd_addr),
    .rdclock   (dat_clk),
    .rden      (ram_rd_en),
    .wraddress (ram_wr_addr),
    .wrclock   (cfg_clk),
    .wren      (ram_wr_en),
    .q         (ram_rd_data)
  );

endmodule
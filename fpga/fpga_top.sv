module fpga_top (
  input  logic CLOCK_50,
  input  logic [1:0] KEY,
  output logic [9:0] LEDR
);


  //Clocks
  logic cfg_clk, dat_clk, CLOCK_100;
  pll_100MHz	pll_100MHz_inst (
	.inclk0 ( CLOCK_50 ),
	.c0 ( CLOCK_100 )
	);

  assign cfg_clk = CLOCK_50;
  assign dat_clk = CLOCK_100;

  logic rst_n;
  assign rst_n = KEY[0];

  // interconnect signals between selftest and ram_stage
  logic cfg_wr_en, cfg_rd_en;
  logic [7:0] cfg_wr_addr, cfg_rd_addr;
  logic [31:0] cfg_wr_data, cfg_rd_data;

  logic ram_wr_en;
  logic [9:0] ram_wr_addr;
  logic [15:0] ram_wr_data;

  logic dst_valid, dst_ready, dst_last;
  logic [15:0] dst_data;
  logic irq;

  ram_stage u_ram_stage (
    .cfg_clk(cfg_clk), .cfg_rst_n(rst_n),
    .dat_clk(dat_clk), .dat_rst_n(rst_n),

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

    .irq(irq),

    .ram_wr_en(ram_wr_en),
    .ram_wr_addr(ram_wr_addr),
    .ram_wr_data(ram_wr_data)
  );

  logic running, pass, fail, done_seen, mismatch_seen;

  dma_selftest u_test (
    .cfg_clk(cfg_clk), .cfg_rst_n(rst_n),
    .dat_clk(dat_clk), .dat_rst_n(rst_n),

    .start(~KEY[1]),

    .cfg_wr_en(cfg_wr_en),
    .cfg_wr_addr(cfg_wr_addr),
    .cfg_wr_data(cfg_wr_data),
    .cfg_rd_en(cfg_rd_en),
    .cfg_rd_addr(cfg_rd_addr),
    .cfg_rd_data(cfg_rd_data),

    .ram_wr_en(ram_wr_en),
    .ram_wr_addr(ram_wr_addr),
    .ram_wr_data(ram_wr_data),

    .dst_valid(dst_valid),
    .dst_data(dst_data),
    .dst_last(dst_last),
    .dst_ready(dst_ready),

    .running(running),
    .pass(pass),
    .fail(fail),
    .done_seen(done_seen),
    .mismatch_seen(mismatch_seen)
  );

  // Heartbeat/Activity LEDs
  assign LEDR[0] = running;
  assign LEDR[1] = pass;
  assign LEDR[2] = fail;
  assign LEDR[3] = mismatch_seen;
  assign LEDR[4] = done_seen;
  //assign LEDR[8:5] = 4'd0;
  assign LEDR[9] = irq;

endmodule
// Domain crossing from 'cfg_clk to 'dat_clk
// Simple 2FF synchronizers + edge capture for start_pulse
module dma_cmd_cdc #(
  parameter int AW = 10
) (
  input  logic cfg_clk,
  input  logic cfg_rst_n,
  input  logic dat_clk,
  input  logic dat_rst_n,

  input  logic          cmd_toggle_cfg,
  input  logic [AW-1:0] src_addr_cfg,
  input  logic [31:0]   len_cfg,

  output logic          start_pulse_dat,
  output logic [AW-1:0] src_addr_dat,
  output logic [31:0]   len_dat
);

  logic cmd_tog_d1, cmd_tog_d2, cmd_tog_d2_q;

  always_ff @(posedge dat_clk or negedge dat_rst_n) begin
    if (!dat_rst_n) begin
      cmd_tog_d1 <= 1'b0;
      cmd_tog_d2 <= 1'b0;
      cmd_tog_d2_q <= 1'b0;
    end else begin
      cmd_tog_d1   <= cmd_toggle_cfg;
      cmd_tog_d2   <= cmd_tog_d1;
      cmd_tog_d2_q <= cmd_tog_d2;
    end
  end
  wire cmd_edge = cmd_tog_d2 ^ cmd_tog_d2_q;

  logic [AW-1:0] src_d1, src_d2;
  logic [31:0]   len_d1, len_d2;

  always_ff @(posedge dat_clk or negedge dat_rst_n) begin
    if (!dat_rst_n) begin
      src_d1 <= '0; src_d2 <= '0;
      len_d1 <= '0; len_d2 <= '0;
      start_pulse_dat <= 1'b0;
    end else begin
      start_pulse_dat <= cmd_edge; // registered pulse

      src_d1 <= src_addr_cfg;
      src_d2 <= src_d1;

      len_d1 <= len_cfg;
      len_d2 <= len_d1;
    end
  end

  // continuously available synced parameters
  assign src_addr_dat = src_d2;
  assign len_dat      = len_d2;

endmodule
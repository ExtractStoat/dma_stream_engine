// Domain crossing of flags from 'dat_clk to 'cfg_clk
// Turns pulses to toggles for stable cdc (fast->slow)
module dma_status_cdc (
  input  logic dat_clk,
  input  logic dat_rst_n,
  input  logic cfg_clk,
  input  logic cfg_rst_n,

  input  logic busy_dat,
  input  logic done_event_dat,
  input  logic err_event_dat,
  input  logic fifo_ovf_event_dat,

  output logic busy_cfg,
  output logic done_pulse_cfg,
  output logic err_pulse_cfg,
  output logic fifo_ovf_pulse_cfg
);

  // busy level sync (2FF)
  logic busy_d1, busy_d2;
  always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
    if (!cfg_rst_n) begin
      busy_d1 <= 1'b0;
      busy_d2 <= 1'b0;
    end else begin
      busy_d1 <= busy_dat;
      busy_d2 <= busy_d1;
    end
  end
  assign busy_cfg = busy_d2;

  // event toggles in dat domain
  logic done_tog_dat, err_tog_dat, ovf_tog_dat;

  always_ff @(posedge dat_clk or negedge dat_rst_n) begin
    if (!dat_rst_n) begin
      done_tog_dat <= 1'b0;
      err_tog_dat  <= 1'b0;
      ovf_tog_dat  <= 1'b0;
    end else begin
      if (done_event_dat) done_tog_dat <= ~done_tog_dat;
      if (err_event_dat)  err_tog_dat  <= ~err_tog_dat;
      if (fifo_ovf_event_dat) ovf_tog_dat <= ~ovf_tog_dat;
    end
  end

  // sync toggles into cfg and edge detect to make pulses
  logic done_d1, done_d2, done_d2_q;
  logic err_d1,  err_d2,  err_d2_q;
  logic ovf_d1,  ovf_d2,  ovf_d2_q;

  always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
    if (!cfg_rst_n) begin
      done_d1 <= 1'b0; done_d2 <= 1'b0; done_d2_q <= 1'b0;
      err_d1  <= 1'b0; err_d2  <= 1'b0; err_d2_q  <= 1'b0;
      ovf_d1  <= 1'b0; ovf_d2  <= 1'b0; ovf_d2_q  <= 1'b0;
    end else begin
      done_d1   <= done_tog_dat;
      done_d2   <= done_d1;
      done_d2_q <= done_d2;

      err_d1    <= err_tog_dat;
      err_d2    <= err_d1;
      err_d2_q  <= err_d2;

      ovf_d1    <= ovf_tog_dat;
      ovf_d2    <= ovf_d1;
      ovf_d2_q  <= ovf_d2;
    end
  end

  assign done_pulse_cfg     = done_d2 ^ done_d2_q;
  assign err_pulse_cfg      = err_d2  ^ err_d2_q;
  assign fifo_ovf_pulse_cfg = ovf_d2  ^ ovf_d2_q;

endmodule
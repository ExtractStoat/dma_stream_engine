module dma_regs #(
  parameter int AW = 10
) (
  input  logic        cfg_clk,
  input  logic        cfg_rst_n,

  input  logic        cfg_wr_en,
  input  logic [7:0]  cfg_wr_addr,
  input  logic [31:0] cfg_wr_data,
  input  logic        cfg_rd_en,
  input  logic [7:0]  cfg_rd_addr,
  output logic [31:0] cfg_rd_data,

  output logic [AW-1:0] src_addr_cfg,
  output logic [31:0]   len_cfg,
  output logic          irq_en_cfg,
  output logic          cmd_toggle_cfg,

  input  logic          busy_cfg,
  input  logic          done_pulse_cfg,
  input  logic          err_pulse_cfg,
  input  logic          fifo_ovf_pulse_cfg,
  input  logic          dst_stall_pulse_cfg,

  output logic          irq
);

  // reg offsets
  localparam logic [7:0] REG_SRC   = 8'h00;
  localparam logic [7:0] REG_LEN   = 8'h04;
  localparam logic [7:0] REG_CTRL  = 8'h08;
  localparam logic [7:0] REG_STAT  = 8'h0C;

  // status bits (sticky)
  logic done_sticky, err_sticky, fifo_ovf_sticky, dst_stall_sticky;

  // Control fields (latched)
  // start is write 1 to start
  // irq_en is latched
  // abort reserved
  always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
    if (!cfg_rst_n) begin
      src_addr_cfg      <= '0;
      len_cfg           <= '0;
      irq_en_cfg        <= 1'b0;
      cmd_toggle_cfg    <= 1'b0;

      done_sticky       <= 1'b0;
      err_sticky        <= 1'b0;
      fifo_ovf_sticky   <= 1'b0;
      dst_stall_sticky  <= 1'b0;
    end else begin
      // latch incoming event pulses into sticky bits
      if (done_pulse_cfg)      done_sticky      <= 1'b1;
      if (err_pulse_cfg)       err_sticky       <= 1'b1;
      if (fifo_ovf_pulse_cfg)  fifo_ovf_sticky  <= 1'b1;
      if (dst_stall_pulse_cfg) dst_stall_sticky <= 1'b1;

      if (cfg_wr_en) begin
        unique case (cfg_wr_addr)
          REG_SRC: begin
            if (!busy_cfg) src_addr_cfg <= cfg_wr_data[AW-1:0];
          end
          REG_LEN: begin
            if (!busy_cfg) len_cfg <= cfg_wr_data;
          end
          REG_CTRL: begin
            // irq_en
            if (!busy_cfg) irq_en_cfg <= cfg_wr_data[1];

            // write 1 to start, ignored if busy
            if (cfg_wr_data[0] && !busy_cfg) begin
              // clear sticky status on new start
              done_sticky      <= 1'b0;
              err_sticky       <= 1'b0;
              fifo_ovf_sticky  <= 1'b0;
              dst_stall_sticky <= 1'b0;

              cmd_toggle_cfg   <= ~cmd_toggle_cfg;
            end
          end
          REG_STAT: begin
            // W1C behavior
            if (cfg_wr_data[1]) done_sticky      <= 1'b0;
            if (cfg_wr_data[2]) err_sticky       <= 1'b0;
            if (cfg_wr_data[3]) fifo_ovf_sticky  <= 1'b0;
            if (cfg_wr_data[4]) dst_stall_sticky <= 1'b0;
          end
          default: ;
        endcase
      end
    end
  end

  // read mux
  always_comb begin
    cfg_rd_data = 32'h0;
    if (cfg_rd_en) begin
      unique case (cfg_rd_addr)
        REG_SRC:  cfg_rd_data = {{(32-AW){1'b0}}, src_addr_cfg};
        REG_LEN:  cfg_rd_data = len_cfg;
        REG_CTRL: cfg_rd_data = {29'h0, 1'b0 /*abort*/, irq_en_cfg, 1'b0 /*start*/};
        REG_STAT: cfg_rd_data = {
          27'h0,
          dst_stall_sticky,
          fifo_ovf_sticky,
          err_sticky,
          done_sticky,
          busy_cfg
        };
        default: cfg_rd_data = 32'h0;
      endcase
    end
  end

  // irq when done sticky and enabled
  assign irq = irq_en_cfg && done_sticky;

endmodule
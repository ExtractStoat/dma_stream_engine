module dma_stream_out #(
  parameter int W = 16,
  parameter int STALL_TIMEOUT_CYCLES = 0 // 0 disables
) (
  input  logic         cfg_clk,
  input  logic         cfg_rst_n,

  input  logic         fifo_empty,
  input  logic [W:0]   fifo_rd_data,   // {last,data}
  output logic         fifo_rd_en,

  output logic         dst_valid,
  output logic [W-1:0] dst_data,
  output logic         dst_last,
  input  logic         dst_ready,

  output logic         dst_stall_event
);

  logic       hold_valid;
  logic [W:0] hold_data;

  // two-stage pending to handle registered rd_data (FIFO)
  logic rd_pend1;
  logic rd_pend2;

  // outputs
  assign dst_valid = hold_valid;
  assign dst_data  = hold_data[W-1:0];
  assign dst_last  = hold_data[W];

  // optional stall counter (needs testing)
  logic [$clog2((STALL_TIMEOUT_CYCLES<2)?2:STALL_TIMEOUT_CYCLES+1)-1:0] stall_cnt;

  always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
    if (!cfg_rst_n) begin
      hold_valid      <= 1'b0;
      hold_data       <= '0;
      rd_pend1        <= 1'b0;
      rd_pend2        <= 1'b0;
      fifo_rd_en      <= 1'b0;
      dst_stall_event <= 1'b0;
      stall_cnt       <= '0;
    end else begin
      // defaults
      fifo_rd_en      <= 1'b0;
      dst_stall_event <= 1'b0;

      // advance pending pipeline
      rd_pend2 <= rd_pend1;
      rd_pend1 <= 1'b0;

      // capture FIFO rd_data when it is now stable for sampling (2 cycles after rd_en)
      if (rd_pend2) begin
        hold_data  <= fifo_rd_data;
        hold_valid <= 1'b1;
      end

      // consume when handshake occurs 
      if (hold_valid && dst_ready) begin
        hold_valid <= 1'b0;
      end

      // Issue read when we need a word and nothing is already in flight
      // in-flight means rd_pend1 or rd_pend2 set, or hold_valid already filled.
      if (!hold_valid && !rd_pend1 && !rd_pend2 && !fifo_empty) begin
        fifo_rd_en <= 1'b1;
        rd_pend1   <= 1'b1;
      end

      // After consuming a word, request next if available
      if (hold_valid && dst_ready) begin
        if (!rd_pend1 && !rd_pend2 && !fifo_empty) begin
          fifo_rd_en <= 1'b1;
          rd_pend1   <= 1'b1;
        end
      end

      // Optional stall timeout
      if (STALL_TIMEOUT_CYCLES == 0) begin
        stall_cnt <= '0;
      end else begin
        if (hold_valid && !dst_ready) begin
          if (stall_cnt == STALL_TIMEOUT_CYCLES[$bits(stall_cnt)-1:0]) begin
            dst_stall_event <= 1'b1;
          end else begin
            stall_cnt <= stall_cnt + 1'b1;
          end
        end else begin
          stall_cnt <= '0;
        end
      end
    end
  end

endmodule
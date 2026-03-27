module dma_selftest #(
  parameter int W  = 16,
  parameter int AW = 10,
  parameter int LEN_WORDS = 256,
  parameter logic [W-1:0] LFSR_SEED = 16'hACE1,
  parameter bit RANDOM_BACKPRESSURE = 0
) (
  input  logic cfg_clk,
  input  logic cfg_rst_n,   // active low reset handled externally if desired
  input  logic dat_clk,
  input  logic dat_rst_n,

  // start pulse in cfg_clk domain
  input  logic start,

  // Hook to fpga_top (DMA config bus)
  output logic        cfg_wr_en,
  output logic [7:0]  cfg_wr_addr,
  output logic [31:0] cfg_wr_data,
  output logic        cfg_rd_en,
  output logic [7:0]  cfg_rd_addr,
  input  logic [31:0] cfg_rd_data,

  // RAM write port into fpga_top
  output logic              ram_wr_en,
  output logic [AW-1:0]     ram_wr_addr,
  output logic [W-1:0]      ram_wr_data,

  // Stream from fpga_top
  input  logic              dst_valid,
  input  logic [W-1:0]      dst_data,
  input  logic              dst_last,
  output logic              dst_ready,

  // Status outputs (to LEDs, etc.)
  output logic running,
  output logic pass,
  output logic fail,
  output logic done_seen,
  output logic mismatch_seen
);

  // Register map (byte offsets)
  localparam byte REG_SRC  = 8'h00;
  localparam byte REG_LEN  = 8'h04;
  localparam byte REG_CTRL = 8'h08;
  localparam byte REG_STAT = 8'h0C;

  // Simple LFSR (Galois)
  function automatic logic [W-1:0] lfsr_step(input logic [W-1:0] s);
    logic feedback;
    begin
      // taps for 16-bit: x^16 + x^14 + x^13 + x^11  (0xB400)
      feedback = s[0];
      lfsr_step = {1'b0, s[W-1:1]};
      if (feedback) lfsr_step ^= W'(16'hB400);
    end
  endfunction

  // Random back pressure function
  function automatic logic lfsr_ready_bit(input logic [W-1:0] s);
  logic [W-1:0] nxt;
  begin
    nxt = lfsr_step(s);
    lfsr_ready_bit = nxt[0];
  end
  endfunction

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_FILL_RAM,
    ST_DMA_CFG0,
    ST_DMA_CFG1,
    ST_DMA_CFG2,
    ST_DMA_START,
    ST_RUN_CHECK,
    ST_POLL_DONE,
    ST_CLEAR_DONE,
    ST_DONE
  } st_t;

  st_t st;

  // counters / state
  logic [AW-1:0] wr_idx;
  logic [31:0]   rx_count;
  logic [W-1:0]  lfsr_wr;
  logic [W-1:0]  lfsr_exp;

  // start edge detect
  logic start_d;
  always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
    if (!cfg_rst_n) start_d <= 1'b0;
    else           start_d <= start;
  end
  wire start_pulse = start & ~start_d;

  // default outputs
  always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
    if (!cfg_rst_n) begin
      cfg_wr_en <= 1'b0; cfg_wr_addr <= '0; cfg_wr_data <= '0;
      cfg_rd_en <= 1'b0; cfg_rd_addr <= '0;

      ram_wr_en <= 1'b0; ram_wr_addr <= '0; ram_wr_data <= '0;

      dst_ready <= 1'b0;

      running <= 1'b0;
      pass <= 1'b0;
      fail <= 1'b0;
      done_seen <= 1'b0;
      mismatch_seen <= 1'b0;

      st <= ST_IDLE;
      wr_idx <= '0;
      rx_count <= 32'd0;
      lfsr_wr <= LFSR_SEED;
      lfsr_exp <= LFSR_SEED;
    end else begin
      // defaults each cycle
      cfg_wr_en <= 1'b0;
      cfg_rd_en <= 1'b0;
      ram_wr_en <= 1'b0;

      // Ready policy
      if (!RANDOM_BACKPRESSURE)
        dst_ready <= 1'b1;
      else
        dst_ready <= lfsr_ready_bit(lfsr_exp);

      unique case (st)

        ST_IDLE: begin
          running <= 1'b0;
          if (start_pulse) begin
            // reset flags
            pass <= 1'b0; fail <= 1'b0;
            done_seen <= 1'b0; mismatch_seen <= 1'b0;

            // writers/checkers
            wr_idx   <= '0;
            rx_count <= 32'd0;

            lfsr_wr  <= LFSR_SEED;
            lfsr_exp <= LFSR_SEED;

            running <= 1'b1;
            st <= ST_FILL_RAM;
          end
        end

        // Fill RAM sequentially addr 0..LEN_WORDS-1
        ST_FILL_RAM: begin
          ram_wr_en   <= 1'b1;
          ram_wr_addr <= wr_idx;
          ram_wr_data <= lfsr_wr;

          // advance LFSR for next location
          lfsr_wr <= lfsr_step(lfsr_wr);

          if (wr_idx == AW'(LEN_WORDS-1)) begin
            st <= ST_DMA_CFG0;
          end else begin
            wr_idx <= wr_idx + 1'b1;
          end
        end

        // Program DMA regs (SRC=0)
        ST_DMA_CFG0: begin
          cfg_wr_en   <= 1'b1;
          cfg_wr_addr <= REG_SRC;
          cfg_wr_data <= 32'd0;
          st <= ST_DMA_CFG1;
        end

        ST_DMA_CFG1: begin
          cfg_wr_en   <= 1'b1;
          cfg_wr_addr <= REG_LEN;
          cfg_wr_data <= 32'(LEN_WORDS);
          st <= ST_DMA_CFG2;
        end

        ST_DMA_CFG2: begin
          // ensure done is cleared before start
          cfg_wr_en   <= 1'b1;
          cfg_wr_addr <= REG_STAT;
          cfg_wr_data <= 32'h0000_0002; // W1C done
          st <= ST_DMA_START;
        end

        ST_DMA_START: begin
          cfg_wr_en   <= 1'b1;
          cfg_wr_addr <= REG_CTRL;
          cfg_wr_data <= 32'h0000_0001; // start
          // reset expected generator for compare
          lfsr_exp <= LFSR_SEED;
          rx_count <= 32'd0;
          st <= ST_RUN_CHECK;
        end

        // Check streamed output
        ST_RUN_CHECK: begin
          if (dst_valid && dst_ready) begin
            if (dst_data !== lfsr_exp) begin
              mismatch_seen <= 1'b1;
              fail <= 1'b1;
              st <= ST_DONE;
            end

            // last should assert only on final beat
            if (dst_last && (rx_count != (LEN_WORDS-1))) begin
              mismatch_seen <= 1'b1;
              fail <= 1'b1;
              st <= ST_DONE;
            end

            // advance expected
            lfsr_exp <= lfsr_step(lfsr_exp);
            rx_count <= rx_count + 32'd1;

            if (rx_count == (LEN_WORDS-1)) begin
              // consumed final beat
              st <= ST_POLL_DONE;
            end
          end
        end

        // Poll STATUS.done to confirm DMA completion
        ST_POLL_DONE: begin
          cfg_rd_en   <= 1'b1;
          cfg_rd_addr <= REG_STAT;

          if (cfg_rd_data[1]) begin
            done_seen <= 1'b1;
            st <= ST_CLEAR_DONE;
          end
        end

        ST_CLEAR_DONE: begin
          cfg_wr_en   <= 1'b1;
          cfg_wr_addr <= REG_STAT;
          cfg_wr_data <= 32'h0000_0002; // clear done sticky
          st <= ST_DONE;
        end

        ST_DONE: begin
          running <= 1'b0;
          if (!fail) pass <= 1'b1;

          // stay here until next start
          if (start_pulse) begin
            st <= ST_IDLE;
          end
        end

        default: st <= ST_IDLE;
      endcase
    end
  end

endmodule
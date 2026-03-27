module dma_ctrl_dat #(
  parameter int W  = 16,
  parameter int AW = 10
) (
  input  logic          dat_clk,
  input  logic          dat_rst_n,

  input  logic          start_pulse_dat,
  input  logic [AW-1:0] src_addr_dat,
  input  logic [31:0]   len_dat,

  output logic          busy_dat,
  output logic          done_event_dat,
  output logic          err_event_dat,
  output logic          fifo_ovf_event_dat,

  output logic          ram_rd_en,
  output logic [AW-1:0] ram_rd_addr,
  input  logic [W-1:0]  ram_rd_data,

  input  logic          fifo_full,
  output logic          fifo_wr_en,
  output logic [W:0]    fifo_wr_data   // {last,data}
);

  typedef enum logic [2:0] {IDLE, ISSUE_RD, WAIT1, WAIT2, PUSH} state_t;
  state_t state;

  logic [AW-1:0] src_ptr;
  logic [31:0]   rem;

  // Pipeline last flag to align with usable ram_rd_data sample
  logic last_d1, last_d2, last_d3;

  always_ff @(posedge dat_clk or negedge dat_rst_n) begin
    if (!dat_rst_n) begin
      state              <= IDLE;
      busy_dat           <= 1'b0;

      src_ptr            <= '0;
      rem                <= '0;

      ram_rd_en          <= 1'b0;
      ram_rd_addr        <= '0;

      fifo_wr_en         <= 1'b0;
      fifo_wr_data       <= '0;

      done_event_dat     <= 1'b0;
      err_event_dat      <= 1'b0;
      fifo_ovf_event_dat <= 1'b0;

      last_d1            <= 1'b0;
      last_d2            <= 1'b0;
      last_d3            <= 1'b0;

    end else begin
      // defaults each cycle
      ram_rd_en          <= 1'b0;
      fifo_wr_en         <= 1'b0;
      done_event_dat     <= 1'b0;
      err_event_dat      <= 1'b0;
      fifo_ovf_event_dat <= 1'b0;

      // shift last pipeline every cycle
      last_d3 <= last_d2;
      last_d2 <= last_d1;

      unique case (state)

        IDLE: begin
          busy_dat <= 1'b0;
          last_d1  <= 1'b0;
          last_d2  <= 1'b0;
          last_d3  <= 1'b0;

          if (start_pulse_dat) begin
            src_ptr <= src_addr_dat;
            rem     <= len_dat;

            if (len_dat == 0) begin
              done_event_dat <= 1'b1;
              state          <= IDLE;
            end else begin
              busy_dat <= 1'b1;

              // Issue first read immediately if FIFO has space
              if (!fifo_full) begin
                ram_rd_en   <= 1'b1;
                ram_rd_addr <= src_addr_dat;   // use src_addr_dat, not src_ptr
                last_d1     <= (len_dat == 32'd1);
                state       <= WAIT1;
              end else begin
                state <= ISSUE_RD;
              end
            end
          end
        end

        ISSUE_RD: begin
          if (!fifo_full) begin
            ram_rd_en   <= 1'b1;
            ram_rd_addr <= src_ptr;
            last_d1     <= (rem == 32'd1);
            state       <= WAIT1;
          end
        end

        WAIT1: begin
          state <= WAIT2;
        end

        WAIT2: begin
          state <= PUSH;
        end

        PUSH: begin
          if (!fifo_full) begin
            fifo_wr_en   <= 1'b1;
            fifo_wr_data <= {last_d3, ram_rd_data};

            // advance
            src_ptr <= src_ptr + 1'b1;
            rem     <= rem - 32'd1;

            if (rem == 32'd1) begin
              busy_dat       <= 1'b0;
              done_event_dat <= 1'b1;
              state          <= IDLE;
            end else begin
              state <= ISSUE_RD;
            end
          end else begin
            // shouldn’t happen, but for safety 
            fifo_ovf_event_dat <= 1'b1;
            state <= PUSH;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
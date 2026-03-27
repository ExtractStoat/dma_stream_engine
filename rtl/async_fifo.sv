// Asynchronous First in First Out
// Gray code pointers + 2FF CDC synchronizers
// Separate write/read clocks and resets
// Registered read data (1 cycle latency)
// Full/Empty based on standard Gray pointer comparisons
// Default target: DATA_W=32, DEPTH=64 (must be power of 2)
// Customizable # of sync stages

module async_fifo #(
  parameter int DATA_W      = 32,
  parameter int DEPTH       = 64,   // must be power of 2
  parameter int SYNC_STAGES = 2     // >=2 
) (
  // Write clock domain
  input  logic              wr_clk,
  input  logic              wr_rst_n,
  input  logic              wr_en,
  input  logic [DATA_W-1:0] wr_data,
  output logic              wr_full,

  // Read clock domain
  input  logic              rd_clk,
  input  logic              rd_rst_n,
  input  logic              rd_en,
  output logic [DATA_W-1:0] rd_data,
  output logic              rd_empty
);

  // -----------------------------------------------------------------------------------------------
  // Parameter / local sizing
  // -----------------------------------------------------------------------------------------------
  localparam int ADDR_W = $clog2(DEPTH);
  // Use one extra bit on pointers to detect wrap/full
  localparam int PTR_W  = ADDR_W + 1;

  // Compile-time checks
  initial begin
    if (DEPTH < 2) begin
      $error("DEPTH must be >= 2");
      $finish;
    end
    if ((1 << ADDR_W) != DEPTH) begin
      $error("DEPTH must be a power of two for this implementation. Got DEPTH=%0d", DEPTH);
      $finish;
    end
    if (SYNC_STAGES < 2) begin
      $error("SYNC_STAGES must be >= 2");
      $finish;
    end
  end

  // -----------------------------------------------------------------------------------------------
  // Memory
  // -----------------------------------------------------------------------------------------------
  logic [DATA_W-1:0] mem [0:DEPTH-1];

  logic [PTR_W-1:0] wr_ptr_bin, wr_ptr_bin_next;
  logic [PTR_W-1:0] wr_ptr_gray, wr_ptr_gray_next;

  logic [PTR_W-1:0] rd_ptr_bin, rd_ptr_bin_next;
  logic [PTR_W-1:0] rd_ptr_gray, rd_ptr_gray_next;

  logic [ADDR_W-1:0] wr_addr;
  logic [ADDR_W-1:0] rd_addr;

  // Write address is lower ADDR_W bits of binary pointer
  assign wr_addr = wr_ptr_bin[ADDR_W-1:0];
  assign rd_addr = rd_ptr_bin[ADDR_W-1:0];

  // -----------------------------------------------------------------------------------------------
  // Helper functions
  // -----------------------------------------------------------------------------------------------
  function automatic logic [PTR_W-1:0] bin2gray(input logic [PTR_W-1:0] b);
    return (b >> 1) ^ b;
  endfunction

  // -----------------------------------------------------------------------------------------------
  // CDC synchronizers (Gray pointers crossing domains)
  // -----------------------------------------------------------------------------------------------
  logic [PTR_W-1:0] rd_ptr_gray_sync_w; // rd gray pointer synced into wr_clk
  logic [PTR_W-1:0] wr_ptr_gray_sync_r; // wr gray pointer synced into rd_clk

  // Multi-stage synchronizer shift register
  logic [PTR_W-1:0] rd_gray_sync_pipe [0:SYNC_STAGES-1];
  logic [PTR_W-1:0] wr_gray_sync_pipe [0:SYNC_STAGES-1];

  // Sync rd_ptr_gray into wr_clk domain
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      for (int s = 0; s < SYNC_STAGES; s++) rd_gray_sync_pipe[s] <= '0;
    end else begin
      rd_gray_sync_pipe[0] <= rd_ptr_gray;
      for (int s = 1; s < SYNC_STAGES; s++) rd_gray_sync_pipe[s] <= rd_gray_sync_pipe[s-1];
    end
  end
  assign rd_ptr_gray_sync_w = rd_gray_sync_pipe[SYNC_STAGES-1];

  // Sync wr_ptr_gray into rd_clk domain
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      for (int s = 0; s < SYNC_STAGES; s++) wr_gray_sync_pipe[s] <= '0;
    end else begin
      wr_gray_sync_pipe[0] <= wr_ptr_gray;
      for (int s = 1; s < SYNC_STAGES; s++) wr_gray_sync_pipe[s] <= wr_gray_sync_pipe[s-1];
    end
  end
  assign wr_ptr_gray_sync_r = wr_gray_sync_pipe[SYNC_STAGES-1];

  // -----------------------------------------------------------------------------------------------
  // Write-side pointer + FULL
  // -----------------------------------------------------------------------------------------------
  // Precompute incremented pointers (independent of wr_full)
  logic wr_full_next;
  logic wr_adv;
  assign wr_ptr_bin_next  = wr_ptr_bin + 1'b1;
  assign wr_ptr_gray_next = bin2gray(wr_ptr_bin_next);

  // Full compare target (invert top 2 bits of synced read gray)
  logic [PTR_W-1:0] rd_gray_sync_w_full_cmp;
  always_comb begin
    rd_gray_sync_w_full_cmp = rd_ptr_gray_sync_w;
    rd_gray_sync_w_full_cmp[PTR_W-1 -: 2] = ~rd_ptr_gray_sync_w[PTR_W-1 -: 2];
  end

  // Decide if a write would occur using current (registered) wr_full
  assign wr_adv = wr_en && !wr_full;

  // Next full: if we advance, compare incremented pointer, else compare current pointer
  always_comb begin
    if (wr_adv)
      wr_full_next = (wr_ptr_gray_next == rd_gray_sync_w_full_cmp);
    else
      wr_full_next = (wr_ptr_gray == rd_gray_sync_w_full_cmp);
  end

  // Pointer updates
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_ptr_bin  <= '0;
      wr_ptr_gray <= '0;
      wr_full     <= 1'b0;
    end else begin
      wr_full <= wr_full_next;
      if (wr_adv) begin
        wr_ptr_bin  <= wr_ptr_bin_next;
        wr_ptr_gray <= wr_ptr_gray_next;
      end
    end
  end

  // Memory write
  always_ff @(posedge wr_clk) begin
    if (wr_adv) begin
      mem[wr_addr] <= wr_data;
    end
  end
  
  // -----------------------------------------------------------------------------------------------
  // Read-side pointer + EMPTY
  // -----------------------------------------------------------------------------------------------
  logic rd_empty_next;
  logic rd_adv;

  assign rd_ptr_bin_next  = rd_ptr_bin + 1'b1;
  assign rd_ptr_gray_next = bin2gray(rd_ptr_bin_next);

  // Decide if a read would occur using current (registered) rd_empty
  assign rd_adv = rd_en && !rd_empty;

  // Next empty: if we advance, compare incremented pointer, else compare current pointer
  always_comb begin
    if (rd_adv)
      rd_empty_next = (rd_ptr_gray_next == wr_ptr_gray_sync_r);
    else
      rd_empty_next = (rd_ptr_gray == wr_ptr_gray_sync_r);
  end

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_ptr_bin  <= '0;
      rd_ptr_gray <= '0;
      rd_empty    <= 1'b1;
    end else begin
      rd_empty <= rd_empty_next;
      if (rd_adv) begin
        rd_ptr_bin  <= rd_ptr_bin_next;
        rd_ptr_gray <= rd_ptr_gray_next;
      end
    end
  end

  // Registered synchronous read data
  // 1-cycle latency from handshake to valid data observation in rd_data.
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_data <= '0;
    end else if (rd_adv) begin
      rd_data <= mem[rd_addr];
    end
  end

endmodule
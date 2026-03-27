`timescale 1ns/1ps

module tb_ram_stage;

  // -----------------------------------------------------------------------------------------------
  // Parameters 
  // -----------------------------------------------------------------------------------------------
  localparam int W  = 16;
  localparam int AW = 10;

  // Register map (byte offsets)
  localparam byte REG_SRC  = 8'h00;
  localparam byte REG_LEN  = 8'h04;
  localparam byte REG_CTRL = 8'h08;
  localparam byte REG_STAT = 8'h0C;

  // -----------------------------------------------------------------------------------------------
  // Clocks / resets
  // -----------------------------------------------------------------------------------------------
  logic cfg_clk, dat_clk;
  logic cfg_rst_n, dat_rst_n;

  // cfg bus
  logic        cfg_wr_en;
  logic [7:0]  cfg_wr_addr;
  logic [31:0] cfg_wr_data;
  logic        cfg_rd_en;
  logic [7:0]  cfg_rd_addr;
  logic [31:0] cfg_rd_data;

  // stream out
  logic        dst_valid;
  logic [W-1:0] dst_data;
  logic        dst_last;
  logic        dst_ready;

  logic        irq;

  // RAM write port (external into fpga_top)
  logic              ram_wr_en;
  logic [AW-1:0]     ram_wr_addr;
  logic [W-1:0]      ram_wr_data;

  // -----------------------------------------------------------------------------------------------
  // DUT (integration layer for ram_dual + dma_core)
  // -----------------------------------------------------------------------------------------------
  ram_stage #(
    .W(W),
    .AW(AW)
  ) dut (
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

    .irq(irq),

    .ram_wr_en(ram_wr_en),
    .ram_wr_addr(ram_wr_addr),
    .ram_wr_data(ram_wr_data)
  );

  // -----------------------------------------------------------------------------------------------
  // Clock generation
  // -----------------------------------------------------------------------------------------------
  initial begin
    cfg_clk = 0;
    forever #10 cfg_clk = ~cfg_clk;   // 50 MHz
  end

  initial begin
    dat_clk = 0;
    forever #5 dat_clk = ~dat_clk;    // 100 MHz
  end

  // -----------------------------------------------------------------------------------------------
  // Reset + defaults
  // -----------------------------------------------------------------------------------------------
  initial begin
    cfg_wr_en   = 0;
    cfg_wr_addr = '0;
    cfg_wr_data = '0;
    cfg_rd_en   = 0;
    cfg_rd_addr = '0;

    ram_wr_en   = 0;
    ram_wr_addr = '0;
    ram_wr_data = '0;

    dst_ready   = 0;

    cfg_rst_n   = 0;
    dat_rst_n   = 0;

    repeat (5) @(posedge cfg_clk);
    cfg_rst_n = 1;

    repeat (5) @(posedge dat_clk);
    dat_rst_n = 1;
  end

  // -----------------------------------------------------------------------------------------------
  // Simple bus tasks (1-cycle strobes)
  // -----------------------------------------------------------------------------------------------
  task automatic cfg_write(input byte addr, input logic [31:0] data);
    @(posedge cfg_clk);
    cfg_wr_en   <= 1'b1;
    cfg_wr_addr <= addr;
    cfg_wr_data <= data;
    @(posedge cfg_clk);
    cfg_wr_en   <= 1'b0;
    cfg_wr_addr <= '0;
    cfg_wr_data <= '0;
  endtask

  task automatic cfg_read(input byte addr, output logic [31:0] data);
    @(posedge cfg_clk);
    cfg_rd_en   <= 1'b1;
    cfg_rd_addr <= addr;
    @(posedge cfg_clk);
    // rd_data is combinatorial in dma_regs when cfg_rd_en=1,
    // but sample it on the next clock for simplicity
    data = cfg_rd_data;
    cfg_rd_en   <= 1'b0;
    cfg_rd_addr <= '0;
  endtask

  // -----------------------------------------------------------------------------------------------
  // RAM write task (write port clock is cfg_clk in fpga_top)
  // -----------------------------------------------------------------------------------------------
  task automatic ram_write(input logic [AW-1:0] addr, input logic [W-1:0] data);
    @(posedge cfg_clk);
    ram_wr_en   <= 1'b1;
    ram_wr_addr <= addr;
    ram_wr_data <= data;
    @(posedge cfg_clk);
    ram_wr_en   <= 1'b0;
    ram_wr_addr <= '0;
    ram_wr_data <= '0;
  endtask

  // -----------------------------------------------------------------------------------------------
  // Scoreboard
  // -----------------------------------------------------------------------------------------------
  int unsigned exp_len;
  logic [W-1:0] exp_mem [0:(1<<AW)-1];

  int unsigned got_count;
  logic seen_last;

  // capture stream output
  always_ff @(posedge cfg_clk or negedge cfg_rst_n) begin
    if (!cfg_rst_n) begin
      got_count <= 0;
      seen_last <= 1'b0;
    end else begin
      if (dst_valid && dst_ready) begin
        // check data ordering
        if (dst_data !== exp_mem[got_count]) begin
          $fatal(1, "DATA MISMATCH at index %0d: got 0x%0h exp 0x%0h",
                 got_count, dst_data, exp_mem[got_count]);
        end

        // check last flag
        if (dst_last && (got_count != exp_len-1)) begin
          $fatal(1, "LAST asserted early at index %0d (exp last at %0d)",
                 got_count, exp_len-1);
        end
        if (!dst_last && (got_count == exp_len-1)) begin
          $fatal(1, "LAST not asserted on final beat index %0d", got_count);
        end

        if (dst_last) seen_last <= 1'b1;

        got_count <= got_count + 1;
      end
    end
  end

  // -----------------------------------------------------------------------------------------------
  // Helpers: wait for done bit (STATUS[1])
  // -----------------------------------------------------------------------------------------------
  task automatic wait_done_poll();
    logic [31:0] stat;
    do begin
      cfg_read(REG_STAT, stat);
    end while (stat[1] !== 1'b1);
  endtask

  task automatic clear_done();
    // W1C on STATUS bit1
    cfg_write(REG_STAT, 32'h0000_0002);
  endtask

  // -----------------------------------------------------------------------------------------------
  // Backpressure generator
  // -----------------------------------------------------------------------------------------------
  task automatic run_backpressure(input int mode, input int cycles);
    // mode 0: always ready
    // mode 1: pseudo-random
    int i;
    for (i = 0; i < cycles; i++) begin
      @(posedge cfg_clk);
      unique case (mode)
        0: dst_ready <= 1'b1;
        1: dst_ready <= $urandom_range(0, 1);
        default: dst_ready <= 1'b1;
      endcase
    end
  endtask

  // -----------------------------------------------------------------------------------------------
  // Testcases
  // -----------------------------------------------------------------------------------------------
  task automatic test_basic(input int unsigned len, input int unsigned base);
    logic [31:0] stat;

    $display("\n--- TEST BASIC len=%0d base=%0d ---", len, base);

    // program expected memory + write RAM
    exp_len   = len;
    got_count = 0;
    seen_last = 1'b0;

    for (int i = 0; i < len; i++) begin
      exp_mem[i] = logic'(16'(i + 16'h1000)); // recognizable pattern
      ram_write(AW'(base + i), exp_mem[i]);
    end

    // give RAM a couple clocks (conservative)
    repeat (3) @(posedge cfg_clk);
    repeat (3) @(posedge dat_clk);

    // configure DMA regs
    cfg_write(REG_SRC, 32'(base));
    cfg_write(REG_LEN, 32'(len));
    cfg_write(REG_CTRL, 32'h0000_0001); // start=1, irq_en=0

    // run sink ready
    dst_ready <= 1'b1;

    // wait done by polling
    wait_done_poll();

    // give stream_out a good amount of clocks cycles to work though fifo
    repeat (24) @(posedge cfg_clk);

    // verify counters
    if (got_count != len) begin
      $fatal(1, "Expected %0d beats, got %0d", len, got_count);
    end
    if (!seen_last && (len != 0)) begin
      $fatal(1, "Did not observe LAST on final beat");
    end

    // check busy cleared
    cfg_read(REG_STAT, stat);
    if (stat[0] !== 1'b0) $fatal(1, "BUSY still set after done");

    // clear done
    clear_done();

    $display("PASS basic len=%0d", len);
  endtask

  task automatic test_backpressure(input int unsigned len, input int unsigned base);
    $display("\n--- TEST BACKPRESSURE len=%0d base=%0d ---", len, base);

    // program expected memory + write RAM
    exp_len   = len;
    got_count = 0;
    seen_last = 1'b0;

    for (int i = 0; i < len; i++) begin
      exp_mem[i] = logic'(16'(16'hA000 + i));
      ram_write(AW'(base + i), exp_mem[i]);
    end

    repeat (3) @(posedge cfg_clk);
    repeat (3) @(posedge dat_clk);

    cfg_write(REG_SRC, 32'(base));
    cfg_write(REG_LEN, 32'(len));
    cfg_write(REG_CTRL, 32'h0000_0001); // start

    // run randomized backpressure while DMA runs
    fork
      begin
        // run for “long enough” (len plus slack)
        run_backpressure(1, (len * 6) + 50);
        dst_ready <= 1'b1; // finish draining
      end
      begin
        wait_done_poll();
      end
    join

    // drain remaining beats if any (should be none after done if FIFO drained,
    // but due to CDC buffering, allow a small tail)
    repeat (50) @(posedge cfg_clk);

    if (got_count != len) begin
      $fatal(1, "Backpressure: expected %0d beats, got %0d", len, got_count);
    end
    if (!seen_last && (len != 0)) begin
      $fatal(1, "Backpressure: missing LAST");
    end

    clear_done();

    $display("PASS backpressure len=%0d", len);
  endtask

  task automatic test_len_zero();
    logic [31:0] stat;

    $display("\n--- TEST LEN=0 ---");
    exp_len   = 0;
    got_count = 0;
    seen_last = 1'b0;

    cfg_write(REG_SRC, 32'd0);
    cfg_write(REG_LEN, 32'd0);
    cfg_write(REG_CTRL, 32'h0000_0001); // start

    wait_done_poll();

    if (got_count != 0) $fatal(1, "LEN=0 should produce no beats");
    cfg_read(REG_STAT, stat);
    if (stat[0] !== 1'b0) $fatal(1, "LEN=0 busy should be 0");

    clear_done();
    $display("PASS len=0");
  endtask

  // -----------------------------------------------------------------------------------------------
  // Main sequence
  // -----------------------------------------------------------------------------------------------
  initial begin
    // wait for reset deassert
    wait(cfg_rst_n && dat_rst_n);

    // keep dst not ready initially
    dst_ready <= 1'b0;
    repeat (5) @(posedge cfg_clk);

    // Run tests
    test_basic(16, 0);
    test_backpressure(64, 100);
    test_len_zero();

    $display("\nALL TESTS PASS ");
    $finish;
  end

endmodule
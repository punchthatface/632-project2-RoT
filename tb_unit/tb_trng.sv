`timescale 1ns/1ps
`default_nettype none

module tb_trng;

  localparam int STAGES       = 19;
  localparam int COUNTER_SIZE = 10;
  localparam int RO_NUM       = 16;
  localparam int WORD_W       = 32;

  localparam int PERIOD       = 10;
  localparam int HALFPERIOD   = PERIOD / 2;

  logic              clk, rst_n;
  logic              gen32, gen16;
  logic              ro_enable;
  logic [RO_NUM-1:0] ro_feedback;
  logic [WORD_W-1:0] trng_word;
  logic              trngready;

  logic [WORD_W-1:0] word16_a, word16_b, word32_a, word32_b;

  integer cycle_count;
  integer launch_cycle;
  integer ready_count;
  integer latency_cur;

  ro_bank #(
    .STAGES(STAGES),
    .COUNTER_SIZE(COUNTER_SIZE),
    .RO_NUM(RO_NUM)
  ) u_ro_bank (
    .enable(ro_enable),
    .feedback(ro_feedback),
    .count()
  );

  trng #(
    .RO_NUM(RO_NUM),
    .WORD_W(WORD_W)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .gen32(gen32),
    .gen16(gen16),
    .ro_feedback(ro_feedback),
    .ro_enable(ro_enable),
    .trng_word(trng_word),
    .trngready(trngready)
  );

  initial begin
    clk = 1'b0;
    forever #HALFPERIOD clk = ~clk;
  end

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      cycle_count <= 0;
      ready_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (trngready)
        ready_count <= ready_count + 1;
    end
  end

  task automatic pulse_gen16;
    begin
      @(negedge clk);
      gen16 = 1'b1;
      @(posedge clk);
      launch_cycle = cycle_count;
      @(negedge clk);
      gen16 = 1'b0;
    end
  endtask

  task automatic pulse_gen32;
    begin
      @(negedge clk);
      gen32 = 1'b1;
      @(posedge clk);
      launch_cycle = cycle_count;
      @(negedge clk);
      gen32 = 1'b0;
    end
  endtask

  task automatic wait_ready_and_check_latency(input integer expected_cycles);
    begin
      wait (trngready === 1'b1);
      latency_cur = cycle_count - launch_cycle;

      if (latency_cur != expected_cycles) begin
        $display("FAIL: expected latency %0d cycles, got %0d",
                 expected_cycles, latency_cur);
        $fatal;
      end

      if (^trng_word === 1'bx) begin
        $display("FAIL: trng_word contains X");
        $fatal;
      end

      $display("TRNG ready after %0d cycles, word = %h", latency_cur, trng_word);

      @(posedge clk);
      @(negedge clk);
      if (trngready !== 1'b0) begin
        $display("FAIL: trngready did not deassert after one cycle");
        $fatal;
      end
    end
  endtask

  initial begin
    rst_n    = 1'b0;
    gen16    = 1'b0;
    gen32    = 1'b0;
    word16_a = '0;
    word16_b = '0;
    word32_a = '0;
    word32_b = '0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ------------------------------------------------------------
    // First 16-bit generation
    // ------------------------------------------------------------
    pulse_gen16;
    wait_ready_and_check_latency(17);
    word16_a = trng_word;

    if (word16_a[31:16] !== 16'h0000) begin
      $display("FAIL: upper 16 bits should be zero for gen16, got %h", word16_a);
      $fatal;
    end

    // ------------------------------------------------------------
    // Second 16-bit generation
    // ------------------------------------------------------------
    repeat (3) @(posedge clk);

    pulse_gen16;
    wait_ready_and_check_latency(17);
    word16_b = trng_word;

    if (word16_b[31:16] !== 16'h0000) begin
      $display("FAIL: upper 16 bits should be zero for gen16, got %h", word16_b);
      $fatal;
    end

    $display("16-bit TRNG words:");
    $display("  word16_a = %h", word16_a);
    $display("  word16_b = %h", word16_b);

    // ------------------------------------------------------------
    // First 32-bit generation
    // ------------------------------------------------------------
    repeat (3) @(posedge clk);

    pulse_gen32;
    wait_ready_and_check_latency(33);
    word32_a = trng_word;

    // ------------------------------------------------------------
    // Second 32-bit generation
    // ------------------------------------------------------------
    repeat (3) @(posedge clk);

    pulse_gen32;
    wait_ready_and_check_latency(33);
    word32_b = trng_word;

    $display("32-bit TRNG words:");
    $display("  word32_a = %h", word32_a);
    $display("  word32_b = %h", word32_b);

    // Soft sanity only: collisions can happen.
    if (word16_a == word16_b)
      $display("WARNING: two 16-bit outputs matched");
    else
      $display("PASS: 16-bit outputs differed");

    if (word32_a == word32_b)
      $display("WARNING: two 32-bit outputs matched");
    else
      $display("PASS: 32-bit outputs differed");

    if (ready_count != 4) begin
      $display("FAIL: expected 4 trngready pulses, got %0d", ready_count);
      $fatal;
    end

    $display("All trng unit tests passed.");
    $finish;
  end

endmodule

`default_nettype wire
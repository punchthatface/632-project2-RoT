`timescale 1ns/1ps
`default_nettype none
import rot_pkg::*;

module tb_f3;

  localparam int PERIOD     = 10;
  localparam int HALFPERIOD = PERIOD / 2;
  localparam int NUM_SAMPLES = 8;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;

  logic            clk, rst_n;
  logic [BUSW-1:0] addr, data_from_cpu;
  logic [BUSW-1:0] data_to_cpu;
  logic            re, we;

  logic [BUSW-1:0] status_word;
  logic [BUSW-1:0] trng_words [0:NUM_SAMPLES-1];
  integer          busy_cycles;

  rot dut (
    .clk(clk),
    .rst_n(rst_n),
    .addr(addr),
    .data_from_cpu(data_from_cpu),
    .data_to_cpu(data_to_cpu),
    .re(re),
    .we(we)
  );

  initial begin
    clk = 1'b0;
    forever #HALFPERIOD clk = ~clk;
  end

  // Performs one CPU-mapped write transaction.
  task automatic cpu_write(input logic [BUSW-1:0] a, input logic [BUSW-1:0] d);
    begin
      @(negedge clk);
      addr          = a;
      data_from_cpu = d;
      we            = 1'b1;
      re            = 1'b0;
      @(posedge clk);
      @(negedge clk);
      we   = 1'b0;
      addr = '0;
    end
  endtask

  // Performs one CPU-mapped read transaction.
  task automatic cpu_read(input logic [BUSW-1:0] a, output logic [BUSW-1:0] d);
    begin
      @(negedge clk);
      addr = a;
      re   = 1'b1;
      we   = 1'b0;
      @(posedge clk);
      #1;
      d = data_to_cpu;
      @(negedge clk);
      re   = 1'b0;
      addr = '0;
    end
  endtask

  // Polls STATUS until the top-level busy bit clears.
  task automatic wait_until_idle;
    status_reg_t status_dec;
    integer timeout;
    logic idle_seen;
    begin
      timeout = 0;
      idle_seen = 1'b0;
      while ((timeout < 200) && !idle_seen) begin
        cpu_read(ADDR_STATUS, status_word);
        status_dec.word = status_word;
        if (!status_dec.bits.busy_global)
          idle_seen = 1'b1;
        timeout = timeout + 1;
      end
      if (!idle_seen) begin
        $display("FAIL: timed out waiting for RoT to become idle");
        $fatal;
      end
    end
  endtask

  // Completes the normal CPU-visible unlock sequence.
  task automatic unlock_rot;
    begin
      cpu_write(ADDR_UNLOCK_KEY, UNLOCK_KEY);
      cpu_write(ADDR_CMD, CMD_UNLOCK);
      wait_until_idle;
    end
  endtask

  // Starts one TRNG32 command, waits for valid output, and reads the 32-bit word.
  task automatic run_trng32_and_read(
    output logic [BUSW-1:0] word_out,
    input  string           label
  );
    status_reg_t status_dec;
    logic [BUSW-1:0] first_status_word;
    logic done_polling;
    begin
      cpu_write(ADDR_CMD, CMD_TRNG_GEN32);

      cpu_read(ADDR_STATUS, first_status_word);
      status_dec.word = first_status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_trng) begin
        $display("FAIL: %s did not enter busy TRNG state", label);
        $fatal;
      end

      busy_cycles = 0;
      done_polling = 1'b0;
      while (!done_polling) begin
        cpu_read(ADDR_STATUS, status_word);
        status_dec.word = status_word;
        if (!status_dec.bits.busy_global) begin
          done_polling = 1'b1;
        end else begin
          busy_cycles = busy_cycles + 1;
          if (busy_cycles > 200) begin
            $display("FAIL: %s never completed", label);
            $fatal;
          end
        end
      end

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.trng_valid) begin
        $display("FAIL: %s completed without trng_valid", label);
        $fatal;
      end

      cpu_read(ADDR_TRNG_WORD, word_out);

      if (^word_out === 1'bx) begin
        $display("FAIL: %s produced X data", label);
        $fatal;
      end

      $display("PASS: %s produced %h after %0d busy polls", label, word_out, busy_cycles);
    end
  endtask

  initial begin
    integer i, j;
    integer unique_count;
    logic seen_before;

    rst_n         = 1'b0;
    addr          = '0;
    data_from_cpu = '0;
    re            = 1'b0;
    we            = 1'b0;
    for (i = 0; i < NUM_SAMPLES; i = i + 1)
      trng_words[i] = '0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Feature F3 flow:
    // 1. Unlock the RoT.
    // 2. Generate 32 fresh TRNG bits.
    // 3. Read them back through the CPU-visible TRNG register.
    // 4. Repeat several times and confirm the sequence is not reproducible.
    unlock_rot;

    for (i = 0; i < NUM_SAMPLES; i = i + 1) begin
      run_trng32_and_read(trng_words[i], $sformatf("TRNG32 sample %0d", i));
      repeat (5 + (i * 2)) @(posedge clk);
    end

    $display("TRNG32 outputs:");
    for (i = 0; i < NUM_SAMPLES; i = i + 1)
      $display("  trng_words[%0d] = %h", i, trng_words[i]);

    unique_count = 0;
    for (i = 0; i < NUM_SAMPLES; i = i + 1) begin
      seen_before = 1'b0;
      for (j = 0; j < i; j = j + 1) begin
        if (trng_words[i] == trng_words[j])
          seen_before = 1'b1;
      end
      if (!seen_before)
        unique_count = unique_count + 1;
    end

    if (unique_count < (NUM_SAMPLES / 2)) begin
      $display("FAIL: repeated TRNG sampling produced only %0d unique values out of %0d samples", unique_count, NUM_SAMPLES);
      $fatal;
    end else begin
      $display("PASS: repeated TRNG sampling produced %0d unique values", unique_count);
    end

    $display("tb_f3 passed.");
    $finish;
  end

endmodule

`default_nettype wire

`timescale 1ns/1ps
`default_nettype none
import rot_pkg::*;

module tb_uc3;

  localparam int PERIOD      = 10;
  localparam int HALFPERIOD  = PERIOD / 2;
  localparam int TOTAL_WORDS = 32;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;

  logic            clk, rst_n;
  logic [BUSW-1:0] addr, data_from_cpu;
  logic [BUSW-1:0] data_to_cpu;
  logic            re, we;

  logic [BUSW-1:0] status_word;
  logic [BUSW-1:0] trng_word;
  logic [BUSW-1:0] prng_words [0:TOTAL_WORDS-1];
  integer          word_idx;
  integer          cycles_waited;

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

  task automatic cpu_write(input logic [BUSW-1:0] a, input logic [BUSW-1:0] d);
    begin
      @(negedge clk);
      addr          = a;
      data_from_cpu = d;
      we            = 1'b1;
      re            = 1'b0;
      @(posedge clk);
      @(negedge clk);
      we            = 1'b0;
      addr          = '0;
      data_from_cpu = '0;
    end
  endtask

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

  task automatic wait_until_idle;
    status_reg_t status_dec;
    integer timeout;
    logic idle_seen;
    begin
      timeout = 0;
      idle_seen = 1'b0;
      while ((timeout < 1000) && !idle_seen) begin
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

  task automatic unlock_rot;
    status_reg_t status_dec;
    begin
      cpu_write(ADDR_UNLOCK_KEY, UNLOCK_KEY);
      cpu_write(ADDR_CMD, CMD_UNLOCK);
      wait_until_idle;
      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (status_dec.bits.busy_global) begin
        $display("FAIL: unlock did not return to idle");
        $fatal;
      end
    end
  endtask

  task automatic run_trng16_once(output logic [BUSW-1:0] word_out);
    status_reg_t status_dec;
    logic done_polling;
    begin
      cpu_write(ADDR_CMD, CMD_TRNG_GEN16);

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_trng) begin
        $display("FAIL: TRNG16 did not enter busy TRNG state");
        $fatal;
      end

      done_polling = 1'b0;
      cycles_waited = 0;
      while (!done_polling) begin
        cpu_read(ADDR_STATUS, status_word);
        status_dec.word = status_word;
        if (!status_dec.bits.busy_global) begin
          done_polling = 1'b1;
        end else begin
          cycles_waited = cycles_waited + 1;
          if (cycles_waited > 500) begin
            $display("FAIL: TRNG16 never completed");
            $fatal;
          end
        end
      end

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.trng_valid) begin
        $display("FAIL: TRNG16 completed without trng_valid");
        $fatal;
      end

      cpu_read(ADDR_TRNG_WORD, word_out);
      if (^word_out === 1'bx) begin
        $display("FAIL: TRNG16 produced X data");
        $fatal;
      end
    end
  endtask

  task automatic seed_prng_from_trng;
    status_reg_t status_dec;
    begin
      cpu_write(ADDR_CMD, CMD_PRNG_SEED);
      wait_until_idle;

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (status_dec.bits.busy_global) begin
        $display("FAIL: PRNG seed did not return to idle");
        $fatal;
      end
    end
  endtask

  task automatic start_prng;
    status_reg_t status_dec;
    begin
      cpu_write(ADDR_CMD, CMD_PRNG_START);
      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_prng || !status_dec.bits.prng_running) begin
        $display("FAIL: PRNG start did not enter running state");
        $fatal;
      end
    end
  endtask

  task automatic collect_prng_words;
    status_reg_t status_dec;
    logic [BUSW-1:0] prev_word;
    logic seen_change;
    logic word_ready;
    begin
      prev_word   = '0;
      seen_change = 1'b0;

      for (word_idx = 0; word_idx < TOTAL_WORDS; word_idx = word_idx + 1) begin
        cycles_waited = 0;
        word_ready = 1'b0;
        while (!word_ready) begin
          cpu_read(ADDR_STATUS, status_word);
          status_dec.word = status_word;
          if (!status_dec.bits.busy_global || !status_dec.bits.busy_prng || !status_dec.bits.prng_running) begin
            $display("FAIL: PRNG stopped before 1024 bits were collected");
            $fatal;
          end
          if (status_dec.bits.prng_word_valid) begin
            word_ready = 1'b1;
          end else begin
            cycles_waited = cycles_waited + 1;
            if (cycles_waited > 50) begin
              $display("FAIL: timed out waiting for PRNG word %0d", word_idx);
              $fatal;
            end
          end
        end

        cpu_read(ADDR_PRNG_WORD, prng_words[word_idx]);
        if (^prng_words[word_idx] === 1'bx) begin
          $display("FAIL: PRNG word %0d contained X", word_idx);
          $fatal;
        end

        if ((word_idx > 0) && (prng_words[word_idx] !== prev_word))
          seen_change = 1'b1;
        prev_word = prng_words[word_idx];

        @(posedge clk);
      end

      if (!seen_change) begin
        $display("FAIL: collected 1024 bits but all 32-bit words matched");
        $fatal;
      end
    end
  endtask

  task automatic stop_prng;
    status_reg_t status_dec;
    begin
      cpu_write(ADDR_CMD, CMD_PRNG_STOP);
      wait_until_idle;

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (status_dec.bits.busy_global || status_dec.bits.busy_prng || status_dec.bits.prng_running) begin
        $display("FAIL: PRNG stop did not return to idle");
        $fatal;
      end
    end
  endtask

  initial begin
    integer i;

    rst_n         = 1'b0;
    addr          = '0;
    data_from_cpu = '0;
    re            = 1'b0;
    we            = 1'b0;
    trng_word     = '0;
    for (i = 0; i < TOTAL_WORDS; i = i + 1)
      prng_words[i] = '0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // UC3 Section 3.3 flow:
    // 1. CPU writes unlock key.
    // 2. CPU issues unlock command.
    // 3. CPU waits until idle.
    // 4. CPU generates 16 TRNG bits.
    // 5. CPU waits until idle.
    // 6. CPU issues the PRNG seed command.
    // 7. CPU waits until idle.
    // 8. CPU starts the PRNG, collects 1024 bits over time, and then stops it.
    unlock_rot;

    run_trng16_once(trng_word);
    $display("TRNG16 seed source = %h", trng_word);

    seed_prng_from_trng;
    start_prng;
    collect_prng_words;
    stop_prng;

    $display("UC3 collected %0d PRNG words (1024 bits total)", TOTAL_WORDS);
    $display("  prng_word[0]  = %h", prng_words[0]);
    $display("  prng_word[1]  = %h", prng_words[1]);
    $display("  prng_word[30] = %h", prng_words[30]);
    $display("  prng_word[31] = %h", prng_words[31]);
    $display("tb_uc3 passed.");
    $finish;
  end

endmodule

`default_nettype wire

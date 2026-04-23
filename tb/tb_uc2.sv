`timescale 1ns/1ps
`default_nettype none
import rot_pkg::*;

module tb_uc2;

  localparam int PERIOD     = 10;
  localparam int HALFPERIOD = PERIOD / 2;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;

  logic            clk, rst_n;
  logic [BUSW-1:0] addr, data_from_cpu;
  logic [BUSW-1:0] data_to_cpu;
  logic            re, we;

  logic [BUSW-1:0] status_word;
  logic [BUSW-1:0] trng_word;
  logic [BUSW-1:0] prime_out_word;
  integer          attempts;
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
      while ((timeout < 500) && !idle_seen) begin
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

  task automatic run_trng32_once(output logic [BUSW-1:0] word_out);
    status_reg_t status_dec;
    logic done_polling;
    begin
      cpu_write(ADDR_CMD, CMD_TRNG_GEN32);

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_trng) begin
        $display("FAIL: TRNG32 did not enter busy TRNG state");
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
          if (busy_cycles > 500) begin
            $display("FAIL: TRNG32 never completed");
            $fatal;
          end
        end
      end

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.trng_valid) begin
        $display("FAIL: TRNG32 completed without trng_valid");
        $fatal;
      end

      cpu_read(ADDR_TRNG_WORD, word_out);
      if (^word_out === 1'bx) begin
        $display("FAIL: TRNG32 produced X data");
        $fatal;
      end
    end
  endtask

  task automatic run_prime_check_on_trng_lsb;
    status_reg_t status_dec;
    logic done_polling;
    logic expected_prime;
    integer divisor;
    begin
      cpu_write(ADDR_PRIME_IN, {22'b0, trng_word[9:0]});
      cpu_write(ADDR_CMD, CMD_PRIME);

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_prime) begin
        $display("FAIL: PRIME did not enter busy PRIME state");
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
          if (busy_cycles > 500) begin
            $display("FAIL: PRIME never completed");
            $fatal;
          end
        end
      end

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.prime_valid) begin
        $display("FAIL: PRIME completed without prime_valid");
        $fatal;
      end

      cpu_read(ADDR_PRIME_OUT, prime_out_word);

      expected_prime = 1'b1;
      if (trng_word[9:0] < 10'd2) begin
        expected_prime = 1'b0;
      end else begin
        for (divisor = 2; divisor <= 31; divisor = divisor + 1) begin
          if ((trng_word[9:0] != divisor[9:0]) && ((trng_word[9:0] % divisor[9:0]) == 0))
            expected_prime = 1'b0;
        end
      end

      if (prime_out_word[0] !== expected_prime) begin
        $display("FAIL: prime result mismatch for TRNG LSB10=%0d", trng_word[9:0]);
        $display(" expected = %0b", expected_prime);
        $display(" observed = %0b", prime_out_word[0]);
        $fatal;
      end
    end
  endtask

  initial begin
    logic odd_found;

    rst_n          = 1'b0;
    addr           = '0;
    data_from_cpu  = '0;
    re             = 1'b0;
    we             = 1'b0;
    trng_word      = '0;
    prime_out_word = '0;
    attempts       = 0;
    odd_found      = 1'b0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // UC2 Section 3.2 flow:
    // Step 1. CPU writes unlock key.
    // Step 2. CPU issues unlock command.
    // Step 3. CPU waits until idle.
    // Step 4. CPU generates 32 TRNG bits.
    // Step 5. CPU waits until idle.
    // Step 6. CPU reads the TRNG word.
    // Step 7. CPU retries in software until the value is odd.
    // Step 8. CPU commands prime checking on the low 10 bits.
    // Step 9. CPU waits until idle.
    // Step 10. CPU reads the prime result.
    $display("UC2 Step 1: write unlock key");
    cpu_write(ADDR_UNLOCK_KEY, UNLOCK_KEY);
    $display("UC2 Step 2: issue unlock command");
    cpu_write(ADDR_CMD, CMD_UNLOCK);
    $display("UC2 Step 3: wait until RoT is idle after unlock");
    wait_until_idle;

    while (!odd_found) begin
      $display("UC2 Step 4: issue TRNG32 command");
      attempts = attempts + 1;
      run_trng32_once(trng_word);
      $display("UC2 Step 5: wait-until-idle completed for TRNG attempt %0d", attempts);
      $display("UC2 Step 6: TRNG attempt %0d produced %h", attempts, trng_word);

      if (trng_word[0]) begin
        $display("UC2 Step 7: software retry loop found odd word after %0d attempt(s)", attempts);
        odd_found = 1'b1;
      end else begin
        $display("UC2 Step 7: TRNG word was even, retrying in software");
      end

      if (attempts > 20) begin
        $display("FAIL: TRNG retry loop did not produce an odd value in time");
        $fatal;
      end
    end

    $display("UC2 Step 8: issue prime check on low 10 TRNG bits");
    run_prime_check_on_trng_lsb;
    $display("UC2 Step 9: wait-until-idle completed for prime check");
    $display("UC2 Step 10: read prime result -> %h", prime_out_word);

    $display("UC2 final values:");
    $display("  trng_word      = %h", trng_word);
    $display("  trng_lsb10     = %0d", trng_word[9:0]);
    $display("  prime_out_word = %h", prime_out_word);
    $display("tb_uc2 passed.");
    $finish;
  end

endmodule

`default_nettype wire

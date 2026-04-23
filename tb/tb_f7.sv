`timescale 1ns/1ps
`default_nettype none
`include "rot_pkg.sv"
import rot_pkg::*;

module tb_f7;

  localparam int PERIOD     = 10;
  localparam int HALFPERIOD = PERIOD / 2;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;

  logic            clk, rst_n;
  logic [BUSW-1:0] addr, data_from_cpu;
  logic [BUSW-1:0] data_to_cpu;
  logic            re, we;

  logic [BUSW-1:0] status_word;
  logic [BUSW-1:0] prime_out_word;
  integer          busy_cycles_prime;
  integer          busy_cycles_composite;

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
      we   = 1'b0;
      addr = '0;
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
    begin
      cpu_write(ADDR_UNLOCK_KEY, UNLOCK_KEY);
      cpu_write(ADDR_CMD, CMD_UNLOCK);
      wait_until_idle;
    end
  endtask

  task automatic run_prime_case(
    input  logic [BUSW-1:0] number_in,
    input  logic            expected_isprime,
    input  string           label,
    output integer          busy_cycles_out
  );
    status_reg_t status_dec;
    logic done_polling;
    begin
      cpu_write(ADDR_PRIME_IN, number_in);
      cpu_write(ADDR_CMD, CMD_PRIME);

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_prime) begin
        $display("FAIL: %s did not enter busy PRIME state", label);
        $fatal;
      end

      busy_cycles_out = 0;
      done_polling = 1'b0;
      while (!done_polling) begin
        cpu_read(ADDR_STATUS, status_word);
        status_dec.word = status_word;
        if (!status_dec.bits.busy_global) begin
          done_polling = 1'b1;
        end else begin
          busy_cycles_out = busy_cycles_out + 1;
          if (busy_cycles_out > 200) begin
            $display("FAIL: %s never completed", label);
            $fatal;
          end
        end
      end

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.prime_valid) begin
        $display("FAIL: %s completed without prime_valid", label);
        $fatal;
      end

      cpu_read(ADDR_PRIME_OUT, prime_out_word);
      if (prime_out_word[0] !== expected_isprime) begin
        $display("FAIL: %s expected=%0b got=%0b", label, expected_isprime, prime_out_word[0]);
        $fatal;
      end

      $display("PASS: %s result=%0b busy_polls=%0d", label, prime_out_word[0], busy_cycles_out);
    end
  endtask

  task automatic inject_prime_fault;
    begin
      @(posedge clk);
      @(posedge clk);
      force dut.u_prime.state = 4'b0011;
      @(posedge clk);
      release dut.u_prime.state;
    end
  endtask

  initial begin
    status_reg_t status_dec;
    integer i;

    rst_n               = 1'b0;
    addr                = '0;
    data_from_cpu       = '0;
    re                  = 1'b0;
    we                  = 1'b0;
    busy_cycles_prime   = 0;
    busy_cycles_composite = 0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Feature F7 flow:
    // 1. Unlock the RoT.
    // 2. Check a prime input and a composite input through the CPU-visible prime interface.
    // 3. Confirm both runs take the same visible busy length.
    // 4. Attempt a fault injection on the internal control state and confirm fail-stop behavior.
    unlock_rot;

    run_prime_case(32'd31, 1'b1, "prime input 31", busy_cycles_prime);
    run_prime_case(32'd21, 1'b0, "composite input 21", busy_cycles_composite);

    if (busy_cycles_prime != busy_cycles_composite) begin
      $display("FAIL: prime checker did not run in constant time");
      $display(" prime_busy_polls     = %0d", busy_cycles_prime);
      $display(" composite_busy_polls = %0d", busy_cycles_composite);
      $fatal;
    end else begin
      $display("PASS: prime and composite cases used the same busy length");
    end

    // ----------------------------------------------------------
    // Fault injection attempt on the prime checker control state
    // A one-bit disturbance of the one-hot FSM should land in an
    // invalid encoding and push the checker into fail-stop behavior.
    // ----------------------------------------------------------
    cpu_write(ADDR_PRIME_IN, 32'd31);
    cpu_write(ADDR_CMD, CMD_PRIME);

    cpu_read(ADDR_STATUS, status_word);
    status_dec.word = status_word;
    if (!status_dec.bits.busy_global || !status_dec.bits.busy_prime) begin
      $display("FAIL: FI case did not enter busy PRIME state");
      $fatal;
    end

    inject_prime_fault;

    for (i = 0; i < 40; i = i + 1) begin
      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global) begin
        $display("FAIL: FI unexpectedly allowed prime operation to complete");
        $fatal;
      end
      if (status_dec.bits.prime_valid) begin
        $display("FAIL: FI unexpectedly produced a valid prime result");
        $fatal;
      end
    end

    $display("PASS: FI attempt did not bypass prime control logic");
    $display("tb_f7 passed.");
    $finish;
  end

endmodule

`default_nettype wire

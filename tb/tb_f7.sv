`timescale 1ns/1ps
`default_nettype none
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
  logic [BUSW-1:0] prime_out_before_fault;
  logic [3:0]      attack_request;
  logic [3:0]      attack_done;

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

  // Completes the normal CPU-visible unlock sequence.
  task automatic unlock_rot;
    begin
      cpu_write(ADDR_UNLOCK_KEY, UNLOCK_KEY);
      cpu_write(ADDR_CMD, CMD_UNLOCK);
      wait_until_idle;
    end
  endtask

  // Runs one prime/composite test case and returns the visible busy duration.
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

  // Confirms three prime-check runs all used the same busy length.
  task automatic check_constant_time_triplet(
    input integer busy0,
    input integer busy1,
    input integer busy2,
    input string  suite_label
  );
    begin
      if ((busy0 != busy1) || (busy1 != busy2)) begin
        $display("FAIL: %s did not run in constant time", suite_label);
        $display("  busy_cycles = %0d, %0d, %0d", busy0, busy1, busy2);
        $fatal;
      end else begin
        $display("PASS: %s used the same busy length for all cases", suite_label);
      end
    end
  endtask

  // Executes one FI campaign run and checks the design stays in fail-stop behavior.
  task automatic run_fault_injection_case(
    input int         attack_id,
    input string      label
  );
    status_reg_t status_dec;
    integer i;
    begin
      rst_n = 1'b0;
      repeat (2) @(posedge clk);
      rst_n = 1'b1;
      @(posedge clk);

      unlock_rot;

      cpu_write(ADDR_PRIME_IN, 32'd21);
      cpu_write(ADDR_CMD, CMD_PRIME);
      wait_until_idle;
      cpu_read(ADDR_PRIME_OUT, prime_out_before_fault);

      cpu_write(ADDR_PRIME_IN, 32'd31);
      cpu_write(ADDR_CMD, CMD_PRIME);

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_prime) begin
        $display("FAIL: %s did not enter busy PRIME state", label);
        $fatal;
      end

      attack_request = attack_id[3:0];
      wait (attack_done == attack_id[3:0]);
      attack_request = '0;

      for (i = 0; i < 40; i = i + 1) begin
        cpu_read(ADDR_STATUS, status_word);
        status_dec.word = status_word;
        if (!status_dec.bits.busy_global) begin
          $display("FAIL: %s unexpectedly allowed prime operation to complete", label);
          $fatal;
        end
        if (status_dec.bits.prime_valid) begin
          $display("FAIL: %s unexpectedly produced a valid prime result", label);
          $fatal;
        end
      end

      cpu_read(ADDR_PRIME_OUT, prime_out_word);
      if (prime_out_word !== prime_out_before_fault) begin
        $display("FAIL: %s corrupted PRIME_OUT despite fail-stop behavior", label);
        $fatal;
      end

      $display("PASS: %s did not bypass prime control logic", label);
    end
  endtask

  // ----------------------------------------------------------
  // Dedicated attack process, following the lab 9 structure:
  // validation traffic lives elsewhere, and fault injection uses
  // three total force/release pairs across three separate runs.
  // ----------------------------------------------------------
  initial begin
    attack_request = '0;
    attack_done    = '0;

    wait (attack_request == 4'd1);
    wait (dut.status.bits.busy_prime);
    #1;
    force dut.u_prime.state = 4'b0011;
    #HALFPERIOD;
    release dut.u_prime.state;
    attack_done = 4'd1;

    wait (attack_request == 4'd2);
    wait (dut.status.bits.busy_prime);
    #1;
    force dut.u_prime.state = 4'b0000;
    #HALFPERIOD;
    release dut.u_prime.state;
    attack_done = 4'd2;

    wait (attack_request == 4'd3);
    wait (dut.status.bits.busy_prime);
    #1;
    force dut.u_prime.state = 4'b0110;
    #HALFPERIOD;
    release dut.u_prime.state;
    attack_done = 4'd3;
  end

  initial begin
    integer busy_cycles_case0;
    integer busy_cycles_case1;
    integer busy_cycles_case2;
    rst_n               = 1'b0;
    addr                = '0;
    data_from_cpu       = '0;
    re                  = 1'b0;
    we                  = 1'b0;
    prime_out_before_fault = '0;
    attack_done         = '0;
    busy_cycles_case0   = 0;
    busy_cycles_case1   = 0;
    busy_cycles_case2   = 0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Feature F7 flow:
    // 1. Unlock the RoT.
    // 2. Check several prime/composite inputs through the CPU-visible prime interface.
    // 3. Confirm all runs take the same visible busy length.
    // 4. Attempt a fault injection on the internal control state and confirm fail-stop behavior.
    unlock_rot;

    run_prime_case(32'd2,  1'b1, "constant-time case 0 input=2",  busy_cycles_case0);
    run_prime_case(32'd21, 1'b0, "constant-time case 1 input=21", busy_cycles_case1);
    run_prime_case(32'd31, 1'b1, "constant-time case 2 input=31", busy_cycles_case2);
    check_constant_time_triplet(busy_cycles_case0, busy_cycles_case1, busy_cycles_case2, "constant-time prime suite");

    // ----------------------------------------------------------
    // Fault injection campaign:
    // 1. Three total force/release pairs
    // 2. Separate attack block above
    // 3. Reset between runs
    // 4. Half-cycle fault duration
    // ----------------------------------------------------------
    run_fault_injection_case(1, "FI run 1");
    run_fault_injection_case(2, "FI run 2");
    run_fault_injection_case(3, "FI run 3");

    $display("tb_f7 passed.");
    $finish;
  end

endmodule

`default_nettype wire

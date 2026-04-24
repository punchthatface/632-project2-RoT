`timescale 1ns/1ps
`default_nettype none
import rot_pkg::*;

module tb_f1;

  localparam int PERIOD     = 10;
  localparam int HALFPERIOD = PERIOD / 2;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;

  logic            clk, rst_n;
  logic [BUSW-1:0] addr, data_from_cpu;
  logic [BUSW-1:0] data_to_cpu;
  logic            re, we;
  logic [BUSW-1:0] status_word;
  logic [BUSW-1:0] out_before, out_after;

  rot dut (
    .clk(clk),
    .rst_n(rst_n),
    .addr(addr),
    .data_from_cpu(data_from_cpu),
    .data_to_cpu(data_to_cpu),
    .re(re),
    .we(we)
  );

  // ------------------------------------------------------------
  // Clock
  // ------------------------------------------------------------
  initial begin
    clk = 0;
    forever #HALFPERIOD clk = ~clk;
  end

  // ------------------------------------------------------------
  // CPU helpers
  // ------------------------------------------------------------
  // Performs one CPU-mapped write transaction.
  task automatic cpu_write(input logic [BUSW-1:0] a, input logic [BUSW-1:0] d);
    begin
      @(negedge clk);
      addr = a;
      data_from_cpu = d;
      we = 1;
      re = 0;
      @(posedge clk);
      @(negedge clk);
      we = 0;
      addr = '0;
    end
  endtask

  // Performs one CPU-mapped read transaction.
  task automatic cpu_read(input logic [BUSW-1:0] a, output logic [BUSW-1:0] d);
    begin
      @(negedge clk);
      addr = a;
      re = 1;
      we = 0;
      @(posedge clk);
      #1;
      d = data_to_cpu;
      @(negedge clk);
      re = 0;
      addr = '0;
    end
  endtask

  // Inserts a fixed delay when this TB only needs time to pass.
  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
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

  // Tries one unlock candidate and proves PRIME still cannot run afterward.
  task automatic expect_locked_prime_blocked(input logic [BUSW-1:0] candidate_key, input string label);
    begin
      cpu_write(ADDR_UNLOCK_KEY, candidate_key);
      cpu_write(ADDR_CMD, CMD_UNLOCK);
      wait_cycles(12);

      cpu_write(ADDR_PRIME_IN, 32'd31);
      cpu_read(ADDR_PRIME_OUT, out_before);
      cpu_write(ADDR_CMD, CMD_PRIME);
      wait_cycles(40);
      cpu_read(ADDR_PRIME_OUT, out_after);

      if (out_before !== out_after) begin
        $display("FAIL: %s unexpectedly unlocked the system", label);
        $fatal;
      end else begin
        $display("PASS: %s kept the system locked", label);
      end
    end
  endtask

  initial begin
    rst_n = 0;
    addr = 0;
    data_from_cpu = 0;
    re = 0;
    we = 0;

    repeat (2) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ============================================================
    // 1) Locked -> PRIME should NOT execute
    // ============================================================
    cpu_write(ADDR_PRIME_IN, 32'd31);

    cpu_read(ADDR_PRIME_OUT, out_before);

    cpu_write(ADDR_CMD, CMD_PRIME);

    wait_cycles(40);

    cpu_read(ADDR_PRIME_OUT, out_after);

    if (out_before !== out_after) begin
      $display("FAIL: command executed while locked");
      $fatal;
    end else begin
      $display("PASS: locked state blocks commands");
    end

    // ============================================================
    // 2) Multiple wrong keys -> still blocked
    // ============================================================
    expect_locked_prime_blocked(32'h00000000, "all-zero wrong key");
    expect_locked_prime_blocked(32'hFFFFFFFF, "all-one wrong key");
    expect_locked_prime_blocked(32'hB27D553B, "near-miss wrong key");

    // ============================================================
    // 3) Reset -> correct key -> should unlock
    // ============================================================
    rst_n = 0;
    repeat (2) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    cpu_write(ADDR_UNLOCK_KEY, UNLOCK_KEY);
    cpu_write(ADDR_CMD, CMD_UNLOCK);
    wait_until_idle;

    // Now PRIME should work
    cpu_write(ADDR_PRIME_IN, 32'd31);
    cpu_write(ADDR_CMD, CMD_PRIME);
    wait_until_idle;

    cpu_read(ADDR_PRIME_OUT, out_after);

    if (out_after[0] !== 1'b1) begin
      $display("FAIL: correct key did not unlock system");
      $fatal;
    end else begin
      $display("PASS: correct key unlocks system");
    end

    $display("tb_f1 passed.");
    $finish;
  end

endmodule

`default_nettype wire

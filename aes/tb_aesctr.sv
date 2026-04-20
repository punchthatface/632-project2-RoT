`timescale 1ns/1ps
`default_nettype none

module tb_aesctr_nist;

  localparam int WIDTH = 128;

  logic               clk, rst_n;
  logic               go, load;
  logic [WIDTH-1:0]   counter1, plaintext, key;
  logic [WIDTH-1:0]   ciphertext;
  logic               ready;

  // DUT
  aesctr dut (
    .clk(clk),
    .rst_n(rst_n),
    .go(go),
    .load(load),
    .counter1(counter1),
    .plaintext(plaintext),
    .key(key),
    .ciphertext(ciphertext),
    .ready(ready)
  );

  // clock: 100MHz
  initial clk = 1'b0;
  always #5 clk = ~clk;

  localparam int READY_TIMEOUT_CYCLES = 800;
  localparam bit CHECK_NO_LEAK = 1'b1;

  // ==========================
  // NIST SP 800-38A F.5.1 vectors
  // ==========================
  localparam int NUM_BLOCKS = 4;

  logic [127:0] master_key;
  logic [127:0] init_ctr;

  logic [127:0] pt_vec  [0:NUM_BLOCKS-1];
  logic [127:0] exp_ct  [0:NUM_BLOCKS-1];

  integer i;
  
  initial begin
    master_key = 128'h2b7e151628aed2a6abf7158809cf4f3c;
    init_ctr   = 128'hf0f1f2f3f4f5f6f7f8f9fafbfcfdfeff;

    // Block #1
    pt_vec[0]  = 128'h6bc1bee22e409f96e93d7e117393172a;
    exp_ct[0]  = 128'h874d6191b620e3261bef6864990db6ce;

    // Block #2
    pt_vec[1]  = 128'hae2d8a571e03ac9c9eb76fac45af8e51;
    exp_ct[1]  = 128'h9806f66b7970fdff8617187bb9fffdff;

    // Block #3
    pt_vec[2]  = 128'h30c81c46a35ce411e5fbc1191a0a52ef;
    exp_ct[2]  = 128'h5ae4df3edbd5d35e5b4f09020db03eab;

    // Block #4
    pt_vec[3]  = 128'hf69f2445df4f9b17ad2b417be66c3710;
    exp_ct[3]  = 128'h1e031dda2fbe03d1792170a0f3009cee;
  end

  // ==========================
  // Helpers
  // ==========================
  task automatic do_reset();
    begin
      rst_n = 1'b0;
      repeat (2) @(posedge clk);
      rst_n = 1'b1;
      @(posedge clk);
    end
  endtask

  task automatic do_load(input logic [127:0] ctr, input logic [127:0] k);
    begin
      counter1  <= ctr;
      key       <= k;

      @(posedge clk);
      load <= 1'b1;

      @(posedge clk);
      load <= 1'b0;

      // Inputs not guaranteed stable after load
      counter1 <= $urandom();
      key      <= $urandom();
    end
  endtask

  task automatic send_block(input logic [127:0] pt);
    begin
      plaintext <= pt;

      @(posedge clk);
      go <= 1'b1;

      @(posedge clk);
      go <= 1'b0;

      // Inputs not guaranteed stable after go
      plaintext <= $urandom();
    end
  endtask

  task automatic wait_ready_and_check(input int idx);
    int cycles;
    begin
      cycles = 0;

      while (ready !== 1'b1) begin
        if (CHECK_NO_LEAK) begin
          if (ciphertext !== 128'h0) begin
            $fatal(1, "Leakage: ciphertext != 0 while ready=0 (block %0d): %032h", idx, ciphertext);
          end
        end

        @(posedge clk);
        cycles++;
        if (cycles >= READY_TIMEOUT_CYCLES) begin
          $fatal(1, "Timeout waiting for ready on block %0d (waited %0d cycles)", idx, cycles);
        end
      end

      // Sample output when ready is asserted
      $display("============================================================");
      $display("BLOCK %0d", idx+1);
      $display("PLAINTEXT  = %032h", pt_vec[idx]);
      $display("EXPECTEDCT = %032h", exp_ct[idx]);
      $display("DUT CT     = %032h", ciphertext);

      if (ciphertext !== exp_ct[idx]) begin
        $fatal(1, "Mismatch on block %0d", idx+1);
      end else begin
        $display("[PASS]");
      end

      // ready should be a 1-cycle pulse
      @(posedge clk);
      if (ready !== 1'b0) begin
        $fatal(1, "ready not a 1-cycle pulse (still high after pulse) on block %0d", idx+1);
      end

      if (CHECK_NO_LEAK) begin
        if (ciphertext !== 128'h0) begin
          $fatal(1, "Leakage after pulse: ciphertext != 0 (block %0d): %032h", idx+1, ciphertext);
        end
      end
    end
  endtask

  // ==========================
  // Main
  // ==========================
  initial begin
    go        = 1'b0;
    load      = 1'b0;
    plaintext = '0;
    key       = '0;
    counter1  = '0;

    do_reset();

    // load once per reset
    do_load(init_ctr, master_key);

    // Run 4 blocks, respecting go/ready protocol (no two go pulses without ready between)
    for (i = 0; i < NUM_BLOCKS; i++) begin
      send_block(pt_vec[i]);
      wait_ready_and_check(i);
    end

    $display("============================================================");
    $display("All NIST CTR-AES128 Encrypt vectors passed.");
    $finish;
  end

endmodule

`default_nettype wire

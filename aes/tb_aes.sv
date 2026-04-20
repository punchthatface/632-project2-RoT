`timescale 1ns/1ps
`default_nettype none

module tb_aes;

  logic         clk, rst_n, go;
  logic [127:0] plaintext, key;
  logic [127:0] ciphertext;
  logic         ready;

  // DUT
  aespipeline dut (
    .clk(clk),
    .rst_n(rst_n),
    .go(go),
    .plaintext(plaintext),
    .key(key),
    .ciphertext(ciphertext),
    .ready(ready)
  );

  // clock: 100MHz
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Safety timeout (avoid infinite sim if ready never asserts)
  localparam int READY_TIMEOUT_CYCLES = 200;

  // ==========================
  // TEST VECTORS
  // ==========================
  localparam int NUM_TESTS = 6;

  logic [127:0] pt_vec   [0:NUM_TESTS-1];
  logic [127:0] key_vec  [0:NUM_TESTS-1];
  logic [127:0] exp_vec  [0:NUM_TESTS-1];
  logic         has_exp  [0:NUM_TESTS-1];

  integer t;

  initial begin
    // 0) NIST AES-128 ECB test vector
    pt_vec[0]  = 128'h00112233445566778899aabbccddeeff;
    key_vec[0] = 128'h000102030405060708090a0b0c0d0e0f;
    exp_vec[0] = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    has_exp[0] = 1'b1;

    // 1) all-zero PT / all-zero KEY
    pt_vec[1]  = 128'h00000000000000000000000000000000;
    key_vec[1] = 128'h00000000000000000000000000000000;
    exp_vec[1] = 128'h66e94bd4ef8a2c3b884cfa59ca342b2e;
    has_exp[1] = 1'b1;

    // 2) all-ones PT / all-ones KEY
    pt_vec[2]  = 128'hffffffffffffffffffffffffffffffff;
    key_vec[2] = 128'hffffffffffffffffffffffffffffffff;
    exp_vec[2] = 128'hbcbf217cb280cf30b2517052193ab979;
    has_exp[2] = 1'b1;

    // 3) counting PT / reversed-ish KEY
    pt_vec[3]  = 128'h000102030405060708090a0b0c0d0e0f;
    key_vec[3] = 128'h0f0e0d0c0b0a09080706050403020100;
    exp_vec[3] = 128'he9729381ebafc05b5d46614fec8685e2;
    has_exp[3] = 1'b1;

    // 4) random-ish #1
    pt_vec[4]  = 128'h0123456789abcdeffedcba9876543210;
    key_vec[4] = 128'h0a1b2c3d4e5f60718293a4b5c6d7e8f9;
    exp_vec[4] = 128'hd1616cbdaa860faedeb4fff9ff9a51dd;
    has_exp[4] = 1'b1;

    // 5) random-ish #2
    pt_vec[5]  = 128'hdeadbeefcafebabefacefeed01234567;
    key_vec[5] = 128'h0011ffeeddccbbaa9988776655443322;
    exp_vec[5] = 128'h72460cf01fbe20381755a01f7bf5fa80;
    has_exp[5] = 1'b1;
  end

  // Print helper
  task automatic show_case(input int idx, input logic [127:0] ct);
    begin
      $display("============================================================");
      $display("TEST %0d", idx);
      $display("PLAINTEXT  = %032h", pt_vec[idx]);
      $display("KEY        = %032h", key_vec[idx]);
      $display("CIPHERTEXT = %032h", ct);

      if (has_exp[idx]) begin
        if (ct === exp_vec[idx]) begin
          $display("EXPECTED   = %032h  [PASS]", exp_vec[idx]);
        end else begin
          $display("EXPECTED   = %032h  [FAIL]", exp_vec[idx]);
        end
      end
    end
  endtask

  // Drive one-cycle go, then wait for ready
  task automatic run_one(input int idx);
    int cycles;
    logic [127:0] ct_sample;
    begin
      // Put inputs up BEFORE asserting go
      plaintext <= pt_vec[idx];
      key       <= key_vec[idx];

      // One-cycle pulse for go (inputs valid on that cycle) :contentReference[oaicite:2]{index=2}
      @(posedge clk);
      go <= 1'b1;

      @(posedge clk);
      go <= 1'b0;

      // After go is deasserted, cannot rely on inputs staying stable :contentReference[oaicite:3]{index=3}
      plaintext <= $urandom();
      key       <= $urandom();

      // Wait until ready asserts (first cycle final ciphertext is available) :contentReference[oaicite:4]{index=4}
      cycles = 0;
      while (ready !== 1'b1) begin
        @(posedge clk);
        cycles++;
        if (cycles >= READY_TIMEOUT_CYCLES) begin
          $fatal(1, "Timeout waiting for ready on test %0d (waited %0d cycles)", idx, cycles);
        end
      end

      // Sample ciphertext when ready is high (same cycle)
      ct_sample = ciphertext;
      show_case(idx, ct_sample);

      // Lab says ready should remain asserted forever for aespipe (multiple encryptions require reset)
      // :contentReference[oaicite:5]{index=5}
      if (ready !== 1'b1) begin
        $fatal(1, "ready deasserted unexpectedly right after being observed high (test %0d)", idx);
      end
    end
  endtask

  initial begin
    // init
    go        = 1'b0;
    plaintext = '0;
    key       = '0;

    // reset (active-low, async in DUT; TB just drives it cleanly)
    rst_n = 1'b0;
    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    // NOTE: aespipe protocol: go asserted once only; to run multiple tests, reset between them. :contentReference[oaicite:6]{index=6}
    for (t = 0; t < NUM_TESTS; t = t + 1) begin
      // reset before each new go so we don't violate the interface contract
      rst_n = 1'b0;
      repeat (2) @(posedge clk);
      rst_n = 1'b1;

      run_one(t);
    end

    $display("============================================================");
    $display("Done.");
    $finish;
  end

endmodule

`default_nettype wire

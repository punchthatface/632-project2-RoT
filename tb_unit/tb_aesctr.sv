`timescale 1ns/1ps
`default_nettype none

module tb_aesctr_quickcheck;

  localparam int WIDTH = 128;

  logic             clk, rst_n;
  logic             go;
  logic [WIDTH-1:0] block_in, key;
  logic [WIDTH-1:0] block_out;
  logic             done;

  aesctr dut (
    .clk(clk),
    .rst_n(rst_n),
    .go(go),
    .block_in(block_in),
    .key(key),
    .block_out(block_out),
    .done(done)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  localparam int DONE_TIMEOUT_CYCLES = 100;

  logic [127:0] pt_vec;
  logic [127:0] exp_ct;

  int cycles;

  task automatic do_reset();
    begin
      rst_n = 1'b0;
      repeat (2) @(posedge clk);
      rst_n = 1'b1;
      @(posedge clk);
    end
  endtask

  task automatic send_block(input logic [127:0] pt, input logic [127:0] k);
    begin
      block_in <= pt;
      key      <= k;

      @(posedge clk);
      go <= 1'b1;

      @(posedge clk);
      go <= 1'b0;

      block_in <= '0;
      key      <= '0;
    end
  endtask

  task automatic wait_done_and_check();
    begin
      cycles = 0;

      while (done !== 1'b1) begin
        if (block_out !== 128'h0) begin
          $fatal(1, "Leakage: block_out != 0 while done=0: %032h", block_out);
        end

        @(posedge clk);
        cycles++;
        if (cycles >= DONE_TIMEOUT_CYCLES) begin
          $fatal(1, "Timeout waiting for done");
        end
      end

      $display("============================================================");
      $display("PLAINTEXT = %032h", pt_vec);
      $display("EXPECTED  = %032h", exp_ct);
      $display("DUT OUT   = %032h", block_out);

      if (block_out !== exp_ct) begin
        $fatal(1, "Mismatch");
      end else begin
        $display("[PASS]");
      end

      @(posedge clk);
      if (done !== 1'b0) begin
        $fatal(1, "done not a 1-cycle pulse");
      end

      if (block_out !== 128'h0) begin
        $fatal(1, "Leakage after done pulse: block_out != 0: %032h", block_out);
      end
    end
  endtask

  initial begin
    go       = 1'b0;
    block_in = '0;
    key      = '0;

    // Same AES-128 KAT as the other TB
    pt_vec = 128'h00112233445566778899AABBCCDDEEFF;
    key    = 128'h000102030405060708090A0B0C0D0E0F;
    exp_ct = 128'h69C4E0D86A7B0430D8CDB78070B4C55A;

    do_reset();

    send_block(pt_vec, key);
    wait_done_and_check();

    $display("Quick AES check passed.");
    $finish;
  end

endmodule

`default_nettype wire
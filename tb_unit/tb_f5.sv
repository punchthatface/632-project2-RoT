`timescale 1ns/1ps
`default_nettype none
`include "rot_pkg.sv"
import rot_pkg::*;

module tb_f5;

  localparam int PERIOD     = 10;
  localparam int HALFPERIOD = PERIOD / 2;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;

  logic              clk, rst_n;
  logic [BUSW-1:0]   addr, data_from_cpu;
  logic [BUSW-1:0]   data_to_cpu;
  logic              re, we;

  logic [BUSW-1:0]   status_word;
  logic [AES_W-1:0]  aes_out_word;
  integer            busy_cycles;

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
    begin
      cpu_write(ADDR_UNLOCK_KEY, UNLOCK_KEY);
      cpu_write(ADDR_CMD, CMD_UNLOCK);
      wait_until_idle;
    end
  endtask

  task automatic load_aes_key(input logic [AES_W-1:0] key_in);
    status_reg_t status_dec;
    begin
      @(negedge clk);
      addr          = ADDR_AES_KEY0;
      data_from_cpu = key_in[127:96];
      we            = 1'b1;
      re            = 1'b0;
      @(posedge clk);

      @(negedge clk);
      addr          = ADDR_AES_KEY1;
      data_from_cpu = key_in[95:64];
      @(posedge clk);

      @(negedge clk);
      addr          = ADDR_AES_KEY2;
      data_from_cpu = key_in[63:32];
      @(posedge clk);

      @(negedge clk);
      addr          = ADDR_AES_KEY3;
      data_from_cpu = key_in[31:0];
      @(posedge clk);

      @(negedge clk);
      we            = 1'b0;
      addr          = '0;
      data_from_cpu = '0;

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.aes_key_correct || status_dec.bits.aes_key_incorrect) begin
        $display("FAIL: AES key load was not marked correct");
        $fatal;
      end
    end
  endtask

  task automatic load_aes_plaintext(input logic [AES_W-1:0] pt_in);
    begin
      cpu_write(ADDR_AES_IN0, pt_in[127:96]);
      cpu_write(ADDR_AES_IN1, pt_in[95:64]);
      cpu_write(ADDR_AES_IN2, pt_in[63:32]);
      cpu_write(ADDR_AES_IN3, pt_in[31:0]);
    end
  endtask

  task automatic read_aes_out(output logic [AES_W-1:0] block_out);
    logic [BUSW-1:0] w0, w1, w2, w3;
    begin
      cpu_read(ADDR_AES_OUT0, w0);
      cpu_read(ADDR_AES_OUT1, w1);
      cpu_read(ADDR_AES_OUT2, w2);
      cpu_read(ADDR_AES_OUT3, w3);
      block_out = {w0, w1, w2, w3};
    end
  endtask

  task automatic run_aes_and_read(output logic [AES_W-1:0] block_out);
    status_reg_t status_dec;
    begin
      cpu_write(ADDR_AES_SRC, 32'h0);
      cpu_write(ADDR_CMD, CMD_AES);

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_aes) begin
        $display("FAIL: AES did not enter busy AES state");
        $fatal;
      end

      busy_cycles = 0;
      while (status_dec.bits.busy_global) begin
        cpu_read(ADDR_STATUS, status_word);
        status_dec.word = status_word;
        if (status_dec.bits.busy_global) begin
          busy_cycles = busy_cycles + 1;
          if (busy_cycles > 200) begin
            $display("FAIL: AES never completed");
            $fatal;
          end
        end
      end

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.aes_out_valid) begin
        $display("FAIL: AES completed without aes_out_valid");
        $fatal;
      end

      read_aes_out(block_out);

      if (^block_out === 1'bx) begin
        $display("FAIL: AES produced X data");
        $fatal;
      end
    end
  endtask

  initial begin
    logic [AES_W-1:0] key_vec;
    logic [AES_W-1:0] pt_vec;
    logic [AES_W-1:0] exp_ct;

    rst_n         = 1'b0;
    addr          = '0;
    data_from_cpu = '0;
    re            = 1'b0;
    we            = 1'b0;
    aes_out_word  = '0;

    key_vec = 128'h000102030405060708090A0B0C0D0E0F;
    pt_vec  = 128'h00112233445566778899AABBCCDDEEFF;
    exp_ct  = 128'h69C4E0D86A7B0430D8CDB78070B4C55A;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    unlock_rot;
    load_aes_key(key_vec);
    load_aes_plaintext(pt_vec);
    run_aes_and_read(aes_out_word);

    $display("AES output:");
    $display("  expected = %h", exp_ct);
    $display("  observed = %h", aes_out_word);
    $display("  busy_polls = %0d", busy_cycles);

    if (aes_out_word !== exp_ct) begin
      $display("FAIL: AES output mismatch");
      $fatal;
    end else begin
      $display("PASS: AES top-level encryption matched the known answer");
    end

    $display("tb_f5 passed.");
    $finish;
  end

endmodule

`default_nettype wire

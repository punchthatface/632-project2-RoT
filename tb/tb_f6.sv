`timescale 1ns/1ps
`default_nettype none
import rot_pkg::*;

module tb_f6;

  localparam int PERIOD     = 10;
  localparam int HALFPERIOD = PERIOD / 2;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;

  logic            clk, rst_n;
  logic [BUSW-1:0] addr, data_from_cpu;
  logic [BUSW-1:0] data_to_cpu;
  logic            re, we;

  logic [BUSW-1:0] status_word;
  logic [AES_W-1:0] ct0, ct1, ct2;
  logic [LFSR_W-1:0] ctr_before_0, ctr_before_1, ctr_before_2;
  logic [LFSR_W-1:0] ctr_after_0, ctr_after_1, ctr_after_2;
  integer           busy_cycles;

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

  function automatic logic [LFSR_W-1:0] lfsr_next_once(
    input logic [LFSR_W-1:0] cur
  );
    begin
      if (cur[0])
        lfsr_next_once = (cur >> 1) ^ 16'hB400;
      else
        lfsr_next_once = (cur >> 1);
    end
  endfunction

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

  task automatic seed_lfsr(input logic [LFSR_W-1:0] seed_in);
    begin
      cpu_write(ADDR_LFSR_SEED, {{(BUSW-LFSR_W){1'b0}}, seed_in});
    end
  endtask

  task automatic read_aes_out(output logic [AES_W-1:0] ct_out);
    logic [BUSW-1:0] w0, w1, w2, w3;
    begin
      cpu_read(ADDR_AES_OUT0, w0);
      cpu_read(ADDR_AES_OUT1, w1);
      cpu_read(ADDR_AES_OUT2, w2);
      cpu_read(ADDR_AES_OUT3, w3);
      ct_out = {w0, w1, w2, w3};
    end
  endtask

  task automatic run_aes_ctr_and_read(
    output logic [AES_W-1:0] ct_out,
    input  string            label
  );
    status_reg_t status_dec;
    begin
      cpu_write(ADDR_CMD, CMD_AES_CTR);

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_aes_ctr) begin
        $display("FAIL: %s did not enter busy AES-CTR state", label);
        $fatal;
      end

      busy_cycles = 0;
      while (status_dec.bits.busy_global) begin
        cpu_read(ADDR_STATUS, status_word);
        status_dec.word = status_word;
        if (status_dec.bits.busy_global) begin
          busy_cycles = busy_cycles + 1;
          if (busy_cycles > 200) begin
            $display("FAIL: %s never completed", label);
            $fatal;
          end
        end
      end

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.aes_out_valid) begin
        $display("FAIL: %s completed without aes_out_valid", label);
        $fatal;
      end

      read_aes_out(ct_out);

      if (^ct_out === 1'bx) begin
        $display("FAIL: %s produced X data", label);
        $fatal;
      end

      $display("PASS: %s produced %h after %0d busy polls", label, ct_out, busy_cycles);
    end
  endtask

  initial begin
    logic [AES_W-1:0] key_vec;
    logic [AES_W-1:0] pt_vec;

    rst_n         = 1'b0;
    addr          = '0;
    data_from_cpu = '0;
    re            = 1'b0;
    we            = 1'b0;
    ct0           = '0;
    ct1           = '0;
    ct2           = '0;
    ctr_before_0  = '0;
    ctr_before_1  = '0;
    ctr_before_2  = '0;
    ctr_after_0   = '0;
    ctr_after_1   = '0;
    ctr_after_2   = '0;

    key_vec = 128'h000102030405060708090A0B0C0D0E0F;
    pt_vec  = 128'h00112233445566778899AABBCCDDEEFF;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Feature F6 flow:
    // 1. Unlock the RoT.
    // 2. Load a valid AES key and plaintext.
    // 3. Seed the shared LFSR/counter.
    // 4. Issue repeated AES-CTR commands and show the shared LFSR/counter advances once per call.
    unlock_rot;
    load_aes_key(key_vec);
    load_aes_plaintext(pt_vec);
    seed_lfsr(16'h1D2B);

    ctr_before_0 = dut.lfsr_seq;
    run_aes_ctr_and_read(ct0, "first AES-CTR");
    ctr_after_0 = dut.lfsr_seq;

    ctr_before_1 = dut.lfsr_seq;
    run_aes_ctr_and_read(ct1, "second AES-CTR");
    ctr_after_1 = dut.lfsr_seq;

    ctr_before_2 = dut.lfsr_seq;
    run_aes_ctr_and_read(ct2, "third AES-CTR");
    ctr_after_2 = dut.lfsr_seq;

    $display("AES-CTR outputs:");
    $display("  ct0 = %h", ct0);
    $display("  ct1 = %h", ct1);
    $display("  ct2 = %h", ct2);
    $display("AES-CTR counter progression:");
    $display("  ctr_before_0 = %h  ctr_after_0 = %h", ctr_before_0, ctr_after_0);
    $display("  ctr_before_1 = %h  ctr_after_1 = %h", ctr_before_1, ctr_after_1);
    $display("  ctr_before_2 = %h  ctr_after_2 = %h", ctr_before_2, ctr_after_2);

    if (ctr_after_0 !== lfsr_next_once(ctr_before_0)) begin
      $display("FAIL: first AES-CTR call did not advance counter correctly");
      $fatal;
    end

    if (ctr_after_1 !== lfsr_next_once(ctr_before_1)) begin
      $display("FAIL: second AES-CTR call did not advance counter correctly");
      $fatal;
    end

    if (ctr_after_2 !== lfsr_next_once(ctr_before_2)) begin
      $display("FAIL: third AES-CTR call did not advance counter correctly");
      $fatal;
    end

    if ((ct0 == ct1) || (ct1 == ct2) || (ct0 == ct2)) begin
      $display("FAIL: AES-CTR outputs did not reflect distinct counter states");
      $fatal;
    end else begin
      $display("PASS: AES-CTR counter progressed and outputs differ across calls");
    end

    $display("tb_f6 passed.");
    $finish;
  end

endmodule

`default_nettype wire

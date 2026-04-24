`timescale 1ns/1ps
`default_nettype none
import rot_pkg::*;

module tb_f6;

  localparam int PERIOD     = 10;
  localparam int HALFPERIOD = PERIOD / 2;
  localparam int NUM_CTR_CALLS = 3;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;

  logic            clk, rst_n;
  logic [BUSW-1:0] addr, data_from_cpu;
  logic [BUSW-1:0] data_to_cpu;
  logic            re, we;

  logic [BUSW-1:0] status_word;
  logic [AES_W-1:0] ct_set_a [0:NUM_CTR_CALLS-1];
  logic [AES_W-1:0] ct_set_b [0:NUM_CTR_CALLS-1];
  logic [LFSR_W-1:0] ctr_before_set_a [0:NUM_CTR_CALLS-1];
  logic [LFSR_W-1:0] ctr_after_set_a  [0:NUM_CTR_CALLS-1];
  logic [LFSR_W-1:0] ctr_before_set_b [0:NUM_CTR_CALLS-1];
  logic [LFSR_W-1:0] ctr_after_set_b  [0:NUM_CTR_CALLS-1];
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

  // Mirrors the shared LFSR's one-step update so this TB can check counter progression.
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

  // Writes the AES key in the required KEY0..KEY3 consecutive-cycle order.
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

  // Loads a full 128-bit plaintext block into the AES input registers.
  task automatic load_aes_plaintext(input logic [AES_W-1:0] pt_in);
    begin
      cpu_write(ADDR_AES_IN0, pt_in[127:96]);
      cpu_write(ADDR_AES_IN1, pt_in[95:64]);
      cpu_write(ADDR_AES_IN2, pt_in[63:32]);
      cpu_write(ADDR_AES_IN3, pt_in[31:0]);
    end
  endtask

  // Seeds the shared LFSR used as the AES-CTR counter source.
  task automatic seed_lfsr(input logic [LFSR_W-1:0] seed_in);
    begin
      cpu_write(ADDR_LFSR_SEED, {{(BUSW-LFSR_W){1'b0}}, seed_in});
    end
  endtask

  // Reads the 128-bit AES output register bank back into one block value.
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

  // Starts one AES-CTR command, waits for completion, and reads the ciphertext.
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
    logic [AES_W-1:0] pt_vec_a;
    logic [AES_W-1:0] pt_vec_b;
    logic [LFSR_W-1:0] seed_a;
    logic [LFSR_W-1:0] seed_b;
    integer i;

    rst_n         = 1'b0;
    addr          = '0;
    data_from_cpu = '0;
    re            = 1'b0;
    we            = 1'b0;
    for (i = 0; i < NUM_CTR_CALLS; i = i + 1) begin
      ct_set_a[i]        = '0;
      ct_set_b[i]        = '0;
      ctr_before_set_a[i] = '0;
      ctr_after_set_a[i]  = '0;
      ctr_before_set_b[i] = '0;
      ctr_after_set_b[i]  = '0;
    end

    key_vec  = 128'h000102030405060708090A0B0C0D0E0F;
    pt_vec_a = 128'h00112233445566778899AABBCCDDEEFF;
    pt_vec_b = 128'hFFEEDDCCBBAA99887766554433221100;
    seed_a   = 16'h1D2B;
    seed_b   = 16'hACE1;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Feature F6 flow:
    // 1. Unlock the RoT.
    // 2. Load a valid AES key and plaintext.
    // 3. Seed the shared LFSR/counter.
    // 4. Issue repeated AES-CTR commands and show the shared LFSR/counter advances once per call.
    // 5. Repeat with a different plaintext and seed to show the counter path works across multiple scenarios.
    unlock_rot;
    load_aes_key(key_vec);
    load_aes_plaintext(pt_vec_a);
    seed_lfsr(seed_a);

    for (i = 0; i < NUM_CTR_CALLS; i = i + 1) begin
      ctr_before_set_a[i] = dut.lfsr_seq;
      run_aes_ctr_and_read(ct_set_a[i], $sformatf("AES-CTR set A call %0d", i));
      ctr_after_set_a[i] = dut.lfsr_seq;
    end

    load_aes_plaintext(pt_vec_b);
    seed_lfsr(seed_b);

    for (i = 0; i < NUM_CTR_CALLS; i = i + 1) begin
      ctr_before_set_b[i] = dut.lfsr_seq;
      run_aes_ctr_and_read(ct_set_b[i], $sformatf("AES-CTR set B call %0d", i));
      ctr_after_set_b[i] = dut.lfsr_seq;
    end

    $display("AES-CTR outputs:");
    for (i = 0; i < NUM_CTR_CALLS; i = i + 1)
      $display("  ct_set_a[%0d] = %h", i, ct_set_a[i]);
    for (i = 0; i < NUM_CTR_CALLS; i = i + 1)
      $display("  ct_set_b[%0d] = %h", i, ct_set_b[i]);
    $display("AES-CTR counter progression:");
    for (i = 0; i < NUM_CTR_CALLS; i = i + 1)
      $display("  set A %0d: %h -> %h", i, ctr_before_set_a[i], ctr_after_set_a[i]);
    for (i = 0; i < NUM_CTR_CALLS; i = i + 1)
      $display("  set B %0d: %h -> %h", i, ctr_before_set_b[i], ctr_after_set_b[i]);

    for (i = 0; i < NUM_CTR_CALLS; i = i + 1) begin
      if (ctr_after_set_a[i] !== lfsr_next_once(ctr_before_set_a[i])) begin
        $display("FAIL: AES-CTR set A call %0d did not advance counter correctly", i);
        $fatal;
      end
      if (ctr_after_set_b[i] !== lfsr_next_once(ctr_before_set_b[i])) begin
        $display("FAIL: AES-CTR set B call %0d did not advance counter correctly", i);
        $fatal;
      end
      if (^ct_set_a[i] === 1'bx || ^ct_set_b[i] === 1'bx) begin
        $display("FAIL: AES-CTR produced X data in set %s call %0d", (^ct_set_a[i] === 1'bx) ? "A" : "B", i);
        $fatal;
      end
    end

    for (i = 1; i < NUM_CTR_CALLS; i = i + 1) begin
      if (ct_set_a[i] == ct_set_a[i-1]) begin
        $display("FAIL: AES-CTR set A calls %0d and %0d produced identical ciphertexts", i-1, i);
        $fatal;
      end
      if (ct_set_b[i] == ct_set_b[i-1]) begin
        $display("FAIL: AES-CTR set B calls %0d and %0d produced identical ciphertexts", i-1, i);
        $fatal;
      end
    end

    if (ct_set_a[0] == ct_set_b[0]) begin
      $display("FAIL: changing plaintext and seed did not change the first AES-CTR ciphertext");
      $fatal;
    end else begin
      $display("PASS: AES-CTR counter progressed and ciphertexts changed across both scenarios");
    end

    $display("tb_f6 passed.");
    $finish;
  end

endmodule

`default_nettype wire

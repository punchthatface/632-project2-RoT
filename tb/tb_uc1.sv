`timescale 1ns/1ps
`default_nettype none
import rot_pkg::*;

module tb_uc1;

  localparam int PERIOD     = 10;
  localparam int HALFPERIOD = PERIOD / 2;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;
  localparam int PUF_CHUNK_W = 30;

  logic             clk, rst_n;
  logic [BUSW-1:0]  addr, data_from_cpu;
  logic [BUSW-1:0]  data_to_cpu;
  logic             re, we;

  logic             ref_go;
  logic [AES_W-1:0] ref_block_in, ref_key, ref_block_out;
  logic             ref_done;

  logic [BUSW-1:0]  status_word;
  logic [AES_W-1:0] aes_out_word;
  logic [AES_W-1:0] puf_enc_word;
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

  aesctr u_ref_aes (
    .clk(clk),
    .rst_n(rst_n),
    .go(ref_go),
    .block_in(ref_block_in),
    .key(ref_key),
    .block_out(ref_block_out),
    .done(ref_done)
  );

  initial begin
    clk = 1'b0;
    forever #HALFPERIOD clk = ~clk;
  end

  function automatic logic [PUF_CHUNK_W-1:0] puf_chunk(
    input logic [PUF_W-1:0] sig,
    input int               idx
  );
    begin
      case (idx)
        0:       puf_chunk = sig[29:0];
        1:       puf_chunk = sig[59:30];
        2:       puf_chunk = sig[89:60];
        default: puf_chunk = sig[119:90];
      endcase
    end
  endfunction

  function automatic logic [AES_W-1:0] puf_chunk_block(
    input logic [PUF_W-1:0] sig,
    input int               idx
  );
    begin
      puf_chunk_block = {{(AES_W-PUF_CHUNK_W){1'b0}}, puf_chunk(sig, idx)};
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
      while ((timeout < 800) && !idle_seen) begin
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

  task automatic load_good_aes_key(input logic [AES_W-1:0] key_in);
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
        $display("FAIL: correct AES key load was not marked correct");
        $fatal;
      end
    end
  endtask

  task automatic read_puf_signature(output logic [PUF_W-1:0] sig_out);
    logic [BUSW-1:0] sig0, sig1, sig2, sig3;
    begin
      cpu_read(ADDR_PUF_SIG0, sig0);
      cpu_read(ADDR_PUF_SIG1, sig1);
      cpu_read(ADDR_PUF_SIG2, sig2);
      cpu_read(ADDR_PUF_SIG3, sig3);
      sig_out = {sig3[23:0], sig2, sig1, sig0};
    end
  endtask

  task automatic wait_for_puf_valid;
    status_reg_t status_dec;
    logic done_polling;
    begin
      busy_cycles = 0;
      done_polling = 1'b0;
      while (!done_polling) begin
        cpu_read(ADDR_STATUS, status_word);
        status_dec.word = status_word;
        if (!status_dec.bits.busy_global) begin
          done_polling = 1'b1;
        end else begin
          busy_cycles = busy_cycles + 1;
          if (busy_cycles > 800) begin
            $display("FAIL: PUF generation never completed");
            $fatal;
          end
        end
      end

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.puf_valid) begin
        $display("FAIL: PUF generation completed without puf_valid");
        $fatal;
      end
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

  task automatic read_puf_enc_block(
    input  int              idx,
    output logic [AES_W-1:0] block_out
  );
    logic [BUSW-1:0] w0, w1, w2, w3;
    logic [BUSW-1:0] a0, a1, a2, a3;
    begin
      case (idx)
        0: begin a0 = ADDR_PUF_ENC0_0; a1 = ADDR_PUF_ENC0_1; a2 = ADDR_PUF_ENC0_2; a3 = ADDR_PUF_ENC0_3; end
        1: begin a0 = ADDR_PUF_ENC1_0; a1 = ADDR_PUF_ENC1_1; a2 = ADDR_PUF_ENC1_2; a3 = ADDR_PUF_ENC1_3; end
        2: begin a0 = ADDR_PUF_ENC2_0; a1 = ADDR_PUF_ENC2_1; a2 = ADDR_PUF_ENC2_2; a3 = ADDR_PUF_ENC2_3; end
        default: begin a0 = ADDR_PUF_ENC3_0; a1 = ADDR_PUF_ENC3_1; a2 = ADDR_PUF_ENC3_2; a3 = ADDR_PUF_ENC3_3; end
      endcase

      cpu_read(a0, w0);
      cpu_read(a1, w1);
      cpu_read(a2, w2);
      cpu_read(a3, w3);
      block_out = {w0, w1, w2, w3};
    end
  endtask

  task automatic ref_encrypt_block(
    input  logic [AES_W-1:0] block_in,
    input  logic [AES_W-1:0] key_in,
    output logic [AES_W-1:0] block_out
  );
    integer cycles;
    begin
      ref_block_in = block_in;
      ref_key      = key_in;

      @(negedge clk);
      ref_go = 1'b1;
      @(posedge clk);
      @(negedge clk);
      ref_go = 1'b0;

      cycles = 0;
      while (!ref_done) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (cycles > 100) begin
          $display("FAIL: reference AES timed out");
          $fatal;
        end
      end

      block_out = ref_block_out;
      @(posedge clk);
    end
  endtask

  task automatic run_aes_puf_encrypt_and_check(
    input int               idx,
    input logic [AES_W-1:0] key_in,
    input logic [PUF_W-1:0] puf_sig_in
  );
    status_reg_t status_dec;
    logic [AES_W-1:0] expected_block;
    logic [AES_W-1:0] plain_block;
    begin
      plain_block = puf_chunk_block(puf_sig_in, idx);
      ref_encrypt_block(plain_block, key_in, expected_block);

      cpu_write(ADDR_CMD, CMD_AES);

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_aes) begin
        $display("FAIL: PUF AES chunk %0d did not enter busy AES state", idx);
        $fatal;
      end

      wait_until_idle;

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.aes_out_valid) begin
        $display("FAIL: PUF AES chunk %0d completed without aes_out_valid", idx);
        $fatal;
      end

      read_aes_out(aes_out_word);
      read_puf_enc_block(idx, puf_enc_word);

      if (aes_out_word !== expected_block) begin
        $display("FAIL: AES output mismatch for PUF chunk %0d", idx);
        $display(" expected = %h", expected_block);
        $display(" observed = %h", aes_out_word);
        $fatal;
      end

      if (puf_enc_word !== expected_block) begin
        $display("FAIL: stored encrypted PUF chunk mismatch for chunk %0d", idx);
        $display(" expected = %h", expected_block);
        $display(" stored   = %h", puf_enc_word);
        $fatal;
      end

      $display("PASS: PUF chunk %0d encrypted to %h", idx, expected_block);
    end
  endtask

  initial begin
    status_reg_t status_dec;
    logic [AES_W-1:0] key_vec;
    logic [PUF_W-1:0] puf_sig_snapshot;
    integer idx;

    rst_n         = 1'b0;
    addr          = '0;
    data_from_cpu = '0;
    re            = 1'b0;
    we            = 1'b0;
    ref_go        = 1'b0;
    ref_block_in  = '0;
    ref_key       = '0;
    aes_out_word  = '0;
    puf_enc_word  = '0;

    key_vec = 128'h000102030405060708090A0B0C0D0E0F;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // UC1 Section 3.1 flow:
    // Step 1. CPU attempts PUF generation while locked.
    // Step 2. CPU writes unlock key.
    // Step 3. CPU issues unlock command.
    // Step 4. CPU waits until idle.
    // Step 5. CPU loads a chosen AES key in order.
    // Step 6. CPU checks AES key load status.
    // Step 7. CPU commands PUF generation.
    // Step 8. CPU waits until idle.
    // Step 9. CPU selects PUF as the AES plaintext source.
    // Step 10. CPU issues four AES commands, waiting between them.
    // Step 11. CPU reads back encrypted PUF data 32 bits at a time.
    $display("UC1 Step 1: attempt PUF generation while locked");
    cpu_write(ADDR_CMD, CMD_PUF_GEN);
    repeat (10) @(posedge clk);
    cpu_read(ADDR_STATUS, status_word);
    status_dec.word = status_word;
    if (status_dec.bits.busy_global || status_dec.bits.puf_valid) begin
      $display("FAIL: locked PUF command changed PUF state");
      $fatal;
    end
    $display("PASS: locked PUF command did not run");

    $display("UC1 Step 2: write unlock key");
    cpu_write(ADDR_UNLOCK_KEY, UNLOCK_KEY);
    $display("UC1 Step 3: issue unlock command");
    cpu_write(ADDR_CMD, CMD_UNLOCK);
    $display("UC1 Step 4: wait until RoT is idle after unlock");
    wait_until_idle;

    $display("UC1 Step 5: load the 128-bit AES key");
    load_good_aes_key(key_vec);
    $display("UC1 Step 6: check AES key load status");
    cpu_read(ADDR_STATUS, status_word);
    status_dec.word = status_word;
    if (!status_dec.bits.aes_key_correct || status_dec.bits.aes_key_incorrect) begin
      $display("FAIL: AES key status was not correct after load");
      $fatal;
    end

    $display("UC1 Step 7: issue PUF generation command");
    cpu_write(ADDR_CMD, CMD_PUF_GEN);
    $display("UC1 Step 8: wait until RoT is idle after PUF generation");
    wait_for_puf_valid;
    read_puf_signature(puf_sig_snapshot);
    $display("UC1 Step 8 result: puf_sig = %h", puf_sig_snapshot);

    $display("UC1 Step 9: select PUF as the AES plaintext source");
    cpu_write(ADDR_AES_SRC, 32'h1);

    $display("UC1 Step 10: issue four AES commands, one per PUF chunk");
    for (idx = 0; idx < 4; idx = idx + 1) begin
      $display("UC1 Step 10.%0d: encrypt PUF chunk %0d", idx + 1, idx);
      run_aes_puf_encrypt_and_check(idx, key_vec, puf_sig_snapshot);
    end

    $display("UC1 Step 11: read encrypted PUF data back 32 bits at a time");
    for (idx = 0; idx < 4; idx = idx + 1) begin
      read_puf_enc_block(idx, puf_enc_word);
      $display("UC1 Step 11 chunk %0d: puf_enc = %h", idx, puf_enc_word);
    end

    $display("tb_uc1 passed.");
    $finish;
  end

endmodule

`default_nettype wire

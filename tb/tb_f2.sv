`timescale 1ns/1ps
`default_nettype none
import rot_pkg::*;

module tb_f2;

  localparam int PERIOD     = 10;
  localparam int HALFPERIOD = PERIOD / 2;
  localparam logic [BUSW-1:0] UNLOCK_KEY = 32'hB27D553A;

  logic            clk, rst_n;
  logic [BUSW-1:0] addr, data_from_cpu;
  logic [BUSW-1:0] data_to_cpu;
  logic            re, we;

  logic [BUSW-1:0] status_word;
  logic [PUF_W-1:0] puf_sig_a, puf_sig_b;
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
    status_reg_t status_dec;
    begin
      cpu_write(ADDR_UNLOCK_KEY, UNLOCK_KEY);
      cpu_write(ADDR_CMD, CMD_UNLOCK);
      wait_until_idle;
      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
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

  task automatic run_puf_and_read(
    output logic [PUF_W-1:0] sig_out,
    input  string            label
  );
    status_reg_t status_dec;
    logic done_polling;
    begin
      cpu_write(ADDR_CMD, CMD_PUF_GEN);

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.busy_global || !status_dec.bits.busy_puf) begin
        $display("FAIL: %s did not enter busy PUF state", label);
        $fatal;
      end

      busy_cycles = 0;
      done_polling = 1'b0;
      while (!done_polling) begin
        cpu_read(ADDR_STATUS, status_word);
        status_dec.word = status_word;
        if (!status_dec.bits.busy_global) begin
          done_polling = 1'b1;
        end else begin
          busy_cycles = busy_cycles + 1;
          if (busy_cycles > 500) begin
            $display("FAIL: %s never completed", label);
            $fatal;
          end
        end
      end

      cpu_read(ADDR_STATUS, status_word);
      status_dec.word = status_word;
      if (!status_dec.bits.puf_valid) begin
        $display("FAIL: %s completed without puf_valid", label);
        $fatal;
      end

      read_puf_signature(sig_out);

      if (^sig_out === 1'bx) begin
        $display("FAIL: %s produced X data", label);
        $fatal;
      end

      $display("PASS: %s produced %h after %0d busy polls", label, sig_out, busy_cycles);
    end
  endtask

  initial begin
    rst_n         = 1'b0;
    addr          = '0;
    data_from_cpu = '0;
    re            = 1'b0;
    we            = 1'b0;
    puf_sig_a     = '0;
    puf_sig_b     = '0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Feature F2 flow:
    // 1. Unlock the RoT.
    // 2. Generate a PUF signature.
    // 3. Read back the 120-bit signature through CPU-visible registers.
    // 4. Generate it again later and confirm reproducibility.
    unlock_rot;

    run_puf_and_read(puf_sig_a, "first PUF generation");
    repeat (10) @(posedge clk);
    run_puf_and_read(puf_sig_b, "second PUF generation");

    $display("PUF signatures:");
    $display("  puf_sig_a = %h", puf_sig_a);
    $display("  puf_sig_b = %h", puf_sig_b);

    if (puf_sig_a !== puf_sig_b) begin
      $display("FAIL: PUF signature not reproducible");
      $fatal;
    end else begin
      $display("PASS: PUF signature is reproducible");
    end

    $display("tb_f2 passed.");
    $finish;
  end

endmodule

`default_nettype wire

`timescale 1ns/1ps
`default_nettype none

module tb_puf;

  localparam int STAGES       = 19;
  localparam int COUNTER_SIZE = 10;
  localparam int WAIT_CYCLES  = 32;
  localparam int RO_NUM       = 16;
  localparam int PUF_W        = (RO_NUM * (RO_NUM - 1)) / 2;

  localparam int PERIOD       = 10;
  localparam int HALFPERIOD   = PERIOD / 2;

  logic                                clk, rst_n;
  logic                                gen;
  logic                                ro_enable;
  logic [RO_NUM-1:0]                   ro_feedback;
  logic [RO_NUM-1:0][COUNTER_SIZE-1:0] ro_count;
  logic [PUF_W-1:0]                    puf_sig;
  logic                                pufready;

  logic [PUF_W-1:0] sig_first, sig_second;

  integer ready_count;

  ro_bank #(
    .STAGES(STAGES),
    .COUNTER_SIZE(COUNTER_SIZE),
    .RO_NUM(RO_NUM)
  ) u_ro_bank (
    .enable(ro_enable),
    .feedback(ro_feedback),
    .count(ro_count)
  );

  puf #(
    .COUNTER_SIZE(COUNTER_SIZE),
    .WAIT_CYCLES(WAIT_CYCLES),
    .RO_NUM(RO_NUM),
    .PUF_W(PUF_W)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .gen(gen),
    .ro_count(ro_count),
    .ro_enable(ro_enable),
    .puf_sig(puf_sig),
    .pufready(pufready)
  );

  // ------------------------------------------------------------
  // Clock
  // ------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #HALFPERIOD clk = ~clk;
  end

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n)
      ready_count <= 0;
    else begin
      if (pufready)
        ready_count <= ready_count + 1;
    end
  end

  task automatic pulse_gen;
    begin
      @(negedge clk);
      gen = 1'b1;
      @(posedge clk);
      @(negedge clk);
      gen = 1'b0;
    end
  endtask

  task automatic wait_ready_and_capture(output logic [PUF_W-1:0] sig_out);
    begin
      wait (pufready === 1'b1);
      sig_out = puf_sig;

      @(posedge clk);
      @(negedge clk);
      if (pufready !== 1'b0) begin
        $display("FAIL: pufready did not deassert after one cycle");
        $fatal;
      end
    end
  endtask

  initial begin
    rst_n      = 1'b0;
    gen        = 1'b0;
    sig_first  = '0;
    sig_second = '0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ------------------------------------------------------------
    // First generation
    // ------------------------------------------------------------
    pulse_gen;
    wait_ready_and_capture(sig_first);

    if (^sig_first === 1'bx) begin
      $display("FAIL: first PUF signature contains X");
      $fatal;
    end else begin
      $display("PASS: first PUF signature captured: %h", sig_first);
    end

    // ------------------------------------------------------------
    // Second generation in same simulation
    // Signature should be reproducible
    // ------------------------------------------------------------
    repeat (5) @(posedge clk);

    pulse_gen;
    wait_ready_and_capture(sig_second);

    if (^sig_second === 1'bx) begin
      $display("FAIL: second PUF signature contains X");
      $fatal;
    end

    if (sig_first !== sig_second) begin
      $display("FAIL: PUF signature not reproducible");
      $display(" first  = %h", sig_first);
      $display(" second = %h", sig_second);
      $fatal;
    end else begin
      $display("PASS: PUF signature is reproducible");
    end

    if (ready_count != 2) begin
      $display("FAIL: expected 2 pufready pulses, got %0d", ready_count);
      $fatal;
    end

    $display("All puf unit tests passed.");
    $finish;
  end

endmodule

`default_nettype wire
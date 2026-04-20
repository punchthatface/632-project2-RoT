`default_nettype none

module tb_lfsr_load;

  localparam WIDTH      = 16;
  localparam PERIOD     = 10;
  localparam HALFPERIOD = PERIOD / 2;

  localparam logic [WIDTH-1:0] SEED     = 16'hACE1;
  localparam logic [WIDTH-1:0] TAP_MASK = 16'hB400;

  logic             clk, rst_n;
  logic             load, pulse;
  logic [WIDTH-1:0] load_value;
  logic [WIDTH-1:0] seq;

  lfsr_load #(
    .WIDTH(WIDTH)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .load(load),
    .pulse(pulse),
    .load_value(load_value),
    .seq(seq)
  );

  // ------------------------------------------------------------
  // Clock
  // ------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #HALFPERIOD clk = ~clk;
  end

  // ------------------------------------------------------------
  // Reference next-state function
  // ------------------------------------------------------------
  function automatic logic [WIDTH-1:0] lfsr_next(input logic [WIDTH-1:0] cur);
    begin
      if (cur[0])
        lfsr_next = (cur >> 1) ^ TAP_MASK;
      else
        lfsr_next = (cur >> 1);
    end
  endfunction

  // ------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------
  task automatic do_pulse;
    begin
      @(negedge clk);
      pulse = 1'b1;
      @(posedge clk);
      @(negedge clk);
      pulse = 1'b0;
    end
  endtask

  task automatic do_load(input logic [WIDTH-1:0] val);
    begin
      @(negedge clk);
      load       = 1'b1;
      load_value = val;
      @(posedge clk);
      @(negedge clk);
      load       = 1'b0;
      load_value = '0;
    end
  endtask

  task automatic check_seq(input logic [WIDTH-1:0] expected, input string msg);
    begin
      if (seq !== expected) begin
        $display("FAIL: %s expected=%h got=%h", msg, expected, seq);
        $fatal;
      end else begin
        $display("PASS: %s seq=%h", msg, seq);
      end
    end
  endtask

  // ------------------------------------------------------------
  // Test sequence
  // ------------------------------------------------------------
  logic [WIDTH-1:0] expected;

  initial begin
    rst_n      = 1'b0;
    load       = 1'b0;
    pulse      = 1'b0;
    load_value = '0;
    expected   = '0;

    // asynchronous reset -> seed
    #1;
    check_seq(SEED, "reset drives seed");

    @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    check_seq(SEED, "seed held after reset release");

    // single pulse
    expected = lfsr_next(SEED);
    do_pulse;
    check_seq(expected, "single pulse advances once");

    // second pulse
    expected = lfsr_next(expected);
    do_pulse;
    check_seq(expected, "second pulse advances once");

    // load arbitrary value
    expected = 16'h1234;
    do_load(16'h1234);
    check_seq(expected, "load writes explicit value");

    // pulse after load
    expected = lfsr_next(expected);
    do_pulse;
    check_seq(expected, "pulse after load advances from loaded value");

    // load must have priority over pulse
    @(negedge clk);
    load       = 1'b1;
    pulse      = 1'b1;
    load_value = 16'hBEEF;
    @(posedge clk);
    @(negedge clk);
    load       = 1'b0;
    pulse      = 1'b0;
    load_value = '0;
    expected   = 16'hBEEF;
    check_seq(expected, "load has priority over pulse");

    // load zero should fall back to seed
    do_load('0);
    expected = SEED;
    check_seq(expected, "zero load falls back to seed");

    // several pulses in a row
    repeat (5) begin
      expected = lfsr_next(expected);
      do_pulse;
      check_seq(expected, "multi-pulse progression");
    end

    $display("All lfsr_load unit tests passed.");
    $finish;
  end

endmodule

`default_nettype wire
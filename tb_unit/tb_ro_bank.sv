`timescale 1ns/1ps
`default_nettype none

module tb_ro_bank;

  localparam int STAGES       = 19;
  localparam int COUNTER_SIZE = 10;
  localparam int RO_NUM       = 16;

  logic                                enable;
  logic [RO_NUM-1:0]                   feedback;
  logic [RO_NUM-1:0][COUNTER_SIZE-1:0] count;

  logic [RO_NUM-1:0][COUNTER_SIZE-1:0] count_before;
  logic [RO_NUM-1:0][COUNTER_SIZE-1:0] count_after;

  integer i;
  integer changed_cnt;

  ro_bank #(
    .STAGES(STAGES),
    .COUNTER_SIZE(COUNTER_SIZE),
    .RO_NUM(RO_NUM)
  ) dut (
    .enable(enable),
    .feedback(feedback),
    .count(count)
  );

  initial begin
    enable = 1'b0;

    // ------------------------------------------------------------
    // With enable low, counters should remain stable
    // ------------------------------------------------------------
    #20;
    count_before = count;
    #20;
    count_after = count;

    if (count_after !== count_before) begin
      $display("FAIL: counts changed while enable=0");
      $fatal;
    end else begin
      $display("PASS: counts stable while enable=0");
    end

    // ------------------------------------------------------------
    // With enable high, counters should start changing
    // ------------------------------------------------------------
    enable = 1'b1;

    #50;
    count_before = count;
    #50;
    count_after = count;

    changed_cnt = 0;
    for (i = 0; i < RO_NUM; i = i + 1) begin
      if (count_after[i] !== count_before[i])
        changed_cnt = changed_cnt + 1;
    end

    if (changed_cnt == 0) begin
      $display("FAIL: no counters changed while enable=1");
      $fatal;
    end else begin
      $display("PASS: %0d counters changed while enable=1", changed_cnt);
    end

    // ------------------------------------------------------------
    // Basic sanity: not all counters should be identical
    // ------------------------------------------------------------
    changed_cnt = 0;
    for (i = 1; i < RO_NUM; i = i + 1) begin
      if (count_after[i] !== count_after[0])
        changed_cnt = changed_cnt + 1;
    end

    if (changed_cnt == 0) begin
      $display("FAIL: all counters are identical");
      $fatal;
    end else begin
      $display("PASS: counters are not all identical");
    end

    $display("All ro_bank unit tests passed.");
    $finish;
  end

endmodule

`default_nettype wire
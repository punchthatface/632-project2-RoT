`default_nettype none

module tb_prime;

  localparam WIDTH      = 10;
  localparam PERIOD     = 10;
  localparam HALFPERIOD = PERIOD / 2;

  logic             clk, rst_n, go;
  logic [WIDTH-1:0] number;
  logic             isprime, done;

  integer cycle_count;
  integer latency_ref;
  integer latency_cur;

  prime #(
    .WIDTH(WIDTH)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .go(go),
    .number(number),
    .isprime(isprime),
    .done(done)
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
      cycle_count <= 0;
    else
      cycle_count <= cycle_count + 1;
  end

  // ------------------------------------------------------------
  // Reference primality function for checking DUT output
  // ------------------------------------------------------------
  function automatic logic ref_isprime(input logic [WIDTH-1:0] n);
    integer d;
    begin
      if (n < 2) begin
        ref_isprime = 1'b0;
      end else begin
        ref_isprime = 1'b1;
        for (d = 2; d < n; d = d + 1) begin
          if ((n % d) == 0)
            ref_isprime = 1'b0;
        end
      end
    end
  endfunction

  // ------------------------------------------------------------
  // One test transaction
  // - pulses go for one cycle
  // - waits for done
  // - checks output correctness
  // - checks done is a one-cycle pulse
  // - checks latency against reference if already established
  // ------------------------------------------------------------
  task automatic run_case(input logic [WIDTH-1:0] n);
    integer launch_cycle;
    logic expected;
    begin
      expected = ref_isprime(n);

      // drive request
      @(negedge clk);
      number = n;
      go     = 1'b1;

      @(posedge clk);
      launch_cycle = cycle_count;

      @(negedge clk);
      go = 1'b0;

      // wait for done pulse
      wait (done === 1'b1);
      latency_cur = cycle_count - launch_cycle;

      if (isprime !== expected) begin
        $display("FAIL: n=%0d expected isprime=%0b got %0b", n, expected, isprime);
        $fatal;
      end

      // establish / compare constant latency
      if (latency_ref < 0) begin
        latency_ref = latency_cur;
        $display("Reference latency established at %0d cycles", latency_ref);
      end else if (latency_cur != latency_ref) begin
        $display("FAIL: n=%0d latency mismatch expected %0d got %0d",
                 n, latency_ref, latency_cur);
        $fatal;
      end

      // done must be a one-cycle pulse
      @(posedge clk);
      @(negedge clk);
      if (done !== 1'b0) begin
        $display("FAIL: done did not deassert after one cycle for n=%0d", n);
        $fatal;
      end

      $display("PASS: n=%0d isprime=%0b latency=%0d", n, isprime, latency_cur);
    end
  endtask

  // ------------------------------------------------------------
  // Test sequence
  // ------------------------------------------------------------
  initial begin
    rst_n       = 1'b0;
    go          = 1'b0;
    number      = '0;
    latency_ref = -1;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    // wait one cycle after reset
    @(posedge clk);

    // primes
    run_case(10'd2);
    run_case(10'd3);
    run_case(10'd5);
    run_case(10'd31);
    run_case(10'd127);
    run_case(10'd509);

    // composites / non-primes
    run_case(10'd0);
    run_case(10'd1);
    run_case(10'd4);
    run_case(10'd9);
    run_case(10'd21);
    run_case(10'd511);

    $display("All prime unit tests passed.");
    $finish;
  end

endmodule

`default_nettype wire
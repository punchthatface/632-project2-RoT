`timescale 1ps/1ps

module puf #(
  parameter STAGES       = 9,
  parameter COUNTER_SIZE = 10,
  parameter WAIT_CYCLES  = 32
)(
  input  logic clk, rst_n,
  input  logic gen,
  output logic pufbit,
  output logic pufready
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_RUN,
    ST_SAMPLE,
    ST_DONE
  } state_t;

  state_t state, next_state;

  logic [$clog2(WAIT_CYCLES+1)-1:0] wait_ctr, next_wait_ctr;
  logic enable;
  logic sample;

  // Output signals from ROs
  logic fb1, fb2;
  logic [COUNTER_SIZE-1:0] count1, count2;

  ring #(
    .STAGES(STAGES),
    .COUNTER_SIZE(COUNTER_SIZE)
  ) ro1 (
    .enable(enable),
    .feedback(fb1),
    .count(count1)
  );

  ring #(
    .STAGES(STAGES),
    .COUNTER_SIZE(COUNTER_SIZE)
  ) ro2 (
    .enable(enable),
    .feedback(fb2),
    .count(count2)
  );

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      state    <= ST_IDLE;
      wait_ctr <= '0;
      pufbit   <= 1'b0;
    end else begin
      state    <= next_state;
      wait_ctr <= next_wait_ctr;

      if (sample) begin
        pufbit <= (count1 > count2);
      end
    end
  end

  always_comb begin
    next_state    = state;
    next_wait_ctr = wait_ctr;
    enable        = 1'b0;
    sample        = 1'b0;
    pufready      = 1'b0;

    case (state)
      ST_IDLE: begin
        if (gen) begin
          next_state    = ST_RUN;
          next_wait_ctr = '0;
        end
      end

      ST_RUN: begin
        enable = 1'b1;
        if (wait_ctr == WAIT_CYCLES-1)
          next_state = ST_SAMPLE;
        else
          next_wait_ctr = wait_ctr + 1'b1;
      end

      ST_SAMPLE: begin
        enable     = 1'b1;
        sample     = 1'b1;
        next_state = ST_DONE;
      end

      ST_DONE: begin
        pufready   = 1'b1;
        next_state = ST_IDLE;
      end

      default: begin
        next_state = ST_IDLE;
      end
    endcase
  end

endmodule
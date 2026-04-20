`timescale 1ns/1ps
`default_nettype none

 // ------------------------------------------------------------
  // Constant-time prime checker with FI-hardened control FSM
  // - checks every divisor from 2 through 31
  // - no early exit
  // - invalid FSM encoding falls into sticky fault state
  // ------------------------------------------------------------
module prime #(
  parameter WIDTH = 10
)(
  input  logic             clk, rst_n, go,
  input  logic [WIDTH-1:0] number,
  output logic             isprime,
  output logic             done
);

  typedef enum logic [3:0] {
    ST_IDLE  = 4'b0001,
    ST_RUN   = 4'b0010,
    ST_DONE  = 4'b0100,
    ST_FAULT = 4'b1000
  } prime_state_t;

  prime_state_t       state, state_next;
  logic [WIDTH-1:0]   number_reg, number_next;
  logic [5:0]         divisor, divisor_next;
  logic               composite, composite_next;
  logic               isprime_reg, isprime_next;
  logic               state_valid;

  assign state_valid =
    (state == ST_IDLE ) ||
    (state == ST_RUN  ) ||
    (state == ST_DONE ) ||
    (state == ST_FAULT);

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_IDLE;
      number_reg  <= '0;
      divisor     <= '0;
      composite   <= 1'b0;
      isprime_reg <= 1'b0;
    end else begin
      state       <= state_next;
      number_reg  <= number_next;
      divisor     <= divisor_next;
      composite   <= composite_next;
      isprime_reg <= isprime_next;
    end
  end

  always_comb begin
    state_next      = state;
    number_next     = number_reg;
    divisor_next    = divisor;
    composite_next  = composite;
    isprime_next    = isprime_reg;

    done    = 1'b0;
    isprime = isprime_reg;

    if (!state_valid) begin
      state_next      = ST_FAULT;
      number_next     = '0;
      divisor_next    = '0;
      composite_next  = 1'b1;
      isprime_next    = 1'b0;
    end else begin
      unique case (state)

        ST_IDLE: begin
          if (go) begin
            number_next     = number;
            divisor_next    = 6'd2;
            composite_next  = 1'b0;
            isprime_next    = 1'b0;
            state_next      = ST_RUN;
          end
        end

        ST_RUN: begin
          if ((number_reg >= 2) &&
              (number_reg != divisor) &&
              (number_reg % divisor == 0)) begin
            composite_next = 1'b1;
          end

          if (divisor == 6'd31) begin
            if ((number_reg < 2) || composite_next) begin
              isprime_next = 1'b0;
            end else begin
              isprime_next = 1'b1;
            end

            state_next = ST_DONE;
          end else begin
            divisor_next = divisor + 6'd1;
          end
        end

        ST_DONE: begin
          done       = 1'b1;
          state_next = ST_IDLE;
        end

        ST_FAULT: begin
          isprime    = 1'b0;
          done       = 1'b0;
          state_next = ST_FAULT;
        end

        default: begin
          state_next      = ST_FAULT;
          number_next     = '0;
          divisor_next    = '0;
          composite_next  = 1'b1;
          isprime_next    = 1'b0;
        end

      endcase
    end
  end

endmodule

`default_nettype wire
module prime #(parameter WIDTH = 11) (
  input  logic             clk, rst_n, go,
  input  logic [WIDTH-1:0] number,
  output logic             isprime, isnotprime
);

  logic next_isprime, next_isnotprime;

  logic [1:0] state, next_state;
  logic [WIDTH-1:0] dividend, next_dividend;
  logic [WIDTH-1:0] divisor,  next_divisor;

  localparam logic [1:0] ST_WAIT_FOR_GO   = 2'b00;
  localparam logic [1:0] ST_TRY_TO_DIVIDE = 2'b01;
  localparam logic [1:0] ST_ENDED         = 2'b10;

  // Sequential (synchronous active-low reset, same as original)
  always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
      state      <= ST_WAIT_FOR_GO;
      isprime    <= 1'b0;
      isnotprime <= 1'b0;
      dividend   <= {WIDTH{1'b0}};
      divisor    <= {WIDTH{1'b0}};
    end
    else begin
      state      <= next_state;
      isprime    <= next_isprime;
      isnotprime <= next_isnotprime;
      dividend   <= next_dividend;
      divisor    <= next_divisor;
    end
  end

  always_comb begin
    next_isprime    = isprime;
    next_isnotprime = isnotprime;
    next_state      = state;
    next_dividend   = dividend;
    next_divisor    = divisor;

    case (state)
      ST_WAIT_FOR_GO: begin
        if (go) begin
          next_dividend = number;

          // Trivial checks (fast early-out)
          // Note: original design can hang for number=1; this prevents that and reduces latency.
          if (number < 2) begin
            next_isnotprime = 1'b1;
            next_state      = ST_ENDED;
          end
          else if (number == 2) begin
            next_isprime = 1'b1;
            next_state   = ST_ENDED;
          end
          else if (number[0] == 1'b0) begin
            // even and >2 => not prime
            next_isnotprime = 1'b1;
            next_state      = ST_ENDED;
          end
          else begin
            // odd >= 3: start with divisor=3 (skip testing divisor=2 again)
            next_divisor = 'd3;
            next_state   = ST_TRY_TO_DIVIDE;
          end
        end
        else begin
          next_state = ST_WAIT_FOR_GO;
        end
      end

      ST_TRY_TO_DIVIDE: begin
        // If divisor*divisor > dividend, we are done
        logic [2*WIDTH-1:0] div_sq;
        logic [2*WIDTH-1:0] dividend_ext;

        div_sq  = divisor * divisor;
        dividend_ext = {{WIDTH{1'b0}}, dividend};

        if (div_sq > dividend_ext) begin
          next_isprime = 1'b1;
          next_state   = ST_ENDED;
        end
        else if ((dividend % divisor) == 0) begin
          next_isnotprime = 1'b1;
          next_state      = ST_ENDED;
        end
        else begin
          // Divisor progression: odd divisors only (3,5,7,...)
          next_divisor = divisor + 2;
          next_state   = ST_TRY_TO_DIVIDE;
        end
      end

      ST_ENDED: begin
        next_state = ST_ENDED;
      end

      default: begin
        next_state = ST_WAIT_FOR_GO;
      end
    endcase
  end

endmodule

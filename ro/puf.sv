`default_nettype none

module puf #(
  parameter COUNTER_SIZE = 10,
  parameter WAIT_CYCLES  = 256,
  parameter RO_NUM       = 16,
  parameter PUF_W        = ((RO_NUM * (RO_NUM - 1)) / 2)
)(
  input  logic                                clk, rst_n,
  input  logic                                gen,
  input  logic [RO_NUM-1:0][COUNTER_SIZE-1:0] ro_count,
  output logic                                ro_enable,
  output logic [PUF_W-1:0]                    puf_sig,
  output logic                                pufready
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_RUN,
    ST_SAMPLE,
    ST_DONE
  } state_t;

  state_t state, state_next;

  int unsigned wait_ctr, wait_ctr_next;

  function automatic logic [PUF_W-1:0] build_sig(
    input logic [RO_NUM-1:0][COUNTER_SIZE-1:0] counts
  );
    logic [PUF_W-1:0] sig;
    integer i, j, k;
    begin
      sig = '0;
      k   = 0;

      // Every bit records which RO in a unique pair counted faster during
      // the sampling window, giving 16 choose 2 = 120 bits for RO_NUM=16.
      for (i = 0; i < RO_NUM; i = i + 1) begin
        for (j = i + 1; j < RO_NUM; j = j + 1) begin
          sig[k] = (counts[i] > counts[j]);
          k = k + 1;
        end
      end

      build_sig = sig;
    end
  endfunction

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      state    <= ST_IDLE;
      wait_ctr <= 0;
      puf_sig  <= '0;
    end else begin
      state    <= state_next;
      wait_ctr <= wait_ctr_next;

      if (state == ST_SAMPLE)
        puf_sig <= build_sig(ro_count);
    end
  end

  // ------------------------------------------------------------
  // PUF controller
  // Keep RO enable high during SAMPLE so counters are still valid
  // when the signature is captured.
  // ------------------------------------------------------------
  always_comb begin
    state_next    = state;
    wait_ctr_next = wait_ctr;

    ro_enable = 1'b0;
    pufready  = 1'b0;

    unique case (state)
      ST_IDLE: begin
        if (gen) begin
          wait_ctr_next = 0;
          state_next    = ST_RUN;
        end
      end

      ST_RUN: begin
        ro_enable = 1'b1;

        if (wait_ctr == (WAIT_CYCLES - 1))
          state_next = ST_SAMPLE;
        else
          wait_ctr_next = wait_ctr + 1;
      end

      ST_SAMPLE: begin
        ro_enable  = 1'b1;
        state_next = ST_DONE;
      end

      ST_DONE: begin
        pufready   = 1'b1;
        state_next = ST_IDLE;
      end

      default: begin
        state_next = ST_IDLE;
      end
    endcase
  end

endmodule

`default_nettype wire

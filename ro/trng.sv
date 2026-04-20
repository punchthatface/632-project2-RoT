`default_nettype none

module trng #(
  parameter RO_NUM = 16,
  parameter WORD_W = 32
)(
  input  logic              clk, rst_n,
  input  logic              gen32, gen16,
  input  logic [RO_NUM-1:0] ro_feedback,
  output logic              ro_enable,
  output logic [WORD_W-1:0] trng_word,
  output logic              trngready
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_RUN,
    ST_DONE
  } state_t;

  state_t state, state_next;

  logic [WORD_W-1:0] shift_reg, shift_reg_next;
  logic [5:0]        bit_count, bit_count_next;
  logic [5:0]        target_count, target_count_next;
  logic [3:0]        mix_sel, mix_sel_next;
  logic              entropy_bit;

  // ------------------------------------------------------------
  // Combine multiple RO outputs.
  // mix_sel changes every request so repeated calls in the same
  // simulation do not trivially replay the same word.
  // ------------------------------------------------------------
  assign entropy_bit =
      ro_feedback[(mix_sel + 4'd0)  & 4'hF] ^
      ro_feedback[(mix_sel + 4'd3)  & 4'hF] ^
      ro_feedback[(mix_sel + 4'd5)  & 4'hF] ^
      ro_feedback[(mix_sel + 4'd7)  & 4'hF] ^
      ro_feedback[(mix_sel + 4'd9)  & 4'hF] ^
      ro_feedback[(mix_sel + 4'd11) & 4'hF] ^
      ro_feedback[(mix_sel + 4'd13) & 4'hF] ^
      ro_feedback[(mix_sel + 4'd15) & 4'hF];

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      state        <= ST_IDLE;
      shift_reg    <= '0;
      bit_count    <= '0;
      target_count <= '0;
      mix_sel      <= 4'd0;
    end else begin
      state        <= state_next;
      shift_reg    <= shift_reg_next;
      bit_count    <= bit_count_next;
      target_count <= target_count_next;
      mix_sel      <= mix_sel_next;
    end
  end

  // ------------------------------------------------------------
  // TRNG controller
  // - gen32 / gen16 are one-cycle start pulses
  // - one entropy bit is sampled per clock while running
  // - current latency is 17 cycles for gen16 and 33 for gen32
  // ------------------------------------------------------------
  always_comb begin
    state_next        = state;
    shift_reg_next    = shift_reg;
    bit_count_next    = bit_count;
    target_count_next = target_count;
    mix_sel_next      = mix_sel;

    ro_enable = 1'b0;
    trngready = 1'b0;
    trng_word = shift_reg;

    unique case (state)
      ST_IDLE: begin
        if (gen32) begin
          shift_reg_next    = '0;
          bit_count_next    = '0;
          target_count_next = 6'd32;
          mix_sel_next      = mix_sel + 4'd1;
          state_next        = ST_RUN;

        end else if (gen16) begin
          shift_reg_next    = '0;
          bit_count_next    = '0;
          target_count_next = 6'd16;
          mix_sel_next      = mix_sel + 4'd1;
          state_next        = ST_RUN;
        end
      end

      ST_RUN: begin
        ro_enable = 1'b1;

        shift_reg_next = {shift_reg[WORD_W-2:0], entropy_bit};

        if (bit_count == (target_count - 1)) begin
          bit_count_next = '0;
          state_next     = ST_DONE;
        end else begin
          bit_count_next = bit_count + 6'd1;
        end
      end

      ST_DONE: begin
        trngready  = 1'b1;
        trng_word  = shift_reg;
        state_next = ST_IDLE;
      end

      default: begin
        state_next = ST_IDLE;
      end
    endcase
  end

endmodule

`default_nettype wire
`default_nettype none

module trng #(
  parameter RO_NUM = 16,
  parameter WORD_W = 32
)(
  input  logic              clk, rst_n,
  input  logic              gen32, gen16,
  input  logic              force_disable,
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
  logic [5:0]        warmup_count, warmup_count_next;
  logic              ro_running, ro_running_next;
  logic              entropy_bit;
  logic              sample_en;

  localparam int WARMUP_CYCLES = 8;

  // ------------------------------------------------------------
  // Combine multiple free-running RO outputs using a fixed mixer.
  // Randomness comes from RO timing variation over time while the
  // bank remains enabled across idle time between requests.
  // ------------------------------------------------------------
  assign sample_en = (warmup_count >= WARMUP_CYCLES);
  assign entropy_bit = ro_feedback[0]  ^ ro_feedback[1]  ^
                       ro_feedback[2]  ^ ro_feedback[3]  ^
                       ro_feedback[4]  ^ ro_feedback[5]  ^
                       ro_feedback[6]  ^ ro_feedback[7]  ^
                       ro_feedback[8]  ^ ro_feedback[9]  ^
                       ro_feedback[10] ^ ro_feedback[11] ^
                       ro_feedback[12] ^ ro_feedback[13] ^
                       ro_feedback[14] ^ ro_feedback[15];

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      state        <= ST_IDLE;
      shift_reg    <= '0;
      bit_count    <= '0;
      target_count <= '0;
      warmup_count <= '0;
      ro_running   <= 1'b0;
    end else begin
      state        <= state_next;
      shift_reg    <= shift_reg_next;
      bit_count    <= bit_count_next;
      target_count <= target_count_next;
      warmup_count <= warmup_count_next;
      ro_running   <= ro_running_next;
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
    warmup_count_next = warmup_count;
    ro_running_next   = ro_running;

    // The top level uses force_disable to hand exclusive RO-bank ownership
    // to the PUF path for one cycle before its counters start running.
    if (force_disable)
      ro_running_next = 1'b0;

    ro_enable = ro_running_next;
    trngready = 1'b0;
    trng_word = shift_reg;

    unique case (state)
      ST_IDLE: begin
        if (gen32) begin
          ro_running_next   = 1'b1;
          shift_reg_next    = '0;
          bit_count_next    = '0;
          target_count_next = 6'd32;
          // First request starts from a freshly enabled bank; later requests
          // sample a bank that has continued evolving during idle time.
          if (ro_running)
            warmup_count_next = WARMUP_CYCLES;
          else
            warmup_count_next = '0;
          state_next        = ST_RUN;

        end else if (gen16) begin
          ro_running_next   = 1'b1;
          shift_reg_next    = '0;
          bit_count_next    = '0;
          target_count_next = 6'd16;
          if (ro_running)
            warmup_count_next = WARMUP_CYCLES;
          else
            warmup_count_next = '0;
          state_next        = ST_RUN;
        end
      end

      ST_RUN: begin
        if (!sample_en) begin
          // Give the bank a short startup/resynchronization window before
          // shifting entropy bits into the CPU-visible word.
          warmup_count_next = warmup_count + 6'd1;
        end else begin
          shift_reg_next = {shift_reg[WORD_W-2:0], entropy_bit};

          if (bit_count == (target_count - 1)) begin
            bit_count_next = '0;
            state_next     = ST_DONE;
          end else begin
            bit_count_next = bit_count + 6'd1;
          end
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

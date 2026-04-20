`default_nettype none

module aesctr #(parameter WIDTH = 128) (
  input  logic             clk, rst_n,
  input  logic             go,
  input  logic [WIDTH-1:0] block_in,
  input  logic [WIDTH-1:0] key,
  output logic [WIDTH-1:0] block_out,
  output logic             done
);

  typedef enum logic [3:0] {
    WAIT_GO,
    ROUND0,
    ROUND1,
    ROUND2,
    ROUND3,
    ROUND4,
    ROUND5,
    ROUND6,
    ROUND7,
    ROUND8,
    ROUND9,
    ROUND10,
    OUT
  } state_t;

  state_t state, next_state;

  logic load_aes_regs;

  logic [3:0] rc;

  logic [WIDTH-1:0] reg_block_in, reg_input_key;
  logic [WIDTH-1:0] reg_round_text, reg_round_key;
  logic [WIDTH-1:0] next_text, next_key;

  logic [WIDTH-1:0] text_rounds, curr_round_key;
  logic [WIDTH-1:0] final_subbed, final_shifted, final_val;

  // ------------------------------------------------------------
  // FSM state register
  // ------------------------------------------------------------
  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      state <= WAIT_GO;
    end else begin
      state <= next_state;
    end
  end

  // ------------------------------------------------------------
  // Inputs are latched on go so later CPU writes do not disturb
  // the current AES operation.
  // ------------------------------------------------------------
  reg_with_load #(.W(WIDTH)) u_reg_block_in (
    .clk, .rst_n, .load(go), .D(block_in), .Q(reg_block_in)
  );

  reg_with_load #(.W(WIDTH)) u_reg_input_key (
    .clk, .rst_n, .load(go), .D(key), .Q(reg_input_key)
  );

  // ------------------------------------------------------------
  // Main AES state/key registers
  // ------------------------------------------------------------
  reg_with_load #(.W(WIDTH)) u_reg_text (
    .clk, .rst_n, .load(load_aes_regs), .D(next_text), .Q(reg_round_text)
  );

  reg_with_load #(.W(WIDTH)) u_reg_key (
    .clk, .rst_n, .load(load_aes_regs), .D(next_key), .Q(reg_round_key)
  );

  // ------------------------------------------------------------
  // AES control FSM
  // go is a one-cycle launch pulse.
  // done is a one-cycle completion pulse in OUT.
  // ------------------------------------------------------------
  always_comb begin
    next_state    = state;
    load_aes_regs = 1'b0;
    done          = 1'b0;

    unique case (state)
      WAIT_GO: begin
        if (go) begin
          next_state = ROUND0;
        end
      end

      ROUND0: begin
        next_state    = ROUND1;
        load_aes_regs = 1'b1;
      end

      ROUND1: begin
        next_state    = ROUND2;
        load_aes_regs = 1'b1;
      end

      ROUND2: begin
        next_state    = ROUND3;
        load_aes_regs = 1'b1;
      end

      ROUND3: begin
        next_state    = ROUND4;
        load_aes_regs = 1'b1;
      end

      ROUND4: begin
        next_state    = ROUND5;
        load_aes_regs = 1'b1;
      end

      ROUND5: begin
        next_state    = ROUND6;
        load_aes_regs = 1'b1;
      end

      ROUND6: begin
        next_state    = ROUND7;
        load_aes_regs = 1'b1;
      end

      ROUND7: begin
        next_state    = ROUND8;
        load_aes_regs = 1'b1;
      end

      ROUND8: begin
        next_state    = ROUND9;
        load_aes_regs = 1'b1;
      end

      ROUND9: begin
        next_state    = ROUND10;
        load_aes_regs = 1'b1;
      end

      ROUND10: begin
        next_state    = OUT;
        load_aes_regs = 1'b1;
      end

      OUT: begin
        next_state = WAIT_GO;
        done       = 1'b1;
      end

      default: begin
        next_state = WAIT_GO;
      end
    endcase
  end

  // ------------------------------------------------------------
  // Round constant selection for key schedule
  // ROUND1 -> rc=0, ..., ROUND10 -> rc=9
  // ------------------------------------------------------------
  always_comb begin
    if (state >= ROUND1 && state <= ROUND10)
      rc = state - ROUND1;
    else
      rc = 4'd9;
  end

  // ------------------------------------------------------------
  // Datapath progression
  // Distinction between AES and AES-CTR are made outside of this module
  // ------------------------------------------------------------
  always_comb begin
    next_text = reg_round_text;
    next_key  = reg_round_key;

    unique case (state)
      WAIT_GO: begin
      end

      ROUND0: begin
        next_text = reg_block_in ^ reg_input_key;
        next_key  = reg_input_key;
      end

      ROUND1, ROUND2, ROUND3, ROUND4, ROUND5,
      ROUND6, ROUND7, ROUND8, ROUND9: begin
        next_text = text_rounds;
        next_key  = curr_round_key;
      end

      ROUND10: begin
        next_text = final_val;
        next_key  = curr_round_key;
      end

      OUT: begin
      end

      default: begin
      end
    endcase
  end

  // ------------------------------------------------------------
  // AES round logic
  // ------------------------------------------------------------
  schedule u_sched (
    .rc(rc),
    .key(reg_round_key),
    .keyout(curr_round_key)
  );

  round u_round (
    .text(reg_round_text),
    .key(curr_round_key),
    .out_text(text_rounds)
  );

  subBytes u_finalsub (
    .bytes(reg_round_text),
    .subbed_bytes(final_subbed)
  );

  shiftRows u_finalshift (
    .in(final_subbed),
    .out(final_shifted)
  );

  assign final_val = final_shifted ^ curr_round_key;

  // ------------------------------------------------------------
  // Output gating
  // Only expose the final AES result when done is asserted.
  // ------------------------------------------------------------
  assign block_out = done ? reg_round_text : '0;

endmodule


module reg_with_load #(parameter W = 128) (
  input  logic         clk, rst_n,
  input  logic         load,
  input  logic [W-1:0] D,
  output logic [W-1:0] Q
);

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n)
      Q <= '0;
    else begin
      if (load)
        Q <= D;
    end
  end

endmodule

`default_nettype wire
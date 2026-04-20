module aespipeline #(parameter WIDTH = 128) (
  input  logic clk, rst_n,
  input  logic go,
  input  logic [WIDTH-1:0] plaintext, key,
  output logic [WIDTH-1:0] ciphertext,
  output logic ready
);

  //######################### STATE KEEPING LOGIC #########################

  // FSM state logic, also acting as a counter to reduce FF count (4 FF)
  typedef enum logic [3:0] {
    IDLE    = 4'd0,
    ROUND1  = 4'd1,
    ROUND2  = 4'd2,
    ROUND3  = 4'd3,
    ROUND4  = 4'd4,
    ROUND5  = 4'd5,
    ROUND6  = 4'd6,
    ROUND7  = 4'd7,
    ROUND8  = 4'd8,
    ROUND9  = 4'd9,
    ROUND10 = 4'd10,
    DONE    = 4'd11
  } state_t;
  state_t state, next_state;

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end

  // Next state logic + counter
  always_comb begin
    next_state = state; // default

    unique case (state)
      IDLE: begin
        if (go) begin
          next_state = ROUND1;
        end
      end
      ROUND1: begin
        next_state = ROUND2;
      end
      ROUND2: begin
        next_state = ROUND3;
      end
      ROUND3: begin
        next_state = ROUND4;
      end
      ROUND4: begin
        next_state = ROUND5;
      end
      ROUND5: begin
        next_state = ROUND6;
      end
      ROUND6: begin
        next_state = ROUND7;
      end
      ROUND7: begin
        next_state = ROUND8;
      end
      ROUND8: begin
        next_state = ROUND9;
      end
      ROUND9: begin
        next_state = ROUND10;
      end
      ROUND10: begin
        next_state = DONE;
      end
      DONE: begin
        next_state = DONE;
      end
    endcase
  end

  // Counter for key generation
  logic [3:0] rc;
  always_comb begin
    if (state >= ROUND1 && state <= ROUND10)
      rc = state - 4'd1; // count happens to be state num - 1
    else
      rc = 4'd9;
  end

  //########################## OUTPUT LOGIC ################################

  // Register for text and key
  logic [WIDTH-1:0] reg_text, reg_key;

  // Intermediary values
  logic [WIDTH-1:0] next_text, next_key;
  logic [WIDTH-1:0] text_rounds, key_rounds;
  logic [WIDTH-1:0] final_subbed, final_shifted, final_val;

  logic load_reg; // flag to tell register whether or not it should load value or not

  // Register for AES state and key (128 + 128 = 256 total)
  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      reg_text <= '0;
      reg_key <= '0;
    end else begin
      if (load_reg) begin
        reg_text <= next_text;
        reg_key <= next_key;
      end
    end
  end

  // Next text/key selection mux + ready output logic
  always_comb begin
    next_text = reg_text;
    next_key  = reg_key;
    ready     = 1'b0;
    load_reg  = 1'b0;

    unique case (state)
      IDLE: begin
        if (go) begin
          next_text = plaintext ^ key;
          next_key  = key;
          load_reg  = 1'b1;
        end
      end
      ROUND1, ROUND2, ROUND3, ROUND4, ROUND5,
      ROUND6, ROUND7, ROUND8, ROUND9: begin
        next_text = text_rounds;
        next_key  = key_rounds;
        load_reg  = 1'b1;
      end
      ROUND10: begin
        next_text = final_val;
        next_key  = key_rounds;
        load_reg  = 1'b1;
        ready     = 1'b0;
      end
      DONE: begin
        load_reg = 1'b0;
        ready    = 1'b1;
      end
    endcase 
  end


  // Rounds 1~9
  schedule u_sched ( // key gen
    .rc(rc),
    .key(reg_key),
    .keyout(key_rounds)
  );
  round u_round ( // AES loop
    .text(reg_text),
    .key(key_rounds),
    .out_text(text_rounds)
  );

  // Final round i = 10
  subBytes u_finalsub (.bytes(reg_text), .subbed_bytes(final_subbed));
  shiftRows u_finalshift (.in(final_subbed), .out(final_shifted));
  assign final_val = final_shifted ^ key_rounds;

  // To keep signal names simple
  assign ciphertext = reg_text;

endmodule

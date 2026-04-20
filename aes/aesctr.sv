module aesctr #(parameter WIDTH = 128) (
  input  logic             clk, rst_n,
  input  logic             go, load,
  input  logic [WIDTH-1:0] counter1, plaintext, key,
  output logic [WIDTH-1:0] ciphertext,
  output logic             ready
);
  
  //######################### STATE KEEPING LOGIC #########################

  // FSM state logic, also acting as a counter to reduce FF count (4 FF)
  typedef enum logic [3:0] {
    WAIT_LOAD = 4'd0,
    WAIT_GO   = 4'd1,
    ROUND0    = 4'd2,
    ROUND1    = 4'd3,
    ROUND2    = 4'd4,
    ROUND3    = 4'd5,
    ROUND4    = 4'd6,
    ROUND5    = 4'd7,
    ROUND6    = 4'd8,
    ROUND7    = 4'd9,
    ROUND8    = 4'd10,
    ROUND9    = 4'd11,
    ROUND10   = 4'd12,
    OUT       = 4'd13
  } state_t;
  state_t state, next_state;

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      state <= WAIT_LOAD;
    end else begin
      state <= next_state;
    end
  end
  
  // Control signals
  logic counter_en;
  logic load_aes_regs;

  // Next state logic + control signal logic
  always_comb begin
    next_state    = state; // default
    counter_en    = 1'b0;
    load_aes_regs = 1'b0;
    ready         = 1'b0;

    unique case (state)
      WAIT_LOAD: begin
        if (load) begin
          next_state = WAIT_GO;
        end
      end
      WAIT_GO: begin
        if (go) begin
          next_state = ROUND0;
          load_aes_regs = 1'b1;
        end
      end
      ROUND0: begin
        next_state = ROUND1;
        load_aes_regs = 1'b1;
      end
      ROUND1: begin
        next_state = ROUND2;
        load_aes_regs = 1'b1;
      end
      ROUND2: begin
        next_state = ROUND3;
        load_aes_regs = 1'b1;
      end
      ROUND3: begin
        next_state = ROUND4;
        load_aes_regs = 1'b1;
      end
      ROUND4: begin
        next_state = ROUND5;
        load_aes_regs = 1'b1;
      end
      ROUND5: begin
        next_state = ROUND6;
        load_aes_regs = 1'b1;
      end
      ROUND6: begin
        next_state = ROUND7;
        load_aes_regs = 1'b1;
      end
      ROUND7: begin
        next_state = ROUND8;
        load_aes_regs = 1'b1;
      end
      ROUND8: begin
        next_state = ROUND9;
        load_aes_regs = 1'b1;
      end
      ROUND9: begin
        next_state = ROUND10;
        load_aes_regs = 1'b1;
      end
      ROUND10: begin
        next_state = OUT;
        counter_en = 1'b1; // increment counter for next loop
        load_aes_regs = 1'b1;
      end
      OUT: begin
        next_state = WAIT_GO;
        ready = 1'b1;
      end
    endcase
  end

  // Counter used in key generation
  logic [3:0] rc;
  always_comb begin
    if (state >= ROUND1 && state <= ROUND10)
      rc = state - 4'd3; // key count happens to be state num - 3
    else
      rc = 4'd9;
  end

  //########################## OUTPUT LOGIC ################################

  // LOADED AT START - Only loaded once per reset
  logic [WIDTH-1:0] counter_reg;
  counterBlock #(.W(128), .N(10)) u_counter_block(
    .clk(clk), .rst_n(rst_n),
    .load(load), .en(counter_en),
    .counter1(counter1),
    .out(counter_reg)
  );

  logic [WIDTH-1:0] master_key;
  reg_with_load #(.W(WIDTH)) u_reg_master_key(
    .clk, .rst_n, .load(load), .D(key), .Q(master_key)
  );

  // LOADED IN AES rounds - Loaded repeatedely

  // Register for plaintext
  logic [WIDTH-1:0] reg_plaintext;
  reg_with_load #(.W(WIDTH)) u_reg_plaintext(
    .clk, .rst_n, .load(go), .D(plaintext), .Q(reg_plaintext)
  );

  // Register for AES state and key (128 + 128 = 256 total)
  logic [WIDTH-1:0] reg_round_text, reg_round_key;
  logic [WIDTH-1:0] next_text, next_key;
  reg_with_load #(.W(WIDTH)) u_reg_text(
    .clk, .rst_n, .load(load_aes_regs), .D(next_text), .Q(reg_round_text)
  );
  reg_with_load #(.W(WIDTH)) u_reg_key(
    .clk, .rst_n, .load(load_aes_regs), .D(next_key), .Q(reg_round_key)
  );

  // Intermediary values
  logic [WIDTH-1:0] text_rounds, curr_round_key;
  logic [WIDTH-1:0] final_subbed, final_shifted, final_val;

  // Next text/key selection mux + ready output logic
  always_comb begin
    next_text = reg_round_text;
    next_key  = reg_round_key;

    unique case (state)
      WAIT_LOAD: begin
        // nothing to do here
      end
      WAIT_GO: begin
        // nothing to do here
      end
      ROUND0: begin
        next_text = counter_reg ^ master_key;
        next_key  = master_key;
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
        //
      end
    endcase 
  end


  // Rounds 1~9
  schedule u_sched ( // key gen
    .rc(rc),
    .key(reg_round_key),
    .keyout(curr_round_key)
  );
  round u_round ( // AES loop
    .text(reg_round_text),
    .key(curr_round_key),
    .out_text(text_rounds)
  );

  // Final round i = 10
  subBytes u_finalsub (.bytes(reg_round_text), .subbed_bytes(final_subbed));
  shiftRows u_finalshift (.in(final_subbed), .out(final_shifted));
  assign final_val = final_shifted ^ curr_round_key;

  // Keep output to 0 until ready to prevent data leakage
  assign ciphertext = ready ? (reg_round_text ^ reg_plaintext) : '0;

endmodule


/* Increments the lower N bits of given input and wraps around upon overflow
   W is the total width of input, and N is the num bit to add.  */
module counterBlock #(parameter int W=128, parameter int N=10) (
  input  logic         clk, rst_n,
  input  logic         load, en,
  input  logic [W-1:0] counter1,
  output logic [W-1:0] out
);

  logic [W-1:0] ctr;

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      ctr <= '0;
    end else if (load) begin
      ctr <= counter1;
    end else if (en) begin
      ctr[N-1:0] <= ctr[N-1:0] + 1'b1;
    end
  end

  assign out = ctr;

endmodule


// Simple register module to keep top module clean
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
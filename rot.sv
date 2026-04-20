`default_nettype none
`include "rot_pkg.sv"
import rot_pkg::*;

module rot (
  input  logic            clk, rst_n,
  input  logic [BUSW-1:0] addr, data_from_cpu,
  output logic [BUSW-1:0] data_to_cpu,
  input  logic            re, we
);

  typedef enum logic [4:0] {
    ST_LOCK_0    = 5'd0,
    ST_LOCK_1    = 5'd1,
    ST_LOCK_2    = 5'd2,
    ST_LOCK_3    = 5'd3,
    ST_LOCK_4    = 5'd4,
    ST_LOCK_5    = 5'd5,
    ST_LOCK_6    = 5'd6,
    ST_LOCK_7    = 5'd7,
    ST_LOCK_TRAP = 5'd8,

    ST_IDLE      = 5'd9,

    ST_AES       = 5'd10,
    ST_AES_CTR   = 5'd11,
    ST_AES_PUF   = 5'd12,
    ST_PUF       = 5'd13,
    ST_TRNG32    = 5'd14,
    ST_TRNG16    = 5'd15,
    ST_PRNG_SEED = 5'd16,
    ST_PRNG_RUN  = 5'd17,
    ST_PRIME     = 5'd18
  } rot_state_t;

  rot_state_t state, state_next;

  rot_regs_t   regs;
  rot_ctrl_t   ctrl, ctrl_next;
  status_reg_t status;
  rot_hw_wr_t  hw_wr;

  logic        cmd_valid;
  cmd_t        cmd_opcode;
  logic        unlock_key_we;

  logic             aes_go, aes_load, aes_ready;
  logic [AES_W-1:0] aes_counter1, aes_plaintext, aes_key, aes_ciphertext;

  logic             prime_go, isprime, isnotprime;
  logic [PRIME_W-1:0] prime_number;

  rot_csr u_rot_csr (
    .clk(clk), .rst_n(rst_n),
    .addr(addr), .data_from_cpu(data_from_cpu),
    .re(re), .we(we),

    .status_in(status),
    .hw_wr(hw_wr),

    .regs_out(regs),
    .cmd_valid(cmd_valid),
    .cmd_opcode(cmd_opcode),
    .unlock_key_we(unlock_key_we),
    .data_to_cpu(data_to_cpu)
  );

  aesctr #(
    .WIDTH(AES_W)
  ) u_aesctr (
    .clk(clk),
    .rst_n(rst_n),
    .go(aes_go),
    .load(aes_load),
    .counter1(aes_counter1),
    .plaintext(aes_plaintext),
    .key(aes_key),
    .ciphertext(aes_ciphertext),
    .ready(aes_ready)
  );

  prime #(
    .WIDTH(PRIME_W)
  ) u_prime (
    .clk(clk),
    .rst_n(rst_n),
    .go(prime_go),
    .number(prime_number),
    .isprime(isprime),
    .isnotprime(isnotprime)
  );

  always_comb begin
    status.word = '0;

    status.bits.busy_global        = ctrl.busy_global;
    status.bits.busy_aes           = ctrl.busy_aes;
    status.bits.busy_aes_ctr       = ctrl.busy_aes_ctr;
    status.bits.busy_puf           = ctrl.busy_puf;
    status.bits.busy_trng          = ctrl.busy_trng;
    status.bits.busy_prng          = ctrl.busy_prng;
    status.bits.busy_prime         = ctrl.busy_prime;

    status.bits.aes_key_incomplete = ctrl.aes_key_incomplete;
    status.bits.aes_key_correct    = ctrl.aes_key_correct;
    status.bits.aes_key_incorrect  = ctrl.aes_key_incorrect;

    status.bits.aes_out_valid      = ctrl.aes_out_valid;
    status.bits.puf_valid          = ctrl.puf_valid;
    status.bits.trng_valid         = ctrl.trng_valid;
    status.bits.prng_word_valid    = ctrl.prng_word_valid;
    status.bits.prng_running       = ctrl.prng_running;
    status.bits.prime_valid        = ctrl.prime_valid;

    status.bits.cmd_rejected       = ctrl.cmd_rejected;
    status.bits.fault_or_lockout   = ctrl.lockout;
  end

  always_comb begin
    state_next = state;
    ctrl_next  = ctrl;
    hw_wr      = '0;

    aes_go        = 1'b0;
    aes_load      = 1'b0;
    aes_counter1  = '0;
    aes_plaintext = '0;
    aes_key       = '0;

    prime_go      = 1'b0;
    prime_number  = regs.prime_in[PRIME_W-1:0];

    // default: clear one-cycle reject pulse
    ctrl_next.cmd_rejected = 1'b0;

    case (state)

      ST_LOCK_0: begin
        if (unlock_key_we) begin
          if (regs.unlock_key[31] && regs.unlock_key[8] && !regs.unlock_key[0]) begin
            state_next = ST_LOCK_1;
          end
          else begin
            state_next = ST_LOCK_TRAP;
          end
        end
      end

      ST_LOCK_1: begin
        if (unlock_key_we) begin
          if (!regs.unlock_key[26] && regs.unlock_key[21] && regs.unlock_key[3]) begin
            state_next = ST_LOCK_2;
          end
          else begin
            state_next = ST_LOCK_TRAP;
          end
        end
      end

      ST_LOCK_2: begin
        if (unlock_key_we) begin
          if (regs.unlock_key[24] && !regs.unlock_key[13] && regs.unlock_key[7]) begin
            state_next = ST_LOCK_3;
          end
          else begin
            state_next = ST_LOCK_TRAP;
          end
        end
      end

      ST_LOCK_3: begin
        if (unlock_key_we) begin
          // PSEUDOCODE: replace with real chosen subset check
          state_next = ST_LOCK_4;
        end
      end

      ST_LOCK_4: begin
        if (unlock_key_we) begin
          // PSEUDOCODE: replace with real chosen subset check
          state_next = ST_LOCK_5;
        end
      end

      ST_LOCK_5: begin
        if (unlock_key_we) begin
          // PSEUDOCODE: replace with real chosen subset check
          state_next = ST_LOCK_6;
        end
      end

      ST_LOCK_6: begin
        if (unlock_key_we) begin
          // PSEUDOCODE: replace with real chosen subset check
          state_next = ST_LOCK_7;
        end
      end

      ST_LOCK_7: begin
        if (unlock_key_we) begin
          // PSEUDOCODE: replace with final chosen subset check
          ctrl_next.unlocked = 1'b1;
          state_next = ST_IDLE;
        end
      end

      ST_LOCK_TRAP: begin
        ctrl_next.lockout = 1'b1;
        state_next = ST_LOCK_TRAP;
      end

      ST_IDLE: begin
        if (cmd_valid) begin
          if (!ctrl.unlocked || ctrl.lockout || ctrl.busy_global) begin
            ctrl_next.cmd_rejected = 1'b1;
          end
          else begin
            unique case (cmd_opcode)
              CMD_AES: begin
                ctrl_next.busy_global   = 1'b1;
                ctrl_next.busy_aes      = 1'b1;
                ctrl_next.aes_out_valid = 1'b0;
                state_next = ST_AES;
              end

              CMD_AES_CTR: begin
                ctrl_next.busy_global   = 1'b1;
                ctrl_next.busy_aes_ctr  = 1'b1;
                ctrl_next.aes_out_valid = 1'b0;
                state_next = ST_AES_CTR;
              end

              CMD_AES_PUF: begin
                ctrl_next.busy_global   = 1'b1;
                ctrl_next.busy_aes      = 1'b1;
                ctrl_next.aes_out_valid = 1'b0;
                state_next = ST_AES_PUF;
              end

              CMD_PUF_GEN: begin
                ctrl_next.busy_global = 1'b1;
                ctrl_next.busy_puf    = 1'b1;
                ctrl_next.puf_valid   = 1'b0;
                state_next = ST_PUF;
              end

              CMD_TRNG_GEN32: begin
                ctrl_next.busy_global = 1'b1;
                ctrl_next.busy_trng   = 1'b1;
                ctrl_next.trng_valid  = 1'b0;
                state_next = ST_TRNG32;
              end

              CMD_TRNG_GEN16: begin
                ctrl_next.busy_global = 1'b1;
                ctrl_next.busy_trng   = 1'b1;
                ctrl_next.trng_valid  = 1'b0;
                state_next = ST_TRNG16;
              end

              CMD_PRNG_SEED: begin
                state_next = ST_PRNG_SEED;
              end

              CMD_PRNG_START: begin
                ctrl_next.busy_global     = 1'b1;
                ctrl_next.busy_prng       = 1'b1;
                ctrl_next.prng_running    = 1'b1;
                ctrl_next.prng_word_valid = 1'b0;
                state_next = ST_PRNG_RUN;
              end

              CMD_PRNG_STOP: begin
                ctrl_next.cmd_rejected = 1'b1;
              end

              CMD_PRIME: begin
                ctrl_next.busy_global = 1'b1;
                ctrl_next.busy_prime  = 1'b1;
                ctrl_next.prime_valid = 1'b0;
                state_next = ST_PRIME;
              end

              default: begin
                ctrl_next.cmd_rejected = 1'b1;
              end
            endcase
          end
        end
      end

      ST_AES: begin
        // PSEUDOCODE:
        // aes_load      = 1'b1 / maybe only once after header update
        // aes_go        = 1'b1;
        // aes_key       = regs.aes_key;
        // aes_plaintext = regs.aes_in;
        if (aes_ready) begin
          hw_wr.en.aes_out = 1'b1;
          hw_wr.aes_out    = aes_ciphertext;

          ctrl_next.busy_global   = 1'b0;
          ctrl_next.busy_aes      = 1'b0;
          ctrl_next.aes_out_valid = 1'b1;
          state_next = ST_IDLE;
        end
      end

      ST_AES_CTR: begin
        // PSEUDOCODE:
        // use shared LFSR output as counter input after lfsr header/body update
        if (aes_ready) begin
          hw_wr.en.aes_out = 1'b1;
          hw_wr.aes_out    = aes_ciphertext;

          ctrl_next.busy_global   = 1'b0;
          ctrl_next.busy_aes_ctr  = 1'b0;
          ctrl_next.aes_out_valid = 1'b1;
          state_next = ST_IDLE;
        end
      end

      ST_AES_PUF: begin
        // PSEUDOCODE:
        // choose next 30-bit chunk from regs.puf_sig
        // pad to 128 bits
        // run AES
        if (aes_ready) begin
          // PSEUDOCODE:
          // write one of hw_wr.puf_enc[x]
          ctrl_next.busy_global   = 1'b0;
          ctrl_next.busy_aes      = 1'b0;
          ctrl_next.aes_out_valid = 1'b1;
          state_next = ST_IDLE;
        end
      end

      ST_PUF: begin
        // PSEUDOCODE:
        // wait for future project-level PUF block done
      end

      ST_TRNG32: begin
        // PSEUDOCODE:
        // wait for future project-level TRNG block done
      end

      ST_TRNG16: begin
        // PSEUDOCODE:
        // wait for future project-level TRNG block done
      end

      ST_PRNG_SEED: begin
        // PSEUDOCODE:
        // hw_wr.en.lfsr_seed = 1'b1;
        // hw_wr.lfsr_seed    = seed source
        state_next = ST_IDLE;
      end

      ST_PRNG_RUN: begin
        // PSEUDOCODE:
        // continuously pulse shared LFSR and pack PRNG words
        // if CMD_PRNG_STOP arrives, stop and return to IDLE
        if (cmd_valid && (cmd_opcode == CMD_PRNG_STOP)) begin
          ctrl_next.busy_global  = 1'b0;
          ctrl_next.busy_prng    = 1'b0;
          ctrl_next.prng_running = 1'b0;
          state_next = ST_IDLE;
        end
      end

      ST_PRIME: begin
        // PSEUDOCODE:
        // prime_go = 1'b1;
        // wait for future done signal after header/body update
        // currently header has no done
      end

      default: begin
        state_next = ST_LOCK_TRAP;
      end

    endcase
  end

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_LOCK_0;
      ctrl  <= '0;
    end
    else begin
      state <= state_next;
      ctrl  <= ctrl_next;
    end
  end

endmodule

`default_nettype wire
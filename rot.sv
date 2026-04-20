`timescale 1ns/1ps
`default_nettype none
`include "rot_pkg.sv"
import rot_pkg::*;

module rot (
  input  logic            clk, rst_n,
  input  logic [BUSW-1:0] addr, data_from_cpu,
  output logic [BUSW-1:0] data_to_cpu,
  input  logic            re, we
);

  localparam int RO_NUM_LOCAL          = 16;
  localparam int RO_COUNTER_SIZE_LOCAL = 10;
  localparam int PRNG_BYTE_W           = 8;
  localparam int PRNG_WORD_BYTES       = BUSW / PRNG_BYTE_W;

  typedef enum logic [4:0] {
    ST_LOCK_0,
    ST_LOCK_1,
    ST_LOCK_2,
    ST_LOCK_3,
    ST_LOCK_4,
    ST_LOCK_5,
    ST_LOCK_6,
    ST_LOCK_7,
    ST_LOCK_TRAP,

    ST_IDLE,

    ST_AES_START,
    ST_AES_WAIT,

    ST_AES_CTR_START,
    ST_AES_CTR_WAIT,

    ST_AES_PUF_START,
    ST_AES_PUF_WAIT,

    ST_PUF_START,
    ST_PUF_WAIT,

    ST_TRNG32_START,
    ST_TRNG32_WAIT,

    ST_TRNG16_START,
    ST_TRNG16_WAIT,

    ST_PRNG_SEED,
    ST_PRNG_RUN,

    ST_PRIME_START,
    ST_PRIME_WAIT
  } rot_state_t;

  rot_state_t state, state_next;

  rot_regs_t   regs;
  rot_ctrl_t   ctrl, ctrl_next;
  status_reg_t status;
  rot_hw_wr_t  hw_wr;

  logic cmd_valid, unlock_start;
  cmd_t cmd_opcode;

  logic             aes_go, aes_done;
  logic [AES_W-1:0] aes_block_in, aes_key, aes_block_out;

  logic             prime_go, isprime, prime_done;
  logic [PRIME_W-1:0] prime_number;

  logic             lfsr_load, lfsr_pulse;
  logic [LFSR_W-1:0] lfsr_load_value, lfsr_seq;
  logic [AES_W-1:0]  ctr_block;

  logic [BUSW-1:0] prng_assembly, prng_assembly_next;
  logic [1:0]      prng_byte_count, prng_byte_count_next;

  logic                                 ro_enable_bank;
  logic                                 puf_gen, pufready, puf_ro_enable;
  logic [PUF_W-1:0]                     puf_sig;
  logic [RO_NUM_LOCAL-1:0][RO_COUNTER_SIZE_LOCAL-1:0] ro_count;

  logic                                 trng_gen32, trng_gen16, trngready, trng_ro_enable;
  logic [TRNG_W-1:0]                    trng_word;
  logic [RO_NUM_LOCAL-1:0]              ro_feedback;

  assign unlock_start = cmd_valid && (cmd_opcode == CMD_UNLOCK);
  assign ctr_block    = {{(AES_W-LFSR_W){1'b0}}, lfsr_seq};
  assign ro_enable_bank = puf_ro_enable | trng_ro_enable;

  rot_csr u_rot_csr (
    .clk(clk), .rst_n(rst_n),
    .addr(addr), .data_from_cpu(data_from_cpu),
    .re(re), .we(we),
    .status_in(status),
    .hw_wr(hw_wr),
    .regs_out(regs),
    .cmd_valid(cmd_valid),
    .cmd_opcode(cmd_opcode),
    .data_to_cpu(data_to_cpu)
  );

  // ------------------------------------------------------------
  // Shared engines / feature submodules
  // ------------------------------------------------------------
  aesctr #(
    .WIDTH(AES_W)
  ) u_aesctr (
    .clk(clk),
    .rst_n(rst_n),
    .go(aes_go),
    .block_in(aes_block_in),
    .key(aes_key),
    .block_out(aes_block_out),
    .done(aes_done)
  );

  prime #(
    .WIDTH(PRIME_W)
  ) u_prime (
    .clk(clk),
    .rst_n(rst_n),
    .go(prime_go),
    .number(prime_number),
    .isprime(isprime),
    .done(prime_done)
  );

  lfsr_load #(
    .WIDTH(LFSR_W)
  ) u_lfsr (
    .clk(clk),
    .rst_n(rst_n),
    .load(lfsr_load),
    .pulse(lfsr_pulse),
    .load_value(lfsr_load_value),
    .seq(lfsr_seq)
  );

  ro_bank #(
    .COUNTER_SIZE(RO_COUNTER_SIZE_LOCAL),
    .RO_NUM(RO_NUM_LOCAL)
  ) u_ro_bank (
    .enable(ro_enable_bank),
    .feedback(ro_feedback),
    .count(ro_count)
  );

  puf #(
    .COUNTER_SIZE(RO_COUNTER_SIZE_LOCAL),
    .RO_NUM(RO_NUM_LOCAL),
    .PUF_W(PUF_W)
  ) u_puf (
    .clk(clk),
    .rst_n(rst_n),
    .gen(puf_gen),
    .ro_count(ro_count),
    .ro_enable(puf_ro_enable),
    .puf_sig(puf_sig),
    .pufready(pufready)
  );

  trng #(
    .RO_NUM(RO_NUM_LOCAL),
    .WORD_W(TRNG_W)
  ) u_trng (
    .clk(clk),
    .rst_n(rst_n),
    .gen32(trng_gen32),
    .gen16(trng_gen16),
    .ro_feedback(ro_feedback),
    .ro_enable(trng_ro_enable),
    .trng_word(trng_word),
    .trngready(trngready)
  );

  // ------------------------------------------------------------
  // STATUS composition
  // ------------------------------------------------------------
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

  // ------------------------------------------------------------
  // Top-level control FSM and datapath steering
  // ------------------------------------------------------------
  always_comb begin
    state_next = state;
    ctrl_next  = ctrl;
    hw_wr      = '0;

    prng_assembly_next   = prng_assembly;
    prng_byte_count_next = prng_byte_count;

    aes_go       = 1'b0;
    aes_block_in = '0;
    aes_key      = '0;

    prime_go     = 1'b0;
    prime_number = regs.prime_in[PRIME_W-1:0];

    lfsr_load       = 1'b0;
    lfsr_pulse      = 1'b0;
    lfsr_load_value = '0;

    puf_gen         = 1'b0;
    trng_gen32      = 1'b0;
    trng_gen16      = 1'b0;

    ctrl_next.cmd_rejected = 1'b0;

    ctrl_next.busy_global  = 1'b0;
    ctrl_next.busy_aes     = 1'b0;
    ctrl_next.busy_aes_ctr = 1'b0;
    ctrl_next.busy_puf     = 1'b0;
    ctrl_next.busy_trng    = 1'b0;
    ctrl_next.busy_prng    = 1'b0;
    ctrl_next.busy_prime   = 1'b0;

    case (state)

      // --------------------------------------------------------
      // Unlock / obfuscation region
      // --------------------------------------------------------
      ST_LOCK_0: begin
        if (cmd_valid && !unlock_start)
          ctrl_next.cmd_rejected = 1'b1;

        if (unlock_start) begin
          ctrl_next.busy_global = 1'b1;

          if ( regs.unlock_key[31] &&
               regs.unlock_key[28] &&
              !regs.unlock_key[24] &&
               regs.unlock_key[20]) begin
            state_next = ST_LOCK_1;
          end else begin
            state_next = ST_LOCK_TRAP;
          end
        end
      end

      ST_LOCK_1: begin
        ctrl_next.busy_global = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if (!regs.unlock_key[30] &&
            !regs.unlock_key[27] &&
            !regs.unlock_key[23] &&
             regs.unlock_key[19]) begin
          state_next = ST_LOCK_2;
        end else begin
          state_next = ST_LOCK_TRAP;
        end
      end

      ST_LOCK_2: begin
        ctrl_next.busy_global = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if ( regs.unlock_key[29] &&
            !regs.unlock_key[26] &&
             regs.unlock_key[22] &&
             regs.unlock_key[18]) begin
          state_next = ST_LOCK_3;
        end else begin
          state_next = ST_LOCK_TRAP;
        end
      end

      ST_LOCK_3: begin
        ctrl_next.busy_global = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if ( regs.unlock_key[25] &&
             regs.unlock_key[21] &&
            !regs.unlock_key[17] &&
            !regs.unlock_key[13]) begin
          state_next = ST_LOCK_4;
        end else begin
          state_next = ST_LOCK_TRAP;
        end
      end

      ST_LOCK_4: begin
        ctrl_next.busy_global = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if ( regs.unlock_key[16] &&
             regs.unlock_key[12] &&
             regs.unlock_key[8]  &&
             regs.unlock_key[4]) begin
          state_next = ST_LOCK_5;
        end else begin
          state_next = ST_LOCK_TRAP;
        end
      end

      ST_LOCK_5: begin
        ctrl_next.busy_global = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if (!regs.unlock_key[15] &&
            !regs.unlock_key[11] &&
            !regs.unlock_key[7]  &&
             regs.unlock_key[3]) begin
          state_next = ST_LOCK_6;
        end else begin
          state_next = ST_LOCK_TRAP;
        end
      end

      ST_LOCK_6: begin
        ctrl_next.busy_global = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if ( regs.unlock_key[14] &&
             regs.unlock_key[10] &&
            !regs.unlock_key[6]  &&
            !regs.unlock_key[2]) begin
          state_next = ST_LOCK_7;
        end else begin
          state_next = ST_LOCK_TRAP;
        end
      end

      ST_LOCK_7: begin
        ctrl_next.busy_global = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if (!regs.unlock_key[9] &&
             regs.unlock_key[5] &&
             regs.unlock_key[1] &&
            !regs.unlock_key[0]) begin
          ctrl_next.unlocked    = 1'b1;
          ctrl_next.busy_global = 1'b0;
          state_next = ST_IDLE;
        end else begin
          state_next = ST_LOCK_TRAP;
        end
      end

      ST_LOCK_TRAP: begin
        ctrl_next.lockout     = 1'b1;
        ctrl_next.busy_global = 1'b0;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;
        state_next = ST_LOCK_TRAP;
      end

      // --------------------------------------------------------
      // Idle / command dispatch
      // --------------------------------------------------------
      ST_IDLE: begin
        if (cmd_valid) begin
          unique case (cmd_opcode)
            CMD_UNLOCK: begin
            end

            CMD_AES: begin
              ctrl_next.aes_out_valid = 1'b0;
              state_next = ST_AES_START;
            end

            CMD_AES_CTR: begin
              ctrl_next.aes_out_valid = 1'b0;
              state_next = ST_AES_CTR_START;
            end

            CMD_AES_PUF: begin
              ctrl_next.aes_out_valid = 1'b0;
              state_next = ST_AES_PUF_START;
            end

            CMD_PUF_GEN: begin
              ctrl_next.puf_valid = 1'b0;
              state_next = ST_PUF_START;
            end

            CMD_TRNG_GEN32: begin
              ctrl_next.trng_valid = 1'b0;
              state_next = ST_TRNG32_START;
            end

            CMD_TRNG_GEN16: begin
              ctrl_next.trng_valid = 1'b0;
              state_next = ST_TRNG16_START;
            end

            CMD_PRNG_SEED: begin
              state_next = ST_PRNG_SEED;
            end

            CMD_PRNG_START: begin
              ctrl_next.prng_word_valid = 1'b0;
              prng_assembly_next        = '0;
              prng_byte_count_next      = '0;
              state_next                = ST_PRNG_RUN;
            end

            CMD_PRNG_STOP: begin
            end

            CMD_PRIME: begin
              ctrl_next.prime_valid = 1'b0;
              state_next = ST_PRIME_START;
            end

            default: begin
              ctrl_next.cmd_rejected = 1'b1;
            end
          endcase
        end
      end

      // --------------------------------------------------------
      // AES-related one-shot launch-and-wait states
      // --------------------------------------------------------
      ST_AES_START: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_aes    = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        aes_go       = 1'b1;
        aes_block_in = regs.aes_in;
        aes_key      = regs.aes_key;

        state_next = ST_AES_WAIT;
      end

      ST_AES_WAIT: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_aes    = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        aes_block_in = regs.aes_in;
        aes_key      = regs.aes_key;

        if (aes_done) begin
          hw_wr.en.aes_out = 1'b1;
          hw_wr.aes_out    = aes_block_out;

          ctrl_next.aes_out_valid = 1'b1;
          state_next = ST_IDLE;
        end
      end

      ST_AES_CTR_START: begin
        ctrl_next.busy_global  = 1'b1;
        ctrl_next.busy_aes_ctr = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        aes_go       = 1'b1;
        aes_block_in = ctr_block;
        aes_key      = regs.aes_key;

        state_next = ST_AES_CTR_WAIT;
      end

      ST_AES_CTR_WAIT: begin
        ctrl_next.busy_global  = 1'b1;
        ctrl_next.busy_aes_ctr = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        aes_block_in = ctr_block;
        aes_key      = regs.aes_key;

        if (aes_done) begin
          hw_wr.en.aes_out = 1'b1;
          hw_wr.aes_out    = aes_block_out ^ regs.aes_in;

          lfsr_pulse = 1'b1;

          ctrl_next.aes_out_valid = 1'b1;
          state_next = ST_IDLE;
        end
      end

      ST_AES_PUF_START: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_aes    = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        aes_go       = 1'b1;
        aes_block_in = '0;
        aes_key      = regs.aes_key;

        state_next = ST_AES_PUF_WAIT;
      end

      ST_AES_PUF_WAIT: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_aes    = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        aes_block_in = '0;
        aes_key      = regs.aes_key;

        if (aes_done) begin
          ctrl_next.aes_out_valid = 1'b1;
          state_next = ST_IDLE;
        end
      end

      // --------------------------------------------------------
      // PUF / TRNG one-shot launch-and-wait states
      // --------------------------------------------------------
      ST_PUF_START: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_puf    = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        puf_gen = 1'b1;

        state_next = ST_PUF_WAIT;
      end

      ST_PUF_WAIT: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_puf    = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if (pufready) begin
          hw_wr.en.puf_sig = 1'b1;
          hw_wr.puf_sig    = puf_sig;

          ctrl_next.puf_valid = 1'b1;
          state_next = ST_IDLE;
        end
      end

      ST_TRNG32_START: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_trng   = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        trng_gen32 = 1'b1;

        state_next = ST_TRNG32_WAIT;
      end

      ST_TRNG32_WAIT: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_trng   = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if (trngready) begin
          hw_wr.en.trng_word = 1'b1;
          hw_wr.trng_word    = trng_word;

          ctrl_next.trng_valid = 1'b1;
          state_next = ST_IDLE;
        end
      end

      ST_TRNG16_START: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_trng   = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        trng_gen16 = 1'b1;

        state_next = ST_TRNG16_WAIT;
      end

      ST_TRNG16_WAIT: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_trng   = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if (trngready) begin
          hw_wr.en.trng_word = 1'b1;
          hw_wr.trng_word    = trng_word;

          ctrl_next.trng_valid = 1'b1;
          state_next = ST_IDLE;
        end
      end

      // --------------------------------------------------------
      // PRNG control states
      // --------------------------------------------------------
      ST_PRNG_SEED: begin
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        lfsr_load       = 1'b1;
        lfsr_load_value = regs.trng_word[LFSR_W-1:0];

        hw_wr.en.lfsr_seed = 1'b1;
        hw_wr.lfsr_seed    = {{(BUSW-LFSR_W){1'b0}}, regs.trng_word[LFSR_W-1:0]};

        state_next = ST_IDLE;
      end

      ST_PRNG_RUN: begin
        ctrl_next.busy_global  = 1'b1;
        ctrl_next.busy_prng    = 1'b1;
        ctrl_next.prng_running = 1'b1;

        if (cmd_valid && (cmd_opcode != CMD_PRNG_STOP))
          ctrl_next.cmd_rejected = 1'b1;

        lfsr_pulse = 1'b1;
        prng_assembly_next = {prng_assembly[BUSW-PRNG_BYTE_W-1:0], lfsr_seq[PRNG_BYTE_W-1:0]};

        if (prng_byte_count == PRNG_WORD_BYTES-1) begin
          hw_wr.en.prng_word = 1'b1;
          hw_wr.prng_word    = {prng_assembly[BUSW-PRNG_BYTE_W-1:0], lfsr_seq[PRNG_BYTE_W-1:0]};

          ctrl_next.prng_word_valid = 1'b1;
          prng_assembly_next        = '0;
          prng_byte_count_next      = '0;
        end else begin
          prng_byte_count_next = prng_byte_count + 2'd1;
        end

        if (cmd_valid && (cmd_opcode == CMD_PRNG_STOP)) begin
          ctrl_next.prng_running = 1'b0;
          state_next             = ST_IDLE;
        end
      end

      // --------------------------------------------------------
      // Prime checker one-shot launch-and-wait states
      // --------------------------------------------------------
      ST_PRIME_START: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_prime  = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        prime_go = 1'b1;

        state_next = ST_PRIME_WAIT;
      end

      ST_PRIME_WAIT: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_prime  = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        if (prime_done) begin
          hw_wr.en.prime_out = 1'b1;
          hw_wr.prime_out    = {{(BUSW-1){1'b0}}, isprime};

          ctrl_next.prime_valid = 1'b1;
          state_next = ST_IDLE;
        end
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

      prng_assembly   <= '0;
      prng_byte_count <= '0;
    end else begin
      state <= state_next;
      ctrl  <= ctrl_next;

      prng_assembly   <= prng_assembly_next;
      prng_byte_count <= prng_byte_count_next;
    end
  end

endmodule

`default_nettype wire
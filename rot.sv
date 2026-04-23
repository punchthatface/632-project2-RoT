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
  localparam int PUF_CHUNK_W           = 30;
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

    ST_PUF_RESET,
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

  logic               prime_go, isprime, prime_done;
  logic [PRIME_W-1:0] prime_number;

  logic              lfsr_load, lfsr_pulse, lfsr_mode_prng;
  logic [LFSR_W-1:0] lfsr_load_value, lfsr_seq;
  logic [PRNG_BYTE_W-1:0] lfsr_byte_out;
  logic [AES_W-1:0]  ctr_block;

  logic [BUSW-1:0] prng_assembly, prng_assembly_next;
  logic [1:0]      prng_byte_count, prng_byte_count_next;
  logic [2:0]      puf_chunk_index, puf_chunk_index_next;
  logic [2:0]      aes_key_track_step, aes_key_track_step_next;
  logic            aes_key_track_active, aes_key_track_active_next;
  logic            aes_key_write;
  logic [1:0]      aes_key_word_sel;

  logic                                 ro_enable_bank;
  logic                                 ro_force_disable;
  logic                                 puf_gen, pufready, puf_ro_enable;
  logic [PUF_W-1:0]                     puf_sig;
  logic [RO_NUM_LOCAL-1:0][RO_COUNTER_SIZE_LOCAL-1:0] ro_count;

  logic                                 trng_gen32, trng_gen16, trngready, trng_ro_enable;
  logic [TRNG_W-1:0]                    trng_word;
  logic [RO_NUM_LOCAL-1:0]              ro_feedback;

  // UC1 exports the 120-bit PUF as four AES-encrypted 30-bit chunks.
  function automatic logic [PUF_CHUNK_W-1:0] puf_chunk(
    input logic [PUF_W-1:0] sig,
    input logic [1:0]       idx
  );
    begin
      unique case (idx)
        2'd0:    puf_chunk = sig[29:0];
        2'd1:    puf_chunk = sig[59:30];
        2'd2:    puf_chunk = sig[89:60];
        default: puf_chunk = sig[119:90];
      endcase
    end
  endfunction

  function automatic logic [AES_W-1:0] puf_chunk_block(
    input logic [PUF_W-1:0] sig,
    input logic [1:0]       idx
  );
    begin
      puf_chunk_block = {{(AES_W-PUF_CHUNK_W){1'b0}}, puf_chunk(sig, idx)};
    end
  endfunction

  assign unlock_start = cmd_valid && (cmd_opcode == CMD_UNLOCK);
  assign ctr_block    = {{(AES_W-LFSR_W){1'b0}}, lfsr_seq};
  // PUF and TRNG share the same RO bank. ro_force_disable gives the PUF
  // flow one cycle of guaranteed reset before it begins counting again.
  assign ro_enable_bank = (puf_ro_enable | trng_ro_enable) & !ro_force_disable;
  assign aes_key_write =
      we &&
      ((addr == ADDR_AES_KEY0) || (addr == ADDR_AES_KEY1) ||
       (addr == ADDR_AES_KEY2) || (addr == ADDR_AES_KEY3));

  always_comb begin
    unique case (addr)
      ADDR_AES_KEY0: aes_key_word_sel = 2'd0;
      ADDR_AES_KEY1: aes_key_word_sel = 2'd1;
      ADDR_AES_KEY2: aes_key_word_sel = 2'd2;
      default:       aes_key_word_sel = 2'd3;
    endcase
  end

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
    .mode_prng(lfsr_mode_prng),
    .load_value(lfsr_load_value),
    .seq(lfsr_seq),
    .byte_out(lfsr_byte_out)
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
    .force_disable(ro_force_disable),
    .ro_feedback(ro_feedback),
    .ro_enable(trng_ro_enable),
    .trng_word(trng_word),
    .trngready(trngready)
  );

  // ------------------------------------------------------------
  // STATUS composition
  // Keep all user-visible status semantics in one place so the CSR block
  // stays a thin register file and rot.sv remains the control authority.
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
    puf_chunk_index_next = puf_chunk_index;
    aes_key_track_step_next   = aes_key_track_step;
    aes_key_track_active_next = aes_key_track_active;

    aes_go       = 1'b0;
    aes_block_in = '0;
    aes_key      = '0;

    prime_go     = 1'b0;
    prime_number = regs.prime_in[PRIME_W-1:0];

    lfsr_load       = 1'b0;
    lfsr_pulse      = 1'b0;
    lfsr_mode_prng  = 1'b0;
    lfsr_load_value = '0;

    puf_gen         = 1'b0;
    trng_gen32      = 1'b0;
    trng_gen16      = 1'b0;
    ro_force_disable = 1'b0;

    ctrl_next.cmd_rejected = 1'b0;

    ctrl_next.busy_global  = 1'b0;
    ctrl_next.busy_aes     = 1'b0;
    ctrl_next.busy_aes_ctr = 1'b0;
    ctrl_next.busy_puf     = 1'b0;
    ctrl_next.busy_trng    = 1'b0;
    ctrl_next.busy_prng    = 1'b0;
    ctrl_next.busy_prime   = 1'b0;

    // AES KEY CHECK LOGIC
    if (aes_key_track_active) begin
      // check if the command is aes key write, and if the number is correct
      if (aes_key_write && (aes_key_word_sel == aes_key_track_step[1:0])) begin
        // last key, so stop
        if (aes_key_track_step == 3'd3) begin
          aes_key_track_active_next   = 1'b0;
          aes_key_track_step_next     = '0;
          ctrl_next.aes_key_incomplete = 1'b0;
          ctrl_next.aes_key_correct    = 1'b1;
          ctrl_next.aes_key_incorrect  = 1'b0;
        // not last key, so keep going
        end else begin
          aes_key_track_step_next      = aes_key_track_step + 3'd1;
          ctrl_next.aes_key_incomplete = 1'b1;
          ctrl_next.aes_key_correct    = 1'b0;
          ctrl_next.aes_key_incorrect  = 1'b0;
        end
      // After KEY0, the next three writes must be KEY1/KEY2/KEY3 on the
      // next consecutive cycles. Anything else ends the sequence as wrong.
      end else begin
        aes_key_track_active_next    = 1'b0;
        aes_key_track_step_next      = '0;
        ctrl_next.aes_key_incomplete = 1'b0;
        ctrl_next.aes_key_correct    = 1'b0;
        ctrl_next.aes_key_incorrect  = 1'b1;
      end
    // Not currently tracking, so check if we should start tracking
    end else if (aes_key_write) begin
      if (aes_key_word_sel == 2'd0) begin
        aes_key_track_active_next    = 1'b1;
        aes_key_track_step_next      = 3'd1;
        ctrl_next.aes_key_incomplete = 1'b1;
        ctrl_next.aes_key_correct    = 1'b0;
        ctrl_next.aes_key_incorrect  = 1'b0;
      // Starting anywhere other than KEY0 is an immediate failure.
      end else begin
        ctrl_next.aes_key_incomplete = 1'b0;
        ctrl_next.aes_key_correct    = 1'b0;
        ctrl_next.aes_key_incorrect  = 1'b1;
      end
    end

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
          // IDLE is the single command-arbitration point because all active
          // operations use the global busy model from the handout.
          unique case (cmd_opcode)
            CMD_UNLOCK: begin
            end

            CMD_AES: begin
              // CMD_AES reuses the shared AES engine for either normal AES
              // or the next padded PUF chunk, depending on AES_SRC bit 0.
              if (!ctrl.aes_key_correct) begin
                ctrl_next.cmd_rejected = 1'b1;
              end else if (regs.aes_src_sel[0]) begin
                if (!ctrl.puf_valid || (puf_chunk_index >= 3'd4)) begin
                  ctrl_next.cmd_rejected = 1'b1;
                end else begin
                  ctrl_next.aes_out_valid = 1'b0;
                  state_next = ST_AES_PUF_START;
                end
              end else begin
                ctrl_next.aes_out_valid = 1'b0;
                state_next = ST_AES_START;
              end
            end

            CMD_AES_CTR: begin
              if (!ctrl.aes_key_correct) begin
                ctrl_next.cmd_rejected = 1'b1;
              end else begin
                ctrl_next.aes_out_valid = 1'b0;
                state_next = ST_AES_CTR_START;
              end
            end

            CMD_AES_PUF: begin
              if (!ctrl.aes_key_correct || !ctrl.puf_valid || (puf_chunk_index >= 3'd4)) begin
                ctrl_next.cmd_rejected = 1'b1;
              end else begin
                ctrl_next.aes_out_valid = 1'b0;
                state_next = ST_AES_PUF_START;
              end
            end

            CMD_PUF_GEN: begin
              ctrl_next.puf_valid = 1'b0;
              state_next = ST_PUF_RESET;
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
              if (!ctrl.trng_valid) begin
                ctrl_next.cmd_rejected = 1'b1;
              end else begin
                ctrl_next.prng_word_valid = 1'b0;
                state_next = ST_PRNG_SEED;
              end
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
          // AES-CTR uses AES(counter) as keystream and XORs it with the
          // CPU-supplied AES input block at the top level.
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
        aes_block_in = puf_chunk_block(regs.puf_sig, puf_chunk_index[1:0]);
        aes_key      = regs.aes_key;

        state_next = ST_AES_PUF_WAIT;
      end

      ST_AES_PUF_WAIT: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_aes    = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        aes_block_in = puf_chunk_block(regs.puf_sig, puf_chunk_index[1:0]);
        aes_key      = regs.aes_key;

        if (aes_done) begin
          hw_wr.en.aes_out = 1'b1;
          hw_wr.aes_out    = aes_block_out;

          // Save each encrypted PUF block in its dedicated UC1 register
          // bank while also mirroring the most recent block into AES_OUT.
          unique case (puf_chunk_index[1:0])
            2'd0: begin
              hw_wr.en.puf_enc[0] = 1'b1;
              hw_wr.puf_enc[0]    = aes_block_out;
            end
            2'd1: begin
              hw_wr.en.puf_enc[1] = 1'b1;
              hw_wr.puf_enc[1]    = aes_block_out;
            end
            2'd2: begin
              hw_wr.en.puf_enc[2] = 1'b1;
              hw_wr.puf_enc[2]    = aes_block_out;
            end
            default: begin
              hw_wr.en.puf_enc[3] = 1'b1;
              hw_wr.puf_enc[3]    = aes_block_out;
            end
          endcase

          ctrl_next.aes_out_valid = 1'b1;
          puf_chunk_index_next    = puf_chunk_index + 3'd1;
          state_next = ST_IDLE;
        end
      end

      // --------------------------------------------------------
      // PUF / TRNG one-shot launch-and-wait states
      // --------------------------------------------------------
      ST_PUF_RESET: begin
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_puf    = 1'b1;
        // Clear any inherited TRNG oscillation phase before starting the
        // PUF measurement so both RO-bank clients can share one instance.
        ro_force_disable      = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        state_next = ST_PUF_START;
      end

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

          ctrl_next.puf_valid  = 1'b1;
          puf_chunk_index_next = '0;
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
        ctrl_next.busy_global = 1'b1;
        ctrl_next.busy_prng   = 1'b1;
        if (cmd_valid)
          ctrl_next.cmd_rejected = 1'b1;

        // UC3 seeds the shared LFSR from the low 16 bits of the most recent
        // TRNG word and mirrors that seed into the CPU-visible seed register.
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

        lfsr_mode_prng  = 1'b1;
        lfsr_pulse      = 1'b1;
        // One PRNG controller cycle produces one fresh byte, so four cycles
        // are assembled into the 32-bit word exposed through ADDR_PRNG_WORD.
        prng_assembly_next = {prng_assembly[BUSW-PRNG_BYTE_W-1:0], lfsr_byte_out};

        if (prng_byte_count == PRNG_WORD_BYTES-1) begin
          hw_wr.en.prng_word = 1'b1;
          hw_wr.prng_word    = {prng_assembly[BUSW-PRNG_BYTE_W-1:0], lfsr_byte_out};

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

      prng_assembly        <= '0;
      prng_byte_count      <= '0;
      puf_chunk_index      <= '0;
      aes_key_track_step   <= '0;
      aes_key_track_active <= 1'b0;
    end else begin
      state <= state_next;
      ctrl  <= ctrl_next;

      prng_assembly        <= prng_assembly_next;
      prng_byte_count      <= prng_byte_count_next;
      puf_chunk_index      <= puf_chunk_index_next;
      aes_key_track_step   <= aes_key_track_step_next;
      aes_key_track_active <= aes_key_track_active_next;
    end
  end

endmodule

`default_nettype wire

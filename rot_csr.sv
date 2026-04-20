`default_nettype none
`include "rot_pkg.sv"
import rot_pkg::*;

module rot_csr (
  input  logic             clk, rst_n,
  input  logic [BUSW-1:0]  addr, data_from_cpu,
  input  logic             re, we,

  input  status_reg_t      status_in,
  input  rot_hw_wr_t       hw_wr,

  output rot_regs_t        regs_out,
  output logic             cmd_valid,
  output cmd_t             cmd_opcode,
  output logic             unlock_key_we,
  output logic [BUSW-1:0]  data_to_cpu
);

  rot_regs_t regs_reg;
  assign regs_out = regs_reg;

  always_comb begin
    cmd_valid      = 1'b0;
    cmd_opcode     = CMD_NOP;
    unlock_key_we  = 1'b0;

    if (we && (addr == ADDR_CMD)) begin
      cmd_valid  = 1'b1;
      cmd_opcode = cmd_t'(data_from_cpu[CMD_W-1:0]);
    end

    if (we && (addr == ADDR_UNLOCK_KEY)) begin
      unlock_key_we = 1'b1;
    end
  end

  always_comb begin
    data_to_cpu = '0;

    if (re) begin
      unique case (addr)
        ADDR_STATUS:     data_to_cpu = status_in.word;
        ADDR_CMD:        data_to_cpu = '0;
        ADDR_UNLOCK_KEY: data_to_cpu = regs_reg.unlock_key;

        ADDR_AES_KEY0:   data_to_cpu = regs_reg.aes_key[127:96];
        ADDR_AES_KEY1:   data_to_cpu = regs_reg.aes_key[95:64];
        ADDR_AES_KEY2:   data_to_cpu = regs_reg.aes_key[63:32];
        ADDR_AES_KEY3:   data_to_cpu = regs_reg.aes_key[31:0];

        ADDR_AES_IN0:    data_to_cpu = regs_reg.aes_in[127:96];
        ADDR_AES_IN1:    data_to_cpu = regs_reg.aes_in[95:64];
        ADDR_AES_IN2:    data_to_cpu = regs_reg.aes_in[63:32];
        ADDR_AES_IN3:    data_to_cpu = regs_reg.aes_in[31:0];

        ADDR_AES_OUT0:   data_to_cpu = regs_reg.aes_out[127:96];
        ADDR_AES_OUT1:   data_to_cpu = regs_reg.aes_out[95:64];
        ADDR_AES_OUT2:   data_to_cpu = regs_reg.aes_out[63:32];
        ADDR_AES_OUT3:   data_to_cpu = regs_reg.aes_out[31:0];

        ADDR_PUF_SIG0:   data_to_cpu = regs_reg.puf_sig[31:0];
        ADDR_PUF_SIG1:   data_to_cpu = regs_reg.puf_sig[63:32];
        ADDR_PUF_SIG2:   data_to_cpu = regs_reg.puf_sig[95:64];
        ADDR_PUF_SIG3:   data_to_cpu = {8'b0, regs_reg.puf_sig[119:96]};

        ADDR_PUF_ENC0_0: data_to_cpu = regs_reg.puf_enc[0][127:96];
        ADDR_PUF_ENC0_1: data_to_cpu = regs_reg.puf_enc[0][95:64];
        ADDR_PUF_ENC0_2: data_to_cpu = regs_reg.puf_enc[0][63:32];
        ADDR_PUF_ENC0_3: data_to_cpu = regs_reg.puf_enc[0][31:0];

        ADDR_PUF_ENC1_0: data_to_cpu = regs_reg.puf_enc[1][127:96];
        ADDR_PUF_ENC1_1: data_to_cpu = regs_reg.puf_enc[1][95:64];
        ADDR_PUF_ENC1_2: data_to_cpu = regs_reg.puf_enc[1][63:32];
        ADDR_PUF_ENC1_3: data_to_cpu = regs_reg.puf_enc[1][31:0];

        ADDR_PUF_ENC2_0: data_to_cpu = regs_reg.puf_enc[2][127:96];
        ADDR_PUF_ENC2_1: data_to_cpu = regs_reg.puf_enc[2][95:64];
        ADDR_PUF_ENC2_2: data_to_cpu = regs_reg.puf_enc[2][63:32];
        ADDR_PUF_ENC2_3: data_to_cpu = regs_reg.puf_enc[2][31:0];

        ADDR_PUF_ENC3_0: data_to_cpu = regs_reg.puf_enc[3][127:96];
        ADDR_PUF_ENC3_1: data_to_cpu = regs_reg.puf_enc[3][95:64];
        ADDR_PUF_ENC3_2: data_to_cpu = regs_reg.puf_enc[3][63:32];
        ADDR_PUF_ENC3_3: data_to_cpu = regs_reg.puf_enc[3][31:0];

        ADDR_TRNG_WORD:  data_to_cpu = regs_reg.trng_word;
        ADDR_PRNG_WORD:  data_to_cpu = regs_reg.prng_word;
        ADDR_LFSR_SEED:  data_to_cpu = regs_reg.lfsr_seed;
        ADDR_PRIME_IN:   data_to_cpu = regs_reg.prime_in;
        ADDR_PRIME_OUT:  data_to_cpu = regs_reg.prime_out;

        default:         data_to_cpu = '0;
      endcase
    end
  end

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      regs_reg <= '0;
    end
    else begin
      if (we) begin
        unique case (addr)
          ADDR_UNLOCK_KEY: regs_reg.unlock_key <= data_from_cpu;

          ADDR_AES_KEY0:   regs_reg.aes_key[127:96] <= data_from_cpu;
          ADDR_AES_KEY1:   regs_reg.aes_key[95:64]  <= data_from_cpu;
          ADDR_AES_KEY2:   regs_reg.aes_key[63:32]  <= data_from_cpu;
          ADDR_AES_KEY3:   regs_reg.aes_key[31:0]   <= data_from_cpu;

          ADDR_AES_IN0:    regs_reg.aes_in[127:96]  <= data_from_cpu;
          ADDR_AES_IN1:    regs_reg.aes_in[95:64]   <= data_from_cpu;
          ADDR_AES_IN2:    regs_reg.aes_in[63:32]   <= data_from_cpu;
          ADDR_AES_IN3:    regs_reg.aes_in[31:0]    <= data_from_cpu;

          ADDR_LFSR_SEED:  regs_reg.lfsr_seed       <= data_from_cpu;
          ADDR_PRIME_IN:   regs_reg.prime_in        <= data_from_cpu;

          default: ;
        endcase
      end

      if (hw_wr.en.aes_out)    regs_reg.aes_out    <= hw_wr.aes_out;
      if (hw_wr.en.puf_sig)    regs_reg.puf_sig    <= hw_wr.puf_sig;
      if (hw_wr.en.puf_enc[0]) regs_reg.puf_enc[0] <= hw_wr.puf_enc[0];
      if (hw_wr.en.puf_enc[1]) regs_reg.puf_enc[1] <= hw_wr.puf_enc[1];
      if (hw_wr.en.puf_enc[2]) regs_reg.puf_enc[2] <= hw_wr.puf_enc[2];
      if (hw_wr.en.puf_enc[3]) regs_reg.puf_enc[3] <= hw_wr.puf_enc[3];
      if (hw_wr.en.trng_word)  regs_reg.trng_word  <= hw_wr.trng_word;
      if (hw_wr.en.prng_word)  regs_reg.prng_word  <= hw_wr.prng_word;
      if (hw_wr.en.lfsr_seed)  regs_reg.lfsr_seed  <= hw_wr.lfsr_seed;
      if (hw_wr.en.prime_out)  regs_reg.prime_out  <= hw_wr.prime_out;
    end
  end

endmodule

`default_nettype wire
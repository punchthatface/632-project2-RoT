`ifndef ROT_PKG
`define ROT_PKG

package rot_pkg;

  // ============================================================
  // Basic widths required by the project
  // ============================================================

  // Width of the CPU-facing bus/register interface.
  localparam int BUSW = 32;

  // Width of the command opcode field inside the CMD register.
  // The CMD register itself is still 32 bits wide; only the low
  // CMD_W bits are interpreted as the command value.
  localparam int CMD_W = 4;

  // AES-128 uses 128-bit keys, plaintexts, and ciphertexts.
  localparam int AES_W = 128;

  // The PUF signature must be 120 bits long.
  localparam int PUF_W = 120;

  // The TRNG output register visible to the CPU is 32 bits wide.
  localparam int TRNG_W = 32;

  // The shared LFSR is 16 bits wide.
  localparam int LFSR_W = 16;

  // The primality checker operates on 10-bit inputs.
  localparam int PRIME_W = 10;

  // Number of ring oscillators in the shared RO bank.
  // 16 oscillators give 16 choose 2 = 120 pairwise comparisons,
  // which matches the required 120-bit PUF signature.
  localparam int RO_NUM = 16;

  // ============================================================
  // Command encoding
  // ============================================================
  // These are the values written by the CPU to ADDR_CMD.
  // Unlock is intentionally NOT part of this command enum.
  // Unlock is handled separately by the top-level lock FSM.

  typedef enum logic [CMD_W-1:0] {
    CMD_NOP        = 4'h0, // no operation
    CMD_AES        = 4'h1, // normal AES encryption using AES_IN
    CMD_AES_CTR    = 4'h2, // AES in CTR mode
    CMD_AES_PUF    = 4'h3, // AES using next padded PUF chunk as plaintext
    CMD_PUF_GEN    = 4'h4, // generate 120-bit PUF signature
    CMD_TRNG_GEN32 = 4'h5, // generate 32 fresh TRNG bits
    CMD_TRNG_GEN16 = 4'h6, // generate 16 fresh TRNG bits
    CMD_PRNG_SEED  = 4'h7, // seed shared LFSR from TRNG data
    CMD_PRNG_START = 4'h8, // start PRNG running mode
    CMD_PRNG_STOP  = 4'h9, // stop PRNG running mode
    CMD_PRIME      = 4'hA  // start primality check
  } cmd_t;

  // ============================================================
  // Top-level control/status bookkeeping
  // ============================================================
  // This struct is convenient for the top-level controller.
  // It holds the logical meaning of the RoT state.
  // Later, these fields are packed into STATUS bits.

  typedef struct packed {
    logic unlocked;            // 1 when the lock FSM has been successfully unlocked
    logic lockout;             // 1 when the lock FSM is in black-hole / fail state

    logic busy_global;         // 1 when any RoT operation is currently active
    logic busy_aes;            // 1 while AES is running
    logic busy_aes_ctr;        // 1 while AES-CTR is running
    logic busy_puf;            // 1 while PUF generation is running
    logic busy_trng;           // 1 while TRNG generation is running
    logic busy_prng;           // 1 while PRNG generation is active
    logic busy_prime;          // 1 while primality checker is running

    logic aes_key_incomplete;  // AES key has not been fully / correctly loaded yet
    logic aes_key_correct;     // AES key load sequence was correct
    logic aes_key_incorrect;   // AES key load sequence was incorrect

    logic aes_out_valid;       // AES output registers contain valid data
    logic puf_valid;           // PUF signature registers contain valid data
    logic trng_valid;          // TRNG output register contains valid data
    logic prng_word_valid;     // PRNG output register contains a fresh 32-bit word
    logic prng_running;        // PRNG is currently running continuously
    logic prime_valid;         // Prime result register contains valid data

    logic cmd_rejected;        // most recent command was rejected by control logic
  } rot_ctrl_t;

  // ============================================================
  // STATUS register bit layout
  // ============================================================
  // This struct describes the 32-bit word returned at ADDR_STATUS.
  // Only 18 bits are currently used; the rest are returned as zero.

  typedef struct packed {
    logic [13:0] reserved;     // unused upper bits, returned as zero

    logic fault_or_lockout;    // lock FSM has entered fault / black-hole state
    logic cmd_rejected;        // command was rejected
    logic prime_valid;         // prime_out is valid
    logic prng_running;        // PRNG is currently running
    logic prng_word_valid;     // prng_word contains a fresh 32-bit word
    logic trng_valid;          // trng_word is valid
    logic puf_valid;           // puf_sig is valid
    logic aes_out_valid;       // aes_out is valid

    logic aes_key_incorrect;   // AES key load sequence was wrong
    logic aes_key_correct;     // AES key load sequence was correct
    logic aes_key_incomplete;  // AES key not fully/correctly loaded yet

    logic busy_prime;          // prime checker currently active
    logic busy_prng;           // PRNG currently active
    logic busy_trng;           // TRNG currently active
    logic busy_puf;            // PUF currently active
    logic busy_aes_ctr;        // AES-CTR currently active
    logic busy_aes;            // AES currently active
    logic busy_global;         // some RoT operation is active
  } status_bits_t;

  // This union lets us access STATUS either as a raw 32-bit word
  // or as named fields.
  typedef union packed {
    logic [BUSW-1:0] word;
    status_bits_t    bits;
  } status_reg_t;

  // ============================================================
  // Stored CPU-visible registers
  // ============================================================
  // This struct is the normal register bank stored in rot_csr.
  // STATUS is not stored here because it is composed from live
  // top-level control state. CMD is not stored here because it is
  // write-to-act, not a persistent register.

  typedef struct packed {
    logic [BUSW-1:0] unlock_key;     // 32-bit word consumed by the unlock FSM

    logic [AES_W-1:0] aes_key;       // 128-bit AES key written by CPU
    logic [AES_W-1:0] aes_in;        // 128-bit AES input/plaintext written by CPU
    logic [AES_W-1:0] aes_out;       // 128-bit AES output written by hardware

    logic [PUF_W-1:0] puf_sig;       // 120-bit raw PUF signature written by hardware

    logic [AES_W-1:0] puf_enc0;      // encrypted PUF chunk 0
    logic [AES_W-1:0] puf_enc1;      // encrypted PUF chunk 1
    logic [AES_W-1:0] puf_enc2;      // encrypted PUF chunk 2
    logic [AES_W-1:0] puf_enc3;      // encrypted PUF chunk 3

    logic [BUSW-1:0] trng_word;      // 32-bit TRNG output
    logic [BUSW-1:0] prng_word;      // 32-bit PRNG output buffer
    logic [BUSW-1:0] lfsr_seed;      // shared LFSR seed register (low 16 bits used)
    logic [BUSW-1:0] prime_in;       // prime checker input register (low 10 bits used)
    logic [BUSW-1:0] prime_out;      // prime checker result register
  } rot_regs_t;

  // ============================================================
  // Hardware write-enable bundle
  // ============================================================
  // These bits tell rot_csr which hardware-produced registers
  // should be updated on a given cycle.

  typedef struct packed {
    logic aes_out;             // write aes_out
    logic puf_sig;             // write puf_sig
    logic [3:0] puf_enc;       // write one or more encrypted PUF blocks
    logic trng_word;           // write trng_word
    logic prng_word;           // write prng_word
    logic lfsr_seed;           // write lfsr_seed
    logic prime_out;           // write prime_out
  } rot_hw_wr_en_t;

  // ============================================================
  // Hardware writeback bundle
  // ============================================================
  // This struct groups all hardware-produced register values that
  // may be written into rot_csr. The matching enable bits above
  // decide which of these values actually update the CSR bank.

  typedef struct packed {
    rot_hw_wr_en_t en;         // per-register write enables

    logic [AES_W-1:0] aes_out; // AES output data
    logic [PUF_W-1:0] puf_sig; // raw PUF signature data

    logic [AES_W-1:0] puf_enc0; // encrypted PUF chunk 0
    logic [AES_W-1:0] puf_enc1; // encrypted PUF chunk 1
    logic [AES_W-1:0] puf_enc2; // encrypted PUF chunk 2
    logic [AES_W-1:0] puf_enc3; // encrypted PUF chunk 3

    logic [BUSW-1:0] trng_word; // TRNG result
    logic [BUSW-1:0] prng_word; // PRNG result
    logic [BUSW-1:0] lfsr_seed; // seed value written back by hardware
    logic [BUSW-1:0] prime_out; // prime checker result
  } rot_hw_wr_t;

  // ============================================================
  // Logical address map
  // ============================================================
  // These are logical register addresses, like Project 1.
  // Every address still returns 32 bits to the CPU.

  localparam logic [BUSW-1:0] ADDR_STATUS     = 32'h0000_0000; // read-only STATUS register
  localparam logic [BUSW-1:0] ADDR_CMD        = 32'h0000_0001; // write-only command trigger
  localparam logic [BUSW-1:0] ADDR_UNLOCK_KEY = 32'h0000_0002; // 32-bit unlock key word

  // AES key words
  localparam logic [BUSW-1:0] ADDR_AES_KEY0   = 32'h0000_0003; // aes_key[127:96]
  localparam logic [BUSW-1:0] ADDR_AES_KEY1   = 32'h0000_0004; // aes_key[95:64]
  localparam logic [BUSW-1:0] ADDR_AES_KEY2   = 32'h0000_0005; // aes_key[63:32]
  localparam logic [BUSW-1:0] ADDR_AES_KEY3   = 32'h0000_0006; // aes_key[31:0]

  // AES input words
  localparam logic [BUSW-1:0] ADDR_AES_IN0    = 32'h0000_0007; // aes_in[127:96]
  localparam logic [BUSW-1:0] ADDR_AES_IN1    = 32'h0000_0008; // aes_in[95:64]
  localparam logic [BUSW-1:0] ADDR_AES_IN2    = 32'h0000_0009; // aes_in[63:32]
  localparam logic [BUSW-1:0] ADDR_AES_IN3    = 32'h0000_000A; // aes_in[31:0]

  // AES output words
  localparam logic [BUSW-1:0] ADDR_AES_OUT0   = 32'h0000_000B; // aes_out[127:96]
  localparam logic [BUSW-1:0] ADDR_AES_OUT1   = 32'h0000_000C; // aes_out[95:64]
  localparam logic [BUSW-1:0] ADDR_AES_OUT2   = 32'h0000_000D; // aes_out[63:32]
  localparam logic [BUSW-1:0] ADDR_AES_OUT3   = 32'h0000_000E; // aes_out[31:0]

  // Raw PUF signature words
  localparam logic [BUSW-1:0] ADDR_PUF_SIG0   = 32'h0000_000F; // puf_sig[31:0]
  localparam logic [BUSW-1:0] ADDR_PUF_SIG1   = 32'h0000_0010; // puf_sig[63:32]
  localparam logic [BUSW-1:0] ADDR_PUF_SIG2   = 32'h0000_0011; // puf_sig[95:64]
  localparam logic [BUSW-1:0] ADDR_PUF_SIG3   = 32'h0000_0012; // {8'b0, puf_sig[119:96]}

  // Encrypted PUF chunk 0
  localparam logic [BUSW-1:0] ADDR_PUF_ENC0_0 = 32'h0000_0013; // puf_enc0[127:96]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC0_1 = 32'h0000_0014; // puf_enc0[95:64]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC0_2 = 32'h0000_0015; // puf_enc0[63:32]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC0_3 = 32'h0000_0016; // puf_enc0[31:0]

  // Encrypted PUF chunk 1
  localparam logic [BUSW-1:0] ADDR_PUF_ENC1_0 = 32'h0000_0017; // puf_enc1[127:96]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC1_1 = 32'h0000_0018; // puf_enc1[95:64]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC1_2 = 32'h0000_0019; // puf_enc1[63:32]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC1_3 = 32'h0000_001A; // puf_enc1[31:0]

  // Encrypted PUF chunk 2
  localparam logic [BUSW-1:0] ADDR_PUF_ENC2_0 = 32'h0000_001B; // puf_enc2[127:96]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC2_1 = 32'h0000_001C; // puf_enc2[95:64]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC2_2 = 32'h0000_001D; // puf_enc2[63:32]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC2_3 = 32'h0000_001E; // puf_enc2[31:0]

  // Encrypted PUF chunk 3
  localparam logic [BUSW-1:0] ADDR_PUF_ENC3_0 = 32'h0000_001F; // puf_enc3[127:96]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC3_1 = 32'h0000_0020; // puf_enc3[95:64]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC3_2 = 32'h0000_0021; // puf_enc3[63:32]
  localparam logic [BUSW-1:0] ADDR_PUF_ENC3_3 = 32'h0000_0022; // puf_enc3[31:0]

  // Random and primality-check related registers
  localparam logic [BUSW-1:0] ADDR_TRNG_WORD  = 32'h0000_0023; // 32-bit TRNG result
  localparam logic [BUSW-1:0] ADDR_PRNG_WORD  = 32'h0000_0024; // 32-bit PRNG output buffer
  localparam logic [BUSW-1:0] ADDR_LFSR_SEED  = 32'h0000_0025; // low 16 bits used as LFSR seed
  localparam logic [BUSW-1:0] ADDR_PRIME_IN   = 32'h0000_0026; // low 10 bits used as prime input
  localparam logic [BUSW-1:0] ADDR_PRIME_OUT  = 32'h0000_0027; // prime checker result

endpackage : rot_pkg

`endif
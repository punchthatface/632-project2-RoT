`default_nettype none

/* This module implements the SubBytes step of AES,
 * substituting each byte in the input using the S-box. */
module subBytes (
  input  logic [127:0] bytes,
  output logic [127:0] subbed_bytes
);

  logic [15:0][7:0] bytes_2d, subbed_bytes_2d;
  assign bytes_2d = bytes;
  assign subbed_bytes = subbed_bytes_2d;

  genvar i;
  generate
    for (i = 0; i < 16; i++) begin : GEN_SBOX
      sbox u_sbox (
        .a(bytes_2d[i]),
        .c(subbed_bytes_2d[i])
      );
    end
  endgenerate

endmodule
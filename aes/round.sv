`default_nettype none

/* This module brings together the three preceding files to
 * orchestrate a full round, followed by XOR with the round key. */ 
module round (
  input  logic [127:0] text, key,
  output logic [127:0] out_text
);

  // SubBytes
  logic [127:0] subbed_bytes;
  subBytes u_sub (.bytes(text), .subbed_bytes(subbed_bytes));

  // ShiftRows
  logic [127:0] shifted_bytes;
  shiftRows u_shift (.in(subbed_bytes), .out(shifted_bytes));

  // MixColumns
  logic [127:0] mixed_bytes;
  mixColumns u_mix (.in(shifted_bytes), .out(mixed_bytes));

  assign out_text = mixed_bytes ^ key;

endmodule
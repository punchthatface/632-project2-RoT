`default_nettype none

/* This module implements the ShiftRows step of AES,
 * shifting the rows of the state to the left by different offsets. */
module shiftRows (
  input  logic [127:0] in,
  output logic [127:0] out
);

  // Converting to/from array form to make shifts more intuitive
  logic [15:0][7:0] in_b, out_b;
  unpack_state u_unp (.in(in),  .b(in_b));
  pack_state   u_pak (.b(out_b), .out(out));

  // Row 0 (no shift)
  // 0 4 8 12
  assign out_b[0]  = in_b[0];
  assign out_b[4]  = in_b[4];
  assign out_b[8]  = in_b[8];
  assign out_b[12] = in_b[12];

  // Row 1 (shift left by 1)
  // 1 5 9 13 --> 5 9 13 1
  assign out_b[1]  = in_b[5];
  assign out_b[5]  = in_b[9];
  assign out_b[9]  = in_b[13];
  assign out_b[13] = in_b[1];

  // Row 2 (shift left by 2)
  // 2 6 10 14 --> 10 14 2 6
  assign out_b[2]  = in_b[10];
  assign out_b[6]  = in_b[14];
  assign out_b[10] = in_b[2];
  assign out_b[14] = in_b[6];

  // Row 3 (shift left by 3)
  // 3 7 11 15 --> 15 3 7 11
  assign out_b[3]  = in_b[15];
  assign out_b[7]  = in_b[3];
  assign out_b[11] = in_b[7];
  assign out_b[15] = in_b[11];

endmodule


/* Helper modules to convert between 128-bit state and 16x8-bit array form */
module unpack_state (
  input  logic [127:0]        in,
  output logic [15:0][7:0]     b
);
  // b[0] is MSB byte (a_0_0), b[15] is LSB byte (a_3_3)
  assign b[0]  = in[127:120];
  assign b[1]  = in[119:112];
  assign b[2]  = in[111:104];
  assign b[3]  = in[103:96];
  assign b[4]  = in[95:88];
  assign b[5]  = in[87:80];
  assign b[6]  = in[79:72];
  assign b[7]  = in[71:64];
  assign b[8]  = in[63:56];
  assign b[9]  = in[55:48];
  assign b[10] = in[47:40];
  assign b[11] = in[39:32];
  assign b[12] = in[31:24];
  assign b[13] = in[23:16];
  assign b[14] = in[15:8];
  assign b[15] = in[7:0];
endmodule


/* Helper modules to convert between 128-bit state and 16x8-bit array form */
module pack_state (
  input  logic [15:0][7:0]    b,
  output logic [127:0]         out
);
  // out[127:120] is b[0] (a_0_0), out[7:0] is b[15] (a_3_3)
  assign out[127:120] = b[0];
  assign out[119:112] = b[1];
  assign out[111:104] = b[2];
  assign out[103:96]  = b[3];
  assign out[95:88]   = b[4];
  assign out[87:80]   = b[5];
  assign out[79:72]   = b[6];
  assign out[71:64]   = b[7];
  assign out[63:56]   = b[8];
  assign out[55:48]   = b[9];
  assign out[47:40]   = b[10];
  assign out[39:32]   = b[11];
  assign out[31:24]   = b[12];
  assign out[23:16]   = b[13];
  assign out[15:8]    = b[14];
  assign out[7:0]     = b[15];
endmodule

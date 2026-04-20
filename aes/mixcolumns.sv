`default_nettype none

/* This module implements the MixColumns step of AES,
 * mixing the columns of the state using a fixed polynomial. */
module mixColumns (
  input  logic [127:0] in,
  output logic [127:0] out
);

  // Converting to/from array form to make column operations more intuitive
  logic [15:0][7:0] a, b;
  unpack_state u_unp (.in(in),  .b(a));
  pack_state   u_pak (.b(b), .out(out));

  genvar col, row;
  generate
    for (col = 0; col < 4; col++) begin : GEN_COL
      // To prevent instantiation exploding with signal name
      logic [7:0] a_0_c, a_1_c, a_2_c, a_3_c;
      assign a_0_c = a[4*col + 0];
      assign a_1_c = a[4*col + 1];
      assign a_2_c = a[4*col + 2];
      assign a_3_c = a[4*col + 3];

      // Matrix C contents hardcoded for each row
      for (row = 0; row < 4; row++) begin : GEN_ROW
        if (row == 0) begin
          compute_col u_row_0 (
            .val_0(a_0_c), .val_1(a_1_c), .val_2(a_2_c), .val_3(a_3_c),
            .c_0(2'd2), .c_1(2'd3), .c_2(2'd1), .c_3(2'd1),
            .b(b[4*col + row])
          );
        end else if (row == 1) begin
          compute_col u_row_1 (
            .val_0(a_0_c), .val_1(a_1_c), .val_2(a_2_c), .val_3(a_3_c),
            .c_0(2'd1), .c_1(2'd2), .c_2(2'd3), .c_3(2'd1),
            .b(b[4*col + row])
          );
        end else if (row == 2) begin
          compute_col u_row_2 (
            .val_0(a_0_c), .val_1(a_1_c), .val_2(a_2_c), .val_3(a_3_c),
            .c_0(2'd1), .c_1(2'd1), .c_2(2'd2), .c_3(2'd3),
            .b(b[4*col + row])
          );
        end else begin
          compute_col u_row_3 (
            .val_0(a_0_c), .val_1(a_1_c), .val_2(a_2_c), .val_3(a_3_c),
            .c_0(2'd3), .c_1(2'd1), .c_2(2'd1), .c_3(2'd2),
            .b(b[4*col + row])
          );
        end
      end
    end
  endgenerate

endmodule

/* This module computes one byte of the output column
 * by performing the Galois field multiplications and XORs. */
module compute_col (
  input  logic [7:0] val_0, val_1, val_2, val_3,
  input  logic [1:0] c_0, c_1, c_2, c_3,
  output logic [7:0] b
);

  // Intermediate values (the a00 * 2 val, for example)
  logic [7:0] product_0, product_1, product_2, product_3;

  galois u_gal0 (.a(val_0), .c(c_0), .b(product_0));
  galois u_gal1 (.a(val_1), .c(c_1), .b(product_1));
  galois u_gal2 (.a(val_2), .c(c_2), .b(product_2));
  galois u_gal3 (.a(val_3), .c(c_3), .b(product_3));

  assign b = product_0 ^ product_1 ^ product_2 ^ product_3;

endmodule

/* This module performs Galois field multiplication
 * of a byte 'a' by a constant 'c' (1, 2, or 3). */
module galois (
  input  logic [7:0] a,
  input  logic [1:0] c,
  output logic [7:0] b
);

  // Defines a*2 according to Galois field mult
  logic [7:0] a_mult_2;
  always_comb begin
    if (!a[7])
      a_mult_2 = a << 1;
    else
      a_mult_2 = (a << 1) ^ 8'b00011011;
  end
  
  // Mux of three cases + default for catching bugs.
  always_comb begin
    b = '0;
    case (c)
      2'd1: begin
        b = a;
      end

      2'd2: begin
        b= a_mult_2;
      end
       
      2'd3: begin
        b = a_mult_2 ^ a;
      end

      default:
        b = '0;
    endcase
  end

endmodule
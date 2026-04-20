`timescale 1ns/1ps
`default_nettype none

module lfsr_load #(parameter WIDTH = 16) (
  input  logic             clk, rst_n,
  input  logic             load, pulse,
  input  logic [WIDTH-1:0] load_value,
  output logic [WIDTH-1:0] seq
);

  // Primitive polynomial of degree 16:
  // x^16 + x^14 + x^13 + x^11 + 1
  //
  // Implemented as a right-shifting Galois LFSR with tap mask B400.
  // This module is intended for WIDTH=16 in Project 2.
  localparam logic [WIDTH-1:0] SEED     = 16'hACE1;
  localparam logic [WIDTH-1:0] TAP_MASK = 16'hB400;

  logic [WIDTH-1:0] flops;

  always_ff @(posedge clk, negedge rst_n) begin
    if (!rst_n) begin
      flops <= SEED;
    end else begin
      if (load) begin
        // Avoid the all-zero lockup state.
        if (load_value == '0)
          flops <= SEED;
        else
          flops <= load_value;
      end else if (pulse) begin
        if (flops[0])
          flops <= (flops >> 1) ^ TAP_MASK;
        else
          flops <= (flops >> 1);
      end
    end
  end

  assign seq = flops;

endmodule

`default_nettype wire
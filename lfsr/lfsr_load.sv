`timescale 1ns/1ps
`default_nettype none


module lfsr_load #(parameter WIDTH = 16) (
  input  logic             clk, rst_n,
  input  logic             load, pulse,
  input  logic             mode_prng,
  input  logic [WIDTH-1:0] load_value,
  output logic [WIDTH-1:0] seq,
  output logic [7:0]       byte_out
);

  // Primitive polynomial of degree 16:
  // x^16 + x^14 + x^13 + x^11 + 1
  //
  // Implemented as a right-shifting Galois LFSR with tap mask B400.
  // This module is intended for WIDTH=16 in Project 2.
  localparam logic [WIDTH-1:0] SEED     = 16'hACE1;
  localparam logic [WIDTH-1:0] TAP_MASK = 16'hB400;

  logic [WIDTH-1:0] flops;
  logic [WIDTH-1:0] next_seq;

  function automatic logic [WIDTH-1:0] lfsr_next_once(
    input logic [WIDTH-1:0] cur
  );
    begin
      if (cur[0])
        lfsr_next_once = (cur >> 1) ^ TAP_MASK;
      else
        lfsr_next_once = (cur >> 1);
    end
  endfunction

  function automatic logic [WIDTH-1:0] lfsr_advance(
    input logic [WIDTH-1:0] cur,
    input logic             prng_mode
  );
    logic [WIDTH-1:0] tmp;
    int i;
    begin
      tmp = cur;

      // PRNG mode consumes eight internal LFSR advances per controller
      // pulse, while AES-CTR uses the same shared state as a 1-step counter.
      if (prng_mode) begin
        for (i = 0; i < 8; i = i + 1)
          tmp = lfsr_next_once(tmp);
      end else begin
        tmp = lfsr_next_once(tmp);
      end

      lfsr_advance = tmp;
    end
  endfunction

  function automatic logic [7:0] lfsr_gen_byte(
    input logic [WIDTH-1:0] cur,
    input logic             prng_mode
  );
    logic [WIDTH-1:0] tmp;
    logic [7:0]       bits;
    int i;
    begin
      tmp  = cur;
      bits = '0;

      // byte_out is the architecturally visible PRNG byte. CTR mode does
      // not need it, but keeping one interface avoids duplicating the LFSR.
      if (prng_mode) begin
        for (i = 0; i < 8; i = i + 1) begin
          tmp     = lfsr_next_once(tmp);
          bits[i] = tmp[0];
        end
      end else begin
        tmp     = lfsr_next_once(tmp);
        bits[0] = tmp[0];
      end

      lfsr_gen_byte = bits;
    end
  endfunction

  assign next_seq = lfsr_advance(flops, mode_prng);
  assign byte_out = lfsr_gen_byte(flops, mode_prng);

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
        flops <= next_seq;
      end
    end
  end

  assign seq = flops;

endmodule

`default_nettype wire

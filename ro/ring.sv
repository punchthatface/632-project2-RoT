`timescale 1fs/1fs

module ring #(
  parameter STAGES       = 9,
  parameter COUNTER_SIZE = 10
)(
  input  logic enable,
  output logic feedback,
  output logic [COUNTER_SIZE-1:0] count
);

  logic [STAGES-1:0] stage;
  logic [COUNTER_SIZE-1:0] ctr;

  initial begin
    if ((STAGES < 3) || ((STAGES % 2) == 0)) begin
      $display("ERROR: STAGES must be odd and >= 3");
      $finish();
    end
  end

  NAND u_nand (
    .a(stage[STAGES-1]),
    .b(enable),
    .z(stage[0])
  );

  genvar i;
  generate
    for (i = 1; i < STAGES; i++) begin : gen_inv
      INV u_inv (
        .a(stage[i-1]),
        .z(stage[i])
      );
    end
  endgenerate

  assign feedback = stage[STAGES-1];
  assign count    = ctr;

  always_ff @(posedge stage[STAGES-1], negedge enable) begin
    if (!enable)
      ctr <= '0;
    else
      ctr <= ctr + 1'b1;
  end

endmodule
`default_nettype none

module ro_bank #(
  parameter STAGES       = 19,
  parameter COUNTER_SIZE = 10,
  parameter RO_NUM       = 16
)(
  input  logic                                enable,
  output logic [RO_NUM-1:0]                   feedback,
  output logic [RO_NUM-1:0][COUNTER_SIZE-1:0] count
);

  // ------------------------------------------------------------
  // Shared ring-oscillator bank
  // ------------------------------------------------------------
  genvar i;
  generate
    for (i = 0; i < RO_NUM; i++) begin : gen_ro
      ring #(
        .STAGES(STAGES),
        .COUNTER_SIZE(COUNTER_SIZE)
      ) u_ring (
        .enable(enable),
        .feedback(feedback[i]),
        .count(count[i])
      );
    end
  endgenerate

endmodule

`default_nettype wire
`default_nettype none


module lfsr_load #(parameter WIDTH = 18) (
  input  logic             clk, rst_n,
  input  logic             load, pulse,
  input  logic [WIDTH-1:0] load_value,
  output logic [WIDTH-1:0] seq
);

localparam SEED = 18'd134;


logic [WIDTH-1:0] flops;

always_ff @(posedge clk, negedge rst_n) begin
  if (!rst_n)
    flops <= SEED;
  else begin
    if (load)
      flops <= load_value;
    else if (pulse) begin
      flops[17] <= flops[0];
      flops[16] <= flops[17];
      flops[15] <= flops[16];
      flops[14] <= flops[15];
      flops[13] <= flops[14];
      flops[12] <= flops[13];
      flops[11] <= flops[12];
      flops[10] <= flops[11];
      flops[9]  <= flops[10];
      flops[8]  <= flops[9];
      flops[7]  <= flops[8];
      flops[6]  <= flops[7] ^ flops[0];  // tap for x^7
      flops[5]  <= flops[6];
      flops[4]  <= flops[5];
      flops[3]  <= flops[4];
      flops[2]  <= flops[3];
      flops[1]  <= flops[2];
      flops[0]  <= flops[1];
    end
  end

end

assign seq = flops;

endmodule

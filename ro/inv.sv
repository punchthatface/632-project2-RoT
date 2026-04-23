`timescale 1fs/1fs
module INV (a, z);
input a;
output z;

reg flip = 0;
reg [31:0] temp;
integer delay;

initial begin
  temp = $urandom; // this gives you a random unsigned number
  if (temp[31])
    flip = 1;
  temp = temp % 1000; // this contrains the random number between 0 and +999
  delay = temp;
  if (flip)
    delay = - delay;
  delay = delay + 10000;
  // $display(delay); // you can comment this line later
end

assign #delay z = !a; // delayed assignment
endmodule

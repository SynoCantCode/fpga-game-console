// delay_ram.v
// a value goes in and the same value comes out DELAY ticks later
// like a row of registers but kept in block ram so it costs way fewer flip flops

module delay_ram #(
    parameter WIDTH = 36,
    parameter DELAY = 18                 // 2 to 32
) (
    input wire clk,
    input wire advance,                  // 0 = hold everything still
    input wire [WIDTH-1:0] in,
    output reg [WIDTH-1:0] out
);

(* syn_ramstyle = "block_ram" *) reg [WIDTH-1:0] places [0:31];
reg [4:0] at = 5'd0;                                 // where the next value gets written
wire [4:0] behind = at - (DELAY - 1);                // the one written DELAY - 1 ticks ago, wraps at 32

// read and write are never the same place since DELAY is at least 2
always @(posedge clk) begin
    if (advance) begin
        places[at] <= in;
        out <= places[behind];
        at <= at + 5'd1;
    end
end

endmodule

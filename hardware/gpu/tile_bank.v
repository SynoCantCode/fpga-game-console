// tile_bank.v
// one bank of tile memory, 512 pixels of 32 bits = one block ram
// one write port, one read port, a read takes one clock

module tile_bank (
    input wire clk,

    // writing
    input wire write_enable,
    input wire [8:0] write_address,
    input wire [31:0] write_data,

    // reading
    input wire [8:0] read_address,
    output reg [31:0] read_data
);

reg [31:0] pixels [0:511];      // the memory

// writing
always @(posedge clk) begin
    if (write_enable)
        pixels[write_address] <= write_data;
end

// reading, the pixel comes out on the next tick
// reading the address being written on the same tick is undefined on the real chip
// COLLISION_JUNK (sim only) returns junk for that so nothing can depend on it
`ifdef COLLISION_JUNK
always @(posedge clk) begin
    if (write_enable && read_address == write_address) read_data <= $random;
    else read_data <= pixels[read_address];
end
`else
always @(posedge clk) begin
    read_data <= pixels[read_address];
end
`endif

endmodule

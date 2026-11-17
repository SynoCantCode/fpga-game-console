// texel_ram.v
// true dual port ram of 16 bit texels
// ports a and b can each read or write one texel every tick

module texel_ram #(
    parameter ADDRESS_BITS = 11             // 2048 texels
) (
    input wire clk,

    // port a
    input wire a_use,                       // 1 = port a does something this tick
    input wire a_write,                     // 1 = write, 0 = read
    input wire [ADDRESS_BITS-1:0] a_address,
    input wire [15:0] a_texel_in,
    output reg [15:0] a_texel,              // the texel read, one tick later

    // port b
    input wire b_use,
    input wire b_write,
    input wire [ADDRESS_BITS-1:0] b_address,
    input wire [15:0] b_texel_in,
    output reg [15:0] b_texel
);

reg [15:0] texels [0:(1 << ADDRESS_BITS) - 1];

`ifdef COLLISION_JUNK
// sim only, reading an address the other port writes (or both writing it) gives junk
wire a_writes = a_use && a_write;
wire b_writes = b_use && b_write;
wire same = (a_address == b_address);
always @(posedge clk) begin
    if (a_use) begin
        if (a_write) texels[a_address] <= (b_writes && same) ? $random : a_texel_in;
        else a_texel <= (b_writes && same) ? $random : texels[a_address];
    end
end
always @(posedge clk) begin
    if (b_use) begin
        if (b_write) begin
            if (!(a_writes && same)) texels[b_address] <= b_texel_in;
        end else b_texel <= (a_writes && same) ? $random : texels[b_address];
    end
end
`else
// port a
always @(posedge clk) begin
    if (a_use) begin
        if (a_write) texels[a_address] <= a_texel_in;
        else a_texel <= texels[a_address];
    end
end

// port b, same memory
always @(posedge clk) begin
    if (b_use) begin
        if (b_write) texels[b_address] <= b_texel_in;
        else b_texel <= texels[b_address];
    end
end
`endif

endmodule

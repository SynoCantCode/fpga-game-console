// texture_slots.v
// 256 texture descriptions in a block ram
// the cpu writes them through the registers, the back half reads one per triangle

module texture_slots (
    input wire clk,

    // write side, from the registers
    input wire write,                       // 1 for one clock
    input wire [7:0] write_slot,
    input wire [41:0] write_description,

    // read side, the back half
    input wire [7:0] read_slot,
    output reg [41:0] description           // one tick later
);

reg [41:0] slots [0:255];  // 42 bits: ddr3 start, log2 w, log2 h, format, bilinear, u rule, v rule, texture only, cutout

always @(posedge clk) begin
    if (write)
        slots[write_slot] <= write_description;
end

// sim only, reading the slot being written gives junk
`ifdef COLLISION_JUNK
always @(posedge clk) begin
    if (write && read_slot == write_slot) description <= {$random, $random};
    else description <= slots[read_slot];
end
`else
always @(posedge clk) begin
    description <= slots[read_slot];
end
`endif

endmodule

// tile_memory.v
// colour and depth for one 64x32 tile while its drawn, 2 samples per pixel
// two sides, one gets drawn into while the other is read out and wiped, swap trades them

module tile_memory #(
    parameter SLOTS = 8                     // slots per quad, 4 pixels x 2 samples
) (
    input wire clk,
    input wire reset,

    input wire swap,                        // 1 for one clock, the sides trade jobs
    input wire [31:0] clear_colour,         // what a wiped pixel becomes

    // the drawing side
    input wire [9:0] draw_read_quad,        // which quad to read
    output wire [SLOTS*32-1:0] draw_read_colour,   // its colours one clock later
    output wire [SLOTS*32-1:0] draw_read_depth,    // its depths one clock later

    input wire [9:0] draw_write_quad,       // which quad the depth writes go to
    input wire [9:0] colour_write_quad,     // colour writes have their own quad, they come later than depth
    input wire [SLOTS-1:0] colour_write_enable,  // one bit per slot
    input wire [SLOTS-1:0] depth_write_enable,   // one bit per slot
    input wire [SLOTS*32-1:0] draw_write_colour,
    input wire [SLOTS*32-1:0] draw_write_depth,

    // the writing out side
    input wire [9:0] out_quad,              // which quad to take
    input wire out_take,                    // 1 = read this quad and wipe it
    output wire [SLOTS*32-1:0] out_colour          // its colours one clock later, from before the wipe
);

// which side does what
// 0 = side 0 draws and side 1 writes out, 1 = the other way
reg drawing_side;
always @(posedge clk) begin
    if (reset)
        drawing_side <= 1'b0;
    else if (swap)
        drawing_side <= !drawing_side;
end

// the banks answer a clock late so remember which side was drawing when they were asked
reg answer_side;
always @(posedge clk) answer_side <= drawing_side;

// the wipe lands one tick after the read
// block ram cant read and write the same address on the same tick
reg wipe_now;                    // 1 = wipe wipe_quad this tick
reg [8:0] wipe_quad;
always @(posedge clk) begin
    wipe_now <= reset ? 1'b0 : out_take;
    wipe_quad <= out_quad[8:0];
end
`ifdef __ICARUS__
`define TILE_MEMORY_CHECKS
`endif
`ifdef VERILATOR
`define TILE_MEMORY_CHECKS
`endif
`ifdef TILE_MEMORY_CHECKS
// sim only, a quad taken on the swap tick would get wiped on the wrong side
always @(posedge clk) if (!reset && swap && out_take) $display("TILE MEMORY ERROR: a quad taken on a swap's tick");
`endif

// the banks, 2 sides x SLOTS x colour and depth
// side s slot l answers at bits [(s * SLOTS + l) * 32 +: 32]
wire [2*SLOTS*32-1:0] colour_answer, depth_answer;

genvar s, l;
generate
    for (s = 0; s < 2; s = s + 1) begin : side
        // is this side the drawing one right now
        wire drawing = (drawing_side == s);

        for (l = 0; l < SLOTS; l = l + 1) begin : lane
            // colour bank, drawn into or read out and wiped to the background
            tile_bank colour (
                .clk(clk),
                .write_enable (drawing ? colour_write_enable[l]           : wipe_now),
                .write_address(drawing ? colour_write_quad[8:0]           : wipe_quad),
                .write_data   (drawing ? draw_write_colour[l * 32 +: 32]  : clear_colour),
                .read_address (drawing ? draw_read_quad[8:0]              : out_quad[8:0]),
                .read_data(colour_answer[(s * SLOTS + l) * 32 +: 32])
            );

            // depth bank, tested and written or wiped to 0 (nothing drawn yet)
            tile_bank depth (
                .clk(clk),
                .write_enable (drawing ? depth_write_enable[l]            : wipe_now),
                .write_address(drawing ? draw_write_quad[8:0]             : wipe_quad),
                .write_data   (drawing ? draw_write_depth[l * 32 +: 32]   : 32'd0),
                .read_address (draw_read_quad[8:0]),
                .read_data(depth_answer[(s * SLOTS + l) * 32 +: 32])
            );
        end
    end
endgenerate

// the drawing sides answers go to the raster, the other sides go to the write out
assign draw_read_colour = (answer_side == 1'b0) ? colour_answer[SLOTS*32-1:0] : colour_answer[2*SLOTS*32-1:SLOTS*32];
assign draw_read_depth  = (answer_side == 1'b0) ? depth_answer[SLOTS*32-1:0]     : depth_answer[2*SLOTS*32-1:SLOTS*32];
assign out_colour       = (answer_side == 1'b0) ? colour_answer[2*SLOTS*32-1:SLOTS*32] : colour_answer[SLOTS*32-1:0];

endmodule

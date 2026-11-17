// raster_texture_tb.v
// test for the rasters texture lane
// hands triangles to the raster and writes every quad that comes out to a file for a python script to check
// depth test is off so every inside sample is drawn
`timescale 1ns / 1ps
module raster_texture_tb;

localparam TRIANGLES = 700;
localparam SLOTS = 8;

reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;

reg [304:0] triangles [0:TRIANGLES-1];
reg [304:0] t = 0;
reg tri_valid = 0;
wire tri_ready, busy;

wire [SLOTS-1:0] tex_drawn;
wire [9:0] tex_quad;
wire tex_textured;
wire [7:0] tex_slot;
wire [3:0] tex_level;
wire [87:0] tex_pu, tex_pv;
wire [9:0] draw_read_quad, draw_write_quad, colour_write_quad;
wire [SLOTS-1:0] colour_write_enable, depth_write_enable;
wire [SLOTS*32-1:0] draw_write_colour, draw_write_depth;

// edge 0 decides which samples are inside, offset 0 = inside, -1 = outside
// edges 1 and 2 are always inside
wire [3*SLOTS*28-1:0] slot_edge;
genvar gs;
generate
    for (gs = 0; gs < SLOTS; gs = gs + 1) begin : edge_0
        assign slot_edge[gs * 28 +: 28] = t[293 + gs] ? 28'd0 : 28'hFFFFFFF;
    end
endgenerate
assign slot_edge[3*SLOTS*28-1:SLOTS*28] = {2*SLOTS*28{1'b0}};

raster dut (
    .clk(clk), .reset(reset),
    .tri_valid(tri_valid), .tri_ready(tri_ready),
    .box_qx0(t[4:0]), .box_qx1(t[9:5]), .box_qy0(t[14:10]), .box_qy1(t[19:15]),
    .e0(40'sd0), .e1(40'sd1000), .e2(40'sd1000),                 // edge 0 is 0 so the slot offsets decide
    .a0(40'sd0), .a1(40'sd0), .a2(40'sd0), .b0(40'sd0), .b1(40'sd0), .b2(40'sd0),
    .z(t[51:20]), .za(t[83:52]), .zb(t[115:84]),
    .colour(32'hFF123456), .smooth(1'b0),
    .fogged(1'b0), .fog_colour(24'd0), .fog_table_write(1'b0), .fog_table_row(8'd0), .fog_table_word(16'd0),
    .colour_p(128'd0), .colour_pa(128'd0), .colour_pb(128'd0),
    .depth_test(1'b0), .depth_write(1'b0), .colour_write(1'b1),
    .slot_edge(slot_edge), .slot_depth({SLOTS*32{1'b0}}),
    .textured(t[116]), .texture_slot(t[124:117]), .texture_shift(t[129:125]), .texture_steep(t[130]),
    .tex_u(t[157:131]), .tex_v(t[184:158]),
    .tex_ua(t[211:185]), .tex_ub(t[238:212]), .tex_va(t[265:239]), .tex_vb(t[292:266]),
    .busy(busy),
    .tex_drawn(tex_drawn), .tex_quad(tex_quad), .tex_textured(tex_textured), .tex_slot(tex_slot),
    .tex_level(tex_level), .tex_pu(tex_pu), .tex_pv(tex_pv),
    .draw_read_quad(draw_read_quad), .draw_read_depth({SLOTS*32{1'b0}}),
    .draw_write_quad(draw_write_quad), .colour_write_quad(colour_write_quad),
    .colour_write_enable(colour_write_enable), .depth_write_enable(depth_write_enable),
    .draw_write_colour(draw_write_colour), .draw_write_depth(draw_write_depth)
);

integer file, n, g, quads = 0;
// write out every quad that draws something
always @(posedge clk)
    if (!reset && tex_drawn !== {SLOTS{1'b0}}) begin
        $fdisplay(file, "%h", {tex_quad, tex_drawn, tex_textured, tex_slot, tex_level, tex_pv, tex_pu});
        quads = quads + 1;
    end

initial begin
    $readmemh("build/raster_texture/triangles.hex", triangles);
    file = $fopen("build/raster_texture/quads.hex", "w");
    repeat (40) @(negedge clk);              // lanes have no reset so let them fill with known values
    reset = 0;
    repeat (4) @(negedge clk);
    for (n = 0; n < TRIANGLES; n = n + 1) begin
        // gap before this triangle, 0 = back to back
        for (g = 0; g < triangles[n][304:301]; g = g + 1) @(negedge clk);
        t = triangles[n];
        tri_valid = 1;
        while (tri_ready !== 1'b1) @(negedge clk);
        @(negedge clk);                      // taken on the clock edge in between
        tri_valid = 0;
    end
    while (busy !== 1'b0) @(negedge clk);
    repeat (40) @(negedge clk);
    $fclose(file);
    if (quads > 1000) $display("PASSED: every check is right (%0d triangles handed over, %0d quads written out)", TRIANGLES, quads);
    else $display("FAILED: only %0d quads came out", quads);
    $finish;
end

endmodule

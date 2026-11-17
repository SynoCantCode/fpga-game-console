// gpu_back_half.v
// the back half wired together
// turns the frames cards and shelves in ddr3 into a finished picture in the frame buffer, tile by tile
// tile_controller -> card_prep -> raster -> tile_memory -> tile_writeout

module gpu_back_half #(
    parameter [24:0] SHELF_BURSTS = 25'd2048
) (
    input wire clk,
    input wire reset,

    // orders
    input wire frame_start,
    input wire [24:0] shelves_start,
    input wire [24:0] cards_start,
    input wire [24:0] frame_buffer_start,
    input wire [31:0] clear_colour,          // background every tile starts from
    input wire [23:0] fog_colour,            // fog colour and the fog tables write port
    input wire fog_table_write,
    input wire [7:0] fog_table_row,
    input wire [15:0] fog_table_word,
    output wire frame_done,
    output wire busy,
    output wire [4:0] perf_bits,            // state bits for the speed counters

    // the arbiters port
    output wire mem_req,
    output wire [2:0] mem_cmd,
    output wire [28:0] mem_addr,
    output wire [255:0] mem_wr_data,
    output wire [31:0] mem_wr_mask,
    input wire mem_grant,
    input wire mem_rd_valid,
    input wire [255:0] mem_rd_data
);

// wires between the parts
// controller and card_prep
wire prep_start, prep_done, prep_empty;
wire [1023:0] prep_card;                   // slots a and b of the card
wire [4:0] prep_tile_x;
wire [4:0] prep_tile_y;

// card_prep to raster
wire [4:0] box_qx0, box_qx1, box_qy0, box_qy1;
wire signed [39:0] e0, e1, e2, a0, a1, a2, b0, b1, b2;
wire [31:0] z, colour;
wire signed [31:0] za, zb;
wire depth_test, depth_write, colour_write;

// controller and raster
wire tri_valid, tri_ready, raster_busy;

// raster and tile_memory, drawing side
wire [9:0] draw_read_quad, draw_write_quad, colour_write_quad;
wire smooth;                                  // smooth shading
wire fogged;                                  // fog
wire [127:0] colour_p, colour_pa, colour_pb;
// texture numbers of the triangle
wire textured, texture_steep;
wire [7:0] texture_slot;
wire [4:0] texture_shift;
wire [26:0] tex_u, tex_v;
wire signed [26:0] tex_ua, tex_ub, tex_va, tex_vb;
wire [255:0] draw_read_colour, draw_read_depth, draw_write_colour, draw_write_depth;     // 8 slots for 2x aa
wire [7:0] colour_write_enable, depth_write_enable;
wire [3*8*28-1:0] slot_edge;                 // slot offsets from card prep
wire [8*32-1:0] slot_depth;

// controller to tile_memory and writeout
wire swap, wo_start, wo_send, wo_busy;
wire [3:0] ctrl_perf;
wire [4:0] wo_tile_x;
wire [4:0] wo_tile_y;
wire [24:0] wo_frame_start;

// writeout and tile_memory
wire [9:0] out_quad;
wire out_take;
wire [255:0] out_colour;

// controller and writeout to the port share
wire ctrl_req, ctrl_grant, wo_req, wo_grant;
wire [2:0] ctrl_cmd, wo_cmd;
wire [28:0] ctrl_addr, wo_addr;
wire [255:0] wo_data;
wire [31:0] wo_mask;

// the parts
tile_controller #(.SHELF_BURSTS(SHELF_BURSTS)) controller (
    .clk(clk), .reset(reset),
    .frame_start(frame_start), .shelves_start(shelves_start), .cards_start(cards_start),
    .frame_buffer_start(frame_buffer_start), .frame_done(frame_done), .busy(busy),
    .mem_req(ctrl_req), .mem_cmd(ctrl_cmd), .mem_addr(ctrl_addr), .mem_grant(ctrl_grant),
    .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data),
    .prep_start(prep_start), .prep_card(prep_card), .prep_tile_x(prep_tile_x), .prep_tile_y(prep_tile_y),
    .prep_done(prep_done), .prep_empty(prep_empty),
    .tri_valid(tri_valid), .tri_ready(tri_ready), .raster_busy(raster_busy),
    .swap(swap), .wo_start(wo_start), .wo_send(wo_send), .wo_tile_x(wo_tile_x), .wo_tile_y(wo_tile_y),
    .wo_frame_start(wo_frame_start), .wo_busy(wo_busy), .perf_bits(ctrl_perf)
);
assign perf_bits = {ctrl_perf, wo_busy};

card_prep prep (
    .clk(clk), .start(prep_start), .card(prep_card), .tile_x(prep_tile_x), .tile_y(prep_tile_y),
    .done(prep_done), .empty(prep_empty),
    .box_qx0(box_qx0), .box_qx1(box_qx1), .box_qy0(box_qy0), .box_qy1(box_qy1),
    .e0(e0), .e1(e1), .e2(e2), .a0(a0), .a1(a1), .a2(a2), .b0(b0), .b1(b1), .b2(b2),
    .z(z), .za(za), .zb(zb), .colour(colour),
    .depth_test(depth_test), .depth_write(depth_write), .colour_write(colour_write),
    .slot_edge(slot_edge), .slot_depth(slot_depth),
    .smooth(smooth), .fogged(fogged), .colour_p(colour_p), .colour_pa(colour_pa), .colour_pb(colour_pb),
    .textured(textured), .texture_slot(texture_slot), .texture_shift(texture_shift), .texture_steep(texture_steep),
    .tex_u(tex_u), .tex_v(tex_v), .tex_ua(tex_ua), .tex_ub(tex_ub), .tex_va(tex_va), .tex_vb(tex_vb)
);

raster raster (
    .clk(clk), .reset(reset),
    .tri_valid(tri_valid), .tri_ready(tri_ready),
    .box_qx0(box_qx0), .box_qx1(box_qx1), .box_qy0(box_qy0), .box_qy1(box_qy1),
    .e0(e0), .e1(e1), .e2(e2), .a0(a0), .a1(a1), .a2(a2), .b0(b0), .b1(b1), .b2(b2),
    .z(z), .za(za), .zb(zb), .colour(colour),
    .depth_test(depth_test), .depth_write(depth_write), .colour_write(colour_write),
    .slot_edge(slot_edge), .slot_depth(slot_depth),
    .smooth(smooth), .colour_p(colour_p), .colour_pa(colour_pa), .colour_pb(colour_pb),
    .fogged(fogged), .fog_colour(fog_colour), .fog_table_write(fog_table_write), .fog_table_row(fog_table_row),
    .fog_table_word(fog_table_word),
    .textured(textured), .texture_slot(texture_slot), .texture_shift(texture_shift), .texture_steep(texture_steep),
    .tex_u(tex_u), .tex_v(tex_v), .tex_ua(tex_ua), .tex_ub(tex_ub), .tex_va(tex_va), .tex_vb(tex_vb),
    // per quad texture outputs, nothing uses them yet
    .tex_drawn(), .tex_quad(), .tex_textured(), .tex_slot(), .tex_level(), .tex_pu(), .tex_pv(),
    .busy(raster_busy),
    .draw_read_quad(draw_read_quad), .draw_read_depth(draw_read_depth),
    .draw_write_quad(draw_write_quad), .colour_write_quad(colour_write_quad), .colour_write_enable(colour_write_enable),
    .depth_write_enable(depth_write_enable), .draw_write_colour(draw_write_colour),
    .draw_write_depth(draw_write_depth)
);

tile_memory tiles (
    .clk(clk), .reset(reset), .swap(swap), .clear_colour(clear_colour),
    .draw_read_quad(draw_read_quad), .draw_read_colour(draw_read_colour), .draw_read_depth(draw_read_depth),
    .draw_write_quad(draw_write_quad), .colour_write_quad(colour_write_quad), .colour_write_enable(colour_write_enable),
    .depth_write_enable(depth_write_enable), .draw_write_colour(draw_write_colour),
    .draw_write_depth(draw_write_depth),
    .out_quad(out_quad), .out_take(out_take), .out_colour(out_colour)
);

tile_writeout writeout (
    .clk(clk), .reset(reset),
    .start(wo_start), .send_to_memory(wo_send), .tile_x(wo_tile_x), .tile_y(wo_tile_y),
    .frame_start_burst(wo_frame_start), .busy(wo_busy), .done(),
    .out_quad(out_quad), .out_take(out_take), .out_colour(out_colour),
    .req(wo_req), .cmd(wo_cmd), .addr(wo_addr), .wr_data(wo_data), .wr_mask(wo_mask), .grant(wo_grant)
);

gpu_port_share door (
    .clk(clk), .reset(reset),
    .ctrl_req(ctrl_req), .ctrl_cmd(ctrl_cmd), .ctrl_addr(ctrl_addr), .ctrl_grant(ctrl_grant),
    .wo_req(wo_req), .wo_cmd(wo_cmd), .wo_addr(wo_addr), .wo_data(wo_data), .wo_mask(wo_mask), .wo_grant(wo_grant),
    .req(mem_req), .cmd(mem_cmd), .addr(mem_addr), .wr_data(mem_wr_data), .wr_mask(mem_wr_mask), .grant(mem_grant)
);

endmodule

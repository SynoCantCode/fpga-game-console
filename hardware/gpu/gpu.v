// gpu.v
// the whole gpu: command processor, front half and back half with one port to memory
// front half turns triangles into cards and shelves in ddr3, back half draws them tile by tile
// the two halves work on different frames at the same time

module gpu #(
    parameter [24:0] SHELF_BURSTS = 25'd2048,
    parameter [15:0] FOCAL = 16'd738,
    parameter [24:0] CARDS_A = 25'd0,          // the two sets of cards and shelves, in bursts
    parameter [24:0] SHELVES_A = 25'd0,
    parameter [24:0] CARDS_B = 25'd0,
    parameter [24:0] SHELVES_B = 25'd0
) (
    input wire clk,
    input wire reset,

    // the registers
    input wire reg_write,                    // 1 for one clock
    input wire reg_read,                     // 1 for one clock, reg_rdata shows up next clock
    input wire [5:0] reg_offset,
    input wire [31:0] reg_wdata,
    output wire [31:0] reg_rdata,
    output wire stopped,                     // 1 = not running

    // the frame buffers and the tv
    input wire buffer_ok,
    input wire [24:0] buffer_start,
    output wire buffer_begin,
    output wire buffer_end,
    input wire tv_frame,                     // 1 for one clock, tv started a new frame

    // status
    output wire front_busy,
    output wire draw_busy,
    output wire [31:0] dropped_near,
    output wire [31:0] dropped_too_far_out,
    output wire [31:0] dropped_back,
    output wire [31:0] dropped_flat,
    output wire [31:0] dropped_off_screen,
    output wire [16:0] cards_made,
    output wire overflow,                    // too many triangles or a full shelf

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

// the registers
wire list_waiting, list_taken, switch_wanted, switch_done;
wire [24:0] next_list;
wire front_begin, draw_start;
wire [15:0] focal = FOCAL;
wire [31:0] near, clear_colour;
wire fogged;                              // fogged switch from the command processor
wire textured;                            // this triangle is textured, its slot and corner uvs
wire [7:0] texture_slot;
wire [191:0] uvs;
wire [23:0] fog_colour;                   // fog settings from the registers to the raster
wire fog_table_write;
wire [7:0] fog_table_row;
wire [15:0] fog_table_word;
wire [1:0] lamp_table_write;              // lamp fade tables
wire [7:0] lamp_table_row;
wire [15:0] lamp_table_word;

// one registered copy of reset per part so no single reset wire has to reach everything
(* syn_preserve = 1 *) reg [7:0] reset_c = 8'hFF;
always @(posedge clk) reset_c <= {8{reset}};

wire [2:0] perf_select;                  // speed counters
wire [31:0] perf_value;
wire [4:0] back_perf;

gpu_registers registers (
    .clk(clk), .reset(reset_c[0]),
    .write(reg_write), .read(reg_read), .offset(reg_offset), .wdata(reg_wdata), .rdata(reg_rdata),
    .list_waiting(list_waiting), .next_list(next_list), .list_taken(list_taken),
    .switch_wanted(switch_wanted), .switch_done(switch_done),
    .front_begin(front_begin), .draw_begin(draw_start), .near(near), .clear_colour(clear_colour),
    .fog_colour(fog_colour), .fog_table_write(fog_table_write), .fog_table_row(fog_table_row), .fog_table_word(fog_table_word),
    .lamp_table_write(lamp_table_write), .lamp_table_row(lamp_table_row), .lamp_table_word(lamp_table_word),
    .stopped(stopped), .frame_finished(buffer_end), .overflow(overflow),
    .dropped_near(dropped_near), .dropped_too_far_out(dropped_too_far_out),
    .perf_select(perf_select), .perf_value(perf_value)
);

// the command processor
wire matrix_valid, matrix_ready, tri_valid, tri_ready;
wire [415:0] matrix;                      // includes the normal scale for lighting
wire [89:0] normals;
wire lit, lights_valid, lights_ready;
wire [311:0] lights;
wire lamps_valid, lamps_ready;
wire [255:0] lamps;
wire [287:0] corners;
wire [95:0] colour;                       // 3 corner colours
wire [3:0] switches;
wire front_end;
reg front_done;
wire [24:0] front_cards, front_shelves;
wire draw_done;
wire [24:0] draw_cards, draw_shelves, frame_buffer;
wire [255:0] answer_data;                 // read answers from the memory door
wire cp_req, cp_grant, cp_rd_valid;                 // command processors side of its request buffer
wire [2:0] cp_cmd;
wire [28:0] cp_addr;
wire door_cp_req, door_cp_grant;                    // the memory doors side
wire [2:0] door_cp_cmd;
wire [28:0] door_cp_addr;

// back halfs busy a tick late from a register, a late start is fine
reg draw_busy_late;
always @(posedge clk) draw_busy_late <= draw_busy;

command_processor #(.CARDS_A(CARDS_A), .SHELVES_A(SHELVES_A), .CARDS_B(CARDS_B), .SHELVES_B(SHELVES_B)) commands (
    .clk(clk), .reset(reset_c[1]),
    .list_waiting(list_waiting), .next_list(next_list), .list_taken(list_taken),
    .switch_wanted(switch_wanted), .switch_done(switch_done), .stopped(stopped),
    .mem_req(cp_req), .mem_cmd(cp_cmd), .mem_addr(cp_addr), .mem_grant(cp_grant),
    .mem_rd_valid(cp_rd_valid), .mem_rd_data(answer_data),
    .matrix_valid(matrix_valid), .matrix_ready(matrix_ready), .matrix(matrix),
    .tri_valid(tri_valid), .tri_ready(tri_ready), .corners(corners), .colour(colour), .switches(switches),
    .normals(normals), .lit(lit), .fogged(fogged), .textured(textured), .texture_slot(texture_slot), .uvs(uvs), .lights_valid(lights_valid), .lights_ready(lights_ready), .lights(lights),
    .lamps_valid(lamps_valid), .lamps_ready(lamps_ready), .lamps(lamps),
    .front_begin(front_begin), .front_cards(front_cards), .front_shelves(front_shelves),
    .front_end(front_end), .front_done(front_done),
    .draw_start(draw_start), .draw_cards(draw_cards), .draw_shelves(draw_shelves), .frame_buffer(frame_buffer),
    .draw_done(draw_done), .draw_busy(draw_busy_late),
    .buffer_ok(buffer_ok), .buffer_start(buffer_start), .buffer_begin(buffer_begin), .buffer_end(buffer_end),
    .tv_frame(tv_frame)
);

// projection to setup
wire proj_valid, proj_ready, proj_busy;
wire signed [15:0] px0, py0, px1, py1, px2, py2;
wire [31:0] pz0, pz1, pz2;
wire [95:0] pcolour;                      // 3 corner colours
wire [3:0] pswitches;
wire pfogged;                             // fogged switch
wire ptextured;                           // texture numbers
wire [7:0] ptexture_slot;
wire [191:0] puvs;

projection project (
    .clk(clk), .reset(reset_c[2]), .focal(focal), .near(near),
    .matrix_valid(matrix_valid), .matrix_ready(matrix_ready), .matrix(matrix),
    .tri_valid(tri_valid), .tri_ready(tri_ready), .corners(corners), .colour_in(colour), .switches_in(switches),
    .normals_in(normals), .lit_in(lit), .fogged_in(fogged), .textured_in(textured), .texture_slot_in(texture_slot), .uvs_in(uvs), .lights_valid(lights_valid), .lights_ready(lights_ready), .lights(lights),
    .lamps_valid(lamps_valid), .lamps_ready(lamps_ready), .lamps(lamps),
    .lamp_table_write(lamp_table_write), .lamp_table_row(lamp_table_row), .lamp_table_word(lamp_table_word),
    .out_valid(proj_valid), .out_ready(proj_ready),
    .x0(px0), .y0(py0), .x1(px1), .y1(py1), .x2(px2), .y2(py2), .z0(pz0), .z1(pz1), .z2(pz2),
    .colour(pcolour), .switches(pswitches), .fogged(pfogged),
    .textured(ptextured), .texture_slot(ptexture_slot), .uvs(puvs),
    .busy(proj_busy), .dropped_near(dropped_near), .dropped_too_far_out(dropped_too_far_out)
);

// setup to binning
reg setup_end, bin_end;
wire setup_flushed, setup_busy, setup_overflow;
wire card_valid, card_ready;                       // setups side of the card buffer
wire [16:0] card_number;
wire [15:0] box_left, box_right, box_top, box_bottom;
wire bin_card_valid, bin_card_ready;               // binnings side
wire [16:0] bin_card_number;
wire [15:0] bin_box_left, bin_box_right, bin_box_top, bin_box_bottom;
wire setup_req, setup_grant;
wire [2:0] setup_cmd;
wire [28:0] setup_addr;
wire [255:0] setup_data;
wire [31:0] setup_mask;

setup make_cards (
    .clk(clk), .reset(reset_c[3]),
    .frame_begin(front_begin), .cards_start(front_cards), .frame_end(setup_end),
    .frame_flushed(setup_flushed), .busy(setup_busy), .overflow(setup_overflow), .cards_made(cards_made),
    .dropped_back(dropped_back), .dropped_flat(dropped_flat), .dropped_off_screen(dropped_off_screen),
    .tri_valid(proj_valid), .tri_ready(proj_ready),
    .x0(px0), .y0(py0), .x1(px1), .y1(py1), .x2(px2), .y2(py2), .z0(pz0), .z1(pz1), .z2(pz2),
    .colour(pcolour), .switches(pswitches), .fogged(pfogged),
    .textured(ptextured), .texture_slot(ptexture_slot), .uvs(puvs),
    .card_valid(card_valid), .card_ready(card_ready), .card_number(card_number),
    .box_left(box_left), .box_right(box_right), .box_top(box_top), .box_bottom(box_bottom),
    .mem_req(setup_req), .mem_cmd(setup_cmd), .mem_addr(setup_addr), .mem_wr_data(setup_data),
    .mem_wr_mask(setup_mask), .mem_grant(setup_grant)
);

// card buffer between setup and binning so each side only sees registers
request_buffer #(.WIDTH(17 + 64)) card_buffer (
    .clk(clk), .reset(reset_c[4]),
    .in_valid(card_valid), .in_data({card_number, box_left, box_right, box_top, box_bottom}), .in_ready(card_ready),
    .out_valid(bin_card_valid),
    .out_data({bin_card_number, bin_box_left, bin_box_right, bin_box_top, bin_box_bottom}),
    .out_ready(bin_card_ready)
);

wire bin_finished, bin_busy, bin_overflow;
wire bin_req, bin_grant;
wire [2:0] bin_cmd;
wire [28:0] bin_addr;
wire [255:0] bin_data;
wire [31:0] bin_mask;

binning #(.SHELF_BURSTS(SHELF_BURSTS)) shelves (
    .clk(clk), .reset(reset_c[4]),
    .frame_begin(front_begin), .shelves_start(front_shelves), .frame_end(bin_end),
    .frame_finished(bin_finished), .busy(bin_busy), .overflow(bin_overflow),
    .card_valid(bin_card_valid), .card_ready(bin_card_ready), .card_number(bin_card_number),
    .box_left(bin_box_left), .box_right(bin_box_right), .box_top(bin_box_top), .box_bottom(bin_box_bottom),
    .mem_req(bin_req), .mem_cmd(bin_cmd), .mem_addr(bin_addr), .mem_wr_data(bin_data), .mem_wr_mask(bin_mask),
    .mem_grant(bin_grant)
);

// finishing the front halfs frame: projection empties, then setup finishes, then binning
localparam F_IDLE = 2'd0, F_WAIT_PROJECTION = 2'd1, F_WAIT_SETUP = 2'd2, F_WAIT_BINNING = 2'd3;
reg [1:0] finishing;
reg setup_done_seen;          // setup said flushed, binning also waits for the card buffer to be empty
// registered a clock late, still exact since nothing was offered then or now
reg proj_busy_late, tri_valid_late;
always @(posedge clk) begin
    proj_busy_late <= proj_busy;
    tri_valid_late <= tri_valid;
end
always @(posedge clk) begin
    if (reset_c[7]) begin
        finishing <= F_IDLE;
        setup_done_seen <= 1'b0;
        setup_end <= 1'b0;
        bin_end <= 1'b0;
        front_done <= 1'b0;
    end else begin
        setup_end <= 1'b0;
        bin_end <= 1'b0;
        front_done <= 1'b0;
        case (finishing)
            F_IDLE:            if (front_end) finishing <= F_WAIT_PROJECTION;
            F_WAIT_PROJECTION: if (!proj_busy_late && !tri_valid_late && !tri_valid) begin setup_end <= 1'b1; finishing <= F_WAIT_SETUP; end
            F_WAIT_SETUP: begin
                if (setup_flushed) setup_done_seen <= 1'b1;
                // every card handed on and none left in the card buffer
                if ((setup_flushed || setup_done_seen) && !bin_card_valid) begin
                    bin_end <= 1'b1;
                    setup_done_seen <= 1'b0;
                    finishing <= F_WAIT_BINNING;
                end
            end
            F_WAIT_BINNING:    if (bin_finished) begin front_done <= 1'b1; finishing <= F_IDLE; end
        endcase
    end
end
assign front_busy = proj_busy || setup_busy || bin_card_valid || bin_busy || (finishing != F_IDLE);
assign overflow = setup_overflow || bin_overflow;

// the back half
wire back_req, back_grant, back_rd_valid;
wire [2:0] back_cmd;
wire [28:0] back_addr;
wire [255:0] back_data;
wire [31:0] back_mask;

gpu_back_half #(.SHELF_BURSTS(SHELF_BURSTS)) back_half (
    .clk(clk), .reset(reset_c[5]),
    .frame_start(draw_start), .shelves_start(draw_shelves), .cards_start(draw_cards),
    .frame_buffer_start(frame_buffer), .clear_colour(clear_colour), .frame_done(draw_done), .busy(draw_busy),
    .fog_colour(fog_colour), .fog_table_write(fog_table_write), .fog_table_row(fog_table_row), .fog_table_word(fog_table_word),
    .mem_req(back_req), .mem_cmd(back_cmd), .mem_addr(back_addr), .mem_wr_data(back_data), .mem_wr_mask(back_mask),
    .mem_grant(back_grant), .mem_rd_valid(back_rd_valid), .mem_rd_data(answer_data), .perf_bits(back_perf)
);

// speed counters
gpu_perf perf (
    .clk(clk), .reset(reset_c[0]),
    .draw_start(draw_start), .draw_done(draw_done), .front_begin(front_begin), .front_done(front_done),
    .state_bits(back_perf), .select(perf_select), .value(perf_value)
);

// request buffer for the command processors reads so each side only sees registers
request_buffer #(.WIDTH(3 + 29)) cp_requests (
    .clk(clk), .reset(reset_c[6]),
    .in_valid(cp_req), .in_data({cp_cmd, cp_addr}), .in_ready(cp_grant),
    .out_valid(door_cp_req), .out_data({door_cp_cmd, door_cp_addr}), .out_ready(door_cp_grant)
);

// one port to memory
gpu_memory_door door (
    .clk(clk), .reset(reset_c[6]),
    .back_req(back_req), .back_cmd(back_cmd), .back_addr(back_addr), .back_data(back_data), .back_mask(back_mask),
    .back_grant(back_grant), .back_rd_valid(back_rd_valid),
    .cp_req(door_cp_req), .cp_cmd(door_cp_cmd), .cp_addr(door_cp_addr), .cp_grant(door_cp_grant),
    .cp_rd_valid(cp_rd_valid),
    .bin_req(bin_req), .bin_cmd(bin_cmd), .bin_addr(bin_addr), .bin_data(bin_data), .bin_mask(bin_mask),
    .bin_grant(bin_grant),
    .setup_req(setup_req), .setup_cmd(setup_cmd), .setup_addr(setup_addr), .setup_data(setup_data),
    .setup_mask(setup_mask), .setup_grant(setup_grant),
    .req(mem_req), .cmd(mem_cmd), .addr(mem_addr), .wr_data(mem_wr_data), .wr_mask(mem_wr_mask), .grant(mem_grant),
    .rd_valid(mem_rd_valid), .rd_data(mem_rd_data), .answer_data(answer_data)
);

endmodule

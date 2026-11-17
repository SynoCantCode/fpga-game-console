// spin_tb.v
// spinning pyramid test, commands through projection, setup, binning and the back half
// saves every frame and checks each triangle projection gives setup
`timescale 1ns / 1ps

module spin_tb;

    localparam FRAME_BURSTS = 115_200;
    localparam SHELF_BURSTS = 16;
    localparam SHELVES_START = FRAME_BURSTS;
    localparam CARDS_START = SHELVES_START + 460 * SHELF_BURSTS;
    localparam MAX_CARDS = 600;
    localparam BLOCKS = CARDS_START + MAX_CARDS * 8;
    localparam MAX_COMMANDS = 4000;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // command list and expected answers
    reg [511:0] commands [0:MAX_COMMANDS - 1];
    reg [255:0] expected [0:MAX_COMMANDS - 1];
    initial begin
        $readmemh("build/spin/commands.hex", commands);
        $readmemh("build/spin/expected.hex", expected);
    end

    // projection
    reg matrix_valid = 0, tri_valid = 0;
    wire matrix_ready, tri_ready;
    reg [511:0] cmd_now = 0;
    wire proj_valid, proj_ready, proj_busy;
    wire signed [15:0] px0, py0, px1, py1, px2, py2;
    wire [31:0] pz0, pz1, pz2;
    wire [95:0] pcolour;
    wire [3:0] pswitches;
    wire [31:0] dropped_near, dropped_far;

    projection project (
        .clk(clk), .reset(reset), .focal(16'd738), .near(32'd19661),
        .matrix_valid(matrix_valid), .matrix_ready(matrix_ready), .matrix({32'd0, cmd_now[383:0]}),
        .tri_valid(tri_valid), .tri_ready(tri_ready), .corners(cmd_now[287:0]),
        .colour_in(cmd_now[383:288]), .switches_in(cmd_now[387:384]), .normals_in(90'd0), .lit_in(1'b0), .fogged_in(1'b0), .textured_in(1'b0), .texture_slot_in(8'd0), .uvs_in(192'd0), .lights_valid(1'b0), .lights_ready(), .lights(312'd0), .lamps_valid(1'b0), .lamps_ready(), .lamps(256'd0), .lamp_table_write(2'b00), .lamp_table_row(8'd0), .lamp_table_word(16'd0),
        .out_valid(proj_valid), .out_ready(proj_ready),
        .x0(px0), .y0(py0), .x1(px1), .y1(py1), .x2(px2), .y2(py2), .z0(pz0), .z1(pz1), .z2(pz2),
        .colour(pcolour), .switches(pswitches),
        .busy(proj_busy), .dropped_near(dropped_near), .dropped_too_far_out(dropped_far));

    // setup
    reg front_begin = 0, setup_end = 0, bin_end = 0;
    wire setup_flushed, setup_busy, setup_overflow;
    wire [16:0] cards_made;
    wire [31:0] dropped_back, dropped_flat, dropped_off_screen;
    wire card_valid, card_ready;
    wire [16:0] card_number;
    wire [15:0] box_left, box_right, box_top, box_bottom;
    wire [4:0] req, grant, rd_valid;
    wire [2:0] setup_cmd, bin_cmd, gpu_cmd;
    wire [28:0] setup_addr, bin_addr, gpu_addr;
    wire [255:0] setup_data, bin_data, gpu_data, rd_data;
    wire [31:0] setup_mask, bin_mask, gpu_mask;

    setup make_cards (
        .fogged(1'b0), .textured(1'b0), .texture_slot(8'd0), .uvs(192'd0),
        .clk(clk), .reset(reset),
        .frame_begin(front_begin), .cards_start(CARDS_START[24:0]), .frame_end(setup_end),
        .frame_flushed(setup_flushed), .busy(setup_busy), .overflow(setup_overflow), .cards_made(cards_made),
        .dropped_back(dropped_back), .dropped_flat(dropped_flat), .dropped_off_screen(dropped_off_screen),
        .tri_valid(proj_valid), .tri_ready(proj_ready),
        .x0(px0), .y0(py0), .x1(px1), .y1(py1), .x2(px2), .y2(py2), .z0(pz0), .z1(pz1), .z2(pz2),
        .colour(pcolour[31:0]), .switches(pswitches),
        .card_valid(card_valid), .card_ready(card_ready), .card_number(card_number),
        .box_left(box_left), .box_right(box_right), .box_top(box_top), .box_bottom(box_bottom),
        .mem_req(req[3]), .mem_cmd(setup_cmd), .mem_addr(setup_addr), .mem_wr_data(setup_data),
        .mem_wr_mask(setup_mask), .mem_grant(grant[3]));

    // binning
    wire bin_finished, bin_busy, bin_overflow;
    binning #(.SHELF_BURSTS(SHELF_BURSTS)) shelves (
        .clk(clk), .reset(reset),
        .frame_begin(front_begin), .shelves_start(SHELVES_START[24:0]), .frame_end(bin_end),
        .frame_finished(bin_finished), .busy(bin_busy), .overflow(bin_overflow),
        .card_valid(card_valid), .card_ready(card_ready), .card_number(card_number),
        .box_left(box_left), .box_right(box_right), .box_top(box_top), .box_bottom(box_bottom),
        .mem_req(req[4]), .mem_cmd(bin_cmd), .mem_addr(bin_addr), .mem_wr_data(bin_data), .mem_wr_mask(bin_mask),
        .mem_grant(grant[4]));

    // the back half
    reg draw_start = 0;
    wire frame_done, gpu_busy;
    gpu_back_half #(.SHELF_BURSTS(SHELF_BURSTS)) back_half (
        .fog_colour(24'd0), .fog_table_write(1'b0), .fog_table_row(8'd0), .fog_table_word(16'd0),
        .clk(clk), .reset(reset),
        .frame_start(draw_start), .shelves_start(SHELVES_START[24:0]), .cards_start(CARDS_START[24:0]),
        .frame_buffer_start(25'd0), .clear_colour(32'hFF1C_2230), .frame_done(frame_done), .busy(gpu_busy),
        .mem_req(req[2]), .mem_cmd(gpu_cmd), .mem_addr(gpu_addr), .mem_wr_data(gpu_data), .mem_wr_mask(gpu_mask),
        .mem_grant(grant[2]), .mem_rd_valid(rd_valid[2]), .mem_rd_data(rd_data));

    // arbiter, fake memory and a display
    wire calibrated, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, mem_rd_valid;
    wire [2:0] cmd;  wire [28:0] addr;  wire [255:0] wr_data, mem_rd_data;  wire [31:0] wr_data_mask;

    reg display_req = 0;  reg [24:0] display_burst = 0;  integer display_wait = 0;
    always @(posedge clk) begin
        #1;
        if (!reset && calibrated) begin
            if (grant[1]) begin
                display_burst = (display_burst + 1) % FRAME_BURSTS;
                display_req = 0;  display_wait = 13;
            end else if (display_wait > 0) display_wait = display_wait - 1;
            else display_req = 1;
        end
    end
    assign req[0] = 0;  assign req[1] = display_req;

    memory_arbiter #(.PORTS(5)) arbiter (
        .clk(clk), .reset(reset), .req(req),
        .port_cmd({bin_cmd, setup_cmd, gpu_cmd, 3'b001, 3'b001}),
        .port_addr({bin_addr, setup_addr, gpu_addr, {1'b0, display_burst, 3'b000}, 29'd0}),
        .port_wr_data({bin_data, setup_data, gpu_data, 256'd0, 256'd0}),
        .port_wr_mask({bin_mask, setup_mask, gpu_mask, 32'd0, 32'd0}),
        .grant(grant), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr), .wr_data_rdy(wr_data_rdy),
        .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data), .wr_data_mask(wr_data_mask),
        .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data));

    fake_memory_controller #(.BLOCKS(BLOCKS)) memory (
        .clk(clk), .calibrated(calibrated), .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data),
        .wr_data_mask(wr_data_mask), .rd_data_valid(mem_rd_valid), .rd_data(mem_rd_data));

    task tick;
        begin @(posedge clk); #1; end
    endtask

    // check projections answers as setup takes them
    integer checked = 0, wrong = 0;
    reg [255:0] want;
    function integer near_enough(input signed [15:0] got, input signed [15:0] exp);
        near_enough = (got - exp <= 1) && (exp - got <= 1);                   // within 1/16 pixel
    endfunction
    function integer depth_close(input [31:0] got, input [31:0] exp);
        reg [31:0] d;
        begin
            d = (got > exp) ? got - exp : exp - got;
            depth_close = (d <= 2 + (exp >> 24));                               // within rounding
        end
    endfunction
    always @(posedge clk) begin
        if (!reset && proj_valid && proj_ready) begin
            want = expected[checked];
            if (!(near_enough(px0, want[15:0]) && near_enough(py0, want[31:16]) &&
                  near_enough(px1, want[47:32]) && near_enough(py1, want[63:48]) &&
                  near_enough(px2, want[79:64]) && near_enough(py2, want[95:80]) &&
                  depth_close(pz0, want[127:96]) && depth_close(pz1, want[159:128]) &&
                  depth_close(pz2, want[191:160]) && pcolour == {3{want[223:192]}})) begin
                if (wrong < 5) $display("        triangle %0d: got (%0d,%0d) (%0d,%0d) (%0d,%0d), expected (%0d,%0d) (%0d,%0d) (%0d,%0d)",
                    checked, px0, py0, px1, py1, px2, py2, $signed(want[15:0]), $signed(want[31:16]),
                    $signed(want[47:32]), $signed(want[63:48]), $signed(want[79:64]), $signed(want[95:80]));
                wrong = wrong + 1;
            end
            checked = checked + 1;
        end
    end

    integer n, frame, back_start, back_clocks;
    reg [3:0] kind;

    initial begin
        $display("spin test: a spinning pyramid through projection, setup, binning and the back half");
        @(negedge clk);
        tick; reset = 0;
        wait (calibrated); tick;

        n = 0;
        frame = 0;
        while (commands[n][511:508] !== 4'hF) begin
            // front half for one frame
            front_begin = 1; tick; front_begin = 0;
            kind = commands[n][511:508];
            while (kind != 4'd3) begin
                cmd_now = commands[n];
                if (kind == 4'd1) begin
                    matrix_valid = 1;
                    while (!matrix_ready) tick;
                    tick;
                    matrix_valid = 0;
                end else begin
                    tri_valid = 1;
                    while (!tri_ready) tick;
                    tick;
                    tri_valid = 0;
                end
                n = n + 1;
                kind = commands[n][511:508];
            end
            n = n + 1;                                   // past the end of frame
            while (proj_busy) tick;
            setup_end = 1; tick; setup_end = 0;
            while (!setup_flushed) tick;
            bin_end = 1; tick; bin_end = 0;
            while (!bin_finished) tick;

            // back half draws it
            draw_start = 1; tick; draw_start = 0;
            back_start = $time;
            while (!frame_done) tick;
            back_clocks = ($time - back_start) / 10;
            $writememh($sformatf("build/spin/frame_%02d.hex", frame), memory.memory, 0, FRAME_BURSTS - 1);
            $display("  frame %0d: %0d cards (%0d back faces hidden), drawn in %0d clocks (%0d.%02d ms)", frame,
                     cards_made, dropped_back, back_clocks, back_clocks / 100_000, (back_clocks / 1000) % 100);
            frame = frame + 1;
        end

        $display("Projection's answers to setup, checked against exact maths:");
        $display("  %0d triangles checked, %0d off by more than 1/16 pixel (should be 0)", checked, wrong);
        $display("  dropped by projection: %0d too close, %0d too far off the screen", dropped_near, dropped_far);
        $display("  overflow flags: setup %0d, binning %0d; handshake mistakes %0d (all should be 0)",
                 setup_overflow, bin_overflow, memory.protocol_mistakes);
        if (wrong == 0 && memory.protocol_mistakes == 0 && !setup_overflow && !bin_overflow)
            $display("PASSED: every check is right");
        else
            $display("FAILED");
        $finish;
    end

endmodule

// picture_tb.v
// a whole scene through the real gpu, saved as an image
// triangles -> setup -> binning -> back half -> frame buffer, all through the arbiter into the fake ddr3
// with a display competing for memory
`timescale 1ns / 1ps

module picture_tb;

    localparam FRAME_BURSTS = 115_200;
    localparam SHELF_BURSTS = 64;                         // small shelves to keep the fake memory small
    localparam SHELVES_START = FRAME_BURSTS;
    localparam CARDS_START = SHELVES_START + 460 * SHELF_BURSTS;
    localparam MAX_TRIANGLES = 4000;
    localparam BLOCKS = CARDS_START + MAX_TRIANGLES * 8;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // the scene
    reg [255:0] scene [0:MAX_TRIANGLES];
    initial $readmemh("build/picture/scene.hex", scene);

    // setup
    reg front_begin = 0, setup_end = 0, bin_end = 0;
    wire setup_flushed, setup_busy, setup_overflow;
    wire [16:0] cards_made;
    wire [31:0] dropped_back, dropped_flat, dropped_off_screen;
    reg tri_valid = 0;  wire tri_ready;
    reg [255:0] t = 0;
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
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .x0(t[15:0]), .y0(t[31:16]), .x1(t[47:32]), .y1(t[63:48]), .x2(t[79:64]), .y2(t[95:80]),
        .z0(t[127:96]), .z1(t[159:128]), .z2(t[191:160]), .colour(t[223:192]), .switches(t[227:224]),
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
        .frame_buffer_start(25'd0), .clear_colour(32'hFFAC_C6D6), .frame_done(frame_done), .busy(gpu_busy),
        .mem_req(req[2]), .mem_cmd(gpu_cmd), .mem_addr(gpu_addr), .mem_wr_data(gpu_data), .mem_wr_mask(gpu_mask),
        .mem_grant(grant[2]), .mem_rd_valid(rd_valid[2]), .mem_rd_data(rd_data));

    // arbiter (display 1, back half 2, setup 3, binning 4), fake memory and a display
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

    integer n, front_start, front_clocks, back_start, back_clocks;

    initial begin
        $display("picture test: a scene through setup, binning and the whole back half, saved as an image");
        @(negedge clk);
        tick; reset = 0;
        wait (calibrated); tick;

        // front half, every triangle into setup, binning follows along
        front_begin = 1; tick; front_begin = 0;
        front_start = $time;
        n = 0;
        while (scene[n] !== {256{1'b1}} && n < MAX_TRIANGLES) begin
            t = scene[n];
            tri_valid = 1;
            while (!tri_ready) tick;
            tick;
            n = n + 1;
        end
        tri_valid = 0;
        setup_end = 1; tick; setup_end = 0;
        while (!setup_flushed) tick;
        bin_end = 1; tick; bin_end = 0;
        while (!bin_finished) tick;
        front_clocks = ($time - front_start) / 10;

        // back half, draw the frame
        draw_start = 1; tick; draw_start = 0;
        back_start = $time;
        while (!frame_done) tick;
        back_clocks = ($time - back_start) / 10;

        $display("Triangles sent: %0d", n);
        $display("  setup made %0d cards; dropped %0d facing away, %0d flat, %0d off the screen",
                 cards_made, dropped_back, dropped_flat, dropped_off_screen);
        $display("  overflow flags: setup %0d, binning %0d (should be 0)", setup_overflow, bin_overflow);
        $display("  front half: %0d clocks (%0d.%02d ms); back half: %0d clocks (%0d.%02d ms) at 100 MHz",
                 front_clocks, front_clocks / 100_000, (front_clocks / 1000) % 100,
                 back_clocks, back_clocks / 100_000, (back_clocks / 1000) % 100);
        $display("  handshake mistakes at the memory controller: %0d (should be 0)", memory.protocol_mistakes);

        $writememh("build/picture/frame.hex", memory.memory, 0, FRAME_BURSTS - 1);
        $display("Frame buffer saved to build/picture/frame.hex");
        $finish;
    end

    // give up if it gets stuck
    initial begin
        #2_000_000_000;
        $display("  FAIL  stuck at time %0d ns", $time);
        $finish;
    end

endmodule

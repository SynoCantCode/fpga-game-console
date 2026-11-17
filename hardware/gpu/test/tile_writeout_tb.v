// tile_writeout_tb.v
// tests tile_writeout.v with the real tile_memory, arbiter and a fake frame buffer
// each sample is made from its screen position so a misplaced pixel or wrong average shows up
`timescale 1ns / 1ps

module tile_writeout_tb;

    localparam FRAME_BURSTS = 115_200;     // 1280 x 720 / 8

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // tile_memory, driven by the test
    reg swap = 0;
    reg [31:0] clear_colour = 32'hFF10_2030;
    reg [9:0] draw_read_quad = 0, draw_write_quad = 0;
    wire [9:0] colour_write_quad = draw_write_quad;   // same quad here
    localparam SLOTS = 8, SPP = 2;                                       // 2x aa, 4 pixels x 2 samples
    reg [SLOTS-1:0] colour_write_enable = 0, depth_write_enable = 0;     // slot = pixel x SPP + sample
    reg [SLOTS*32-1:0] draw_write_colour = 0, draw_write_depth = 0;
    wire [SLOTS*32-1:0] draw_read_colour, draw_read_depth, out_colour;
    wire [9:0] out_quad;  wire out_take;

    tile_memory tiles (
        .clk(clk), .reset(reset), .swap(swap), .clear_colour(clear_colour),
        .draw_read_quad(draw_read_quad), .draw_read_colour(draw_read_colour), .draw_read_depth(draw_read_depth),
        .draw_write_quad(draw_write_quad), .colour_write_quad(colour_write_quad), .colour_write_enable(colour_write_enable),
        .depth_write_enable(depth_write_enable), .draw_write_colour(draw_write_colour),
        .draw_write_depth(draw_write_depth),
        .out_quad(out_quad), .out_take(out_take), .out_colour(out_colour));

    // the write-out
    reg start = 0, send_to_memory = 0;
    reg [4:0] tile_x = 0;  reg [4:0] tile_y = 0;
    wire busy, done;
    wire [4:0] req, grant, rd_valid;
    wire [2:0] gpu_cmd;  wire [28:0] gpu_addr;  wire [255:0] gpu_data, rd_data;  wire [31:0] gpu_mask;

    tile_writeout writeout (
        .clk(clk), .reset(reset),
        .start(start), .send_to_memory(send_to_memory), .tile_x(tile_x), .tile_y(tile_y),
        .frame_start_burst(25'd0), .busy(busy), .done(done),
        .out_quad(out_quad), .out_take(out_take), .out_colour(out_colour),
        .req(req[2]), .cmd(gpu_cmd), .addr(gpu_addr), .wr_data(gpu_data), .wr_mask(gpu_mask), .grant(grant[2]));

    wire calibrated, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, mem_rd_valid;

    // a display on port 1 reading at about the real displays pace
    // it has top priority so it must not ask nonstop
    reg display_req = 0;  reg [24:0] display_burst = 0;  integer display_wait = 0;
    always @(posedge clk) begin
        #1;
        if (!reset && calibrated) begin
            if (grant[1]) begin
                display_burst = (display_burst + 1) % FRAME_BURSTS;
                display_req = 0;
                display_wait = 13;
            end else if (display_wait > 0) display_wait = display_wait - 1;
            else display_req = 1;
        end
    end
    assign req[0] = 0;  assign req[1] = display_req;  assign req[3] = 0;  assign req[4] = 0;

    // arbiter and fake memory
    wire [2:0] cmd;  wire [28:0] addr;  wire [255:0] wr_data, mem_rd_data;  wire [31:0] wr_data_mask;

    memory_arbiter #(.PORTS(5)) arbiter (
        .clk(clk), .reset(reset), .req(req),
        .port_cmd({3'b001, 3'b001, gpu_cmd, 3'b001, 3'b001}),
        .port_addr({29'd0, 29'd0, gpu_addr, {1'b0, display_burst, 3'b000}, 29'd0}),
        .port_wr_data({256'd0, 256'd0, gpu_data, 256'd0, 256'd0}),
        .port_wr_mask({32'd0, 32'd0, gpu_mask, 32'd0, 32'd0}),
        .grant(grant), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr), .wr_data_rdy(wr_data_rdy),
        .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data), .wr_data_mask(wr_data_mask),
        .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data));

    fake_memory_controller #(.BLOCKS(FRAME_BURSTS)) memory (
        .clk(clk), .calibrated(calibrated), .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data),
        .wr_data_mask(wr_data_mask), .rd_data_valid(mem_rd_valid), .rd_data(mem_rd_data));

    // helpers
    integer failures = 0;

    task check(input [8*60-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    task tick;
        begin @(posedge clk); #1; end
    endtask

    // sample k of the pixel at x y, made from its own position
    function [31:0] sample_for(input integer x, input integer y, input integer k);
        sample_for = {4'hA, x[11:0], y[11:0], 4'h5} ^ (k * 32'h1D2B_3967);
    endfunction

    // what the pixel should be in the frame buffer, the rounded average of its samples
    function [31:0] pixel_for(input integer x, input integer y);
        integer c, k, sum;
        begin
            for (c = 0; c < 4; c = c + 1) begin
                sum = SPP / 2;
                for (k = 0; k < SPP; k = k + 1) sum = sum + ((sample_for(x, y, k) >> (c * 8)) & 255);
                pixel_for[c * 8 +: 8] = sum / SPP;
            end
        end
    endfunction

    // fill the drawing side one quad per clock
    task draw_tile(input integer tx, input integer ty);
        integer q, t, x, y;
        begin
            colour_write_enable = {SLOTS{1'b1}}; depth_write_enable = {SLOTS{1'b1}};
            for (q = 0; q < 512; q = q + 1) begin
                draw_write_quad = q;
                for (t = 0; t < SLOTS; t = t + 1) begin
                    x = tx * 64 + (q % 32) * 2 + (t / SPP) % 2;      // pixel 0 top left, 1 top right, 2 bottom left, 3 bottom right
                    y = ty * 32 + (q / 32) * 2 + (t / SPP) / 2;
                    draw_write_colour[t * 32 +: 32] = sample_for(x, y, t % SPP);
                    draw_write_depth[t * 32 +: 32] = 32'h1234 + q;
                end
                tick;
            end
            colour_write_enable = 0; depth_write_enable = 0;
        end
    endtask

    task do_swap;
        begin swap = 1; tick; swap = 0; end
    endtask

    task begin_writeout(input integer tx, input integer ty, input send);
        begin
            tile_x = tx; tile_y = ty; send_to_memory = send; start = 1; tick; start = 0;
        end
    endtask

    task wait_done;
        begin
            while (!done) tick;
            repeat (8) tick;   // let the last writes land
        end
    endtask

    // check a tile in the frame buffer, adds to wrong
    integer wrong = 0;
    task check_tile_in_memory(input integer tx, input integer ty);
        integer x, y, burst;
        reg [255:0] word;
        for (y = ty * 32; y < ty * 32 + 32 && y < 720; y = y + 1)
            for (x = tx * 64; x < tx * 64 + 64; x = x + 1) begin
                burst = y * 160 + x / 8;
                word = memory.memory[burst];
                if (word[(x % 8) * 32 +: 32] !== pixel_for(x, y)) begin
                    if (wrong < 5) $display("        wrong at (%0d, %0d): got %h, expected %h", x, y,
                                            word[(x % 8) * 32 +: 32], pixel_for(x, y));
                    wrong = wrong + 1;
                end
            end
    endtask

    // is the drawing side all clean, adds to wrong
    task check_drawing_side_clean;
        integer q;
        for (q = 0; q < 512; q = q + 1) begin
            draw_read_quad = q; tick;
            if (draw_read_colour !== {SLOTS{clear_colour}} || draw_read_depth !== 0) wrong = wrong + 1;
        end
    endtask

    // tiles to try, corners, edges, the middle and the short bottom row
    integer tile_list_x [0:5];
    integer tile_list_y [0:5];
    integer n, i, writes_before, nonzero, expected_bursts, start_time, clocks_taken;

    // count write-out writes that go to the burst right after the last one
    integer wo_writes = 0, wo_next_door = 0;
    reg [28:0] wo_last_addr = 0;
    always @(posedge clk) if (grant[2]) begin
        wo_writes = wo_writes + 1;
        if (gpu_addr == wo_last_addr + 29'd8) wo_next_door = wo_next_door + 1;
        wo_last_addr = gpu_addr;
    end

    // watchdog
    initial begin
        #20_000_000;
        $display("  FAIL  stuck: write-out sender %0d, busy %0d, req %0d, quad row %0d, strip %0d, time %0d ns",
                 writeout.sender, busy, req[2], writeout.quad_row, writeout.strip, $time);
        $finish;
    end

    initial begin
        tile_list_x[0] = 0;  tile_list_y[0] = 0;     // top left
        tile_list_x[1] = 19; tile_list_y[1] = 0;     // top right
        tile_list_x[2] = 7;  tile_list_y[2] = 11;    // middle
        tile_list_x[3] = 0;  tile_list_y[3] = 22;    // bottom left, 16 pixels tall
        tile_list_x[4] = 19; tile_list_y[4] = 22;    // bottom right
        tile_list_x[5] = 12; tile_list_y[5] = 21;    // just above the bottom row

        $display("tile_writeout test: tile_memory -> write-out -> arbiter (port 2) -> fake DDR3, a display competing");
        @(negedge clk);
        tick; reset = 0;
        wait (calibrated); tick;

        // test 1 startup wipe of both sides, nothing should reach memory
        writes_before = memory.writes_taken;
        do_swap;                                  // side 0 writes out
        begin_writeout(0, 0, 0); wait_done;
        do_swap;                                  // side 1 writes out
        begin_writeout(0, 0, 0); wait_done;
        do_swap;                                  // side 0 draws, side 1 waits
        $display("Start-up wipe (send_to_memory = 0):");
        check("writes that reached memory", memory.writes_taken - writes_before, 0);
        wrong = 0; check_drawing_side_clean;
        check("pixels not clean on the drawing side", wrong, 0);

        // test 2 write out each tile while drawing the next one
        draw_tile(tile_list_x[0], tile_list_y[0]);
        start_time = $time;
        for (n = 0; n < 6; n = n + 1) begin
            do_swap;
            begin_writeout(tile_list_x[n], tile_list_y[n], 1);
            if (n < 5) draw_tile(tile_list_x[n + 1], tile_list_y[n + 1]);
            wait_done;
        end
        clocks_taken = ($time - start_time) / 10;

        wrong = 0;
        for (n = 0; n < 6; n = n + 1) check_tile_in_memory(tile_list_x[n], tile_list_y[n]);
        $display("Six tiles (corners, edges, middle, bottom row), each written out while the next was drawn:");
        check("pixels wrong or misplaced in the frame buffer", wrong, 0);

        // test 3 only the right bursts were written, nothing below the screen
        nonzero = 0;
        for (i = 0; i < FRAME_BURSTS; i = i + 1) if (memory.memory[i] !== 256'd0) nonzero = nonzero + 1;
        expected_bursts = 4 * 256 + 2 * 128;
        $display("Only the tiles' own bursts are written (bottom row: 16 rows only, nothing below the screen):");
        check("bursts written in the frame buffer", nonzero, expected_bursts);
        check("writes taken by the memory", memory.writes_taken, expected_bursts);

        // test 4 the side just written out is clean
        do_swap;
        wrong = 0; check_drawing_side_clean;
        $display("After its write-out, the side is wiped:");
        check("pixels not clean", wrong, 0);

        // test 5 no handshake mistakes and writes go in row order
        $display("The memory controller's view:");
        check("handshake mistakes", memory.protocol_mistakes, 0);
        $display("In memory-row order (2026-11-13): %0d of %0d write-out writes went to the burst next door", wo_next_door, wo_writes);
        check("writes NOT next door, of each 100 (row order: about 12)", 100 - (wo_next_door * 100) / (wo_writes > 0 ? wo_writes : 1) > 20, 0);
        $display("  (speed: about %0d clocks per tile, with a display competing)", clocks_taken / 6);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

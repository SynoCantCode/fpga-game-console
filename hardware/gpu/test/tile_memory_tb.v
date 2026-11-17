// tile_memory_tb.v
// test for tile_memory, the 64x32 tile with two sides, colour and depth
// a plain array model says what every read should return
`timescale 1ns / 1ps

module tile_memory_tb;
    localparam SLOTS = 8, SPP = 2;                 // 4 pixels x 2 samples per quad

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    reg swap = 0;
    reg [31:0] clear_colour = 32'hFF_AC_C6_D6;     // sky blue 0xAARRGGBB
    reg [9:0] draw_read_quad = 0, draw_write_quad = 0, out_quad = 0;
    reg [9:0] colour_write_quad = 0;                 // colour writes have their own quad
    reg [SLOTS-1:0] colour_write_enable = 0, depth_write_enable = 0;
    reg [SLOTS*32-1:0] draw_write_colour = 0, draw_write_depth = 0;
    reg out_take = 0;
    wire [SLOTS*32-1:0] draw_read_colour, draw_read_depth, out_colour;

    tile_memory memory (
        .clk(clk), .reset(reset), .swap(swap), .clear_colour(clear_colour),
        .draw_read_quad(draw_read_quad), .draw_read_colour(draw_read_colour), .draw_read_depth(draw_read_depth),
        .draw_write_quad(draw_write_quad), .colour_write_quad(colour_write_quad), .colour_write_enable(colour_write_enable),
        .depth_write_enable(depth_write_enable), .draw_write_colour(draw_write_colour),
        .draw_write_depth(draw_write_depth),
        .out_quad(out_quad), .out_take(out_take), .out_colour(out_colour));

    // model, side s quad q slot l at [s*512*SLOTS + q*SLOTS + l]
    reg [31:0] model_colour [0:2*512*SLOTS-1];
    reg [31:0] model_depth  [0:2*512*SLOTS-1];
    integer drawing = 0;                 // side the model thinks is drawing

    integer failures = 0, wrong = 0;

    task check(input [8*56-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    task tick;
        begin @(posedge clk); #1; end
    endtask

    task compare(input [SLOTS*32-1:0] got, input [SLOTS*32-1:0] wanted, input [8*16-1:0] what);
        if (got !== wanted) begin
            if (wrong < 5) $display("        wrong %0s: got %h, expected %h", what, got, wanted);
            wrong = wrong + 1;
        end
    endtask

    // the models slots of a quad packed like the wires, slot 0 lowest
    function [SLOTS*32-1:0] quad_colour(input integer side_number, input integer q);
        integer k;
        for (k = 0; k < SLOTS; k = k + 1) quad_colour[k * 32 +: 32] = model_colour[side_number * (512 * SLOTS) + q * SLOTS + k];
    endfunction
    function [SLOTS*32-1:0] quad_depth(input integer side_number, input integer q);
        integer k;
        for (k = 0; k < SLOTS; k = k + 1) quad_depth[k * 32 +: 32] = model_depth[side_number * (512 * SLOTS) + q * SLOTS + k];
    endfunction

    function [SLOTS*32-1:0] random512(input integer unused);
        integer k;
        for (k = 0; k < SLOTS; k = k + 1) random512[k * 32 +: 32] = $urandom;
    endfunction

    // pick a random draw write for this clock
    task random_draw_write;
        begin
            draw_write_quad = $urandom % 512;
            colour_write_quad = $urandom % 512;      // usually a different quad than the depth write
            colour_write_enable = $urandom;
            depth_write_enable = $urandom;
            draw_write_colour = random512(0);
            draw_write_depth = random512(0);
        end
    endtask
    // put that write in the model, call after the tick
    task model_draw_write;
        integer k;
        for (k = 0; k < SLOTS; k = k + 1) begin
            if (colour_write_enable[k]) model_colour[drawing * (512 * SLOTS) + colour_write_quad * SLOTS + k] = draw_write_colour[k * 32 +: 32];
            if (depth_write_enable[k])  model_depth[drawing * (512 * SLOTS) + draw_write_quad * SLOTS + k]  = draw_write_depth[k * 32 +: 32];
        end
    endtask
    task model_wipe(input integer side_number, input integer q);
        integer k;
        for (k = 0; k < SLOTS; k = k + 1) begin
            model_colour[side_number * (512 * SLOTS) + q * SLOTS + k] = clear_colour;
            model_depth[side_number * (512 * SLOTS) + q * SLOTS + k] = 0;
        end
    endtask

    task do_swap;
        begin swap = 1; tick; swap = 0; drawing = 1 - drawing; end
    endtask

    // write out the side that isnt drawing and check all 512 quads
    // draw_too = also draw and read the other side at random every clock
    task write_out_while_drawing(input draw_too);
        integer q;
        reg [SLOTS*32-1:0] wanted_out, wanted_colour, wanted_depth;
        begin
            for (q = 0; q < 512; q = q + 1) begin
                out_quad = q; out_take = 1;
                wanted_out = quad_colour(1 - drawing, q);
                if (draw_too) begin
                    random_draw_write;
                    draw_read_quad = $urandom % 512;
                    wanted_colour = quad_colour(drawing, draw_read_quad);   // a read sees the pixels from before this clock
                    wanted_depth = quad_depth(drawing, draw_read_quad);
                end
                tick;
                compare(out_colour, wanted_out, "write-out");
                model_wipe(1 - drawing, q);
                if (draw_too) begin
                    compare(draw_read_colour, wanted_colour, "draw colour");
                    compare(draw_read_depth, wanted_depth, "draw depth");
                    model_draw_write;
                end
            end
            out_take = 0; colour_write_enable = 0; depth_write_enable = 0;
        end
    endtask

    // read back every quad of the drawing side and compare with the model
    task read_whole_drawing_side;
        integer q;
        for (q = 0; q < 512; q = q + 1) begin
            draw_read_quad = q;
            tick;
            compare(draw_read_colour, quad_colour(drawing, q), "colour");
            compare(draw_read_depth, quad_depth(drawing, q), "depth");
        end
    endtask

    integer i, t, x, y, lane_of, quad_of, sample;
    reg [31:0] pixel;

    initial begin
        $display("tile_memory test: one 64 x 32 tile, two sides, colour + depth, %0d slots per quad", SLOTS);
        for (i = 0; i < 2 * 512 * SLOTS; i = i + 1) begin model_colour[i] = 32'hx; model_depth[i] = 32'hx; end
        @(negedge clk);
        tick; reset = 0;

        // test 1 startup wipe, write out both sides then everything is background with depth 0
        for (i = 0; i < 512; i = i + 1) begin out_quad = i; out_take = 1; tick; model_wipe(1 - drawing, i); end
        out_take = 0; do_swap;
        for (i = 0; i < 512; i = i + 1) begin out_quad = i; out_take = 1; tick; model_wipe(1 - drawing, i); end
        out_take = 0; do_swap;
        wrong = 0;
        read_whole_drawing_side;
        $display("Start-up wipe of both sides:");
        check("pixels not background / depth not 0", wrong, 0);

        // test 2 random quad writes, some slots off, colour and depth separate, then read all back
        wrong = 0;
        for (i = 0; i < 5000; i = i + 1) begin random_draw_write; tick; model_draw_write; end
        colour_write_enable = 0; depth_write_enable = 0;
        read_whole_drawing_side;
        $display("5,000 random quad writes (slots on and off, colour and depth separately), all read back:");
        check("wrong pixels", wrong, 0);

        // test 3 swap, write out the finished tile while the next one is drawn
        do_swap;
        wrong = 0;
        write_out_while_drawing(1);
        $display("Swap, then write out the finished tile while the next is drawn (both busy every clock):");
        check("wrong pixels (write-out and drawing side)", wrong, 0);

        // test 4 several tiles in a row
        wrong = 0;
        for (t = 0; t < 6; t = t + 1) begin
            do_swap;
            write_out_while_drawing(1);
        end
        do_swap;
        write_out_while_drawing(0);          // last tile written out alone
        do_swap;                             // the wiped side is drawing now, must be all background
        read_whole_drawing_side;
        $display("Six more tiles in a row, swapping each time, then one more write-out:");
        check("wrong pixels", wrong, 0);

        // test 5 where sample s of pixel x y lives, write by position and read back by quad and slot
        wrong = 0;
        for (i = 0; i < 300; i = i + 1) begin
            x = $urandom % 64; y = $urandom % 32; sample = $urandom % SPP;
            lane_of = {y[0], x[0]} * SPP + sample; quad_of = {y[4:1], x[5:1]};
            pixel = {8'hFF, x[7:0], y[7:0], 6'd0, sample[1:0]};
            draw_write_quad = quad_of;  colour_write_quad = quad_of;
            colour_write_enable = {{(SLOTS-1){1'b0}}, 1'b1} << lane_of; depth_write_enable = 0;
            draw_write_colour = 0; draw_write_colour[lane_of * 32 +: 32] = pixel;
            tick;
            colour_write_enable = 0;
            draw_read_quad = quad_of; tick;
            if (draw_read_colour[lane_of * 32 +: 32] !== pixel) wrong = wrong + 1;
        end
        $display("Samples written by (x, y, s), found in slot {y[0], x[0]} x SPP + s of quad {y[4:1], x[5:1]}:");
        check("samples not where expected", wrong, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

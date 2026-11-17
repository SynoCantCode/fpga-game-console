// video_timing_tb.v
// runs the timing for 2 whole frames and checks every number against 720p
`timescale 1ns / 1ps

module video_timing_tb;

    // what 720p should be
    localparam ROW_TICKS      = 1650;
    localparam FRAME_ROWS     = 750;
    localparam FRAME_TICKS    = ROW_TICKS * FRAME_ROWS;   // ticks per frame
    localparam VISIBLE_TICKS  = 1280 * 720;               // visible pixels per frame
    localparam HSYNC_TICKS    = 40;                       // hsync is high for 40 pixels
    localparam HSYNC_START_X  = 1390;                     // starting at x = 1390
    localparam VSYNC_ROWS     = 5;                        // vsync is high for 5 rows
    localparam VSYNC_START_Y  = 725;                      // starting at row 725

    // the block being tested
    reg clk = 0;
    reg reset = 1;
    wire [10:0] x;
    wire [9:0]  y;
    wire visible, hsync, vsync;

    video_timing timing (
        .clk(clk), .reset(reset),
        .x(x), .y(y),
        .visible(visible), .hsync(hsync), .vsync(vsync)
    );

    // 74.25 MHz clock
    always #6.734 clk = ~clk;

    // check helper
    integer failures = 0;

    task check(input string what, input integer got, input integer expected);
        if (got == expected) begin
            $display("  ok    %0s: %0d", what, got);
        end else begin
            $display("  FAIL  %0s: got %0d, expected %0d", what, got, expected);
            failures = failures + 1;
        end
    endtask

    // measure one frame by looking at every pixel and counting
    // looks at the falling clock edge when everything has settled
    integer visible_ticks, hsync_ticks, hsync_pulses, vsync_ticks, vsync_pulses;
    integer hsync_wrong_start, vsync_wrong_start, hsync_wrong_length;
    integer highest_x, highest_y, pulse_length, i;
    reg was_hsync, was_vsync;

    task measure_one_frame;
        begin
            visible_ticks = 0; hsync_ticks = 0; hsync_pulses = 0; vsync_ticks = 0; vsync_pulses = 0;
            hsync_wrong_start = 0; vsync_wrong_start = 0; hsync_wrong_length = 0;
            highest_x = 0; highest_y = 0; pulse_length = 0;
            was_hsync = 0; was_vsync = 0;

            for (i = 0; i < FRAME_TICKS; i = i + 1) begin
                @(negedge clk);

                if (visible === 1'b1) visible_ticks = visible_ticks + 1;
                if (hsync   === 1'b1) hsync_ticks   = hsync_ticks + 1;
                if (vsync   === 1'b1) vsync_ticks   = vsync_ticks + 1;
                if (x > highest_x) highest_x = x;
                if (y > highest_y) highest_y = y;

                // a pulse starts when the signal goes 0 to 1, check it starts in the right place
                if (hsync === 1'b1 && !was_hsync) begin
                    hsync_pulses = hsync_pulses + 1;
                    if (x != HSYNC_START_X) hsync_wrong_start = hsync_wrong_start + 1;
                    pulse_length = 0;
                end
                if (vsync === 1'b1 && !was_vsync) begin
                    vsync_pulses = vsync_pulses + 1;
                    if (y != VSYNC_START_Y || x != 0) vsync_wrong_start = vsync_wrong_start + 1;
                end

                // every hsync pulse must be exactly 40 ticks long
                if (hsync === 1'b1) pulse_length = pulse_length + 1;
                if (hsync !== 1'b1 && was_hsync && pulse_length != HSYNC_TICKS)
                    hsync_wrong_length = hsync_wrong_length + 1;

                was_hsync = (hsync === 1'b1);
                was_vsync = (vsync === 1'b1);
            end
        end
    endtask

    task report_frame(input integer frame);
        begin
            $display("Frame %0d:", frame);
            check("highest x (pixel in a row)", highest_x, ROW_TICKS - 1);
            check("highest y (row in a frame)", highest_y, FRAME_ROWS - 1);
            check("visible pixels per frame", visible_ticks, VISIBLE_TICKS);
            check("hsync pulses per frame (one per row)", hsync_pulses, FRAME_ROWS);
            check("hsync ticks per frame (40 x 750)", hsync_ticks, HSYNC_TICKS * FRAME_ROWS);
            check("hsync pulses not exactly 40 long", hsync_wrong_length, 0);
            check("hsync pulses not starting at x = 1390", hsync_wrong_start, 0);
            check("vsync pulses per frame", vsync_pulses, 1);
            check("vsync ticks per frame (5 rows)", vsync_ticks, VSYNC_ROWS * ROW_TICKS);
            check("vsync pulses not starting at row 725, x = 0", vsync_wrong_start, 0);
        end
    endtask

    // the test
    initial begin
        $display("video_timing test: 2 frames, %0d ticks each", FRAME_TICKS);

        // hold reset for a few ticks then let it run from the top left corner
        repeat (3) @(posedge clk);
        reset = 0;

        measure_one_frame; report_frame(1);
        measure_one_frame; report_frame(2);   // second frame shows it wraps around right

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

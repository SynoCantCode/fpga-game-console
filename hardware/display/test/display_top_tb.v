// display_top_tb.v
// whole display tested end to end by only looking at the hdmi wires
// a fake tv reads the bits, finds the words, decodes them and rebuilds a frame
// then checks the frame shape, every pixel color, and that each - wire is the opposite of its + wire
`timescale 1ns / 1ps

module display_top_tb;

    GSR GSR (.GSRI(1'b1));   // gowins global reset, the sim models need it (1 = not resetting)

    // the design as it goes on the board
    reg clk_50 = 0;
    always #10 clk_50 = ~clk_50;   // board crystal (the fake pll ignores it)

    wire [2:0] tmds_data_p, tmds_data_n;
    wire tmds_clock_p, tmds_clock_n;

    display_top display (
        .clk_50(clk_50),
        .tmds_data_p(tmds_data_p), .tmds_data_n(tmds_data_n),
        .tmds_clock_p(tmds_clock_p), .tmds_clock_n(tmds_clock_n)
    );

    // what the picture should be, same rule as test_picture.v
    // the 2nd frame after reset is checked so the moving box has moved once
    localparam CHECKED_BOX_X = 8;

    function [23:0] expected_color(input integer px, input integer py);
        begin
            if (px == 0 || px == 1279 || py == 0 || py == 719) expected_color = 24'hFF0000;   // red border
            else case (px / 160)
                0: expected_color = 24'hFFFFFF;   // white
                1: expected_color = 24'hFFFF00;   // yellow
                2: expected_color = 24'h00FFFF;   // cyan
                3: expected_color = 24'h00FF00;   // green
                4: expected_color = 24'hFF00FF;   // magenta
                5: expected_color = 24'hFF0000;   // red
                6: expected_color = 24'h0000FF;   // blue
                default: expected_color = 24'h000000;   // black
            endcase
            if (!(px == 0 || px == 1279 || py == 0 || py == 719) &&
                px >= CHECKED_BOX_X && px < CHECKED_BOX_X + 80 && py >= 320 && py < 400)
                expected_color = ~expected_color;   // moving box flips the color
        end
    endfunction

    // tv decoder, one 10 bit code back to 8 bits
    function [7:0] decode(input [9:0] code);
        reg [7:0] d;
        integer k;
        begin
            d = code[9] ? ~code[7:0] : code[7:0];
            decode[0] = d[0];
            for (k = 1; k < 8; k = k + 1)
                decode[k] = code[8] ? (d[k] ^ d[k-1]) : ~(d[k] ^ d[k-1]);
        end
    endfunction

    localparam CONTROL_00 = 10'b1101010100, CONTROL_01 = 10'b0010101011,
               CONTROL_10 = 10'b0101010100, CONTROL_11 = 10'b1010101011;

    function is_control(input [9:0] code);
        is_control = (code == CONTROL_00) || (code == CONTROL_01) || (code == CONTROL_10) || (code == CONTROL_11);
    endfunction

    // fake tv part 1 read one bit per lane in the middle of each bit
    reg [9:0] window [0:2];        // last 10 bits of each lane, oldest at bit 0
    integer pair_mismatches = 0;
    integer lane;

    // part 2 find where words start, its wherever lane 0 keeps showing control codes
    integer bit_count = 0;          // bits read so far
    integer phase = -1;             // which of the 10 bit positions words start at, -1 = not found yet
    integer control_streak [0:9];   // control codes in a row seen at each position
    integer i;
    initial for (i = 0; i < 10; i = i + 1) control_streak[i] = 0;

    // part 3 rebuild the frame from the words
    reg was_vsync = 0, was_hsync = 0, was_visible = 0;
    integer frames_seen = 0;        // vsync pulses seen
    integer row = -1, column = 0;   // spot in the frame being rebuilt, row -1 = before the first visible row
    integer visible_rows = 0, hsyncs = 0, vsyncs = 0, short_rows = 0, wrong_pixels = 0, checked_pixels = 0;
    reg [9:0] word0, word1, word2;
    reg [23:0] got, want;

    always @(display.serial_clk) begin
        #0.6734;   // middle of the bit
        for (lane = 0; lane < 3; lane = lane + 1) begin
            window[lane] = {tmds_data_p[lane], window[lane][9:1]};
            if (tmds_data_n[lane] !== ~tmds_data_p[lane]) pair_mismatches = pair_mismatches + 1;
        end
        bit_count = bit_count + 1;

        if (phase < 0) begin
            // still looking, 60 control codes in a row at one position = found
            if (is_control(window[0])) control_streak[bit_count % 10] = control_streak[bit_count % 10] + 1;
            else                       control_streak[bit_count % 10] = 0;
            if (control_streak[bit_count % 10] >= 60) phase = bit_count % 10;
        end else if (bit_count % 10 == phase) begin
            word0 = window[0]; word1 = window[1]; word2 = window[2];
            take_word;
        end
    end

    task take_word;
        reg vs, hs, vis;
        begin
            vis = !is_control(word0);
            vs = (word0 == CONTROL_10) || (word0 == CONTROL_11);
            hs = (word0 == CONTROL_01) || (word0 == CONTROL_11);

            if (vs && !was_vsync) begin   // new frame
                frames_seen = frames_seen + 1;
                row = -1;
                if (frames_seen == 2) vsyncs = vsyncs + 1;
            end
            if (hs && !was_hsync && frames_seen == 1) hsyncs = hsyncs + 1;

            if (vis && !was_visible) begin   // new visible row
                row = row + 1;
                column = 0;
                if (frames_seen == 1) visible_rows = visible_rows + 1;
            end
            if (!vis && was_visible && frames_seen == 1 && column != 1280) short_rows = short_rows + 1;

            if (vis && frames_seen == 1) begin
                got = {decode(word2), decode(word1), decode(word0)};   // red green blue
                want = expected_color(column, row);
                if (got !== want) begin
                    if (wrong_pixels < 5) $display("        wrong pixel at x %0d, y %0d: got %h, expected %h", column, row, got, want);
                    wrong_pixels = wrong_pixels + 1;
                end
                checked_pixels = checked_pixels + 1;
            end
            if (vis) column = column + 1;

            was_vsync = vs; was_hsync = hs; was_visible = vis;
        end
    endtask

    // check helper
    integer failures = 0;

    task check(input string what, input integer got_value, input integer expected);
        if (got_value == expected) begin
            $display("  ok    %0s: %0d", what, got_value);
        end else begin
            $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected);
            failures = failures + 1;
        end
    endtask

    // the test, runs until one whole frame has been seen
    initial begin
        $display("display_top test: the whole display, read off the HDMI wires (about 2 frames, takes a while)");

        fork
            begin wait (frames_seen == 2); end
            begin #40_000_000; end   // give up after 40 ms of sim time
        join_any

        $display("Finding the words:");
        check("word boundary found (1 = yes)", (phase >= 0), 1);
        $display("One whole frame, rebuilt from the wires:");
        check("visible rows", visible_rows, 720);
        check("rows that weren't exactly 1280 pixels", short_rows, 0);
        check("hsync pulses (one per row)", hsyncs, 750);
        check("next vsync arrived (one per frame)", vsyncs, 1);
        check("pixels checked", checked_pixels, 1280 * 720);
        check("pixels with the wrong color", wrong_pixels, 0);
        $display("Wire pairs:");
        check("times a - wire wasn't the opposite of its + wire", pair_mismatches, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

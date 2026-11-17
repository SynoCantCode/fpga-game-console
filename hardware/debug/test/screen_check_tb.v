// screen_check_tb.v
// runs the screen check with the real video timing and a known picture
// starts a capture mid frame, reads all 720 row sums and compares, then again with a changed picture
`timescale 1ns / 1ps

module screen_check_tb;

    reg pixel_clk = 0, dev_clk = 0;
    always #6.74 pixel_clk = ~pixel_clk;        // 74.2 MHz
    always #4.85 dev_clk = ~dev_clk;            // about 103 MHz, unrelated
    reg pixel_reset = 1, dev_reset = 1;

    wire [10:0] x;  wire [9:0] y;  wire visible, hsync, vsync;
    video_timing timing (.clk(pixel_clk), .reset(pixel_reset), .x(x), .y(y), .visible(visible), .hsync(hsync),
                         .vsync(vsync));

    reg [7:0] twist = 0;                         // changes the picture for the second capture
    wire [7:0] red = x + 3 * y + twist, green = x ^ y, blue = 5 * x + y;

    reg reg_write = 0, reg_read = 0;  reg [4:0] reg_offset = 0;  reg [31:0] reg_wdata = 0;  wire [31:0] reg_rdata;
    screen_check check (
        .pixel_clk(pixel_clk), .pixel_reset(pixel_reset), .visible(visible), .vsync(vsync),
        .red(red), .green(green), .blue(blue),
        .dev_clk(dev_clk), .dev_reset(dev_reset), .reg_write(reg_write), .reg_read(reg_read),
        .reg_offset(reg_offset), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata));

    task write_reg(input [4:0] off, input [31:0] v);
        begin
            @(posedge dev_clk); reg_write <= 1; reg_offset <= off; reg_wdata <= v;
            @(posedge dev_clk); reg_write <= 0;
        end
    endtask
    task read_reg(input [4:0] off, output [31:0] v);
        begin
            @(posedge dev_clk); reg_read <= 1; reg_offset <= off;
            @(posedge dev_clk); reg_read <= 0;
            @(posedge dev_clk); v = reg_rdata;
        end
    endtask

    // what one rows sum should be
    function [31:0] row_sum(input integer yy, input [7:0] tw);
        integer xx;  reg [31:0] s;  reg [7:0] r, g, b;
        begin
            s = 0;
            for (xx = 0; xx < 1280; xx = xx + 1) begin
                r = xx + 3 * yy + tw;  g = xx ^ yy;  b = 5 * xx + yy;
                s = s + {8'd0, r, g, b};
            end
            row_sum = s;
        end
    endfunction

    integer failures = 0, row, k;
    reg [31:0] v;

    task capture_and_check(input [7:0] tw, input [8*16-1:0] label);
        integer wrong;
        begin
            wrong = 0;
            write_reg(5'h00, 1);                                 // start
            read_reg(5'h04, v);
            if (v[0]) begin $display("  FAIL  DONE still set right after START"); failures = failures + 1; end
            v = 0;
            while (!v[0]) read_reg(5'h04, v);                    // wait for done
            for (row = 0; row < 720; row = row + 1) begin
                write_reg(5'h08, row);
                read_reg(5'h0C, v);
                read_reg(5'h0C, v);
                if (v !== row_sum(row, tw)) begin
                    if (wrong < 5) $display("        row %0d: got %h, expected %h", row, v, row_sum(row, tw));
                    wrong = wrong + 1;
                end
            end
            $display("  %s  %0s: rows whose sum is wrong: %0d of 720", wrong ? "FAIL" : "ok  ", label, wrong);
            failures = failures + wrong;
        end
    endtask

    initial begin
        $display("screen_check test: the real 720p timing, a known picture, an unrelated device clock");
        repeat (10) @(posedge pixel_clk);
        pixel_reset = 0;
        repeat (10) @(posedge dev_clk);
        dev_reset = 0;
        wait (y == 300);                                       // start partway through a frame
        capture_and_check(8'd0, "first capture");
        twist = 8'd77;                                         // different picture from now on
        wait (y == 500);
        capture_and_check(8'd77, "second capture");
        if (failures == 0) $display("PASSED: every check is right");
        else $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end
endmodule

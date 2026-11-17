// tmds_encoder_tb.v
// decodes everything the encoder sends like a tv would
// checks all 256 colors come back, the 4 control codes are right, and the 1s and 0s stay balanced
`timescale 1ns / 1ps

module tmds_encoder_tb;

    // the block being tested
    reg clk = 0;
    // no starting values so the first real value counts as a change
    reg visible;
    reg [7:0] color;
    reg [1:0] control;
    wire [9:0] tmds;

    tmds_encoder encoder (.clk(clk), .visible(visible), .color(color), .control(control), .tmds(tmds));

    always #6.734 clk = ~clk;   // 74.25 MHz

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

    // tv side, decode a 10 bit color code back to 8 bits
    function [7:0] decode(input [9:0] code);
        reg [7:0] d;
        integer k;
        begin
            d = code[9] ? ~code[7:0] : code[7:0];          // bit 9 undo the flip
            decode[0] = d[0];
            for (k = 1; k < 8; k = k + 1)                  // bit 8 undo method A or B
                decode[k] = code[8] ? (d[k] ^ d[k-1]) : ~(d[k] ^ d[k-1]);
        end
    endfunction

    // 1s minus 0s in one 10 bit code
    function integer balance_of(input [9:0] code);
        integer k;
        begin
            balance_of = 0;
            for (k = 0; k < 10; k = k + 1) balance_of = balance_of + (code[k] ? 1 : -1);
        end
    endfunction

    // send one pixel, set the inputs between ticks then read the code just after the next tick
    task send_pixel(input is_visible, input [7:0] c, input [1:0] ctrl);
        begin
            @(negedge clk);
            visible = is_visible; color = c; control = ctrl;
            @(posedge clk); #1;   // the encoder took it on this edge, tmds is now its code
        end
    endtask

    // the test
    integer n, wrong_colors, running, worst;
    reg [9:0] expected_control [0:3];

    initial begin
        $display("tmds_encoder test");

        // the control codes
        expected_control[0] = 10'b1101010100;
        expected_control[1] = 10'b0010101011;
        expected_control[2] = 10'b0101010100;
        expected_control[3] = 10'b1010101011;
        $display("Control codes (hidden parts):");
        for (n = 0; n < 4; n = n + 1) begin
            send_pixel(0, 8'h00, n[1:0]);
            check($sformatf("control %0d%0d gives the standard code", n[1], n[0]), tmds, expected_control[n]);
        end

        // colors, every value then a long stretch of random ones
        wrong_colors = 0; running = 0; worst = 0;
        for (n = 0; n < 256 + 20000; n = n + 1) begin
            send_pixel(1, (n < 256) ? n[7:0] : $random, 2'b00);
            if (decode(tmds) != color) wrong_colors = wrong_colors + 1;
            running = running + balance_of(tmds);
            if (running > worst) worst = running;
            if (-running > worst) worst = -running;
        end
        $display("Colors (all 256, then 20,000 random):");
        check("colors that decode wrong", wrong_colors, 0);
        check("running balance never more than 10 off (1 = still within)", (worst <= 10), 1);
        $display("        (worst balance seen: %0d)", worst);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

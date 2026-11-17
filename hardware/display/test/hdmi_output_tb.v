// hdmi_output_tb.v
// feeds each lane 2 codes taking turns, then reads the wires bit by bit like a tv
// checks the codes come out in order on the right lane, the - wires are opposite, and the clock lane carries the pixel clock
`timescale 1ns / 1ps

module hdmi_output_tb;

    // gowins global reset, the sim models need it (1 = not resetting)
    GSR GSR (.GSRI(1'b1));

    // clocks, the serial one is 5x the pixel one
    reg pixel_clk = 0;
    reg serial_clk = 0;
    always #6.734  pixel_clk  = ~pixel_clk;
    always #1.3468 serial_clk = ~serial_clk;

    // the block being tested
    reg reset = 1;
    reg [9:0] blue_code = 0, green_code = 0, red_code = 0;
    wire [2:0] data_p, data_n;
    wire clock_p, clock_n;

    hdmi_output out (
        .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset(reset),
        .blue_code(blue_code), .green_code(green_code), .red_code(red_code),
        .data_p(data_p), .data_n(data_n), .clock_p(clock_p), .clock_n(clock_n)
    );

    // 2 test codes per lane, all different so a swapped lane is caught
    localparam BLUE_A  = 10'b1101010100, BLUE_B  = 10'b0010101011;
    localparam GREEN_A = 10'b0000011111, GREEN_B = 10'b1010000001;
    localparam RED_A   = 10'b1110001100, RED_B   = 10'b0001100111;

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

    // the tv, reads every bit in the middle of its slot
    // keeps the last 20 bits of each lane, oldest at bit 0
    reg [19:0] window [0:2];
    integer found_blue = 0, found_green = 0, found_red = 0, pair_mismatches = 0, clock_mismatches = 0;
    reg listening = 0;
    integer lane;

    always @(serial_clk) begin
        #0.6734;   // middle of the bit
        if (listening) begin
            for (lane = 0; lane < 3; lane = lane + 1) begin
                window[lane] = {data_p[lane], window[lane][19:1]};
                if (data_n[lane] !== ~data_p[lane]) pair_mismatches = pair_mismatches + 1;
            end
            if (window[0] == {BLUE_B, BLUE_A})   found_blue  = found_blue + 1;
            if (window[1] == {GREEN_B, GREEN_A}) found_green = found_green + 1;
            if (window[2] == {RED_B, RED_A})     found_red   = found_red + 1;
            if (clock_p !== pixel_clk || clock_n !== ~pixel_clk) clock_mismatches = clock_mismatches + 1;
        end
    end

    // the test
    integer n;

    initial begin
        $display("hdmi_output test: 200 pixels, each lane taking turns between its two codes");

        repeat (4) @(posedge pixel_clk);
        reset = 0;
        repeat (4) @(posedge pixel_clk);   // let the serializers start up
        listening = 1;

        for (n = 0; n < 200; n = n + 1) begin
            @(negedge pixel_clk);
            blue_code  = n[0] ? BLUE_B  : BLUE_A;
            green_code = n[0] ? GREEN_B : GREEN_A;
            red_code   = n[0] ? RED_B   : RED_A;
        end
        repeat (4) @(posedge pixel_clk);   // let the last pixels come out
        listening = 0;

        // a few pairs at the start are lost while the serializer fills up
        $display("Lanes (each A-then-B pair seen on the wire, bit 0 first):");
        check("blue lane 0 pairs seen (98 or more = 1)",  (found_blue  >= 98), 1);
        check("green lane 1 pairs seen (98 or more = 1)", (found_green >= 98), 1);
        check("red lane 2 pairs seen (98 or more = 1)",   (found_red   >= 98), 1);
        $display("        (seen: blue %0d, green %0d, red %0d)", found_blue, found_green, found_red);
        $display("Wire pairs:");
        check("times a - wire wasn't the opposite of its + wire", pair_mismatches, 0);
        check("times the clock lane didn't match the pixel clock", clock_mismatches, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

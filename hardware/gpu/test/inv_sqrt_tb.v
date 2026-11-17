// inv_sqrt_tb.v
// test for the inverse square root unit, every number checked against the reference model
// the line stops at random to check nothing moves or gets lost while it waits
`timescale 1ns/1ps
module inv_sqrt_tb;
    reg clk = 0; always #5 clk = !clk;
    localparam MAX = 40000;
    reg [55:0] v_list [0:MAX-1];
    reg [31:0] y_list [0:MAX-1];
    reg [7:0] half_list [0:MAX-1];
    reg [55:0] v; reg valid_in = 0; reg advance = 0;
    wire [30:0] y; wire [5:0] half; wire valid_out;
    inv_sqrt dut (.clk(clk), .advance(advance), .v(v), .valid_in(valid_in), .y(y), .half(half), .valid_out(valid_out));
    integer fd, n = 0, sent = 0, got = 0, bad = 0, r, seed = 5;
    reg [55:0] a; reg [31:0] b; reg [7:0] c;
    initial begin
        // load the numbers and the expected answers
        fd = $fopen("build/light/inv_sqrt_vectors.hex", "r");
        while (!$feof(fd) && n < MAX) begin
            r = $fscanf(fd, "%h %h %h\n", a, b, c);
            if (r == 3) begin v_list[n] = a; y_list[n] = b; half_list[n] = c; n = n + 1; end
        end
        $fclose(fd);
        v = 1;
        // send one number per moving clock and check each answer
        while (got < n) begin
            @(negedge clk);
            advance = ($random(seed) & 3) != 0;
            if (advance) begin
                if (sent < n) begin v = v_list[sent]; valid_in = 1; sent = sent + 1; end
                else begin v = 1; valid_in = 0; end
            end
            @(posedge clk); #1;
            if (advance && valid_out) begin
                if (y !== y_list[got][30:0] || half !== half_list[got][5:0]) begin
                    bad = bad + 1;
                    if (bad <= 5) $display("  v %h: got y %h half %0d, want y %h half %0d", v_list[got], y, half, y_list[got], half_list[got]);
                end
                got = got + 1;
            end
        end
        $display("inv_sqrt: %0d numbers, %0d different from light_model.py: %s", n, bad, bad == 0 ? "PASS" : "FAIL");
        if (bad == 0) $display("PASSED: every check is right"); else $display("FAILED: %0d wrong", bad);
        $finish;
    end
endmodule

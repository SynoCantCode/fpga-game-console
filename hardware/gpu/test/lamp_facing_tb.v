// lamp_facing_tb.v
// test for how much a corner faces a lamp and the distance squared, checked against the reference model
// the line stops at random
`timescale 1ns/1ps
module lamp_facing_tb;
    reg clk = 0; always #5 clk = !clk;
    localparam MAX = 40000;
    reg [15:0] nx_l [0:MAX-1]; reg [15:0] ny_l [0:MAX-1]; reg [15:0] nz_l [0:MAX-1];
    reg [31:0] cx_l [0:MAX-1]; reg [31:0] cy_l [0:MAX-1]; reg [31:0] cz_l [0:MAX-1];
    reg [31:0] lx_l [0:MAX-1]; reg [31:0] ly_l [0:MAX-1]; reg [31:0] lz_l [0:MAX-1];
    reg [15:0] f_l [0:MAX-1]; reg [55:0] d2_l [0:MAX-1];
    reg [15:0] nx, ny, nz; reg [31:0] cx, cy, cz, lx, ly, lz; reg valid_in = 0, advance = 0;
    wire [14:0] facing; wire [55:0] d2; wire valid_out;
    lamp_facing dut (.clk(clk), .advance(advance), .valid_in(valid_in),
        .normal_x(nx), .normal_y(ny), .normal_z(nz), .corner_x(cx), .corner_y(cy), .corner_z(cz),
        .lamp_x(lx), .lamp_y(ly), .lamp_z(lz), .facing(facing), .d2(d2), .valid_out(valid_out));
    integer fd, n = 0, sent = 0, got = 0, bad = 0, r, seed = 3, lit = 0;
    reg [15:0] a1, a2, a3, a10; reg [31:0] a4, a5, a6, a7, a8, a9; reg [55:0] a11;
    initial begin
        // load the corners and the expected answers
        fd = $fopen("build/light/lamp_facing_vectors.hex", "r");
        while (!$feof(fd) && n < MAX) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h\n", a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11);
            if (r == 11) begin
                nx_l[n] = a1; ny_l[n] = a2; nz_l[n] = a3; cx_l[n] = a4; cy_l[n] = a5; cz_l[n] = a6;
                lx_l[n] = a7; ly_l[n] = a8; lz_l[n] = a9; f_l[n] = a10; d2_l[n] = a11; n = n + 1;
            end
        end
        $fclose(fd);
        {nx, ny, nz, cx, cy, cz, lx, ly, lz} = 0;
        // send one corner per moving clock and check each answer
        while (got < n) begin
            @(negedge clk);
            advance = ($random(seed) & 3) != 0;
            if (advance) begin
                if (sent < n) begin
                    nx = nx_l[sent]; ny = ny_l[sent]; nz = nz_l[sent]; cx = cx_l[sent]; cy = cy_l[sent]; cz = cz_l[sent];
                    lx = lx_l[sent]; ly = ly_l[sent]; lz = lz_l[sent]; valid_in = 1; sent = sent + 1;
                end else valid_in = 0;
            end
            @(posedge clk); #1;
            if (advance && valid_out) begin
                if (facing !== f_l[got][14:0] || d2 !== d2_l[got]) begin
                    bad = bad + 1;
                    if (bad <= 5) $display("  corner %0d: got facing %0d d2 %h, want %0d %h", got, facing, d2, f_l[got], d2_l[got]);
                end
                if (f_l[got] != 0) lit = lit + 1;
                got = got + 1;
            end
        end
        $display("lamp_facing: %0d corners (%0d facing the lamp), %0d different from light_model.py: %s", n, lit, bad, bad == 0 ? "PASS" : "FAIL");
        if (bad == 0) $display("PASSED: every check is right"); else $display("FAILED: %0d wrong", bad);
        $finish;
    end
endmodule

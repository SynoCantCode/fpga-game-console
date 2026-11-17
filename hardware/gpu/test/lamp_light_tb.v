// lamp_light_tb.v
// test for one lamps light on each corner, checked against the reference model
// the position goes in first and the normal two moving clocks later
// the line stops at random
`timescale 1ns/1ps
module lamp_light_tb;
    reg clk = 0; always #5 clk = !clk;
    reg advance = 0, valid_in = 0, table_write = 0;
    reg [31:0] cx = 0, cy = 0, cz = 0, lx = 0, ly = 0, lz = 0; reg [15:0] nx = 0, ny = 0, nz = 0;
    reg [23:0] colour = 0; reg [3:0] range = 0; reg [7:0] table_row = 0; reg [15:0] table_word = 0;
    wire [22:0] ar, ag, ab; wire valid_out;
    lamp_light dut (.clk(clk), .advance(advance), .valid_in(valid_in), .corner_x(cx), .corner_y(cy), .corner_z(cz),
        .normal_x(nx), .normal_y(ny), .normal_z(nz), .lamp_x(lx), .lamp_y(ly), .lamp_z(lz), .lamp_colour(colour),
        .range(range), .table_write(table_write), .table_row(table_row), .table_word(table_word),
        .amount_red(ar), .amount_green(ag), .amount_blue(ab), .valid_out(valid_out));
    localparam MAX = 64;
    reg [15:0] qn [0:MAX-1][0:2];          // each corners normal, given two moving clocks after its position
    reg [22:0] want [0:MAX-1][0:2];
    reg qv [0:MAX-1];
    integer fd, r, sent = 0, got = 0, moves = 0, bad = 0, lit = 0, seed = 17, i;
    reg [7:0] c; reg [31:0] a1, a2, a3; reg [23:0] a4; reg [15:0] b1, b2, b3; reg [22:0] e1, e2, e3;
    // one clock, put_corner = a new corner enters on it
    task tick(input put_corner); begin
        @(negedge clk);
        advance = put_corner ? 1'b1 : (($random(seed) & 3) != 0);
        valid_in = put_corner;
        if (advance) begin
            // the normal of the corner that entered two moves ago
            if (moves >= 2 && qv[(moves - 2) % MAX]) begin
                nx = qn[(moves - 2) % MAX][0]; ny = qn[(moves - 2) % MAX][1]; nz = qn[(moves - 2) % MAX][2];
            end
            qv[moves % MAX] = put_corner;
            if (put_corner) begin qn[moves % MAX][0] = b1; qn[moves % MAX][1] = b2; qn[moves % MAX][2] = b3;
                want[sent % MAX][0] = e1; want[sent % MAX][1] = e2; want[sent % MAX][2] = e3;
                cx = a1; cy = a2; cz = a3; sent = sent + 1; end
        end
        @(posedge clk); #1;
        if (advance) begin
            moves = moves + 1;
            if (valid_out) begin
                if ({ar, ag, ab} !== {want[got % MAX][0], want[got % MAX][1], want[got % MAX][2]}) begin
                    bad = bad + 1;
                    if (bad <= 5) $display("  corner %0d: got %0d %0d %0d, want %0d %0d %0d", got, ar, ag, ab,
                                           want[got % MAX][0], want[got % MAX][1], want[got % MAX][2]);
                end
                if (want[got % MAX][0] != 0 || want[got % MAX][1] != 0 || want[got % MAX][2] != 0) lit = lit + 1;
                got = got + 1;
            end
        end
    end endtask
    task drain; begin while (got < sent) tick(0); repeat (3) tick(0); end endtask
    initial begin
        for (i = 0; i < MAX; i = i + 1) qv[i] = 0;
        fd = $fopen("build/light/lamp_light_vectors.txt", "r");
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%c", c);
            // W = table write, L = lamp settings, C = corner
            if (c == "W") begin
                r = $fscanf(fd, " %h %h\n", a1, a2);
                // tables and settings only change with nothing in flight
                if (sent != got) drain;
                @(negedge clk); advance = 0; table_write = 1; table_row = a1[7:0]; table_word = a2[15:0];
                @(negedge clk); table_write = 0;
            end else if (c == "L") begin
                r = $fscanf(fd, " %h %h %h %h %h\n", a1, a2, a3, a4, e1);
                if (sent != got) drain;
                lx = a1; ly = a2; lz = a3; colour = a4; range = e1[3:0];
            end else if (c == "C") begin
                r = $fscanf(fd, " %h %h %h %h %h %h %h %h %h\n", a1, a2, a3, b1, b2, b3, e1, e2, e3);
                while (($random(seed) & 3) == 0) tick(0);
                tick(1);
            end
        end
        $fclose(fd);
        drain;
        $display("lamp_light: %0d corners (%0d lit), %0d different from light_model.py: %s", got, lit, bad, bad == 0 ? "PASS" : "FAIL");
        if (bad == 0) $display("PASSED: every check is right"); else $display("FAILED: %0d wrong", bad);
        $finish;
    end
endmodule

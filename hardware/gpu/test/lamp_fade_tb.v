// lamp_fade_tb.v
// test for a lamps fade from its table, checked against the reference model
// table writes and range changes only happen with nothing in flight
// the line stops at random
`timescale 1ns/1ps
module lamp_fade_tb;
    reg clk = 0; always #5 clk = !clk;
    reg advance = 0, valid_in = 0, table_write = 0;
    reg [55:0] d2 = 1; reg signed [3:0] range = 0; reg [7:0] table_row = 0; reg [15:0] table_word = 0;
    wire [8:0] fade; wire valid_out;
    lamp_fade dut (.clk(clk), .advance(advance), .valid_in(valid_in), .d2(d2), .range(range),
        .table_write(table_write), .table_row(table_row), .table_word(table_word), .fade(fade), .valid_out(valid_out));
    localparam MAX = 64;                                  // most corners in flight at once
    reg [8:0] want [0:MAX-1];
    integer fd, r, sent = 0, got = 0, bad = 0, seed = 11, nonzero = 0, partial = 0;
    reg [7:0] c; reg [55:0] a; reg [15:0] b;
    // one clock that moves at random, check a corner if one comes out
    task step; begin
        @(negedge clk);
        advance = ($random(seed) & 3) != 0;
        @(posedge clk); #1;
        if (advance && valid_out) begin
            if (fade !== want[got % MAX]) begin
                bad = bad + 1;
                if (bad <= 5) $display("  corner %0d: got fade %0d, want %0d", got, fade, want[got % MAX]);
            end
            if (want[got % MAX] != 0) nonzero = nonzero + 1;
            if (want[got % MAX] != 0 && want[got % MAX] != 256) partial = partial + 1;
            got = got + 1;
        end
    end endtask
    // let everything in flight come out
    task drain; begin
        valid_in = 0;
        while (got < sent) step;
        @(negedge clk); advance = 0;
    end endtask
    initial begin
        fd = $fopen("build/light/lamp_fade_vectors.txt", "r");
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%c", c);
            // W = table write, R = range, C = corner
            if (c == "W") begin
                r = $fscanf(fd, " %h %h\n", a, b);
                if (sent != got) drain;
                @(negedge clk); advance = 0; table_write = 1; table_row = a[7:0]; table_word = b;
                @(negedge clk); table_write = 0;
            end else if (c == "R") begin
                r = $fscanf(fd, " %h\n", a);
                if (sent != got) drain;
                range = a[3:0];
            end else if (c == "C") begin
                r = $fscanf(fd, " %h %h\n", a, b);
                // wait for a clock that moves then put the corner in
                @(negedge clk);
                while (($random(seed) & 3) == 0) begin advance = 0; valid_in = 0; @(posedge clk); #1;
                    @(negedge clk); end
                advance = 1; valid_in = 1; d2 = a; want[sent % MAX] = b[8:0]; sent = sent + 1;
                @(posedge clk); #1;
                if (valid_out) begin
                    if (fade !== want[got % MAX]) begin
                        bad = bad + 1;
                        if (bad <= 5) $display("  corner %0d: got fade %0d, want %0d", got, fade, want[got % MAX]);
                    end
                    if (want[got % MAX] != 0) nonzero = nonzero + 1;
                    if (want[got % MAX] != 0 && want[got % MAX] != 256) partial = partial + 1;
                    got = got + 1;
                end
            end
        end
        $fclose(fd);
        drain;
        $display("lamp_fade: %0d corners (%0d lit, %0d partly), %0d different from light_model.py: %s", got, nonzero,
                 partial, bad, bad == 0 ? "PASS" : "FAIL");
        if (bad == 0) $display("PASSED: every check is right"); else $display("FAILED: %0d wrong", bad);
        $finish;
    end
endmodule

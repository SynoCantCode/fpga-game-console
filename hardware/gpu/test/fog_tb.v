// fog_tb.v
// test for the fog unit, checked quad by quad against the reference model
// a new quad goes in every clock, its q first and its pixel colours later
// the table and fog colour change between groups while the unit is empty
`timescale 1ns / 1ps

module fog_tb;

    localparam WAIT = 12, MAX_GROUPS = 64, MAX_QUADS = 65536;
    localparam LATE = WAIT + 4;                    // pixels come this many clocks after their q
    localparam OUT = 3;                            // fogged pixels come this many clocks after the pixels

    reg clk = 0;
    always #5 clk = ~clk;

    reg [4119:0] tables [0:MAX_GROUPS-1];
    reg [171:0] quads [0:MAX_QUADS-1];
    reg [127:0] expected [0:MAX_QUADS-1];
    integer n_quads;

    reg [31:0] q_in = 0;  reg fogged_in = 0;  reg [127:0] pixels_in = 0;
    wire [127:0] pixels_out;
    reg [23:0] fog_colour = 0;
    reg table_write = 0;  reg [7:0] table_row = 0;  reg [15:0] table_word = 0;

    fog #(.WAIT(WAIT)) unit (
        .clk(clk), .q_in(q_in), .fogged_in(fogged_in), .pixels_in(pixels_in), .pixels_out(pixels_out),
        .fog_colour(fog_colour), .table_write(table_write), .table_row(table_row), .table_word(table_word)
    );

    task tick;
        begin @(posedge clk); #1; end
    endtask

    integer group, first, last, t, r, checked = 0, wrong = 0, changed = 0;
    initial begin
        $readmemh("build/fog/fog_tables.hex", tables);
        $readmemh("build/fog/fog_quads.hex", quads);
        $readmemh("build/fog/fog_expected.hex", expected);
        n_quads = 0;
        while (n_quads < MAX_QUADS && quads[n_quads] !== 172'bx) n_quads = n_quads + 1;
        $display("fog test: %0d quads", n_quads);
        first = 0;
        while (first < n_quads) begin
            // this group is quads first to last
            group = quads[first][7:0];
            last = first;
            while (last + 1 < n_quads && quads[last + 1][7:0] == group) last = last + 1;
            // write its table and fog colour, the unit is empty now
            fog_colour = tables[group][4119:4096];
            for (r = 0; r < 256; r = r + 1) begin
                table_write = 1;  table_row = r[7:0];  table_word = tables[group][16 * r +: 16];
                tick;
            end
            table_write = 0;
            changed = changed + 1;
            // clock t, quad first+t gives its q, quad first+t-LATE gives its pixels
            // and the fogged pixels of quad first+t-LATE-OUT have come out
            for (t = 0; t <= (last - first) + LATE + OUT; t = t + 1) begin
                if (first + t <= last) begin
                    q_in = quads[first + t][40:9];  fogged_in = quads[first + t][8];
                end else begin
                    q_in = 0;  fogged_in = 0;
                end
                if (t >= LATE && first + t - LATE <= last) pixels_in = quads[first + t - LATE][168:41];
                else pixels_in = 0;
                if (t >= LATE + OUT && first + t - LATE - OUT <= last) begin
                    if (pixels_out !== expected[first + t - LATE - OUT]) begin
                        wrong = wrong + 1;
                        if (wrong <= 10) $display("  WRONG quad %0d: got %h, the reference says %h", first + t - LATE - OUT,
                                                  pixels_out, expected[first + t - LATE - OUT]);
                    end
                    checked = checked + 1;
                end
                tick;
            end
            first = last + 1;
        end
        $display("  quads checked: %0d, wrong: %0d (tables set: %0d)", checked, wrong, changed);
        if (checked == n_quads && n_quads > 0 && wrong == 0) $display("PASSED: every check is right");
        else $display("FAILED");
        $finish;
    end

endmodule

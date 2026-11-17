// lighting_tb.v
// test for the light unit, checked corner by corner against the reference model
// the line stalls at random and nothing may move then
// settings only change while the unit is empty
`timescale 1ns / 1ps

module lighting_tb;

    localparam MAX_GROUPS = 256, MAX_CORNERS = 65536, LATENCY = 23;   // LATENCY = how many stations the light unit has

    reg clk = 0;
    always #5 clk = ~clk;

    reg [703:0] settings [0:MAX_GROUPS-1];
    reg [103:0] corner_list [0:MAX_CORNERS-1];
    reg [31:0] expected [0:MAX_CORNERS-1];
    integer n_corners;

    reg advance = 0;
    reg [29:0] normal_in = 0;  reg [31:0] colour_in = 0;  reg lit_in = 0;  reg [31:0] scale_in = 0;
    reg [287:0] turn = 0;  reg [23:0] ambient = 0;  reg [191:0] sun_dirs = 0;  reg [95:0] sun_cols = 0;
    wire [31:0] colour_out;

    lighting unit (
        .clk(clk), .advance_a(advance), .advance_b(advance),
        .normal_in(normal_in), .colour_in(colour_in), .lit_in(lit_in), .normal_scale_in(scale_in),
        .turn(turn), .ambient(ambient), .sun_directions(sun_dirs), .sun_colours(sun_cols),
        .corner_x(32'sd0), .corner_y(32'sd0), .corner_z(32'sd0), .lamp_positions(192'd0), .lamp_colours(48'd0),
        .lamp_ranges(8'd0), .lamp_table_write(2'b00), .lamp_table_row(8'd0), .lamp_table_word(16'd0),   // lamps off, this test is just the suns
        .colour_out(colour_out)
    );

    // which stations hold a real corner, moves on advance like the unit
    reg [LATENCY:1] valid = 0;
    integer fed = 0, checked = 0, wrong = 0, stalls = 0, moved_while_stalled = 0;
    integer group, k, seed;
    reg [31:0] held_colour;

    task tick;
        begin @(posedge clk); #1; end
    endtask

    initial begin
        $readmemh("build/light/light_settings.hex", settings);
        $readmemh("build/light/light_corners.hex", corner_list);
        $readmemh("build/light/light_expected.hex", expected);
        n_corners = 0;
        while (n_corners < MAX_CORNERS && corner_list[n_corners] !== 104'bx) n_corners = n_corners + 1;
        $display("lighting test: %0d corners", n_corners);
        seed = 1;
        group = -1;
        while (checked < n_corners) begin
            // next corner, a new settings group only once the unit is empty
            if (fed < n_corners && corner_list[fed][7:0] != group && valid != 0) begin
                // let the unit empty out first
                normal_in = 0; colour_in = 0; lit_in = 0; scale_in = 0;
                advance = 1;
            end else begin
                if (fed < n_corners && corner_list[fed][7:0] != group) begin
                    group = corner_list[fed][7:0];
                    {sun_cols, sun_dirs, ambient, turn} = settings[group];
                end
                advance = ($random(seed) & 7) != 0;               // stall about 1 tick in 8
            end
            if (!advance) begin
                // stall, the output must not change
                stalls = stalls + 1;
                held_colour = colour_out;
                tick;
                if (colour_out !== held_colour) moved_while_stalled = moved_while_stalled + 1;
            end else begin
                // feed a corner if its in the current group, else an empty one
                if (fed < n_corners && corner_list[fed][7:0] == group) begin
                    {normal_in, colour_in, lit_in, scale_in} = corner_list[fed][102:8];
                    valid = {valid[LATENCY-1:1], 1'b1};
                    fed = fed + 1;
                end else begin
                    normal_in = 0; colour_in = 0; lit_in = 0; scale_in = 0;
                    valid = {valid[LATENCY-1:1], 1'b0};
                end
                tick;
                // what left the last station on this tick
                if (valid[LATENCY]) begin
                    if (colour_out !== expected[checked]) begin
                        wrong = wrong + 1;
                        if (wrong <= 10) $display("  WRONG corner %0d: got %h, the reference says %h", checked, colour_out,
                                                  expected[checked]);
                    end
                    checked = checked + 1;
                end
            end
        end
        $display("  corners checked: %0d, wrong: %0d", checked, wrong);
        $display("  stalls: %0d, the output changed during a stall: %0d", stalls, moved_while_stalled);
        if (checked == n_corners && n_corners > 0 && wrong == 0 && moved_while_stalled == 0 && stalls > 100)
            $display("PASSED: every check is right");
        else
            $display("FAILED");
        $finish;
    end

endmodule

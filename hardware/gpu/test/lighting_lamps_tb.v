// lighting_lamps_tb.v
// test for the light unit with the 2 lamps on, checked corner by corner against the reference model
// the line stalls at random and nothing may move then
// settings and lamp tables only change while the unit is empty
`timescale 1ns / 1ps

module lighting_lamps_tb;

    localparam MAX_GROUPS = 256, MAX_CORNERS = 65536, LATENCY = 23;   // LATENCY = how many stations the light unit has

    reg clk = 0;
    always #5 clk = ~clk;

    reg [951:0] settings [0:MAX_GROUPS-1];
    reg [199:0] corner_list [0:MAX_CORNERS-1];
    reg [15:0] lamp_tables [0:MAX_GROUPS*512-1];
    reg [31:0] expected [0:MAX_CORNERS-1];
    integer n_corners;

    reg advance = 0;
    reg [29:0] normal_in = 0;  reg [31:0] colour_in = 0;  reg lit_in = 0;  reg [31:0] scale_in = 0;
    reg [287:0] turn = 0;  reg [23:0] ambient = 0;  reg [191:0] sun_dirs = 0;  reg [95:0] sun_cols = 0;
    wire [31:0] colour_out;
    reg [191:0] lamp_pos = 0;  reg [47:0] lamp_cols = 0;  reg [7:0] lamp_rng = 0;
    reg [1:0] lt_write = 0;  reg [7:0] lt_row = 0;  reg [15:0] lt_word = 0;
    reg [95:0] pos_in = 0, pos_q1 = 0, pos_q2 = 0;   // the position enters station 3, so its the one fed two moves ago
    integer t_i;

    lighting unit (
        .clk(clk), .advance_a(advance), .advance_b(advance),
        .normal_in(normal_in), .colour_in(colour_in), .lit_in(lit_in), .normal_scale_in(scale_in),
        .turn(turn), .ambient(ambient), .sun_directions(sun_dirs), .sun_colours(sun_cols),
        .corner_x(pos_in[31:0]), .corner_y(pos_in[63:32]), .corner_z(pos_in[95:64]), .lamp_positions(lamp_pos),
        .lamp_colours(lamp_cols), .lamp_ranges(lamp_rng), .lamp_table_write(lt_write), .lamp_table_row(lt_row),
        .lamp_table_word(lt_word),
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
        $readmemh("build/light/lamp_settings.hex", settings);
        $readmemh("build/light/lamp_corners.hex", corner_list);
        $readmemh("build/light/lamp_expected.hex", expected);
        $readmemh("build/light/lamp_tables.hex", lamp_tables);
        n_corners = 0;
        while (n_corners < MAX_CORNERS && corner_list[n_corners] !== 200'bx) n_corners = n_corners + 1;
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
                    {lamp_rng, lamp_cols, lamp_pos, sun_cols, sun_dirs, ambient, turn} = settings[group];
                    // write the 2 lamp tables while the unit is empty
                    for (t_i = 0; t_i < 512; t_i = t_i + 1) begin
                        @(negedge clk); lt_write = (t_i < 256) ? 2'b01 : 2'b10; lt_row = t_i[7:0];
                        lt_word = lamp_tables[group * 512 + t_i];
                    end
                    @(negedge clk); lt_write = 2'b00;
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
                pos_in = pos_q2;                                   // the corner fed two moves ago enters station 3 now
                if (fed < n_corners && corner_list[fed][7:0] == group) begin
                    {normal_in, colour_in, lit_in, scale_in} = corner_list[fed][102:8];
                    pos_q2 = pos_q1; pos_q1 = corner_list[fed][198:103];
                    valid = {valid[LATENCY-1:1], 1'b1};
                    fed = fed + 1;
                end else begin
                    normal_in = 0; colour_in = 0; lit_in = 0; scale_in = 0;
                    pos_q2 = pos_q1; pos_q1 = 0;
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

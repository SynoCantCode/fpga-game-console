// projection_lights_tb.v
// test for lighting inside projection
// a random stream of matrix, sun lights and triangles while setup takes triangles at random moments
// every triangles colours must match the reference model for the matrix and lights it went in with
`timescale 1ns / 1ps

module projection_lights_tb;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    localparam MAX_OPS = 20000;
    localparam LIGHT_STATIONS = 23;               // must match the light units station count in projection.v
    reg [515:0] ops [0:MAX_OPS-1];
    reg [95:0] want [0:MAX_OPS-1];
    integer n_ops;

    reg matrix_valid = 0;  wire matrix_ready;  reg [415:0] matrix = 0;
    reg lights_valid = 0;  wire lights_ready;  reg [311:0] lights = 0;
    reg tri_valid = 0;     wire tri_ready;
    reg [287:0] corners = 0;  reg [95:0] colour_in = 0;  reg [3:0] switches_in = 0;  reg [89:0] normals_in = 0;
    reg lit_in = 0;
    wire out_valid;  reg out_ready = 0;
    wire signed [15:0] x0, y0, x1, y1, x2, y2;
    wire [31:0] z0, z1, z2;
    wire [95:0] colour;  wire [3:0] switches;  wire busy;
    wire [31:0] dropped_near, dropped_far;

    projection dut (
        .clk(clk), .reset(reset), .focal(16'd738), .near(32'h0001_0000),
        .matrix_valid(matrix_valid), .matrix_ready(matrix_ready), .matrix(matrix),
        .tri_valid(tri_valid), .tri_ready(tri_ready), .corners(corners), .colour_in(colour_in),
        .switches_in(switches_in), .normals_in(normals_in), .lit_in(lit_in), .fogged_in(1'b0), .textured_in(1'b0), .texture_slot_in(8'd0), .uvs_in(192'd0),
        .lights_valid(lights_valid), .lights_ready(lights_ready), .lights(lights), .lamps_valid(1'b0), .lamps_ready(), .lamps(256'd0), .lamp_table_write(2'b00), .lamp_table_row(8'd0), .lamp_table_word(16'd0),
        .out_valid(out_valid), .out_ready(out_ready),
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2), .z0(z0), .z1(z1), .z2(z2),
        .colour(colour), .switches(switches), .busy(busy),
        .dropped_near(dropped_near), .dropped_too_far_out(dropped_far)
    );

    integer got = 0, wrong = 0, lights_taken_while_busy = 0, n_tris = 0;

    // setups side, take at random moments and compare each triangles colours
    always @(posedge clk) begin
        out_ready <= ($urandom % 3 != 0);
        if (out_valid && out_ready) begin
            if (colour !== want[got]) begin
                if (wrong < 8) $display("  WRONG triangle %0d: colours %h, the reference says %h", got, colour, want[got]);
                wrong = wrong + 1;
            end
            got = got + 1;
        end
        // sun lights taken while a corner is still in the light unit would be a bug
        if (lights_valid && lights_ready && (dut.full[LIGHT_STATIONS:1] != 0)) lights_taken_while_busy = lights_taken_while_busy + 1;
    end

    integer i, t0;
    reg [3:0] kind;
    reg [511:0] rec;
    initial begin
        $readmemh("build/light/ops.hex", ops);
        $readmemh("build/light/colours.hex", want);
        n_ops = 0;
        while (n_ops < MAX_OPS && ops[n_ops] !== 516'bx) begin
            if (ops[n_ops][3:0] == 4'h2) n_tris = n_tris + 1;
            n_ops = n_ops + 1;
        end
        $display("projection + lighting test: %0d records, %0d triangles", n_ops, n_tris);
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;
        for (i = 0; i < n_ops; i = i + 1) begin
            kind = ops[i][3:0];
            rec = ops[i][515:4];
            // one record at a time, held until projection takes it
            if (kind == 4'h1) begin
                matrix = rec[415:0];  matrix_valid = 1;
                @(posedge clk); while (!matrix_ready) @(posedge clk); #1;
                matrix_valid = 0;
            end else if (kind == 4'h6) begin
                lights = rec[311:0];  lights_valid = 1;
                @(posedge clk); while (!lights_ready) @(posedge clk); #1;
                lights_valid = 0;
            end else begin
                corners = rec[287:0];  colour_in = rec[383:288];  switches_in = rec[387:384];  lit_in = rec[388];
                normals_in = rec[481:392];  tri_valid = 1;
                @(posedge clk); while (!tri_ready) @(posedge clk); #1;
                tri_valid = 0;
            end
            if ($urandom % 4 == 0) begin @(posedge clk); #1; end     // a gap now and then
        end
        t0 = 0;
        while (got < n_tris && t0 < 10000) begin @(posedge clk); t0 = t0 + 1; end
        $display("  triangles out: %0d of %0d, wrong colours: %0d", got, n_tris, wrong);
        $display("  dropped (near / off the screen): %0d / %0d (should be 0 / 0)", dropped_near, dropped_far);
        $display("  SUN LIGHTS taken while a corner was in the light unit: %0d (should be 0)", lights_taken_while_busy);
        if (got == n_tris && n_tris > 0 && wrong == 0 && dropped_near == 0 && dropped_far == 0 && lights_taken_while_busy == 0)
            $display("PASSED: every check is right");
        else
            $display("FAILED");
        $finish;
    end

endmodule

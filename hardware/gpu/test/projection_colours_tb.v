// projection_colours_tb.v
// test that projection keeps each triangles 3 corner colours and texture numbers with the right triangle
// setup takes them at random moments and every 5th triangle gets dropped
`timescale 1ns / 1ps

module projection_colours_tb;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    reg matrix_valid = 0;
    wire matrix_ready;
    reg [415:0] matrix = 0;           // no lighting here
    reg tri_valid = 0;
    wire tri_ready;
    reg [287:0] corners = 0;
    reg [95:0] colour_in = 0;
    reg [3:0] switches_in = 4'b1111;
    reg textured_in = 0;  reg [7:0] texture_slot_in = 0;  reg [191:0] uvs_in = 0;
    wire textured;  wire [7:0] texture_slot;  wire [191:0] uvs;
    wire out_valid;
    reg out_ready = 0;
    wire signed [15:0] x0, y0, x1, y1, x2, y2;
    wire [31:0] z0, z1, z2;
    wire [95:0] colour;
    wire [3:0] switches;
    wire busy;
    wire [31:0] dropped_near, dropped_far;

    projection dut (
        .clk(clk), .reset(reset), .focal(16'd738), .near(32'h0001_0000),   // 52 degree view
        .matrix_valid(matrix_valid), .matrix_ready(matrix_ready), .matrix(matrix),
        .tri_valid(tri_valid), .tri_ready(tri_ready), .corners(corners), .colour_in(colour_in),
        .switches_in(switches_in), .normals_in(90'd0), .lit_in(1'b0), .fogged_in(1'b0), .textured_in(textured_in), .texture_slot_in(texture_slot_in), .uvs_in(uvs_in), .lights_valid(1'b0), .lights_ready(), .lights(312'd0), .lamps_valid(1'b0), .lamps_ready(), .lamps(256'd0), .lamp_table_write(2'b00), .lamp_table_row(8'd0), .lamp_table_word(16'd0),
        .out_valid(out_valid), .out_ready(out_ready),
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2), .z0(z0), .z1(z1), .z2(z2),
        .colour(colour), .switches(switches), .textured(textured), .texture_slot(texture_slot), .uvs(uvs), .busy(busy),
        .dropped_near(dropped_near), .dropped_too_far_out(dropped_far)
    );

    localparam N = 400;
    reg [95:0] sent [0:N-1];                  // colours of every triangle that should come out, in order
    reg [200:0] sent_texture [0:N-1];         // and its {textured, slot, u and v}
    integer kept = 0, dropped_sent = 0, got = 0, wrong = 0, failures = 0, texture_wrong = 0, textured_sent = 0;

    function [31:0] q16(input integer v);      // v units in Q16.16
        q16 = v * 65536;
    endfunction

    task check(input [8*60-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    // setups side, take at random moments and compare with what was sent
    always @(posedge clk) begin
        out_ready <= ($urandom % 3 != 0);
        if (out_valid && out_ready) begin
            if (colour !== sent[got]) begin
                if (wrong < 5) $display("  triangle %0d: colours %h, sent %h", got, colour, sent[got]);
                wrong = wrong + 1;
            end
            if ({textured, texture_slot, uvs} !== sent_texture[got]) begin
                if (texture_wrong < 5) $display("  triangle %0d: texture numbers %h, sent %h", got, {textured, texture_slot, uvs}, sent_texture[got]);
                texture_wrong = texture_wrong + 1;
            end
            got = got + 1;
        end
    end

    // the copies of advance inside projection must always equal the original
    // count stalls too so we know the line really stopped
    integer copy_wrong = 0, stalls = 0, gaps = 0;
    always @(posedge clk) if (!reset) begin
        if (dut.advance_c !== {8{dut.advance}}) begin
            if (copy_wrong < 5) $display("  copies of advance %b, advance %b", dut.advance_c, dut.advance);
            copy_wrong = copy_wrong + 1;
        end
        if (!dut.advance) stalls = stalls + 1;
    end

    integer i, k;
    reg [31:0] c [0:2];
    initial begin
        $display("projection colours test: %0d triangles with 3 different corner colours, every 5th dropped", N);
        repeat (3) @(posedge clk);
        reset = 0;
        // matrix with no turn, size 1, moved 5 units away
        @(posedge clk); #1;
        matrix = 0;
        matrix[0 * 32 +: 32] = q16(1);  matrix[5 * 32 +: 32] = q16(1);  matrix[10 * 32 +: 32] = q16(1);
        matrix[11 * 32 +: 32] = q16(5);
        matrix_valid = 1;
        while (!matrix_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        matrix_valid = 0;
        for (i = 0; i < N; i = i + 1) begin
            for (k = 0; k < 3; k = k + 1) c[k] = $urandom;
            colour_in = {c[2], c[1], c[0]};
            textured_in = $urandom;  texture_slot_in = $urandom;
            uvs_in = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
            corners = 0;
            corners[0 * 96 +: 32] = q16(-1);  corners[0 * 96 + 32 +: 32] = q16(-1);
            corners[1 * 96 +: 32] = q16(1);   corners[1 * 96 + 32 +: 32] = q16(-1);
            corners[2 * 96 +: 32] = q16(0);   corners[2 * 96 + 32 +: 32] = q16(1);
            if (i % 5 == 4) begin
                corners[1 * 96 + 64 +: 32] = q16(-10);       // corner 1 behind the camera so its dropped
                dropped_sent = dropped_sent + 1;
            end else begin
                sent[kept] = colour_in;
                sent_texture[kept] = {textured_in, texture_slot_in, uvs_in};
                textured_sent = textured_sent + textured_in;
                kept = kept + 1;
            end
            tri_valid = 1;
            @(posedge clk);
            while (!tri_ready) @(posedge clk);
            #1;
            // pause after about 1 triangle in 3 so there are empty stations between triangles
            if ($urandom % 3 == 0) begin
                tri_valid = 0;
                gaps = gaps + 1;
                repeat (1 + $urandom % 6) @(posedge clk);
                #1;
            end
        end
        tri_valid = 0;
        repeat (400) @(posedge clk);
        $display("Results:");
        check("triangles out", got, kept);
        check("triangles with the wrong colours", wrong, 0);
        check("wrong texture numbers (textured, slot, u, v)", texture_wrong, 0);
        if (textured_sent < 50 || textured_sent > kept - 50) begin $display("  FAIL  too few textured or plain triangles"); failures = failures + 1; end
        else $display("  ok    kept triangles that were textured: %0d of %0d", textured_sent, kept);
        check("triangles dropped (corner behind the camera)", dropped_near, dropped_sent);
        check("ticks where a copy of advance differs from it", copy_wrong, 0);
        if (stalls == 0) begin $display("  FAIL  the line never stopped: the copies were not tested"); failures = failures + 1; end
        else $display("  ok    ticks the line stopped (the copies tested through them): %0d", stalls);
        if (gaps == 0) begin $display("  FAIL  no pauses between triangles"); failures = failures + 1; end
        else $display("  ok    pauses between triangles: %0d", gaps);
        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

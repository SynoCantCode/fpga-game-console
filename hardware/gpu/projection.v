// projection.v
// turns a shapes 3d corners into screen corners for setup
// matrix times corner, drop it if its too close, divide by distance
// one corner per clock, then 3 corners get collected back into a triangle

module projection (
    input wire clk,
    input wire reset,

    // settings
    input wire [15:0] focal,                 // zoom, pixels per unit at distance 1
    input wire [31:0] near,                  // near limit Q16.16, must be under 2048

    // the matrix, 12 entries Q16.16, row i col j at bits (i*4 + j)*32
    input wire matrix_valid,
    output wire matrix_ready,
    input wire [415:0] matrix,                   // normal scale in the top 32 bits

    // triangle in, 3 corners of x y z Q16.16, corner k at bits k*96
    input wire tri_valid,
    output wire tri_ready,
    input wire [287:0] corners,
    input wire [95:0] colour_in,                       // corner k at bits 32*k
    input wire [3:0] switches_in,
    input wire [89:0] normals_in,                      // corner k at bits 30*k
    input wire lit_in,                                 // 1 = light it
    input wire fogged_in,                              // 1 = fog it, just passes through
    input wire textured_in,                            // texture stuff passes through untouched
    input wire [7:0] texture_slot_in,
    input wire [191:0] uvs_in,                         // corner k u at bits 64*k, v at 64*k + 32
    // sun lights, ambient then 4 directions then 4 colours
    input wire lights_valid,
    output wire lights_ready,
    input wire [311:0] lights,
    // lamps, lamp k at bit 128*k, x y z colour range
    input wire lamps_valid,
    output wire lamps_ready,
    input wire [255:0] lamps,
    // writes to the lamp fade tables
    input wire [1:0] lamp_table_write,
    input wire [7:0] lamp_table_row,
    input wire [15:0] lamp_table_word,

    // to setup
    output reg out_valid,
    input wire out_ready,
    output reg signed [15:0] x0, y0, x1, y1, x2, y2,      // 1/16 pixel
    output reg [31:0] z0, z1, z2,                         // near / distance, bigger = closer
    output reg [95:0] colour,                          // corner k at bits 32*k
    output reg [3:0] switches,
    output reg fogged,
    output reg textured,
    output reg [7:0] texture_slot,
    output reg [191:0] uvs,

    output wire busy,
    output reg [31:0] dropped_near,           // triangles dropped for being too close
    output reg [31:0] dropped_too_far_out     // dropped for being way off screen
);

localparam LAST = 26;                    // last stage, 20-26 just wait for the light unit
localparam RECIP_OUT = 14;               // stage where 1/z is ready

// the matrix
reg signed [31:0] m [0:11];
// only the bottom 27 bits get multiplied so each multiply fits one dsp block
function signed [26:0] turn(input [31:0] entry);
    turn = entry[26:0];
endfunction
integer i;

// hold, the triangle being fed in one corner per clock
reg hold_full;
reg [287:0] hold_corners;
reg [95:0] hold_colour;
reg [89:0] hold_normals;
reg hold_lit;
reg [3:0] hold_switches;
reg hold_fogged;
reg [1:0] feed;                          // which corner goes in next

// texture numbers dont change here so they wait in a small queue instead of riding the pipeline
// one entry per triangle, in when its taken, out when its last corner is collected
reg [200:0] texture_ride [0:15];         // {textured, slot, uvs}
reg [3:0] ride_in, ride_out;
wire [200:0] ride_now = texture_ride[ride_out];
// the corner going in is always at the bottom, they slide down after each one
wire signed [31:0] vx = hold_corners[31:0];
wire signed [31:0] vy = hold_corners[63:32];
wire signed [31:0] vz = hold_corners[95:64];

// the whole pipeline moves together, it only stops when setup cant take a finished triangle
reg [LAST:0] full;                       // full[k] = stage k has a corner, bit 0 unused
reg [1:0] tag [1:LAST];                  // which corner of its triangle
reg [31:0] ride_colour [1:LAST];
reg [4:0] ride_switches [1:LAST];         // bit 4 = fogged
wire advance = !(full[LAST] && tag[LAST] == 2'd2 && out_valid);

// copies of advance, one per group of stages so the wire stays short
// syn_preserve stops the tool merging them back into one
localparam COPIES = 8;
(* syn_preserve = 1 *) reg [COPIES-1:0] last_full_c;     // copies of full[LAST]
(* syn_preserve = 1 *) reg [COPIES-1:0] last_corner2_c;  // copies of tag[LAST] == 2
(* syn_preserve = 1 *) reg [COPIES-1:0] out_valid_c;     // copies of out_valid
wire [COPIES-1:0] advance_c = ~(last_full_c & last_corner2_c & out_valid_c);

// the light unit, runs next to stages 1-23
localparam LIGHT_OUT = 23;               // stage where the lit colour is ready
reg [31:0] normal_scale;                 // from the matrix
reg [23:0] ambient;
reg [191:0] sun_directions;
reg [95:0] sun_colours;
wire [31:0] lit_colour;
reg signed [39:0] s2_x, s2_y, s2_z;      // stage 2 output, declared early for the light unit
// lamp settings, off until set
reg [191:0] lamp_positions = 192'd0;
reg [47:0] lamp_colours = 48'd0;
reg [7:0] lamp_ranges = 8'd0;
assign lamps_ready = !hold_full && (full[LIGHT_OUT:1] == 0);
// clamp to 32 bits for the lamps
function signed [31:0] hold32(input signed [39:0] v);
    hold32 = (v > 40'sd2147483647) ? 32'sh7FFFFFFF : (v < -40'sd2147483648) ? 32'sh80000000 : v[31:0];
endfunction
// lights only change when no corner is in the light unit
assign lights_ready = !hold_full && (full[LIGHT_OUT:1] == 0);
lighting light (
    .clk(clk), .advance_a(advance_c[6]), .advance_b(advance_c[7]),
    .normal_in(hold_normals[29:0]), .colour_in(hold_colour[31:0]), .lit_in(hold_lit), .normal_scale_in(normal_scale),
    .turn({m[10], m[9], m[8], m[6], m[5], m[4], m[2], m[1], m[0]}),
    .ambient(ambient), .sun_directions(sun_directions), .sun_colours(sun_colours),
    .corner_x(hold32(s2_x)), .corner_y(hold32(s2_y)), .corner_z(hold32(s2_z)),
    .lamp_positions(lamp_positions), .lamp_colours(lamp_colours), .lamp_ranges(lamp_ranges),
    .lamp_table_write(lamp_table_write), .lamp_table_row(lamp_table_row), .lamp_table_word(lamp_table_word),
    .colour_out(lit_colour)
);

`ifdef CORNER_RATE_DIV
// simulation only, take a corner every nth clock
reg [2:0] rate_count = 3'd0;
always @(posedge clk) rate_count <= (rate_count == `CORNER_RATE_DIV - 1) ? 3'd0 : rate_count + 1'b1;
wire rate_phase = (rate_count == 3'd0);
`else
wire rate_phase = 1'b1;
`endif
assign tri_ready = advance_c[5] && (!hold_full || (feed == 2'd2 && rate_phase));
wire take_triangle = tri_valid && tri_ready;
assign matrix_ready = !hold_full;
wire feeding = hold_full && advance_c[5] && rate_phase;

// stage 1 the 9 multiplies and the move column
reg signed [63:0] pr [0:8];              // row r col c at pr[r*3 + c]
reg signed [31:0] move_x, move_y, move_z;

// stage 2 the sums
// 3 products of a row / 2^16 + the rows move
function signed [39:0] row_sum(input signed [63:0] a, input signed [63:0] b, input signed [63:0] c,
                               input signed [31:0] t);
    reg signed [65:0] sum;
    begin
        sum = a + b + c;
        row_sum = (sum >>> 16) + t;
    end
endfunction

// stage 3 too close? and into the reciprocal
reg [35:0] s3_distance;
wire s2_bad = (s2_z < $signed({8'd0, near})) || (s2_z >= 40'sd68719476736);     // closer than near or past 2^36

// stages 4-14 the reciprocal works out 1/distance, x y and bad wait next to it
wire [35:0] recip_r;
wire [5:0] recip_p;
reciprocal recip (.clk(clk), .advance(advance_c[4]), .area(s3_distance), .r(recip_r), .p(recip_p));
reg signed [39:0] w_x [3:RECIP_OUT];
reg signed [39:0] w_y [3:RECIP_OUT];
reg w_bad [3:RECIP_OUT];

// stage 15 scale
wire [20:0] focal16 = {1'b0, focal, 4'd0};          // zoom in 1/16 pixels
reg [56:0] s15_rf;                                  // 1/z times focal16
reg [67:0] s15_nz;                                  // near times 1/z
reg signed [39:0] s15_x, s15_y;
reg [5:0] s15_p;
reg s15_bad;

// stage 16 times
wire [35:0] rf_top = s15_rf[56:21];                 // top 36 bits
reg signed [75:0] s16_px, s16_py;                   // x and y times that
reg [67:0] s16_z;                                   // depth, only partly shifted
reg [3:0] s16_fine;                                 // rest of the shift, done in stage 17
reg [5:0] s16_p;
reg s16_bad;

// stages 17-18 back to 1/16 pixel, rounded
// stage 17 add a half so the shift rounds
reg signed [75:0] s17_px, s17_py;
reg [6:0] s17_shift;
reg [31:0] s17_z;
wire [67:0] s17_z_fine = s16_z >> s16_fine;
reg s17_bad;
// stage 18 shift
reg signed [47:0] s18_dx, s18_dy;
reg [31:0] s18_z;
reg s18_bad;

// stage 19 screen
wire signed [47:0] sx = 48'sd10240 + s18_dx;        // 640 * 16
wire signed [47:0] sy = 48'sd5760 - s18_dy;         // 360 * 16
reg signed [15:0] s19_sx, s19_sy;
reg [31:0] s19_z;
reg s19_bad_near, s19_bad_far;
reg signed [15:0] s20_sx, s20_sy, s21_sx, s21_sy, s22_sx, s22_sy, s23_sx, s23_sy, s24_sx, s24_sy, s25_sx, s25_sy,
                 s26_sx, s26_sy;   // stages 20-26 wait
reg [31:0] s20_z, s21_z, s22_z, s23_z, s24_z, s25_z, s26_z;
reg s20_bad_near, s20_bad_far, s21_bad_near, s21_bad_far, s22_bad_near, s22_bad_far, s23_bad_near, s23_bad_far,
    s24_bad_near, s24_bad_far, s25_bad_near, s25_bad_far, s26_bad_near, s26_bad_far;

// the collector
reg signed [15:0] c_x [0:1];
reg signed [15:0] c_y [0:1];
reg [31:0] c_z [0:1];
reg [31:0] c_colour0, c_colour1;         // corners 0 and 1 wait here for corner 2
reg c_bad_near, c_bad_far;

assign busy = hold_full || (full != 0) || out_valid;

// the data moves up one stage on advance
// no reset here, full says if a stage matters and full is reset
integer j;
// tags colours and switches riding along
always @(posedge clk) begin
    if (advance_c[0]) begin
        tag[1] <= feed;
        ride_colour[1] <= hold_colour[31:0];
        ride_switches[1] <= {hold_fogged, hold_switches};
        for (j = 2; j <= LAST; j = j + 1) begin
            tag[j] <= tag[j - 1];
            ride_colour[j] <= (j == LIGHT_OUT + 1) ? lit_colour : ride_colour[j - 1];   // lit colour from here on
            ride_switches[j] <= ride_switches[j - 1];
        end
    end
end

// stages 1-3
always @(posedge clk) begin
    if (advance_c[1]) begin
        // stage 1 products
        pr[0] <= turn(m[0]) * vx;  pr[1] <= turn(m[1]) * vy;  pr[2] <= turn(m[2])  * vz;
        pr[3] <= turn(m[4]) * vx;  pr[4] <= turn(m[5]) * vy;  pr[5] <= turn(m[6])  * vz;
        pr[6] <= turn(m[8]) * vx;  pr[7] <= turn(m[9]) * vy;  pr[8] <= turn(m[10]) * vz;
        move_x <= m[3];  move_y <= m[7];  move_z <= m[11];

        // stage 2 sums
        s2_x <= row_sum(pr[0], pr[1], pr[2], move_x);
        s2_y <= row_sum(pr[3], pr[4], pr[5], move_y);
        s2_z <= row_sum(pr[6], pr[7], pr[8], move_z);

        // stage 3 near, a bad corner gives the reciprocal a harmless number
        s3_distance <= s2_bad ? 36'h1_0000 : s2_z[35:0];
        w_x[3] <= s2_x;  w_y[3] <= s2_y;  w_bad[3] <= s2_bad;
    end
end

// stages 4-14 waiting next to the reciprocal
integer jw;
always @(posedge clk) begin
    if (advance_c[2]) begin
        for (jw = 4; jw <= RECIP_OUT; jw = jw + 1) begin
            w_x[jw] <= w_x[jw - 1];  w_y[jw] <= w_y[jw - 1];  w_bad[jw] <= w_bad[jw - 1];
        end
    end
end

// stages 15-26
always @(posedge clk) begin
    if (advance_c[3]) begin
        // stage 15 scale
        s15_rf <= recip_r * focal16;
        s15_nz <= near[26:0] * recip_r;          // 27 x 36 bits, one dsp block
        s15_x <= w_x[RECIP_OUT];  s15_y <= w_y[RECIP_OUT];
        s15_p <= recip_p;  s15_bad <= w_bad[RECIP_OUT];

        // stage 16 times
        s16_px <= s15_x * $signed({1'b0, rf_top});
        s16_py <= s15_y * $signed({1'b0, rf_top});
        // the shift by 3 + p is split in two, the coarse part here and the fine part in stage 17
        s16_z <= s15_nz >> {s15_p[5:3], 3'b000};
        s16_fine <= 4'd3 + {1'b0, s15_p[2:0]};
        s16_p <= s15_p;  s16_bad <= s15_bad;

        // stage 17 round, and cap the depth at 32 bits
        s17_px <= s16_px + (76'sd1 <<< (6'd13 + s16_p));
        s17_py <= s16_py + (76'sd1 <<< (6'd13 + s16_p));
        s17_shift <= 7'd14 + s16_p;
        s17_z <= (s17_z_fine > 68'hFFFF_FFFF) ? 32'hFFFF_FFFF : s17_z_fine[31:0];
        s17_bad <= s16_bad;

        // stage 18 shift
        s18_dx <= s17_px >>> s17_shift;
        s18_dy <= s17_py >>> s17_shift;
        s18_z <= s17_z;  s18_bad <= s17_bad;

        // stage 19 add the screen middle and check it still fits
        s19_sx <= sx[15:0];
        s19_sy <= sy[15:0];
        s19_z <= s18_z;
        s19_bad_near <= s18_bad;
        s19_bad_far <= (sx > 48'sd32000) || (sx < -48'sd32000) || (sy > 48'sd32000) || (sy < -48'sd32000);

        // stages 20-26 wait
        s20_sx <= s19_sx;  s20_sy <= s19_sy;  s20_z <= s19_z;  s20_bad_near <= s19_bad_near;  s20_bad_far <= s19_bad_far;
        s21_sx <= s20_sx;  s21_sy <= s20_sy;  s21_z <= s20_z;  s21_bad_near <= s20_bad_near;  s21_bad_far <= s20_bad_far;
        s22_sx <= s21_sx;  s22_sy <= s21_sy;  s22_z <= s21_z;  s22_bad_near <= s21_bad_near;  s22_bad_far <= s21_bad_far;
        s23_sx <= s22_sx;  s23_sy <= s22_sy;  s23_z <= s22_z;  s23_bad_near <= s22_bad_near;  s23_bad_far <= s22_bad_far;
        s24_sx <= s23_sx;  s24_sy <= s23_sy;  s24_z <= s23_z;  s24_bad_near <= s23_bad_near;  s24_bad_far <= s23_bad_far;
        s25_sx <= s24_sx;  s25_sy <= s24_sy;  s25_z <= s24_z;  s25_bad_near <= s24_bad_near;  s25_bad_far <= s24_bad_far;
        s26_sx <= s25_sx;  s26_sy <= s25_sy;  s26_z <= s25_z;  s26_bad_near <= s25_bad_near;  s26_bad_far <= s25_bad_far;
    end
end

// the copies registers, same rules as the originals
wire delivering = advance && full[LAST] && tag[LAST] == 2'd2 && !(c_bad_near || s26_bad_near) && !(c_bad_far || s26_bad_far);
always @(posedge clk) begin
    if (advance)
        last_corner2_c <= {COPIES{tag[LAST - 1] == 2'd2}};
    if (reset) begin
        last_full_c <= 0;
        out_valid_c <= 0;
    end else begin
        if (advance)
            last_full_c <= {COPIES{full[LAST - 1]}};
        if (out_valid && out_ready)
            out_valid_c <= 0;
        if (delivering)
            out_valid_c <= {COPIES{1'b1}};
    end
end

always @(posedge clk) begin
    if (reset) begin
        hold_full <= 1'b0;
        full <= 0;
        out_valid <= 1'b0;
        ride_in <= 4'd0;
        ride_out <= 4'd0;
        dropped_near <= 0;
        dropped_too_far_out <= 0;
    end else begin
        // take new settings
        if (matrix_valid && matrix_ready) begin
            for (i = 0; i < 12; i = i + 1) m[i] <= matrix[i * 32 +: 32];
            normal_scale <= matrix[415:384];
        end
        if (lights_valid && lights_ready) begin
            ambient <= lights[23:0];
            sun_directions <= lights[215:24];
            sun_colours <= lights[311:216];
        end
        if (lamps_valid && lamps_ready) begin
            lamp_positions <= {lamps[128 + 64 +: 32], lamps[128 + 32 +: 32], lamps[128 +: 32],
                               lamps[64 +: 32], lamps[32 +: 32], lamps[0 +: 32]};
            lamp_colours <= {lamps[128 + 96 +: 24], lamps[96 +: 24]};
            lamp_ranges <= {lamps[128 + 120 +: 4], lamps[120 +: 4]};
        end

        // setup takes the finished triangle
        if (out_valid && out_ready) out_valid <= 1'b0;

        if (advance_c[5]) begin
            // hold, take a new triangle or feed the next corner
            if (take_triangle) begin
                hold_corners <= corners;
                hold_colour <= colour_in;
                hold_switches <= switches_in;
                hold_fogged <= fogged_in;
                hold_normals <= normals_in;
                hold_lit <= lit_in;
                hold_full <= 1'b1;
                feed <= 0;
                texture_ride[ride_in] <= {textured_in, texture_slot_in, uvs_in};
                ride_in <= ride_in + 1'b1;
            end else if (feeding && feed == 2'd2)
                hold_full <= 1'b0;
            if (feeding && !take_triangle) begin
                feed <= feed + 1'b1;
                hold_corners <= hold_corners >> 96;        // next corner slides to the bottom
                hold_colour <= hold_colour >> 32;
                hold_normals <= hold_normals >> 30;
            end

            // every stage moves up one
            full <= {full[LAST-1:1], feeding, 1'b0};

            // the collector, corners 0 and 1 wait and corner 2 finishes the triangle
            if (full[LAST]) begin
                if (tag[LAST] != 2'd2) begin
                    c_x[tag[LAST]] <= s26_sx;  c_y[tag[LAST]] <= s26_sy;  c_z[tag[LAST]] <= s26_z;
                    if (tag[LAST] == 2'd0) c_colour0 <= ride_colour[LAST];
                    else                   c_colour1 <= ride_colour[LAST];
                    if (tag[LAST] == 2'd0) begin
                        c_bad_near <= s26_bad_near;
                        c_bad_far <= s26_bad_far;
                    end else begin
                        c_bad_near <= c_bad_near || s26_bad_near;
                        c_bad_far <= c_bad_far || s26_bad_far;
                    end
                end else begin
                    ride_out <= ride_out + 1'b1;          // texture numbers leave the queue, kept or not
                    if (c_bad_near || s26_bad_near)
                        dropped_near <= dropped_near + 1;
                    else if (c_bad_far || s26_bad_far)
                        dropped_too_far_out <= dropped_too_far_out + 1;
                    else begin
                        x0 <= c_x[0];  y0 <= c_y[0];  z0 <= c_z[0];
                        x1 <= c_x[1];  y1 <= c_y[1];  z1 <= c_z[1];
                        x2 <= s26_sx;  y2 <= s26_sy;  z2 <= s26_z;
                        colour <= {ride_colour[LAST], c_colour1, c_colour0};   // corners 2 1 0
                        switches <= ride_switches[LAST][3:0];
                        fogged <= ride_switches[LAST][4];
                        {textured, texture_slot, uvs} <= ride_now;
                        out_valid <= 1'b1;
                    end
                end
            end
        end
    end
end

endmodule

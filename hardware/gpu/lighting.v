// lighting.v
// works out each corners lit colour, runs next to projection one corner per clock
// lit = colour x (ambient + 4 suns x how much the normal faces them + 2 lamps)
// an unlit corner keeps its colour
module lighting (
    input wire clk,
    input wire advance_a,                   // pipeline moves, copy for stages 1-6
    input wire advance_b,                   // same thing, copy for the rest

    // the corner coming in
    input wire [29:0] normal_in,            // x y z at bits 0 10 20, 10 bit signed, 512 = 1.0
    input wire [31:0] colour_in,            // 0xAARRGGBB
    input wire lit_in,                      // 1 = light it, 0 = keep its colour
    input wire [31:0] normal_scale_in,      // Q16.16, rides along with the corner

    // settings
    input wire [287:0] turn,                // the 9 rotation entries Q16.16, row r col c at bits (r*3 + c)*32
    input wire [23:0] ambient,              // 0xRRGGBB
    input wire [191:0] sun_directions,      // sun k x y z 16 bit signed at bits 48*k
    input wire [95:0] sun_colours,          // sun k 0xRRGGBB at bits 24*k

    // the 2 lamps
    input wire signed [31:0] corner_x,      // corner position in camera space Q16.16, arrives at stage 3
    input wire signed [31:0] corner_y,
    input wire signed [31:0] corner_z,
    input wire [191:0] lamp_positions,      // lamp k x y z Q16.16 at bits 96*k
    input wire [47:0] lamp_colours,         // lamp k 0xRRGGBB at bits 24*k, 0 = off
    input wire [7:0] lamp_ranges,           // lamp k range at bits 4*k
    input wire [1:0] lamp_table_write,      // bit k writes a row of lamp ks fade table
    input wire [7:0] lamp_table_row,
    input wire [15:0] lamp_table_word,

    // the lit colour out
    output reg [31:0] colour_out
);

// small helpers
// bottom 27 bits of a rotation entry, same as projection
function signed [26:0] turn27(input [31:0] entry);
    turn27 = entry[26:0];
endfunction

// colour 0-255 as an amount where 256 = 1.0, so 255 becomes 256
function [8:0] amount_of(input [7:0] v);
    amount_of = {1'b0, v} + {8'd0, v[7]};
endfunction

// clamps
function signed [26:0] hold27(input signed [39:0] v);
    hold27 = (v > 40'sd67108863) ? 27'sd67108863 : (v < -40'sd67108864) ? -27'sd67108864 : v[26:0];
endfunction
function signed [15:0] hold16(input signed [59:0] v);
    hold16 = (v > 60'sd32767) ? 16'sd32767 : (v < -60'sd32768) ? -16'sd32768 : v[15:0];
endfunction
function [14:0] hold_facing(input signed [34:0] v);      // 0 to 16384
    hold_facing = (v < 35'sd0) ? 15'd0 : (v > 35'sd16384) ? 15'd16384 : v[14:0];
endfunction

// add a rows 3 products and scale down
function signed [26:0] row_of(input signed [36:0] a, input signed [36:0] b, input signed [36:0] c);
    reg signed [38:0] sum;
    begin
        sum = a + b + c;
        row_of = hold27(sum >>> 11);
    end
endfunction

// round one channel, add a half then / 2^22, max 255
function [7:0] round_channel(input [32:0] t);
    reg [32:0] r;
    begin
        r = (t + 33'd2097152) >> 22;
        round_channel = (r > 33'd255) ? 8'd255 : r[7:0];
    end
endfunction

wire signed [9:0] nx = normal_in[9:0];
wire signed [9:0] ny = normal_in[19:10];
wire signed [9:0] nz = normal_in[29:20];

// the corners colour, lit bit and normal scale ride along
reg [31:0] s1_colour, s2_colour, s3_colour, s4_colour, s5_colour, s6_colour, s7_colour, s8_colour, s9_colour,
           s10_colour, s11_colour, s12_colour, s13_colour, s14_colour, s15_colour, s16_colour, s17_colour, s18_colour,
           s19_colour, s20_colour, s21_colour, s22_colour;
reg s1_lit, s2_lit, s3_lit, s4_lit, s5_lit, s6_lit, s7_lit, s8_lit, s9_lit, s10_lit, s11_lit, s12_lit, s13_lit,
    s14_lit, s15_lit, s16_lit, s17_lit, s18_lit, s19_lit, s20_lit, s21_lit, s22_lit;
reg [31:0] s1_scale, s2_scale;
always @(posedge clk) begin
    if (advance_a) begin
        s1_colour <= colour_in;   s1_lit <= lit_in;   s1_scale <= normal_scale_in;
        s2_colour <= s1_colour;   s2_lit <= s1_lit;   s2_scale <= s1_scale;
        s3_colour <= s2_colour;   s3_lit <= s2_lit;
        s4_colour <= s3_colour;   s4_lit <= s3_lit;
        s5_colour <= s4_colour;   s5_lit <= s4_lit;
        s6_colour <= s5_colour;   s6_lit <= s5_lit;
    end
end
always @(posedge clk) begin
    if (advance_b) begin
        s7_colour <= s6_colour;   s7_lit <= s6_lit;
        s8_colour <= s7_colour;   s8_lit <= s7_lit;
        s9_colour <= s8_colour;   s9_lit <= s8_lit;
        s10_colour <= s9_colour;  s10_lit <= s9_lit;
        s11_colour <= s10_colour; s11_lit <= s10_lit;
        s12_colour <= s11_colour; s12_lit <= s11_lit;
        s13_colour <= s12_colour; s13_lit <= s12_lit;
        s14_colour <= s13_colour; s14_lit <= s13_lit;
        s15_colour <= s14_colour; s15_lit <= s14_lit;
        s16_colour <= s15_colour; s16_lit <= s15_lit;
        s17_colour <= s16_colour; s17_lit <= s16_lit;
        s18_colour <= s17_colour; s18_lit <= s17_lit;
        s19_colour <= s18_colour; s19_lit <= s18_lit;
        s20_colour <= s19_colour; s20_lit <= s19_lit;
        s21_colour <= s20_colour; s21_lit <= s20_lit;
        s22_colour <= s21_colour; s22_lit <= s21_lit;
    end
end

// stages 1-4 rotate the normal, one row at a time
// every number gets its own named register, lists got turned into ram by the tool
genvar r, k, ch;
generate
    for (r = 0; r < 3; r = r + 1) begin : row
        reg signed [36:0] p0, p1, p2;        // stage 1 rotation entry x normal
        reg signed [26:0] sum;               // stage 2 the row sum
        reg signed [59:0] scaled;            // stage 3 times the normal scale
        reg signed [15:0] n;                 // stage 4 the rotated normal
        always @(posedge clk) begin
            if (advance_a) begin
                p0 <= turn27(turn[(r * 3 + 0) * 32 +: 32]) * nx;
                p1 <= turn27(turn[(r * 3 + 1) * 32 +: 32]) * ny;
                p2 <= turn27(turn[(r * 3 + 2) * 32 +: 32]) * nz;
                sum <= row_of(p0, p1, p2);
                scaled <= sum * $signed({1'b0, s2_scale});
                n <= hold16(scaled >>> 16);
            end
        end
    end

    // stages 5-8 for each sun
    for (k = 0; k < 4; k = k + 1) begin : sun
        reg signed [31:0] d0, d1, d2;        // stage 5 normal dot sun direction
        reg [14:0] facing;                   // stage 6 how much it faces the sun, never below 0
        always @(posedge clk) begin
            if (advance_a) begin
                d0 <= row[0].n * $signed(sun_directions[48 * k + 0 +: 16]);
                d1 <= row[1].n * $signed(sun_directions[48 * k + 16 +: 16]);
                d2 <= row[2].n * $signed(sun_directions[48 * k + 32 +: 16]);
                facing <= hold_facing((d0 + d1 + d2) >>> 14);
            end
        end
        // stages 7-8 sun colour x facing for red green blue
        // built from logic in two halves to save dsp blocks
        for (ch = 0; ch < 3; ch = ch + 1) begin : chan
            reg [8:0] amt;                   // sun colour as an amount
            always @(posedge clk) amt <= amount_of(sun_colours[24 * k + 8 * (2 - ch) +: 8]);
            wire [16:0] low_part /* synthesis syn_dspstyle = "logic" */;
            wire [15:0] high_part /* synthesis syn_dspstyle = "logic" */;
            assign low_part = amt * facing[7:0];
            assign high_part = amt * facing[14:8];
            reg [16:0] lo;
            reg [15:0] hi;
            reg [23:0] c;
            always @(posedge clk) begin
                if (advance_b) begin
                    lo <= low_part;
                    hi <= high_part;
                    c <= {hi, 8'd0} + {7'd0, lo};
                end
            end
        end
    end

    // the 2 lamps, they run next to stages 3-19
    for (k = 0; k < 2; k = k + 1) begin : lamp
        wire [22:0] amt_r, amt_g, amt_b;
        lamp_light3 one (
            .clk(clk), .advance(advance_b), .valid_in(1'b0),
            .corner_x(corner_x), .corner_y(corner_y), .corner_z(corner_z),
            .normal_x(row[0].n), .normal_y(row[1].n), .normal_z(row[2].n),
            .lamp_x(lamp_positions[96 * k +: 32]), .lamp_y(lamp_positions[96 * k + 32 +: 32]),
            .lamp_z(lamp_positions[96 * k + 64 +: 32]), .lamp_colour(lamp_colours[24 * k +: 24]),
            .range(lamp_ranges[4 * k +: 4]), .table_write(lamp_table_write[k]), .table_row(lamp_table_row),
            .table_word(lamp_table_word),
            .amount_red(amt_r), .amount_green(amt_g), .amount_blue(amt_b), .valid_out()
        );
    end

    // stages 9-22 for each of red green blue
    for (ch = 0; ch < 3; ch = ch + 1) begin : colour
        reg [8:0] ambient_amt;               // ambient as an amount
        always @(posedge clk) ambient_amt <= amount_of(ambient[8 * (2 - ch) +: 8]);
        reg [24:0] amount;                   // stage 9 ambient + the 4 suns
        reg [24:0] a10, a11, a12, a13, a14, a15, a16, a17, a18, a19;   // waits for the lamps
        // this channels lamp amounts
        wire [22:0] lamp0 = (ch == 0) ? lamp[0].amt_r : (ch == 1) ? lamp[0].amt_g : lamp[0].amt_b;
        wire [22:0] lamp1 = (ch == 0) ? lamp[1].amt_r : (ch == 1) ? lamp[1].amt_g : lamp[1].amt_b;
        reg [24:0] total;                    // stage 20 plus the 2 lamps
        // stage 21 the corners colour in four 2 bit pieces, each times the total
        wire [7:0] c8 = s20_colour[8 * (2 - ch) +: 8];
        wire [26:0] part0 /* synthesis syn_dspstyle = "logic" */;
        wire [26:0] part1 /* synthesis syn_dspstyle = "logic" */;
        wire [26:0] part2 /* synthesis syn_dspstyle = "logic" */;
        wire [26:0] part3 /* synthesis syn_dspstyle = "logic" */;
        assign part0 = c8[1:0] * total;
        assign part1 = c8[3:2] * total;
        assign part2 = c8[5:4] * total;
        assign part3 = c8[7:6] * total;
        reg [26:0] p0, p1, p2, p3;
        reg [32:0] t;                        // stage 22 the pieces added, colour x total
        always @(posedge clk) begin
            if (advance_b) begin
                amount <= {ambient_amt, 14'd0}
                          + sun[0].chan[ch].c + sun[1].chan[ch].c + sun[2].chan[ch].c + sun[3].chan[ch].c;
                a10 <= amount;  a11 <= a10;  a12 <= a11;  a13 <= a12;  a14 <= a13;  a15 <= a14;
                a16 <= a15;  a17 <= a16;  a18 <= a17;  a19 <= a18;
                total <= a19 + {2'd0, lamp0} + {2'd0, lamp1};
                p0 <= part0;
                p1 <= part1;
                p2 <= part2;
                p3 <= part3;
                t <= {p3, 6'd0} + {2'd0, p2, 4'd0} + {4'd0, p1, 2'd0} + {6'd0, p0};
            end
        end
    end
endgenerate

// stage 23 round, alpha kept, or the colour as it was if unlit
always @(posedge clk) begin
    if (advance_b)
        colour_out <= s22_lit ? {s22_colour[31:24], round_channel(colour[0].t), round_channel(colour[1].t),
                                 round_channel(colour[2].t)}
                              : s22_colour;
end

endmodule

// lamp_light3.v
// one lamps light on one corner
// amount = lamp colour x facing x fade / 256 for red green blue
// the vector to the lamp gets scaled to 18 bits so every multiply fits one dsp block
module lamp_light3 (
    input wire clk,
    input wire advance,
    input wire valid_in,

    input wire signed [31:0] corner_x,      // corner position in camera space Q16.16, arrives at stage 1
    input wire signed [31:0] corner_y,
    input wire signed [31:0] corner_z,
    input wire signed [15:0] normal_x,      // rotated normal, 16384 = 1.0, arrives at stage 3
    input wire signed [15:0] normal_y,
    input wire signed [15:0] normal_z,

    input wire signed [31:0] lamp_x,        // lamp settings
    input wire signed [31:0] lamp_y,
    input wire signed [31:0] lamp_z,
    input wire [23:0] lamp_colour,
    input wire signed [3:0] range,
    input wire table_write,                 // fade table write
    input wire [7:0] table_row,
    input wire [15:0] table_word,

    output reg [22:0] amount_red,           // the lamp amounts
    output reg [22:0] amount_green,
    output reg [22:0] amount_blue,
    output reg valid_out
);

localparam signed [32:0] REACH_TOP = 33'sd134217727;      // 2^27 - 1
localparam signed [32:0] REACH_BOTTOM = -33'sd134217728;  // -2^27

// clamp to 28 bits
function signed [27:0] hold28(input signed [32:0] v);
    hold28 = (v > REACH_TOP) ? REACH_TOP[27:0] : (v < REACH_BOTTOM) ? REACH_BOTTOM[27:0] : v[27:0];
endfunction

// colour 0-255 as an amount where 256 = 1.0
function [8:0] amount_of(input [7:0] v);
    amount_of = {1'b0, v} + {8'd0, v[7]};
endfunction

// size without the sign
function [26:0] size_of(input signed [27:0] a);
    size_of = a[27] ? ~a[26:0] : a[26:0];
endfunction

// how many bits the number needs, 0 for 0
function [4:0] bits_of(input [26:0] v);
    integer b;
    begin
        bits_of = 5'd0;
        for (b = 0; b < 27; b = b + 1)
            if (v[b]) bits_of = b[4:0] + 5'd1;
    end
endfunction

// stage 1 vector from corner to lamp
reg signed [27:0] s1_tx, s1_ty, s1_tz;
reg s1_valid;
always @(posedge clk) if (advance) begin
    s1_tx <= hold28($signed({lamp_x[31], lamp_x}) - $signed({corner_x[31], corner_x}));
    s1_ty <= hold28($signed({lamp_y[31], lamp_y}) - $signed({corner_y[31], corner_y}));
    s1_tz <= hold28($signed({lamp_z[31], lamp_z}) - $signed({corner_z[31], corner_z}));
    s1_valid <= valid_in;
end

// stage 2 find the shift s that makes the biggest part fit 18 bits
wire [4:0] s1_bits = bits_of(size_of(s1_tx) | size_of(s1_ty) | size_of(s1_tz));
reg signed [27:0] s2_tx, s2_ty, s2_tz;
reg [3:0] s2_s;
reg s2_valid;
always @(posedge clk) if (advance) begin
    s2_tx <= s1_tx;  s2_ty <= s1_ty;  s2_tz <= s1_tz;
    s2_s <= (s1_bits > 5'd17) ? (s1_bits - 5'd17) : 4'd0;
    s2_valid <= s1_valid;
end

// stage 3 shift, the normal arrives here
wire signed [27:0] s2_shx = s2_tx >>> s2_s;
wire signed [27:0] s2_shy = s2_ty >>> s2_s;
wire signed [27:0] s2_shz = s2_tz >>> s2_s;
reg signed [17:0] s3_tx, s3_ty, s3_tz;
reg signed [15:0] s3_nx, s3_ny, s3_nz;
reg [3:0] s3_s;
reg s3_valid;
always @(posedge clk) if (advance) begin
    s3_tx <= s2_shx[17:0];  s3_ty <= s2_shy[17:0];  s3_tz <= s2_shz[17:0];
    s3_nx <= normal_x;  s3_ny <= normal_y;  s3_nz <= normal_z;
    s3_s <= s2_s;
    s3_valid <= s2_valid;
end

// stage 4 the squares and normal x vector
reg [34:0] s4_sq_x, s4_sq_y, s4_sq_z;
reg signed [33:0] s4_nt_x, s4_nt_y, s4_nt_z;
reg [3:0] s4_s;
reg s4_valid;
always @(posedge clk) if (advance) begin
    s4_sq_x <= s3_tx * s3_tx;
    s4_sq_y <= s3_ty * s3_ty;
    s4_sq_z <= s3_tz * s3_tz;
    s4_nt_x <= s3_nx * s3_tx;
    s4_nt_y <= s3_ny * s3_ty;
    s4_nt_z <= s3_nz * s3_tz;
    s4_s <= s3_s;
    s4_valid <= s3_valid;
end

// stage 5 the sums, scaled distance squared (at least 1) and normal dot vector
wire [35:0] s4_sum = s4_sq_x + s4_sq_y + s4_sq_z;
reg [35:0] s5_d2s;
reg signed [35:0] s5_nl;
reg [3:0] s5_s;
reg s5_valid;
always @(posedge clk) if (advance) begin
    s5_d2s <= (s4_sum == 0) ? 36'd1 : s4_sum;
    s5_nl <= s4_nt_x + s4_nt_y + s4_nt_z;
    s5_s <= s4_s;
    s5_valid <= s4_valid;
end

// stages 6-11 inverse square root of the scaled distance squared
wire [17:0] s11_y;
wire [5:0] s11_half;
wire s11_valid;
inv_sqrt17 root (.clk(clk), .advance(advance), .v(s5_d2s), .valid_in(s5_valid), .y(s11_y), .half(s11_half),
                 .valid_out(s11_valid));

// stage 6 the true distance squared, stages 7-11 the fade from it
reg [55:0] s6_d2;
always @(posedge clk) if (advance)
    s6_d2 <= {20'd0, s5_d2s} << {s5_s, 1'b0};        // undo the scaling, x 2^(2s)
wire [8:0] s11_fade;
lamp_fade fade_unit (.clk(clk), .advance(advance), .valid_in(1'b0), .d2(s6_d2), .range(range),
                     .table_write(table_write), .table_row(table_row), .table_word(table_word),
                     .fade(s11_fade), .valid_out());

// nl waits for the inverse square root, the fade waits until stage 15
reg signed [35:0] s6_nl, s7_nl, s8_nl, s9_nl, s10_nl, s11_nl;
always @(posedge clk) if (advance) begin
    s6_nl <= s5_nl;  s7_nl <= s6_nl;  s8_nl <= s7_nl;  s9_nl <= s8_nl;  s10_nl <= s9_nl;  s11_nl <= s10_nl;
end
reg [8:0] s12_fade, s13_fade, s14_fade, s15_fade;
always @(posedge clk) if (advance) begin
    s12_fade <= s11_fade;  s13_fade <= s12_fade;  s14_fade <= s13_fade;  s15_fade <= s14_fade;
end

// stage 12 scale nl down by half
reg signed [35:0] s12_nls;
reg [17:0] s12_y;
reg s12_valid;
always @(posedge clk) if (advance) begin
    s12_nls <= s11_nl >>> s11_half;
    s12_y <= s11_y;
    s12_valid <= s11_valid;
end

// stage 13 times y
reg signed [54:0] s13_product;
reg s13_valid;
always @(posedge clk) if (advance) begin
    s13_product <= s12_nls * $signed({1'b0, s12_y});
    s13_valid <= s12_valid;
end

// stage 14 facing, clamped to 0-16384
wire signed [54:0] s13_shifted = s13_product >>> 17;
reg [14:0] s14_facing;
reg s14_valid;
always @(posedge clk) if (advance) begin
    s14_facing <= (s13_shifted < 0) ? 15'd0 : (s13_shifted > 55'sd16384) ? 15'd16384 : s13_shifted[14:0];
    s14_valid <= s13_valid;
end

// stage 15 lamp colour x facing
wire [23:0] s14_cr;
wire [23:0] s14_cg;
wire [23:0] s14_cb;
assign s14_cr = amount_of(lamp_colour[23:16]) * s14_facing;
assign s14_cg = amount_of(lamp_colour[15:8]) * s14_facing;
assign s14_cb = amount_of(lamp_colour[7:0]) * s14_facing;
reg [23:0] s15_cr, s15_cg, s15_cb;
reg s15_valid;
always @(posedge clk) if (advance) begin
    s15_cr <= s14_cr;  s15_cg <= s14_cg;  s15_cb <= s14_cb;
    s15_valid <= s14_valid;
end

// stage 16 times the fade
// kept as one whole multiply, split in two the tool chained the dsp blocks and lost a shift
wire [32:0] s15_fr;
wire [32:0] s15_fg;
wire [32:0] s15_fb;
assign s15_fr = s15_cr * s15_fade;
assign s15_fg = s15_cg * s15_fade;
assign s15_fb = s15_cb * s15_fade;
reg [32:0] s16_fr, s16_fg, s16_fb;
reg s16_valid;
always @(posedge clk) if (advance) begin
    s16_fr <= s15_fr;  s16_fg <= s15_fg;  s16_fb <= s15_fb;
    s16_valid <= s15_valid;
end

// stage 17 / 256, the lamp amounts
always @(posedge clk) if (advance) begin
    amount_red <= s16_fr[30:8];
    amount_green <= s16_fg[30:8];
    amount_blue <= s16_fb[30:8];
    valid_out <= s16_valid;
end

endmodule

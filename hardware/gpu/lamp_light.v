// lamp_light.v
// one lamps light on one corner, the version with full width multiplies
// amount = lamp colour x facing x fade / 256 for red green blue
module lamp_light (
    input wire clk,
    input wire advance,                     // 1 = every stage moves one step
    input wire valid_in,                    // rides along

    // the corner
    input wire signed [31:0] corner_x,      // position in camera space Q16.16, arrives at stage 1
    input wire signed [31:0] corner_y,
    input wire signed [31:0] corner_z,
    input wire signed [15:0] normal_x,      // rotated normal, 16384 = 1.0, arrives at stage 3
    input wire signed [15:0] normal_y,
    input wire signed [15:0] normal_z,

    // lamp settings
    input wire signed [31:0] lamp_x,        // position in camera space Q16.16
    input wire signed [31:0] lamp_y,
    input wire signed [31:0] lamp_z,
    input wire [23:0] lamp_colour,          // 0xRRGGBB, 0 = off
    input wire signed [3:0] range,          // fade table range
    input wire table_write,                 // fade table write
    input wire [7:0] table_row,
    input wire [15:0] table_word,

    // the lamp amounts out
    output reg [22:0] amount_red,           // 0 to 2^22
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

// stage 1 vector from corner to lamp
reg signed [27:0] s1_tx, s1_ty, s1_tz;
reg s1_valid;
always @(posedge clk) if (advance) begin
    s1_tx <= hold28($signed({lamp_x[31], lamp_x}) - $signed({corner_x[31], corner_x}));
    s1_ty <= hold28($signed({lamp_y[31], lamp_y}) - $signed({corner_y[31], corner_y}));
    s1_tz <= hold28($signed({lamp_z[31], lamp_z}) - $signed({corner_z[31], corner_z}));
    s1_valid <= valid_in;
end

// stage 2 the squares
reg [54:0] s2_sq_x, s2_sq_y, s2_sq_z;
reg signed [27:0] s2_tx, s2_ty, s2_tz;
reg s2_valid;
always @(posedge clk) if (advance) begin
    s2_sq_x <= s1_tx * s1_tx;
    s2_sq_y <= s1_ty * s1_ty;
    s2_sq_z <= s1_tz * s1_tz;
    s2_tx <= s1_tx;  s2_ty <= s1_ty;  s2_tz <= s1_tz;
    s2_valid <= s1_valid;
end

// stage 3 distance squared (at least 1) and normal x vector, the normal arrives here
wire [55:0] s2_sum = s2_sq_x + s2_sq_y + s2_sq_z;
reg [55:0] s3_d2;
reg signed [43:0] s3_nt_x, s3_nt_y, s3_nt_z;
reg s3_valid;
always @(posedge clk) if (advance) begin
    s3_d2 <= (s2_sum == 0) ? 56'd1 : s2_sum;
    s3_nt_x <= normal_x * s2_tx;
    s3_nt_y <= normal_y * s2_ty;
    s3_nt_z <= normal_z * s2_tz;
    s3_valid <= s2_valid;
end

// stages 4-9 inverse square root, stages 4-8 the fade next to it
wire [30:0] s9_y;
wire [5:0] s9_half;
wire s9_valid;
inv_sqrt root (.clk(clk), .advance(advance), .v(s3_d2), .valid_in(s3_valid), .y(s9_y), .half(s9_half),
               .valid_out(s9_valid));

wire [8:0] s8_fade;
lamp_fade fade_unit (.clk(clk), .advance(advance), .valid_in(1'b0), .d2(s3_d2), .range(range),
                     .table_write(table_write), .table_row(table_row), .table_word(table_word),
                     .fade(s8_fade), .valid_out());

// stage 4 normal dot vector, then it waits for the inverse square root
reg signed [45:0] s4_nl, s5_nl, s6_nl, s7_nl, s8_nl, s9_nl;
always @(posedge clk) if (advance) begin
    s4_nl <= s3_nt_x + s3_nt_y + s3_nt_z;
    s5_nl <= s4_nl;  s6_nl <= s5_nl;  s7_nl <= s6_nl;  s8_nl <= s7_nl;  s9_nl <= s8_nl;
end

// the fade waits until stage 13
reg [8:0] s9_fade, s10_fade, s11_fade, s12_fade;
always @(posedge clk) if (advance) begin
    s9_fade <= s8_fade;  s10_fade <= s9_fade;  s11_fade <= s10_fade;  s12_fade <= s11_fade;
end

// stage 10 times y
reg signed [77:0] s10_product;
reg [5:0] s10_half;
reg s10_valid;
always @(posedge clk) if (advance) begin
    s10_product <= s9_nl * $signed({1'b0, s9_y});
    s10_half <= s9_half;
    s10_valid <= s9_valid;
end

// stage 11 facing, clamped to 0-16384
wire signed [77:0] s10_shifted = s10_product >>> (7'd30 + {1'b0, s10_half});
reg [14:0] s11_facing;
reg s11_valid;
always @(posedge clk) if (advance) begin
    s11_facing <= (s10_shifted < 0) ? 15'd0 : (s10_shifted > 78'sd16384) ? 15'd16384 : s10_shifted[14:0];
    s11_valid <= s10_valid;
end

// stage 12 lamp colour x facing, built from logic
wire [23:0] s11_cr /* synthesis syn_dspstyle = "logic" */;
wire [23:0] s11_cg /* synthesis syn_dspstyle = "logic" */;
wire [23:0] s11_cb /* synthesis syn_dspstyle = "logic" */;
assign s11_cr = amount_of(lamp_colour[23:16]) * s11_facing;
assign s11_cg = amount_of(lamp_colour[15:8]) * s11_facing;
assign s11_cb = amount_of(lamp_colour[7:0]) * s11_facing;
reg [23:0] s12_cr, s12_cg, s12_cb;
reg s12_valid;
always @(posedge clk) if (advance) begin
    s12_cr <= s11_cr;  s12_cg <= s11_cg;  s12_cb <= s11_cb;
    s12_valid <= s11_valid;
end

// stage 13 times the fade, / 256
wire [32:0] s12_fr /* synthesis syn_dspstyle = "logic" */;
wire [32:0] s12_fg /* synthesis syn_dspstyle = "logic" */;
wire [32:0] s12_fb /* synthesis syn_dspstyle = "logic" */;
assign s12_fr = s12_cr * s12_fade;
assign s12_fg = s12_cg * s12_fade;
assign s12_fb = s12_cb * s12_fade;
always @(posedge clk) if (advance) begin
    amount_red <= s12_fr[30:8];
    amount_green <= s12_fg[30:8];
    amount_blue <= s12_fb[30:8];
    valid_out <= s12_valid;
end

endmodule

// lamp_facing.v
// how much a corner faces a lamp
// facing = max(0, normal dot to_lamp / distance), also gives the distance squared for the fade
module lamp_facing (
    input wire clk,
    input wire advance,                     // 1 = every stage moves one step
    input wire valid_in,                    // rides along

    // the corner
    input wire signed [15:0] normal_x,      // rotated normal, 16384 = 1.0
    input wire signed [15:0] normal_y,
    input wire signed [15:0] normal_z,
    input wire signed [31:0] corner_x,      // position in camera space Q16.16
    input wire signed [31:0] corner_y,
    input wire signed [31:0] corner_z,

    // the lamp
    input wire signed [31:0] lamp_x,        // position in camera space Q16.16
    input wire signed [31:0] lamp_y,
    input wire signed [31:0] lamp_z,

    // out
    output reg [14:0] facing,               // 0 to 16384
    output reg [55:0] d2,                   // distance squared
    output reg valid_out
);

localparam signed [32:0] REACH_TOP = 33'sd134217727;      // 2^27 - 1
localparam signed [32:0] REACH_BOTTOM = -33'sd134217728;  // -2^27

// clamp to 28 bits
function signed [27:0] hold28(input signed [32:0] v);
    hold28 = (v > REACH_TOP) ? REACH_TOP[27:0] : (v < REACH_BOTTOM) ? REACH_BOTTOM[27:0] : v[27:0];
endfunction

// stage 1 vector from corner to lamp
reg signed [27:0] s1_tx, s1_ty, s1_tz;
reg signed [15:0] s1_nx, s1_ny, s1_nz;
reg s1_valid;

always @(posedge clk) if (advance) begin
    s1_tx <= hold28($signed({lamp_x[31], lamp_x}) - $signed({corner_x[31], corner_x}));
    s1_ty <= hold28($signed({lamp_y[31], lamp_y}) - $signed({corner_y[31], corner_y}));
    s1_tz <= hold28($signed({lamp_z[31], lamp_z}) - $signed({corner_z[31], corner_z}));
    s1_nx <= normal_x;
    s1_ny <= normal_y;
    s1_nz <= normal_z;
    s1_valid <= valid_in;
end

// stage 2 the squares and normal x vector
reg [54:0] s2_sq_x, s2_sq_y, s2_sq_z;
reg signed [43:0] s2_nt_x, s2_nt_y, s2_nt_z;
reg s2_valid;

always @(posedge clk) if (advance) begin
    s2_sq_x <= s1_tx * s1_tx;
    s2_sq_y <= s1_ty * s1_ty;
    s2_sq_z <= s1_tz * s1_tz;
    s2_nt_x <= s1_nx * s1_tx;
    s2_nt_y <= s1_ny * s1_ty;
    s2_nt_z <= s1_nz * s1_tz;
    s2_valid <= s1_valid;
end

// stage 3 the sums
wire [55:0] s2_sum = s2_sq_x + s2_sq_y + s2_sq_z;

reg [55:0] s3_d2;
reg signed [45:0] s3_nl;
reg s3_valid;

always @(posedge clk) if (advance) begin
    s3_d2 <= (s2_sum == 0) ? 56'd1 : s2_sum;         // at least 1
    s3_nl <= s2_nt_x + s2_nt_y + s2_nt_z;
    s3_valid <= s2_valid;
end

// stages 4-9 inverse square root, nl and d2 wait next to it
wire [30:0] s9_y;
wire [5:0] s9_half;
wire s9_valid;
inv_sqrt root (.clk(clk), .advance(advance), .v(s3_d2), .valid_in(s3_valid), .y(s9_y), .half(s9_half),
               .valid_out(s9_valid));

reg signed [45:0] s4_nl, s5_nl, s6_nl, s7_nl, s8_nl, s9_nl;
reg [55:0] s4_d2, s5_d2, s6_d2, s7_d2, s8_d2, s9_d2;

always @(posedge clk) if (advance) begin
    s4_nl <= s3_nl;  s5_nl <= s4_nl;  s6_nl <= s5_nl;  s7_nl <= s6_nl;  s8_nl <= s7_nl;  s9_nl <= s8_nl;
    s4_d2 <= s3_d2;  s5_d2 <= s4_d2;  s6_d2 <= s5_d2;  s7_d2 <= s6_d2;  s8_d2 <= s7_d2;  s9_d2 <= s8_d2;
end

// stage 10 times y
reg signed [77:0] s10_product;
reg [5:0] s10_half;
reg [55:0] s10_d2;
reg s10_valid;

always @(posedge clk) if (advance) begin
    s10_product <= s9_nl * $signed({1'b0, s9_y});
    s10_half <= s9_half;
    s10_d2 <= s9_d2;
    s10_valid <= s9_valid;
end

// stage 11 facing, a lamp behind the corner gives 0
wire signed [77:0] s10_shifted = s10_product >>> (7'd30 + {1'b0, s10_half});

always @(posedge clk) if (advance) begin
    facing <= (s10_shifted < 0) ? 15'd0 : (s10_shifted > 78'sd16384) ? 15'd16384 : s10_shifted[14:0];
    d2 <= s10_d2;
    valid_out <= s10_valid;
end

endmodule

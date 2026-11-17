// inv_sqrt17.v
// 1 / sqrt(v), answer is y / 2^(17 + half)
// same as inv_sqrt but 17 bits after the point so each multiply fits one dsp block
module inv_sqrt17 (
    input wire clk,
    input wire advance,                     // 1 = every stage moves one step
    input wire [35:0] v,                    // the number, at least 1
    input wire valid_in,                    // rides along
    output reg [17:0] y,                    // 1 / sqrt(v) = y / 2^(17 + half)
    output reg [5:0] half,
    output reg valid_out
);

// stage 1 find the top 1 bit, rounded down to an even position
// even so the square root of 2^p is a whole power of 2
function [5:0] top_bit_even(input [35:0] n);
    integer i;
    begin
        top_bit_even = 0;
        for (i = 0; i < 36; i = i + 1)
            if (n[i]) top_bit_even = i[5:0];
        top_bit_even = {top_bit_even[5:1], 1'b0};          // round down to even
    end
endfunction

reg [35:0] s1_v;
reg [5:0] s1_p;
reg s1_valid;

always @(posedge clk) if (advance) begin
    s1_v <= v;
    s1_p <= top_bit_even(v);
    s1_valid <= valid_in;
end

// stage 2 shift v so m is between 1.0 and 4.0 in Q2.17
wire [52:0] s1_wide = {s1_v, 17'd0} >> s1_p;

reg [18:0] s2_m;
reg [5:0] s2_half;
reg s2_valid;

always @(posedge clk) if (advance) begin
    s2_m <= s1_wide[18:0];
    s2_half <= {1'b0, s1_p[5:1]};                          // p / 2
    s2_valid <= s1_valid;
end

// stage 3 table, first guess y0 from the top 8 bits of m
wire [16:0] s3_y0;
rsqrt_table17 guess (.clk(clk), .enable(advance), .index(s2_m[18:11]), .value(s3_y0));

reg [18:0] s3_m;
reg [5:0] s3_half;
reg s3_valid;

always @(posedge clk) if (advance) begin
    s3_m <= s2_m;
    s3_half <= s2_half;
    s3_valid <= s2_valid;
end

// stage 4 y0 squared
wire [33:0] s3_square = s3_y0 * s3_y0;

reg [16:0] s4_y0;
reg [16:0] s4_y0_squared;
reg [18:0] s4_m;
reg [5:0] s4_half;
reg s4_valid;

always @(posedge clk) if (advance) begin
    s4_y0 <= s3_y0;
    s4_y0_squared <= s3_square[33:17];
    s4_m <= s3_m;
    s4_half <= s3_half;
    s4_valid <= s3_valid;
end

// stage 5 m times y0 squared, comes out about 1.0
wire [35:0] s4_product = s4_m * s4_y0_squared;

reg [16:0] s5_y0;
reg [18:0] s5_t;
reg [5:0] s5_half;
reg s5_valid;

always @(posedge clk) if (advance) begin
    s5_y0 <= s4_y0;
    s5_t <= s4_product[35:17];
    s5_half <= s4_half;
    s5_valid <= s4_valid;
end

// stage 6 newton, y1 = y0 x (3 - m x y0^2) / 2
wire [19:0] s5_three_minus_t = 20'd393216 - {1'b0, s5_t};          // 3.0 in Q2.17
wire [36:0] s5_newton = s5_y0 * s5_three_minus_t;

always @(posedge clk) if (advance) begin
    y <= s5_newton[35:18];
    half <= s5_half;
    valid_out <= s5_valid;
end

endmodule

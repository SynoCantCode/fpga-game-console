// reciprocal.v
// works out 1 / area with a table and 2 rounds of newtons method
// pipelined, a new area can go in every clock and the answer comes out 11 clocks later

module reciprocal (
    input wire clk,
    input wire advance,              // moves the whole pipeline one stage
    input wire [35:0] area,          // must be > 0
    output wire [35:0] r,            // 1 / m in Q1.35 where area = m x 2^p
    output wire [5:0] p              // area is between 2^p and 2^(p+1)
);

localparam LATENCY = 11;

// where the highest 1 bit is
function [5:0] highest_one(input [35:0] v);
    integer i;
    begin
        highest_one = 0;
        for (i = 0; i < 36; i = i + 1)
            if (v[i]) highest_one = i;
    end
endfunction

// p and m ride along every stage
reg [5:0]  p_s [1:LATENCY];
reg [35:0] m_s [1:LATENCY];

reg [35:0] area_1;

// stage 3 first guess from the table
wire [16:0] r0_3;                    // Q0.17
reciprocal_table first_guess (.clk(clk), .enable(advance), .index(m_s[2][34:26]), .value(r0_3));

// round 1 only needs about 20 good bits so the numbers are short
reg [16:0] r0_4, r0_5, r0_6;
reg [42:0] mr_4;                     // m x r0
reg signed [17:0] d_5;               // 1 - m x r0, how far off the guess is
reg signed [35:0] rd_6;              // r0 x d
reg [26:0] r1_7, r1_8, r1_9, r1_10;   // r1 in Q1.26

// round 2 full width
reg [62:0] mr_8;                     // m x r1
reg signed [17:0] d_9;               // 1 - m x r1
reg signed [45:0] rd_10;              // r1 x d
reg [35:0] r2_11;                    // the answer in Q1.35

// the subtracts and adds
localparam signed [44:0] ONE_Q42 = 45'sd1 <<< 42;     // 1.0
localparam signed [64:0] ONE_Q61 = 65'sd1 <<< 61;     // 1.0
wire signed [44:0] miss_5  = ONE_Q42 - $signed({2'b00, mr_4});                          // 1 - m x r0
wire signed [64:0] miss_9  = ONE_Q61 - $signed({2'b00, mr_8});                          // 1 - m x r1
wire signed [37:0] r1_sum  = $signed({11'd0, r0_6, 9'd0}) + (rd_6 >>> 17);              // r0 + r0 x d
wire signed [47:0] r2_sum  = $signed({12'd0, r1_10, 9'd0}) + (rd_10 >>> 27);           // r1 + r1 x d

integer k;
always @(posedge clk) if (advance) begin
    // stage 1 find the highest 1
    p_s[1] <= highest_one(area);
    area_1 <= area;
    // stage 2 shift it to the top so m is between 1 and 2
    p_s[2] <= p_s[1];
    m_s[2] <= area_1 << (6'd35 - p_s[1]);

    for (k = 3; k <= LATENCY; k = k + 1) begin
        p_s[k] <= p_s[k - 1];
        m_s[k] <= m_s[k - 1];
    end

    // stage 4 m x r0
    r0_4 <= r0_3;
    mr_4 <= m_s[3][35:10] * r0_3;
    // stage 5 d = 1 - m x r0
    r0_5 <= r0_4;
    d_5 <= miss_5 >>> 16;
    // stage 6 r0 x d
    r0_6 <= r0_5;
    rd_6 <= $signed({1'b0, r0_5}) * d_5;
    // stage 7 r1 = r0 + r0 x d
    r1_7 <= r1_sum[26:0];

    // stage 8 m x r1
    r1_8 <= r1_7;
    mr_8 <= m_s[7] * r1_7;
    // stage 9 d = 1 - m x r1
    r1_9 <= r1_8;
    d_9 <= miss_9 >>> 25;
    // stage 10 r1 x d
    r1_10 <= r1_9;
    rd_10 <= $signed({1'b0, r1_9}) * d_9;
    // stage 11 r2 = r1 + r1 x d
    r2_11 <= r2_sum[35:0];
end

assign r = r2_11;
assign p = p_s[LATENCY];

endmodule

// fog.v
// blends a quads 4 pixel colours toward the fog colour, more the further away it is
// pixel = colour + (fog colour - colour) x f, f comes from a table looked up by distance

module fog #(
    parameter WAIT = 12                      // clocks the fog amount waits for the pixel colours
) (
    input wire clk,

    // the quad going in
    input wire [31:0] q_in,                  // q at the quads centre, bigger = closer, 0 counts as 1
    input wire fogged_in,                    // 1 = fog this quad

    // the quads 4 pixel colours, WAIT + 4 clocks after its q
    input wire [127:0] pixels_in,            // pixel i is 0xAARRGGBB at [i x 32]
    output wire [127:0] pixels_out,          // 3 clocks later

    // settings
    input wire [23:0] fog_colour,            // 0xRRGGBB
    input wire table_write,                  // 1 for one clock, writes table_word to table_row
    input wire [7:0] table_row,
    input wire [15:0] table_word             // this rows f in bits 0-7, next rows f in bits 8-15
);

// where the top 1 bit of a 32 bit number is
function [4:0] top_bit(input [31:0] v);
    integer b;
    begin
        top_bit = 5'd0;
        for (b = 1; b < 32; b = b + 1)
            if (v[b]) top_bit = b[4:0];
    end
endfunction

// stage a1 find the top bit of q
reg [31:0] a1_q;
reg [4:0] a1_p;
reg a1_fogged;
wire [31:0] q_or_1 = (q_in == 32'd0) ? 32'd1 : q_in;
always @(posedge clk) begin
    a1_q <= q_or_1;
    a1_p <= top_bit(q_or_1);
    a1_fogged <= fogged_in;
end

// stage a2 the table row and the fraction toward the next row
wire [31:0] a1_shifted = a1_q << (5'd31 - a1_p);          // top bit moved to position 31
wire [4:0] a1_e = 5'd31 - a1_p;                           // which doubling of the distance
wire a1_beyond = (a1_e > 5'd15);                          // past the end of the table, use the last row
reg [7:0] a2_row, a2_fraction;
reg a2_fogged;
always @(posedge clk) begin
    a2_row <= a1_beyond ? 8'd255 : {a1_e[3:0], ~a1_shifted[30:27]};
    a2_fraction <= a1_beyond ? 8'd0 : ~a1_shifted[26:19];
    a2_fogged <= a1_fogged;
end

// stage a3 read the table, 256 rows of 16 bits
reg [15:0] rows [0:255];
reg [15:0] a3_word;
reg [7:0] a3_fraction;
reg a3_fogged;
integer init_i;
initial for (init_i = 0; init_i < 256; init_i = init_i + 1) rows[init_i] = 16'd0;      // no fog until its filled
always @(posedge clk) begin
    if (table_write) rows[table_row] <= table_word;
    a3_word <= rows[a2_row];
    a3_fraction <= a2_fraction;
    a3_fogged <= a2_fogged;
end

// stage a3b hold the table output in plain registers, ram output is slow
reg [15:0] a3b_word;
reg [7:0] a3b_fraction;
reg a3b_fogged;
always @(posedge clk) begin
    a3b_word <= a3_word;
    a3b_fraction <= a3_fraction;
    a3b_fogged <= a3_fogged;
end

// stage a4 this row x (256 - fraction) and next row x fraction
wire [8:0] a3_rest = 9'd256 - {1'b0, a3b_fraction};
wire [16:0] a3_this_part /* synthesis syn_dspstyle = "logic" */;
wire [15:0] a3_next_part /* synthesis syn_dspstyle = "logic" */;
assign a3_this_part = a3b_word[7:0] * a3_rest;
assign a3_next_part = a3b_word[15:8] * a3b_fraction;
// syn_preserve so the tools dont move these registers past the add
(* syn_preserve = 1 *) reg [16:0] a4_this_part;
(* syn_preserve = 1 *) reg [15:0] a4_next_part;
reg a4_fogged;
always @(posedge clk) begin
    a4_this_part <= a3_this_part;
    a4_next_part <= a3_next_part;
    a4_fogged <= a3b_fogged;
end

// stage a5 the fog amount, 255 counts as fully fogged, 0 if not fogged
wire [16:0] a4_sum = a4_this_part + {1'b0, a4_next_part};
wire [7:0] a4_f8 = a4_sum[15:8];
reg [8:0] a5_amount;                                      // 0 to 256
always @(posedge clk)
    a5_amount <= a4_fogged ? ({1'b0, a4_f8} + {8'd0, a4_f8[7]}) : 9'd0;

// the amount waits in a shift register until its pixels show up
reg [(WAIT-1)*9-1:0] wait_amount;
always @(posedge clk) wait_amount <= {wait_amount[(WAIT-2)*9-1:0], a5_amount};
wire [8:0] amount = wait_amount[(WAIT-2)*9 +: 9];

// stages b0 b1 b2 for each pixel i and channel ch (0 blue 1 green 2 red)
reg [127:0] b0_pixels, b1_pixels;                         // the colours as they came in
always @(posedge clk) begin
    b0_pixels <= pixels_in;
    b1_pixels <= b0_pixels;
end

genvar i, ch;
generate
    for (i = 0; i < 4; i = i + 1) begin : pixel
        for (ch = 0; ch < 3; ch = ch + 1) begin : chan
            wire [7:0] c_in = pixels_in[i * 32 + ch * 8 +: 8];
            reg signed [9:0] b0_difference;               // b0 fog - colour
            always @(posedge clk) b0_difference <= $signed({2'b00, fog_colour[ch * 8 +: 8]}) - $signed({2'b00, c_in});
            // b1 times the amount
            wire signed [19:0] product /* synthesis syn_dspstyle = "logic" */;
            assign product = b0_difference * $signed({1'b0, amount});
            reg signed [19:0] b1_product;
            always @(posedge clk) b1_product <= product;
            // b2 colour + (product + 128) / 256, always fits 8 bits
            wire signed [19:0] rounded = (b1_product + 20'sd128) >>> 8;
            wire [7:0] c_b1 = b1_pixels[i * 32 + ch * 8 +: 8];
            wire [9:0] sum = {2'b00, c_b1} + rounded[9:0];
            reg [7:0] b2_c;
            always @(posedge clk) b2_c <= sum[7:0];
            assign pixels_out[i * 32 + ch * 8 +: 8] = b2_c;
        end
        reg [7:0] b2_alpha;                               // alpha passes through
        always @(posedge clk) b2_alpha <= b1_pixels[i * 32 + 24 +: 8];
        assign pixels_out[i * 32 + 24 +: 8] = b2_alpha;
    end
endgenerate

endmodule

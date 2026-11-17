// lamp_fade.v
// how much a lamp fades with distance, looked up in a table the program fills
// 256 rows spaced by doublings of distance squared, 16 rows per doubling
// blends between this row and the next
module lamp_fade (
    input wire clk,
    input wire advance,                     // 1 = every stage moves one step
    input wire valid_in,                    // rides along
    input wire [55:0] d2,                   // distance squared

    // settings
    input wire signed [3:0] range,          // slides the table closer or farther
    input wire table_write,                 // write one row
    input wire [7:0] table_row,
    input wire [15:0] table_word,           // this rows fade in bits 0-7, the next rows in 8-15

    // out
    output reg [8:0] fade,                  // 0 to 256
    output reg valid_out
);

// where the top 1 bit is
function [5:0] top_bit(input [55:0] v);
    integer b;
    begin
        top_bit = 6'd0;
        for (b = 1; b < 56; b = b + 1)
            if (v[b]) top_bit = b[5:0];
    end
endfunction

// stage 1 find the top bit
reg [55:0] s1_d2;
reg [5:0] s1_p;
reg s1_valid;

always @(posedge clk) if (advance) begin
    s1_d2 <= d2;
    s1_p <= top_bit(d2);
    s1_valid <= valid_in;
end

// stage 2 the row and the fraction
wire signed [7:0] s1_e = $signed({2'b00, s1_p}) - 8'sd24 - {{4{range[3]}}, range};      // which doubling
wire [55:0] s1_shifted = s1_d2 << (6'd55 - s1_p);       // top bit moved to bit 55

reg [7:0] s2_row, s2_fraction;
reg s2_valid;

always @(posedge clk) if (advance) begin
    if (s1_e < 0) begin                                 // closer than the table, first row
        s2_row <= 8'd0;
        s2_fraction <= 8'd0;
    end else if (s1_e > 15) begin                       // farther than the table, last row
        s2_row <= 8'd255;
        s2_fraction <= 8'd0;
    end else begin
        s2_row <= {s1_e[3:0], s1_shifted[54:51]};
        s2_fraction <= s1_shifted[50:43];
    end
    s2_valid <= s1_valid;
end

// stage 3 read the table
reg [15:0] rows [0:255];
reg [15:0] s3_word;
reg [7:0] s3_fraction;
reg s3_valid;

integer init_i;
initial for (init_i = 0; init_i < 256; init_i = init_i + 1) rows[init_i] = 16'd0;    // dark until filled

always @(posedge clk) begin
    if (table_write) rows[table_row] <= table_word;
    if (advance) begin
        s3_word <= rows[s2_row];
        s3_fraction <= s2_fraction;
        s3_valid <= s2_valid;
    end
end

// stage 4 the two halves of the blend
wire [8:0] s3_rest = 9'd256 - {1'b0, s3_fraction};
wire [16:0] s3_this_part /* synthesis syn_dspstyle = "logic" */;
wire [15:0] s3_next_part /* synthesis syn_dspstyle = "logic" */;
assign s3_this_part = s3_word[7:0] * s3_rest;
assign s3_next_part = s3_word[15:8] * s3_fraction;

reg [16:0] s4_this_part;
reg [15:0] s4_next_part;
reg s4_valid;

always @(posedge clk) if (advance) begin
    s4_this_part <= s3_this_part;
    s4_next_part <= s3_next_part;
    s4_valid <= s3_valid;
end

// stage 5 add them, / 256
wire [16:0] s4_sum = s4_this_part + {1'b0, s4_next_part};
wire [7:0] s4_f8 = s4_sum[15:8];

always @(posedge clk) if (advance) begin
    fade <= {1'b0, s4_f8} + {8'd0, s4_f8[7]};           // 255 counts as 256
    valid_out <= s4_valid;
end

endmodule

// debug_strip.v
// debug only, draws 8 squares in the top left corner
// square k is green when flag k is 1, red when 0

module debug_strip (
    input wire pixel_clk,
    input wire [10:0] x,
    input wire [9:0] y,
    input wire [7:0] flags,                 // can come from any clock
    input wire [7:0] red_in, green_in, blue_in,
    output reg [7:0] red_out, green_out, blue_out
);

reg [7:0] flags_s1, flags_s2;               // 2 flip flops into the pixel clock

// which square this pixel is in, if any
wire in_row = (y >= 10'd8) && (y < 10'd40);
wire [10:0] dx = x - 11'd8;
wire [2:0] square = dx / 11'd40;
wire in_square = in_row && (x >= 11'd8) && (dx < 11'd320) && ((dx % 11'd40) < 11'd32);

always @(posedge pixel_clk) begin
    flags_s1 <= flags;
    flags_s2 <= flags_s1;
    if (in_square) begin
        red_out   <= flags_s2[square] ? 8'd0   : 8'd255;
        green_out <= flags_s2[square] ? 8'd255 : 8'd0;
        blue_out  <= 8'd0;
    end else begin
        red_out <= red_in;  green_out <= green_in;  blue_out <= blue_in;
    end
end

endmodule

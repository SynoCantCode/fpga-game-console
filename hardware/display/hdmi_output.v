// hdmi_output.v
// sends the three 10 bit codes out the hdmi port one bit at a time
// uses gowins OSER10 serializer and ELVDS_OBUF wire pair output

module hdmi_output (
    input wire pixel_clk,         // a new set of codes every tick
    input wire serial_clk,        // 5x faster, the serializer sends 2 bits per tick of this
    input wire reset,
    input wire [9:0] blue_code,   // lane 0, also carries the syncs
    input wire [9:0] green_code,  // lane 1
    input wire [9:0] red_code,    // lane 2
    output wire [2:0] data_p,     // the 3 color lanes, + wires
    output wire [2:0] data_n,     // - wires
    output wire clock_p,          // clock lane +
    output wire clock_n           // clock lane -
);

// serialize each lane, 10 bits in and out one at a time, bit 0 first
wire [2:0] serial_bit;

OSER10 serialize_blue (
    .D0(blue_code[0]), .D1(blue_code[1]), .D2(blue_code[2]), .D3(blue_code[3]), .D4(blue_code[4]),
    .D5(blue_code[5]), .D6(blue_code[6]), .D7(blue_code[7]), .D8(blue_code[8]), .D9(blue_code[9]),
    .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(reset),
    .Q(serial_bit[0])
);

OSER10 serialize_green (
    .D0(green_code[0]), .D1(green_code[1]), .D2(green_code[2]), .D3(green_code[3]), .D4(green_code[4]),
    .D5(green_code[5]), .D6(green_code[6]), .D7(green_code[7]), .D8(green_code[8]), .D9(green_code[9]),
    .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(reset),
    .Q(serial_bit[1])
);

OSER10 serialize_red (
    .D0(red_code[0]), .D1(red_code[1]), .D2(red_code[2]), .D3(red_code[3]), .D4(red_code[4]),
    .D5(red_code[5]), .D6(red_code[6]), .D7(red_code[7]), .D8(red_code[8]), .D9(red_code[9]),
    .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(reset),
    .Q(serial_bit[2])
);

// each lane out on its wire pair
ELVDS_OBUF pair_blue  (.I(serial_bit[0]), .O(data_p[0]), .OB(data_n[0]));
ELVDS_OBUF pair_green (.I(serial_bit[1]), .O(data_p[1]), .OB(data_n[1]));
ELVDS_OBUF pair_red   (.I(serial_bit[2]), .O(data_p[2]), .OB(data_n[2]));

// the clock lane is just the pixel clock on its own pair
ELVDS_OBUF pair_clock (.I(pixel_clk), .O(clock_p), .OB(clock_n));

endmodule

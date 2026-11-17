// display_top.v
// display test top, 50 MHz in and a 720p test picture out the hdmi port
// crystal > pll > video_timing > test_picture > 3 tmds encoders > hdmi_output

module display_top (
    input wire clk_50,               // 50 MHz crystal
    output wire [2:0] tmds_data_p,   // hdmi color lanes +
    output wire [2:0] tmds_data_n,   // hdmi color lanes -
    output wire tmds_clock_p,        // hdmi clock lane +
    output wire tmds_clock_n         // hdmi clock lane -
);

// pixel and serial clocks
wire pixel_clk, serial_clk, pll_locked;

display_pll pll (
    .clkin(clk_50), .clkout0(pixel_clk), .clkout1(serial_clk), .lock(pll_locked)
);

// hold reset until the pll is locked
reg [1:0] reset_delay = 2'b11;

always @(posedge pixel_clk or negedge pll_locked) begin
    if (!pll_locked)
        reset_delay <= 2'b11;
    else
        reset_delay <= {reset_delay[0], 1'b0};
end

wire reset = reset_delay[1];

// where we are on screen
wire [10:0] x;
wire [9:0] y;
wire visible, hsync, vsync;

video_timing timing (
    .clk(pixel_clk), .reset(reset),
    .x(x), .y(y), .visible(visible), .hsync(hsync), .vsync(vsync)
);

// moving box, steps right every frame and wraps at the edge
localparam BOX_STEP = 8;
reg [10:0] box_x = 0;

always @(posedge pixel_clk) begin
    if (reset)
        box_x <= 0;
    else if (x == 1649 && y == 749)               // last tick of a frame
        box_x <= (box_x >= 1280 - BOX_STEP) ? 0 : box_x + BOX_STEP;
end

// what color this pixel is
wire [7:0] red, green, blue;

test_picture picture (
    .x(x), .y(y), .box_x(box_x), .red(red), .green(green), .blue(blue)
);

// colors to 10 bit codes, the blue lane also carries the syncs
wire [9:0] blue_code, green_code, red_code;

tmds_encoder encode_blue  (.clk(pixel_clk), .visible(visible), .color(blue),  .control({vsync, hsync}), .tmds(blue_code));
tmds_encoder encode_green (.clk(pixel_clk), .visible(visible), .color(green), .control(2'b00),          .tmds(green_code));
tmds_encoder encode_red   (.clk(pixel_clk), .visible(visible), .color(red),   .control(2'b00),          .tmds(red_code));

// codes to the hdmi wires
hdmi_output out (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset(reset),
    .blue_code(blue_code), .green_code(green_code), .red_code(red_code),
    .data_p(tmds_data_p), .data_n(tmds_data_n),
    .clock_p(tmds_clock_p), .clock_n(tmds_clock_n)
);

endmodule

// test_picture.v
// test picture, 8 color bars with a red border and a box sliding across
// no memory needed, the color comes straight from x, y and box_x

module test_picture (
    input wire [10:0] x,       // which pixel of the row
    input wire [9:0] y,        // which row
    input wire [10:0] box_x,   // left edge of the moving box
    output reg [7:0] red,
    output reg [7:0] green,
    output reg [7:0] blue
);

localparam WIDTH = 1280;
localparam HEIGHT = 720;
localparam BAR_WIDTH = 160;   // 8 bars

wire on_border = (x == 0) || (x == WIDTH - 1) || (y == 0) || (y == HEIGHT - 1);
wire [2:0] bar = x / BAR_WIDTH;   // which bar this pixel is in

// the moving box, shows the bars color flipped so it stands out
localparam BOX_SIZE = 80;
localparam BOX_TOP = 320;
wire in_box = (x >= box_x) && (x < box_x + BOX_SIZE) && (y >= BOX_TOP) && (y < BOX_TOP + BOX_SIZE);

always @(*) begin
    if (on_border) begin
        red = 255; green = 0; blue = 0;          // red border
    end else begin
        case (bar)
            0: begin red = 255; green = 255; blue = 255; end   // white
            1: begin red = 255; green = 255; blue = 0;   end   // yellow
            2: begin red = 0;   green = 255; blue = 255; end   // cyan
            3: begin red = 0;   green = 255; blue = 0;   end   // green
            4: begin red = 255; green = 0;   blue = 255; end   // magenta
            5: begin red = 255; green = 0;   blue = 0;   end   // red
            6: begin red = 0;   green = 0;   blue = 255; end   // blue
            7: begin red = 0;   green = 0;   blue = 0;   end   // black
        endcase
        if (in_box) begin
            red = 255 - red; green = 255 - green; blue = 255 - blue;   // flipped color
        end
    end
end

endmodule

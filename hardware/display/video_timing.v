// video_timing.v
// counts across every pixel of 1280x720 at 60hz (720p)
// one clock tick = one pixel

module video_timing (
    input wire clk,
    input wire reset,
    output reg [10:0] x,
    output reg [9:0] y,
    output wire hsync,
    output wire visible,
    output wire vsync
);

// one row in pixels
localparam H_VISIBLE = 1280;
localparam H_FRONT_PORCH = 110;
localparam H_SYNC = 40;
localparam H_BACK_PORCH = 220;
localparam H_TOTAL = H_VISIBLE + H_FRONT_PORCH + H_SYNC + H_BACK_PORCH; // 1650

// row counter

wire at_end_of_row = (x == H_TOTAL - 1);

always @(posedge clk) begin
    if (reset) begin
        x <= 0;
    end else if (at_end_of_row) begin
        x <= 0;
    end else begin
        x <= x + 1;
    end
end

// one frame in rows
localparam V_VISIBLE = 720;
localparam V_FRONT_PORCH = 5;
localparam V_SYNC = 5;
localparam V_BACK_PORCH = 20;
localparam V_TOTAL = V_VISIBLE + V_FRONT_PORCH + V_SYNC + V_BACK_PORCH; // 750

// frame counter, one row further each time
wire at_end_of_frame = (y == V_TOTAL - 1);

always @(posedge clk) begin
    if (reset) begin
        y <= 0;
    end else if (at_end_of_row) begin
        if (at_end_of_frame) begin
            y <= 0;
        end else begin
            y <= y + 1;
        end
    end
end

// signals for the tv
localparam H_SYNC_START = H_VISIBLE + H_FRONT_PORCH;
localparam H_SYNC_END = H_VISIBLE + H_FRONT_PORCH + H_SYNC;
localparam V_SYNC_START = V_VISIBLE + V_FRONT_PORCH;
localparam V_SYNC_END = V_VISIBLE + V_FRONT_PORCH + V_SYNC;

assign visible = (x < H_VISIBLE) && (y < V_VISIBLE);
assign hsync = (x >= H_SYNC_START) && (x < H_SYNC_END);
assign vsync = (y >= V_SYNC_START) && (y < V_SYNC_END);

endmodule

// frame_buffers.v
// keeps track of the 3 frame buffers so the gpu never draws into the one on the tv
// one is showing, one may be ready (finished, waiting) and one may be drawing
// nothing is copied, swapping just gives the frame reader a different start address

module frame_buffers #(
    parameter [24:0] BUFFER0 = 25'd0,             // where each buffer starts in ddr3, in 32 byte bursts
    parameter [24:0] BUFFER1 = 25'd115200,
    parameter [24:0] BUFFER2 = 25'd230400
) (
    input wire clk,
    input wire reset,

    // frame reader
    output wire [24:0] show_start,      // buffer to show from the next top of the picture
    input wire switched,                // pulse, the frame reader took show_start

    // gpu
    output wire draw_ok,                // 1 = the gpu may start a frame
    output wire [24:0] draw_start,      // the buffer to draw into
    input wire draw_begin,              // pulse, gpu starts drawing
    input wire draw_end,                // pulse, gpu finished the frame

    // state, for looking at
    output reg [1:0] showing,           // which buffer is on the tv
    output reg ready_valid,
    output reg [1:0] ready,
    output reg drawing_valid,
    output reg [1:0] drawing
);

function [24:0] start_of(input [1:0] n);
    start_of = (n == 2'd0) ? BUFFER0 : (n == 2'd1) ? BUFFER1 : BUFFER2;
endfunction

// buffer to show next, and the free one
wire [1:0] to_show = ready_valid ? ready : showing;
wire [1:0] free = ready_valid ? (2'd3 - showing - ready)            // 0 + 1 + 2 = 3 so this is the one left
                              : ((showing == 2'd0) ? 2'd1 : 2'd0);  // nothing ready, any but the showing one

assign show_start = start_of(to_show);
assign draw_ok = !drawing_valid;
assign draw_start = start_of(free);

always @(posedge clk) begin
    if (reset) begin
        showing <= 2'd0;
        ready_valid <= 1'b0;
        ready <= 2'd0;
        drawing_valid <= 1'b0;
        drawing <= 2'd0;
    end else begin
        // tv moves to the ready buffer if there is one
        if (switched) showing <= to_show;

        // the finished frame becomes ready, a newer one replaces an older one
        if (draw_end) begin
            ready <= drawing;
            ready_valid <= 1'b1;
            drawing_valid <= 1'b0;
        end else if (switched)
            ready_valid <= 1'b0;

        // gpu starts a frame in the free buffer
        if (draw_begin && draw_ok) begin
            drawing <= free;
            drawing_valid <= 1'b1;
        end
    end
end

endmodule

// screen_check.v
// sums each row of pixels as it goes to the tv so the cpu can check whats really on screen
// registers  0x00 start  0x04 status  0x08 row  0x0C that rows sum
// the summing runs on the pixel clock, the registers on the device clock

`default_nettype none

module screen_check (
    // the picture going to the hdmi encoders
    input wire pixel_clk,
    input wire pixel_reset,
    input wire visible,              // 1 = a pixel of the picture
    input wire vsync,                // frame sync pulse
    input wire [7:0] red,
    input wire [7:0] green,
    input wire [7:0] blue,

    // cpu side, from the device hub
    input wire dev_clk,
    input wire dev_reset,
    input wire reg_write,
    input wire reg_read,
    input wire [4:0] reg_offset,
    input wire [31:0] reg_wdata,
    output reg [31:0] reg_rdata
);

localparam ROWS = 720;

// device side, start out, done in, sums read back
reg start_flip;                  // flips once per start
reg done_flip_s1, done_flip_s2;  // the pixel sides done toggle through 2 flip flops
reg done_seen_flip;              // the done toggle at the last start, done = they differ
reg [9:0] read_row;
wire [31:0] read_sum;            // the rams answer one clock after the address
reg waiting_s1, waiting_s2, summing_s1, summing_s2;   // pixel side state for status
wire waiting_p, summing_p;
reg done_flip_p;
reg waiting, summing;

always @(posedge dev_clk) begin
    if (dev_reset) begin
        start_flip <= 1'b0;
        done_seen_flip <= 1'b0;
        done_flip_s1 <= 1'b0;  done_flip_s2 <= 1'b0;
        read_row <= 10'd0;
        reg_rdata <= 32'd0;
        waiting_s1 <= 1'b0;  waiting_s2 <= 1'b0;  summing_s1 <= 1'b0;  summing_s2 <= 1'b0;
    end else begin
        done_flip_s1 <= done_flip_p;  done_flip_s2 <= done_flip_s1;
        waiting_s1 <= waiting_p;      waiting_s2 <= waiting_s1;
        summing_s1 <= summing_p;      summing_s2 <= summing_s1;
        if (reg_write) begin
            case (reg_offset)
                5'h00: if (reg_wdata[0]) begin
                           start_flip <= !start_flip;
                           done_seen_flip <= done_flip_s2;     // done reads 0 until the pixel side flips again
                       end
                5'h08: read_row <= reg_wdata[9:0];
                default: ;
            endcase
        end
        if (reg_read) begin
            case (reg_offset)
                5'h04:   reg_rdata <= {29'd0, summing_s2, waiting_s2, (done_flip_s2 != done_seen_flip)};
                5'h0C:   reg_rdata <= read_sum;
                default: reg_rdata <= 32'd0;
            endcase
        end
    end
end

// pixel side, wait for a frame then sum 720 rows
reg start_s1, start_s2, start_seen;    // the start toggle through 2 flip flops
assign waiting_p = waiting;
assign summing_p = summing;
reg last_visible, last_vsync;
reg [9:0] row;                   // the row being summed
reg [31:0] sum;                  // this rows sum so far
reg write_now;                   // a row just ended, store its sum
reg [9:0] write_row;
reg [31:0] write_sum;

always @(posedge pixel_clk) begin
    if (pixel_reset) begin
        start_s1 <= 1'b0;  start_s2 <= 1'b0;  start_seen <= 1'b0;
        done_flip_p <= 1'b0;
        waiting <= 1'b0;  summing <= 1'b0;
        last_visible <= 1'b0;  last_vsync <= 1'b0;
        row <= 10'd0;  sum <= 32'd0;
        write_now <= 1'b0;
    end else begin
        start_s1 <= start_flip;  start_s2 <= start_s1;
        last_visible <= visible;
        last_vsync <= vsync;
        write_now <= 1'b0;
        if (start_s2 != start_seen) begin                 // new start, wait for the gap between frames
            start_seen <= start_s2;
            waiting <= 1'b1;
            summing <= 1'b0;
        end
        if (waiting && vsync && !last_vsync) begin        // sync pulse, next visible pixel is the first of row 0
            waiting <= 1'b0;
            summing <= 1'b1;
            row <= 10'd0;
            sum <= 32'd0;
        end
        if (summing) begin
            if (visible)
                sum <= sum + {8'd0, red, green, blue};
            if (last_visible && !visible) begin           // row ended
                write_now <= 1'b1;
                write_row <= row;
                write_sum <= sum;
                sum <= 32'd0;
                if (row == ROWS - 1) begin
                    summing <= 1'b0;
                    done_flip_p <= !done_flip_p;
                end else
                    row <= row + 10'd1;
            end
        end
    end
end

// the 720 sums, written on the pixel clock and read on the device clock
reg [31:0] sums [0:ROWS-1];
reg [31:0] read_sum_r;
assign read_sum = read_sum_r;
always @(posedge pixel_clk) begin
    if (write_now) sums[write_row] <= write_sum;
end
always @(posedge dev_clk) begin
    read_sum_r <= sums[read_row];
end

endmodule

`default_nettype wire

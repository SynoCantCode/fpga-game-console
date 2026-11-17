// tile_writeout.v
// takes a finished 64x32 tile out of tile_memory and writes it to the frame buffer in ddr3
// averages each pixels 2 aa samples into one colour on the way
// a reader fills strip buffers (8x2 pixels) while a sender writes them out

module tile_writeout (
    input wire clk,
    input wire reset,

    // orders
    input wire start,                     // 1 for one clock, begin on the tile
    input wire send_to_memory,            // 1 = write it to the frame buffer, 0 = only wipe it
    input wire [4:0] tile_x,              // which tile across
    input wire [4:0] tile_y,              // which tile down
    input wire [24:0] frame_start_burst,  // where the frame buffer begins in ddr3, in bursts
    output wire busy,                     // 1 = working on a tile
    output reg done,                      // 1 for one clock, tile written and wiped

    // to tile_memory
    output wire [9:0] out_quad,
    output wire out_take,
    input wire [255:0] out_colour,      // a quads 8 sample colours

    // to the memory port
    output reg req,
    output wire [2:0] cmd,
    output wire [28:0] addr,
    output wire [255:0] wr_data,
    output wire [31:0] wr_mask,
    input wire grant
);

localparam CMD_WRITE = 3'b000;
localparam SCREEN_HEIGHT = 720;

// the job, latched at start
reg running;
reg [4:0] tx;
reg [4:0] ty;
reg [24:0] base;
reg sending;

// burst number of row y = y*160 + tile*8 + strip
function [24:0] burst_of(input [9:0] y, input [4:0] tile, input [2:0] strip);
    burst_of = ({15'd0, y} << 7) + ({15'd0, y} << 5) + {17'd0, tile, strip};
endfunction

// resolve, each pixels 2 samples become one colour, rounded average per channel
function [31:0] average2(input [63:0] samples);
    integer c;
    reg [8:0] sum;
    begin
        for (c = 0; c < 4; c = c + 1) begin
            sum = samples[c * 8 +: 8] + samples[32 + c * 8 +: 8] + 9'd1;
            average2[c * 8 +: 8] = sum[8:1];
        end
    end
endfunction
wire [127:0] resolved = {average2(out_colour[255:192]), average2(out_colour[191:128]),
                         average2(out_colour[127:64]), average2(out_colour[63:0])};       // pixels 3 2 1 0

// the two strip buffers, top row and bottom row of 8 pixels each
// plain registers written at fixed bit positions, not arrays, so synthesis doesnt turn them into ram
reg [255:0] buf_top0, buf_top1, buf_bottom0, buf_bottom1;
reg [1:0] buf_full;              // 1 = buffer holds a whole strip waiting to be sent
// where each buffers strip is in the tile
reg [4:0] buf_row0, buf_row1;
reg [2:0] buf_strip0, buf_strip1;

// the reader, asks tile_memory for one quad per clock
reg reading;                     // strips left to read
reg [4:0] quad_row;              // which pair of pixel rows
reg [2:0] strip;                 // which strip across
reg [1:0] q;                     // which quad of the strip
reg fill;                        // which buffer gets filled next

// only start a strip when its buffer is free
wire can_ask = reading && ((q != 0) || !buf_full[fill]);
wire last_strip = (quad_row == 5'd15) && (strip == 3'd7);

// tile_memory address is {quad y, quad x}
assign out_quad = {quad_row, strip, q};
assign out_take = can_ask;

// the answer comes one clock later so remember where it goes
reg answer_coming;
reg [1:0] answer_slot;           // which quad of its strip
reg answer_buf;                  // which buffer
reg [4:0] answer_row;
reg [2:0] answer_strip;

// the sender, writes full buffers to ddr3
// top bursts go out right away, bottom bursts are parked and sent 8 in a row
// so writes stay on neighbouring addresses
localparam SEND_IDLE    = 2'd0;
localparam SEND_TOP     = 2'd1;  // sending a strips top row burst
localparam SEND_BOTTOMS = 2'd2;  // sending the 8 parked bottom row bursts
reg [1:0] sender;
reg [2:0] bottom_k;              // which parked bottom is being sent
reg [9:0] band_bottom_y;         // the bands bottom pixel row
// parked bottom bursts, plain registers again
reg [255:0] park0, park1, park2, park3, park4, park5, park6, park7;
reg [255:0] park_out;            // the parked burst being sent
always @(*) begin
    case (bottom_k)
        3'd0: park_out = park0;  3'd1: park_out = park1;  3'd2: park_out = park2;  3'd3: park_out = park3;
        3'd4: park_out = park4;  3'd5: park_out = park5;  3'd6: park_out = park6;  default: park_out = park7;
    endcase
end
reg send;                        // which buffer gets sent next
reg [24:0] write_burst;          // worked out a clock early

wire [4:0] buf_row_send   = send ? buf_row1 : buf_row0;          // row and strip of the buffer being sent
wire [2:0] buf_strip_send = send ? buf_strip1 : buf_strip0;
wire [9:0] send_top_y    = {ty, buf_row_send[3:0], 1'b0};     // tile_y*32 + quad_row*2
wire [9:0] send_bottom_y = {ty, buf_row_send[3:0], 1'b1};     // the row under it

assign cmd = CMD_WRITE;
assign addr = {1'b0, write_burst, 3'b000};
assign wr_data = (sender == SEND_TOP) ? (send ? buf_top1 : buf_top0) : park_out;
assign wr_mask = 32'd0;                                    // write all 32 bytes
assign busy = running;

// pixels into the strip buffers, no reset since they are only read when buf_full is set
// one block per slot so each writes a fixed 64 bits
genvar bs;
generate
    for (bs = 0; bs < 4; bs = bs + 1) begin : strip_slot
        always @(posedge clk) begin
            if (answer_coming && answer_slot == bs && !answer_buf) begin
                buf_top0[bs * 64 +: 64]    <= resolved[63:0];
                buf_bottom0[bs * 64 +: 64] <= resolved[127:64];
            end
            if (answer_coming && answer_slot == bs && answer_buf) begin
                buf_top1[bs * 64 +: 64]    <= resolved[63:0];
                buf_bottom1[bs * 64 +: 64] <= resolved[127:64];
            end
        end
    end
endgenerate

// park the bottom burst when the sender picks the strip up
wire parking = (sender == SEND_IDLE) && buf_full[send];
wire [255:0] bottom_send = send ? buf_bottom1 : buf_bottom0;
always @(posedge clk) begin
    if (parking && buf_strip_send == 3'd0) park0 <= bottom_send;
    if (parking && buf_strip_send == 3'd1) park1 <= bottom_send;
    if (parking && buf_strip_send == 3'd2) park2 <= bottom_send;
    if (parking && buf_strip_send == 3'd3) park3 <= bottom_send;
    if (parking && buf_strip_send == 3'd4) park4 <= bottom_send;
    if (parking && buf_strip_send == 3'd5) park5 <= bottom_send;
    if (parking && buf_strip_send == 3'd6) park6 <= bottom_send;
    if (parking && buf_strip_send == 3'd7) park7 <= bottom_send;
end

// the main block
always @(posedge clk) begin
    if (reset) begin
        running <= 1'b0;
        reading <= 1'b0;
        buf_full <= 2'b00;
        answer_coming <= 1'b0;
        sender <= SEND_IDLE;
        req <= 1'b0;
        done <= 1'b0;
    end else begin
        done <= 1'b0;

        // new tile
        if (start && !running) begin
            tx <= tile_x;
            ty <= tile_y;
            base <= frame_start_burst;
            sending <= send_to_memory;
            running <= 1'b1;
            reading <= 1'b1;
            quad_row <= 0;  strip <= 0;  q <= 0;
            fill <= 1'b0;
            send <= 1'b0;
        end

        // reader asks for a quad and steps to the next
        answer_coming <= can_ask;
        answer_slot <= q;
        answer_buf <= fill;
        answer_row <= quad_row;
        answer_strip <= strip;
        if (can_ask) begin
            q <= q + 1'b1;                                    // wraps by itself
            if (q == 2'd3) begin                              // last quad of the strip
                fill <= !fill;
                if (last_strip) reading <= 1'b0;
                else begin
                    strip <= strip + 1'b1;                    // wraps by itself
                    if (strip == 3'd7) quad_row <= quad_row + 1'b1;
                end
            end
        end

        // an answer arrived
        if (answer_coming) begin
            if (answer_slot == 2'd3) begin                    // strip is whole
                buf_full[answer_buf] <= 1'b1;
                if (answer_buf) begin buf_row1 <= answer_row;  buf_strip1 <= answer_strip; end
                else            begin buf_row0 <= answer_row;  buf_strip0 <= answer_strip; end
            end
        end

        // sender
        case (sender)
            SEND_IDLE: begin
                if (buf_full[send]) begin
                    req <= sending && (send_top_y < SCREEN_HEIGHT);
                    write_burst <= base + burst_of(send_top_y, tx, buf_strip_send);
                    sender <= SEND_TOP;
                end
            end
            SEND_TOP: begin
                if (!req || grant) begin                      // granted or nothing to send
                    buf_full[send] <= 1'b0;
                    send <= !send;
                    band_bottom_y <= send_bottom_y;
                    if (buf_strip_send == 3'd7) begin         // last strip of the band, now the 8 bottoms
                        bottom_k <= 3'd0;
                        req <= sending && (send_bottom_y < SCREEN_HEIGHT);
                        write_burst <= base + burst_of(send_bottom_y, tx, 3'd0);
                        sender <= SEND_BOTTOMS;
                    end else begin
                        req <= 1'b0;
                        sender <= SEND_IDLE;
                    end
                end
            end
            SEND_BOTTOMS: begin
                if (!req || grant) begin
                    if (bottom_k == 3'd7) begin
                        req <= 1'b0;
                        sender <= SEND_IDLE;
                    end else begin
                        bottom_k <= bottom_k + 1'b1;
                        req <= sending && (band_bottom_y < SCREEN_HEIGHT);
                        write_burst <= base + burst_of(band_bottom_y, tx, bottom_k + 3'd1);
                    end
                end
            end
            default: sender <= SEND_IDLE;
        endcase

        // tile done, everything read and sent
        if (running && !reading && !answer_coming && buf_full == 2'b00 && sender == SEND_IDLE && !(start && !running)) begin
            running <= 1'b0;
            done <= 1'b1;
        end
    end
end

endmodule

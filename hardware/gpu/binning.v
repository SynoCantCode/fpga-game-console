// binning.v
// puts each triangles number into the list of every tile its box touches
// numbers collect 8 at a time in a tray inside the chip then go to ddr3 in one write
// each tiles list in ddr3 is word 0 = the count then the numbers

module binning #(
    parameter [24:0] SHELF_BURSTS = 25'd2048,     // size of one tiles list in bursts
    parameter TILES_ACROSS = 20,
    parameter TILES = 460                         // 20 across x 23 down, tiles are 64 x 32
) (
    input wire clk,
    input wire reset,

    // frame control
    input wire frame_begin,                 // pulse, new frame so all lists start empty
    input wire [24:0] shelves_start,        // where the lists begin in ddr3, in bursts
    input wire frame_end,                   // pulse, no more triangles this frame
    output reg frame_finished,              // pulse, every list is complete in ddr3
    output wire busy,
    output reg overflow,                    // a list was full and a number got dropped

    // triangles coming in from setup
    input wire card_valid,
    output wire card_ready,
    input wire [16:0] card_number,
    input wire [15:0] box_left, box_right,  // the triangles box in pixels
    input wire [15:0] box_top, box_bottom,

    // writing ddr3
    output reg mem_req,
    output wire [2:0] mem_cmd,
    output reg [28:0] mem_addr,
    output reg [255:0] mem_wr_data,
    output reg [31:0] mem_wr_mask,          // 1 = dont write that byte
    input wire mem_grant
);

localparam CMD_WRITE = 3'b000;
localparam [15:0] CAPACITY = SHELF_BURSTS * 8 - 1;     // numbers a list can hold, word 0 is the count
assign mem_cmd = CMD_WRITE;

// states
localparam IDLE       = 4'd0;
localparam CLEARING   = 4'd1;     // all counts back to 0, one per clock
localparam RUNNING    = 4'd2;     // taking triangles
localparam END_WAIT   = 4'd3;     // let the last triangle and tray finish
localparam END_READ   = 4'd4;     // end of frame, one tile at a time, read its count and tray
localparam END_DATA   = 4'd5;     // keep them
localparam END_BUILD  = 4'd6;     // build its last burst
localparam END_WRITE  = 4'd7;     // send it, and the count on its own if needed
localparam END_NEXT   = 4'd8;
reg [3:0] state;
wire walking_time = (state == RUNNING) || (state == END_WAIT);

reg [24:0] shelves;
reg frame_ending;                 // frame_end came while clearing

// address of burst b of a tiles list
function [24:0] shelf_burst(input [24:0] start, input [8:0] tile, input [12:0] b);
    shelf_burst = start + tile * SHELF_BURSTS + b;
endfunction

// the counts, how many numbers each tile has so far (block ram)
wire count_write;
wire [8:0] count_write_tile;
wire [16:0] count_write_value;     // {full, count}
wire count_read;                  // only read when the pipeline moves
wire [8:0] count_read_tile;
reg [16:0] count_answer;          // {full, count} one clock after asking

// the full bit is worked out when the count is written so nothing has to compare it after the read
reg [16:0] counts [0:TILES-1];
// COLLISION_JUNK is sim only, reading the address being written gives junk like the real ram might
always @(posedge clk) begin
    if (count_write) counts[count_write_tile] <= count_write_value;
`ifdef COLLISION_JUNK
    if (count_read) count_answer <= (count_write && count_write_tile == count_read_tile) ? $random : counts[count_read_tile];
`else
    if (count_read) count_answer <= counts[count_read_tile];
`endif
end

// the trays, 8 rams (one per spot) so a whole tray can be read in one clock
wire tray_write;
wire [2:0] tray_write_spot;
wire [8:0] tray_write_tile;
wire [31:0] tray_write_number;
wire [2:0] tray_count_low;        // low 3 bits of the count before this number
wire [8:0] tray_read_tile;
wire [255:0] tray_read;           // the 8 spots one clock after asking

genvar s;
generate
    for (s = 0; s < 8; s = s + 1) begin : spot
        reg [31:0] bank [0:TILES-1];
        reg [31:0] answer;
        always @(posedge clk) begin
            // spot = count + 1 so compare the count with s - 1 instead of adding
            if (tray_write && tray_count_low == ((s + 7) % 8)) bank[tray_write_tile] <= tray_write_number;
`ifdef COLLISION_JUNK
            answer <= (tray_write && tray_count_low == ((s + 7) % 8) && tray_write_tile == tray_read_tile) ? $random
                                                                                                  : bank[tray_read_tile];
`else
            answer <= bank[tray_read_tile];
`endif
        end
        assign tray_read[s * 32 +: 32] = answer;
    end
endgenerate

// stage A visit the next tile and ask for its count
reg walking;
reg [4:0] tx, first_tx, last_tx;
reg [4:0] ty, last_ty;
reg [16:0] number;
wire [8:0] tile_a = {ty, 4'd0} + {ty, 2'd0} + tx;        // ty x 20 + tx
wire last_tile = (tx == last_tx) && (ty == last_ty);

// stage B the count is here, add the number to the tray and write count + 1 back
reg b_full;
reg [8:0] b_tile;
reg [16:0] b_number;

// the last count written, for forwarding
// if the same tile comes twice in a row the ram read is stale so use this instead
reg last_valid;
reg [8:0] last_tile_written;
reg [16:0] last_count;            // {full, count}
reg b_forward;                    // b_tile is the tile written last, worked out a clock ahead

wire [16:0] count_full_now = b_forward ? last_count : count_answer;   // {full, count}
wire [15:0] count_now = count_full_now[15:0];
wire [15:0] next_word = count_now + 16'd1;               // where this number goes in the list
wire [2:0] spot_now = next_word[2:0];                    // its spot in the tray
wire [12:0] burst_now = next_word[15:3];                 // which burst of the list the tray is
wire shelf_full = count_full_now[16];
wire fills_shelf = (count_now == CAPACITY - 16'd1);      // this number is the lists last
// this number takes the trays last spot so the tray goes to ddr3
wire tray_fills = (count_now[2:0] == 3'd6);

// the tray sender, a full tray is read (1 clock) then waits for its ddr3 write
reg sending_read;                 // reading a full tray this clock
reg [24:0] send_shelf;            // where that list starts
reg [12:0] send_burst;
reg [31:0] send_last;             // the number that filled it, the ram still has the old value
wire sender_busy = sending_read || mem_req;

// a number that fills a tray has to wait if the last full tray hasnt left yet
wire stall = b_full && tray_fills && sender_busy;
wire advance = walking_time && !stall;
wire b_adds = b_full && advance;                         // stage B adds its number this clock

// tray and count writes
assign tray_write = b_adds && !shelf_full;
assign tray_write_spot = spot_now;
assign tray_count_low = count_now[2:0];
assign tray_write_tile = b_tile;
assign tray_write_number = {15'd0, b_number};

reg [8:0] clear_tile;
assign count_write = (state == CLEARING) || (b_adds && !shelf_full);
assign count_write_tile = (state == CLEARING) ? clear_tile : b_tile;
assign count_write_value = (state == CLEARING) ? 17'd0 : {fills_shelf, next_word};

// end of frame, one tile at a time
reg [8:0] end_tile;
reg [24:0] end_shelf;             // where this list starts
reg [15:0] end_count;
reg [255:0] end_tray;
reg [2:0] end_filled;             // words used in the lists last burst
reg [12:0] end_burst;             // which burst that is
reg count_left;                   // the count still needs its own write
wire [15:0] end_next = count_answer[15:0] + 16'd1;
// write mask for words 0 to k-1
function [31:0] mask_for_words(input [3:0] k);
    mask_for_words = ~((32'd1 << (k * 4)) - 32'd1);
endfunction

assign count_read = walking_time ? advance : (state == END_READ);
assign count_read_tile = walking_time ? tile_a : end_tile;
assign tray_read_tile = walking_time ? b_tile : end_tile;

assign card_ready = (state == RUNNING) && (!walking || (advance && last_tile));
wire take_card = card_valid && card_ready;
assign busy = (state != IDLE);

always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;
        walking <= 1'b0;
        b_full <= 1'b0;
        last_valid <= 1'b0;
        b_forward <= 1'b0;
        sending_read <= 1'b0;
        mem_req <= 1'b0;
        frame_finished <= 1'b0;
        frame_ending <= 1'b0;
        overflow <= 1'b0;
    end else begin
        frame_finished <= 1'b0;
        sending_read <= 1'b0;

        // a full tray, one clock after reading it the 8 numbers go out
        if (sending_read) begin
            mem_wr_data <= {send_last, tray_read[223:0]};                 // spots 0-6 from the tray, 7 is the last number
            mem_wr_mask <= (send_burst == 0) ? 32'h0000_000F : 32'h0;     // first burst skips word 0, thats the count
            mem_addr <= {1'b0, send_shelf + send_burst, 3'b000};
            mem_req <= 1'b1;
        end
        if (mem_req && mem_grant && state != END_WRITE) mem_req <= 1'b0;

        case (state)
            IDLE: begin
                if (frame_begin) begin
                    shelves <= shelves_start;
                    overflow <= 1'b0;
                    clear_tile <= 0;
                    last_valid <= 1'b0;
                    b_forward <= 1'b0;
                    frame_ending <= 1'b0;
                    state <= CLEARING;
                end
            end

            CLEARING: begin
                if (frame_end) frame_ending <= 1'b1;
                clear_tile <= clear_tile + 1'b1;
                if (clear_tile == TILES - 1) state <= frame_ending ? END_WAIT : RUNNING;
            end

            RUNNING, END_WAIT: begin
                if (advance) begin
                    // stage B this tile gets the number
                    if (b_full) begin
                        // remember the count for forwarding
                        last_valid <= 1'b1;
                        last_tile_written <= b_tile;
                        last_count <= shelf_full ? count_full_now : {fills_shelf, next_word};
                        if (shelf_full)
                            overflow <= 1'b1;                                   // no room, dropped
                        if (tray_fills) begin                                   // tray is full, send it
                            sending_read <= !shelf_full;
                            send_shelf <= shelf_burst(shelves, b_tile, 13'd0);
                            send_burst <= burst_now;
                            send_last <= {15'd0, b_number};
                        end
                    end
                    // is the next tile in stage B the one written last
                    b_forward <= (b_full || last_valid) && ((b_full ? b_tile : last_tile_written) == tile_a);

                    // stage A to B, step to the next tile
                    b_full <= walking;
                    b_tile <= tile_a;
                    b_number <= number;
                    if (walking) begin
                        if (last_tile) walking <= 1'b0;
                        else if (tx == last_tx) begin
                            tx <= first_tx;
                            ty <= ty + 1'b1;
                        end else
                            tx <= tx + 1'b1;
                    end
                end

                // a new triangle, turn its box into tiles
                if (take_card) begin
                    number <= card_number;
                    first_tx <= box_left[10:6];  tx <= box_left[10:6];  last_tx <= box_right[10:6];
                    ty <= box_top[9:5];  last_ty <= box_bottom[9:5];
                    walking <= (box_left <= box_right) && (box_top <= box_bottom);
                end

                if (state == RUNNING && frame_end) state <= END_WAIT;
                if (state == END_WAIT && !walking && !b_full && !sender_busy) begin
                    end_tile <= 0;
                    state <= END_READ;
                end
            end

            // end of frame, each tiles last burst and its count
            END_READ: begin
                end_shelf <= shelf_burst(shelves, end_tile, 13'd0);
                state <= END_DATA;
            end
            END_DATA: begin
                end_count <= count_answer[15:0];
                end_tray <= tray_read;
                end_filled <= end_next[2:0];
                end_burst <= end_next[15:3];
                state <= END_BUILD;
            end
            END_BUILD: begin
                if (end_burst == 0) begin
                    // everything is in the first burst, count in word 0 then the numbers
                    mem_wr_data <= {end_tray[255:32], 16'd0, end_count};
                    mem_wr_mask <= mask_for_words({1'b0, end_filled});
                    mem_addr <= {1'b0, end_shelf, 3'b000};
                    count_left <= 1'b0;
                end else if (end_filled != 0) begin
                    // a partly full later burst, then the count on its own
                    mem_wr_data <= end_tray;
                    mem_wr_mask <= mask_for_words({1'b0, end_filled});
                    mem_addr <= {1'b0, end_shelf + end_burst, 3'b000};
                    count_left <= 1'b1;
                end else begin
                    // the last burst already went out full, only the count
                    mem_wr_data <= {224'd0, 16'd0, end_count};
                    mem_wr_mask <= mask_for_words(4'd1);
                    mem_addr <= {1'b0, end_shelf, 3'b000};
                    count_left <= 1'b0;
                end
                mem_req <= 1'b1;
                state <= END_WRITE;
            end
            END_WRITE: begin
                if (mem_grant) begin
                    if (count_left) begin
                        mem_wr_data <= {224'd0, 16'd0, end_count};
                        mem_wr_mask <= mask_for_words(4'd1);
                        mem_addr <= {1'b0, end_shelf, 3'b000};
                        count_left <= 1'b0;                              // mem_req stays up for this one
                    end else begin
                        mem_req <= 1'b0;
                        state <= END_NEXT;
                    end
                end
            end
            END_NEXT: begin
                if (end_tile == TILES - 1) begin
                    frame_finished <= 1'b1;
                    state <= IDLE;
                end else begin
                    end_tile <= end_tile + 1'b1;
                    state <= END_READ;
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule

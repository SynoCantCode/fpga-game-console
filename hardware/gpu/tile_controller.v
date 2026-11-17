// tile_controller.v
// runs the back half. for each tile it reads the shelf (list of card numbers) and the cards from ddr3
// sends each card through card_prep to the raster, then swaps the tile memory and starts the writeout
// it fetches cards ahead so the raster isnt waiting on memory

module tile_controller #(
    parameter [24:0] SHELF_BURSTS = 25'd2048,      // bursts per shelf
    parameter TILES_ACROSS = 20,
    parameter TILES_DOWN = 23,                     // last row is only half on screen
    parameter CARD_SLOTS = 16                      // cards on their way or waiting at once, power of 2
) (
    input wire clk,
    input wire reset,

    // orders
    input wire frame_start,                 // 1 for one clock, draw a frame
    input wire [24:0] shelves_start,        // where the shelves begin, in bursts
    input wire [24:0] cards_start,          // where the cards begin
    input wire [24:0] frame_buffer_start,   // where the frame buffer begins
    output reg frame_done,                  // 1 for one clock, the frame is in the frame buffer
    output wire busy,
    output reg [3:0] perf_bits,             // {tile end, shelf wait, waiting for raster, no card ready} for the speed counters

    // reading ddr3
    output reg mem_req,
    output wire [2:0] mem_cmd,
    output wire [28:0] mem_addr,
    input wire mem_grant,
    input wire mem_rd_valid,
    input wire [255:0] mem_rd_data,

    // card_prep
    output reg prep_start,
    output reg [1023:0] prep_card,          // slot a low half, slot b high half
    output wire [4:0] prep_tile_x,
    output wire [4:0] prep_tile_y,
    input wire prep_done,
    input wire prep_empty,

    // the raster
    output reg tri_valid,                   // the triangle from card_prep is ready
    input wire tri_ready,
    input wire raster_busy,

    // tile memory and writeout
    output reg swap,
    output reg wo_start,
    output reg wo_send,
    output wire [4:0] wo_tile_x,
    output wire [4:0] wo_tile_y,
    output wire [24:0] wo_frame_start,
    input wire wo_busy
);

localparam CMD_READ = 3'b001;
localparam TILES = TILES_ACROSS * TILES_DOWN;

// the tile loop and the fetcher
localparam IDLE          = 5'd0;
localparam WIPE_START    = 5'd1;    // at startup the writeout wipes both sides of the tile memory without sending
localparam WIPE_GAP      = 5'd2;
localparam WIPE_WAIT     = 5'd3;
localparam WIPE_SWAP     = 5'd4;
localparam WIPE_SWAP_END = 5'd5;
localparam TILE_BEGIN    = 5'd6;    // new tile, ask for the first burst of its shelf
localparam SHELF_ASK     = 5'd7;    // asking for a shelf burst
localparam SHELF_WAIT    = 5'd8;    // waiting for it
localparam NEXT_CARD     = 5'd9;    // next card on the shelf or the shelf is done
localparam CARD_ASK0     = 5'd10;   // asking for the cards 4 bursts
localparam CARD_ASK1     = 5'd11;
localparam TILE_FINISH   = 5'd12;   // all cards asked for, wait until drawn and the writeout is free
localparam TILE_SWAP     = 5'd13;
localparam TILE_WRITEOUT = 5'd14;
localparam TILE_NEXT     = 5'd15;
localparam FRAME_FINISH  = 5'd16;   // wait for the last tiles writeout
localparam NEXT_PICK     = 5'd17;   // work out the next cards number and address a clock ahead
localparam CARD_ASK2     = 5'd18;
localparam CARD_ASK3     = 5'd19;
reg [4:0] state;

// the frames addresses
reg [24:0] shelves, cards, frame_buffer;

// where we are
reg [4:0] tile_x;
reg [4:0] tile_y;
reg [8:0] tile_index;        // tile_y*20 + tile_x
reg wiped;                   // startup wipe done
reg wipe_round;              // which side is being wiped

// the shelf being read
reg [15:0] count;            // how many cards on this shelf
reg [15:0] entry;            // which one the fetcher asks for next
reg [255:0] shelf_burst;     // the shelf burst we have, 8 words
reg [12:0] loaded_burst;     // which burst of the shelf that is
reg [12:0] asking_burst;     // which burst is being fetched
reg shelf_arrived;           // it came back

// word 0 of the shelf is the count so card number entry is at word entry + 1
wire [15:0] entry_word = entry + 16'd1;
wire [12:0] needed_burst = entry_word[15:3];
wire [2:0] word_in_burst = entry_word[2:0];
wire [31:0] card_number = shelf_burst[word_in_burst * 32 +: 32];

reg [24:0] shelf_address;                                              // this tiles shelf

reg [24:0] read_burst;       // the address being asked for

// worked out in NEXT_PICK, used in NEXT_CARD
reg pick_done;               // every card on the shelf has been asked for
reg pick_need_shelf;         // the next number is in a shelf burst we dont have
reg [12:0] pick_shelf_burst;
reg [24:0] pick_shelf_address;
reg [24:0] pick_card_address;
assign mem_cmd = CMD_READ;
assign mem_addr = {1'b0, read_burst, 3'b000};

// one tag per request, answers come back in the same order
localparam TAG_SHELF  = 3'd0;
localparam TAG_CARD0  = 3'd1;        // a cards bursts 0 to 3
localparam TAG_CARD1  = 3'd2;
localparam TAG_CARD2  = 3'd3;
localparam TAG_CARD3  = 3'd4;
reg [2:0] tags [0:127];
reg [6:0] tag_in, tag_out;            // wrap by themselves
reg [7:0] tags_waiting;              // requests sent that havent been answered

wire push_tag = mem_grant;           // every grant is one of the fetchers requests
wire [2:0] new_tag = (state == CARD_ASK0) ? TAG_CARD0 : (state == CARD_ASK1) ? TAG_CARD1 :
                     (state == CARD_ASK2) ? TAG_CARD2 : (state == CARD_ASK3) ? TAG_CARD3 : TAG_SHELF;
wire [2:0] arriving_tag = tags[tag_out];

// the waiting room, whole cards in order until the sender takes them
// lut memory, its too small to be worth block ram
(* syn_ramstyle = "distributed_ram" *) reg [1023:0] room [0:CARD_SLOTS-1];
localparam SLOT_BITS = $clog2(CARD_SLOTS);
reg [SLOT_BITS-1:0] room_in, room_out;   // wrap by themselves
reg [SLOT_BITS:0] room_count;
reg [767:0] part_card;               // a cards first 3 bursts until the fourth arrives
reg [SLOT_BITS:0] cards_out;         // cards asked for or waiting that the sender hasnt taken

// the sender, waiting room to card_prep to raster
localparam SEND_IDLE = 2'd0;
localparam SEND_PREP = 2'd1;         // card_prep is working
localparam SEND_HAND = 2'd2;         // waiting for the raster to take it
reg [1:0] sender;
wire sender_takes = (sender == SEND_IDLE) && (room_count != 0);

assign prep_tile_x = tile_x;
assign prep_tile_y = tile_y;
assign wo_tile_x = tile_x;
assign wo_tile_y = tile_y;
assign wo_frame_start = frame_buffer;
assign busy = (state != IDLE);

// bits for the speed counters
always @(posedge clk)
    perf_bits <= {state == TILE_FINISH, state == SHELF_WAIT, sender == SEND_HAND, (sender == SEND_IDLE) && (room_count == 0)};

// everything for this tile is drawn
wire tile_drained = (cards_out == 0) && (tags_waiting == 0) && (sender == SEND_IDLE) && !raster_busy;

always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;
        mem_req <= 1'b0;
        prep_start <= 1'b0;
        tri_valid <= 1'b0;
        swap <= 1'b0;
        wo_start <= 1'b0;
        wo_send <= 1'b0;
        frame_done <= 1'b0;
        wiped <= 1'b0;
        tag_in <= 0;  tag_out <= 0;  tags_waiting <= 0;
        room_in <= 0;  room_out <= 0;  room_count <= 0;
        cards_out <= 0;
        sender <= SEND_IDLE;
        shelf_arrived <= 1'b0;
    end else begin
        prep_start <= 1'b0;
        frame_done <= 1'b0;

        // answers go where their tag says
        if (mem_rd_valid) begin
            tag_out <= tag_out + 1'b1;
            case (arriving_tag)
                TAG_SHELF: begin
                    shelf_burst <= mem_rd_data;
                    loaded_burst <= asking_burst;
                    if (asking_burst == 0) count <= mem_rd_data[15:0];          // word 0 of the shelf
                    shelf_arrived <= 1'b1;
                end
                TAG_CARD0: part_card[255:0]   <= mem_rd_data;
                TAG_CARD1: part_card[511:256] <= mem_rd_data;
                TAG_CARD2: part_card[767:512] <= mem_rd_data;
                default: begin                                               // last burst, the card is whole
                    room[room_in] <= {mem_rd_data, part_card};
                    room_in <= room_in + 1'b1;
                end
            endcase
        end

        // the sender
        case (sender)
            SEND_IDLE: begin
                if (sender_takes) begin
`ifdef COLLISION_JUNK
                    // sim only, junk if this slot is being written on the same tick
                    prep_card <= (mem_rd_valid && arriving_tag == TAG_CARD3 &&
                                  room_in == room_out) ? {32{$random}} : room[room_out];
`else
                    prep_card <= room[room_out];
`endif
                    room_out <= room_out + 1'b1;
                    prep_start <= 1'b1;
                    sender <= SEND_PREP;
                end
            end
            SEND_PREP: begin
                if (prep_done) begin
                    if (prep_empty) sender <= SEND_IDLE;        // nothing of it in this tile, skip
                    else begin
                        tri_valid <= 1'b1;
                        sender <= SEND_HAND;
                    end
                end
            end
            SEND_HAND: begin
                if (tri_ready) begin                            // the raster takes it
                    tri_valid <= 1'b0;
                    sender <= SEND_IDLE;
                end
            end
            default: sender <= SEND_IDLE;
        endcase

        // the tile loop and the fetcher
        case (state)
            IDLE: begin
                if (frame_start) begin
                    shelves <= shelves_start;
                    shelf_address <= shelves_start;
                    cards <= cards_start;
                    frame_buffer <= frame_buffer_start;
                    tile_x <= 0;  tile_y <= 0;  tile_index <= 0;
                    wipe_round <= 1'b0;
                    state <= wiped ? TILE_BEGIN : WIPE_START;
                end
            end

            // startup only, wipe both sides of the tile memory
            WIPE_START: begin
                wo_start <= 1'b1;
                wo_send <= 1'b0;                     // wipe, dont send
                state <= WIPE_GAP;
            end
            WIPE_GAP: begin
                wo_start <= 1'b0;
                state <= WIPE_WAIT;
            end
            WIPE_WAIT: begin
                if (!wo_busy) state <= WIPE_SWAP;
            end
            WIPE_SWAP: begin
                swap <= 1'b1;
                state <= WIPE_SWAP_END;
            end
            WIPE_SWAP_END: begin
                swap <= 1'b0;
                if (wipe_round) begin
                    wiped <= 1'b1;
                    state <= TILE_BEGIN;
                end else begin
                    wipe_round <= 1'b1;
                    state <= WIPE_START;
                end
            end

            // a tile, start with the shelfs first burst
            TILE_BEGIN: begin
                entry <= 0;
                count <= 0;
                asking_burst <= 0;
                read_burst <= shelf_address;
                shelf_arrived <= 1'b0;
                mem_req <= 1'b1;
                state <= SHELF_ASK;
            end
            SHELF_ASK: begin
                if (mem_grant) begin
                    mem_req <= 1'b0;
                    state <= SHELF_WAIT;
                end
            end
            SHELF_WAIT: begin
                if (shelf_arrived) state <= NEXT_PICK;
            end

            NEXT_PICK: begin
                pick_done <= (entry == count);
                pick_need_shelf <= (needed_burst != loaded_burst);
                pick_shelf_burst <= needed_burst;
                pick_shelf_address <= shelf_address + needed_burst;
                pick_card_address <= cards + {card_number[16:0], 3'b000};   // card n is at cards_start + n*8
                state <= NEXT_CARD;
            end
            NEXT_CARD: begin
                if (pick_done) begin
                    state <= TILE_FINISH;                                // every card asked for
                end else if (pick_need_shelf) begin
                    asking_burst <= pick_shelf_burst;                    // the number is in another shelf burst
                    read_burst <= pick_shelf_address;
                    shelf_arrived <= 1'b0;
                    mem_req <= 1'b1;
                    state <= SHELF_ASK;
                end else if (cards_out < CARD_SLOTS) begin               // room for one more card
                    read_burst <= pick_card_address;
                    mem_req <= 1'b1;
                    state <= CARD_ASK0;
                end
                // otherwise all slots are busy, wait here
            end
            CARD_ASK0: begin
                if (mem_grant) begin
                    read_burst <= read_burst + 1'b1;                     // next burst of the card
                    state <= CARD_ASK1;
                end
            end
            CARD_ASK1: begin
                if (mem_grant) begin
                    read_burst <= read_burst + 1'b1;
                    state <= CARD_ASK2;
                end
            end
            CARD_ASK2: begin
                if (mem_grant) begin
                    read_burst <= read_burst + 1'b1;
                    state <= CARD_ASK3;
                end
            end
            CARD_ASK3: begin
                if (mem_grant) begin
                    mem_req <= 1'b0;
                    entry <= entry + 1'b1;
                    state <= NEXT_PICK;                                  // dont wait for the answer
                end
            end

            // tile is drawn, swap, send it, next tile
            TILE_FINISH: begin
                if (tile_drained && !wo_busy) state <= TILE_SWAP;
            end
            TILE_SWAP: begin
                swap <= 1'b1;
                state <= TILE_WRITEOUT;
            end
            TILE_WRITEOUT: begin
                swap <= 1'b0;
                wo_start <= 1'b1;
                wo_send <= 1'b1;
                state <= TILE_NEXT;
            end
            TILE_NEXT: begin
                wo_start <= 1'b0;
                if (tile_index == TILES - 1) begin
                    state <= FRAME_FINISH;
                end else begin
                    tile_index <= tile_index + 1'b1;
                    shelf_address <= shelf_address + SHELF_BURSTS;
                    if (tile_x == TILES_ACROSS - 1) begin
                        tile_x <= 0;
                        tile_y <= tile_y + 1'b1;
                    end else
                        tile_x <= tile_x + 1'b1;
                    state <= TILE_BEGIN;
                end
            end
            FRAME_FINISH: begin
                if (!wo_busy) begin
                    frame_done <= 1'b1;
                    state <= IDLE;
                end
            end

            default: state <= IDLE;
        endcase

        // the counters, each can go up and down on the same tick
        if (push_tag) begin
            tags[tag_in] <= new_tag;
            tag_in <= tag_in + 1'b1;
        end
        tags_waiting <= tags_waiting + push_tag - mem_rd_valid;

        // waiting room
        room_count <= room_count + (mem_rd_valid && arriving_tag == TAG_CARD3) - sender_takes;

        // cards out
        cards_out <= cards_out + (state == CARD_ASK0 && mem_grant) - sender_takes;
    end
end

endmodule

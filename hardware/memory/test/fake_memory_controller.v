// fake_memory_controller.v
// test only stand in for gowins ddr3 controller (the real one is encrypted so it cant be simulated)
// same handshake, sometimes busy, read answers come back in order after a delay, counts protocol mistakes
// can also charge ddr3 style costs for row changes and read/write switches
`timescale 1ns / 1ps

module fake_memory_controller #(
    parameter BLOCKS = 1024,          // how many 32 byte blocks it stores
    parameter LATENCY = 20,           // ticks from a read command to its answer
    parameter BROKEN_BLOCK = -1,      // -1 = perfect memory, else one bit of that block gets flipped
    parameter [15:0] SEED = 16'hACE1, // start of the busy pattern
    parameter STALL_PERIOD = 0,       // 0 = off, else every STALL_PERIOD ticks its busy for STALL_LEN ticks
    parameter STALL_LEN = 0,
    parameter ANSWER_GAPS = 0,        // 1 = read answers held back now and then
    parameter ROW_MISS = 0,           // ticks to change the open row, 0 = free
    parameter TURNAROUND = 0,         // ticks to switch between reading and writing, 0 = free
    parameter RANDOM_BUSY = 1,        // 1 = busy about 1 tick in 4 at random
    parameter WRAP = 0                // 1 = addresses past BLOCKS wrap around
) (
    input wire clk,
    output reg calibrated = 0,
    output wire cmd_ready,
    input wire cmd_en,
    input wire [2:0] cmd,
    input wire [28:0] addr,
    output wire wr_data_rdy,
    input wire wr_data_en,
    input wire wr_data_end,
    input wire [255:0] wr_data,
    input wire [31:0] wr_data_mask,
    output reg rd_data_valid = 0,
    output reg [255:0] rd_data = 0
);

    // the stored memory, one 256 bit word per block
    reg [255:0] memory [0:BLOCKS-1];
    integer i;
    initial for (i = 0; i < BLOCKS; i = i + 1) memory[i] = 256'd0;

    function integer block_of(input [28:0] a);
        block_of = a[27:3];   // block number
    endfunction

    // calibrated after 200 ticks
    integer ticks = 0;
    always @(posedge clk) begin
        ticks = ticks + 1;
        if (ticks == 200) calibrated <= 1;
    end

    // busy now and then, an lfsr decides
    reg [15:0] lfsr = SEED;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    wire stalled = (STALL_PERIOD > 0) && ((ticks % (STALL_PERIOD > 0 ? STALL_PERIOD : 1)) < STALL_LEN);
    // ddr3 costs, each banks open row and the last direction
    integer open_row [0:7];                 // -1 = no row open
    integer bank_i;
    initial for (bank_i = 0; bank_i < 8; bank_i = bank_i + 1) open_row[bank_i] = -1;
    integer last_dir = -1;                  // 0 = write, 1 = read, -1 = nothing yet
    reg [7:0] door_wait = 0;                // cmd_ready stays off this many more ticks
    integer row_misses = 0, turnarounds = 0;
    // the costs can be overridden with plusargs on the sim command line
    integer row_miss_v = ROW_MISS, turnaround_v = TURNAROUND, random_busy_v = RANDOM_BUSY;
    // swap which address bits pick the bank
    integer swap_v = 0;
    // one open row for the whole memory, own row change cost for reads, own answer delay
    integer one_row_v = 0, row_miss_read_v = -1, latency_v = LATENCY;
    // a read/write switch only costs extra inside the same row
    integer switch_in_row_v = 0;
    reg row_changed;
    integer open_bank = -1, open_row_one = -1;
    initial begin
        if ($value$plusargs("FAKE_ROW_MISS=%d", row_miss_v)) $display("fake DDR3: row change costs %0d ticks", row_miss_v);
        if ($value$plusargs("FAKE_TURNAROUND=%d", turnaround_v)) $display("fake DDR3: read/write switch costs %0d ticks", turnaround_v);
        if ($value$plusargs("FAKE_SWITCH_IN_ROW=%d", switch_in_row_v)) $display("fake DDR3: switch only within a row %0d", switch_in_row_v);
        if ($value$plusargs("FAKE_ONE_ROW=%d", one_row_v)) $display("fake DDR3: one open row %0d", one_row_v);
        if ($value$plusargs("FAKE_ROW_MISS_READ=%d", row_miss_read_v)) $display("fake DDR3: row change for a read %0d", row_miss_read_v);
        if ($value$plusargs("FAKE_LATENCY_RUN=%d", latency_v)) $display("fake DDR3: answer delay %0d", latency_v);
        if ($value$plusargs("FAKE_SWAP=%d", swap_v)) $display("fake DDR3: bank bits swapped %0d", swap_v);
        if ($value$plusargs("FAKE_RANDOM_BUSY=%d", random_busy_v)) $display("fake DDR3: random busy ticks %0d", random_busy_v);
    end
    integer cost;
    reg [2:0] the_bank;
    reg [14:0] the_row;
    wire costs_done = (door_wait == 0);

    assign cmd_ready   = calibrated && !stalled && costs_done && (random_busy_v == 0 || lfsr[1:0] != 2'b00);
    assign wr_data_rdy = calibrated && !stalled && costs_done && (random_busy_v == 0 || lfsr[3:2] != 2'b00);
    wire answer_held = (ANSWER_GAPS != 0) && (lfsr[6:5] == 2'b00);

    // protocol checks on the client
    integer protocol_mistakes = 0;
    integer writes_taken = 0, reads_taken = 0;

    // reads waiting to be answered, a queue of block number and when its due
    integer queue_block [0:255];
    integer queue_due [0:255];
    integer queue_in = 0, queue_out = 0;

    integer b, k;
    reg [255:0] merged;

    always @(posedge clk) begin
        rd_data_valid <= 0;
        if (door_wait != 0) door_wait <= door_wait - 1;

        if (cmd_en && !cmd_ready) protocol_mistakes = protocol_mistakes + 1;          // sent while busy
        if (wr_data_en && !wr_data_rdy) protocol_mistakes = protocol_mistakes + 1;    // data while busy
        if (wr_data_en && !wr_data_end) protocol_mistakes = protocol_mistakes + 1;    // one word = one burst

        if (cmd_en && cmd_ready) begin
            b = block_of(addr);
            if (WRAP != 0) b = b % BLOCKS;
            // cost of this command, another row? other direction?
            cost = 0;
            row_changed = 0;
            the_bank = swap_v ? addr[12:10] : addr[27:25];
            the_row = swap_v ? {addr[24:13], addr[27:25]} : addr[24:10];
            if (one_row_v != 0) begin
                // one open row for everything, another bank or row = a row change
                if (row_miss_v > 0 && (open_bank != the_bank || open_row_one != the_row)) begin
                    cost = cost + ((cmd == 3'b001 && row_miss_read_v >= 0) ? row_miss_read_v : row_miss_v);
                    row_misses = row_misses + 1;
                    row_changed = 1;
                end
                open_bank = the_bank;
                open_row_one = the_row;
            end else begin
                if (row_miss_v > 0 && open_row[the_bank] != the_row) begin
                    cost = cost + ((cmd == 3'b001 && row_miss_read_v >= 0) ? row_miss_read_v : row_miss_v);
                    row_misses = row_misses + 1;
                end
                open_row[the_bank] = the_row;
            end
            if (turnaround_v > 0 && last_dir >= 0 && last_dir != (cmd == 3'b001 ? 1 : 0)
                && !(switch_in_row_v != 0 && row_changed)) begin
                cost = cost + turnaround_v;
                turnarounds = turnarounds + 1;
            end
            last_dir = (cmd == 3'b001) ? 1 : 0;
            if (cost > 0) door_wait <= cost;          // not ready for cost ticks
            if (addr[2:0] != 0 || b >= BLOCKS) protocol_mistakes = protocol_mistakes + 1;   // not a block start or too far
            else if (cmd == 3'b000) begin
                if (!(wr_data_en && wr_data_rdy)) protocol_mistakes = protocol_mistakes + 1; // write without its data
                // write only the bytes the mask allows
                merged = memory[b];
                for (k = 0; k < 32; k = k + 1)
                    if (!wr_data_mask[k]) merged[k*8 +: 8] = wr_data[k*8 +: 8];
                if (b == BROKEN_BLOCK) merged[77] = ~merged[77];   // the fault, one flipped bit
                memory[b] = merged;
                writes_taken = writes_taken + 1;
            end else if (cmd == 3'b001) begin
                queue_block[queue_in % 256] = b;
                queue_due[queue_in % 256] = ticks + cost + latency_v;
                queue_in = queue_in + 1;
                reads_taken = reads_taken + 1;
            end else protocol_mistakes = protocol_mistakes + 1;   // unknown command
        end

        // answer the oldest waiting read once its due, in order, one per tick at most
        if (queue_out < queue_in && ticks >= queue_due[queue_out % 256] && !answer_held) begin
            rd_data_valid <= 1;
            rd_data <= memory[queue_block[queue_out % 256]];
            queue_out = queue_out + 1;
        end
    end

endmodule

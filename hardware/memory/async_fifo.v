// async_fifo.v
// a fifo between two unrelated clocks, in on write_clk and out on read_clk
// each sides pointer crosses to the other clock in gray code through 2 flip flops
// full and empty use a slightly old copy of the other pointer, which is always the safe direction

module async_fifo #(
    parameter WIDTH = 256,                  // bits per entry
    parameter ADDR_BITS = 8,                // 2^8 = 256 entries
    parameter SMALL = 0                     // 1 = keep the entries in lut memory instead of block ram
) (
    // write side
    input wire write_clk,
    input wire write_reset,
    input wire write_en,                    // 1 = put write_data in this tick, only while not full
    input wire [WIDTH-1:0] write_data,
    output wire full,                       // 1 = no room
    output wire [ADDR_BITS:0] write_count,  // entries in the fifo as the write side sees it

    // read side
    input wire read_clk,
    input wire read_reset,
    input wire read_en,                     // 1 = take the oldest entry this tick, only while not empty
    output wire [WIDTH-1:0] read_data,      // the oldest entry
    output wire empty                       // 1 = nothing to read
);

localparam DEPTH = 1 << ADDR_BITS;

// gray code, to and from a normal number
function [ADDR_BITS:0] to_gray(input [ADDR_BITS:0] number);
    to_gray = number ^ (number >> 1);
endfunction

function [ADDR_BITS:0] from_gray(input [ADDR_BITS:0] gray);
    integer i;
    begin
        from_gray[ADDR_BITS] = gray[ADDR_BITS];
        for (i = ADDR_BITS - 1; i >= 0; i = i - 1)
            from_gray[i] = from_gray[i+1] ^ gray[i];
    end
endfunction

// the pointers that cross, in gray code
reg [ADDR_BITS:0] write_ptr_gray;     // the read side looks at this
reg [ADDR_BITS:0] read_ptr_gray;      // the write side looks at this

// write side, all on write_clk
reg [ADDR_BITS:0] write_ptr;                  // where the next entry goes, top bit counts laps
reg [ADDR_BITS:0] read_gray_1, read_gray_2;   // the read pointer caught by 2 flip flops

// where the reader was a couple of ticks ago
// converted from gray code into a register, the xor chain is slow
reg [ADDR_BITS:0] read_ptr_seen;

assign write_count = write_ptr - read_ptr_seen;   // how far the writer is ahead of the reader
assign full = (write_count == DEPTH);             // a whole lap ahead = no room

always @(posedge write_clk) begin
    if (write_reset) begin
        write_ptr <= 0;
        write_ptr_gray <= 0;
        read_gray_1 <= 0;
        read_gray_2 <= 0;
        read_ptr_seen <= 0;
    end else begin
        read_ptr_seen <= from_gray(read_gray_2);
        if (write_en && !full) begin
            write_ptr <= write_ptr + 1;
            write_ptr_gray <= to_gray(write_ptr + 1);   // what the read side will see
        end
        read_gray_1 <= read_ptr_gray;    // may catch it mid change
        read_gray_2 <= read_gray_1;      // settled before its used
    end
end

// read side, all on read_clk
reg [ADDR_BITS:0] read_ptr;                    // the next entry to take, top bit counts laps
reg [ADDR_BITS:0] write_gray_1, write_gray_2;  // the write pointer caught by 2 flip flops
reg [WIDTH-1:0] read_data_reg;

// where the writer was a couple of ticks ago
reg [ADDR_BITS:0] write_ptr_seen;

assign empty = (read_ptr == write_ptr_seen);   // same slot same lap = nothing waiting

wire take = read_en && !empty;                                 // an entry is taken this tick
wire [ADDR_BITS:0] read_ptr_next = read_ptr + take;            // where the pointer will be after this tick

// the storage, written on write_clk and read on read_clk
// always reads the slot the read pointer is about to be on so read_data is ready when it gets there
// block ram for big fifos, lut memory for a few entries (SMALL = 1)
// same two blocks twice, only the kind of memory differs
generate
    if (SMALL) begin : small_storage
        (* syn_ramstyle = "distributed_ram" *) reg [WIDTH-1:0] ram [0:DEPTH-1];
        always @(posedge write_clk) begin
            if (write_en && !full)
                ram[write_ptr[ADDR_BITS-1:0]] <= write_data;
        end
        always @(posedge read_clk)
            read_data_reg <= ram[read_ptr_next[ADDR_BITS-1:0]];
    end else begin : block_storage
        reg [WIDTH-1:0] ram [0:DEPTH-1];
        always @(posedge write_clk) begin
            if (write_en && !full)
                ram[write_ptr[ADDR_BITS-1:0]] <= write_data;
        end
        always @(posedge read_clk)
            read_data_reg <= ram[read_ptr_next[ADDR_BITS-1:0]];
    end
endgenerate

assign read_data = read_data_reg;

always @(posedge read_clk) begin
    if (read_reset) begin
        read_ptr <= 0;
        read_ptr_gray <= 0;
        write_gray_1 <= 0;
        write_gray_2 <= 0;
        write_ptr_seen <= 0;
    end else begin
        write_ptr_seen <= from_gray(write_gray_2);
        read_ptr <= read_ptr_next;
        read_ptr_gray <= to_gray(read_ptr_next);   // what the write side will see
        write_gray_1 <= write_ptr_gray;            // may catch it mid change
        write_gray_2 <= write_gray_1;              // settled before its used
    end
end

endmodule

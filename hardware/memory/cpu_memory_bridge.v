// cpu_memory_bridge.v
// connects the cpus memory bus (64 bit ahb) to the memory arbiter
// a read fetches the whole 32 byte block and the rest of the burst is answered from it
// a write goes out as a 32 byte write with a byte mask

module cpu_memory_bridge (
    input wire clk,                   // memory side clock, also the cpus memory bus clock
    input wire reset,

    // cpu memory bus (ahb)
    input wire [31:0] haddr,
    input wire [1:0] htrans,          // 10 = new transfer, 11 = next of a burst
    input wire hwrite,                // 1 = write
    input wire [2:0] hsize,           // bytes = 1 << hsize
    input wire [63:0] hwdata,         // write data, in the data phase
    output wire [63:0] hrdata,
    output wire hready,               // 0 = cpu waits
    output wire hresp,                // always okay

    // to the memory arbiter
    output wire req,
    output wire [2:0] cmd,
    output wire [28:0] addr,
    output wire [255:0] wr_data,
    output wire [31:0] wr_mask,
    input wire grant,
    input wire rd_valid,
    input wire [255:0] rd_data
);

localparam CMD_WRITE = 3'b000;
localparam CMD_READ  = 3'b001;
localparam TRANS_NONSEQ = 2'b10;
localparam TRANS_SEQ    = 2'b11;

// the steps
localparam READY       = 3'd0;  // nothing pending, take the next transfer
localparam FETCH_ASK   = 3'd1;  // read missed, asking the arbiter for the block
localparam FETCH_WAIT  = 3'd2;  // waiting for the block to come back
localparam WRITING     = 3'd3;  // a write, waiting for the arbiter to take it
localparam WRITE_CATCH = 3'd4;  // copy the write data and mask into registers first so the arbiter only sees registers
localparam READ_CHECK  = 3'd5;  // a read, is it in the block we hold? checked a clock later on our own copy of the address

reg [2:0] state;
reg [63:0] write_data;          // the 8 bytes to write
reg [31:0] write_mask;          // 1 = dont write that byte

// the transfer being worked on
reg [31:0] cur_addr;
reg cur_write;
reg [2:0] cur_size;

// the last block fetched
reg [255:0] block;
reg [24:0] block_number;
reg block_valid;

// which 32 byte block an address is in
function [24:0] block_of(input [31:0] a);
    block_of = a[29:5];
endfunction

// the bytes a transfer writes, 1 = write this byte
function [31:0] byte_enables(input [31:0] a, input [2:0] size);
    reg [15:0] in_piece;
    begin
        in_piece = ((16'd1 << (1 << size)) - 16'd1) << a[2:0];      // size bytes starting at the addresses byte
        byte_enables = {24'd0, in_piece[7:0]} << (a[4:3] * 8);       // moved to its 8 byte piece in the block
    end
endfunction

// ahb side
assign hready = (state == READY);
assign hresp = 1'b0;
assign hrdata = block[cur_addr[4:3]*64 +: 64];        // the 8 byte piece the cpu asked for

// the address phase is taken when were ready and the cpu is asking
wire taking = hready && htrans[1];
reg cur_seq;                    // this transfer is the next of a burst
wire read_hit = cur_seq && block_valid && (block_of(cur_addr) == block_number);

// arbiter side
assign req = (state == FETCH_ASK) || (state == WRITING);
assign cmd = (state == WRITING) ? CMD_WRITE : CMD_READ;
assign addr = {1'b0, block_of(cur_addr), 3'b000};
assign wr_data = {4{write_data}};                      // same piece in every slot, the mask picks the bytes
assign wr_mask = write_mask;
always @(posedge clk) begin
    if (reset) begin
        state <= READY;
        block_valid <= 0;
        cur_addr <= 0;
        cur_write <= 0;
        cur_size <= 0;
        cur_seq <= 0;
    end else begin
        case (state)
            READY: begin
                if (taking) begin
                    cur_addr <= haddr;
                    cur_write <= hwrite;
                    cur_size <= hsize;
                    cur_seq <= (htrans == TRANS_SEQ);
                    state <= hwrite ? WRITE_CATCH : READ_CHECK;
                end
            end

            READ_CHECK: begin
                if (read_hit)
                    state <= READY;                    // hit, the data is already in the block
                else
                    state <= FETCH_ASK;
            end

            FETCH_ASK: begin
                if (grant)
                    state <= FETCH_WAIT;
            end

            FETCH_WAIT: begin
                if (rd_valid) begin
                    block <= rd_data;
                    block_number <= block_of(cur_addr);
                    block_valid <= 1;
                    state <= READY;
                end
            end

            WRITE_CATCH: begin
                // data phase, the bytes are on hwdata now
                write_data <= hwdata;
                write_mask <= ~byte_enables(cur_addr, cur_size);
                state <= WRITING;
            end

            WRITING: begin
                if (grant) begin
                    block_valid <= 0;                   // the block we hold may be out of date now
                    state <= READY;
                end
            end
        endcase
    end
end

endmodule

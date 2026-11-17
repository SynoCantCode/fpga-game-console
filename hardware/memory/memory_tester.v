// memory_tester.v
// memory self test, writes a pattern into ddr3 then reads it all back and checks it
// every 4 byte word holds its own word number so any wrong address or lost write shows up

module memory_tester #(
    parameter BLOCKS = 32768             // how many 32 byte blocks to test
) (
    input wire clk,                      // the memory controllers clk_out
    input wire reset,

    // the memory controller
    input wire calibrated,               // 1 = the controller is ready
    input wire cmd_ready,                // 1 = it can take a command this tick
    output wire cmd_en,                  // 1 = we give it a command this tick
    output wire [2:0] cmd,               // 000 = write, 001 = read
    output wire [28:0] addr,             // {rank, bank, row, column}
    input wire wr_data_rdy,              // 1 = it can take write data this tick
    output wire wr_data_en,              // 1 = we give it write data this tick
    output wire wr_data_end,             // always the last piece, one 256 bit word is a whole burst
    output wire [255:0] wr_data,         // the 32 bytes to write
    output wire [31:0] wr_data_mask,     // 1 = dont write that byte
    input wire rd_data_valid,            // pulse, rd_data holds the next answer
    input wire [255:0] rd_data,          // the 32 bytes read

    // the result
    output wire done,                    // 1 once the test has finished
    output reg [31:0] errors             // blocks that came back wrong, 0 = passed
);

localparam CMD_WRITE = 3'b000;
localparam CMD_READ  = 3'b001;

// the steps of the test
localparam WAIT_CALIB = 2'd0;   // wait for the controller to calibrate
localparam WRITING    = 2'd1;   // write the pattern into every block
localparam READING    = 2'd2;   // read every block back and check it
localparam FINISHED   = 2'd3;   // done, the result is in errors

// where a block lives, a block is 8 columns so its number sits above 3 zero bits
function [28:0] address_of(input [25:0] block);
    address_of = {1'b0, block[24:0], 3'b000};
endfunction

// what a block should hold, 8 words each its own word number
function [255:0] pattern_for(input [25:0] block);
    integer k;
    for (k = 0; k < 8; k = k + 1)
        pattern_for[k*32 +: 32] = {block, 3'b000} + k;
endfunction

// where the test is
reg [1:0] state;
reg [25:0] writes_sent;    // blocks written so far
reg [25:0] reads_sent;     // read commands sent so far
reg [25:0] answers_seen;   // read answers checked so far

// something goes out only on a tick where the controller is ready for it
wire send_write = (state == WRITING) && cmd_ready && wr_data_rdy;          // a write, command + data together
wire send_read  = (state == READING) && (reads_sent < BLOCKS) && cmd_ready; // a read, just the command

assign cmd_en       = send_write || send_read;
assign cmd          = (state == WRITING) ? CMD_WRITE : CMD_READ;
assign addr         = (state == WRITING) ? address_of(writes_sent) : address_of(reads_sent);
assign wr_data_en   = send_write;
assign wr_data_end  = send_write;
assign wr_data      = pattern_for(writes_sent);
assign wr_data_mask = 32'd0;              // write all 32 bytes
assign done         = (state == FINISHED);

always @(posedge clk) begin
    if (reset) begin
        state <= WAIT_CALIB;
        writes_sent <= 0;
        reads_sent <= 0;
        answers_seen <= 0;
        errors <= 0;
    end else begin
        case (state)
            WAIT_CALIB: begin
                if (calibrated)
                    state <= WRITING;
            end

            WRITING: begin
                if (send_write) begin
                    writes_sent <= writes_sent + 1;
                    if (writes_sent == BLOCKS - 1)
                        state <= READING;
                end
            end

            READING: begin
                if (send_read)
                    reads_sent <= reads_sent + 1;

                if (rd_data_valid) begin
                    if (rd_data != pattern_for(answers_seen))
                        errors <= errors + 1;
                    answers_seen <= answers_seen + 1;
                    if (answers_seen == BLOCKS - 1)
                        state <= FINISHED;
                end
            end

            FINISHED: begin
                // stay here
            end
        endcase
    end
end

endmodule

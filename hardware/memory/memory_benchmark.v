// memory_benchmark.v
// times how fast the ddr3 controller handles different access patterns
// runs 16 tests and counts the ticks until every command is taken and every read answered
// address = {rank, bank, row, column}, a row holds 128 bursts

module memory_benchmark (
    input wire clk,                      // the memory controllers clk_out
    input wire reset,

    // the memory controller
    input wire calibrated,
    input wire cmd_ready,
    output wire cmd_en,
    output wire [2:0] cmd,               // 000 = write, 001 = read
    output wire [28:0] addr,             // {rank, bank, row, column}
    input wire wr_data_rdy,
    output wire wr_data_en,
    output wire wr_data_end,
    output wire [255:0] wr_data,
    output wire [31:0] wr_data_mask,
    input wire rd_data_valid,
    input wire [255:0] rd_data,

    // the results
    output wire done,                    // 1 once all 16 tests have run
    output reg [32*16-1:0] results       // test k is at bits k*32
);

localparam CMD_WRITE = 3'b000;
localparam CMD_READ  = 3'b001;
localparam TESTS = 16;

// the tests

// how many commands test t sends
function [16:0] commands_in(input [3:0] t);
    if (t == 12) commands_in = 17'd1024;
    else         commands_in = 17'd4096;
endfunction

// is command n of test t a read
function is_read_at(input [3:0] t, input [16:0] n);
    case (t)
        0, 2, 4, 6, 11, 14: is_read_at = 0;
        10:                 is_read_at = !n[0];       // read, write, read, write
        8:                  is_read_at = n[0];        // write, read, write, read
        9:                  is_read_at = n[3];        // 8 writes, 8 reads
        13:                 is_read_at = n[5];        // 32 writes, 32 reads
        default:            is_read_at = 1;
    endcase
endfunction

// an address from its parts, burst = which burst in the row
function [28:0] place(input [2:0] bank, input [14:0] row, input [6:0] burst);
    place = {1'b0, bank, row, burst, 3'b000};
endfunction

// where command n of test t goes
function [28:0] address_at(input [3:0] t, input [16:0] n, input [31:0] r);
    case (t)
        0, 1, 12:         address_at = place(3'd0, {6'd0, n[15:7]}, n[6:0]);   // straight line
        2, 3:             address_at = place(3'd0, n[14:0], 7'd0);            // new row every time
        4, 5:             address_at = place(n[2:0], 15'd0, n[9:3]);         // banks in turn, row 0 in each
        6, 7, 10:         address_at = place(3'd0, {n[0], 6'd0, n[15:8]}, n[7:1]);   // 2 rows in turn
        11:               address_at = place(3'd0, {n[1:0], 6'd0, n[15:9]}, n[8:2]); // 4 rows in turn
        14:               address_at = place(3'd0, n[15:1], {6'd0, n[0]});    // 2 bursts then another row
        15:               address_at = place(3'd0, {2'd0, n[15:3]}, {4'd0, n[2:0]}); // 8 bursts then another row
        8:                address_at = place(3'd0, {7'd0, n[15:8]}, n[7:1]);  // the write and the read hit the same burst
        9:                address_at = place(3'd0, {7'd0, n[15:8]}, {n[7:4], n[2:0]});
        13:               address_at = place(3'd0, {7'd0, n[15:8]}, {n[7:6], n[4:0]});
        default:          address_at = place(r[27:25], r[24:10], r[9:3]);    // random
    endcase
endfunction

// what a written burst holds, its address and command number
function [255:0] data_for(input [28:0] a, input [16:0] n);
    data_for = {4{3'b000, a, 15'd0, n}};   // 4 x 64 bits
endfunction

// where the benchmark is
localparam WAIT_CALIB = 2'd0;   // wait for the controller to calibrate
localparam GAP        = 2'd1;   // short pause between tests
localparam RUN        = 2'd2;   // sending commands and counting ticks
localparam FINISHED   = 2'd3;   // all done

reg [1:0] state;
reg [3:0] test;                 // which test
reg [16:0] sent;                // commands taken so far in this test
reg [16:0] reads_sent;          // of those, reads
reg [16:0] answers;             // read answers so far
reg [31:0] ticks;               // ticks since the test started
reg [15:0] gap_ticks;
reg [31:0] random;              // lfsr

// the command this tick
wire [16:0] n_cmds   = commands_in(test);
wire this_is_read    = is_read_at(test, sent);
wire [28:0] this_addr = address_at(test, sent, random);
wire one_at_a_time_ok = (test != 12) || (answers == reads_sent);   // test 12 waits for each answer
wire want_send = (state == RUN) && (sent < n_cmds) && one_at_a_time_ok;
wire send = want_send && cmd_ready && (this_is_read || wr_data_rdy);   // a write needs both command and data ready

assign cmd_en       = send;
assign cmd          = this_is_read ? CMD_READ : CMD_WRITE;
assign addr         = this_addr;
assign wr_data_en   = send && !this_is_read;
assign wr_data_end  = send && !this_is_read;
assign wr_data      = data_for(this_addr, sent);
assign wr_data_mask = 32'd0;
assign done         = (state == FINISHED);

// every command taken and every read answered
wire [16:0] answers_now = answers + (rd_data_valid ? 17'd1 : 17'd0);
wire test_over = (sent == n_cmds) && (answers_now == reads_sent);

integer k;
always @(posedge clk) begin
    if (reset) begin
        state <= WAIT_CALIB;
        test <= 0;
        sent <= 0;
        reads_sent <= 0;
        answers <= 0;
        ticks <= 0;
        gap_ticks <= 0;
        random <= 32'hACE1_2468;
        results <= 0;
    end else begin
        case (state)
            WAIT_CALIB: if (calibrated) state <= GAP;

            GAP: begin
                // short pause then the next test starts from zero
                gap_ticks <= gap_ticks + 1;
                if (gap_ticks == 999) begin
                    gap_ticks <= 0;
                    sent <= 0;
                    reads_sent <= 0;
                    answers <= 0;
                    ticks <= 0;
                    state <= RUN;
                end
            end

            RUN: begin
                ticks <= ticks + 1;
                if (send) begin
                    sent <= sent + 1;
                    if (this_is_read) reads_sent <= reads_sent + 1;
                    random <= {random[30:0], random[31] ^ random[21] ^ random[1] ^ random[0]};
                end
                if (rd_data_valid) answers <= answers + 1;
                if (test_over) begin
                    // store this tests ticks
                    for (k = 0; k < TESTS; k = k + 1)
                        if (k == test) results[k*32 +: 32] <= ticks + 1;
                    if (test == TESTS - 1) state <= FINISHED;
                    else begin
                        test <= test + 1;
                        state <= GAP;
                    end
                end
            end

            FINISHED: ;
        endcase
    end
end

endmodule

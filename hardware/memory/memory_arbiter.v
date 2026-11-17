// memory_arbiter.v
// shares the one ddr3 controller between several ports
// ports 0 and 1 always go first, the rest share the free turns by budget (deficit round robin)
// one turn = one 32 byte burst, read answers come back in order to whoever asked

module memory_arbiter #(
    parameter PORTS = 5,                       // how many ports
    parameter [PORTS*16-1:0] BUDGET = {16'd1, 16'd3, 16'd6, 16'd0, 16'd0}   // shares of the free turns, ports 4 .. 0
) (
    input wire clk,                            // the memory controllers clk_out
    input wire reset,

    // the ports, a client holds its request until its granted
    input wire [PORTS-1:0] req,                // 1 = this port is asking
    input wire [PORTS*3-1:0] port_cmd,         // 000 write, 001 read
    input wire [PORTS*29-1:0] port_addr,       // each ports address
    input wire [PORTS*256-1:0] port_wr_data,   // each ports 32 bytes to write
    input wire [PORTS*32-1:0] port_wr_mask,    // byte mask, 1 = dont write that byte
    output wire [PORTS-1:0] grant,             // pulse, your command was taken
    output wire [PORTS-1:0] rd_valid,          // pulse, rd_data is your read answer
    output wire [255:0] rd_data,               // read answers, same wires to every port

    // to gowins memory controller
    input wire cmd_ready,
    output wire cmd_en,
    output wire [2:0] cmd,
    output wire [28:0] addr,
    input wire wr_data_rdy,
    output wire wr_data_en,
    output wire wr_data_end,
    output wire [255:0] wr_data,
    output wire [31:0] wr_data_mask,
    input wire mem_rd_valid,
    input wire [255:0] mem_rd_data
);

localparam CMD_WRITE = 3'b000;
localparam CMD_READ  = 3'b001;
localparam STRICT_PORTS = 2;                   // ports 0 and 1 always go first

// the winner of this tick
wire [3:0] winner;     // which port is granted
wire send;             // 1 = the winners command goes into the output buffer

// the who asked fifo, which port each read answer belongs to
localparam ASKED_DEPTH = 64;              // reads that can be on their way at once
reg [3:0] asked [0:ASKED_DEPTH-1];        // port numbers in the order their reads were sent
reg [5:0] asked_in;
reg [5:0] asked_out;
reg [6:0] asked_count;                    // reads on their way
reg asked_full;                           // no more reads until answers come back

wire read_sent = send && (port_cmd[winner*3 +: 3] == CMD_READ);
wire [6:0] asked_count_next = asked_count + read_sent - mem_rd_valid;

always @(posedge clk) begin
    if (reset) begin
        asked_in <= 0;
        asked_out <= 0;
        asked_count <= 0;
        asked_full <= 1'b0;
    end else begin
        if (read_sent) begin
            asked[asked_in] <= winner;
            asked_in <= asked_in + 1;     // wraps by itself
        end
        if (mem_rd_valid)
            asked_out <= asked_out + 1;
        asked_count <= asked_count_next;
        asked_full <= (asked_count_next == ASKED_DEPTH);
    end
end

// answers go to every port, only the owners rd_valid goes to 1
// both come from registers one clock after the controllers answer
wire [3:0] owner = asked[asked_out];
reg [PORTS-1:0] answer_valid;
reg [255:0] answer_data;

always @(posedge clk) begin
    if (reset) answer_valid <= 0;
    else       answer_valid <= mem_rd_valid ? (1 << owner) : 0;
    answer_data <= mem_rd_data;
end

assign rd_data = answer_data;
assign rd_valid = answer_valid;

// output buffer, the winners command waits here for the controller
// each ports command ANDed with its won bit then ORed together
reg [PORTS-1:0] won;
reg [3+29+256+32-1:0] winner_entry;
integer w;
always @(*) begin
    winner_entry = 0;
    for (w = 0; w < PORTS; w = w + 1)
        if (won[w])
            winner_entry = winner_entry | {port_cmd[w*3 +: 3], port_addr[w*29 +: 29], port_wr_data[w*256 +: 256],
                                           port_wr_mask[w*32 +: 32]};
end
localparam ENTRY = 3 + 29 + 256 + 32;     // cmd, addr, data, mask
wire buffer_room;                         // the buffer can take a command this tick
wire out_valid;
wire [ENTRY-1:0] out_entry;
wire [2:0] out_cmd = out_entry[ENTRY-1 -: 3];
// the controller takes it when it can take the command and (for a write) the data
wire out_taken = out_valid && cmd_ready && (out_cmd == CMD_READ || wr_data_rdy);

request_buffer #(.WIDTH(ENTRY)) out_buffer (
    .clk(clk), .reset(reset),
    .in_valid(send),
    .in_data(winner_entry),
    .in_ready(buffer_room),
    .out_valid(out_valid), .out_data(out_entry), .out_ready(out_taken)
);

// a port can go if theres room in the buffer and in the who asked fifo
reg [PORTS-1:0] eligible;   // 1 = asking and its command could go in right now
integer p;

always @(*) begin
    for (p = 0; p < PORTS; p = p + 1)
        eligible[p] = req[p] && buffer_room && !asked_full;
end

// the budgets, each ports turns left in this window. signed, below zero = in debt
// one flat vector, port q is at [q*18 +: 18]
reg [PORTS*18-1:0] credit;
reg [PORTS-1:0] has_credit;   // credit > 0, kept as ready made bits

// the window ends when no port thats asking has budget left
reg budget_left;

always @(*) begin
    budget_left = 0;
    for (p = STRICT_PORTS; p < PORTS; p = p + 1)
        if (req[p] && has_credit[p]) budget_left = 1;
end

// the picker, first yes wins
reg [3:0] pick;
reg found;

always @(*) begin
    found = 0;
    pick = 0;
    // 1 strict ports, lowest number first
    for (p = 0; p < STRICT_PORTS; p = p + 1)
        if (!found && eligible[p]) begin found = 1; pick = p; end
    // 2 ports with budget left, lowest number first
    for (p = STRICT_PORTS; p < PORTS; p = p + 1)
        if (!found && eligible[p] && has_credit[p]) begin found = 1; pick = p; end
    // 3 anyone else still waiting gets the leftover turn
    for (p = STRICT_PORTS; p < PORTS; p = p + 1)
        if (!found && eligible[p]) begin found = 1; pick = p; end
end

assign winner = pick;
assign send = found;
always @(*) won = found ? (1 << pick) : 0;

// every free turn costs 1. when the window ends everyone is topped up by its share
// the 4 possible next budgets are worked out ahead and the pickers answer just chooses one
integer q;
reg signed [17:0] share;     // signed so a debt compares right
reg signed [17:0] stay, stay_new, paid, paid_new;    // no turn / took a turn, same window / new window
reg took;                                            // this port took a turn this tick

// minus the turn taken, plus a share in a new window, never more than one share
function signed [17:0] next_credit(input signed [17:0] now, input turn, input new_window, input signed [17:0] top);
    reg signed [17:0] t;
    begin
        t = now - (turn ? 18'sd1 : 18'sd0);
        if (new_window) t = t + top;
        if (t > top) t = top;
        next_credit = t;
    end
endfunction

always @(posedge clk) begin
    for (q = 0; q < PORTS; q = q + 1) begin
        share = $signed({2'b00, BUDGET[q*16 +: 16]});
        if (reset) begin
            credit[q*18 +: 18] <= share;
            has_credit[q] <= (share > 0);
        end else begin
            stay     = next_credit($signed(credit[q*18 +: 18]), 1'b0, 1'b0, share);
            stay_new = next_credit($signed(credit[q*18 +: 18]), 1'b0, 1'b1, share);
            paid     = next_credit($signed(credit[q*18 +: 18]), 1'b1, 1'b0, share);
            paid_new = next_credit($signed(credit[q*18 +: 18]), 1'b1, 1'b1, share);
            took = won[q] && (q >= STRICT_PORTS);
            case ({took, !budget_left})
                2'b00: begin credit[q*18 +: 18] <= stay;     has_credit[q] <= (stay > 0);     end
                2'b01: begin credit[q*18 +: 18] <= stay_new; has_credit[q] <= (stay_new > 0); end
                2'b10: begin credit[q*18 +: 18] <= paid;     has_credit[q] <= (paid > 0);     end
                2'b11: begin credit[q*18 +: 18] <= paid_new; has_credit[q] <= (paid_new > 0); end
            endcase
        end
    end
end

// the buffers oldest command goes to the memory controller
assign cmd_en       = out_taken;
assign cmd          = out_cmd;
assign addr         = out_entry[ENTRY-4 -: 29];
assign wr_data      = out_entry[32 +: 256];
assign wr_data_mask = out_entry[31:0];
assign wr_data_en   = out_taken && (out_cmd == CMD_WRITE);
assign wr_data_end  = wr_data_en;
// granted = your command is in the buffer
assign grant        = send ? (1 << winner) : 0;

endmodule

// gpu_memory_door.v
// the gpus one port to memory, shared by the back half, command processor, binning and setup
// requests go into a small buffer first so the arbiter only sees registers
// read answers go back to whoever asked, in order

module gpu_memory_door (
    input wire clk,
    input wire reset,

    // the back half
    input wire back_req,
    input wire [2:0] back_cmd,
    input wire [28:0] back_addr,
    input wire [255:0] back_data,
    input wire [31:0] back_mask,
    output wire back_grant,
    output reg back_rd_valid,

    // the command processor (reads only)
    input wire cp_req,
    input wire [2:0] cp_cmd,
    input wire [28:0] cp_addr,
    output wire cp_grant,
    output reg cp_rd_valid,

    // binning
    input wire bin_req,
    input wire [2:0] bin_cmd,
    input wire [28:0] bin_addr,
    input wire [255:0] bin_data,
    input wire [31:0] bin_mask,
    output wire bin_grant,

    // setup
    input wire setup_req,
    input wire [2:0] setup_cmd,
    input wire [28:0] setup_addr,
    input wire [255:0] setup_data,
    input wire [31:0] setup_mask,
    output wire setup_grant,

    // the arbiters port
    output wire req,
    output wire [2:0] cmd,
    output wire [28:0] addr,
    output wire [255:0] wr_data,
    output wire [31:0] wr_mask,
    input wire grant,
    input wire rd_valid,
    input wire [255:0] rd_data,

    // read data one clock later, both readers share it and only the owners rd_valid is 1
    output reg [255:0] answer_data
);

localparam CMD_READ = 3'b001;

// requests waiting for the arbiter
localparam ENTRY = 1 + 3 + 29 + 256 + 32;      // whose (1 = command processor), cmd, addr, data, mask
wire room;                                     // buffer can take a request this tick
wire [ENTRY-1:0] out_entry;
wire out_by_cp = out_entry[ENTRY-1];
wire [2:0] out_cmd = out_entry[ENTRY-2 -: 3];

// whose turn it is gets decided a clock ahead and kept in a register
// so each grant only depends on its own request and registers
// priority is back half, command processor, binning, setup
reg turn_back, turn_cp, turn_bin, turn_setup;

// the owner keeps its turn while it still asks, up to RUN grants
// ddr3 keeps one row open so hopping between parts every burst is slow
localparam RUN = 8;
reg [4:0] run_left;
wire owner_asks = (turn_back && back_req) || (turn_cp && cp_req) || (turn_bin && bin_req) || (turn_setup && setup_req);
wire keep = (run_left != 0) && owner_asks;
always @(posedge clk) begin
    if (reset) begin
        turn_back <= 1'b0;  turn_cp <= 1'b0;  turn_bin <= 1'b0;  turn_setup <= 1'b0;
        run_left <= 0;
    end else if (keep) begin
        if (room) run_left <= run_left - 1'b1;
    end else begin
        turn_back  <= back_req;
        turn_cp    <= !back_req && cp_req;
        turn_bin   <= !back_req && !cp_req && bin_req;
        turn_setup <= !back_req && !cp_req && !bin_req && setup_req;
        run_left <= RUN - 1;
    end
end

wire pick_back  = turn_back  && back_req;
wire pick_cp    = turn_cp    && cp_req;
wire pick_bin   = turn_bin   && bin_req;
wire pick_setup = turn_setup && setup_req;

assign back_grant  = room && pick_back;
assign cp_grant    = room && pick_cp;
assign bin_grant   = room && pick_bin;
assign setup_grant = room && pick_setup;

request_buffer #(.WIDTH(ENTRY)) waiting (
    .clk(clk), .reset(reset),
    .in_valid(pick_back || pick_cp || pick_bin || pick_setup),
    .in_data({turn_cp,
              turn_back ? back_cmd  : turn_cp ? cp_cmd  : turn_bin ? bin_cmd  : setup_cmd,
              turn_back ? back_addr : turn_cp ? cp_addr : turn_bin ? bin_addr : setup_addr,
              turn_back ? back_data : turn_bin ? bin_data : setup_data,
              turn_back ? back_mask : turn_bin ? bin_mask : setup_mask}),
    .in_ready(room),
    .out_valid(req), .out_data(out_entry), .out_ready(grant)
);

assign cmd = out_cmd;
assign addr = out_entry[ENTRY-5 -: 29];
assign wr_data = out_entry[32 +: 256];
assign wr_mask = out_entry[31:0];

// whose read was it, 1 = command processor 0 = back half
reg whose [0:63];
reg [5:0] w_in, w_out;
wire read_sent = grant && req && (out_cmd == CMD_READ);

always @(posedge clk) begin
    if (reset) begin
        w_in <= 0;
        w_out <= 0;
    end else begin
        if (read_sent) begin
            whose[w_in] <= out_by_cp;
            w_in <= w_in + 1'b1;           // wraps by itself
        end
        if (rd_valid) w_out <= w_out + 1'b1;
    end
end

always @(posedge clk) begin
    if (reset) begin
        cp_rd_valid <= 1'b0;
        back_rd_valid <= 1'b0;
    end else begin
        cp_rd_valid   <= rd_valid && whose[w_out];
        back_rd_valid <= rd_valid && !whose[w_out];
    end
    answer_data <= rd_data;
end

endmodule

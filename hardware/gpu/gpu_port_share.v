// gpu_port_share.v
// the gpu has one memory port and two parts use it
// the controller reads shelves and cards, the writeout writes finished tiles
// lets one through at a time, writeout first when both ask

module gpu_port_share (
    input wire clk,
    input wire reset,
    // the controller (reads)
    input wire ctrl_req,
    input wire [2:0] ctrl_cmd,
    input wire [28:0] ctrl_addr,
    output wire ctrl_grant,

    // the writeout (writes)
    input wire wo_req,
    input wire [2:0] wo_cmd,
    input wire [28:0] wo_addr,
    input wire [255:0] wo_data,
    input wire [31:0] wo_mask,
    output wire wo_grant,

    // the arbiters port
    output wire req,
    output wire [2:0] cmd,
    output wire [28:0] addr,
    output wire [255:0] wr_data,
    output wire [31:0] wr_mask,
    input wire grant
);

// whoever got the last grant keeps going while it still asks, up to RUN grants in a row
localparam RUN = 8;
reg last_ctrl;                     // last grant went to the controller
reg [4:0] run_left;                // grants left in the run
wire stick_ctrl = last_ctrl && (run_left != 0) && ctrl_req;
wire pick_writeout = wo_req && !stick_ctrl;
always @(posedge clk) begin
    if (reset) begin
        last_ctrl <= 1'b0;
        run_left <= 0;
    end else if (grant && req) begin
        if (pick_writeout == !last_ctrl && run_left != 0) run_left <= run_left - 1'b1;   // same one again
        else run_left <= RUN - 1;                                                   // new run
        last_ctrl <= !pick_writeout;
    end
end

assign req      = ctrl_req || wo_req;
assign cmd      = pick_writeout ? wo_cmd  : ctrl_cmd;
assign addr     = pick_writeout ? wo_addr : ctrl_addr;
assign wr_data  = wo_data;
assign wr_mask  = wo_mask;

assign wo_grant   = grant && pick_writeout;
assign ctrl_grant = grant && !pick_writeout;

endmodule

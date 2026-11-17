// device_hub.v
// the cpus device window (0xE80n_oooo) to our devices registers, n = device, oooo = register offset
// the cpu bus and the devices are on different clocks so a request bit and a done bit cross through 2 flip flops

module device_hub (
    // cpu side (ahb)
    input wire bus_clk,
    input wire bus_reset,
    input wire hsel,                        // this window is being used
    input wire [31:0] haddr,
    input wire [1:0] htrans,                // bit 1 = a real transfer
    input wire hwrite,
    input wire [31:0] hwdata,
    output reg [31:0] hrdata,               // changes on the falling edge, see below
    output reg hready,                      // 0 = cpu waits
    output wire hresp,                      // always okay

    // device side
    input wire dev_clk,
    input wire dev_reset,
    output reg dev_write,  // one clock pulse, write dev_wdata
    output reg dev_read,  // one clock pulse, answer on dev_rdata the next clock
    output reg [3:0] dev_select,            // which device 0-15
    output reg [15:0] dev_offset,           // which register, byte offset
    output reg [31:0] dev_wdata,
    input wire [16*32-1:0] dev_rdata  // device n answers at bits n*32
);

assign hresp = 1'b0;

// the cpu bus side
localparam IDLE = 2'd0, DATA = 2'd1, WAIT = 2'd2, FINISH = 2'd3;
reg [1:0] state;
wire ready_now = (state == IDLE) || (state == FINISH);
reg [31:0] answer_now;                      // the read answer

// hready and hrdata change on the falling edge
// the cpu gets this clock a bit later than we do so this fixes a hold problem
always @(negedge bus_clk) begin
    hready <= ready_now;
    hrdata <= answer_now;
end

// what crosses, held still while the request is out
reg [19:0] req_addr;                        // address inside the window
reg req_write;
reg [31:0] req_wdata;
reg req_flip;                               // flips once per access

// done bit coming back through 2 flip flops
reg done_flip;
reg done_s1, done_s2;
reg [31:0] answer;                          // from the device side

// new transfer, the address phase
wire new_transfer = ready_now && hsel && htrans[1];

always @(posedge bus_clk) begin
    if (bus_reset) begin
        state <= IDLE;
        req_flip <= 1'b0;
        done_s1 <= 1'b0;
        done_s2 <= 1'b0;
    end else begin
        done_s1 <= done_flip;
        done_s2 <= done_s1;
        case (state)
            IDLE, FINISH: begin
                if (new_transfer) begin
                    req_addr <= haddr[19:0];
                    req_write <= hwrite;
                    state <= DATA;
                end else
                    state <= IDLE;
            end
            DATA: begin
                // data phase, write data is on hwdata now
                req_wdata <= hwdata;
                req_flip <= !req_flip;      // send it
                state <= WAIT;
            end
            WAIT: begin
                if (done_s2 == req_flip) begin
                    answer_now <= answer;   // a write answers 0
                    state <= FINISH;        // done
                end
            end
        endcase
    end
end

// the device side
reg req_s1, req_s2, req_seen;               // request bit through 2 flip flops, and the last one handled
reg reading;                                // a read went out last clock, answer is on dev_rdata now
wire new_request = (req_s2 != req_seen);

always @(posedge dev_clk) begin
    if (dev_reset) begin
        req_s1 <= 1'b0;
        req_s2 <= 1'b0;
        req_seen <= 1'b0;
        done_flip <= 1'b0;
        dev_write <= 1'b0;
        dev_read <= 1'b0;
        reading <= 1'b0;
    end else begin
        req_s1 <= req_flip;
        req_s2 <= req_s1;
        dev_write <= 1'b0;
        dev_read <= 1'b0;
        reading <= 1'b0;

        if (new_request) begin
            req_seen <= req_s2;
            dev_select <= req_addr[19:16];
            dev_offset <= req_addr[15:0];
            dev_wdata <= req_wdata;
            if (req_write) begin
                dev_write <= 1'b1;
                answer <= 32'd0;
                done_flip <= !done_flip;        // a write is done once its sent
            end else begin
                dev_read <= 1'b1;
            end
        end
        // a read, the device answers the clock after dev_read
        if (dev_read) reading <= 1'b1;
        if (reading) begin
            answer <= dev_rdata[dev_select * 32 +: 32];
            done_flip <= !done_flip;
        end
    end
end

endmodule

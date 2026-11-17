// gpu_clock_crossing.v
// the gpu runs on its own clock, the memory side on another
// every signal between the two goes through here
// requests and read answers use async fifos, the frame buffer handshake uses toggles

module gpu_clock_crossing #(
    parameter LIMIT = 112                  // most reads in flight, the answer fifo has 128 places
) (
    // gpu side
    input wire gpu_clk,
    input wire gpu_reset,
    input wire g_req,
    input wire [2:0] g_cmd,
    input wire [28:0] g_addr,
    input wire [255:0] g_wr_data,
    input wire [31:0] g_wr_mask,
    output reg g_grant,                    // 1 = room, a request offered this tick is taken
    output reg g_rd_valid,
    output reg [255:0] g_rd_data,
    output reg g_buffer_ok,                // a buffer is reserved for the next frame
    output reg [24:0] g_buffer_start,      // where it starts
    input wire g_buffer_begin,             // 1 for one tick, gpu starts drawing into it
    input wire g_buffer_end,               // 1 for one tick, gpu finished that frame
    output reg g_tv_frame,                 // 1 for one tick, the tv started a frame

    // memory side
    input wire mem_clk,
    input wire mem_reset,
    output wire m_req,                     // to the arbiters gpu port
    output wire [2:0] m_cmd,
    output wire [28:0] m_addr,
    output wire [255:0] m_wr_data,
    output wire [31:0] m_wr_mask,
    input wire m_grant,
    input wire m_rd_valid,                 // the arbiters answer
    input wire [255:0] m_rd_data,
    input wire m_buffer_ok,                // from the frame buffer keeper
    input wire [24:0] m_buffer_start,
    output reg m_buffer_begin,
    output reg m_buffer_end,
    input wire m_tv_frame                  // from the frame reader
);

localparam CMD_READ = 3'b001;
localparam REQ_WIDTH = 3 + 29 + 256 + 32;

// 1 memory requests, gpu to arbiter
wire req_full;
wire [4:0] req_count;                   // entries in the fifo as the gpu side sees it
wire req_empty;
wire [REQ_WIDTH-1:0] req_out;
wire buffer_room;

// reads taken but not answered yet
// the memory side cant wait so stop granting when too many are out, then the answer fifo cant overflow
reg [7:0] reads_out;
wire take = g_req && g_grant;
wire take_read = take && (g_cmd == CMD_READ);
wire answer_now;                        // an answer leaves the answer fifo this tick

// counted a tick late from a register
reg take_read_r;
always @(posedge gpu_clk) begin
    if (gpu_reset) begin
        reads_out <= 8'd0;
        g_grant <= 1'b0;
        take_read_r <= 1'b0;
    end else begin
        take_read_r <= take_read;
        reads_out <= reads_out + take_read_r - answer_now;
        // room, with 2 places to spare since the count is a tick old
        g_grant <= (req_count < 5'd13) && (reads_out < LIMIT);
    end
end

// small so it goes in lut memory
async_fifo #(.WIDTH(REQ_WIDTH), .ADDR_BITS(4), .SMALL(1)) requests (
    .write_clk(gpu_clk), .write_reset(gpu_reset),
    .write_en(take), .write_data({g_cmd, g_addr, g_wr_data, g_wr_mask}),
    .full(req_full), .write_count(req_count),
    .read_clk(mem_clk), .read_reset(mem_reset),
    .read_en(buffer_room), .read_data(req_out), .empty(req_empty)
);

// two buffers in a row, one by the fifo and one by the arbiter
wire mid_valid, mid_room;
wire [REQ_WIDTH-1:0] mid_data;
request_buffer #(.WIDTH(REQ_WIDTH)) by_fifo (
    .clk(mem_clk), .reset(mem_reset),
    .in_valid(!req_empty), .in_data(req_out), .in_ready(buffer_room),
    .out_valid(mid_valid), .out_data(mid_data), .out_ready(mid_room)
);
request_buffer #(.WIDTH(REQ_WIDTH)) by_arbiter (
    .clk(mem_clk), .reset(mem_reset),
    .in_valid(mid_valid), .in_data(mid_data), .in_ready(mid_room),
    .out_valid(m_req), .out_data({m_cmd, m_addr, m_wr_data, m_wr_mask}), .out_ready(m_grant)
);

// 2 read answers, arbiter to gpu
wire answer_empty;
wire [255:0] answer_out;
assign answer_now = !answer_empty;      // always taken right away

async_fifo #(.WIDTH(256), .ADDR_BITS(7)) answers (
    .write_clk(mem_clk), .write_reset(mem_reset),
    .write_en(m_rd_valid), .write_data(m_rd_data),
    .full(), .write_count(),
    .read_clk(gpu_clk), .read_reset(gpu_reset),
    .read_en(answer_now), .read_data(answer_out), .empty(answer_empty)
);

always @(posedge gpu_clk) begin
    g_rd_valid <= gpu_reset ? 1'b0 : answer_now;
    g_rd_data <= answer_out;
end

// 3 the frame buffers and the tv frame tick
// a toggle crossing: an event flips a flop, the other clock catches it with 2 flops and sees the change
// gpu side
reg g_ask;                               // toggles to say frame done, give me a buffer
reg g_asked_once;                        // first ask right after reset
reg [2:0] g_answer_seen;                 // the answer toggle synced, bit 0 may be mid change
reg [2:0] g_tv_seen;
reg [24:0] g_held_copy;
reg [11:0] g_taken;                      // requests taken from the gpu, wraps
reg [11:0] g_end_taken;                  // g_taken when the gpu said finished, held still
reg m_tv_toggle;                         // memory side regs, used below
reg m_answer;
reg [24:0] m_held_start;

always @(posedge gpu_clk) begin
    if (gpu_reset) begin
        g_ask <= 1'b0;
        g_asked_once <= 1'b0;
        g_buffer_ok <= 1'b0;
        g_tv_frame <= 1'b0;
        g_answer_seen <= 3'd0;
        g_tv_seen <= 3'd0;
        g_taken <= 12'd0;
        g_end_taken <= 12'd0;
    end else begin
        g_taken <= g_taken + take;
        g_answer_seen <= {g_answer_seen[1:0], m_answer};
        g_tv_seen <= {g_tv_seen[1:0], m_tv_toggle};
        g_tv_frame <= g_tv_seen[2] ^ g_tv_seen[1];
        // ask once after reset then after every finished frame
        if (!g_asked_once) begin
            g_asked_once <= 1'b1;
            g_ask <= !g_ask;
        end else if (g_buffer_end) begin
            g_ask <= !g_ask;
            g_end_taken <= g_taken + take;       // counts this ticks request too
        end
        // the answer came, m_held_start has been still long enough to copy
        if (g_answer_seen[2] ^ g_answer_seen[1]) begin
            g_buffer_ok <= 1'b1;
            g_buffer_start <= m_held_start;
        end else if (g_buffer_begin)
            g_buffer_ok <= 1'b0;
    end
end

// memory side
reg [2:0] m_ask_seen;
reg m_drew;                              // a buffer was handed out, so the next ask also means its finished
reg m_need;                              // an ask is waiting for a buffer
reg m_end_waits;                         // a finished frame waits for its last requests to reach the arbiter
reg [11:0] m_delivered;                  // requests handed to the arbiter, wraps
reg [11:0] m_end_target;                 // the gpus count when it said finished
wire [11:0] m_end_left = m_end_target - m_delivered;      // this frames requests not handed over yet
wire m_frame_delivered = (m_end_left == 12'd0) || m_end_left[11];   // none left or already past it

always @(posedge mem_clk) begin
    if (mem_reset) begin
        m_ask_seen <= 3'd0;
        m_drew <= 1'b0;
        m_need <= 1'b0;
        m_answer <= 1'b0;
        m_end_waits <= 1'b0;
        m_delivered <= 12'd0;
        m_buffer_begin <= 1'b0;
        m_buffer_end <= 1'b0;
        m_tv_toggle <= 1'b0;
    end else begin
        m_ask_seen <= {m_ask_seen[1:0], g_ask};
        if (m_req && m_grant) m_delivered <= m_delivered + 1'b1;
        if (m_tv_frame) m_tv_toggle <= !m_tv_toggle;
        m_buffer_begin <= 1'b0;
        m_buffer_end <= 1'b0;
        if (m_ask_seen[2] ^ m_ask_seen[1]) begin
            // new ask, the buffer handed out last time holds a finished frame
            if (m_drew) m_end_waits <= 1'b1;
            m_end_target <= g_end_taken;         // held still since the toggle so safe to copy
            m_need <= 1'b1;
        end else if (m_end_waits) begin
            // pass the finished frame on once all its requests reached the arbiter
            if (m_frame_delivered) begin
                m_buffer_end <= 1'b1;
                m_end_waits <= 1'b0;
            end
        end else if (m_need && m_buffer_ok && !m_buffer_end) begin
            // reserve the free buffer
            m_buffer_begin <= 1'b1;
            m_held_start <= m_buffer_start;
            m_drew <= 1'b1;
            m_need <= 1'b0;
            m_answer <= !m_answer;
        end
    end
end

endmodule

// request_buffer.v
// holds requests on their way to memory, 2 slots, first in first out
// each sides decisions start and end at a register so the logic between them stays short

module request_buffer #(
    parameter WIDTH = 8                    // bits per request
) (
    input wire clk,
    input wire reset,

    // in, a request goes in when in_valid and in_ready are both 1
    input wire in_valid,
    input wire [WIDTH-1:0] in_data,
    output wire in_ready,

    // out, the oldest request, taken when out_valid and out_ready are both 1
    output wire out_valid,
    output wire [WIDTH-1:0] out_data,
    input wire out_ready
);

reg [WIDTH-1:0] slot0, slot1;
reg write_at, read_at;                         // which slot is written next / read next
reg [1:0] count;                               // requests held, 0 1 or 2
reg held0, held1;                              // this slot holds a request

// has room and holds a request as ready made bits, worked out a tick early
reg not_full, not_empty;
assign in_ready = not_full;
assign out_valid = not_empty;
assign out_data = read_at ? slot1 : slot0;

// push uses the counts own bit instead of not_full (always equal)
// so synthesis cant share one gate between this buffer and the sender
wire push = in_valid && !count[1];
wire pop = out_valid && out_ready;
wire [1:0] count_next = count + push - pop;

always @(posedge clk) begin
    if (reset) begin
        write_at <= 1'b0;
        read_at <= 1'b0;
        count <= 2'd0;
        not_full <= 1'b1;
        not_empty <= 1'b0;
        held0 <= 1'b0;
        held1 <= 1'b0;
    end else begin
        if (push) write_at <= !write_at;
        if (pop) read_at <= !read_at;
        count <= count_next;
        not_full <= (count_next != 2'd2);
        not_empty <= (count_next != 2'd0);
        // a slot fills when a request goes in and empties when its taken
        if      (push && !write_at) held0 <= 1'b1;
        else if (pop && !read_at)   held0 <= 1'b0;
        if      (push && write_at)  held1 <= 1'b1;
        else if (pop && read_at)    held1 <= 1'b0;
    end
end

// the data, an empty slot just keeps copying in_data
always @(posedge clk) begin
    if (!held0) slot0 <= in_data;
    if (!held1) slot1 <= in_data;
end

endmodule

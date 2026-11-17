// request_buffer_tb.v
// the 2 place request buffer on its own with random requests in and random takers
// a reference queue says what the buffer must hold, checked every tick, plus a reset in the middle
`timescale 1ns/1ps
module request_buffer_tb;

reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;

reg in_valid = 0;
reg [15:0] in_data = 0;
wire in_ready;
wire out_valid;
wire [15:0] out_data;
reg out_ready = 0;

request_buffer #(.WIDTH(16)) dut (
    .clk(clk), .reset(reset),
    .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
    .out_valid(out_valid), .out_data(out_data), .out_ready(out_ready)
);

// the reference, what the buffer must hold, oldest first
reg [15:0] model [0:1];
integer held = 0;
integer errors = 0, pushes = 0, pops = 0, full_ticks = 0, empty_ticks = 0, both_ticks = 0;
reg [15:0] next_value = 1;

task fail(input [8*60-1:0] what);
    begin
        if (errors < 10) $display("  FAIL at %0t: %0s (held %0d, out_valid %b, in_ready %b, out_data %h, model %h)",
                                  $time, what, held, out_valid, in_ready, out_data, model[0]);
        errors = errors + 1;
    end
endtask

integer t, mode;
reg push_now, pop_now;     // this ticks handshakes, taken before the clock edge so theres no race
initial begin
    repeat (3) @(posedge clk);
    #1 reset = 0;
    for (t = 0; t < 20000; t = t + 1) begin
        // this ticks inputs
        if (t % 500 == 0) mode = $urandom % 4;            // stretches 0 normal, 1 never take, 2 always take, 3 normal
        in_valid = ($urandom % 3 != 0);
        in_data = next_value;
        out_ready = (mode == 1) ? 0 : (mode == 2) ? 1 : ($urandom % 2);
        if (t == 12345) reset = 1;                         // a reset in the middle
        if (t == 12347) reset = 0;
        #3;
        // what the buffer shows must match the reference
        if (!reset) begin
            if (out_valid !== (held != 0)) fail("out_valid is not (holds a request)");
            if (in_ready !== (held != 2)) fail("in_ready is not (has room)");
            if (held != 0 && out_data !== model[0]) fail("out_data is not the oldest request");
            if (held == 2) full_ticks = full_ticks + 1;
            if (held == 0) empty_ticks = empty_ticks + 1;
        end
        push_now = in_valid && in_ready;
        pop_now = out_valid && out_ready;
        @(posedge clk);
        // the reference moves as the handshakes say
        if (reset) held = 0;
        else begin
            if (push_now && pop_now) both_ticks = both_ticks + 1;
            if (pop_now) begin
                model[0] = model[1];
                held = held - 1;
                pops = pops + 1;
            end
            if (push_now) begin
                model[held] = in_data;
                held = held + 1;
                pushes = pushes + 1;
                next_value = next_value + 1;
            end
        end
        #1;
    end
    $display("request buffer: %0d in, %0d out; ticks full %0d, empty %0d, in and out together %0d",
             pushes, pops, full_ticks, empty_ticks, both_ticks);
    if (full_ticks == 0 || empty_ticks == 0 || both_ticks == 0) fail("the test never reached full / empty / both");
    if (errors == 0) $display("PASSED: every check is right");
    else $display("FAILED: %0d wrong", errors);
    $finish;
end

endmodule

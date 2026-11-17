`timescale 1ns/1ps
// request_buffer_equiv_tb.v
// new request buffer vs the old one, same random inputs, every output compared every tick
module request_buffer_equiv_tb;
    reg clk = 0; always #5 clk = !clk;
    reg reset = 1, in_valid = 0, out_ready = 0; reg [15:0] in_data = 0;
    wire r0, r1, v0, v1; wire [15:0] d0, d1;
    request_buffer #(.WIDTH(16)) new_one (.clk(clk), .reset(reset), .in_valid(in_valid), .in_data(in_data), .in_ready(r0), .out_valid(v0), .out_data(d0), .out_ready(out_ready));
    request_buffer_old #(.WIDTH(16)) old_one (.clk(clk), .reset(reset), .in_valid(in_valid), .in_data(in_data), .in_ready(r1), .out_valid(v1), .out_data(d1), .out_ready(out_ready));
    integer t, bad = 0, pushes = 0, pops = 0, full_ticks = 0, seed = 5, mode;
    initial begin
        repeat (3) @(posedge clk); reset = 0;
        for (t = 0; t < 1000000; t = t + 1) begin
            @(negedge clk);
            mode = (t / 50000) % 4;
            in_valid = (mode == 0) ? (($random(seed) & 3) != 0) : (mode == 1) ? (($random(seed) & 7) == 0) : ($random(seed) & 1);
            out_ready = (mode == 2) ? (($random(seed) & 7) == 0) : (mode == 3) ? 1 : ($random(seed) & 1);
            in_data = $random(seed);
            if (($random(seed) & 4095) == 0) reset = 1; else reset = 0;      // a reset now and then
            @(posedge clk); #1;
        end
        $display("request buffer old vs new: 1,000,000 ticks, %0d pushes, %0d pops, %0d full ticks, differences %0d: %s",
                 pushes, pops, full_ticks, bad, bad == 0 ? "SAME" : "DIFFERENT");
        $finish;
    end
    always @(negedge clk) begin
        if (in_valid && r0) pushes = pushes + 1;
        if (v0 && out_ready) pops = pops + 1;
        if (!r0) full_ticks = full_ticks + 1;
        if ({r0, v0, (v0 ? d0 : 16'd0), new_one.count, new_one.held0, new_one.held1, new_one.write_at, new_one.read_at} !==
            {r1, v1, (v1 ? d1 : 16'd0), old_one.count, old_one.held0, old_one.held1, old_one.write_at, old_one.read_at}) begin
            bad = bad + 1; if (bad < 5) $display("tick %0d differs", t);
        end
    end
endmodule

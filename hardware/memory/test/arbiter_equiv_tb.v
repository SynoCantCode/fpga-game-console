`timescale 1ns/1ps
// arbiter_equiv_tb.v
// new arbiter vs the old one, same random inputs, every output compared every tick
module arb_equiv_tb;
    reg clk = 0; always #5 clk = !clk;
    reg reset = 1;
    reg [4:0] req = 0; reg [14:0] cmd_in = 0; reg [144:0] addr_in = 0; reg [1279:0] data_in = 0; reg [159:0] mask_in = 0;
    reg cmd_ready = 1, wr_data_rdy = 1, mem_rd_valid = 0; reg [255:0] mem_rd_data = 0;
    wire [4:0] g0, g1, v0, v1; wire [255:0] d0, d1, w0, w1; wire c0, c1, e0, e1, n0, n1; wire [2:0] k0, k1;
    wire [28:0] a0, a1; wire [31:0] m0, m1; wire cal;
    memory_arbiter #(.PORTS(5)) new_one (.clk(clk), .reset(reset), .req(req), .port_cmd(cmd_in), .port_addr(addr_in),
        .port_wr_data(data_in), .port_wr_mask(mask_in), .grant(g0), .rd_valid(v0), .rd_data(d0), .cmd_ready(cmd_ready),
        .cmd_en(c0), .cmd(k0), .addr(a0), .wr_data_rdy(wr_data_rdy), .wr_data_en(e0), .wr_data_end(n0), .wr_data(w0),
        .wr_data_mask(m0), .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data));
    memory_arbiter_old #(.PORTS(5)) old_one (.clk(clk), .reset(reset), .req(req), .port_cmd(cmd_in), .port_addr(addr_in),
        .port_wr_data(data_in), .port_wr_mask(mask_in), .grant(g1), .rd_valid(v1), .rd_data(d1), .cmd_ready(cmd_ready),
        .cmd_en(c1), .cmd(k1), .addr(a1), .wr_data_rdy(wr_data_rdy), .wr_data_en(e1), .wr_data_end(n1), .wr_data(w1),
        .wr_data_mask(m1), .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data));
    integer debt = 0, windows = 0, took_at_window = 0, k;
    integer t, bad = 0, grants = 0, reads_out = 0, i, mode; integer seed = 7;
    initial begin
        repeat (3) @(posedge clk); reset = 0;
        for (t = 0; t < 400000; t = t + 1) begin
            @(negedge clk);
            mode = (t / 20000) % 4;              // phases busy, sparse, controller stalling, mixed
            for (i = 0; i < 5; i = i + 1) begin
                if (g0[i] || !req[i] || ($random(seed) & 31) == 0)
                    req[i] = (mode == 1) ? (($random(seed) & 7) == 0) : (($random(seed) & 3) != 0);
                if (g0[i] || !req[i]) begin
                    cmd_in[i*3 +: 3] = ($random(seed) & 1) ? 3'b001 : 3'b000;
                    addr_in[i*29 +: 29] = $random(seed);
                    data_in[i*256 +: 256] = {8{$random(seed)}};
                    mask_in[i*32 +: 32] = $random(seed);
                end
            end
            cmd_ready = (mode == 2) ? (($random(seed) & 3) == 0) : (($random(seed) & 7) != 0);
            wr_data_rdy = ($random(seed) & 7) != 0;
            mem_rd_valid = (reads_out > 0) && (($random(seed) & 3) == 0);
            mem_rd_data = {8{$random(seed)}};
            @(posedge clk); #1;
        end
        $display("ticks 400000, grants %0d, differences %0d: %s", grants, bad, bad == 0 ? "SAME" : "DIFFERENT");
        $display("coverage: tick-ports in debt %0d, new-window ticks %0d, a turn taken on a new-window tick %0d", debt, windows, took_at_window);
        $finish;
    end
    always @(posedge clk) if (!reset) begin
        if (c0 && k0 == 3'b001) reads_out = reads_out + 1;
        if (mem_rd_valid) reads_out = reads_out - 1;
    end
    always @(negedge clk) if (!reset) begin
        for (k = 2; k < 5; k = k + 1) if ($signed(new_one.credit[k*18 +: 18]) < 0) debt = debt + 1;
        if (!new_one.budget_left) windows = windows + 1;
        if (!new_one.budget_left && g0[4:2] != 0) took_at_window = took_at_window + 1;
        if (g0 != 0) grants = grants + 1;
        if ({g0, v0, d0, c0, k0, a0, e0, n0, w0, m0, new_one.credit, new_one.has_credit} !==
            {g1, v1, d1, c1, k1, a1, e1, n1, w1, m1, old_one.credit, old_one.has_credit}) begin
            bad = bad + 1; if (bad < 5) $display("tick %0d: differ", t);
        end
    end
endmodule

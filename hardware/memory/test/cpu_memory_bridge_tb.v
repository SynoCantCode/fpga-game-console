// cpu_memory_bridge_tb.v
// fake cpu bus -> bridge -> arbiter -> fake memory, with a hungry fake gpu competing
// a byte array model says what every read should return
// tests every size at every position, cache line bursts, and lots of random reads and writes
`timescale 1ns / 1ps

module cpu_memory_bridge_tb;

    localparam MEMORY_BYTES = 16384;            // area the test uses

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // the fake cpus bus wires
    reg [31:0] haddr = 0;  reg [1:0] htrans = 0;  reg hwrite = 0;  reg [2:0] hsize = 0;  reg [63:0] hwdata = 0;
    wire [63:0] hrdata;  wire hready, hresp;

    // bridge, arbiter, fake memory
    wire [4:0] req, grant, rd_valid;
    wire [2:0] bridge_cmd;  wire [28:0] bridge_addr;  wire [255:0] bridge_data, rd_data;  wire [31:0] bridge_mask;
    reg gpu_req = 0;  reg [28:0] gpu_addr = {1'b0, 25'd1000, 3'b000};
    assign req[0] = 0;  assign req[1] = 0;  assign req[2] = gpu_req;  assign req[4] = 0;

    wire door_req, door_grant;  wire [2:0] door_cmd;  wire [28:0] door_addr;  wire [255:0] door_data;  wire [31:0] door_mask;

    cpu_memory_bridge bridge (
        .clk(clk), .reset(reset),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata),
        .hrdata(hrdata), .hready(hready), .hresp(hresp),
        .req(door_req), .cmd(door_cmd), .addr(door_addr), .wr_data(door_data), .wr_mask(door_mask),
        .grant(door_grant), .rd_valid(rd_valid[3]), .rd_data(rd_data));

    // 2 request buffers between the bridge and the arbiter like in console_top.v
    wire mid_valid, mid_room;  wire [3 + 29 + 256 + 32 - 1:0] mid_data;
    request_buffer #(.WIDTH(3 + 29 + 256 + 32)) cpu_to_arbiter (
        .clk(clk), .reset(reset),
        .in_valid(door_req), .in_data({door_cmd, door_addr, door_data, door_mask}), .in_ready(door_grant),
        .out_valid(mid_valid), .out_data(mid_data), .out_ready(mid_room));
    request_buffer #(.WIDTH(3 + 29 + 256 + 32)) cpu_at_arbiter (
        .clk(clk), .reset(reset),
        .in_valid(mid_valid), .in_data(mid_data), .in_ready(mid_room),
        .out_valid(req[3]), .out_data({bridge_cmd, bridge_addr, bridge_data, bridge_mask}), .out_ready(grant[3]));

    wire calibrated, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, mem_rd_valid;
    wire [2:0] cmd;  wire [28:0] addr;  wire [255:0] wr_data, mem_rd_data;  wire [31:0] wr_data_mask;

    memory_arbiter #(.PORTS(5)) arbiter (
        .clk(clk), .reset(reset), .req(req),
        .port_cmd({3'b001, bridge_cmd, 3'b000, 3'b001, 3'b001}),
        .port_addr({29'd0, bridge_addr, gpu_addr, 29'd0, 29'd0}),
        .port_wr_data({256'd0, bridge_data, {8{32'hDEADBEEF}}, 256'd0, 256'd0}),
        .port_wr_mask({32'd0, bridge_mask, 32'd0, 32'd0, 32'd0}),
        .grant(grant), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr), .wr_data_rdy(wr_data_rdy),
        .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data), .wr_data_mask(wr_data_mask),
        .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data));

    fake_memory_controller #(.BLOCKS(2048)) memory (
        .clk(clk), .calibrated(calibrated), .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data),
        .wr_data_mask(wr_data_mask), .rd_data_valid(mem_rd_valid), .rd_data(mem_rd_data));

    // hungry gpu, writes nonstop to blocks outside the cpus area
    always @(posedge clk) begin
        #1;
        if (!reset && calibrated) begin
            if (grant[2]) gpu_addr = {1'b0, 25'd1000 + ((gpu_addr[27:3] - 25'd1000 + 25'd1) % 25'd1000), 3'b000};
            gpu_req = 1;
        end
    end

    // model of memory, what every byte should be
    reg [7:0] model [0:MEMORY_BYTES-1];
    integer i;
    initial for (i = 0; i < MEMORY_BYTES; i = i + 1) model[i] = 8'h00;

    // count the bridges memory reads to check a burst costs one trip
    integer bridge_reads = 0;
    always @(posedge clk) if (grant[3] && bridge_cmd == 3'b001) bridge_reads = bridge_reads + 1;

    integer failures = 0, wrong_reads = 0, reads_checked = 0;

    // fake cpu, a pipelined burst of n transfers (n = 1 for a single one)
    // the next address goes up while the previous transfers data phase finishes
    reg [31:0] beat_addr [0:3];
    reg [63:0] beat_data [0:3];
    reg [63:0] got [0:3];

    task ahb_burst(input integer n, input is_write, input [2:0] size);
        integer k;
        begin
            for (k = 0; k <= n; k = k + 1) begin
                @(negedge clk);
                if (k < n) begin
                    haddr = beat_addr[k];  hwrite = is_write;  hsize = size;
                    htrans = (k == 0) ? 2'b10 : 2'b11;     // nonseq first then seq
                end else begin
                    htrans = 2'b00;                        // idle
                end
                if (k > 0 && is_write) hwdata = beat_data[k-1];
                @(posedge clk);
                while (!hready) @(posedge clk);
                if (k > 0 && !is_write) got[k-1] = hrdata;
            end
        end
    endtask

    // the bytes a transfer touches in the model
    task model_write(input [31:0] a, input [2:0] size, input [63:0] data);
        integer b;
        for (b = 0; b < (1 << size); b = b + 1) model[a + b] = data[(a[2:0] + b) * 8 +: 8];
    endtask

    task check_read(input [31:0] a, input [2:0] size, input [63:0] data);
        integer b;
        begin
            reads_checked = reads_checked + 1;
            for (b = 0; b < (1 << size); b = b + 1)
                if (data[(a[2:0] + b) * 8 +: 8] !== model[a + b]) begin
                    if (wrong_reads < 5) $display("        wrong: address %h byte %0d: got %h, expected %h",
                                                  a, b, data[(a[2:0] + b) * 8 +: 8], model[a + b]);
                    wrong_reads = wrong_reads + 1;
                end
        end
    endtask

    task single_write(input [31:0] a, input [2:0] size, input [63:0] data);
        begin
            beat_addr[0] = a; beat_data[0] = data;
            ahb_burst(1, 1, size);
            model_write(a, size, data);
        end
    endtask

    task single_read(input [31:0] a, input [2:0] size);
        begin
            beat_addr[0] = a;
            ahb_burst(1, 0, size);
            check_read(a, size, got[0]);
        end
    endtask

    // a wrapping cache line burst starting at piece "first" of the block
    task line_burst(input is_write, input [31:0] base, input integer first);
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1) begin
                beat_addr[k] = base + ((first + k) % 4) * 8;
                beat_data[k] = {$urandom, $urandom};
            end
            ahb_burst(4, is_write, 3'd3);
            for (k = 0; k < 4; k = k + 1)
                if (is_write) model_write(beat_addr[k], 3'd3, beat_data[k]);
                else          check_read(beat_addr[k], 3'd3, got[k]);
        end
    endtask

    task check(input string what, input integer got_value, input integer low, input integer high);
        if (got_value >= low && got_value <= high) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d .. %0d", what, got_value, low, high); failures = failures + 1; end
    endtask

    // the test
    integer s, offset, trips_before, n, wrong_before;
    reg [31:0] a;

    initial begin
        $display("cpu_memory_bridge test: a pretend CPU (AHB) through the bridge, the arbiter and the fake memory");
        repeat (5) @(posedge clk);
        reset = 0;
        wait (calibrated);

        // test 1 every size at every position
        for (s = 0; s <= 3; s = s + 1)
            for (offset = 0; offset < 32; offset = offset + (1 << s))
                single_write(32'h100 + offset + s * 64, s, {$urandom, $urandom});
        for (s = 0; s <= 3; s = s + 1)
            for (offset = 0; offset < 32; offset = offset + (1 << s))
                single_read(32'h100 + offset + s * 64, s);
        $display("Single transfers of 1, 2, 4 and 8 bytes at every position:");
        check("reads that came back wrong", wrong_reads, 0, 0);

        // test 2 cache lines, write bursts then wrapping read bursts from every piece
        for (n = 0; n < 4; n = n + 1) line_burst(1, 32'h800 + n * 32, n);
        wrong_before = wrong_reads;
        trips_before = bridge_reads;
        for (n = 0; n < 4; n = n + 1) line_burst(0, 32'h800 + n * 32, (n + 1) % 4);
        $display("Cache lines (bursts of 4 x 8 bytes, wrapping around the 32-byte block):");
        check("wrong reads", wrong_reads - wrong_before, 0, 0);
        check("memory trips for 4 read bursts (one each)", bridge_reads - trips_before, 4, 4);

        // test 3 random everything
        wrong_before = wrong_reads;
        for (n = 0; n < 3000; n = n + 1) begin
            s = $urandom % 4;
            a = ($urandom % (MEMORY_BYTES - 64)) & ~((1 << s) - 1);       // aligned to its size
            case ($urandom % 4)
                0: single_write(a, s, {$urandom, $urandom});
                1: single_read(a, s);
                2: line_burst(1, a & ~32'h1F, $urandom % 4);
                3: line_burst(0, a & ~32'h1F, $urandom % 4);
            endcase
        end
        $display("3,000 random reads and writes (all sizes, single and cache-line bursts):");
        check("wrong reads", wrong_reads - wrong_before, 0, 0);
        check("reads checked in total", reads_checked, 1000, 1000000);

        $display("While a hungry GPU competed for memory:");
        check("GPU writes that went through", memory.writes_taken > 1000, 1, 1);
        check("handshake mistakes seen by the memory controller", memory.protocol_mistakes, 0, 0);
        check("error responses to the CPU", hresp, 0, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

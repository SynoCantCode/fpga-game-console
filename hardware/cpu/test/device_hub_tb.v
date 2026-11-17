// device_hub_tb.v
// fake cpu bus talks to 2 fake devices on an unrelated clock
// random writes and reads, a read from an empty slot, back to back transfers

`timescale 1ns/1ps
module device_hub_tb;
    reg bus_clk = 0, dev_clk = 0;
    always #10 bus_clk = !bus_clk;              // 50 MHz
    always #4.85 dev_clk = !dev_clk;            // about 103 MHz, unrelated to the bus clock on purpose
    reg bus_reset = 1, dev_reset = 1;

    // cpu side
    reg hsel = 0, hwrite = 0;
    reg [31:0] haddr = 0, hwdata = 0;
    reg [1:0] htrans = 0;
    wire [31:0] hrdata;
    wire hready, hresp;

    // device side
    wire dev_write, dev_read;
    wire [3:0] dev_select;
    wire [15:0] dev_offset;
    wire [31:0] dev_wdata;
    reg [16*32-1:0] dev_rdata = 0;

    device_hub hub (
        .bus_clk(bus_clk), .bus_reset(bus_reset), .hsel(hsel), .haddr(haddr), .htrans(htrans), .hwrite(hwrite),
        .hwdata(hwdata), .hrdata(hrdata), .hready(hready), .hresp(hresp),
        .dev_clk(dev_clk), .dev_reset(dev_reset), .dev_write(dev_write), .dev_read(dev_read),
        .dev_select(dev_select), .dev_offset(dev_offset), .dev_wdata(dev_wdata), .dev_rdata(dev_rdata)
    );

    // 2 fake devices with 16 registers each, they answer the clock after a read
    reg [31:0] regs1 [0:15];
    reg [31:0] regs3 [0:15];
    integer writes_seen = 0;
    integer i;
    initial for (i = 0; i < 16; i = i + 1) begin regs1[i] = 0; regs3[i] = 0; end
    always @(posedge dev_clk) begin
        if (dev_write) begin
            writes_seen = writes_seen + 1;
            if (dev_select == 1) regs1[dev_offset[5:2]] <= dev_wdata;
            if (dev_select == 3) regs3[dev_offset[5:2]] <= dev_wdata;
        end
        if (dev_read) begin
            dev_rdata[1 * 32 +: 32] <= (dev_select == 1) ? regs1[dev_offset[5:2]] : 32'd0;
            dev_rdata[3 * 32 +: 32] <= (dev_select == 3) ? regs3[dev_offset[5:2]] : 32'd0;
        end
    end

    // what the test thinks is in the registers
    reg [31:0] model1 [0:15];
    reg [31:0] model3 [0:15];
    initial for (i = 0; i < 16; i = i + 1) begin model1[i] = 0; model3[i] = 0; end

    integer failures = 0, wrong_reads = 0, reads = 0, writes = 0, empty_wrong = 0, timeouts = 0;
    task check(input [8*60-1:0] what, input integer got_value, input integer expected);
        begin
            if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
            else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
        end
    endtask

    // the fake cpu
    // wait for a bus clock edge where hready is 1
    task wait_ready;
        integer n;
        begin
            n = 0;
            @(posedge bus_clk);
            while (!hready) begin
                @(posedge bus_clk); n = n + 1;
                if (n > 200) begin timeouts = timeouts + 1; disable wait_ready; end
            end
        end
    endtask

    // one transfer, address phase then data phase
    reg [31:0] got;
    task transfer(input write, input [31:0] addr, input [31:0] data);
        begin
            #1;
            hsel = 1; htrans = 2'b10; haddr = addr; hwrite = write;
            wait_ready;                             // address phase taken
            #1;
            hwdata = data;
            htrans = 2'b00; hsel = 0;               // nothing else offered
            wait_ready;                             // data phase done
            got = hrdata;
        end
    endtask

    // 2 transfers back to back, the second address goes out during the first data phase
    reg [31:0] got_first;
    task two_transfers(input w1, input [31:0] a1, input [31:0] d1, input w2, input [31:0] a2, input [31:0] d2);
        begin
            #1;
            hsel = 1; htrans = 2'b10; haddr = a1; hwrite = w1;
            wait_ready;                             // first address taken
            #1;
            hwdata = d1;
            hsel = 1; htrans = 2'b10; haddr = a2; hwrite = w2;    // second address offered now
            wait_ready;                             // first data done and second address taken
            got_first = hrdata;
            #1;
            hwdata = d2;
            htrans = 2'b00; hsel = 0;
            wait_ready;                             // second data done
            got = hrdata;
        end
    endtask

    integer n, slot, r;
    reg [31:0] value, want;
    initial begin
        $display("device_hub test: a 50 MHz CPU bus -> one clock crossing -> devices on an unrelated ~103 MHz clock");
        #95 bus_reset = 0; dev_reset = 0;
        repeat (3) @(posedge bus_clk);

        // test 1 random writes and reads one at a time
        for (n = 0; n < 400; n = n + 1) begin
            slot = ($urandom % 2) ? 3 : 1;
            r = $urandom % 16;
            if ($urandom % 2) begin
                value = $urandom;
                transfer(1, 32'hE800_0000 | (slot << 16) | (r << 2), value);
                if (slot == 1) model1[r] = value; else model3[r] = value;
                writes = writes + 1;
            end else begin
                transfer(0, 32'hE800_0000 | (slot << 16) | (r << 2), 0);
                want = (slot == 1) ? model1[r] : model3[r];
                if (got !== want) begin
                    if (wrong_reads < 5) $display("        read slot %0d reg %0d: got %h, expected %h", slot, r, got, want);
                    wrong_reads = wrong_reads + 1;
                end
                reads = reads + 1;
            end
        end
        $display("400 single transfers (writes and reads, devices 1 and 3):");
        check("reads that came back wrong", wrong_reads, 0);

        // test 2 a slot with no device
        for (n = 0; n < 10; n = n + 1) begin
            transfer(0, 32'hE807_0000 | (n << 2), 0);
            if (got !== 32'd0) empty_wrong = empty_wrong + 1;
            reads = reads + 1;
        end
        $display("Reading a slot with no device:");
        check("answers that weren't 0", empty_wrong, 0);

        // test 3 write then read the same register back to back
        wrong_reads = 0;
        for (n = 0; n < 100; n = n + 1) begin
            r = $urandom % 16;
            value = $urandom;
            two_transfers(1, 32'hE803_0000 | (r << 2), value, 0, 32'hE803_0000 | (r << 2), 0);
            model3[r] = value;
            writes = writes + 1;  reads = reads + 1;
            if (got !== value) wrong_reads = wrong_reads + 1;
        end
        $display("A write and a read of the same register back to back (the read's address offered during the write):");
        check("reads that didn't see the write just before", wrong_reads, 0);

        repeat (10) @(posedge bus_clk);
        $display("Overall:");
        check("writes that reached a device (each exactly once)", writes_seen, writes);
        check("transfers that never finished", timeouts, 0);
        check("error responses", hresp, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end
endmodule

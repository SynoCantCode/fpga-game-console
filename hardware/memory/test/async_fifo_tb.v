// async_fifo_tb.v
// fifo test with 2 unrelated clocks, numbers go in counting up and must come out in the same order
// 3 phases both random, fast writer slow reader (must fill), slow writer fast reader (must run dry)
`timescale 1ns / 1ps

module async_fifo_tb;

    localparam WIDTH = 256, ADDR_BITS = 8, DEPTH = 256;

    reg write_clk = 0, read_clk = 0;
    always #5     write_clk = ~write_clk;   // 100 MHz
    always #6.741 read_clk  = ~read_clk;    // 74.17 MHz

    reg write_reset = 1, read_reset = 1;
    reg write_en = 0, read_en = 0;
    reg [WIDTH-1:0] write_data = 0;
    wire [WIDTH-1:0] read_data;
    wire full, empty;
    wire [ADDR_BITS:0] write_count;

    async_fifo #(.WIDTH(WIDTH), .ADDR_BITS(ADDR_BITS)) fifo (
        .write_clk(write_clk), .write_reset(write_reset), .write_en(write_en), .write_data(write_data),
        .full(full), .write_count(write_count),
        .read_clk(read_clk), .read_reset(read_reset), .read_en(read_en), .read_data(read_data), .empty(empty)
    );

    function [WIDTH-1:0] value_for(input integer n);
        value_for = {8{n[31:0]}};             // the number n repeated across all 256 bits
    endfunction

    // how eager each side is, percent chance of acting on a tick
    integer write_eagerness = 50, read_eagerness = 50;
    reg running = 0;

    // the writer
    integer written = 0, times_full = 0, max_count = 0;
    always @(posedge write_clk) begin
        if (write_en && !full) written = written + 1;            // the edge just took an entry
        if (full) times_full = times_full + 1;
        if (write_count > max_count) max_count = write_count;
    end
    always @(negedge write_clk) begin
        write_en = running && (($urandom % 100) < write_eagerness);
        write_data = value_for(written);
    end

    // the reader, checks every entry it takes
    integer taken = 0, wrong = 0, times_empty = 0;
    always @(posedge read_clk) begin
        if (read_en && !empty) begin
            if (read_data !== value_for(taken)) begin
                if (wrong < 5) $display("        entry %0d came out wrong", taken);
                wrong = wrong + 1;
            end
            taken = taken + 1;
        end
        if (empty) times_empty = times_empty + 1;
    end
    always @(negedge read_clk) read_en = running && (($urandom % 100) < read_eagerness);

    // check helper
    integer failures = 0;

    task check(input string what, input integer got, input integer low, input integer high);
        if (got >= low && got <= high) begin
            $display("  ok    %0s: %0d", what, got);
        end else begin
            $display("  FAIL  %0s: got %0d, expected %0d .. %0d", what, got, low, high);
            failures = failures + 1;
        end
    endtask

    // the test
    integer full_before, empty_before;

    initial begin
        $display("async_fifo test: writing at 100 MHz, reading at 74.17 MHz");
        repeat (5) @(posedge write_clk);
        write_reset = 0;
        read_reset = 0;
        repeat (5) @(posedge read_clk);
        running = 1;

        // phase 1 both at random
        write_eagerness = 50; read_eagerness = 60;
        #200_000;

        // phase 2 fast writer slow reader, it must fill up
        full_before = times_full;
        write_eagerness = 90; read_eagerness = 10;
        #200_000;
        $display("Fast writer, slow reader:");
        check("ticks the FIFO said full", (times_full - full_before) > 0, 1, 1);
        check("most entries ever in (the FIFO holds 256)", max_count, 250, 256);

        // phase 3 slow writer fast reader, it must run dry
        empty_before = times_empty;
        write_eagerness = 5; read_eagerness = 95;
        #200_000;
        $display("Slow writer, fast reader:");
        check("ticks the FIFO said empty", (times_empty - empty_before) > 0, 1, 1);

        // stop writing and let the reader empty it
        write_eagerness = 0; read_eagerness = 100;
        #50_000;
        running = 0;
        #1_000;

        $display("Every entry:");
        check("entries written", written, 1000, 1000000);
        check("entries taken (all of them)", taken, written, written);
        check("entries that came out wrong or out of order", wrong, 0, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

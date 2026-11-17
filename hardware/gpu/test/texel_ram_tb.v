// texel_ram_tb.v
// test for texel_ram, the texture caches memory, 16 bit texels with two ports
// a plain array model says what every read should return
// also runs on the synthesized netlist when NETLIST is defined
`timescale 1ns / 1ps

module texel_ram_tb;
    parameter BITS = 11;
    localparam SIZE = 1 << BITS;

    reg clk = 0;
    always #5 clk = ~clk;

    reg a_use = 0, a_write = 0, b_use = 0, b_write = 0;
    reg [BITS-1:0] a_address = 0, b_address = 0;
    reg [15:0] a_texel_in = 0, b_texel_in = 0;
    wire [15:0] a_texel, b_texel;

`ifdef NETLIST
    texel_ram ram (
`else
    texel_ram #(.ADDRESS_BITS(BITS)) ram (
`endif
        .clk(clk),
        .a_use(a_use), .a_write(a_write), .a_address(a_address), .a_texel_in(a_texel_in), .a_texel(a_texel),
        .b_use(b_use), .b_write(b_write), .b_address(b_address), .b_texel_in(b_texel_in), .b_texel(b_texel));

    reg [15:0] model [0:SIZE-1];
    reg [15:0] a_expected = 0, b_expected = 0;      // what each port should show once it has read
    reg a_has_read = 0, b_has_read = 0;

    integer failures = 0, wrong = 0, reads = 0, writes = 0, both_busy = 0, seed = 2026;

    task check(input [8*56-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    // one clock, the model takes the same step then both ports are compared with it
    task tick;
        begin
            if (a_use && !a_write) begin a_expected = model[a_address]; a_has_read = 1; reads = reads + 1; end
            if (b_use && !b_write) begin b_expected = model[b_address]; b_has_read = 1; reads = reads + 1; end
            if (a_use && a_write) begin model[a_address] = a_texel_in; writes = writes + 1; end
            if (b_use && b_write) begin model[b_address] = b_texel_in; writes = writes + 1; end
            if (a_use && b_use) both_busy = both_busy + 1;
            @(posedge clk); #1;
            if (a_has_read && a_texel !== a_expected) begin
                if (wrong < 5) $display("        wrong at place A: got %h, expected %h", a_texel, a_expected);
                wrong = wrong + 1;
            end
            if (b_has_read && b_texel !== b_expected) begin
                if (wrong < 5) $display("        wrong at place B: got %h, expected %h", b_texel, b_expected);
                wrong = wrong + 1;
            end
        end
    endtask

    task idle; begin a_use = 0; b_use = 0; a_write = 0; b_write = 0; end endtask

    integer i, r;

    initial begin
        $display("texel_ram test: %0d texels of 16 bits, two places", SIZE);
        @(negedge clk);

        // test 1 fill through A and read back through B, then the other way
        idle;
        for (i = 0; i < SIZE; i = i + 1) begin
            a_use = 1; a_write = 1; a_address = i; a_texel_in = (i * 16'h9E37) ^ 16'h5A5A; tick;
        end
        idle;
        for (i = 0; i < SIZE; i = i + 1) begin b_use = 1; b_write = 0; b_address = i; tick; end
        idle;
        for (i = 0; i < SIZE; i = i + 1) begin
            b_use = 1; b_write = 1; b_address = i; b_texel_in = (i * 16'h6C8F) ^ 16'hC3C3; tick;
        end
        idle;
        for (i = 0; i < SIZE; i = i + 1) begin a_use = 1; a_write = 0; a_address = i; tick; end
        idle; tick;
        $display("Fill through one place, read back through the other (both ways):");
        check("wrong texels", wrong, 0);

        // test 2 both ports reading in one tick
        wrong = 0;
        for (i = 0; i < 256; i = i + 1) begin
            a_use = 1; a_write = 0; a_address = i * 7 + 3; b_use = 1; b_write = 0; b_address = SIZE - 1 - i * 5; tick;
            a_address = i * 3; b_address = i * 3; tick;                       // same texel from both
        end
        idle; tick;
        $display("Both places reading in one tick (different addresses, and the same one):");
        check("wrong texels", wrong, 0);

        // test 3 both ports writing in one tick then read back
        wrong = 0;
        for (i = 0; i < 256; i = i + 1) begin
            a_use = 1; a_write = 1; a_address = 2 * i; a_texel_in = 16'hA000 + i;
            b_use = 1; b_write = 1; b_address = 2 * i + 1; b_texel_in = 16'hB000 + i; tick;
        end
        idle;
        for (i = 0; i < 256; i = i + 1) begin
            a_use = 1; a_write = 0; a_address = 2 * i + 1; b_use = 1; b_write = 0; b_address = 2 * i; tick;
        end
        idle; tick;
        $display("Both places writing in one tick, read back:");
        check("wrong texels", wrong, 0);

        // test 4 one writes while the other reads another address
        wrong = 0;
        for (i = 0; i < 256; i = i + 1) begin
            a_use = 1; a_write = 1; a_address = 600 + i; a_texel_in = 16'h1234 ^ i;
            b_use = 1; b_write = 0; b_address = 599 + i; tick;                // reads what A wrote one tick before
        end
        idle; tick;
        $display("One place writing while the other reads (the texel written a tick earlier):");
        check("wrong texels", wrong, 0);

        // test 5 a ports texel stays until its next read
        wrong = 0;
        a_use = 1; a_write = 0; a_address = 40; b_use = 1; b_write = 0; b_address = 41; tick;
        idle; for (i = 0; i < 5; i = i + 1) tick;                             // idle ticks
        a_use = 1; a_write = 1; a_address = 40; a_texel_in = 16'hFFFF; tick;  // As own write, even to the address its showing
        b_use = 1; b_write = 1; b_address = 300; b_texel_in = 16'h0F0F; a_use = 0; tick;
        idle; tick;
        $display("A place's texel stays until its next read (idle ticks, writes):");
        check("wrong texels", wrong, 0);

        // test 6 random ticks, half of them in a small corner so the ports keep meeting
        wrong = 0; reads = 0; writes = 0; both_busy = 0;
        for (i = 0; i < 40000; i = i + 1) begin
            r = $random(seed);
            a_use = (r[1:0] != 0); a_write = r[2]; b_use = (r[4:3] != 0); b_write = r[5];
            a_address = r[6] ? r[10:7] : r[21:11]; b_address = r[22] ? r[26:23] : ($random(seed) & (SIZE - 1));
            a_texel_in = $random(seed); b_texel_in = $random(seed);
            // both on one address is only allowed if both read
            if (a_use && b_use && a_address == b_address && (a_write || b_write)) b_address = b_address ^ 1'b1;
            tick;
        end
        idle; tick;
        $display("40,000 random ticks (%0d reads, %0d writes, both places busy in %0d ticks):", reads, writes, both_busy);
        check("wrong texels", wrong, 0);
        if (reads < 20000 || writes < 20000 || both_busy < 15000) begin
            $display("  FAIL  the random part did too little"); failures = failures + 1;
        end

        if (failures == 0) $display("PASSED: every check is right");
        else $display("FAILED: %0d checks wrong", failures);
        $finish;
    end
endmodule

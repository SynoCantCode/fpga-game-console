// texture_slots_tb.v
// test for texture_slots, 256 texture descriptions of 42 bits with one write port and one read port
// a plain array model says what every read should return
// also runs on the synthesized netlist
`timescale 1ns / 1ps

module texture_slots_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg write = 0;
    reg [7:0] write_slot = 0, read_slot = 0;
    reg [41:0] write_description = 0;
    wire [41:0] description;

    texture_slots table_ (
        .clk(clk),
        .write(write), .write_slot(write_slot), .write_description(write_description),
        .read_slot(read_slot), .description(description));

    reg [41:0] model [0:255];
    reg [41:0] expected = 0;
    reg written [0:255];                  // reads of a slot never written arent compared
    reg known = 0;
    integer failures = 0, wrong = 0, writes = 0, seed = 77;

    task check(input [8*56-1:0] what, input integer got_value, input integer expected_value);
        if (got_value == expected_value) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected_value); failures = failures + 1; end
    endtask

    // one clock, the model takes the same step then the read is compared
    task tick;
        begin
            expected = model[read_slot]; known = written[read_slot];
            if (write) begin model[write_slot] = write_description; written[write_slot] = 1; writes = writes + 1; end
            @(posedge clk); #1;
            if (known && description !== expected) begin
                if (wrong < 5) $display("        wrong: slot %0d: got %h, expected %h", read_slot, description, expected);
                wrong = wrong + 1;
            end
        end
    endtask

    integer i, r;
    reg [41:0] earlier;

    initial begin
        $display("texture_slots test: 256 descriptions of 42 bits");
        @(negedge clk);

        // test 1 fill every slot with a pattern then its opposite, read all back
        for (i = 0; i < 256; i = i + 1) written[i] = 0;
        for (i = 0; i < 256; i = i + 1) begin
            write = 1; write_slot = i; write_description = {i[7:0], ~i[7:0], i[7:0] ^ 8'h5A, 10'h2AA, i[7:0]}; read_slot = i + 1; tick;
        end
        write = 0;
        for (i = 0; i < 256; i = i + 1) begin read_slot = i; tick; end
        for (i = 0; i < 256; i = i + 1) begin
            write = 1; write_slot = i; write_description = ~{i[7:0], ~i[7:0], i[7:0] ^ 8'h5A, 10'h2AA, i[7:0]}; read_slot = i + 1; tick;
        end
        write = 0;
        for (i = 0; i < 256; i = i + 1) begin read_slot = i; tick; end
        $display("Fill all 256 slots (twice, opposite bits), read them all back:");
        check("wrong descriptions", wrong, 0);

        // test 2 a read takes one clock
        wrong = 0;
        read_slot = 10; tick; earlier = description;
        read_slot = 200; tick;
        $display("A read takes one clock:");
        check("the new slot shows after one tick", (description === model[200]) && (earlier === model[10]), 1);

        // test 3 write low, nothing changes
        write = 0; write_slot = 200; write_description = 42'h155_5555_5555; read_slot = 3; tick;
        read_slot = 200; tick;
        $display("Write low:");
        check("wrong descriptions", wrong, 0);

        // test 4 write one slot while reading another
        wrong = 0;
        for (i = 0; i < 255; i = i + 1) begin
            write = 1; write_slot = i; write_description = {10'h155, i[7:0], 16'hBEEF, ~i[7:0]}; read_slot = i + 1; tick;
        end
        write = 0;
        for (i = 0; i < 256; i = i + 1) begin read_slot = i; tick; end
        $display("Writing one slot while reading another:");
        check("wrong descriptions", wrong, 0);

        // test 5 random clocks, a quarter of them in 4 slots so reads and writes nearly meet
        wrong = 0; writes = 0;
        for (i = 0; i < 20000; i = i + 1) begin
            r = $random(seed);
            write = r[0]; write_slot = r[2:1] == 0 ? r[4:3] : r[12:5]; read_slot = r[14:13] == 0 ? r[16:15] : r[24:17];
            write_description = {$random(seed), $random(seed)};
            if (write && read_slot == write_slot) read_slot = read_slot + 1'b1;       // never read and write the same slot in one tick
            tick;
        end
        write = 0; tick;
        $display("20,000 random clocks (%0d writes):", writes);
        check("wrong descriptions", wrong, 0);
        if (writes < 8000) begin $display("  FAIL  too few writes"); failures = failures + 1; end

        if (failures == 0) $display("PASSED: every check is right");
        else $display("FAILED: %0d checks wrong", failures);
        $finish;
    end
endmodule

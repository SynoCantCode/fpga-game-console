// tile_bank_tb.v
// test for tile_bank, one bank of the tile memory, 512 pixels of 32 bits
// a plain array model says what every read should return
`timescale 1ns / 1ps

module tile_bank_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg write_enable = 0;
    reg [8:0] write_address = 0, read_address = 0;
    reg [31:0] write_data = 0;
    wire [31:0] read_data;

    tile_bank bank (
        .clk(clk),
        .write_enable(write_enable), .write_address(write_address), .write_data(write_data),
        .read_address(read_address), .read_data(read_data));

    reg [31:0] model [0:1023];

    integer failures = 0, wrong = 0;

    task check(input [8*48-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    // one clock, set inputs after the falling edge and look just after the rising edge
    task tick;
        begin @(posedge clk); #1; end
    endtask

    task compare_read(input [31:0] expected);
        if (read_data !== expected) begin
            if (wrong < 5) $display("        wrong: got %h, expected %h", read_data, expected);
            wrong = wrong + 1;
        end
    endtask

    integer i, n, held;
    reg [31:0] old_value, new_value, expected_next;
    reg [9:0] a;

    initial begin
        $display("tile_bank test: one bank of the tile memory (512 x 32 bits)");
        @(negedge clk);

        // test 1 fill every address with its own pattern then read them all back
        for (i = 0; i < 512; i = i + 1) begin
            write_enable = 1; write_address = i; write_data = {i[9:0], 6'b101010, ~i[9:0], 6'b010101};
            model[i] = write_data;
            tick;
        end
        write_enable = 0;
        for (i = 0; i < 512; i = i + 1) begin
            read_address = i;
            tick;
            compare_read(model[i]);
        end
        $display("Fill all 512 pixels, read them all back:");
        check("wrong pixels", wrong, 0);

        // test 2 a read takes one clock, the old pixel stays until the tick
        read_address = 10; tick;                      // now showing pixel 10
        read_address = 20; #2;                        // between ticks, still pixel 10
        held = (read_data === model[10]);
        tick;                                         // now pixel 20
        $display("A read takes one clock:");
        check("still the old pixel before the tick (1 = yes)", held, 1);
        check("the new pixel right after the tick (1 = yes)", read_data === model[20], 1);

        // test 3 write_enable low, nothing may change
        write_enable = 0; write_address = 5; write_data = 32'hFFFF_FFFF; tick;
        read_address = 5; tick;
        $display("write_enable low:");
        check("pixel 5 unchanged (1 = yes)", read_data === model[5], 1);

        // test 4 read one address while writing another in the same clock
        write_enable = 1; write_address = 100; write_data = 32'hCAFE_0100; read_address = 200;
        tick;
        model[100] = 32'hCAFE_0100;
        write_enable = 0;
        $display("Reading and writing in the same clock, different addresses:");
        check("the read was right (1 = yes)", read_data === model[200], 1);
        read_address = 100; tick;
        check("the write landed (1 = yes)", read_data === 32'hCAFE_0100, 1);

        // test 5 read and write the same address in the same clock, the read gets the old pixel
        old_value = model[300]; new_value = 32'h1234_5678;
        write_enable = 1; write_address = 300; write_data = new_value; read_address = 300;
        tick;
        model[300] = new_value;
        write_enable = 0;
        $display("Reading and writing the SAME address in the same clock:");
        check("the read got the OLD pixel (1 = yes)", read_data === old_value, 1);
        tick;
        check("one clock later, the new one (1 = yes)", read_data === new_value, 1);

        // test 6 random reads and writes every clock
        // expected read is taken before this clocks write lands
        wrong = 0;
        for (n = 0; n < 20000; n = n + 1) begin
            read_address = $urandom % 512;
            write_enable = $urandom % 2;
            write_address = $urandom % 512;
            write_data = $urandom;
            expected_next = model[read_address];
            tick;
            if (write_enable) model[write_address] = write_data;
            compare_read(expected_next);
        end
        $display("20,000 random clocks of reads and writes together:");
        check("wrong reads", wrong, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

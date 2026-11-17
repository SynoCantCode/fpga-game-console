// memory_report_tb.v
// memory report + uart sender, a fake pc reads the serial wire and collects the text
// run 1 has 0 errors and must say ok, run 2 has 42 errors and must say fail with the count
`timescale 1ns / 1ps

module memory_report_tb;

    localparam CLOCKS_PER_BIT = 4;
    localparam TICKS_BETWEEN = 200;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // run 1 passed
    wire send_1, busy_1, tx_1;  wire [7:0] byte_1;
    memory_report #(.TICKS_BETWEEN(TICKS_BETWEEN)) report_1 (
        .clk(clk), .reset(reset), .done(1'b1), .errors(32'd0),
        .uart_busy(busy_1), .uart_send(send_1), .uart_byte(byte_1)
    );
    uart_tx #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) uart_1 (
        .clk(clk), .rst(reset), .send(send_1), .byte_to_send(byte_1), .busy(busy_1), .tx(tx_1)
    );

    // run 2 42 bad blocks
    wire send_2, busy_2, tx_2;  wire [7:0] byte_2;
    memory_report #(.TICKS_BETWEEN(TICKS_BETWEEN)) report_2 (
        .clk(clk), .reset(reset), .done(1'b1), .errors(32'd42),
        .uart_busy(busy_2), .uart_send(send_2), .uart_byte(byte_2)
    );
    uart_tx #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) uart_2 (
        .clk(clk), .rst(reset), .send(send_2), .byte_to_send(byte_2), .busy(busy_2), .tx(tx_2)
    );

    // fake pc, one receiver per wire collecting text
    reg [8*64-1:0] text_1 = 0, text_2 = 0;   // what each wire said, newest character at the bottom
    integer length_1 = 0, length_2 = 0, framing_errors = 0;

    task automatic receive_into(input integer which);
        reg [7:0] got;
        integer b;
        begin
            forever begin
                // wait for the start bit
                if (which == 1) wait (tx_1 === 1'b0); else wait (tx_2 === 1'b0);
                repeat (CLOCKS_PER_BIT / 2) @(posedge clk);          // to the middle of the start bit
                for (b = 0; b < 8; b = b + 1) begin
                    repeat (CLOCKS_PER_BIT) @(posedge clk);
                    got[b] = (which == 1) ? tx_1 : tx_2;              // lowest bit first
                end
                repeat (CLOCKS_PER_BIT) @(posedge clk);
                if (((which == 1) ? tx_1 : tx_2) !== 1'b1) framing_errors = framing_errors + 1;   // stop bit must be 1
                if (which == 1) begin text_1 = {text_1[8*63-1:0], got}; length_1 = length_1 + 1; end
                else            begin text_2 = {text_2[8*63-1:0], got}; length_2 = length_2 + 1; end
            end
        end
    endtask

    initial receive_into(1);
    initial receive_into(2);

    // check helpers
    integer failures = 0;

    task check(input string what, input integer got, input integer expected);
        if (got == expected) begin
            $display("  ok    %0s: %0d", what, got);
        end else begin
            $display("  FAIL  %0s: got %0d, expected %0d", what, got, expected);
            failures = failures + 1;
        end
    endtask

    task check_text(input string what, input [8*64-1:0] got, input integer got_length,
                    input [8*64-1:0] expected, input integer expected_length);
        // both are right aligned so equal lengths + equal values = same text
        if (got_length == expected_length && got == expected) begin
            $display("  ok    %0s", what);
        end else begin
            $display("  FAIL  %0s: got %0d characters \"%0s\"", what, got_length, got);
            failures = failures + 1;
        end
    endtask

    // the test
    initial begin
        $display("memory_report test (with uart_tx): decoding the serial wire");
        repeat (5) @(posedge clk);
        reset = 0;

        // long enough for 2 ok messages
        repeat (2 * (TICKS_BETWEEN + 11 * 10 * CLOCKS_PER_BIT) + 50) @(posedge clk);

        $display("errors = 0:");
        check_text("wire said \"MEMORY OK\" CR LF, twice", text_1, length_1,
                   {"MEMORY OK", 8'd13, 8'd10, "MEMORY OK", 8'd13, 8'd10}, 22);
        $display("errors = 42:");
        check_text("wire said \"MEMORY FAIL 0000002A\" CR LF first", text_2 >> (8 * (length_2 - 22)), 22,
                   {"MEMORY FAIL 0000002A", 8'd13, 8'd10}, 22);
        check("stop bits that weren't 1", framing_errors, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

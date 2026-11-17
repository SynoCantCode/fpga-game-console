// uart_tx_tb.v
// sends H then i back to back and a fake pc reads the wire and decodes them
// checks the wire rests at 1, busy timing, the frame format, and that a send while busy is ignored

module uart_tx_tb;

    localparam CLOCKS_PER_BIT = 4;

    reg clk = 0, rst = 1;
    reg send = 0;
    reg [7:0] byte_to_send = 8'h00;
    wire busy, tx;

    uart_tx #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) dut (
        .clk(clk), .rst(rst), .send(send), .byte_to_send(byte_to_send), .busy(busy), .tx(tx)
    );

    always #5 clk = ~clk;

    integer fails = 0, checks = 0, i, busy_ticks;
    reg [7:0] received;
    reg [7:0] received_bytes [0:1];

    task automatic expect(input [31:0] got, input [31:0] want, input [8*40-1:0] what);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("FAIL  %0s: got 0x%h, expected 0x%h", what, got, want);
            end
        end
    endtask

    // automatic so the sender and the fake pc can call these at the same time

    // wait some ticks
    task automatic ticks(input integer count);
        integer k;
        begin
            for (k = 0; k < count; k = k + 1) begin
                @(posedge clk); #1;
            end
        end
    endtask

    // fake pc, wait for the start bit then read each bit in its middle
    task automatic receive_byte(output [7:0] got);
        integer b;
        begin
            while (tx == 1'b1) ticks(1);
            ticks(CLOCKS_PER_BIT / 2);
            expect(tx, 1'b0, "start bit is 0");
            for (b = 0; b < 8; b = b + 1) begin
                ticks(CLOCKS_PER_BIT);
                got[b] = tx;              // lowest bit first
            end
            ticks(CLOCKS_PER_BIT);
            expect(tx, 1'b1, "stop bit is 1");
        end
    endtask

    // send one byte then wait until the transmitter is free
    task automatic send_byte(input [7:0] value);
        begin
            byte_to_send = value;
            send = 1;
            ticks(1);
            send = 0;
            expect(busy, 1'b1, "busy right after send");
        end
    endtask

    initial begin
        ticks(2);
        expect(tx, 1'b1, "wire rests at 1 during reset");
        expect(busy, 1'b0, "not busy during reset");
        rst = 0;
        ticks(3);
        expect(tx, 1'b1, "wire rests at 1 after reset");
        expect(busy, 1'b0, "not busy after reset");

        fork
            // sender side
            begin
                send_byte(8'h48);   // H

                // count the ticks until busy turns off
                busy_ticks = 0;
                while (busy) begin
                    // halfway through try to send another byte, it must be ignored
                    if (busy_ticks == 12) begin
                        byte_to_send = 8'h58;   // X
                        send = 1;
                    end else begin
                        send = 0;
                    end
                    ticks(1);
                    busy_ticks = busy_ticks + 1;
                end
                send = 0;
                expect(busy_ticks, 10 * CLOCKS_PER_BIT, "one byte takes 10 bits of time");
                expect(tx, 1'b1, "wire back at 1 after the byte");

                send_byte(8'h69);   // i, back to back
            end
            // fake pc side
            begin
                receive_byte(received); received_bytes[0] = received;
                receive_byte(received); received_bytes[1] = received;
            end
        join

        expect(received_bytes[0], 8'h48, "first byte 'H'");
        expect(received_bytes[1], 8'h69, "second byte 'i'");

        // after the last byte the wire rests at 1, not busy, nothing else comes out
        ticks(CLOCKS_PER_BIT);
        expect(busy, 1'b0, "not busy at the end");
        for (i = 0; i < 50; i = i + 1) begin
            if (tx !== 1'b1) begin fails = fails + 1; $display("FAIL  wire moved after the last byte"); end
            ticks(1);
        end
        checks = checks + 1;

        if (fails == 0) $display("PASS: all %0d checks passed", checks);
        else            $display("FAILED: %0d of %0d checks", fails, checks);
        $finish;
    end

endmodule

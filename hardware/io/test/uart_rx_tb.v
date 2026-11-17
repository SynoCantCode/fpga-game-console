// uart_rx_tb.v
// loopback test, bytes sent by uart_tx must arrive correctly
// also checks byte_waiting, that a short blip is not a byte, and that a bad stop bit is thrown away

module uart_rx_tb;

    localparam CLOCKS_PER_BIT = 8;

    reg clk = 0, rst = 1;

    // the sender
    reg send = 0;
    reg [7:0] byte_to_send = 8'h00;
    wire busy, tx;
    uart_tx #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) sender (
        .clk(clk), .rst(rst), .send(send), .byte_to_send(byte_to_send), .busy(busy), .tx(tx)
    );

    // wire into the receiver, normally the senders tx or driven by hand for the bad byte checks
    reg is_driving_by_hand = 0;
    reg wire_by_hand = 1;
    wire rx = is_driving_by_hand ? wire_by_hand : tx;

    reg take_byte = 0;
    wire [7:0] received_byte;
    wire byte_waiting;
    uart_rx #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) receiver (
        .clk(clk), .rst(rst), .rx(rx), .take_byte(take_byte),
        .received_byte(received_byte), .byte_waiting(byte_waiting)
    );

    always #5 clk = ~clk;

    integer fails = 0, checks = 0, i;
    reg [7:0] test_bytes [0:4];

    task automatic expect(input [31:0] got, input [31:0] want, input [8*48-1:0] what);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                $display("FAIL  %0s: got 0x%h, expected 0x%h", what, got, want);
            end
        end
    endtask

    task automatic ticks(input integer count);
        integer k;
        begin
            for (k = 0; k < count; k = k + 1) begin
                @(posedge clk); #1;
            end
        end
    endtask

    // send one byte and wait until its fully out
    task automatic send_byte(input [7:0] value);
        begin
            byte_to_send = value; send = 1;
            ticks(1);
            send = 0;
            while (busy) ticks(1);
            ticks(4);
        end
    endtask

    // the cpu takes the waiting byte
    task automatic take;
        begin
            take_byte = 1; ticks(1); take_byte = 0;
        end
    endtask

    // drive one 10 bit frame by hand with the stop bit chosen
    task automatic send_by_hand(input [7:0] value, input stop_bit);
        integer b;
        begin
            is_driving_by_hand = 1;
            wire_by_hand = 0; ticks(CLOCKS_PER_BIT);                // start bit
            for (b = 0; b < 8; b = b + 1) begin
                wire_by_hand = value[b]; ticks(CLOCKS_PER_BIT);     // data, lowest first
            end
            wire_by_hand = stop_bit; ticks(CLOCKS_PER_BIT);         // stop bit
            wire_by_hand = 1; ticks(2 * CLOCKS_PER_BIT);            // rest
            is_driving_by_hand = 0;
        end
    endtask

    initial begin
        test_bytes[0] = "H"; test_bytes[1] = "i"; test_bytes[2] = 8'h00; test_bytes[3] = 8'hFF; test_bytes[4] = 8'hA5;

        ticks(2); rst = 0; ticks(2);
        expect(byte_waiting, 1'b0, "nothing waiting after reset");

        // loopback, every byte arrives, waits and is taken
        for (i = 0; i < 5; i = i + 1) begin
            send_byte(test_bytes[i]);
            expect(byte_waiting, 1'b1, "a byte is waiting");
            expect(received_byte, test_bytes[i], "the byte that arrived");
            take;
            expect(byte_waiting, 1'b0, "taken: no longer waiting");
        end

        // 2 bytes in a row without taking the first, the newest one is kept
        send_byte(8'h31);
        send_byte(8'h32);
        expect(byte_waiting, 1'b1, "still waiting");
        expect(received_byte, 8'h32, "the newer byte is kept");
        take;

        // a blip shorter than half a bit is not a byte
        is_driving_by_hand = 1;
        wire_by_hand = 0; ticks(2);
        wire_by_hand = 1; ticks(20 * CLOCKS_PER_BIT);
        is_driving_by_hand = 0;
        expect(byte_waiting, 1'b0, "a blip is not a byte");

        // a frame with stop bit 0 is thrown away
        send_by_hand(8'h77, 1'b0);
        ticks(12 * CLOCKS_PER_BIT);      // let the wire rest so the receiver is back to waiting
        expect(byte_waiting, 1'b0, "bad stop bit: thrown away");

        // a good frame by hand still works after
        send_by_hand(8'h5A, 1'b1);
        expect(byte_waiting, 1'b1, "good frame by hand arrives");
        expect(received_byte, 8'h5A, "the hand-sent byte");

        if (fails == 0) $display("PASS: all %0d checks passed", checks);
        else            $display("FAILED: %0d of %0d checks", fails, checks);
        $finish;
    end

endmodule

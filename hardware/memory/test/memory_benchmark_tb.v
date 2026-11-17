// memory_benchmark_tb.v
// runs the memory benchmark against the fake memory with known costs
// works out what each test should measure from the fakes own counters and compares
// also reads the serial line like a pc and checks the report has the same numbers
`timescale 1ns / 1ps

module memory_benchmark_tb;

    localparam LATENCY = 20;

    reg clk = 0;
    always #5 clk = ~clk;       // 100 MHz
    reg reset = 1;

    wire calibrated, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, rd_data_valid, done;
    wire [2:0] cmd;  wire [28:0] addr;  wire [255:0] wr_data, rd_data;  wire [31:0] wr_data_mask;
    wire [32*16-1:0] results;

    fake_memory_controller #(.BLOCKS(4096), .LATENCY(LATENCY), .WRAP(1)) memory (
        .clk(clk), .calibrated(calibrated), .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data),
        .wr_data_mask(wr_data_mask), .rd_data_valid(rd_data_valid), .rd_data(rd_data)
    );
    memory_benchmark bench (
        .clk(clk), .reset(reset), .calibrated(calibrated), .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd),
        .addr(addr), .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end),
        .wr_data(wr_data), .wr_data_mask(wr_data_mask), .rd_data_valid(rd_data_valid), .rd_data(rd_data),
        .done(done), .results(results)
    );

    // the report goes through the real uart sender
    wire uart_send, uart_busy, tx;  wire [7:0] uart_byte;
    bench_report #(.TICKS_BETWEEN(1000)) report (
        .clk(clk), .reset(reset), .done(done), .results(results),
        .uart_busy(uart_busy), .uart_send(uart_send), .uart_byte(uart_byte)
    );
    uart_tx #(.CLOCKS_PER_BIT(8)) serial (
        .clk(clk), .rst(reset), .send(uart_send), .byte_to_send(uart_byte), .busy(uart_busy), .tx(tx)
    );

    // the costs this run uses, same plusargs the fake reads
    integer row_cost = 0, turn_cost = 0, random_busy = 1;
    initial begin
        if (!$value$plusargs("FAKE_ROW_MISS=%d", row_cost)) row_cost = 0;
        if (!$value$plusargs("FAKE_TURNAROUND=%d", turn_cost)) turn_cost = 0;
        if (!$value$plusargs("FAKE_RANDOM_BUSY=%d", random_busy)) random_busy = 1;
    end

    // for every test, the fakes counters at its start and end give what the ticks must be
    integer failures = 0, checked = 0;
    integer miss0, turn0, reads0, writes0;
    integer misses, turns, n_reads, n_writes, expect_low, expect_high, got, t;
    reg was_running = 0;
    always @(posedge clk) begin
        if (bench.state == 1) begin                      // pause before a test, grab the start counts
            miss0 = memory.row_misses; turn0 = memory.turnarounds;
            reads0 = memory.reads_taken; writes0 = memory.writes_taken;
        end
        if (bench.state == 2 && bench.test_over) begin   // a test ends
            #1;
            t = bench.test;
            if (bench.state != 2) t = (bench.state == 3) ? 15 : bench.test - 1;
            got = results[t*32 +: 32];
            misses = memory.row_misses - miss0;  turns = memory.turnarounds - turn0;
            n_reads = memory.reads_taken - reads0;  n_writes = memory.writes_taken - writes0;
            if (random_busy == 0) begin
                // one command a tick plus every cost, reads also wait for the last answer
                expect_low = n_reads + n_writes + misses * row_cost + turns * turn_cost;
                expect_high = expect_low + (n_reads > 0 ? LATENCY + 4 : 2);
                // the last commands own cost comes after the test is over so it doesnt count
                expect_low = expect_low - row_cost - turn_cost;
                if (t == 12) begin
                    // one read at a time, every read waits for its answer
                    expect_low = n_reads * (LATENCY + 1) + misses * row_cost;
                    expect_high = n_reads * (LATENCY + 4) + misses * row_cost;
                end
                checked = checked + 1;
                if (got < expect_low || got > expect_high) begin
                    failures = failures + 1;
                    $display("  WRONG test %0d: measured %0d ticks, the fake charged %0d - %0d (%0d reads, %0d writes, %0d row changes, %0d switches)",
                             t, got, expect_low, expect_high, n_reads, n_writes, misses, turns);
                end else
                    $display("  ok    test %2d: %6d ticks (expected %0d - %0d; %0d reads, %0d writes, %0d row changes, %0d switches)",
                             t, got, expect_low, expect_high, n_reads, n_writes, misses, turns);
            end else
                $display("  test %2d: %0d ticks (random busy: not predicted)", t, got);
        end
        was_running <= (bench.state == 2);
    end

    // pc side, decode the serial line and collect result lines until END
    integer bit_i, line_len = 0, lines_ok = 0, lines_bad = 0, ends = 0;
    reg [7:0] rx_byte;
    reg [8*16-1:0] line_buf;
    reg [31:0] parsed;
    integer d, digit;
    task check_line;
        begin
            // line_buf holds the last characters, a result line is 11 characters
            if (line_len == 11 && line_buf[8*10 +: 8] == "B") begin
                parsed = 0;
                for (d = 0; d < 8; d = d + 1) begin
                    digit = line_buf[8*(7 - d) +: 8];
                    parsed = parsed * 16 + ((digit >= "A") ? digit - "A" + 10 : digit - "0");
                end
                digit = line_buf[8*9 +: 8];
                t = (digit >= "A") ? digit - "A" + 10 : digit - "0";
                if (parsed == results[t*32 +: 32]) lines_ok = lines_ok + 1;
                else begin lines_bad = lines_bad + 1; $display("  WRONG serial line for test %0d: %h", t, parsed); end
            end else if (line_len == 3 && line_buf[0 +: 24] == "END") ends = ends + 1;
        end
    endtask
    initial begin
        forever begin
            @(negedge tx);                    // start bit
            repeat (4) @(posedge clk);        // to the middle of it
            for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
                repeat (8) @(posedge clk);
                rx_byte[bit_i] = tx;
            end
            repeat (8) @(posedge clk);        // stop bit
            if (rx_byte == 8'd13) begin check_line; line_len = 0; line_buf = 0; end
            else if (rx_byte != 8'd10) begin line_buf = {line_buf[8*15-1:0], rx_byte}; line_len = line_len + 1; end
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        reset = 0;
        fork
            begin wait (ends >= 1); end
            begin repeat (3_000_000) @(posedge clk); $display("  TIMED OUT (state %0d, test %0d)", bench.state, bench.test); end
        join_any
        #100;
        $display("  tests run: %0d of 16 (done = %0d)", bench.test + 1, done);
        $display("  serial lines matching the results: %0d of 16 (wrong: %0d), END lines: %0d", lines_ok, lines_bad, ends);
        $display("  handshake mistakes seen by the fake memory: %0d", memory.protocol_mistakes);
        $display("  reads sent %0d, answered %0d", memory.reads_taken, memory.queue_out);
        if (done && lines_ok == 16 && lines_bad == 0 && ends >= 1 && memory.protocol_mistakes == 0 && failures == 0
            && memory.reads_taken == memory.queue_out && (random_busy != 0 || checked == 16))
            $display("PASSED: every check is right");
        else
            $display("FAILED");
        $finish;
    end

endmodule

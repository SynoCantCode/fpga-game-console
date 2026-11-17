// memory_tester_tb.v
// memory tester against the fake memory controller
// run 1 a perfect memory must give 0 errors, run 2 a memory with one flipped bit must give exactly 1 bad block
`timescale 1ns / 1ps

module memory_tester_tb;

    localparam BLOCKS = 1000;   // small test area so it simulates quick

    reg clk = 0;
    always #5 clk = ~clk;       // 100 MHz
    reg reset = 1;

    // run 1 a perfect memory
    wire calibrated_1, cmd_ready_1, cmd_en_1, wr_data_rdy_1, wr_data_en_1, wr_data_end_1, rd_data_valid_1, done_1;
    wire [2:0] cmd_1;  wire [28:0] addr_1;  wire [255:0] wr_data_1, rd_data_1;  wire [31:0] wr_data_mask_1, errors_1;

    fake_memory_controller #(.BLOCKS(BLOCKS)) good_memory (
        .clk(clk), .calibrated(calibrated_1), .cmd_ready(cmd_ready_1), .cmd_en(cmd_en_1), .cmd(cmd_1), .addr(addr_1),
        .wr_data_rdy(wr_data_rdy_1), .wr_data_en(wr_data_en_1), .wr_data_end(wr_data_end_1), .wr_data(wr_data_1),
        .wr_data_mask(wr_data_mask_1), .rd_data_valid(rd_data_valid_1), .rd_data(rd_data_1)
    );
    memory_tester #(.BLOCKS(BLOCKS)) tester_1 (
        .clk(clk), .reset(reset), .calibrated(calibrated_1), .cmd_ready(cmd_ready_1), .cmd_en(cmd_en_1), .cmd(cmd_1),
        .addr(addr_1), .wr_data_rdy(wr_data_rdy_1), .wr_data_en(wr_data_en_1), .wr_data_end(wr_data_end_1),
        .wr_data(wr_data_1), .wr_data_mask(wr_data_mask_1), .rd_data_valid(rd_data_valid_1), .rd_data(rd_data_1),
        .done(done_1), .errors(errors_1)
    );

    // run 2 a faulty memory, block 123 gets one flipped bit
    wire calibrated_2, cmd_ready_2, cmd_en_2, wr_data_rdy_2, wr_data_en_2, wr_data_end_2, rd_data_valid_2, done_2;
    wire [2:0] cmd_2;  wire [28:0] addr_2;  wire [255:0] wr_data_2, rd_data_2;  wire [31:0] wr_data_mask_2, errors_2;

    fake_memory_controller #(.BLOCKS(BLOCKS), .BROKEN_BLOCK(123)) bad_memory (
        .clk(clk), .calibrated(calibrated_2), .cmd_ready(cmd_ready_2), .cmd_en(cmd_en_2), .cmd(cmd_2), .addr(addr_2),
        .wr_data_rdy(wr_data_rdy_2), .wr_data_en(wr_data_en_2), .wr_data_end(wr_data_end_2), .wr_data(wr_data_2),
        .wr_data_mask(wr_data_mask_2), .rd_data_valid(rd_data_valid_2), .rd_data(rd_data_2)
    );
    memory_tester #(.BLOCKS(BLOCKS)) tester_2 (
        .clk(clk), .reset(reset), .calibrated(calibrated_2), .cmd_ready(cmd_ready_2), .cmd_en(cmd_en_2), .cmd(cmd_2),
        .addr(addr_2), .wr_data_rdy(wr_data_rdy_2), .wr_data_en(wr_data_en_2), .wr_data_end(wr_data_end_2),
        .wr_data(wr_data_2), .wr_data_mask(wr_data_mask_2), .rd_data_valid(rd_data_valid_2), .rd_data(rd_data_2),
        .done(done_2), .errors(errors_2)
    );

    // check helper
    integer failures = 0;

    task check(input string what, input integer got, input integer expected);
        if (got == expected) begin
            $display("  ok    %0s: %0d", what, got);
        end else begin
            $display("  FAIL  %0s: got %0d, expected %0d", what, got, expected);
            failures = failures + 1;
        end
    endtask

    // the test
    initial begin
        $display("memory_tester test: %0d blocks, against a fake memory controller", BLOCKS);
        repeat (5) @(posedge clk);
        reset = 0;

        fork
            begin wait (done_1 && done_2); end
            begin #2_000_000; end   // give up after 2 ms
        join_any
        repeat (50) @(posedge clk);   // let any stray extra commands show up

        $display("Perfect memory:");
        check("finished (1 = yes)", done_1, 1);
        check("bad blocks reported", errors_1, 0);
        check("blocks written", good_memory.writes_taken, BLOCKS);
        check("blocks read", good_memory.reads_taken, BLOCKS);
        check("handshake mistakes", good_memory.protocol_mistakes, 0);
        $display("Faulty memory (one bit flipped in block 123):");
        check("finished (1 = yes)", done_2, 1);
        check("bad blocks reported", errors_2, 1);
        check("handshake mistakes", bad_memory.protocol_mistakes, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

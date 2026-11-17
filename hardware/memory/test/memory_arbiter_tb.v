// memory_arbiter_tb.v
// arbiter test with the fake memory controller and one fake client per port
// the display reads now and then, gpu cpu and dma ask nonstop, port 0 never asks
// checks the display always goes first, the free turns are split 6 3 1, nobody starves, and every read gets the right data back
`timescale 1ns / 1ps

module memory_arbiter_tb;

    localparam PORTS = 5;
    localparam DISPLAY_EVERY = 16;      // the display asks for one burst every 16 ticks
    localparam MEASURED_TURNS = 20000;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // the arbiter and the fake memory controller
    reg [PORTS-1:0] req = 0;
    reg [PORTS*3-1:0] port_cmd = 0;
    reg [PORTS*29-1:0] port_addr = 0;
    reg [PORTS*256-1:0] port_wr_data = 0;
    wire [PORTS*32-1:0] port_wr_mask = 0;
    wire [PORTS-1:0] grant, rd_valid;
    wire [255:0] rd_data;

    wire calibrated, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, mem_rd_valid;
    wire [2:0] cmd;  wire [28:0] addr;  wire [255:0] wr_data, mem_rd_data;  wire [31:0] wr_data_mask;

    memory_arbiter #(
        .PORTS(PORTS),
        .BUDGET({16'd1, 16'd3, 16'd6, 16'd0, 16'd0})
    ) arbiter (
        .clk(clk), .reset(reset),
        .req(req), .port_cmd(port_cmd), .port_addr(port_addr), .port_wr_data(port_wr_data), .port_wr_mask(port_wr_mask),
        .grant(grant), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr), .wr_data_rdy(wr_data_rdy),
        .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data), .wr_data_mask(wr_data_mask),
        .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data)
    );

    fake_memory_controller #(.BLOCKS(2048)) memory (
        .clk(clk), .calibrated(calibrated), .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data),
        .wr_data_mask(wr_data_mask), .rd_data_valid(mem_rd_valid), .rd_data(mem_rd_data)
    );

    // what each client writes, a value that says whose block it is and which lap
    function [255:0] pattern(input integer port, input integer block, input integer lap);
        pattern = {8{port[7:0], lap[7:0], block[15:0]}};
    endfunction

    function [28:0] address_of(input integer port, input integer block);
        reg [24:0] number;
        begin
            number = port * 256 + block;                       // each client has its own 256 blocks
            address_of = {1'b0, number, 3'b000};
        end
    endfunction

    // the clients
    integer step [0:PORTS-1];          // even = write next, odd = read next
    integer block_of [0:PORTS-1];
    integer lap_of [0:PORTS-1];
    integer wait_ticks [0:PORTS-1];    // how long the current request has been waiting
    integer longest_wait [0:PORTS-1];
    integer grants [0:PORTS-1];        // grants counted while measuring
    integer display_timer = 0;
    integer p, i;
    reg measuring = 0;
    reg stopped = 0;     // 1 = test is over, nobody asks anymore
    reg gpu_idle = 0;    // gpu has nothing to do and stops asking
    integer phase2_turns [0:PORTS-1];
    initial for (p = 0; p < PORTS; p = p + 1) phase2_turns[p] = 0;

    // expected read answers per client in order
    reg [255:0] expected [0:PORTS-1][0:127];
    integer expect_in [0:PORTS-1];
    integer expect_out [0:PORTS-1];
    integer wrong_answers = 0, answers = 0;

    initial for (p = 0; p < PORTS; p = p + 1) begin
        step[p] = 0; block_of[p] = 0; lap_of[p] = 0; wait_ticks[p] = 0; longest_wait[p] = 0; grants[p] = 0;
        expect_in[p] = 0; expect_out[p] = 0;
    end

    task set_request(input integer port);
        reg is_read;
        begin
            if (port == 1) is_read = 1;                      // the display only reads
            else is_read = step[port][0];
            port_cmd[port*3 +: 3] = is_read ? 3'b001 : 3'b000;
            port_addr[port*29 +: 29] = address_of(port, block_of[port]);
            port_wr_data[port*256 +: 256] = pattern(port, block_of[port], lap_of[port]);
            req[port] = 1;
        end
    endtask

    reg [PORTS-1:0] seen_grant, seen_valid;
    reg [255:0] seen_data;
    reg [PORTS*3-1:0] seen_cmd;

    always @(posedge clk) if (!reset && calibrated) begin
        // note what happened on this edge then change the requests just after it so theres no race
        seen_grant = grant; seen_valid = rd_valid; seen_data = rd_data; seen_cmd = port_cmd;
        #1;
        // grants and answers
        for (p = 1; p < PORTS; p = p + 1) begin
            if (seen_grant[p]) begin
                if (measuring) grants[p] = grants[p] + 1;
                if (seen_cmd[p*3 +: 3] == 3'b001) begin    // a read, remember what it should bring back
                    expected[p][expect_in[p] % 128] = (p == 1) ? 256'd0 : pattern(p, block_of[p], lap_of[p]);
                    expect_in[p] = expect_in[p] + 1;
                end
                if (p != 1) begin                           // hungry clients go to the next step right away
                    if (step[p][0]) begin
                        block_of[p] = (block_of[p] + 1) % 256;
                        if (block_of[p] == 0) lap_of[p] = lap_of[p] + 1;
                    end
                    step[p] = step[p] + 1;
                    if (!stopped && !(p == 2 && gpu_idle)) set_request(p); else req[p] = 0;
                end else begin
                    req[1] = 0;                              // the display waits for its next moment
                end
                if (wait_ticks[p] > longest_wait[p] && measuring) longest_wait[p] = wait_ticks[p];
                wait_ticks[p] = 0;
            end else if (req[p]) begin
                wait_ticks[p] = wait_ticks[p] + 1;
            end
            if (seen_valid[p]) begin
                answers = answers + 1;
                if (expect_out[p] >= expect_in[p] || seen_data !== expected[p][expect_out[p] % 128]) begin
                    if (wrong_answers < 5) $display("        wrong answer for port %0d", p);
                    wrong_answers = wrong_answers + 1;
                end
                expect_out[p] = expect_out[p] + 1;
            end
        end
        // the display asks again every DISPLAY_EVERY ticks
        display_timer = display_timer + 1;
        if (display_timer == DISPLAY_EVERY) begin
            display_timer = 0;
            if (!req[1] && !stopped) set_request(1);
        end
    end

    // nobody else may be granted while the display is asking
    integer display_passed_over = 0;
    always @(posedge clk) if (req[1] && grant != 0 && !grant[1] && !arbiter.asked_full) display_passed_over = display_passed_over + 1;

    // answers or grants for more than one port at once would be a bug
    integer double_grants = 0;
    always @(posedge clk) if ((grant & (grant - 1)) != 0 || (rd_valid & (rd_valid - 1)) != 0) double_grants = double_grants + 1;

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
    integer turns_measured, free_turns, budget_total;
    integer budget_turns [0:PORTS-1];   // turns a port spent from its budget, not leftovers
    initial for (p = 0; p < PORTS; p = p + 1) budget_turns[p] = 0;
    always @(posedge clk) if (gpu_idle && !stopped) for (i = 3; i < PORTS; i = i + 1)
        if (grant[i]) phase2_turns[i] = phase2_turns[i] + 1;
    always @(posedge clk) if (measuring) for (i = 2; i < PORTS; i = i + 1)
        if (grant[i] && arbiter.credit[i] > 0 && arbiter.budget_left) budget_turns[i] = budget_turns[i] + 1;

    initial begin
        $display("memory_arbiter test: display + 3 hungry clients (GPU, CPU, DMA), free turns shared 6 : 3 : 1");
        repeat (5) @(posedge clk);
        reset = 0;
        wait (calibrated);
        @(negedge clk);
        for (p = 2; p < PORTS; p = p + 1) set_request(p);   // hungry clients start asking

        repeat (3000) @(posedge clk);                        // settle in
        measuring = 1;
        turns_measured = 0;
        while (turns_measured < MEASURED_TURNS) begin
            @(posedge clk);
            if (cmd_en && cmd_ready) turns_measured = turns_measured + 1;
        end
        measuring = 0;

        // phase 2 the gpu is idle, its share should go to cpu and dma keeping their 3 to 1
        @(negedge clk);
        gpu_idle = 1;
        repeat (500) @(posedge clk);                         // let the gpus last request finish
        for (p = 3; p < PORTS; p = p + 1) phase2_turns[p] = 0;
        repeat (20000) @(posedge clk);
        @(negedge clk);
        stopped = 1;
        req = 0;                                             // everyone stops asking
        repeat (200) @(posedge clk);                         // let the last answers come back

        $display("Share of all %0d turns (percent):", MEASURED_TURNS);
        check("display (asks every 16 ticks: takes what it needs)", 100 * grants[1] / MEASURED_TURNS, 5, 15);
        $display("All free turns (leftovers included: they're paid back from later budgets), tenths of a percent:");
        free_turns = grants[2] + grants[3] + grants[4];
        check("GPU (6 of 10 = 600)", 1000 * grants[2] / free_turns, 590, 610);
        check("CPU (3 of 10 = 300)", 1000 * grants[3] / free_turns, 290, 310);
        check("DMA (1 of 10 = 100)", 1000 * grants[4] / free_turns, 90, 110);
        $display("GPU idle (not asking): the free turns split between CPU and DMA, still 3 : 1:");
        check("CPU (3 of 4 = 750 tenths of a percent)", 1000 * phase2_turns[3] / (phase2_turns[3] + phase2_turns[4]), 730, 770);
        check("DMA (1 of 4 = 250)", 1000 * phase2_turns[4] / (phase2_turns[3] + phase2_turns[4]), 230, 270);
        $display("Longest wait for a turn (ticks):");
        check("display (only the memory controller's own busy moments)", longest_wait[1], 0, 20);
        check("times someone else was granted while the display was asking", display_passed_over, 0, 0);
        check("CPU (short: the shares come in small windows)", longest_wait[3], 0, 60);
        check("DMA (never starved)", longest_wait[4], 0, 100);
        $display("Read answers:");
        check("answers delivered", answers, 1000, 1000000);
        check("answers to the wrong client or with wrong data", wrong_answers, 0, 0);
        check("answers still missing", (expect_in[1] - expect_out[1]) + (expect_in[2] - expect_out[2]) +
              (expect_in[3] - expect_out[3]) + (expect_in[4] - expect_out[4]), 0, 0);
        $display("Handshake:");
        check("ticks with two grants or two answers at once", double_grants, 0, 0);
        check("handshake mistakes seen by the memory controller", memory.protocol_mistakes, 0, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

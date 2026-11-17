// binning_tb.v
// tests binning.v through the real arbiter into a fake memory
// the test sends cards and keeps its own list of what every shelf should hold
// small shelves here so one can be filled up
`timescale 1ns / 1ps

module binning_tb;

    localparam SHELF_BURSTS = 16;
    localparam CAPACITY = SHELF_BURSTS * 8 - 1;      // 127
    localparam BLOCKS = 460 * SHELF_BURSTS;          // shelves start at burst 0
    localparam FRAME_BURSTS = 115_200;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // binning
    reg frame_begin = 0, frame_end = 0;
    wire frame_finished, busy, overflow;
    reg card_valid = 0;  wire card_ready;
    reg [16:0] card_number = 0;
    reg [15:0] box_left = 0, box_right = 0, box_top = 0, box_bottom = 0;
    wire [4:0] req, grant, rd_valid;
    wire [2:0] bin_cmd;  wire [28:0] bin_addr;  wire [255:0] bin_data, rd_data;  wire [31:0] bin_mask;

    binning #(.SHELF_BURSTS(SHELF_BURSTS)) binner (
        .clk(clk), .reset(reset),
        .frame_begin(frame_begin), .shelves_start(25'd0), .frame_end(frame_end),
        .frame_finished(frame_finished), .busy(busy), .overflow(overflow),
        .card_valid(card_valid), .card_ready(card_ready), .card_number(card_number),
        .box_left(box_left), .box_right(box_right), .box_top(box_top), .box_bottom(box_bottom),
        .mem_req(req[2]), .mem_cmd(bin_cmd), .mem_addr(bin_addr), .mem_wr_data(bin_data), .mem_wr_mask(bin_mask),
        .mem_grant(grant[2]));

    // arbiter, fake memory and a display on port 1
    wire calibrated, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, mem_rd_valid;
    wire [2:0] cmd;  wire [28:0] addr;  wire [255:0] wr_data, mem_rd_data;  wire [31:0] wr_data_mask;

    reg display_req = 0;  reg [24:0] display_burst = 0;  integer display_wait = 0;
    always @(posedge clk) begin
        #1;
        if (!reset && calibrated) begin
            if (grant[1]) begin
                display_burst = (display_burst + 1) % BLOCKS;
                display_req = 0;  display_wait = 13;
            end else if (display_wait > 0) display_wait = display_wait - 1;
            else display_req = 1;
        end
    end
    assign req[0] = 0;  assign req[1] = display_req;  assign req[3] = 0;  assign req[4] = 0;

    memory_arbiter #(.PORTS(5)) arbiter (
        .clk(clk), .reset(reset), .req(req),
        .port_cmd({3'b001, 3'b001, bin_cmd, 3'b001, 3'b001}),
        .port_addr({29'd0, 29'd0, bin_addr, {1'b0, display_burst, 3'b000}, 29'd0}),
        .port_wr_data({256'd0, 256'd0, bin_data, 256'd0, 256'd0}),
        .port_wr_mask({32'd0, 32'd0, bin_mask, 32'd0, 32'd0}),
        .grant(grant), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr), .wr_data_rdy(wr_data_rdy),
        .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data), .wr_data_mask(wr_data_mask),
        .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data));

    fake_memory_controller #(.BLOCKS(BLOCKS)) memory (
        .clk(clk), .calibrated(calibrated), .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data),
        .wr_data_mask(wr_data_mask), .rd_data_valid(mem_rd_valid), .rd_data(mem_rd_data));

    // helpers
    integer failures = 0, wrong = 0;

    task check(input [8*60-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    task tick;
        begin @(posedge clk); #1; end
    endtask

    // the tests own list of what every shelf should hold
    integer want_count [0:459];
    integer want_entry [0:459][0:CAPACITY-1];
    integer visits = 0;

    task new_frame;
        integer t;
        begin
            for (t = 0; t < 460; t = t + 1) want_count[t] = 0;
            visits = 0;
            frame_begin = 1; tick; frame_begin = 0;
        end
    endtask

    // send one card back to back, box in pixels
    task send_card(input integer n, input integer l, input integer r, input integer t, input integer b);
        integer tx, ty;
        begin
            card_number = n; box_left = l; box_right = r; box_top = t; box_bottom = b;
            card_valid = 1;
            while (!card_ready) tick;
            tick;
            for (ty = t / 32; ty <= b / 32; ty = ty + 1)
                for (tx = l / 64; tx <= r / 64; tx = tx + 1) begin
                    visits = visits + 1;
                    if (want_count[ty * 20 + tx] < CAPACITY) begin
                        want_entry[ty * 20 + tx][want_count[ty * 20 + tx]] = n;
                        want_count[ty * 20 + tx] = want_count[ty * 20 + tx] + 1;
                    end
                end
        end
    endtask

    task end_frame;
        begin
            card_valid = 0;
            frame_end = 1; tick; frame_end = 0;
            while (!frame_finished) tick;
            repeat (8) tick;   // let the last writes land
        end
    endtask

    // fill the shelves with junk so only what binning writes can pass
    task junk_shelves;
        integer i;
        for (i = 0; i < BLOCKS; i = i + 1) memory.memory[i] = {8{32'hFFFF_FFFF}};
    endtask

    // read every shelf back and compare with the list
    task check_shelves;
        integer t, k, word;
        reg [255:0] burst;
        begin
            for (t = 0; t < 460; t = t + 1) begin
                burst = memory.memory[t * SHELF_BURSTS];
                if (burst[31:0] !== want_count[t]) begin
                    if (wrong < 5) $display("        shelf %0d: count %0d, expected %0d", t, burst[31:0], want_count[t]);
                    wrong = wrong + 1;
                end
                for (k = 0; k < want_count[t]; k = k + 1) begin
                    word = k + 1;
                    burst = memory.memory[t * SHELF_BURSTS + word / 8];
                    if (burst[(word % 8) * 32 +: 32] !== want_entry[t][k]) begin
                        if (wrong < 5) $display("        shelf %0d number %0d: %0d, expected %0d", t, k,
                                                burst[(word % 8) * 32 +: 32], want_entry[t][k]);
                        wrong = wrong + 1;
                    end
                end
            end
        end
    endtask

    integer n, l, r, t, b, w, h, most, start_clock, clocks;

    initial begin
        $display("binning test: cards -> binning -> arbiter -> fake DDR3, shelves checked number by number");
        @(negedge clk);
        tick; reset = 0;
        wait (calibrated); tick;
        junk_shelves;

        // test 1 120 cards of every size
        new_frame;
        start_clock = $time / 10;
        for (n = 0; n < 120; n = n + 1) begin
            w = (n % 10 == 0) ? 1279 : (n % 3 == 0) ? 300 : 40;     // a few whole screen, some big, most small
            h = (n % 10 == 0) ? 719  : (n % 3 == 0) ? 200 : 30;
            l = $urandom % 1280;  t = $urandom % 720;
            r = l + $urandom % (w + 1);  b = t + $urandom % (h + 1);
            if (r > 1279) r = 1279;  if (b > 719) b = 719;
            if (n % 10 == 0) begin l = 0; t = 0; r = 1279; b = 719; end
            send_card(n, l, r, t, b);
        end
        clocks = $time / 10 - start_clock;
        end_frame;
        most = 0; for (n = 0; n < 460; n = n + 1) if (want_count[n] > most) most = want_count[n];
        wrong = 0; check_shelves;
        $display("Frame 1: 120 cards (%0d tile visits, the fullest shelf %0d numbers):", visits, most);
        check("wrong counts or numbers on the shelves", wrong, 0);
        check("overflow (should stay down)", overflow, 0);
        $display("  (speed: %0d clocks for %0d tile visits)", clocks, visits);

        // test 2 a second frame on top, counts start again from 0
        new_frame;
        for (n = 0; n < 60; n = n + 1) begin
            l = $urandom % 1280;  t = $urandom % 720;
            r = l + $urandom % 200;  b = t + $urandom % 150;
            if (r > 1279) r = 1279;  if (b > 719) b = 719;
            send_card(1000 + n, l, r, t, b);
        end
        end_frame;
        wrong = 0; check_shelves;
        $display("Frame 2: 60 other cards on top of frame 1's shelves:");
        check("wrong counts or numbers on the shelves", wrong, 0);

        // test 3 too many cards on one tile
        new_frame;
        for (n = 0; n < CAPACITY + 13; n = n + 1) send_card(2000 + n, 10, 20, 10, 20);    // all in tile 0
        end_frame;
        wrong = 0; check_shelves;
        $display("Frame 3: %0d cards on tile 0 (it holds %0d):", CAPACITY + 13, CAPACITY);
        check("wrong counts or numbers on the shelves", wrong, 0);
        check("overflow (should be up)", overflow, 1);

        // test 4 two tiles filled past capacity taking turns
        new_frame;
        for (n = 0; n < CAPACITY + 13; n = n + 1) begin
            send_card(3000 + 2 * n, 70, 120, 10, 20);          // tile 1
            send_card(3001 + 2 * n, 140, 180, 10, 20);         // tile 2
        end
        end_frame;
        wrong = 0; check_shelves;
        $display("Frame 4: %0d cards each on tiles 1 and 2, taking turns (each holds %0d):", CAPACITY + 13, CAPACITY);
        check("wrong counts or numbers on the shelves", wrong, 0);
        check("tile 1's count (full)", want_count[1], CAPACITY);
        check("tile 2's count (full)", want_count[2], CAPACITY);

        $display("The memory controller's view:");
        check("handshake mistakes", memory.protocol_mistakes, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

    // watchdog
    initial begin
        #100_000_000;
        $display("  FAIL  stuck: binning state %0d, walking %0d, time %0d ns", binner.state, binner.walking, $time);
        $finish;
    end

endmodule

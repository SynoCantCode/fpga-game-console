// gpu_tb.v
// the whole gpu on its own, a command list in fake DDR3 then go
// saves every finished frame and checks they come out in order into the right buffers
`timescale 1ns / 1ps

module gpu_tb;

    localparam FRAME_BURSTS = 115_200;
    localparam SHELF_BURSTS = 16;
    localparam [24:0] FB0 = 0, FB1 = 115200, FB2 = 230400;
    localparam [24:0] SHELVES_A = 345600, SHELVES_B = 352960;       // 460 shelves x 16 bursts each
    localparam [24:0] CARDS_A = 360320, CARDS_B = 365120;
    localparam [24:0] LIST_START = 370000;           // where the command list sits in memory
    localparam BLOCKS = 372000;
    localparam TV_TICKS = 200_000;                    // a pretend tv frame, shorter than a real one to save time
    localparam FRAMES_TO_DRAW = 4;

    // clocks, with TWO_CLOCKS the gpu gets its own clock and the real crossing is used
    reg clk = 0;                                      // gpu clock
`ifdef TWO_CLOCKS
`ifndef GPU_HALF
`define GPU_HALF 6.25
`endif
`ifndef GPU_START
`define GPU_START 3.7
`endif
    initial begin #(`GPU_START); forever #(`GPU_HALF) clk = ~clk; end
    reg mclk = 0;
    always #5 mclk = ~mclk;
`define MCLK mclk
`else
    always #5 clk = ~clk;
`define MCLK clk
`endif
    reg reset = 1;

    // memory image
    reg [255:0] image [0:1199];
    reg [31:0] fog_words [0:256];                     // fog table then the fog color
    reg [15:0] lamp_words [0:511];                    // lamp 0 table then lamp 1
    initial $readmemh("build/cp/memory.hex", image);

    // frame buffers and a pretend tv
    reg tv_frame = 0;                                 // memory side
    wire buffer_ok, buffer_begin, buffer_end;          // gpu side
    wire [24:0] buffer_start, show_start;
    wire m_buffer_ok, m_buffer_begin, m_buffer_end;    // frame buffer side
    wire [24:0] m_buffer_start;
    wire g_tv_frame;                                   // tv tick as the gpu sees it
    wire [1:0] showing, ready, drawing;
    wire ready_valid, drawing_valid;
    frame_buffers #(.BUFFER0(FB0), .BUFFER1(FB1), .BUFFER2(FB2)) buffers (
        .clk(`MCLK), .reset(reset), .show_start(show_start), .switched(tv_frame),
        .draw_ok(m_buffer_ok), .draw_start(m_buffer_start), .draw_begin(m_buffer_begin), .draw_end(m_buffer_end),
        .showing(showing), .ready_valid(ready_valid), .ready(ready), .drawing_valid(drawing_valid), .drawing(drawing));

    // the gpu
    reg reg_write = 0, reg_read = 0;
    reg [5:0] reg_offset = 0;
    reg [31:0] reg_wdata = 0;
    wire [31:0] reg_rdata;
    wire stopped, front_busy, draw_busy, overflow;
    wire [31:0] dropped_near, dropped_far, dropped_back, dropped_flat, dropped_off;
    wire [16:0] cards_made;
    wire [4:0] req, grant, rd_valid;
    wire [2:0] gpu_cmd;  wire [28:0] gpu_addr;  wire [255:0] gpu_data, rd_data;  wire [31:0] gpu_mask;
    wire g_req, g_grant, g_rd_valid;                   // gpu memory port, its side of the crossing
    wire [2:0] g_cmd;  wire [28:0] g_addr;  wire [255:0] g_data, g_rd_data;  wire [31:0] g_mask;

    gpu #(.SHELF_BURSTS(SHELF_BURSTS), .CARDS_A(CARDS_A), .SHELVES_A(SHELVES_A), .CARDS_B(CARDS_B),
          .SHELVES_B(SHELVES_B)) the_gpu (
        .clk(clk), .reset(reset),
        .reg_write(reg_write), .reg_read(reg_read), .reg_offset(reg_offset), .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata), .stopped(stopped),
        .buffer_ok(buffer_ok), .buffer_start(buffer_start), .buffer_begin(buffer_begin), .buffer_end(buffer_end),
        .tv_frame(g_tv_frame),
        .front_busy(front_busy), .draw_busy(draw_busy),
        .dropped_near(dropped_near), .dropped_too_far_out(dropped_far), .dropped_back(dropped_back),
        .dropped_flat(dropped_flat), .dropped_off_screen(dropped_off), .cards_made(cards_made), .overflow(overflow),
        .mem_req(g_req), .mem_cmd(g_cmd), .mem_addr(g_addr), .mem_wr_data(g_data), .mem_wr_mask(g_mask),
        .mem_grant(g_grant), .mem_rd_valid(g_rd_valid), .mem_rd_data(g_rd_data));

`ifdef TWO_CLOCKS
    // real crossing between the gpu clock and the memory clock
    gpu_clock_crossing crossing (
        .gpu_clk(clk), .gpu_reset(reset),
        .g_req(g_req), .g_cmd(g_cmd), .g_addr(g_addr), .g_wr_data(g_data), .g_wr_mask(g_mask),
        .g_grant(g_grant), .g_rd_valid(g_rd_valid), .g_rd_data(g_rd_data),
        .g_buffer_ok(buffer_ok), .g_buffer_start(buffer_start), .g_buffer_begin(buffer_begin), .g_buffer_end(buffer_end),
        .g_tv_frame(g_tv_frame),
        .mem_clk(mclk), .mem_reset(reset),
        .m_req(req[2]), .m_cmd(gpu_cmd), .m_addr(gpu_addr), .m_wr_data(gpu_data), .m_wr_mask(gpu_mask),
        .m_grant(grant[2]), .m_rd_valid(rd_valid[2]), .m_rd_data(rd_data),
        .m_buffer_ok(m_buffer_ok), .m_buffer_start(m_buffer_start), .m_buffer_begin(m_buffer_begin),
        .m_buffer_end(m_buffer_end), .m_tv_frame(tv_frame));
`else
    // one clock, gpu wired straight through
    assign req[2] = g_req;  assign gpu_cmd = g_cmd;  assign gpu_addr = g_addr;  assign gpu_data = g_data;
    assign gpu_mask = g_mask;  assign g_grant = grant[2];  assign g_rd_valid = rd_valid[2];  assign g_rd_data = rd_data;
    assign buffer_ok = m_buffer_ok;  assign buffer_start = m_buffer_start;
    assign m_buffer_begin = buffer_begin;  assign m_buffer_end = buffer_end;  assign g_tv_frame = tv_frame;
`endif

    // arbiter, fake memory and a display reading
    wire calibrated, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, mem_rd_valid;
    wire [2:0] cmd;  wire [28:0] addr;  wire [255:0] wr_data, mem_rd_data;  wire [31:0] wr_data_mask;

    reg display_req = 0;  reg [24:0] display_burst = 0;  integer display_wait = 0;
    always @(posedge `MCLK) begin
        #1;
        if (!reset && calibrated) begin
            if (grant[1]) begin
                display_burst = (display_burst + 1) % FRAME_BURSTS;
                display_req = 0;  display_wait = 13;
            end else if (display_wait > 0) display_wait = display_wait - 1;
            else display_req = 1;
        end
    end
    assign req[0] = 0;  assign req[1] = display_req;  assign req[3] = 0;  assign req[4] = 0;

    memory_arbiter #(.PORTS(5)) arbiter (
        .clk(`MCLK), .reset(reset), .req(req),
        .port_cmd({3'b001, 3'b001, gpu_cmd, 3'b001, 3'b001}),
        .port_addr({29'd0, 29'd0, gpu_addr, {1'b0, show_start + display_burst, 3'b000}, 29'd0}),
        .port_wr_data({256'd0, 256'd0, gpu_data, 256'd0, 256'd0}),
        .port_wr_mask({32'd0, 32'd0, gpu_mask, 32'd0, 32'd0}),
        .grant(grant), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr), .wr_data_rdy(wr_data_rdy),
        .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data), .wr_data_mask(wr_data_mask),
        .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data));

`ifndef FAKE_SEED
`define FAKE_SEED 16'hACE1
`endif
`ifndef FAKE_STALL_PERIOD
`define FAKE_STALL_PERIOD 0
`endif
`ifndef FAKE_STALL_LEN
`define FAKE_STALL_LEN 0
`endif
`ifndef FAKE_GAPS
`define FAKE_GAPS 0
`endif
`ifndef FAKE_LATENCY
`define FAKE_LATENCY 20
`endif
    fake_memory_controller #(.BLOCKS(BLOCKS), .SEED(`FAKE_SEED), .STALL_PERIOD(`FAKE_STALL_PERIOD),
        .STALL_LEN(`FAKE_STALL_LEN), .ANSWER_GAPS(`FAKE_GAPS), .LATENCY(`FAKE_LATENCY)) memory (
        .clk(`MCLK), .calibrated(calibrated), .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data),
        .wr_data_mask(wr_data_mask), .rd_data_valid(mem_rd_valid), .rd_data(mem_rd_data));

    task tick;
        begin @(posedge clk); #1; end
    endtask

    // card buffer between setup and binning, at end of frame it must be empty
    integer cards_in = 0, cards_out = 0, card_buffer_wrong = 0, bin_ends = 0;
`ifdef NETLIST
    // inside names dont exist in a netlist so these checks are skipped
    initial begin cards_in = 1; bin_ends = 1; end
`else
    always @(posedge clk) if (!reset) begin
        if (the_gpu.card_valid && the_gpu.card_ready) cards_in = cards_in + 1;
        if (the_gpu.bin_card_valid && the_gpu.bin_card_ready) cards_out = cards_out + 1;
        if (the_gpu.bin_end) begin
            bin_ends = bin_ends + 1;
            if (the_gpu.bin_card_valid || cards_in != cards_out) begin
                if (card_buffer_wrong < 5)
                    $display("  binning told 'end of frame' with a card still in the card buffer (%0d in, %0d out)",
                             cards_in, cards_out);
                card_buffer_wrong = card_buffer_wrong + 1;
            end
        end
    end
`endif

    // speed counters, the test counts the same things itself
    integer t_on = 0, t_back = 0, t_wo = 0, t_fin = 0, last_back = 0, last_wo = 0, last_fin = 0;
    integer f_on2 = 0, t_front = 0, last_front = 0;
`ifndef NETLIST
    always @(posedge clk) if (!reset) begin
        if (the_gpu.draw_start) begin t_on = 1; t_back = 0; t_wo = 0; t_fin = 0; end
        else if (t_on) begin
            t_back = t_back + 1;
            if (the_gpu.back_half.wo_busy) t_wo = t_wo + 1;
            if (the_gpu.back_half.controller.state == 12) t_fin = t_fin + 1;
            if (the_gpu.draw_done) begin t_on = 0; last_back = t_back; last_wo = t_wo; last_fin = t_fin; end
        end
        if (the_gpu.front_begin) begin f_on2 = 1; t_front = 0; end
        else if (f_on2) begin
            t_front = t_front + 1;
            if (the_gpu.front_done) begin f_on2 = 0; last_front = t_front; end
        end
    end
`endif
    integer perf_wrong = 0;
    reg [31:0] perf_read [0:7];
    task perf_near(input [8*40-1:0] what, input integer got, input integer want, input integer slack);
        if (got > want + slack || got + slack < want) begin
            $display("  FAIL  speed counter %0s: %0d, the testbench counted %0d", what, got, want);
            perf_wrong = perf_wrong + 1;
        end else $display("  ok    speed counter %0s: %0d (testbench %0d)", what, got, want);
    endtask

    // projections 8 copies of advance must always equal the original
    integer advance_copy_wrong = 0, projection_stalls = 0;
`ifndef NETLIST
    always @(posedge clk) if (!reset) begin
        if (the_gpu.project.advance_c !== {8{the_gpu.project.advance}}) begin
            if (advance_copy_wrong < 5)
                $display("  projection's copies of advance %b, advance %b", the_gpu.project.advance_c, the_gpu.project.advance);
            advance_copy_wrong = advance_copy_wrong + 1;
        end
        if (!the_gpu.project.advance) projection_stalls = projection_stalls + 1;
    end
`endif

    // pretend tv, a new frame every TV_TICKS clocks
    integer tv_count = 0, tv_frames = 0;
    always @(posedge `MCLK) begin
        if (!reset) begin
            tv_count <= (tv_count == TV_TICKS - 1) ? 0 : tv_count + 1;
            tv_frame <= (tv_count == TV_TICKS - 1);
            if (tv_count == TV_TICKS - 1) tv_frames = tv_frames + 1;
        end
    end

    // watch the frames finish, save each one and check the pacing
    integer drawn = 0, too_fast = 0, wrong_buffer = 0, last_start_tv = -1;
    integer cards_of [0:63];                        // card count of each drawn frame
    reg [24:0] buffer_of_drawing;
    // watched on the memory side where the frame buffers see them
    always @(posedge `MCLK) begin
        if (!reset && m_buffer_begin) begin
            if (tv_frames == last_start_tv) too_fast = too_fast + 1;       // two frames begun within one tv frame
            last_start_tv = tv_frames;
            buffer_of_drawing = m_buffer_start;
            if (m_buffer_start == show_start) wrong_buffer = wrong_buffer + 1;
        end
        if (!reset && m_buffer_end) begin
            if (drawn < FRAMES_TO_DRAW)             // only the first frames are saved
                $writememh($sformatf("build/cp/frame_%02d.hex", drawn), memory.memory,
                           buffer_of_drawing, buffer_of_drawing + FRAME_BURSTS - 1);
            if (drawn < 64) cards_of[drawn] = cards_made;
            $display("  frame %0d drawn into the buffer at %0d (TV frame %0d): %0d cards", drawn, buffer_of_drawing,
                     tv_frames, cards_made);
            drawn = drawn + 1;
        end
    end

    integer i, first_p2, frames_before, p2_failures = 0;
    task p2_check(input [8*70-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); p2_failures = p2_failures + 1; end
    endtask
    localparam LIST_B = 371300;                     // phase 2 tiny lists

    initial begin
        $display("gpu test: a command list in DDR3, 'go', and the whole GPU runs on its own");
`ifdef TWO_CLOCKS
        $display("  TWO CLOCKS: the GPU at half-tick %0.3f ns (start %0.2f), the memory side at 100 MHz, the real crossing between", `GPU_HALF, `GPU_START);
`else
        $display("  one clock for everything");
`endif
        @(negedge clk);
        tick; reset = 0;
        wait (calibrated); tick;
        for (i = 0; i < 1200; i = i + 1) memory.memory[LIST_START + i] = image[i];

`ifdef FOG_SETUP
        // load the fog table and color through the registers
        $readmemh("build/cp/fog.hex", fog_words);
        for (i = 0; i < 256; i = i + 1) begin
            reg_offset = 6'h24;  reg_wdata = {8'd0, i[7:0], fog_words[i][15:0]};  reg_write = 1;  tick;  reg_write = 0;
        end
        reg_offset = 6'h20;  reg_wdata = fog_words[256];  reg_write = 1;  tick;  reg_write = 0;  tick;
`endif
`ifdef LAMP_SETUP
        // load both lamp tables through the registers
        $readmemh("build/cp/lamps.hex", lamp_words);
        for (i = 0; i < 512; i = i + 1) begin
            reg_offset = 6'h28;  reg_wdata = {7'd0, i[8], i[7:0], lamp_words[i]};  reg_write = 1;  tick;  reg_write = 0;
        end
        tick;
`endif
        // ring the doorbell with the list address in bytes
        reg_offset = 5'h00;  reg_wdata = LIST_START * 32;  reg_write = 1;  tick;  reg_write = 0;
        while (drawn < FRAMES_TO_DRAW) tick;

        // read the registers back
        reg_offset = 5'h04;  reg_read = 1;  tick;  reg_read = 0;  tick;
        $display("  FRAMES_DRAWN register: %0d (should be %0d)", reg_rdata, FRAMES_TO_DRAW);
        if (reg_rdata != FRAMES_TO_DRAW) $display("FAILED: the FRAMES_DRAWN register is wrong");
        // read the 8 speed counters
        for (i = 0; i < 8; i = i + 1) begin
            reg_offset = 5'h1C;  reg_wdata = i;  reg_write = 1;  tick;  reg_write = 0;  tick;
            reg_read = 1;  tick;  reg_read = 0;  tick;
            perf_read[i] = reg_rdata;
        end
`ifndef NETLIST
        perf_near("0 back half ticks", perf_read[0], last_back, 0);
        perf_near("1 front half ticks", perf_read[1], last_front, 0);
        perf_near("2 tile ends", perf_read[2], last_fin, 2);
        perf_near("6 write-out busy", perf_read[6], last_wo, 2);
`endif
        if (perf_read[7] < perf_read[0] || perf_read[3] > perf_read[0] || perf_read[4] > perf_read[0] || perf_read[5] > perf_read[0]) begin
            $display("  FAIL  speed counters out of order: period %0d, back %0d, shelf wait %0d, hand %0d, no card %0d",
                     perf_read[7], perf_read[0], perf_read[3], perf_read[4], perf_read[5]);
            perf_wrong = perf_wrong + 1;
        end else $display("  ok    period %0d >= back %0d >= shelf wait %0d, hand %0d, no card %0d", perf_read[7], perf_read[0],
                          perf_read[3], perf_read[4], perf_read[5]);
        reg_offset = 5'h00;  reg_read = 1;  tick;  reg_read = 0;  tick;
        $display("  DOORBELL register reads running = %0d (should be 1)", reg_rdata);
        reg_offset = 5'h08;  reg_read = 1;  tick;  reg_read = 0;  tick;
        $display("  ERRORS register: %b (bit 2 set: the floor triangle too far off the screen, as expected)", reg_rdata[2:0]);

        // phase 2 doorbell queue, switch and starting again after a stop
        // two tiny lists, each one empty frame
        for (i = 0; i < 2; i = i + 1) begin
            memory.memory[LIST_B + i * 8 + 0] = 256'd0;
            memory.memory[LIST_B + i * 8 + 1] = {4'h3, 252'd0};       // end frame
            memory.memory[LIST_B + i * 8 + 2] = 256'd0;
            memory.memory[LIST_B + i * 8 + 3] = {4'hF, 252'd0};       // stop
        end
        $display("Phase 2: the doorbell's queue, SWITCH, and a STOP:");
        // ring list B while list A runs, it waits in the queue
        reg_offset = 5'h00;  reg_wdata = LIST_B * 32;  reg_write = 1;  tick;  reg_write = 0;
        reg_offset = 5'h00;  reg_read = 1;  tick;  reg_read = 0;  tick;
        p2_check("DOORBELL reads: running, 1 waiting (binary 0011)", reg_rdata, 3);
        first_p2 = drawn;
        while (drawn < first_p2 + 2) tick;
        p2_check("2 more frames: still list A (cards in the last one > 0)", cards_of[drawn - 1] > 0, 1);
        // switch, list B takes over at the next end frame then stops
        reg_offset = 5'h18;  reg_wdata = 1;  reg_write = 1;  tick;  reg_write = 0;
        first_p2 = drawn;
        while (!(drawn > first_p2 && cards_of[drawn - 1] == 0) && drawn < first_p2 + 4) tick;
        p2_check("after SWITCH: an empty frame (list B) within 3 frames", cards_of[drawn - 1], 0);
        while (!stopped && drawn < first_p2 + 6) tick;
        repeat (2000) tick;
        p2_check("  then list B's STOP: stopped", stopped, 1);
        reg_offset = 5'h18;  reg_read = 1;  tick;  reg_read = 0;  tick;
        p2_check("  SWITCH reads 0 (done)", reg_rdata, 0);
        frames_before = drawn;
        while (drawn == frames_before && tv_frames < 400) tick;    // the frame list B filled gets drawn
        repeat (3 * TV_TICKS) tick;
        frames_before = drawn;
        // ring list C while stopped, one ring starts it
        reg_offset = 5'h00;  reg_wdata = (LIST_B + 8) * 32;  reg_write = 1;  tick;  reg_write = 0;
        repeat (50) tick;
        p2_check("one ring while stopped: running again", !stopped, 1);
        while (!stopped) tick;
        while (drawn == frames_before && tv_frames < 600) tick;
        p2_check("  list C's frame drawn (empty)", cards_of[drawn - 1], 0);
        p2_check("  and stopped at its STOP", stopped, 1);
        reg_offset = 5'h00;  reg_read = 1;  tick;  reg_read = 0;  tick;
        p2_check("  DOORBELL reads: stopped, nothing waiting", reg_rdata, 0);

        $display("Checks:");
        $display("  phase 2 (queue, SWITCH, STOP) checks wrong: %0d (should be 0)", p2_failures);
        $display("  frames begun twice within one TV frame (too fast): %0d (should be 0)", too_fast);
        $display("  frames drawn into the buffer on the TV: %0d (should be 0)", wrong_buffer);
        $display("  stopped at the end (list C's STOP): %0d (should be 1)", stopped);
        $display("  errors: overflow %0d, handshake mistakes %0d (should be 0)", overflow, memory.protocol_mistakes);
        $display("  card buffer: %0d cards in, %0d out; frame ends with a card left in it: %0d (should be 0; %0d frame ends)",
                 cards_in, cards_out, card_buffer_wrong, bin_ends);
        $display("  ticks where a copy of projection's advance differs: %0d (should be 0; the line stopped %0d ticks)",
                 advance_copy_wrong, projection_stalls);
        if (too_fast == 0 && wrong_buffer == 0 && stopped && p2_failures == 0 && !overflow && memory.protocol_mistakes == 0
            && card_buffer_wrong == 0 && bin_ends > 0 && cards_in > 0 && perf_wrong == 0 && advance_copy_wrong == 0)
            $display("PASSED: every check here is right (the pictures are compared next)");
        else
            $display("FAILED");
        $finish;
    end

    // watchdog
    initial begin
        #600_000_000;
        $display("  FAIL  stuck: command processor state %0d, frames drawn %0d", the_gpu.commands.state, drawn);
        $finish;
    end

endmodule

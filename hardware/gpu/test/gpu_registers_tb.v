// gpu_registers_tb.v
// test for gpu_registers, the registers the cpu uses to talk to the gpu
// doorbell queue, switch, frame counter, errors, settings, texture slots and table writes
`timescale 1ns / 1ps

module gpu_registers_tb;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    reg write = 0, read = 0;
    reg [5:0] offset = 0;
    reg [31:0] wdata = 0;
    wire [31:0] rdata;
    wire list_waiting, switch_wanted;
    wire [24:0] next_list;
    reg list_taken = 0, switch_done = 0, front_begin = 0, draw_begin = 0;
    wire [31:0] near, clear_colour;
    reg stopped = 1, frame_finished = 0, overflow = 0;
    reg [31:0] dropped_near = 0, dropped_far = 0;
    wire texture_slot_write, fog_table_write;
    wire [7:0] texture_slot_number, fog_table_row, lamp_table_row;
    wire [41:0] texture_slot_description;
    wire [15:0] fog_table_word, lamp_table_word;
    wire [1:0] lamp_table_write;
    wire [23:0] fog_colour;
    wire [2:0] perf_select;
    integer slot_pulses = 0;
    always @(posedge clk) if (texture_slot_write) slot_pulses = slot_pulses + 1;

    gpu_registers regs (
        .clk(clk), .reset(reset), .write(write), .read(read), .offset(offset), .wdata(wdata), .rdata(rdata),
        .list_waiting(list_waiting), .next_list(next_list), .list_taken(list_taken),
        .switch_wanted(switch_wanted), .switch_done(switch_done),
        .front_begin(front_begin), .draw_begin(draw_begin), .near(near), .clear_colour(clear_colour),
        .stopped(stopped), .frame_finished(frame_finished), .overflow(overflow),
        .dropped_near(dropped_near), .dropped_too_far_out(dropped_far),
        .fog_table_write(fog_table_write), .fog_table_row(fog_table_row), .fog_table_word(fog_table_word),
        .lamp_table_write(lamp_table_write), .lamp_table_row(lamp_table_row), .lamp_table_word(lamp_table_word),
        .texture_slot_write(texture_slot_write), .texture_slot_number(texture_slot_number),
        .texture_slot_description(texture_slot_description), .fog_colour(fog_colour), .perf_select(perf_select),
        .perf_value(32'd0));

    integer failures = 0;
    task check(input [8*60-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask
    task tick; begin @(posedge clk); #1; end endtask
    task wr(input [5:0] o, input [31:0] d); begin offset = o; wdata = d; write = 1; tick; write = 0; end endtask
    task rd(input [5:0] o); begin offset = o; read = 1; tick; read = 0; end endtask
    task take; begin list_taken = 1; tick; list_taken = 0; end endtask     // gpu takes the oldest list

    integer i;
    initial begin
        $display("gpu_registers test: the GPU's front door");
        tick; tick; reset = 0; tick;

        // test 1 doorbell and its queue
        $display("DOORBELL:");
        check("nothing waiting at first", list_waiting, 0);
        wr(5'h00, 32'h1000_0000);                         // 256 MB
        check("one ring: a list is waiting", list_waiting, 1);
        check("  at 256 MB (in bursts: 256 MB / 32)", next_list, 32'h1000_0000 / 32);
        rd(5'h00);  check("reads: stopped, 1 waiting (binary 0010)", rdata, 2);
        take;
        check("taken: nothing waiting", list_waiting, 0);
        stopped = 0;  rd(5'h00);  check("reads: running, 0 waiting (binary 0001)", rdata, 1);
        for (i = 1; i <= 5; i = i + 1) wr(5'h00, 32'h1000_0000 + i * 32'h100);    // 5 rings but only 4 fit
        rd(5'h00);  check("5 rings: 4 waiting, running (binary 1001)", rdata, 9);
        rd(5'h08);  check("  the 5th was dropped: ERRORS bit 3 (binary 1000)", rdata, 8);
        check("  first out is the first rung", next_list, (32'h1000_0000 + 32'h100) / 32);
        take;  check("  then the second", next_list, (32'h1000_0000 + 32'h200) / 32);
        // ring and take on the same tick, count stays and order is kept
        offset = 5'h00;  wdata = 32'h2000_0000;  write = 1;  list_taken = 1;  tick;  write = 0;  list_taken = 0;
        rd(5'h00);  check("  a ring and a take together: still 3 waiting (binary 0111)", rdata, 7);
        check("  next is the third", next_list, (32'h1000_0000 + 32'h300) / 32);
        take; take;  check("  ... and the newest comes last", next_list, 32'h2000_0000 / 32);
        take;  check("  all taken", list_waiting, 0);
        wr(5'h08, 32'd8);  rd(5'h08);  check("  ERRORS bit 3 cleared", rdata, 0);

        // test 2 switch
        $display("SWITCH:");
        rd(5'h18);  check("not asked at first", rdata, 0);
        wr(5'h18, 32'd1);  check("asked: the GPU sees it", switch_wanted, 1);
        rd(5'h18);  check("  and it reads 1", rdata, 1);
        switch_done = 1; tick; switch_done = 0;
        check("the GPU did it: cleared", switch_wanted, 0);

        // test 3 frames drawn
        for (i = 0; i < 7; i = i + 1) begin frame_finished = 1; tick; frame_finished = 0; tick; end
        rd(5'h04);
        $display("FRAMES_DRAWN:");
        check("after 7 frames", rdata, 7);

        // test 4 errors
        overflow = 1; tick; overflow = 0;
        dropped_near = 3; tick; tick;
        rd(5'h08);
        $display("ERRORS:");
        check("overflow + too close set (binary 011)", rdata, 3);
        wr(5'h08, 32'd1);                                  // clear bit 0
        rd(5'h08);  check("bit 0 cleared (binary 010)", rdata, 2);
        // new error on the same tick as a clear of everything, the new one must stay
        offset = 5'h08;  wdata = 32'd15;  write = 1;  dropped_far = 1;  tick;  write = 0;
        tick;
        rd(5'h08);  check("a new error on the same tick as a clear stays (binary 100)", rdata, 4);

        // test 5 settings, the gpu only gets a new value at its next frame start
        $display("Settings:");
        rd(5'h0C);  check("NEAR_LIMIT starts at 0.3 (19,661)", rdata, 19661);
        rd(5'h10);  check("BACKGROUND starts dark navy (0xFF1C2230)", rdata, 32'hFF1C_2230);
        wr(5'h0C, 32'd32768);   rd(5'h0C);  check("NEAR_LIMIT written 0.5: reads back at once", rdata, 32768);
        check("  the GPU still uses 0.3 (mid-frame)", near, 19661);
        draw_begin = 1; tick; draw_begin = 0;
        check("  a back-half start doesn't change near", near, 19661);
        front_begin = 1; tick; front_begin = 0;
        check("  the next front-half frame start: the GPU uses 0.5", near, 32768);
        wr(5'h10, 32'hFF80_C0FF);  rd(5'h10);  check("BACKGROUND written: reads back at once", rdata, 32'hFF80_C0FF);
        check("  the GPU still uses the old one (mid-frame)", clear_colour, 32'hFF1C_2230);
        front_begin = 1; tick; front_begin = 0;
        check("  a front-half start doesn't change the background", clear_colour, 32'hFF1C_2230);
        draw_begin = 1; tick; draw_begin = 0;
        check("  the next back-half start: the GPU uses the new one", clear_colour, 32'hFF80_C0FF);
        wr(5'h14, 32'h1234_5678);  rd(5'h14);  check("MISC keeps what's written", rdata, 32'h1234_5678);
        check("nothing queued by other writes", list_waiting, 0);

        // test 6 texture slots and table writes
        $display("TEXTURE_BASE, TEXTURE_SLOT:");
        check("no slot pulse from anything so far", slot_pulses, 0);
        wr(6'h2C, 32'h0246_8AC0);                          // texture starts at byte 0x02468AC0
        check("TEXTURE_BASE alone: no slot pulse", texture_slot_write, 0);
        rd(6'h2C);  check("TEXTURE_BASE reads back", rdata, 32'h0246_8AC0);
        // slot 200, 1024 wide 8 high, ARGB 4444, bilinear, u mirrors, v clamps, texture only, cutout
        wr(6'h30, 32'd200 | (10 << 8) | (3 << 12) | (2 << 16) | (1 << 18) | (2 << 19) | (1 << 21) | (1 << 23) | (1 << 24));
        check("TEXTURE_SLOT: a pulse", texture_slot_write, 1);
        check("  for slot 200", texture_slot_number, 200);
        check("  the start in bursts (bytes / 32)", texture_slot_description[24:0], 32'h0246_8AC0 / 32);
        check("  log2 width 10", texture_slot_description[28:25], 10);
        check("  log2 height 3", texture_slot_description[32:29], 3);
        check("  format 2", texture_slot_description[34:33], 2);
        check("  bilinear", texture_slot_description[35], 1);
        check("  u mirrors (2)", texture_slot_description[37:36], 2);
        check("  v clamps (1)", texture_slot_description[39:38], 1);
        check("  texture only", texture_slot_description[40], 1);
        check("  cutout", texture_slot_description[41], 1);
        tick;  check("the pulse lasts one clock", texture_slot_write, 0);
        // second slot, same base, everything else 0 or small
        wr(6'h30, 32'd7 | (3 << 8) | (3 << 12));
        check("another slot (7): the base is kept", texture_slot_description[24:0], 32'h0246_8AC0 / 32);
        check("  8 x 8, format 0, nearest, repeat, x colour, no cutout", texture_slot_description[41:25], (3 << 4) | 3);
        check("  slot 7", texture_slot_number, 7);
        tick;
        wr(6'h2C, 32'h0000_0020);  wr(6'h30, 32'd255 | (6 << 8) | (6 << 12));       // base and slot on back to back clocks
        check("base then slot on the next clock: the new base (1 burst)", texture_slot_description[24:0], 1);
        tick;
        check("3 slot pulses in all", slot_pulses, 3);
        wr(6'h24, {8'd0, 8'd77, 16'hBEEF});
        check("FOG_TABLE: a pulse, row 77, word BEEF", {fog_table_write, fog_table_row, fog_table_word}, {1'b1, 8'd77, 16'hBEEF});
        check("  no lamp or slot pulse", {lamp_table_write, texture_slot_write}, 0);
        wr(6'h28, {7'd0, 1'b1, 8'd5, 16'h1234});
        check("LAMP_TABLE with bit 24: lamp 1's pulse, row 5, word 1234", {lamp_table_write, lamp_table_row, lamp_table_word}, {2'b10, 8'd5, 16'h1234});
        wr(6'h28, {7'd0, 1'b0, 8'd6, 16'h4321});
        check("LAMP_TABLE without: lamp 0's pulse", lamp_table_write, 1);
        tick;
        check("still 3 slot pulses", slot_pulses, 3);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

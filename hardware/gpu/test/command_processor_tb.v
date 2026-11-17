// command_processor_tb.v
// test for the command processor on its own
// runs two command lists from a pretend memory and checks everything it hands on comes out once, in order
// memory and projection answer after random waits
`timescale 1ns / 1ps

module command_processor_tb;
    parameter SEED = 1;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // the processor
    reg list_waiting = 0;  reg [24:0] next_list = 0;  wire list_taken;
    wire switch_done, stopped;
    wire mem_req;  wire [2:0] mem_cmd;  wire [28:0] mem_addr;
    reg mem_grant = 0, mem_rd_valid = 0;  reg [255:0] mem_rd_data = 0;
    wire matrix_valid, tri_valid, lights_valid, lamps_valid;
    reg matrix_ready = 0, tri_ready = 0, lights_ready = 0, lamps_ready = 0;
    wire [415:0] matrix;  wire [287:0] corners;  wire [95:0] colour;  wire [3:0] switches;  wire [89:0] normals;
    wire lit, fogged, textured;  wire [7:0] texture_slot;  wire [191:0] uvs;
    wire [311:0] lights;  wire [255:0] lamps;
    wire front_begin, front_end, draw_start, buffer_begin, buffer_end;
    wire [24:0] front_cards, front_shelves, draw_cards, draw_shelves, frame_buffer;
    reg front_done = 0, draw_done = 0, draw_busy = 0, tv_frame = 0;

    command_processor #(.CARDS_A(25'd100), .SHELVES_A(25'd200), .CARDS_B(25'd300), .SHELVES_B(25'd400)) cp (
        .clk(clk), .reset(reset),
        .list_waiting(list_waiting), .next_list(next_list), .list_taken(list_taken),
        .switch_wanted(1'b0), .switch_done(switch_done), .stopped(stopped),
        .mem_req(mem_req), .mem_cmd(mem_cmd), .mem_addr(mem_addr), .mem_grant(mem_grant),
        .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data),
        .matrix_valid(matrix_valid), .matrix_ready(matrix_ready), .matrix(matrix),
        .tri_valid(tri_valid), .tri_ready(tri_ready), .corners(corners), .colour(colour), .switches(switches),
        .normals(normals), .lit(lit), .fogged(fogged), .textured(textured), .texture_slot(texture_slot), .uvs(uvs),
        .lights_valid(lights_valid), .lights_ready(lights_ready), .lights(lights),
        .lamps_valid(lamps_valid), .lamps_ready(lamps_ready), .lamps(lamps),
        .front_begin(front_begin), .front_cards(front_cards), .front_shelves(front_shelves),
        .front_end(front_end), .front_done(front_done),
        .draw_start(draw_start), .draw_cards(draw_cards), .draw_shelves(draw_shelves), .frame_buffer(frame_buffer),
        .draw_done(draw_done), .draw_busy(draw_busy),
        .buffer_ok(1'b1), .buffer_start(25'd777), .buffer_begin(buffer_begin), .buffer_end(buffer_end),
        .tv_frame(tv_frame));

    // pretend memory, grants at random, answers in order after a random wait
    reg [255:0] memory [0:4095];
    reg [24:0] asked [0:63];  integer due [0:63];
    integer ask_in = 0, ask_out = 0, now = 0, last_due = 0, seed = SEED;
    integer wait_for;
    always @(posedge clk) begin
        now = now + 1;
        if (mem_req && mem_grant) begin
            wait_for = 3 + ($random(seed) & 7);
            last_due = (now + wait_for > last_due) ? now + wait_for : last_due + 1;
            asked[ask_in % 64] = mem_addr[27:3];  due[ask_in % 64] = last_due;
            ask_in = ask_in + 1;
        end
        if (ask_in != ask_out && now >= due[ask_out % 64]) begin
            mem_rd_valid <= 1'b1;  mem_rd_data <= memory[asked[ask_out % 64] & 4095];
            ask_out = ask_out + 1;
        end else
            mem_rd_valid <= 1'b0;
        mem_grant <= ($random(seed) & 3) != 0;
        // pretend projection, ready at random
        matrix_ready <= ($random(seed) & 3) == 0;
        tri_ready <= ($random(seed) & 3) != 0;
        lights_ready <= ($random(seed) & 7) == 0;
        lamps_ready <= ($random(seed) & 7) == 0;
        tv_frame <= (now % 50) == 0;
    end

    // frame rhythm, front half finishes a bit after end frame, a draw takes a while
    integer front_count = -1, draw_count = -1;
    always @(posedge clk) begin
        front_done <= 1'b0;  draw_done <= 1'b0;
        if (front_end) front_count = 5 + ($random(seed) & 15);
        if (front_count == 0) front_done <= 1'b1;
        if (front_count >= 0) front_count = front_count - 1;
        if (draw_start) begin draw_busy <= 1'b1; draw_count = 30; end
        if (draw_count == 0) begin draw_done <= 1'b1; draw_busy <= 1'b0; end
        if (draw_count >= 0) draw_count = draw_count - 1;
    end

    // compare what comes out with the expected events as they happen
    reg [703:0] events [0:255];
    integer n_events = 0, seen = 0, wrong = 0, triangles = 0, textured_count = 0, draws = 0, fronts = 0, stops = 0;
    reg started = 0, stopped_before = 1;
    reg [703:0] got, want, mask;
    task event_out(input [3:0] what, input [699:0] numbers, input [699:0] counted);
        begin
            got = {what, numbers};  want = events[seen];  mask = {4'hF, counted};
            if (seen >= n_events) begin
                if (wrong < 8) $display("  WRONG: an extra event (kind %h) after the last one", what);
                wrong = wrong + 1;
            end else if ((got & mask) !== (want & mask)) begin
                if (wrong < 8) $display("  WRONG event %0d: kind %h (wanted %h); the first differing bit: %0d", seen, what,
                                        want[703:700], first_difference((got ^ want) & mask));
                wrong = wrong + 1;
            end
            seen = seen + 1;
        end
    endtask
    function integer first_difference(input [703:0] d);
        integer b;
        begin
            first_difference = -1;
            for (b = 703; b >= 0; b = b - 1) if (d[b]) first_difference = b;
        end
    endfunction

    localparam [699:0] ALL = {700{1'b1}};
    always @(posedge clk) if (!reset) begin
        if (list_taken) started = 1;
        if (matrix_valid && matrix_ready) event_out(4'h1, {284'd0, matrix}, {284'd0, {416{1'b1}}});
        if (tri_valid && tri_ready) begin
            triangles = triangles + 1;  textured_count = textured_count + textured;
            // slot and uvs only count for a textured triangle
            event_out(4'h2, {19'd0, uvs, texture_slot, textured, normals, fogged, lit, switches, colour, corners},
                      textured ? {19'd0, {681{1'b1}}} : {219'd0, {481{1'b1}}});
        end
        if (lights_valid && lights_ready) event_out(4'h6, {388'd0, lights}, {388'd0, {312{1'b1}}});
        if (lamps_valid && lamps_ready) event_out(4'h7, {444'd0, lamps}, {444'd0, {256{1'b1}}});
        if (front_end) event_out(4'h3, 700'd0, ALL);
        if (started && stopped && !stopped_before) begin event_out(4'hF, 700'd0, ALL); stops = stops + 1; end
        stopped_before = stopped;
        if (draw_start) draws = draws + 1;
        if (front_begin) fronts = fronts + 1;
    end

    integer failures = 0, i, ticks;
    task check(input [8*64-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    initial begin
        for (i = 0; i < 4096; i = i + 1) memory[i] = 256'd0;
        for (i = 0; i < 256; i = i + 1) events[i] = {704{1'bx}};
        $readmemh("build/cp_unit/cp_memory.hex", memory);
        $readmemh("build/cp_unit/cp_events.hex", events);
        while (n_events < 256 && events[n_events] !== {704{1'bx}}) n_events = n_events + 1;
        $display("command processor test: %0d events expected (random waits: seed %0d)", n_events, SEED);
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);
        list_waiting = 1;  next_list = 25'd64;
        while (!list_taken) @(posedge clk);
        @(posedge clk);  list_waiting = 0;
        // first list runs to its stop then ring the second list
        ticks = 0;
        while (stops < 1 && ticks < 200000) begin @(posedge clk); ticks = ticks + 1; end
        repeat (20) @(posedge clk);
        list_waiting = 1;  next_list = 25'd3000;
        while (!list_taken && ticks < 200000) begin @(posedge clk); ticks = ticks + 1; end
        @(posedge clk);  list_waiting = 0;
        while (stops < 2 && ticks < 400000) begin @(posedge clk); ticks = ticks + 1; end
        repeat (100) @(posedge clk);

        check("events seen", seen, n_events);
        check("wrong events", wrong, 0);
        check("both lists reached their STOP", stops, 2);
        check("triangles handed on", triangles, 22);
        check("  of them textured", textured_count, 9);
        check("draws started (one per END FRAME)", draws, 3);
        check("front-half frames begun (the first + one after each draw)", fronts, 4);
        if (failures == 0) $display("PASSED: every check is right");
        else $display("FAILED: %0d checks wrong", failures);
        $finish;
    end
endmodule

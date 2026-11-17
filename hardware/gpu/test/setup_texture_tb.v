// setup_texture_tb.v
// test for setups texture planes
// triangles go through setup with random waits and every card it writes is saved for a python script to check
// here we check the card count, order, no card written twice and nothing dropped
`timescale 1ns / 1ps

module setup_texture_tb;
    parameter SEED = 1;
    localparam MAX = 512;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    reg frame_begin = 0, frame_end = 0;
    wire frame_flushed, setup_busy, setup_overflow;
    wire [16:0] cards_made;
    wire [31:0] dropped_back, dropped_flat, dropped_off_screen;
    reg tri_valid = 0;  wire tri_ready;
    reg [511:0] now = 0;                              // the triangle being offered
    wire card_valid;  reg card_ready = 0;
    wire [16:0] card_number;
    wire [15:0] box_left, box_right, box_top, box_bottom;
    wire mem_req;  reg mem_grant = 0;
    wire [2:0] mem_cmd;  wire [28:0] mem_addr;  wire [255:0] mem_wr_data;  wire [31:0] mem_wr_mask;

    setup make_cards (
        .clk(clk), .reset(reset),
        .frame_begin(frame_begin), .cards_start(25'd0), .frame_end(frame_end),
        .frame_flushed(frame_flushed), .busy(setup_busy), .overflow(setup_overflow), .cards_made(cards_made),
        .dropped_back(dropped_back), .dropped_flat(dropped_flat), .dropped_off_screen(dropped_off_screen),
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .x0(now[15:0]), .y0(now[31:16]), .x1(now[47:32]), .y1(now[63:48]), .x2(now[79:64]), .y2(now[95:80]),
        .z0(now[127:96]), .z1(now[159:128]), .z2(now[191:160]),
        .colour(now[287:192]), .switches({1'b0, now[290:288]}), .fogged(1'b0),
        .textured(now[292]), .texture_slot(now[300:293]), .uvs(now[492:301]),
        .card_valid(card_valid), .card_ready(card_ready), .card_number(card_number),
        .box_left(box_left), .box_right(box_right), .box_top(box_top), .box_bottom(box_bottom),
        .mem_req(mem_req), .mem_cmd(mem_cmd), .mem_addr(mem_addr), .mem_wr_data(mem_wr_data),
        .mem_wr_mask(mem_wr_mask), .mem_grant(mem_grant));

    // pretend memory and binnings side, both take things after random waits
    reg [255:0] memory [0:MAX*8-1];
    reg written [0:MAX*8-1];
    integer seed = SEED, bursts = 0, numbers = 0, out_of_order = 0, twice = 0, i;
    always @(posedge clk) begin
        if (mem_req && mem_grant) begin
            if (written[mem_addr[27:3]]) twice = twice + 1;
            memory[mem_addr[27:3]] = mem_wr_data;  written[mem_addr[27:3]] = 1;
            bursts = bursts + 1;
        end
        if (card_valid && card_ready) begin
            if (card_number != numbers) out_of_order = out_of_order + 1;
            numbers = numbers + 1;
        end
        mem_grant <= ($random(seed) & 3) != 0;
        card_ready <= ($random(seed) & 3) == 0;
    end

    reg [511:0] triangles [0:MAX-1];
    integer n_triangles = 0, failures = 0, file, ticks;
    task check(input [8*56-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    initial begin
        for (i = 0; i < MAX; i = i + 1) triangles[i] = {512{1'bx}};
        for (i = 0; i < MAX * 8; i = i + 1) begin written[i] = 0; memory[i] = 256'd0; end
        $readmemh("build/setup_texture/triangles.hex", triangles);
        // end of the list is the first entry the file didnt fill, x in icarus and 0 in verilator
        while (n_triangles < MAX && triangles[n_triangles] !== {512{1'bx}} && triangles[n_triangles] !== 512'd0)
            n_triangles = n_triangles + 1;
        $display("setup texture test: %0d triangles (random waits: seed %0d)", n_triangles, SEED);
        repeat (3) @(posedge clk);
        #1 reset = 0;
        @(posedge clk); #1 frame_begin = 1;
        @(posedge clk); #1 frame_begin = 0;
        for (i = 0; i < n_triangles; i = i + 1) begin
            now = triangles[i];  tri_valid = 1;
            @(posedge clk);
            while (!tri_ready) @(posedge clk);
            #1;
            if (($random(seed) & 3) == 0) begin              // a pause now and then
                tri_valid = 0;
                repeat (1 + ($random(seed) & 7)) @(posedge clk);
                #1;
            end
        end
        tri_valid = 0;
        @(posedge clk); #1 frame_end = 1;
        @(posedge clk); #1 frame_end = 0;
        ticks = 0;
        while (!frame_flushed && ticks < 200000) begin @(posedge clk); ticks = ticks + 1; end
        repeat (20) @(posedge clk);

        // save the cards for the python check
        file = $fopen("build/setup_texture/cards.hex", "w");
        for (i = 0; i < cards_made; i = i + 1)
            $fdisplay(file, "%064x%064x%064x%064x", memory[i * 8 + 3], memory[i * 8 + 2], memory[i * 8 + 1], memory[i * 8]);
        $fclose(file);

        check("the frame was flushed", ticks < 200000, 1);
        check("cards made (every triangle is a kept one)", cards_made, n_triangles);
        check("card numbers handed to binning", numbers, n_triangles);
        check("card numbers out of order", out_of_order, 0);
        check("bursts written twice", twice, 0);
        check("triangles dropped", dropped_back + dropped_flat + dropped_off_screen, 0);
        check("overflow", setup_overflow, 0);
        if (failures == 0) $display("PASSED: every check is right");
        else $display("FAILED: %0d checks wrong", failures);
        $finish;
    end
endmodule

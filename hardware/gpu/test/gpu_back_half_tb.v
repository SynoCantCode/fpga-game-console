// gpu_back_half_tb.v
// tests the gpus whole back half, cards and shelves in fake DDR3 to pixels in the frame buffer
// the test plays the front half and a model draws the same triangles to compare every pixel
`timescale 1ns / 1ps

module gpu_back_half_tb;

    localparam FRAME_BURSTS = 115_200;               // 1280 x 720 / 8
    localparam SHELF_BURSTS = 16;
    localparam SHELVES_START = FRAME_BURSTS;          // frame buffer at 0 then the shelves then the cards
    localparam CARDS_START = SHELVES_START + 460 * SHELF_BURSTS;
    localparam MAX_CARDS = 256;
    localparam BLOCKS = CARDS_START + MAX_CARDS * 8;
    localparam TRIANGLES = 60;                        // per frame

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // the back half
    reg frame_start = 0;
    reg [31:0] clear_colour = 32'hFFAC_C6D6;
    wire frame_done, busy;
    wire [4:0] req, grant, rd_valid;
    wire [2:0] gpu_cmd;  wire [28:0] gpu_addr;  wire [255:0] gpu_data, rd_data;  wire [31:0] gpu_mask;

    gpu_back_half #(.SHELF_BURSTS(SHELF_BURSTS)) gpu (
        .fog_colour(24'd0), .fog_table_write(1'b0), .fog_table_row(8'd0), .fog_table_word(16'd0),
        .clk(clk), .reset(reset),
        .frame_start(frame_start), .shelves_start(SHELVES_START[24:0]), .cards_start(CARDS_START[24:0]),
        .frame_buffer_start(25'd0), .clear_colour(clear_colour), .frame_done(frame_done), .busy(busy),
        .mem_req(req[2]), .mem_cmd(gpu_cmd), .mem_addr(gpu_addr), .mem_wr_data(gpu_data), .mem_wr_mask(gpu_mask),
        .mem_grant(grant[2]), .mem_rd_valid(rd_valid[2]), .mem_rd_data(rd_data));

    // arbiter, fake memory and a display on port 1
    wire calibrated, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, mem_rd_valid;
    wire [2:0] cmd;  wire [28:0] addr;  wire [255:0] wr_data, mem_rd_data;  wire [31:0] wr_data_mask;

    reg display_req = 0;  reg [24:0] display_burst = 0;  integer display_wait = 0;
    always @(posedge clk) begin
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
        .clk(clk), .reset(reset), .req(req),
        .port_cmd({3'b001, 3'b001, gpu_cmd, 3'b001, 3'b001}),
        .port_addr({29'd0, 29'd0, gpu_addr, {1'b0, display_burst, 3'b000}, 29'd0}),
        .port_wr_data({256'd0, 256'd0, gpu_data, 256'd0, 256'd0}),
        .port_wr_mask({32'd0, 32'd0, gpu_mask, 32'd0, 32'd0}),
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

    // the model, whole screen with SPP samples per pixel
    localparam SPP = 2;                                          // 2x aa
    reg [31:0] model_colour [0:1280*720*SPP-1];
    reg [31:0] model_depth  [0:1280*720*SPP-1];

    // sample points in 1/16 pixel from the pixel center
    function integer sample_dx(input integer sm);
        sample_dx = (sm == 0) ? -4 : 4;
    endfunction
    function integer sample_dy(input integer sm);
        sample_dy = (sm == 0) ? -4 : 4;
    endfunction

    // the pixel the write-out should send, the average of its samples
    function [31:0] model_pixel(input integer x, input integer y);
        integer ch, sm, sum;
        begin
            for (ch = 0; ch < 4; ch = ch + 1) begin
                sum = SPP / 2;
                for (sm = 0; sm < SPP; sm = sm + 1) sum = sum + ((model_colour[(y * 1280 + x) * SPP + sm] >> (ch * 8)) & 255);
                model_pixel[ch * 8 +: 8] = sum / SPP;
            end
        end
    endfunction

    // the front half, done by the test
    function integer edge_at(input integer xi, input integer yi, input integer xj, input integer yj,
                             input integer px, input integer py);
        edge_at = (xj - xi) * (py - yi) - (yj - yi) * (px - xi);
    endfunction
    function integer floor16(input integer v);
        floor16 = (v >= 0) ? v / 16 : -((-v + 15) / 16);
    endfunction

    integer shelf_count [0:459];
    integer shelf_entry [0:459][0:126];
    integer cards_made;

    // one triangle, makes its card, bins it and the model draws it
    task front_half_triangle(input integer x0, input integer y0, input integer x1, input integer y1,
                             input integer x2, input integer y2,
                             input [31:0] z0, input signed [31:0] za, input signed [31:0] zb,
                             input [31:0] colour, input [2:0] switches);
        integer vx [0:2];
        integer vy [0:2];
        integer area, t, left, right, top, bottom, tx, ty, n, x, y, sm, at, dz;
        integer c [0:2];
        integer a [0:2];
        integer b [0:2];
        reg [511:0] card;
        reg signed [63:0] k0, k1, k2;
        reg [31:0] pz;
        begin
            vx[0] = x0; vy[0] = y0; vx[1] = x1; vy[1] = y1; vx[2] = x2; vy[2] = y2;
            area = edge_at(vx[0], vy[0], vx[1], vy[1], vx[2], vy[2]);
            if (area < 0) begin
                t = vx[1]; vx[1] = vx[2]; vx[2] = t;  t = vy[1]; vy[1] = vy[2]; vy[2] = t;  area = -area;
            end
            left = floor16(vx[0]); right = left; top = floor16(vy[0]); bottom = top;
            for (t = 1; t < 3; t = t + 1) begin
                if (floor16(vx[t]) < left) left = floor16(vx[t]);
                if (floor16(vx[t]) > right) right = floor16(vx[t]);
                if (floor16(vy[t]) < top) top = floor16(vy[t]);
                if (floor16(vy[t]) > bottom) bottom = floor16(vy[t]);
            end
            if (left < 0) left = 0;  if (top < 0) top = 0;
            if (right > 1279) right = 1279;  if (bottom > 719) bottom = 719;
            if (area > 0 && left <= right && top <= bottom && cards_made < MAX_CARDS) begin
                // setups job, each edge value at pixel 0 0 center and its steps per pixel
                for (t = 0; t < 3; t = t + 1) begin
                    c[t] = edge_at(vx[(t + 1) % 3], vy[(t + 1) % 3], vx[(t + 2) % 3], vy[(t + 2) % 3], 8, 8);
                    a[t] = -(vy[(t + 2) % 3] - vy[(t + 1) % 3]) * 16;
                    b[t] =  (vx[(t + 2) % 3] - vx[(t + 1) % 3]) * 16;
                end
                card = 0;
                for (t = 0; t < 3; t = t + 1) begin
                    card[t * 88 +: 40] = c[t];  card[t * 88 + 40 +: 24] = a[t];  card[t * 88 + 64 +: 24] = b[t];
                end
                card[264 +: 32] = z0;  card[296 +: 32] = za;  card[328 +: 32] = zb;
                card[360 +: 16] = left;  card[376 +: 16] = right;  card[392 +: 16] = top;  card[408 +: 16] = bottom;
                card[424 +: 32] = colour;
                card[456 +: 8] = {4'b0001, 1'b0, switches};      // slot A used plus the 3 switches
                n = cards_made;  cards_made = cards_made + 1;
                memory.memory[CARDS_START + n * 8]     = card[255:0];
                memory.memory[CARDS_START + n * 8 + 1] = card[511:256];
                // binnings job, card number onto the shelf of every tile its box touches
                for (ty = top / 32; ty <= bottom / 32; ty = ty + 1)
                    for (tx = left / 64; tx <= right / 64; tx = tx + 1) begin
                        shelf_entry[ty * 20 + tx][shelf_count[ty * 20 + tx]] = n;
                        shelf_count[ty * 20 + tx] = shelf_count[ty * 20 + tx] + 1;
                    end
                // model draws it at each sample point
                for (y = top; y <= bottom; y = y + 1)
                    for (x = left; x <= right; x = x + 1)
                        for (sm = 0; sm < SPP; sm = sm + 1) begin
                            k0 = c[0] + a[0] * x + b[0] * y + (a[0] * sample_dx(sm) + b[0] * sample_dy(sm)) / 16;
                            k1 = c[1] + a[1] * x + b[1] * y + (a[1] * sample_dx(sm) + b[1] * sample_dy(sm)) / 16;
                            k2 = c[2] + a[2] * x + b[2] * y + (a[2] * sample_dx(sm) + b[2] * sample_dy(sm)) / 16;
                            dz = (za * sample_dx(sm) + zb * sample_dy(sm) + 8) >>> 4;    // signed so >>> keeps the sign
                            pz = z0 + za * x + zb * y + dz;
                            at = (y * 1280 + x) * SPP + sm;
                            if (k0 >= 0 && k1 >= 0 && k2 >= 0 && (!switches[0] || pz > model_depth[at])) begin
                                if (switches[2]) model_colour[at] = colour;
                                if (switches[1]) model_depth[at] = pz;
                            end
                        end
            end
        end
    endtask

    // write every tiles shelf into the fake memory, word 0 is the count
    task write_shelves;
        integer s, w, burst;
        reg [255:0] word;
        for (s = 0; s < 460; s = s + 1)
            for (burst = 0; burst < SHELF_BURSTS; burst = burst + 1) begin
                word = 0;
                for (w = 0; w < 8; w = w + 1) begin
                    if (burst == 0 && w == 0) word[31:0] = shelf_count[s];
                    else if (burst * 8 + w - 1 < shelf_count[s]) word[w * 32 +: 32] = shelf_entry[s][burst * 8 + w - 1];
                end
                memory.memory[SHELVES_START + s * SHELF_BURSTS + burst] = word;
            end
    endtask

    // fresh frame, empty shelves, no cards, model back to the background
    task new_frame;
        integer i;
        begin
            for (i = 0; i < 460; i = i + 1) shelf_count[i] = 0;
            cards_made = 0;
            for (i = 0; i < 1280 * 720 * SPP; i = i + 1) begin model_colour[i] = clear_colour; model_depth[i] = 0; end
        end
    endtask

    // random triangles, a few big, many small, some reaching off the screen
    task make_random_triangles;
        integer n, cx, cy, size;
        reg [2:0] sw;
        for (n = 0; n < TRIANGLES; n = n + 1) begin
            size = (n < 4) ? 700 : (n < 25) ? 160 : 30;
            cx = ($urandom % 1400) - 60;  cy = ($urandom % 840) - 60;
            sw = {($urandom % 6) != 0, ($urandom % 4) != 0, ($urandom % 5) != 0};   // color write, depth write, depth test
            front_half_triangle(
                (cx + ($urandom % (2 * size)) - size) * 16 + $urandom % 16, (cy + ($urandom % (2 * size)) - size) * 16 + $urandom % 16,
                (cx + ($urandom % (2 * size)) - size) * 16 + $urandom % 16, (cy + ($urandom % (2 * size)) - size) * 16 + $urandom % 16,
                (cx + ($urandom % (2 * size)) - size) * 16 + $urandom % 16, (cy + ($urandom % (2 * size)) - size) * 16 + $urandom % 16,
                $urandom, ($urandom % 2001) - 1000, ($urandom % 2001) - 1000, $urandom, sw);
        end
    endtask

    // compare the whole frame buffer with the model
    task compare_frame;
        integer x, y;
        reg [255:0] w;
        for (y = 0; y < 720; y = y + 1)
            for (x = 0; x < 1280; x = x + 1) begin
                w = memory.memory[y * 160 + x / 8];
                if (w[(x % 8) * 32 +: 32] !== model_pixel(x, y)) begin
                    if (wrong < 5) $display("        wrong pixel (%0d, %0d): %h, expected %h", x, y,
                                            w[(x % 8) * 32 +: 32], model_pixel(x, y));
                    wrong = wrong + 1;
                end
            end
    endtask

    task draw_frame;
        integer started;
        begin
            frame_start = 1; tick; frame_start = 0;
            started = $time;
            while (!frame_done) tick;
            $display("  (the frame took %0d clocks = %0d.%02d ms at 100 MHz)", ($time - started) / 10,
                     ($time - started) / 1_000_000, (($time - started) / 10_000) % 100);
        end
    endtask

    integer f, used, i, sx, sy;

    // time the crowded tile and how much of it the raster was drawing
    integer crowded_start = 0, crowded_clocks = 0, crowded_drawing = 0;
    reg [7:0] last_index = 0;
    reg in_crowded = 0;
    always @(posedge clk) begin
        if (gpu.controller.tile_index == 105 && last_index == 104) begin
            crowded_start = $time;  crowded_drawing = 0;  in_crowded = 1;
        end
        if (in_crowded && gpu.raster.walking) crowded_drawing = crowded_drawing + 1;
        if (in_crowded && gpu.swap) begin
            crowded_clocks = ($time - crowded_start) / 10;  in_crowded = 0;
        end
        last_index = gpu.controller.tile_index;
    end

    initial begin
        $display("gpu_back_half test: cards + shelves in DDR3 -> the whole back half -> the frame buffer");
        @(negedge clk);
        tick; reset = 0;
        wait (calibrated); tick;

        // two frames of random triangles
        for (f = 1; f <= 2; f = f + 1) begin
            new_frame;
            make_random_triangles;
            write_shelves;
            used = 0; for (i = 0; i < 460; i = i + 1) used = used + shelf_count[i];
            $display("Frame %0d: %0d triangles, %0d card numbers on the shelves:", f, cards_made, used);
            draw_frame;
            wrong = 0; compare_frame;
            check("pixels different from the model (of 921,600)", wrong, 0);
        end

        // third frame, many tiny triangles in one tile
        new_frame;
        for (i = 0; i < 120; i = i + 1) begin
            sx = (320 + ($urandom % 58)) * 16;  sy = (320 + ($urandom % 58)) * 16;     // corners close together
            front_half_triangle(sx, sy, sx + 16 + $urandom % 80, sy + $urandom % 40, sx + $urandom % 40, sy + 16 + $urandom % 80,
                                $urandom, 0, 0, $urandom, 3'b111);
        end
        write_shelves;
        $display("Frame 3: %0d tiny triangles, all in one tile:", cards_made);
        draw_frame;
        wrong = 0; compare_frame;
        check("pixels different from the model (of 921,600)", wrong, 0);
        $display("  (the crowded tile took %0d clocks; the raster was drawing for %0d of them (%0d%%), waiting the rest.",
                 crowded_clocks, crowded_drawing, 100 * crowded_drawing / crowded_clocks);
        $display("   It can't finish before the tile before it is written out: about 2,200 clocks)");

        $display("The memory controller's view:");
        check("handshake mistakes", memory.protocol_mistakes, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

    // watchdog
    initial begin
        #400_000_000;
        $display("  FAIL  stuck: controller state %0d, tile %0d, time %0d ns", gpu.controller.state,
                 gpu.controller.tile_index, $time);
        $finish;
    end

endmodule

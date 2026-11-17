// setup_tb.v
// tests setup.v together with binning.v, triangles in, cards and shelves out to memory
// the test works out every card itself and compares what landed in memory
`timescale 1ns / 1ps

module setup_tb;

    localparam SHELF_BURSTS = 16;
    localparam SHELVES_START = 0;
    localparam CARDS_START = 460 * SHELF_BURSTS;
    localparam MAX_TEST_CARDS = 400;
    localparam BLOCKS = CARDS_START + MAX_TEST_CARDS * 8;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // setup
    reg frame_begin = 0, frame_end = 0;
    wire frame_flushed, setup_busy, setup_overflow;
    wire [16:0] cards_made;
    wire [31:0] dropped_back, dropped_flat, dropped_off_screen;
    reg tri_valid = 0;  wire tri_ready;
    reg signed [15:0] x0 = 0, y0 = 0, x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    reg [31:0] z0 = 0, z1 = 0, z2 = 0, colour = 0;
    reg [95:0] colours = 0;                          // corner k color at bits 32 x k
    reg [3:0] switches = 0;
    wire card_valid, card_ready;
    wire [16:0] card_number;
    wire [15:0] box_left, box_right, box_top, box_bottom;
    wire [4:0] req, grant, rd_valid;
    wire [2:0] setup_cmd, bin_cmd;  wire [28:0] setup_addr, bin_addr;
    wire [255:0] setup_data, bin_data, rd_data;  wire [31:0] setup_mask, bin_mask;

    setup make_cards (
        .fogged(1'b0), .textured(1'b0), .texture_slot(8'd0), .uvs(192'd0),
        .clk(clk), .reset(reset),
        .frame_begin(frame_begin), .cards_start(CARDS_START[24:0]), .frame_end(frame_end),
        .frame_flushed(frame_flushed), .busy(setup_busy), .overflow(setup_overflow), .cards_made(cards_made),
        .dropped_back(dropped_back), .dropped_flat(dropped_flat), .dropped_off_screen(dropped_off_screen),
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2), .z0(z0), .z1(z1), .z2(z2),
        .colour(colours), .switches(switches),              // 3 corner colors, flat = all the same
        .card_valid(card_valid), .card_ready(card_ready), .card_number(card_number),
        .box_left(box_left), .box_right(box_right), .box_top(box_top), .box_bottom(box_bottom),
        .mem_req(req[3]), .mem_cmd(setup_cmd), .mem_addr(setup_addr), .mem_wr_data(setup_data),
        .mem_wr_mask(setup_mask), .mem_grant(grant[3]));

    // binning
    reg bin_begin = 0, bin_end = 0;
    wire bin_finished, bin_busy, bin_overflow;

    binning #(.SHELF_BURSTS(SHELF_BURSTS)) shelves (
        .clk(clk), .reset(reset),
        .frame_begin(bin_begin), .shelves_start(SHELVES_START[24:0]), .frame_end(bin_end),
        .frame_finished(bin_finished), .busy(bin_busy), .overflow(bin_overflow),
        .card_valid(card_valid), .card_ready(card_ready), .card_number(card_number),
        .box_left(box_left), .box_right(box_right), .box_top(box_top), .box_bottom(box_bottom),
        .mem_req(req[2]), .mem_cmd(bin_cmd), .mem_addr(bin_addr), .mem_wr_data(bin_data), .mem_wr_mask(bin_mask),
        .mem_grant(grant[2]));

    // arbiter, fake memory and a display competing for it
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
    assign req[0] = 0;  assign req[1] = display_req;  assign req[4] = 0;

    memory_arbiter #(.PORTS(5)) arbiter (
        .clk(clk), .reset(reset), .req(req),
        .port_cmd({3'b001, setup_cmd, bin_cmd, 3'b001, 3'b001}),
        .port_addr({29'd0, setup_addr, bin_addr, {1'b0, display_burst, 3'b000}, 29'd0}),
        .port_wr_data({256'd0, setup_data, bin_data, 256'd0, 256'd0}),
        .port_wr_mask({32'd0, setup_mask, bin_mask, 32'd0, 32'd0}),
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

    function integer floor16(input integer v);
        floor16 = (v >= 0) ? v / 16 : -((-v + 15) / 16);
    endfunction
    // the line from corner i to corner j at pixel 0 0 center
    function integer line_c(input integer ix, input integer iy, input integer jx, input integer jy);
        line_c = (jx - ix) * (8 - iy) - (jy - iy) * (8 - ix);
    endfunction

    // what the test expects
    reg [511:0] want_card [0:MAX_TEST_CARDS-1];
    reg signed [63:0] want_plane [0:MAX_TEST_CARDS-1][0:2];   // exact A and B, checked to within 2
    integer corner_x [0:MAX_TEST_CARDS-1][0:2];                // corners as sent, for checking C
    integer corner_y [0:MAX_TEST_CARDS-1][0:2];
    reg [31:0] corner_z [0:MAX_TEST_CARDS-1][0:2];
    integer want_cards = 0, want_back = 0, want_flat = 0, want_off = 0;
    // smooth triangles, 4 color planes
    reg want_smooth [0:MAX_TEST_CARDS-1];
    reg signed [63:0] want_cplane [0:MAX_TEST_CARDS-1][0:3][0:1];   // exact A and B per channel
    reg [31:0] corner_p [0:MAX_TEST_CARDS-1][0:3][0:2];             // P per channel at each corner
    integer smooth_sent = 0;
    // P = corner color channel x q / 512
    function [31:0] p_value(input [31:0] q, input [31:0] corner_colour, input integer h);
        reg [40:0] product;
        begin
            product = corner_colour[h * 8 +: 8] * q;
            p_value = product[40:9];
        end
    endfunction
    integer shelf_count [0:459];
    integer shelf_entry [0:459][0:126];

    // work out the card for this triangle, or that its dropped
    task expect_triangle(input integer ax, input integer ay, input integer bx, input integer by,
                         input integer cx, input integer cy, input [31:0] za, input [31:0] zb, input [31:0] zc,
                         input [95:0] cols, input [3:0] sw);
        integer vx [0:2];
        integer vy [0:2];
        integer area, t, left, right, top, bottom, k, i, j, tx, ty;
        reg [511:0] c;
        reg signed [127:0] sum_a, sum_b, sum_c, zz;
        reg smooth;
        integer h;
        begin
            smooth = !(cols[31:0] == cols[63:32] && cols[63:32] == cols[95:64]);
            vx[0] = ax; vy[0] = ay; vx[1] = bx; vy[1] = by; vx[2] = cx; vy[2] = cy;
            area = (vx[1] - vx[0]) * (vy[2] - vy[0]) - (vy[1] - vy[0]) * (vx[2] - vx[0]);
            left = floor16(vx[0]); right = left; top = floor16(vy[0]); bottom = top;
            for (t = 1; t < 3; t = t + 1) begin
                if (floor16(vx[t]) < left) left = floor16(vx[t]);
                if (floor16(vx[t]) > right) right = floor16(vx[t]);
                if (floor16(vy[t]) < top) top = floor16(vy[t]);
                if (floor16(vy[t]) > bottom) bottom = floor16(vy[t]);
            end
            if (area == 0) want_flat = want_flat + 1;
            else if (area < 0 && sw[3]) want_back = want_back + 1;
            else if (right < 0 || left > 1279 || bottom < 0 || top > 719) want_off = want_off + 1;
            else begin
                // the exact plane, lines as given before any flip
                sum_a = 0; sum_b = 0; sum_c = 0;
                for (k = 0; k < 3; k = k + 1) begin
                    i = (k + 1) % 3;  j = (k + 2) % 3;
                    zz = (k == 0) ? za : (k == 1) ? zb : zc;
                    sum_a = sum_a + (vy[i] - vy[j]) * 16 * zz;
                    sum_b = sum_b + (vx[j] - vx[i]) * 16 * zz;
                    sum_c = sum_c + line_c(vx[i], vy[i], vx[j], vy[j]) * zz;
                end
                want_plane[want_cards][0] = rounded(sum_a, area);
                want_plane[want_cards][1] = rounded(sum_b, area);
                // smooth, same plane math per color channel with P
                want_smooth[want_cards] = smooth;
                if (smooth) for (h = 0; h < 4; h = h + 1) begin
                    sum_a = 0; sum_b = 0;
                    for (k = 0; k < 3; k = k + 1) begin
                        i = (k + 1) % 3;  j = (k + 2) % 3;
                        zz = p_value((k == 0) ? za : (k == 1) ? zb : zc, cols[k * 32 +: 32], h);
                        corner_p[want_cards][h][k] = zz[31:0];
                        sum_a = sum_a + (vy[i] - vy[j]) * 16 * zz;
                        sum_b = sum_b + (vx[j] - vx[i]) * 16 * zz;
                    end
                    want_cplane[want_cards][h][0] = rounded(sum_a, area);
                    want_cplane[want_cards][h][1] = rounded(sum_b, area);
                end
                for (k = 0; k < 3; k = k + 1) begin
                    corner_x[want_cards][k] = vx[k];  corner_y[want_cards][k] = vy[k];
                    corner_z[want_cards][k] = (k == 0) ? za : (k == 1) ? zb : zc;
                end
                if (area < 0) begin                       // kept back face, swap corners 1 and 2
                    t = vx[1]; vx[1] = vx[2]; vx[2] = t;  t = vy[1]; vy[1] = vy[2]; vy[2] = t;
                end
                if (left < 0) left = 0;  if (top < 0) top = 0;
                if (right > 1279) right = 1279;  if (bottom > 719) bottom = 719;
                c = 0;
                for (k = 0; k < 3; k = k + 1) begin
                    i = (k + 1) % 3;  j = (k + 2) % 3;
                    c[k * 88 +: 40] = line_c(vx[i], vy[i], vx[j], vy[j]);
                    c[k * 88 + 40 +: 24] = (vy[i] - vy[j]) * 16;
                    c[k * 88 + 64 +: 24] = (vx[j] - vx[i]) * 16;
                    // top left rule
                    if (!((vy[i] - vy[j]) > 0 || ((vy[i] - vy[j]) == 0 && (vx[j] - vx[i]) > 0)))
                        c[k * 88 +: 40] = line_c(vx[i], vy[i], vx[j], vy[j]) - 1;
                end
                c[360 +: 16] = left;  c[376 +: 16] = right;  c[392 +: 16] = top;  c[408 +: 16] = bottom;
                c[424 +: 32] = cols[31:0];
                c[456 +: 8] = {smooth ? 4'b0011 : 4'b0001, 1'b0, sw[2:0]};      // slots used, A and also B if smooth
                want_card[want_cards] = c;
                for (ty = top / 32; ty <= bottom / 32; ty = ty + 1)
                    for (tx = left / 64; tx <= right / 64; tx = tx + 1) begin
                        shelf_entry[ty * 20 + tx][shelf_count[ty * 20 + tx]] = want_cards;
                        shelf_count[ty * 20 + tx] = shelf_count[ty * 20 + tx] + 1;
                    end
                want_cards = want_cards + 1;
            end
        end
    endtask

    // send a triangle to setup back to back
    task send_triangle(input integer ax, input integer ay, input integer bx, input integer by,
                       input integer cx, input integer cy, input [3:0] sw, input smooth);
        begin
            x0 = ax; y0 = ay; x1 = bx; y1 = by; x2 = cx; y2 = cy;
            z0 = $urandom; z1 = $urandom; z2 = $urandom; colour = $urandom; switches = sw;
            // flat = one color for all 3 corners, smooth = 3 different ones
            colours = smooth ? {$urandom, $urandom, colour} : {3{colour}};
            if (smooth) smooth_sent = smooth_sent + 1;
            expect_triangle(ax, ay, bx, by, cx, cy, z0, z1, z2, colours, sw);
            tri_valid = 1;
            while (!tri_ready) tick;
            tick;
        end
    endtask

    integer n, cx, cy, size, kind, t, k, word, plane_wrong, worst, h, smooth_wrong, smooth_checked, too_steep, smooth_steep;
    // a plane whose exact A or B doesnt fit in 32 bits
    function steep(input signed [63:0] a, input signed [63:0] b);
        steep = (a >= 64'sd2147483648 || a < -64'sd2147483648 || b >= 64'sd2147483648 || b < -64'sd2147483648);
    endfunction
    reg [511:0] got;
    reg signed [31:0] diff;
    reg signed [63:0] allowed;
    reg signed [63:0] plane_at;
    localparam [511:0] PLANE_BITS = {152'd0, 96'hFFFFFFFF_FFFFFFFF_FFFFFFFF, 264'd0};

    // n / d rounded to nearest, d can be negative
    function signed [63:0] rounded(input signed [127:0] num, input integer den);
        reg signed [127:0] d, q;
        begin
            d = den;
            if (d < 0) begin d = -d; num = -num; end
            q = (num >= 0) ? (num + d / 2) / d : -((-num + d / 2) / d);
            rounded = q[63:0];
        end
    endfunction
    reg [3:0] sw;
    reg [255:0] burst;

    initial begin
        $display("setup test: corners -> setup -> cards in DDR3, numbers + boxes -> binning -> shelves");
        for (t = 0; t < 460; t = t + 1) shelf_count[t] = 0;
        @(negedge clk);
        tick; reset = 0;
        wait (calibrated); tick;

        frame_begin = 1; bin_begin = 1; tick; frame_begin = 0; bin_begin = 0;

        // 300 random triangles
        for (n = 0; n < 300; n = n + 1) begin
            kind = $urandom % 10;
            size = (kind == 0) ? 600 : (kind < 4) ? 120 : 25;
            cx = ($urandom % 1500) - 110;  cy = ($urandom % 940) - 110;
            sw = {($urandom % 2) == 0, 3'b111};            // half of them hide back faces
            if (n % 37 == 5)                                // flat sliver, three corners in a row
                send_triangle(cx * 16, cy * 16, (cx + 10) * 16, (cy + 5) * 16, (cx + 20) * 16, (cy + 10) * 16, sw, n % 3 == 0);
            else if (n % 41 == 7)                           // completely off the screen
                send_triangle(-900 * 16, 100 * 16, -700 * 16, 120 * 16, -800 * 16, 300 * 16, sw, n % 3 == 0);
            else
                send_triangle((cx + $urandom % (2 * size) - size) * 16 + $urandom % 16,
                              (cy + $urandom % (2 * size) - size) * 16 + $urandom % 16,
                              (cx + $urandom % (2 * size) - size) * 16 + $urandom % 16,
                              (cy + $urandom % (2 * size) - size) * 16 + $urandom % 16,
                              (cx + $urandom % (2 * size) - size) * 16 + $urandom % 16,
                              (cy + $urandom % (2 * size) - size) * 16 + $urandom % 16, sw, n % 3 == 0);
        end
        tri_valid = 0;
        frame_end = 1; tick; frame_end = 0;
        while (!frame_flushed) tick;
        bin_end = 1; tick; bin_end = 0;
        while (!bin_finished) tick;
        repeat (8) tick;   // let the last writes land

        // check every card in memory
        $display("300 triangles in (back faces, slivers and off-screen ones mixed in):");
        check("cards made", cards_made, want_cards);
        wrong = 0;  plane_wrong = 0;  worst = 0;  too_steep = 0;
        for (n = 0; n < want_cards; n = n + 1) begin
            got = {memory.memory[CARDS_START + n * 8 + 1], memory.memory[CARDS_START + n * 8]};
            // everything but the plane must be exact
            if ((got & ~PLANE_BITS) !== want_card[n]) begin
                if (wrong < 3) $display("        card %0d differs", n);
                wrong = wrong + 1;
            end
            // a plane with X bits is wrong
            if (^got[264 +: 96] === 1'bx) begin
                if (plane_wrong < 3) $display("        card %0d: the plane has unknown (X) bits", n);
                plane_wrong = plane_wrong + 1;
            end
            // planes too steep for 32 bits are counted, not checked
            if (steep(want_plane[n][0], want_plane[n][1])) too_steep = too_steep + 1;
            else begin
            // A and B within a small allowance
            for (k = 1; k < 3; k = k + 1) begin
                diff = got[264 + 32 * k +: 32] - want_plane[n][k - 1][31:0];       // card order is C A B
                allowed = 2 + ((want_plane[n][k - 1] < 0 ? -want_plane[n][k - 1] : want_plane[n][k - 1]) >>> 30);
                if (diff > allowed || diff < -allowed) begin
                    if (plane_wrong < 3) $display("        card %0d plane value %0d off by %0d", n, k, diff);
                    plane_wrong = plane_wrong + 1;
                end
            end
            // the plane must give each corners depth, with a rounding allowance
            for (k = 0; k < 3; k = k + 1) begin
                plane_at = $signed(got[264 +: 32])
                         + (($signed(got[296 +: 32]) * (corner_x[n][k] - 8) + $signed(got[328 +: 32]) * (corner_y[n][k] - 8)) >>> 4);
                diff = plane_at[31:0] - corner_z[n][k];
                allowed = 2 + ((corner_x[n][k] > corner_x[n][0] ? corner_x[n][k] - corner_x[n][0] : corner_x[n][0] - corner_x[n][k])
                             + (corner_y[n][k] > corner_y[n][0] ? corner_y[n][k] - corner_y[n][0] : corner_y[n][0] - corner_y[n][k])) / 16;
                if (diff > allowed || diff < -allowed) begin
                    if (plane_wrong < 3) $display("        card %0d: the plane at corner %0d is off by %0d (allowed %0d)", n, k, diff, allowed);
                    plane_wrong = plane_wrong + 1;
                end
                if (diff > worst) worst = diff;  if (-diff > worst) worst = -diff;
            end
            end
        end
        check("cards with a wrong line, box, colour or switch bit", wrong, 0);
        check("distance plane values off by more than allowed", plane_wrong, 0);
        // smooth cards, same checks on each color plane
        smooth_wrong = 0;  smooth_checked = 0;  smooth_steep = 0;
        for (n = 0; n < want_cards; n = n + 1) if (want_smooth[n]) begin
            smooth_checked = smooth_checked + 1;
            got = {memory.memory[CARDS_START + n * 8 + 3], memory.memory[CARDS_START + n * 8 + 2]};
            if (got[511:384] !== 128'd0) smooth_wrong = smooth_wrong + 1;
            for (h = 0; h < 4; h = h + 1) begin
                if (^got[h * 96 +: 96] === 1'bx) begin
                    if (smooth_wrong < 3) $display("        smooth card %0d channel %0d: unknown (X) bits", n, h);
                    smooth_wrong = smooth_wrong + 1;
                end
                if (steep(want_cplane[n][h][0], want_cplane[n][h][1])) smooth_steep = smooth_steep + 1;
                else begin
                for (k = 1; k < 3; k = k + 1) begin
                    diff = got[h * 96 + 32 * k +: 32] - want_cplane[n][h][k - 1][31:0];
                    allowed = 2 + ((want_cplane[n][h][k - 1] < 0 ? -want_cplane[n][h][k - 1] : want_cplane[n][h][k - 1]) >>> 30);
                    if (diff > allowed || diff < -allowed) begin
                        if (smooth_wrong < 3) $display("        smooth card %0d channel %0d plane value %0d off by %0d", n, h, k, diff);
                        smooth_wrong = smooth_wrong + 1;
                    end
                end
                for (k = 0; k < 3; k = k + 1) begin
                    plane_at = $signed(got[h * 96 +: 32])
                             + (($signed(got[h * 96 + 32 +: 32]) * (corner_x[n][k] - 8) + $signed(got[h * 96 + 64 +: 32]) * (corner_y[n][k] - 8)) >>> 4);
                    diff = plane_at[31:0] - corner_p[n][h][k];
                    allowed = 2 + ((corner_x[n][k] > corner_x[n][0] ? corner_x[n][k] - corner_x[n][0] : corner_x[n][0] - corner_x[n][k])
                                 + (corner_y[n][k] > corner_y[n][0] ? corner_y[n][k] - corner_y[n][0] : corner_y[n][0] - corner_y[n][k])) / 16;
                    if (diff > allowed || diff < -allowed) begin
                        if (smooth_wrong < 3) $display("        smooth card %0d channel %0d: at corner %0d off by %0d (allowed %0d)", n, h, k, diff, allowed);
                        smooth_wrong = smooth_wrong + 1;
                    end
                end
                end
            end
        end
        $display("Smooth triangles (every third sent, %0d; %0d kept as cards):", smooth_sent, smooth_checked);
        $display("  (%0d colour planes too steep for a 32-bit slope: not checked)", smooth_steep);
        check("smooth cards checked > 50", smooth_checked > 50, 1);
        check("smooth colour plane values off by more than allowed", smooth_wrong, 0);
        $display("  (the plane's largest miss at a corner: %0d, out of depths up to 4 billion)", worst);
        $display("  (%0d near-slivers with random depths too steep for a 32-bit slope: not checked)", too_steep);

        // the dropped ones
        check("dropped: facing away (with hide back faces on)", dropped_back, want_back);
        check("dropped: flat slivers", dropped_flat, want_flat);
        check("dropped: off the screen", dropped_off_screen, want_off);

        // the shelves
        wrong = 0;
        for (t = 0; t < 460; t = t + 1) begin
            burst = memory.memory[SHELVES_START + t * SHELF_BURSTS];
            if (burst[31:0] !== shelf_count[t]) wrong = wrong + 1;
            for (k = 0; k < shelf_count[t]; k = k + 1) begin
                word = k + 1;
                burst = memory.memory[SHELVES_START + t * SHELF_BURSTS + word / 8];
                if (burst[(word % 8) * 32 +: 32] !== shelf_entry[t][k]) wrong = wrong + 1;
            end
        end
        $display("The shelves binning made from setup's cards:");
        check("wrong counts or numbers", wrong, 0);

        $display("The memory controller's view:");
        check("handshake mistakes", memory.protocol_mistakes, 0);
        check("overflow flags (should stay down)", setup_overflow + bin_overflow, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

    // watchdog
    initial begin
        #100_000_000;
        $display("  FAIL  stuck at time %0d ns", $time);
        $finish;
    end

endmodule

// raster_tb.v
// tests raster.v with the real tile_memory
// the test makes triangles and a plain software rasterizer says what every sample should be
`timescale 1ns / 1ps

module raster_tb;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    // tile_memory
    reg swap = 0;
    reg [31:0] clear_colour = 32'hFF20_3040;
    reg [9:0] out_quad = 0;  reg out_take = 0;
    localparam SLOTS = 8, SPP = 2;                                       // 2x aa, 4 pixels x 2 samples
    wire [SLOTS*32-1:0] out_colour, draw_read_colour, draw_read_depth;   // 32 bits per slot
    wire [9:0] raster_read_quad, draw_write_quad, colour_write_quad;
    wire [SLOTS-1:0] colour_write_enable, depth_write_enable;
    wire [SLOTS*32-1:0] draw_write_colour, draw_write_depth;

    // the test borrows the read port to look at the tile while the raster is idle
    reg checking = 0;  reg [9:0] check_quad = 0;
    wire [9:0] draw_read_quad = checking ? check_quad : raster_read_quad;

    tile_memory tiles (
        .clk(clk), .reset(reset), .swap(swap), .clear_colour(clear_colour),
        .draw_read_quad(draw_read_quad), .draw_read_colour(draw_read_colour), .draw_read_depth(draw_read_depth),
        .draw_write_quad(draw_write_quad), .colour_write_quad(colour_write_quad), .colour_write_enable(colour_write_enable),
        .depth_write_enable(depth_write_enable), .draw_write_colour(draw_write_colour),
        .draw_write_depth(draw_write_depth),
        .out_quad(out_quad), .out_take(out_take), .out_colour(out_colour));

    // the raster
    reg tri_valid = 0;
    wire tri_ready, busy;
    reg [4:0] box_qx0 = 0, box_qx1 = 0, box_qy0 = 0, box_qy1 = 0;
    reg signed [39:0] e0 = 0, e1 = 0, e2 = 0, a0 = 0, a1 = 0, a2 = 0, b0 = 0, b1 = 0, b2 = 0;
    reg [31:0] z = 0;  reg signed [31:0] za = 0, zb = 0;
    reg [31:0] colour = 0;
    reg smooth = 0;                              // smooth shading color planes
    reg [127:0] colour_p = 0, colour_pa = 0, colour_pb = 0;
    reg depth_test = 1, depth_write = 1, colour_write = 1;
    reg [3*SLOTS*28-1:0] slot_edge = 0;          // edge offsets per slot
    reg [SLOTS*32-1:0] slot_depth = 0;           // depth offset per slot

    raster raster (
        .fogged(1'b0), .fog_colour(24'd0), .fog_table_write(1'b0), .fog_table_row(8'd0), .fog_table_word(16'd0),
        .clk(clk), .reset(reset),
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .box_qx0(box_qx0), .box_qx1(box_qx1), .box_qy0(box_qy0), .box_qy1(box_qy1),
        .e0(e0), .e1(e1), .e2(e2), .a0(a0), .a1(a1), .a2(a2), .b0(b0), .b1(b1), .b2(b2),
        .z(z), .za(za), .zb(zb), .colour(colour),
        .depth_test(depth_test), .depth_write(depth_write), .colour_write(colour_write),
        .slot_edge(slot_edge), .slot_depth(slot_depth),
        .textured(1'b0), .texture_slot(8'd0), .texture_shift(5'd0), .texture_steep(1'b0), .tex_u(27'd0), .tex_v(27'd0),
        .tex_ua(27'sd0), .tex_ub(27'sd0), .tex_va(27'sd0), .tex_vb(27'sd0),
        .tex_drawn(), .tex_quad(), .tex_textured(), .tex_slot(), .tex_level(), .tex_pu(), .tex_pv(),
        .smooth(smooth), .colour_p(colour_p), .colour_pa(colour_pa), .colour_pb(colour_pb),
        .busy(busy),
        .draw_read_quad(raster_read_quad), .draw_read_depth(draw_read_depth),
        .draw_write_quad(draw_write_quad), .colour_write_quad(colour_write_quad), .colour_write_enable(colour_write_enable),
        .depth_write_enable(depth_write_enable), .draw_write_colour(draw_write_colour),
        .draw_write_depth(draw_write_depth));

    // the model, one entry per sample
    reg [31:0] model_colour [0:64*64*SPP-1];
    reg [31:0] model_depth  [0:64*64*SPP-1];

    // sample points in 1/16 pixel from the pixel center
    function integer sample_dx(input integer sm);
        sample_dx = (sm == 0) ? -4 : 4;
    endfunction
    function integer sample_dy(input integer sm);
        sample_dy = (sm == 0) ? -4 : 4;
    endfunction
    // a samples depth change from the pixel center
    function integer sample_dz(input integer sm);
        sample_dz = (za * sample_dx(sm) + zb * sample_dy(sm) + 8) >>> 4;
    endfunction

    integer failures = 0, wrong = 0;

    task check(input [8*60-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    task tick;
        begin @(posedge clk); #1; end
    endtask

    // the test does setups job here, corners in 1/16 pixel to raster inputs
    // edge value from corner i to corner j at point px py
    function integer edge_at(input integer xi, input integer yi, input integer xj, input integer yj,
                             input integer px, input integer py);
        edge_at = (xj - xi) * (py - yi) - (yj - yi) * (px - xi);
    endfunction

    function integer floor16(input integer v);          // v / 16 rounded down
        floor16 = (v >= 0) ? v / 16 : -((-v + 15) / 16);
    endfunction

    integer vx [0:2];
    integer vy [0:2];
    reg usable;                                          // 0 = flat or misses the tile

    // work out the edges and box for a triangle, sets usable
    task prepare(input integer x0, input integer y0, input integer x1, input integer y1,
                 input integer x2, input integer y2);
        integer area, t, minx, maxx, miny, maxy, px, py;
        begin
            vx[0] = x0; vy[0] = y0; vx[1] = x1; vy[1] = y1; vx[2] = x2; vy[2] = y2;
            area = edge_at(vx[0], vy[0], vx[1], vy[1], vx[2], vy[2]);
            if (area < 0) begin                          // flip it so inside is positive
                t = vx[1]; vx[1] = vx[2]; vx[2] = t;
                t = vy[1]; vy[1] = vy[2]; vy[2] = t;
                area = -area;
            end
            // box in quads, cut to the tile
            minx = floor16(vx[0]); maxx = minx; miny = floor16(vy[0]); maxy = miny;
            for (t = 1; t < 3; t = t + 1) begin
                if (floor16(vx[t]) < minx) minx = floor16(vx[t]);
                if (floor16(vx[t]) > maxx) maxx = floor16(vx[t]);
                if (floor16(vy[t]) < miny) miny = floor16(vy[t]);
                if (floor16(vy[t]) > maxy) maxy = floor16(vy[t]);
            end
            if (minx < 0) minx = 0;  if (miny < 0) miny = 0;
            if (maxx > 63) maxx = 63;  if (maxy > 31) maxy = 31;     // tile is 64 x 32
            usable = (area > 0) && (minx <= maxx) && (miny <= maxy);
            box_qx0 = minx / 2; box_qx1 = maxx / 2; box_qy0 = miny / 2; box_qy1 = maxy / 2;
            // edge values at the first pixel center and their steps per pixel
            px = box_qx0 * 2 * 16 + 8;  py = box_qy0 * 2 * 16 + 8;
            e0 = edge_at(vx[1], vy[1], vx[2], vy[2], px, py);
            e1 = edge_at(vx[2], vy[2], vx[0], vy[0], px, py);
            e2 = edge_at(vx[0], vy[0], vx[1], vy[1], px, py);
            a0 = -(vy[2] - vy[1]) * 16;  b0 = (vx[2] - vx[1]) * 16;
            a1 = -(vy[0] - vy[2]) * 16;  b1 = (vx[0] - vx[2]) * 16;
            a2 = -(vy[1] - vy[0]) * 16;  b2 = (vx[1] - vx[0]) * 16;
            set_slots;
        end
    endtask

    // each slots offset from the quads top left pixel center
    task set_slots;
        integer t, pix, smp, right, down;
        begin
            for (t = 0; t < SLOTS; t = t + 1) begin
                pix = t / SPP;  smp = t % SPP;  right = pix % 2;  down = pix / 2;
                slot_edge[(0 * SLOTS + t) * 28 +: 28] = right * a0 + down * b0 + (a0 * sample_dx(smp) + b0 * sample_dy(smp)) / 16;
                slot_edge[(1 * SLOTS + t) * 28 +: 28] = right * a1 + down * b1 + (a1 * sample_dx(smp) + b1 * sample_dy(smp)) / 16;
                slot_edge[(2 * SLOTS + t) * 28 +: 28] = right * a2 + down * b2 + (a2 * sample_dx(smp) + b2 * sample_dy(smp)) / 16;
                slot_depth[t * 32 +: 32] = right * za + down * zb + sample_dz(smp);
            end
        end
    endtask

    // model draws the triangle one sample at a time
    task model_draw;
        integer x, y, sm, dx, dy, k0, k1, k2, px, py, at;
        reg [31:0] pz;
        begin
            for (y = box_qy0 * 2; y <= box_qy1 * 2 + 1; y = y + 1)
                for (x = box_qx0 * 2; x <= box_qx1 * 2 + 1; x = x + 1)
                    for (sm = 0; sm < SPP; sm = sm + 1) begin
                        px = x * 16 + 8 + sample_dx(sm);  py = y * 16 + 8 + sample_dy(sm);
                        k0 = edge_at(vx[1], vy[1], vx[2], vy[2], px, py);
                        k1 = edge_at(vx[2], vy[2], vx[0], vy[0], px, py);
                        k2 = edge_at(vx[0], vy[0], vx[1], vy[1], px, py);
                        dx = x - box_qx0 * 2;  dy = y - box_qy0 * 2;
                        pz = z + za * dx + zb * dy + sample_dz(sm);
                        at = (y * 64 + x) * SPP + sm;
                        if (k0 >= 0 && k1 >= 0 && k2 >= 0 && (!depth_test || pz > model_depth[at])) begin
                            if (colour_write) model_colour[at] = smooth ? smooth_colour(x, y) : colour;
                            if (depth_write)  model_depth[at] = pz;
                        end
                    end
        end
    endtask

    // send the triangle to the raster, back_to_back keeps tri_valid up
    integer quads_sent = 0;
    task send(input back_to_back);
        begin
            tri_valid = 1;
            while (!tri_ready) tick;
            tick;                                        // this tick takes it
            if (!back_to_back) tri_valid = 0;
            model_draw;
            quads_sent = quads_sent + (box_qx1 - box_qx0 + 1) * (box_qy1 - box_qy0 + 1);
        end
    endtask

    // after the raster says not busy no more writes should come, watch 20 ticks
    integer late_writes = 0, w_watch;
    task finish_drawing;
        begin
            tri_valid = 0; while (busy) tick;
            for (w_watch = 0; w_watch < 20; w_watch = w_watch + 1) begin
                if (colour_write_enable != 0 || depth_write_enable != 0) late_writes = late_writes + 1;
                tick;
            end
        end
    endtask

    // is this sample point inside the triangle
    function inside_at(input integer x, input integer y, input integer sm);
        integer px, py;
        begin
            px = x * 16 + 8 + sample_dx(sm);  py = y * 16 + 8 + sample_dy(sm);
            inside_at = edge_at(vx[1], vy[1], vx[2], vy[2], px, py) >= 0 && edge_at(vx[2], vy[2], vx[0], vy[0], px, py) >= 0
                        && edge_at(vx[0], vy[0], vx[1], vy[1], px, py) >= 0;
        end
    endfunction
    // model color for a pixel of a smooth triangle
    // q and P are taken at a point inside the triangle, not always the center
    function [31:0] smooth_colour(input integer x, input integer y);
        integer h, qdx, qdy, dx, dy, half_za, half_zb, t, pick, tx, ty;
        reg [31:0] qc, pv, quarter;
        reg signed [32:0] both;
        reg signed [63:0] v;
        begin
            dx = x - box_qx0 * 2;  dy = y - box_qy0 * 2;                        // from the box first pixel
            qdx = (x / 2) * 2 - box_qx0 * 2;  qdy = (y / 2) * 2 - box_qy0 * 2;  // its quads top left pixel
            tx = (x / 2) * 2;  ty = (y / 2) * 2;
            // half step done on its own so the signed shift works
            half_za = za >>> 1;  half_zb = zb >>> 1;
            if (inside_at(tx, ty, 1) && inside_at(tx + 1, ty + 1, 0))
                qc = z + za * qdx + zb * qdy + half_za + half_zb;
            else begin
                pick = 0;
                for (t = SLOTS - 1; t >= 0; t = t - 1)
                    if (inside_at(tx + (t / SPP) % 2, ty + (t / SPP) / 2, t % SPP)) pick = t;
                qc = z + za * (qdx + (pick / SPP) % 2) + zb * (qdy + (pick / SPP) / 2) + sample_dz(pick % SPP);
            end
            for (h = 0; h < 4; h = h + 1) begin
                pv = colour_p[h * 32 +: 32] + $signed(colour_pa[h * 32 +: 32]) * dx + $signed(colour_pb[h * 32 +: 32]) * dy;
                both = $signed(colour_pa[h * 32 +: 32]) + $signed(colour_pb[h * 32 +: 32]);
                quarter = both >>> 2;
                if (!(inside_at(x, y, 0) && inside_at(x, y, 1)))
                    pv = inside_at(x, y, 0) ? pv - quarter : pv + quarter;
                v = ($signed({{32{pv[31]}}, pv}) * 512 + $signed({33'd0, qc[31:1]})) / $signed({32'd0, qc});
                smooth_colour[h * 8 +: 8] = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
            end
        end
    endfunction
    // smooth colors only need to be within 1 per channel
    reg smooth_check = 0;
    function within_1(input [31:0] got, input [31:0] want);
        integer h, d;
        begin
            within_1 = 1;
            for (h = 0; h < 4; h = h + 1) begin
                d = got[h * 8 +: 8] - want[h * 8 +: 8];
                if (d > 1 || d < -1) within_1 = 0;
            end
        end
    endfunction

    // read the whole tile and count samples that differ from the model
    task compare_tile;
        integer q, t, x, y, at;
        begin
            checking = 1;
            for (q = 0; q < 512; q = q + 1) begin
                check_quad = q; tick;
                for (t = 0; t < SLOTS; t = t + 1) begin
                    x = (q % 32) * 2 + (t / SPP) % 2;  y = (q / 32) * 2 + (t / SPP) / 2;
                    at = (y * 64 + x) * SPP + t % SPP;
                    if ((smooth_check ? !within_1(draw_read_colour[t * 32 +: 32], model_colour[at])
                                      : draw_read_colour[t * 32 +: 32] !== model_colour[at]) ||
                        draw_read_depth[t * 32 +: 32] !== model_depth[at]) begin
                        if (wrong < 5) $display("        wrong sample %0d of pixel (%0d, %0d): colour %h depth %h, expected %h %h",
                            t % SPP, x, y, draw_read_colour[t * 32 +: 32], draw_read_depth[t * 32 +: 32],
                            model_colour[at], model_depth[at]);
                        wrong = wrong + 1;
                    end
                end
            end
            checking = 0;
        end
    endtask

    // start a fresh tile, wipe the other side and swap to it
    task fresh_tile;
        integer i;
        begin
            for (i = 0; i < 512; i = i + 1) begin out_quad = i; out_take = 1; tick; end
            out_take = 0;
            swap = 1; tick; swap = 0;
            for (i = 0; i < 64 * 64 * SPP; i = i + 1) begin model_colour[i] = clear_colour; model_depth[i] = 0; end
        end
    endtask

    task set_switches(input t, input dw, input cw);
        begin depth_test = t; depth_write = dw; colour_write = cw; end
    endtask

    integer i, n, coloured, start_clock, clocks, sx, sy;
    integer ex, ey, thin;                                // for the edge-on triangles

    initial begin
        $display("raster test: triangles -> raster -> tile_memory, against a pixel-by-pixel model");
        @(negedge clk);
        tick; reset = 0; tick;
        fresh_tile; fresh_tile;               // wipe both sides

        // test 1 one big triangle with flat depth
        set_switches(1, 1, 1);
        z = 1000; za = 0; zb = 0; colour = 32'hFFFF_0000;
        prepare(5 * 16, 3 * 16, 60 * 16 + 7, 20 * 16 + 3, 18 * 16 + 9, 58 * 16 + 12);
        send(0); finish_drawing;
        wrong = 0; compare_tile;
        coloured = 0; for (i = 0; i < 64 * 64 * SPP; i = i + 1) if (model_colour[i] == 32'hFFFF_0000) coloured = coloured + 1;
        $display("One big triangle (%0d samples inside):", coloured);
        check("samples different from the model", wrong, 0);

        // test 2 depth, three overlapping triangles, the near one must win
        fresh_tile;
        za = 0; zb = 0;
        z = 100; colour = 32'hFF00_00FF; prepare(0, 0, 64 * 16, 0, 0, 64 * 16);             send(0);   // far
        z = 300; colour = 32'hFF00_FF00; prepare(10 * 16, 10 * 16, 60 * 16, 20 * 16, 20 * 16, 60 * 16); send(0);   // near
        z = 200; colour = 32'hFFFF_FF00; prepare(0, 30 * 16, 64 * 16, 30 * 16, 32 * 16, 64 * 16); send(0);   // middle
        finish_drawing;
        wrong = 0; compare_tile;
        $display("Three overlapping triangles sent far, near, middle (depth test):");
        check("samples different from the model", wrong, 0);

        // test 3 tiny triangles back to back on the same few quads
        fresh_tile;
        set_switches(1, 1, 1);
        for (n = 0; n < 400; n = n + 1) begin
            z = 1000 + ($urandom % 2000); za = 0; zb = 0; colour = $urandom;
            prepare(($urandom % 64), ($urandom % 64), 64 + ($urandom % 64), ($urandom % 64), ($urandom % 64), 64 + ($urandom % 64));
            if (usable) send(1);
        end
        finish_drawing;
        wrong = 0; compare_tile;
        $display("400 tiny triangles back to back on the same few quads (the forwarding case):");
        check("samples different from the model", wrong, 0);

        // test 4 the switches
        fresh_tile;
        z = 500; za = 0; zb = 0;
        set_switches(1, 1, 1); colour = 32'hFF11_1111; prepare(0, 0, 64 * 16, 0, 0, 64 * 16); send(0);         // solid
        set_switches(1, 0, 1); z = 900; colour = 32'h8022_2222; prepare(0, 0, 64 * 16, 64 * 16, 0, 64 * 16); send(0); // see-through, color but no depth
        set_switches(1, 1, 1); z = 700; colour = 32'hFF33_3333; prepare(0, 16 * 16, 64 * 16, 16 * 16, 0, 32 * 16); send(0); // behind the see-through one, still drawn
        set_switches(1, 1, 0); z = 950; colour = 32'hFF44_4444; prepare(40 * 16, 0, 64 * 16, 0, 64 * 16, 30 * 16); send(0); // depth only
        set_switches(0, 0, 1); z = 1;   colour = 32'hFF55_5555; prepare(0, 0, 20 * 16, 0, 0, 20 * 16); send(0);         // no depth test
        finish_drawing;
        wrong = 0; compare_tile;
        $display("The switches (see-through, depth only, no depth test):");
        check("samples different from the model", wrong, 0);

        // test 5 random triangles, some reaching outside the tile
        fresh_tile;
        wrong = 0;
        for (n = 0; n < 600; n = n + 1) begin
            z = $urandom; za = ($urandom % 2001) - 1000; zb = ($urandom % 2001) - 1000; colour = $urandom;
            set_switches(($urandom % 5) != 0, ($urandom % 4) != 0, ($urandom % 6) != 0);
            sx = ($urandom % 96) - 16; sy = ($urandom % 96) - 16;
            prepare(sx * 16 + $urandom % 16, sy * 16 + $urandom % 16,
                    (sx + ($urandom % 40) - 20) * 16 + $urandom % 16, (sy + ($urandom % 40) - 20) * 16 + $urandom % 16,
                    (sx + ($urandom % 40) - 20) * 16 + $urandom % 16, (sy + ($urandom % 40) - 20) * 16 + $urandom % 16);
            if (usable) send($urandom % 2);
            if (n % 100 == 99) begin finish_drawing; compare_tile; end
        end
        $display("600 random triangles (random planes and switches, partly outside the tile):");
        check("samples different from the model", wrong, 0);

        // test 6 smooth shading with random color planes
        fresh_tile;
        set_switches(1, 1, 1);
        smooth = 1;  smooth_check = 1;  wrong = 0;
        for (n = 0; n < 40; n = n + 1) begin
            z = 32'h4000_0000 + ($urandom % 32'h1000_0000);  za = ($urandom % 4001) - 2000;  zb = ($urandom % 4001) - 2000;
            for (i = 0; i < 4; i = i + 1) begin
                // channel goes from about c0 to c1 across 64 pixels
                colour_p[i * 32 +: 32] = ($urandom % 256) * (z / 512);
                colour_pa[i * 32 +: 32] = $signed(($urandom % 9) - 4) * (z / 512 / 16);
                colour_pb[i * 32 +: 32] = $signed(($urandom % 9) - 4) * (z / 512 / 16);
            end
            sx = ($urandom % 96) - 16; sy = ($urandom % 64) - 16;
            prepare(sx * 16 + $urandom % 16, sy * 16 + $urandom % 16,
                    (sx + ($urandom % 50) - 25) * 16 + $urandom % 16, (sy + ($urandom % 50) - 25) * 16 + $urandom % 16,
                    (sx + ($urandom % 50) - 25) * 16 + $urandom % 16, (sy + ($urandom % 50) - 25) * 16 + $urandom % 16);
            if (usable) send($urandom % 2);
        end
        finish_drawing;
        compare_tile;
        $display("40 smooth triangles (each channel changing across them; within 1 of P x 512 / q per channel):");
        check("samples different from the model", wrong, 0);

        // test 7 edge-on triangles, slivers under a pixel thin with steep color and depth
        fresh_tile;
        wrong = 0;
        for (n = 0; n < 60; n = n + 1) begin
            // long thin triangle, third corner just off the line
            sx = 4 + $urandom % 40;  sy = 4 + $urandom % 40;
            ex = sx + 6 + $urandom % 14;  ey = sy + ($urandom % 13) - 6;
            thin = 2 + $urandom % 10;
            z = 32'h4000_0000 + ($urandom % 32'h1000_0000);
            // steep across the sliver, gentle along it
            za = ($urandom % 2001) - 1000;  zb = $signed(($urandom % 2) ? 32'sd40_000_000 : -32'sd40_000_000);
            for (i = 0; i < 4; i = i + 1) begin
                colour_p[i * 32 +: 32] = (40 + $urandom % 60) * (z / 512);
                colour_pa[i * 32 +: 32] = $signed(($urandom % 5) - 2) * (z / 512 / 16);
                colour_pb[i * 32 +: 32] = $signed(($urandom % 2) ? 160 : -160) * (z / 512);
            end
            prepare(sx * 16 + $urandom % 16, sy * 16 + $urandom % 16, ex * 16 + $urandom % 16, ey * 16 + $urandom % 16,
                    ((sx + ex) / 2) * 16 + $urandom % 16, ((sy + ey) / 2) * 16 + 8 + thin);
            if (usable) send(0);
        end
        finish_drawing;
        compare_tile;
        $display("60 edge-on smooth triangles (slivers under a pixel thin, steep colour and depth across them):");
        check("samples different from the model", wrong, 0);

        // test 8 flat and smooth mixed, small triangles back to back
        fresh_tile;
        wrong = 0;
        for (n = 0; n < 300; n = n + 1) begin
            smooth = $urandom % 2;
            colour = 32'hFF00_0000 | ($urandom & 32'h00FF_FFFF);
            // near and far triangles in turn
            if (n % 2) begin z = 32'h4000_0000 + ($urandom % 32'h1000_0000);  za = ($urandom % 2001) - 1000;  zb = ($urandom % 2001) - 1000; end
            else       begin z = 32'h0010_0000 + ($urandom % 32'h0080_0000);  za = ($urandom % 41) - 20;      zb = ($urandom % 41) - 20; end
            for (i = 0; i < 4; i = i + 1) begin
                // channel size tiny, middling or full
                case ($urandom % 3)
                    0: colour_p[i * 32 +: 32] = ($urandom % 4) * (z / 512);
                    1: colour_p[i * 32 +: 32] = (60 + $urandom % 60) * (z / 512);
                    default: colour_p[i * 32 +: 32] = (240 + $urandom % 16) * (z / 512);
                endcase
                colour_pa[i * 32 +: 32] = $signed(($urandom % 5) - 2) * (z / 512 / 16);
                colour_pb[i * 32 +: 32] = $signed(($urandom % 5) - 2) * (z / 512 / 16);
                // one in 5 gets a very steep color
                if (n % 5 == 0) colour_pb[i * 32 +: 32] = $signed(($urandom % 2) ? 900 : -900) * (z / 512);
            end
            sx = 4 + $urandom % 52;  sy = 4 + $urandom % 52;
            prepare(sx * 16 + $urandom % 16, sy * 16 + $urandom % 16,
                    (sx + 1 + $urandom % 4) * 16 + $urandom % 16, (sy + ($urandom % 5) - 2) * 16 + $urandom % 16,
                    (sx + ($urandom % 5) - 2) * 16 + $urandom % 16, (sy + 1 + $urandom % 4) * 16 + $urandom % 16);
            if (usable) send(1);
        end
        finish_drawing;
        compare_tile;
        $display("300 small triangles back to back, flat and smooth mixed, colours tiny to full:");
        check("samples different from the model", wrong, 0);
        smooth = 0;  smooth_check = 0;

        // test 9 speed, back to back should be one quad per clock
        fresh_tile;
        set_switches(1, 1, 1);
        quads_sent = 0;
        za = 0; zb = 0; colour = 32'hFF66_6666;
        while (!tri_ready) tick;
        start_clock = $time / 10 + 1;                    // stopwatch starts at the tick that takes the first one
        for (n = 0; n < 50; n = n + 1) begin
            z = 10 + n;
            prepare(($urandom % 48) * 16, ($urandom % 48) * 16, ($urandom % 64) * 16, ($urandom % 64) * 16,
                    ($urandom % 64) * 16, ($urandom % 64) * 16);
            if (usable) send(1);
        end
        tri_valid = 0;
        while (raster.walking) tick;
        clocks = $time / 10 - start_clock;
        $display("Speed, 50 triangles back to back:");
        check("clocks taken minus quads walked (0 = one quad every clock)", clocks - quads_sent, 0);

        $display("After each drawing:");
        check("writes after the raster said it was done (not busy)", late_writes, 0);
        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

    // watchdog
    initial begin
        #200_000_000;
        $display("  FAIL  stuck at time %0d ns", $time);
        $finish;
    end

endmodule

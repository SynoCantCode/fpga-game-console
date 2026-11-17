// card_prep_colour_tb.v
// test for card_preps colour and texture planes, random cards at random tiles
// each value at the start pixel must be C + A*x + B*y and the steps pass through unchanged
`timescale 1ns / 1ps

module card_prep_colour_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg start = 0;
    reg [1023:0] card = 0;
    reg [4:0] tile_x = 0, tile_y = 0;
    wire done, empty;
    wire [4:0] box_qx0, box_qx1, box_qy0, box_qy1;
    wire signed [39:0] e0, e1, e2, a0, a1, a2, b0, b1, b2;
    wire [31:0] z;
    wire signed [31:0] za, zb;
    wire [31:0] colour;
    wire depth_test, depth_write, colour_write;
    wire [3*8*28-1:0] slot_edge;
    wire [8*32-1:0] slot_depth;
    wire smooth;
    wire [127:0] colour_p, colour_pa, colour_pb;
    wire textured, texture_steep;
    wire [7:0] texture_slot;
    wire [4:0] texture_shift;
    wire [26:0] tex_u, tex_v;
    wire signed [26:0] tex_ua, tex_ub, tex_va, tex_vb;
    reg [161:0] planes;
    reg [26:0] want27;
    integer texture_wrong = 0, textured_seen = 0;

    card_prep dut (
        .clk(clk), .start(start), .card(card), .tile_x(tile_x), .tile_y(tile_y), .done(done), .empty(empty),
        .box_qx0(box_qx0), .box_qx1(box_qx1), .box_qy0(box_qy0), .box_qy1(box_qy1),
        .e0(e0), .e1(e1), .e2(e2), .a0(a0), .a1(a1), .a2(a2), .b0(b0), .b1(b1), .b2(b2),
        .z(z), .za(za), .zb(zb), .colour(colour),
        .depth_test(depth_test), .depth_write(depth_write), .colour_write(colour_write),
        .slot_edge(slot_edge), .slot_depth(slot_depth),
        .smooth(smooth), .colour_p(colour_p), .colour_pa(colour_pa), .colour_pb(colour_pb),
        .textured(textured), .texture_slot(texture_slot), .texture_shift(texture_shift), .texture_steep(texture_steep),
        .tex_u(tex_u), .tex_v(tex_v), .tex_ua(tex_ua), .tex_ub(tex_ub), .tex_va(tex_va), .tex_vb(tex_vb)
    );

    integer n, h, failures = 0, checked = 0, wrong = 0, z_wrong = 0, empties = 0, smooth_seen = 0;
    integer left, right, top, bottom, tl, tr, tt, tb, sx, sy;
    reg [31:0] want;
    reg is_smooth;

    task check(input [8*60-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    initial begin
        $display("card_prep colour test: 2,000 random cards with colour planes, at random tiles");
        // going and done have no reset so let them fill with 0s first
        repeat (12) @(posedge clk);
        for (n = 0; n < 2000; n = n + 1) begin
            card = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
                    $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
                    $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
                    $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
            // a box on the screen and a tile near it
            left = $urandom % 1280;  right = left + $urandom % 200;  if (right > 1279) right = 1279;
            top = $urandom % 720;    bottom = top + $urandom % 120;  if (bottom > 719) bottom = 719;
            card[360 +: 16] = left;  card[376 +: 16] = right;  card[392 +: 16] = top;  card[408 +: 16] = bottom;
            is_smooth = ($urandom % 2);
            card[461] = is_smooth;
            tile_x = (left + $urandom % (right - left + 1)) / 64;
            tile_y = (top + $urandom % (bottom - top + 1)) / 32;
            @(negedge clk);  start = 1;  @(negedge clk);  start = 0;
            // === 1 so an unknown done doesnt count
            while (done !== 1'b1) @(negedge clk);
            // start pixel is the box cut to the tile, rounded down to the quad
            tl = (left > tile_x * 64) ? left : tile_x * 64;   tr = (right < tile_x * 64 + 63) ? right : tile_x * 64 + 63;
            tt = (top > tile_y * 32) ? top : tile_y * 32;     tb = (bottom < tile_y * 32 + 31) ? bottom : tile_y * 32 + 31;
            if (empty) begin empties = empties + 1; continue; end
            sx = tl - (tl % 2);  sy = tt - (tt % 2);
            checked = checked + 1;
            if (smooth !== is_smooth) wrong = wrong + 1;
            if (is_smooth) smooth_seen = smooth_seen + 1;
            // check the depth the same way to make sure the start pixel here is right
            want = card[264 +: 32] + $signed(card[296 +: 32]) * sx + $signed(card[328 +: 32]) * sy;
            if (z !== want) z_wrong = z_wrong + 1;
            for (h = 0; h < 4; h = h + 1) begin
                want = card[512 + h * 96 +: 32] + $signed(card[512 + h * 96 + 32 +: 32]) * sx
                     + $signed(card[512 + h * 96 + 64 +: 32]) * sy;
                if (colour_p[h * 32 +: 32] !== want) begin
                    if (wrong < 5) $display("  card %0d channel %0d: %h, want %h (start %0d, %0d)", n, h, colour_p[h * 32 +: 32], want, sx, sy);
                    wrong = wrong + 1;
                end
                if (colour_pa[h * 32 +: 32] !== card[512 + h * 96 + 32 +: 32]) wrong = wrong + 1;
                if (colour_pb[h * 32 +: 32] !== card[512 + h * 96 + 64 +: 32]) wrong = wrong + 1;
            end
            // texture planes {V.B, V.A, V.C, U.B, U.A, U.C} are card bits 478-511 on top of 896-1023
            planes = {card[511:478], card[1023:896]};
            if (card[462]) textured_seen = textured_seen + 1;
            if (textured !== card[462] || texture_slot !== card[471:464] || texture_shift !== card[476:472]
                || texture_steep !== card[477]) texture_wrong = texture_wrong + 1;
            want27 = planes[26:0] + $signed(planes[53:27]) * sx + $signed(planes[80:54]) * sy;
            if (tex_u !== want27) begin
                if (texture_wrong < 5) $display("  card %0d U: %h, want %h (start %0d, %0d)", n, tex_u, want27, sx, sy);
                texture_wrong = texture_wrong + 1;
            end
            want27 = planes[107:81] + $signed(planes[134:108]) * sx + $signed(planes[161:135]) * sy;
            if (tex_v !== want27) texture_wrong = texture_wrong + 1;
            if (tex_ua !== planes[53:27] || tex_ub !== planes[80:54] || tex_va !== planes[134:108]
                || tex_vb !== planes[161:135]) texture_wrong = texture_wrong + 1;
        end
        $display("Results (%0d cards checked, %0d smooth, %0d textured, %0d empty in their tile):", checked, smooth_seen, textured_seen, empties);
        check("cards checked > 1,500", checked > 1500, 1);
        check("depth z at the start pixel wrong (this test's own model)", z_wrong, 0);
        check("colour values, steps or smooth bits wrong", wrong, 0);
        check("texture planes, steps, slot, shift, too steep wrong", texture_wrong, 0);
        check("textured cards > 500", textured_seen > 500, 1);
        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

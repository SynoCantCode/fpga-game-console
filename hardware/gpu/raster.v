// raster.v
// the rasterizer, draws one triangle into tile memory a quad (2x2 pixels) every clock
// only adds, walks the triangles box and tests 2 samples per pixel against the edges and the depth
// also works out each quads colour (smooth shading + fog) and its texture coords

module raster #(
    parameter SLOTS = 8                             // slots per quad, 4 pixels x 2 samples
) (
    input wire clk,
    input wire reset,

    // the triangle, taken on a tick where tri_valid and tri_ready are both 1
    input wire tri_valid,
    output wire tri_ready,
    input wire [4:0] box_qx0, box_qx1,              // the box in quads, first and last column
    input wire [4:0] box_qy0, box_qy1,              // first and last row
    input wire signed [39:0] e0, e1, e2,            // edge values at the boxs first pixel, >= 0 means inside
    input wire signed [39:0] a0, a1, a2,            // change per pixel right
    input wire signed [39:0] b0, b1, b2,            // change per pixel down
    input wire [31:0] z,                            // depth at the first pixel, bigger = closer
    input wire signed [31:0] za, zb,                // change per pixel right / down
    input wire [31:0] colour,                       // 0xAARRGGBB flat colour
    input wire smooth,                              // 1 = smooth shading, use the colour planes
    input wire fogged,                              // 1 = fog this triangle
    input wire [23:0] fog_colour,                   // fog settings, passed to fog.v
    input wire fog_table_write,
    input wire [7:0] fog_table_row,
    input wire [15:0] fog_table_word,
    input wire [127:0] colour_p,                    // colour planes at the first pixel, channel h at h x 32
    input wire [127:0] colour_pa, colour_pb,        // change per pixel right / down
    input wire depth_test,                          // 1 = only draw where closer
    input wire depth_write,                         // 1 = write the new depth
    input wire colour_write,                        // 1 = write the colour
    input wire [3*SLOTS*28-1:0] slot_edge,             // each slots edge offsets, edge k slot t at (k x SLOTS + t) x 28
    input wire [SLOTS*32-1:0] slot_depth,              // each slots depth offset, slot t at t x 32
    // texture stuff from card prep
    input wire textured,                            // 1 = this triangle has a texture
    input wire [7:0] texture_slot,                  // which one
    input wire [4:0] texture_shift,                 // the triangles shift
    input wire texture_steep,                       // too steep, use the smallest mipmap
    input wire [26:0] tex_u, tex_v,                 // U and V planes at the first pixel
    input wire signed [26:0] tex_ua, tex_ub,        // U change per pixel right / down
    input wire signed [26:0] tex_va, tex_vb,        // same for V
    output wire busy,                               // 1 = still drawing, dont swap the tile memory

    // each quads texture coords, a few ticks after its colour write
    output reg [SLOTS-1:0] tex_drawn,               // which slots are drawn
    output reg [9:0] tex_quad,                      // which quad
    output wire tex_textured,                       // 1 = its triangle has a texture
    output wire [7:0] tex_slot,                     // which one
    output wire [3:0] tex_level,                    // mip level
    output wire [4*22-1:0] tex_pu, tex_pv,          // pixel i u and v at [i x 22], signed 1/256 texel

    // to tile_memory, slot t at t x 32
    output wire [9:0] draw_read_quad,
    input wire [SLOTS*32-1:0] draw_read_depth,
    output wire [9:0] draw_write_quad,
    output wire [9:0] colour_write_quad,            // colour writes come later than depth so they have their own quad
    output wire [SLOTS-1:0] colour_write_enable,
    output wire [SLOTS-1:0] depth_write_enable,
    output wire [SLOTS*32-1:0] draw_write_colour,
    output wire [SLOTS*32-1:0] draw_write_depth
);

// the triangle being walked, its steps and settings
reg signed [39:0] step_a [0:2];      // per edge, one pixel right
reg signed [39:0] step_b [0:2];      // per edge, one pixel down
reg signed [31:0] step_za, step_zb;
reg [31:0] tri_colour;
reg tri_smooth;
reg tri_fogged;
reg [127:0] step_ca, step_cb;     // colour plane steps
reg tri_depth_test, tri_depth_write, tri_colour_write;
reg [4:0] first_qx, last_qx, last_qy;
reg [3*SLOTS*28-1:0] tri_slot_edge;     // the slot offsets
reg [SLOTS*32-1:0] tri_slot_depth;
reg tri_textured;
reg signed [26:0] step_ua, step_ub, step_va, step_vb;     // U and V steps
reg [3:0] tri_number;                // this triangles place in the texture list

// stage 1 walk, where we are and the values at this quads top left pixel
reg walking;
reg [4:0] qx, qy;
reg signed [39:0] e_now [0:2];       // edge values at this quad
reg signed [39:0] e_row [0:2];       // edge values at the first quad of this row
reg [31:0] z_now, z_row;
reg [127:0] cp_now, cp_row;          // colour planes
reg [26:0] u_now, u_row;             // U plane
reg [26:0] v_now, v_row;

// kept as ready made bits so last_quad doesnt need two compares
reg at_row_end;                      // qx is the rows last quad
reg on_last_row;                     // qy is the boxs last row
wire last_in_row = at_row_end;
wire last_quad = walking && at_row_end && on_last_row;

// a new triangle can be taken when idle or on the last quad of the current one
assign tri_ready = !walking || last_quad;
wire take = tri_valid && tri_ready;

integer k;
always @(posedge clk) begin
    if (reset) begin
        walking <= 1'b0;
        tri_number <= 4'd0;
    end else if (take) begin
        tri_textured <= textured;
        step_ua <= tex_ua;  step_ub <= tex_ub;  step_va <= tex_va;  step_vb <= tex_vb;
        u_now <= tex_u;  u_row <= tex_u;
        v_now <= tex_v;  v_row <= tex_v;
        tri_number <= tri_number + 4'd1;
        // new triangle, keep its steps and settings and start at the boxs first quad
        step_a[0] <= a0;  step_a[1] <= a1;  step_a[2] <= a2;
        step_b[0] <= b0;  step_b[1] <= b1;  step_b[2] <= b2;
        step_za <= za;  step_zb <= zb;
        tri_colour <= colour;
        tri_smooth <= smooth;  step_ca <= colour_pa;  step_cb <= colour_pb;
        tri_fogged <= fogged;
        tri_depth_test <= depth_test;  tri_depth_write <= depth_write;  tri_colour_write <= colour_write;
        tri_slot_edge <= slot_edge;  tri_slot_depth <= slot_depth;
        first_qx <= box_qx0;  last_qx <= box_qx1;  last_qy <= box_qy1;
        qx <= box_qx0;  qy <= box_qy0;
        at_row_end <= (box_qx0 == box_qx1);
        on_last_row <= (box_qy0 == box_qy1);
        e_now[0] <= e0;  e_now[1] <= e1;  e_now[2] <= e2;
        e_row[0] <= e0;  e_row[1] <= e1;  e_row[2] <= e2;
        z_now <= z;  z_row <= z;
        cp_now <= colour_p;  cp_row <= colour_p;
        walking <= 1'b1;
    end else if (walking) begin
        if (last_quad) begin
            walking <= 1'b0;                         // done
        end else if (last_in_row) begin
            // next row, 2 pixels down from the rows first quad
            qx <= first_qx;
            qy <= qy + 1'b1;
            at_row_end <= (first_qx == last_qx);
            on_last_row <= (qy + 1'b1 == last_qy);
            for (k = 0; k < 3; k = k + 1) begin
                e_row[k] <= e_row[k] + (step_b[k] <<< 1);
                e_now[k] <= e_row[k] + (step_b[k] <<< 1);
            end
            z_row <= z_row + (step_zb <<< 1);
            z_now <= z_row + (step_zb <<< 1);
            for (k = 0; k < 4; k = k + 1) begin
                cp_row[k * 32 +: 32] <= cp_row[k * 32 +: 32] + (step_cb[k * 32 +: 32] << 1);
                cp_now[k * 32 +: 32] <= cp_row[k * 32 +: 32] + (step_cb[k * 32 +: 32] << 1);
            end
            u_row <= u_row + {step_ub[25:0], 1'b0};
            u_now <= u_row + {step_ub[25:0], 1'b0};
            v_row <= v_row + {step_vb[25:0], 1'b0};
            v_now <= v_row + {step_vb[25:0], 1'b0};
        end else begin
            // next quad, 2 pixels right
            qx <= qx + 1'b1;
            at_row_end <= (qx + 1'b1 == last_qx);
            for (k = 0; k < 3; k = k + 1)
                e_now[k] <= e_now[k] + (step_a[k] <<< 1);
            z_now <= z_now + (step_za <<< 1);
            for (k = 0; k < 4; k = k + 1)
                cp_now[k * 32 +: 32] <= cp_now[k * 32 +: 32] + (step_ca[k * 32 +: 32] << 1);
            u_now <= u_now + {step_ua[25:0], 1'b0};
            v_now <= v_now + {step_va[25:0], 1'b0};
        end
    end
end

// each slots own values = the quads values + the slots offsets
wire [SLOTS-1:0] in_triangle;             // 1 = this sample is inside all 3 edges
wire [SLOTS*32-1:0] lane_z;                 // each slots depth

genvar l;
generate
    for (l = 0; l < SLOTS; l = l + 1) begin : slot
        wire signed [39:0] edge0 = e_now[0] + $signed(tri_slot_edge[(0 * SLOTS + l) * 28 +: 28]);
        wire signed [39:0] edge1 = e_now[1] + $signed(tri_slot_edge[(1 * SLOTS + l) * 28 +: 28]);
        wire signed [39:0] edge2 = e_now[2] + $signed(tri_slot_edge[(2 * SLOTS + l) * 28 +: 28]);

        // inside = no sign bit set
        assign in_triangle[l] = !(edge0[39] | edge1[39] | edge2[39]);

        assign lane_z[l * 32 +: 32] = z_now + tri_slot_depth[l * 32 +: 32];
    end
endgenerate

// ask tile_memory for this quads stored depths, they arrive next tick
assign draw_read_quad = {qy, qx};

// registers between walk and load
reg test_valid;
reg [9:0] test_quad;
reg [SLOTS-1:0] test_inside;
reg [SLOTS*32-1:0] test_z;
reg [31:0] test_colour;
reg test_depth_test, test_depth_write, test_colour_write;

always @(posedge clk) begin
    if (reset)
        test_valid <= 1'b0;
    else
        test_valid <= walking;
    test_quad <= {qy, qx};
    test_inside <= in_triangle;
    test_z <= lane_z;
    test_colour <= tri_colour;               // carried along, the next triangle may already be taken
    test_depth_test <= tri_depth_test;
    test_depth_write <= tri_depth_write;
    test_colour_write <= tri_colour_write;
end

// stage 2 load, the stored depths arrive
reg c_valid;
reg [9:0] c_quad;
reg [SLOTS-1:0] c_inside;
reg [SLOTS*32-1:0] c_z;
reg [SLOTS*32-1:0] c_memory;                // the depths from memory
reg [31:0] c_colour;
reg c_depth_test, c_depth_write, c_colour_write;

always @(posedge clk) begin
    c_valid <= reset ? 1'b0 : test_valid;
    c_quad <= test_quad;
    c_inside <= test_inside;
    c_z <= test_z;
    c_memory <= draw_read_depth;
    c_colour <= test_colour;
    c_depth_test <= test_depth_test;
    c_depth_write <= test_depth_write;
    c_colour_write <= test_colour_write;
end

// stage 3 compare
// the last 3 writes werent in memory yet when it was read
// so if one of them was this same quad use its depth instead (forwarding)
reg w_valid;                         // stage 4 registers, declared here for the forwarding
reg [9:0] w_quad;
reg [SLOTS-1:0] w_colour_enable, w_depth_enable;
reg [31:0] w_colour;
reg [SLOTS*32-1:0] w_depth;

reg [9:0] last_write_quad;           // the write from the last tick
reg [SLOTS-1:0] last_depth_written;
reg [SLOTS*32-1:0] last_depth;
reg [9:0] last2_write_quad;          // the write from the tick before that
reg [SLOTS-1:0] last2_depth_written;
reg [SLOTS*32-1:0] last2_depth;

wire [SLOTS-1:0] pass;                    // 1 = this sample gets drawn

generate
    for (l = 0; l < SLOTS; l = l + 1) begin : test
        // do all 4 compares side by side then pick the newest one
        wire from_write = (w_quad == c_quad) && w_depth_enable[l];
        wire from_last  = (last_write_quad == c_quad) && last_depth_written[l];
        wire from_last2 = (last2_write_quad == c_quad) && last2_depth_written[l];
        wire closer_than_write  = c_z[l * 32 +: 32] > w_depth[l * 32 +: 32];
        wire closer_than_last   = c_z[l * 32 +: 32] > last_depth[l * 32 +: 32];
        wire closer_than_last2  = c_z[l * 32 +: 32] > last2_depth[l * 32 +: 32];
        wire closer_than_memory = c_z[l * 32 +: 32] > c_memory[l * 32 +: 32];
        wire closer = from_write ? closer_than_write : from_last ? closer_than_last :
                      from_last2 ? closer_than_last2 : closer_than_memory;

        assign pass[l] = c_inside[l] && (!c_depth_test || closer);
    end
endgenerate

// stage 4 write
always @(posedge clk) begin
    w_valid <= reset ? 1'b0 : c_valid;
    w_quad <= c_quad;
    w_colour_enable <= (!reset && c_valid && c_colour_write) ? pass : {SLOTS{1'b0}};
    w_depth_enable  <= (!reset && c_valid && c_depth_write)  ? pass : {SLOTS{1'b0}};
    w_colour <= c_colour;
    w_depth <= c_z;
    // remember the last 2 writes for forwarding
    last_write_quad <= w_quad;
    last_depth_written <= reset ? {SLOTS{1'b0}} : w_depth_enable;
    last_depth <= w_depth;
    last2_write_quad <= last_write_quad;
    last2_depth_written <= reset ? {SLOTS{1'b0}} : last_depth_written;
    last2_depth <= last_depth;
end

assign draw_write_quad = w_quad;
assign depth_write_enable = w_depth_enable;
assign draw_write_depth = w_depth;

// the colour lane, the delay
// a quads colour write happens COLOUR_DELAY ticks after its depth write
// smooth colours take that long to work out, flat ones go the same way so they stay in order
// plain vectors shifted along, not arrays, so they stay registers
localparam COLOUR_DELAY = 15;
reg [COLOUR_DELAY*SLOTS-1:0] cl_enable;      // station d at [d x SLOTS], 0 = newest
reg [COLOUR_DELAY*10-1:0] cl_quad;
always @(posedge clk) begin
    cl_enable <= reset ? {COLOUR_DELAY*SLOTS{1'b0}} : {cl_enable[(COLOUR_DELAY-1)*SLOTS-1:0], w_colour_enable};
    cl_quad <= {cl_quad[(COLOUR_DELAY-1)*10-1:0], w_quad};
end
assign colour_write_enable = cl_enable[(COLOUR_DELAY-1)*SLOTS +: SLOTS];
assign colour_write_quad = cl_quad[(COLOUR_DELAY-1)*10 +: 10];

// the colour lane, working out the colours
// each channel has a plane P = colour x q / 512 that the walker steps
// colour = P x 512 / q, with one 1/q per quad
// pixel i channel h at [(i x 4 + h) x W]
localparam LANE_RECIP = 11;
localparam NP = 16;                          // 4 pixels x 4 channels
// done on their own so >>> keeps the sign
wire signed [31:0] half_za = step_za >>> 1;
wire signed [31:0] half_zb = step_zb >>> 1;

// lane 0, each pixels P at its centre and q at the quad centre
reg [NP*32-1:0] ln_p;
reg ln_smooth;
reg ln_fogged;
reg [31:0] ln_colour;
reg [31:0] ln_q;
reg [127:0] ln_quarter;                      // each channels (A + B) / 4, a quarter pixel right and down
integer li, lh;
always @(posedge clk) begin
    for (li = 0; li < 4; li = li + 1)
        for (lh = 0; lh < 4; lh = lh + 1)
            ln_p[(li * 4 + lh) * 32 +: 32] <= cp_now[lh * 32 +: 32]
                                             + ((li % 2) ? step_ca[lh * 32 +: 32] : 32'd0)
                                             + ((li / 2) ? step_cb[lh * 32 +: 32] : 32'd0);
    ln_smooth <= tri_smooth;
    ln_fogged <= tri_fogged;
    ln_colour <= tri_colour;
    ln_q <= z_now + half_za + half_zb;                      // half a pixel right and down
    for (lh = 0; lh < 4; lh = lh + 1)
        ln_quarter[lh * 32 +: 32] <= quarter_of(step_ca[lh * 32 +: 32], step_cb[lh * 32 +: 32]);
end
function [31:0] quarter_of(input signed [31:0] right, input signed [31:0] down);
    reg signed [32:0] both;
    begin
        both = right + down;
        quarter_of = both >>> 2;
    end
endfunction

// pick, take the values at a point thats inside the triangle
// with aa a pixel centre can be just outside and the planes go way out of range there
// both samples inside = use the centre, only one inside = move a quarter pixel toward it
wire [2:0] quad_pick = first_inside(test_inside);           // the quads first inside slot
wire centre_inside = test_inside[1] && test_inside[6];      // the two samples nearest the quad centre
reg [NP*32-1:0] lk_p;
reg lk_smooth;
reg lk_fogged;
reg [31:0] lk_colour;
reg [31:0] lk_q;
always @(posedge clk) begin
    for (li = 0; li < 4; li = li + 1)
        for (lh = 0; lh < 4; lh = lh + 1)
            lk_p[(li * 4 + lh) * 32 +: 32] <=
                (test_inside[li * 2] && test_inside[li * 2 + 1]) ? ln_p[(li * 4 + lh) * 32 +: 32]
                : test_inside[li * 2] ? ln_p[(li * 4 + lh) * 32 +: 32] - ln_quarter[lh * 32 +: 32]
                :                       ln_p[(li * 4 + lh) * 32 +: 32] + ln_quarter[lh * 32 +: 32];
    lk_q <= centre_inside ? ln_q : test_z[quad_pick * 32 +: 32];
    lk_smooth <= ln_smooth;
    lk_fogged <= ln_fogged;
    lk_colour <= ln_colour;
end

// where qs highest 1 bit is
// found here too so the scaling doesnt have to wait for the reciprocal
function [5:0] highest_one(input [31:0] number);
    integer b;
    begin
        highest_one = 6'd0;
        for (b = 0; b < 32; b = b + 1)
            if (number[b]) highest_one = b;
    end
endfunction
wire [5:0] lk_exp = highest_one((lk_q == 32'd0) ? 32'd1 : lk_q);

wire [35:0] lane_r;
wire [5:0] lane_p;
reciprocal lane_recip (.clk(clk), .advance(1'b1), .area({4'd0, (lk_q == 32'd0) ? 32'd1 : lk_q}), .r(lane_r), .p(lane_p));

// scale, P x 2^(25 - p) kept to 27 bits, done while the reciprocal works
// how many of the top bits just repeat the sign
function [4:0] redundant_signs(input [31:0] v);
    integer b;
    reg going;
    begin
        redundant_signs = 5'd0;
        going = 1'b1;
        for (b = 30; b >= 0; b = b - 1)
            if (going && v[b] == v[31]) redundant_signs = redundant_signs + 5'd1;
            else going = 1'b0;
    end
endfunction
// scale 1 which way and how far to shift, one copy per value to keep fanout down
(* syn_preserve = 1 *) reg [NP-1:0] s1_left;
(* syn_preserve = 1 *) reg [NP*6-1:0] s1_amount;
reg [NP*32-1:0] s1_p;
reg [NP*5-1:0] s1_n;
reg s1_smooth;
reg [31:0] s1_colour;
always @(posedge clk) begin
    for (li = 0; li < NP; li = li + 1) begin
        s1_left[li] <= (lk_exp <= 6'd25);
        s1_amount[li * 6 +: 6] <= (lk_exp <= 6'd25) ? (6'd25 - lk_exp) : (lk_exp - 6'd25);
        s1_n[li * 5 +: 5] <= redundant_signs(lk_p[li * 32 +: 32]);
    end
    s1_p <= lk_p;
    s1_smooth <= lk_smooth;
    s1_colour <= lk_colour;
end
// scale 2 the shift and whether the result is too big for 27 bits
reg [NP*27-1:0] s2_v;
reg [NP-1:0] s2_over, s2_negative;
reg s2_smooth;
reg [31:0] s2_colour;
always @(posedge clk) begin
    for (li = 0; li < NP; li = li + 1) begin
        // two statements on purpose, in one ?: the >>> would lose its sign
        if (s1_left[li]) s2_v[li * 27 +: 27] <= s1_p[li * 32 +: 27] << s1_amount[li * 6 +: 6];
        else             s2_v[li * 27 +: 27] <= $signed(s1_p[li * 32 +: 32]) >>> s1_amount[li * 6 +: 6];
        s2_over[li] <= s1_left[li] ? ({1'b0, s1_n[li * 5 +: 5]} < 6'd5 + s1_amount[li * 6 +: 6])
                                   : ({2'b00, s1_n[li * 5 +: 5]} + {1'b0, s1_amount[li * 6 +: 6]} < 7'd5);
        s2_negative[li] <= s1_p[li * 32 + 31];
    end
    s2_smooth <= s1_smooth;
    s2_colour <= s1_colour;
end
// scale 3 the clamp
reg [NP*27-1:0] sc_p;
reg sc_smooth;
reg [31:0] sc_colour;
always @(posedge clk) begin
    for (li = 0; li < NP; li = li + 1)
        sc_p[li * 27 +: 27] <= !s2_over[li] ? s2_v[li * 27 +: 27] : s2_negative[li] ? 27'h4000000 : 27'h3FFFFFF;
    sc_smooth <= s2_smooth;
    sc_colour <= s2_colour;
end

// the scaled values wait for the reciprocal, row d at [d x W]
localparam SCALED_WAIT = LANE_RECIP - 3;
reg [SCALED_WAIT*NP*27-1:0] sw_p;
reg [SCALED_WAIT-1:0] sw_smooth;
reg [SCALED_WAIT*32-1:0] sw_colour;
always @(posedge clk) begin
    sw_p <= {sw_p[(SCALED_WAIT-1)*NP*27-1:0], sc_p};
    sw_smooth <= {sw_smooth[SCALED_WAIT-2:0], sc_smooth};
    sw_colour <= {sw_colour[(SCALED_WAIT-1)*32-1:0], sc_colour};
end
wire [NP*27-1:0] sw_p_out = sw_p[(SCALED_WAIT-1)*NP*27 +: NP*27];
wire sw_smooth_out = sw_smooth[SCALED_WAIT-1];
wire [31:0] sw_colour_out = sw_colour[(SCALED_WAIT-1)*32 +: 32];
wire [16:0] lane_r17 = lane_r[35:19];        // top 17 bits of the reciprocal

// times, scaled P x r
reg [NP*45-1:0] tm_v;
reg tm_smooth;
reg [31:0] tm_colour;
always @(posedge clk) begin
    for (li = 0; li < NP; li = li + 1)
        tm_v[li * 45 +: 45] <= $signed(sw_p_out[li * 27 +: 27]) * $signed({1'b0, lane_r17});
    tm_smooth <= sw_smooth_out;
    tm_colour <= sw_colour_out;
end

// round, / 2^32 rounded and clamped to 0-255, or the flat colour
function [7:0] channel_of(input signed [44:0] v);
    reg signed [44:0] w;
    begin
        w = (v + 45'sd2147483648) >>> 32;                         // + 2^31 rounds to nearest
        channel_of = (w < 0) ? 8'd0 : (w > 45'sd255) ? 8'd255 : w[7:0];
    end
endfunction
reg [4*32-1:0] rd_pixel;                     // pixel i colour at [i x 32]
always @(posedge clk)
    for (li = 0; li < 4; li = li + 1)
        rd_pixel[li * 32 +: 32] <= tm_smooth ? {channel_of(tm_v[(li * 4 + 3) * 45 +: 45]), channel_of(tm_v[(li * 4 + 2) * 45 +: 45]),
                                                channel_of(tm_v[(li * 4 + 1) * 45 +: 45]), channel_of(tm_v[(li * 4 + 0) * 45 +: 45])}
                                             : tm_colour;

// fog, q goes in early and the colours come later
wire [4*32-1:0] fg_pixel;
fog #(.WAIT(9)) fog_unit (
    .clk(clk), .q_in(lk_q), .fogged_in(lk_fogged), .pixels_in(rd_pixel), .pixels_out(fg_pixel),
    .fog_colour(fog_colour), .table_write(fog_table_write), .table_row(fog_table_row), .table_word(fog_table_word)
);

// every sample of a pixel gets that pixels colour
localparam SPP = SLOTS / 4;
genvar cs;
generate
    for (cs = 0; cs < SLOTS; cs = cs + 1) begin : colour_slot
        assign draw_write_colour[cs * 32 +: 32] = fg_pixel[(cs / SPP) * 32 +: 32];
    end
endgenerate

// busy while any colour is still in the lane
// loaded from the delay lines next content so its not a tick late
reg lane_busy;
always @(posedge clk) lane_busy <= reset ? 1'b0 : ({cl_enable[(COLOUR_DELAY-1)*SLOTS-1:0], w_colour_enable} != 0);

assign busy = walking || test_valid || c_valid || w_valid || lane_busy;

// the texture lane, each quads place in its texture
// runs beside the colour lane and shares its 1/q
// U and V are taken at a sample point inside the triangle, at the quad centre they could wrap

// the texture list, each triangles numbers are written once here when its taken
// quads only carry the 4 bit place number, the walker may be several triangles ahead by the time theyre needed
(* syn_ramstyle = "distributed_ram" *) reg [185:0] texture_list [0:15];
always @(posedge clk)
    if (take)
        texture_list[tri_number + 4'd1] <= {texture_slot, texture_steep, texture_shift, zb, za, tex_vb, tex_va, tex_ub, tex_ua};

// lane 0, U and V at the quads 8 sample points
// the cards values have 2^26 added, taken off here by flipping the top bit
wire signed [27:0] both_u = step_ua + step_ub;
wire signed [27:0] both_v = step_va + step_vb;
wire [26:0] quarter_u = {both_u[27], both_u[27:2]};          // (A + B) / 4
wire [26:0] quarter_v = {both_v[27], both_v[27:2]};
function [26:0] at_sample(input [26:0] here, input [26:0] right, input [26:0] down, input [26:0] quarter, input [2:0] t);
    reg [26:0] sum;
    begin
        sum = here + (t[1] ? right : 27'd0) + (t[2] ? down : 27'd0) + (t[0] ? quarter : (~quarter + 27'd1));
        at_sample = {!sum[26], sum[25:0]};
    end
endfunction
reg [8*27-1:0] ln_us, ln_vs;         // slot t at [t x 27]
reg ln_textured;
reg [3:0] ln_number;
integer lt;
always @(posedge clk) begin
    for (lt = 0; lt < 8; lt = lt + 1) begin
        ln_us[lt * 27 +: 27] <= at_sample(u_now, step_ua, step_ub, quarter_u, lt[2:0]);
        ln_vs[lt * 27 +: 27] <= at_sample(v_now, step_va, step_vb, quarter_v, lt[2:0]);
    end
    ln_textured <= tri_textured;
    ln_number <= tri_number;
end

// the first slot whose sample is inside the triangle
function [2:0] first_inside(input [7:0] slots_inside);
    integer i;
    begin
        first_inside = 3'd0;                 // nothing inside = nothing drawn so any point will do
        for (i = 7; i >= 0; i = i - 1)
            if (slots_inside[i]) first_inside = i;
    end
endfunction
wire [2:0] ln_pick = quad_pick;              // same pick as the colour lane

// wait for the reciprocal, station d at [d x W]
localparam TEX_WAIT = LANE_RECIP + 1;
reg [TEX_WAIT*27-1:0] lw_us, lw_vs;
reg [TEX_WAIT*3-1:0] lw_pick;
reg [TEX_WAIT-1:0] lw_textured;
reg [TEX_WAIT*4-1:0] lw_number;
always @(posedge clk) begin
    lw_us <= {lw_us[(TEX_WAIT-1)*27-1:0], ln_us[ln_pick * 27 +: 27]};
    lw_vs <= {lw_vs[(TEX_WAIT-1)*27-1:0], ln_vs[ln_pick * 27 +: 27]};
    lw_pick <= {lw_pick[(TEX_WAIT-1)*3-1:0], ln_pick};
    lw_textured <= {lw_textured[TEX_WAIT-2:0], ln_textured};
    lw_number <= {lw_number[(TEX_WAIT-1)*4-1:0], ln_number};
end
// this quads triangle numbers from the list
wire [185:0] listed = texture_list[lw_number[(TEX_WAIT-1)*4 +: 4]];

// the 4 pixels u v and the mip level
texture_coords coords (
    .clk(clk),
    .us(lw_us[(TEX_WAIT-1)*27 +: 27]), .vs(lw_vs[(TEX_WAIT-1)*27 +: 27]), .pick(lw_pick[(TEX_WAIT-1)*3 +: 3]),
    .au(listed[26:0]), .bu(listed[53:27]), .av(listed[80:54]), .bv(listed[107:81]),
    .za(listed[139:108]), .zb(listed[171:140]),
    .r(lane_r[35:19]), .p(lane_p),
    .s(listed[176:172]), .steep(listed[177]),
    .textured(lw_textured[TEX_WAIT-1]), .slot(listed[185:178]),
    .u(tex_pu), .v(tex_pv), .level(tex_level), .textured_out(tex_textured), .slot_out(tex_slot)
);
// the colour writes mask and quad delayed to line up with the coords
reg [5*SLOTS-1:0] tex_drawn_wait;
reg [5*10-1:0] tex_quad_wait;
always @(posedge clk) begin
    tex_drawn_wait <= reset ? {5*SLOTS{1'b0}} : {tex_drawn_wait[4*SLOTS-1:0], colour_write_enable};
    tex_drawn <= reset ? {SLOTS{1'b0}} : tex_drawn_wait[4*SLOTS +: SLOTS];
    tex_quad_wait <= {tex_quad_wait[4*10-1:0], colour_write_quad};
    tex_quad <= tex_quad_wait[4*10 +: 10];
end

endmodule

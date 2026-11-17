// setup.v
// triangle setup, takes a screen space triangle and builds its card
// the card is the 3 edge equations, the depth plane, the box, colour and switches
// then it writes the card to ddr3 and tells binning the card number and box

module setup #(
    parameter [16:0] MAX_CARDS = 17'd131071          // cards per frame
) (
    input wire clk,
    input wire reset,

    // frame control
    input wire frame_begin,                 // pulse, new frame so card numbers start at 0
    input wire [24:0] cards_start,          // where the cards go in ddr3, in bursts
    input wire frame_end,                   // pulse, no more triangles this frame
    output reg frame_flushed,               // pulse, every card is written and handed on
    output wire busy,
    output reg overflow,                    // more than MAX_CARDS triangles, the rest got dropped
    output reg [16:0] cards_made,           // how many cards this frame
    output reg [31:0] dropped_back,         // dropped for facing away
    output reg [31:0] dropped_flat,         // dropped for having no area
    output reg [31:0] dropped_off_screen,   // dropped for missing the screen

    // triangles in from projection
    input wire tri_valid,
    output wire tri_ready,
    input wire signed [15:0] x0, y0,        // corner 0 screen position in 1/16 pixel
    input wire signed [15:0] x1, y1,        // corner 1
    input wire signed [15:0] x2, y2,        // corner 2
    input wire [31:0] z0, z1, z2,           // 1 / distance at each corner, bigger = closer
    input wire [95:0] colour,               // the 3 corner colours 0xAARRGGBB
    input wire [3:0] switches,              // 0 depth test 1 depth write 2 colour write 3 hide back faces
    input wire fogged,                      // 1 = fog it
    input wire textured,                    // 1 = it has a texture
    input wire [7:0] texture_slot,
    input wire [191:0] uvs,                 // u and v for each corner, signed, 1/256 texel

    // to binning
    output reg card_valid,
    input wire card_ready,
    output reg [16:0] card_number,
    output reg [15:0] box_left, box_right, box_top, box_bottom,

    // writing cards to ddr3
    output reg mem_req,
    output wire [2:0] mem_cmd,
    output reg [28:0] mem_addr,
    output wire [255:0] mem_wr_data,
    output wire [31:0] mem_wr_mask,
    input wire mem_grant
);

localparam CMD_WRITE = 3'b000;
assign mem_cmd = CMD_WRITE;
assign mem_wr_mask = 32'd0;              // write all 32 bytes

reg [24:0] cards_area;                   // where this frames cards start

// the whole pipeline moves together
// it only stops when the last stage has a triangle and the card stage is still busy
reg card_full;                           // a card is being written or handed on
localparam LAST = 23;                    // the last stage
reg [LAST:0] full;                       // which stages hold a triangle
wire advance = !(full[LAST] && card_full);
// 4 copies of advance, one per group of stages, to keep the fanout down
(* syn_preserve = 1 *) reg [3:0] last_full_c;
(* syn_preserve = 1 *) reg [3:0] card_full_c;
wire advance_g0 = !(last_full_c[0] && card_full_c[0]);     // stages 0-3
wire advance_g1 = !(last_full_c[1] && card_full_c[1]);     // stages 4-14
wire advance_g2 = !(last_full_c[2] && card_full_c[2]);     // stages 15-19
wire advance_g3 = !(last_full_c[3] && card_full_c[3]);     // stages 20-23

// hold, the triangle being fed in one pass per clock
// pass 0 is depth, 1-4 are the colour channels (only if the corner colours differ), 5 and 6 are texture u and v
// every pass reuses the same plane stages with different corner values
reg h_full;
reg [2:0] h_pass;                        // the pass going in next
reg [2:0] h_last;                        // its last pass, 0 flat 4 smooth 6 textured
reg h_smooth;                            // the 3 corner colours differ
reg h_textured;
reg [7:0] h_slot;
reg signed [21:0] h_v0, h_v1, h_v2;      // the corners v
reg signed [15:0] hx0, hy0, hx1, hy1, hx2, hy2;
reg [31:0] hz0, hz1, hz2;
reg [95:0] h_colour;
reg [3:0] h_switches;
reg h_fogged;
`ifdef SETUP_RATE_DIV
// sim only, take a pass only every Nth clock
reg [2:0] rate_count = 3'd0;
always @(posedge clk) rate_count <= (rate_count == `SETUP_RATE_DIV - 1) ? 3'd0 : rate_count + 1'b1;
wire rate_phase = (rate_count == 3'd0);
`else
wire rate_phase = 1'b1;
`endif
reg texture_ready;                       // the texture values and shift are worked out
// a pass goes into stage 0 this clock, texture passes wait until their numbers are ready
wire issue = h_full && advance && rate_phase && (h_pass < 3'd5 || texture_ready);
wire h_free = !h_full || (issue && h_pass == h_last);       // can take the next triangle
assign tri_ready = h_free;
wire take_in = tri_valid && h_free;
wire take_new = issue;

always @(posedge clk) begin
    if (reset)
        h_full <= 1'b0;
    else if (take_in) begin
        hx0 <= x0;  hy0 <= y0;  hx1 <= x1;  hy1 <= y1;  hx2 <= x2;  hy2 <= y2;
        hz0 <= z0;  hz1 <= z1;  hz2 <= z2;
        h_colour <= colour;  h_switches <= switches;  h_fogged <= fogged;
        h_pass <= 3'd0;
        h_smooth <= !(colour[31:0] == colour[63:32] && colour[63:32] == colour[95:64]);
        h_textured <= textured;
        h_slot <= texture_slot;
        h_v0 <= uvs[53:32];  h_v1 <= uvs[117:96];  h_v2 <= uvs[181:160];
        h_last <= textured ? 3'd6 : (colour[31:0] == colour[63:32] && colour[63:32] == colour[95:64]) ? 3'd0 : 3'd4;
        h_full <= 1'b1;
    end else if (issue) begin
        if (h_pass == h_last) h_full <= 1'b0;
        else if (h_pass == 3'd0 && !h_smooth) h_pass <= 3'd5;       // flat and textured, skip the colour passes
        else h_pass <= h_pass + 1'b1;
    end
end

// the texture numbers, worked out beside the pipeline while the first passes go in
// u and v dont step evenly across the screen in perspective but u x q and v x q do (q = 1 / distance)
// step 1 u x q, step 2 v x q, step 3 how big are they, step 4 add a little margin
// step 5 pick one shift for the triangle, step 6 the 3 U values, step 7 the 3 V values
reg [2:0] texture_step;                  // 0 = nothing to do
reg signed [21:0] tm0, tm1, tm2;         // multiplier inputs, the us then the vs
reg signed [54:0] pu0, pu1, pu2;         // u x q
reg signed [54:0] pv0, pv1, pv2;         // v x q
reg [53:0] texture_size;                 // all 6 sizes ORed together
reg [4:0] texture_shift;
reg [26:0] tu0, tu1, tu2;                // corner values for the U pass
reg [26:0] tv0, tv1, tv2;                // corner values for the V pass

// texture number times q, q is unsigned so give it a 0 sign bit
function signed [54:0] times_q(input signed [21:0] t, input [31:0] q);
    times_q = t * $signed({1'b0, q});
endfunction
// size of a product, its bits below the sign, inverted if negative
function [53:0] size_of(input signed [54:0] p);
    size_of = p[53:0] ^ {54{p[54]}};
endfunction
// how many bits a number takes
function [5:0] length_of(input [53:0] v);
    integer b;
    begin
        length_of = 6'd0;
        for (b = 0; b < 54; b = b + 1)
            if (v[b]) length_of = b + 1;
    end
endfunction
wire [5:0] texture_length = length_of(texture_size);
// a corner value is (product >> s) + 2^26 so its always positive
// the plane stages take unsigned values, the raster takes the 2^26 off again
function [26:0] texture_value(input signed [54:0] product, input [4:0] s);
    reg signed [54:0] moved;
    begin
        moved = product >>> s;
        texture_value = {!moved[26], moved[25:0]};
    end
endfunction
// the 3 shifters do the U values first then the V values
wire v_turn = (texture_step == 3'd7);
wire signed [54:0] shift_in0 = v_turn ? pv0 : pu0;
wire signed [54:0] shift_in1 = v_turn ? pv1 : pu1;
wire signed [54:0] shift_in2 = v_turn ? pv2 : pu2;

always @(posedge clk) begin
    if (reset) begin
        texture_step <= 3'd0;
        texture_ready <= 1'b0;
    end else if (take_in) begin
        tm0 <= uvs[21:0];  tm1 <= uvs[85:64];  tm2 <= uvs[149:128];       // the us
        texture_ready <= 1'b0;
        texture_step <= textured ? 3'd1 : 3'd0;
    end else begin
        case (texture_step)
            3'd1: begin
                pu0 <= times_q(tm0, hz0);  pu1 <= times_q(tm1, hz1);  pu2 <= times_q(tm2, hz2);
                tm0 <= h_v0;  tm1 <= h_v1;  tm2 <= h_v2;                     // the vs next
                texture_step <= 3'd2;
            end
            3'd2: begin
                pv0 <= times_q(tm0, hz0);  pv1 <= times_q(tm1, hz1);  pv2 <= times_q(tm2, hz2);
                texture_step <= 3'd3;
            end
            3'd3: begin
                texture_size <= size_of(pu0) | size_of(pu1) | size_of(pu2) | size_of(pv0) | size_of(pv1) | size_of(pv2);
                texture_step <= 3'd4;
            end
            3'd4: begin
                // margin so rounding in the planes cant make a value wrap
                texture_size <= texture_size + {14'd0, texture_size[53:14]};
                texture_step <= 3'd5;
            end
            3'd5: begin
                texture_shift <= (texture_length > 6'd26) ? texture_length - 6'd26 : 5'd0;
                texture_step <= 3'd6;
            end
            3'd6: begin
                tu0 <= texture_value(shift_in0, texture_shift);  tu1 <= texture_value(shift_in1, texture_shift);
                tu2 <= texture_value(shift_in2, texture_shift);
                texture_step <= 3'd7;
            end
            3'd7: begin
                tv0 <= texture_value(shift_in0, texture_shift);  tv1 <= texture_value(shift_in1, texture_shift);
                tv2 <= texture_value(shift_in2, texture_shift);
                texture_ready <= 1'b1;
                texture_step <= 3'd0;
            end
            default: ;
        endcase
    end
end

// a passes corner value for the plane
// pass 0 is the distance, passes 1-4 are a colour channel x distance / 512
function [31:0] pass_value(input [31:0] z, input [31:0] corner_colour, input [2:0] pass);
    reg [7:0] channel;
    reg [40:0] product;
    begin
        case (pass)
            3'd1: channel = corner_colour[7:0];
            3'd2: channel = corner_colour[15:8];
            3'd3: channel = corner_colour[23:16];
            default: channel = corner_colour[31:24];
        endcase
        product = channel * z;
        pass_value = (pass == 3'd0) ? z : product[40:9];
    end
endfunction

// stage 0 take the triangle
reg signed [15:0] t_x0, t_y0, t_x1, t_y1, t_x2, t_y2;
reg [31:0] t_z0, t_z1, t_z2, t_colour;
reg [3:0] t_switches;
reg t_fogged;
reg [2:0] t_pass;                        // 0 depth, 1-4 colour channels, 5 U, 6 V
reg t_smooth;
reg t_textured;
reg [7:0] t_slot;
reg [4:0] t_shift;

// stage 1 the 3 edge lines, the area and the box
// each edge is a line a.x + b.y + c, positive on the inside
reg signed [39:0] l_c0, l_c1, l_c2;      // each lines value at pixel (0, 0)
reg signed [23:0] l_a0, l_a1, l_a2;      // change per pixel right
reg signed [23:0] l_b0, l_b1, l_b2;      // change per pixel down
reg signed [39:0] l_area;                // twice the area, the sign says which way it faces
reg signed [15:0] l_left, l_right, l_top, l_bottom;     // the box in whole pixels
reg [31:0] l_z0, l_z1, l_z2, l_colour;
reg [3:0] l_switches;
reg l_fogged;
reg [2:0] l_pass;
reg l_smooth;
reg l_textured;
reg [7:0] l_slot;
reg [4:0] l_shift;
reg signed [15:0] l_x0, l_y0;            // corner 0, needed for C at the end

// one lines c, from corner I to corner J
function signed [39:0] line_c(input signed [15:0] ix, input signed [15:0] iy,
                              input signed [15:0] jx, input signed [15:0] jy);
    reg signed [16:0] dx, dy, ox, oy;
    begin
        dx = jx - ix;  dy = jy - iy;
        ox = 17'sd8 - ix;  oy = 17'sd8 - iy;
        line_c = dx * oy - dy * ox;
    end
endfunction

function signed [15:0] smallest(input signed [15:0] p, input signed [15:0] q, input signed [15:0] r);
    smallest = (p < q) ? ((p < r) ? p : r) : ((q < r) ? q : r);
endfunction
function signed [15:0] largest(input signed [15:0] p, input signed [15:0] q, input signed [15:0] r);
    largest = (p > q) ? ((p > r) ? p : r) : ((q > r) ? q : r);
endfunction

// stages 2 and 3 the products and sums for the plane
// everything that just rides along to the card (lines, area, box, colour, switches ...)
localparam RIDE = 3 * 88 + 40 + 64 + 32 + 4 + 64 + 4 + 1 + 14;
localparam SUMS = 60 + 60;                           // the two sums, one for A one for B
wire [RIDE-1:0] l_ride = {l_shift, l_slot, l_textured,
                          l_fogged, l_smooth, l_pass, l_z0, l_y0, l_x0, l_switches, l_colour, l_bottom, l_top, l_right, l_left, l_area,
                          l_b2, l_a2, l_c2, l_b1, l_a1, l_c1, l_b0, l_a0, l_c0};

// signed number times a distance, the distance is unsigned so give it a 0 sign bit
function signed [75:0] times_z(input signed [39:0] k, input [31:0] z);
    times_z = k * $signed({1'b0, z});
endfunction

// the ride waits in block ram until stage 20 instead of going through 18 rows of registers
wire [RIDE-1:0] ride_at_19;
delay_ram #(.WIDTH(RIDE), .DELAY(18)) ride_wait (.clk(clk), .advance(advance), .in(l_ride), .out(ride_at_19));
reg signed [75:0] q_a0, q_a1, q_a2, q_b0, q_b1, q_b2;
reg q_negative;
reg [35:0] q_size;

reg s_negative;
reg signed [59:0] s_sum_a, s_sum_b;
reg [35:0] s_size;                       // the area without its sign, goes to the reciprocal

// stages 4-14 wait for the reciprocal
localparam RECIP_OUT = 14;               // the stage where 1 / area is ready
wire [35:0] recip_r;
wire [5:0] recip_p;
reciprocal recip (.clk(clk), .advance(advance), .area(s_size), .r(recip_r), .p(recip_p));

reg [SUMS:0] waiting [4:RECIP_OUT];              // the two sums + was the area negative

// stages 15-23 A and B = sum x (1 / area), rounded, then C from corner 0
wire signed [59:0] w_sum_a = waiting[RECIP_OUT][0 +: 60];
wire signed [59:0] w_sum_b = waiting[RECIP_OUT][60 +: 60];
wire w_negative = waiting[RECIP_OUT][SUMS];

// stage 15 sum x r in 4 pieces so each multiply fits the dsp blocks
reg signed [56:0] h_a_th, h_a_tl, h_b_th, h_b_tl;                   // top x r_hi, top x r_lo
reg [55:0] h_a_lh, h_a_ll, h_b_lh, h_b_ll;                            // low x r_hi, low x r_lo
reg [5:0] h_p;
reg h_negative;
function signed [56:0] top_piece(input signed [75:0] sum, input [17:0] r_half);
    top_piece = (sum >>> 38) * $signed({1'b0, r_half});
endfunction
function [55:0] low_piece(input signed [75:0] sum, input [17:0] r_half);
    low_piece = sum[37:0] * r_half;
endfunction

// stage 16 add the pieces in pairs
reg signed [75:0] g_a_top, g_b_top;
reg [73:0] g_a_low, g_b_low;
reg [5:0] g_p;
reg g_negative;
function signed [75:0] top_pair(input signed [56:0] times_hi, input signed [56:0] times_lo);
    top_pair = (times_hi <<< 18) + times_lo;
endfunction
function [73:0] low_pair(input [55:0] times_hi, input [55:0] times_lo);
    low_pair = (times_hi << 18) + times_lo;
endfunction

// stage 17 join the pairs
reg signed [127:0] j_a, j_b;
reg [5:0] j_p;
reg signed [127:0] j_half;               // the rounding half, made here so the next stage only adds
reg j_negative;
function signed [127:0] join_pairs(input signed [75:0] top, input [73:0] low);
    join_pairs = (top <<< 38) + $signed({54'd0, low});
endfunction

// stage 18 add the half so the shift rounds, negate if the area was negative
reg signed [127:0] o_a, o_b;
reg [6:0] o_shift;

// stage 19 coarse shift, by a multiple of 16
reg signed [46:0] k_a, k_b;
reg [3:0] k_fine;
reg k_over;                              // A or B doesnt even fit 47 bits
function fits_47(input signed [127:0] v);
    fits_47 = (v[127:46] == {82{v[46]}});
endfunction
wire signed [127:0] o_a_coarse = o_a >>> {o_shift[6:4], 4'd0};
wire signed [127:0] o_b_coarse = o_b >>> {o_shift[6:4], 4'd0};

// stage 20 fine shift, the last 0-15 bits, gives A and B
reg [RIDE-1:0] n_ride;
reg signed [31:0] n_a, n_b;
wire signed [15:0] n_x0 = n_ride[419:404], n_y0 = n_ride[435:420];
// too steep = A or B doesnt fit the 27 bits a texture plane keeps
wire signed [46:0] k_a_moved = k_a >>> k_fine;
wire signed [46:0] k_b_moved = k_b >>> k_fine;
function fits_27(input signed [46:0] v);
    fits_27 = (v[46:26] == {21{v[26]}});
endfunction
reg n_steep, u_steep, v_steep, p_steep;

// stage 21 A x (x0 - half a pixel) and B x (y0 - half a pixel)
reg [RIDE-1:0] u_ride;
reg signed [31:0] u_a, u_b;
reg signed [48:0] u_tilt_x, u_tilt_y;

// a back faces lines get flipped here, every line negated and lines 1 and 2 swapped
wire signed [39:0] u_c0 = u_ride[39:0],     u_c1 = u_ride[127:88],   u_c2 = u_ride[215:176];
wire signed [23:0] u_a0 = u_ride[63:40],    u_a1 = u_ride[151:128],  u_a2 = u_ride[239:216];
wire signed [23:0] u_b0 = u_ride[87:64],    u_b1 = u_ride[175:152],  u_b2 = u_ride[263:240];
wire u_flip = ($signed(u_ride[303:264]) < 0);          // negative area = back face
wire [263:0] u_turned = u_flip ? {-u_b1, -u_a1, -u_c1, -u_b2, -u_a2, -u_c2, -u_b0, -u_a0, -u_c0}
                               : {u_b2, u_a2, u_c2, u_b1, u_a1, u_c1, u_b0, u_a0, u_c0};

// stage 22 add the two tilts, + 8 so the / 16 rounds
reg [RIDE-1:0] v_ride;
reg signed [31:0] v_a, v_b;
reg [35:0] v_sum;
reg [263:0] v_turned;                    // the 3 lines, flipped if its a back face
wire [31:0] v_z0 = v_ride[467:436];

// stage 23 C = z0 - that / 16
reg [RIDE-1:0] p_ride;
reg [31:0] p_plane_a, p_plane_b, p_plane_c;

// the triangle as it reaches stage 23, in pieces
wire signed [39:0] v_c0 = v_ride[39:0],     v_c1 = v_ride[127:88],   v_c2 = v_ride[215:176];
wire signed [23:0] v_a0 = v_ride[63:40],    v_a1 = v_ride[151:128],  v_a2 = v_ride[239:216];
wire signed [23:0] v_b0 = v_ride[87:64],    v_b1 = v_ride[175:152],  v_b2 = v_ride[263:240];
wire signed [39:0] v_area = v_ride[303:264];
wire signed [15:0] v_left = v_ride[319:304], v_right = v_ride[335:320], v_top = v_ride[351:336], v_bottom = v_ride[367:352];
wire [3:0] v_switches = v_ride[403:400];

// keep or drop, worked out a stage early so the card stage only looks at a few bits
wire is_back = (v_area < 0);
wire is_flat = (v_area == 0);
wire hide_back = v_switches[3];
wire misses_screen = (v_right < 0) || (v_left > 16'sd1279) || (v_bottom < 0) || (v_top > 16'sd719);

// the lines after the back face flip
wire signed [39:0] f_c0 = v_turned[39:0],    f_c1 = v_turned[127:88],   f_c2 = v_turned[215:176];
wire signed [23:0] f_a0 = v_turned[63:40],   f_a1 = v_turned[151:128],  f_a2 = v_turned[239:216];
wire signed [23:0] f_b0 = v_turned[87:64],   f_b1 = v_turned[175:152],  f_b2 = v_turned[263:240];

// top left rule, a pixel exactly on a shared edge belongs to only one triangle
// on edges that arent top or left, c - 1 makes on the edge count as outside
function top_left(input signed [23:0] a, input signed [23:0] b);
    top_left = (a > 0) || (a == 0 && b > 0);
endfunction
wire signed [39:0] r_c0 = top_left(f_a0, f_b0) ? f_c0 : f_c0 - 40'sd1;
wire signed [39:0] r_c1 = top_left(f_a1, f_b1) ? f_c1 : f_c1 - 40'sd1;
wire signed [39:0] r_c2 = top_left(f_a2, f_b2) ? f_c2 : f_c2 - 40'sd1;

// the box clamped to the screen
wire [15:0] cut_left   = (v_left < 0)          ? 16'd0    : v_left;
wire [15:0] cut_right  = (v_right > 16'sd1279) ? 16'd1279 : v_right;
wire [15:0] cut_top    = (v_top < 0)           ? 16'd0    : v_top;
wire [15:0] cut_bottom = (v_bottom > 16'sd719) ? 16'd719  : v_bottom;

// kept for the card stage
reg p_flat, p_back_hidden, p_misses;     // why it would be dropped
reg [263:0] p_lines;                     // the 3 lines, flipped if needed
reg [15:0] p_left, p_right, p_top, p_bottom;     // the box clamped to the screen
wire [31:0] p_colour = p_ride[399:368];
wire [3:0] p_switches = p_ride[403:400];
wire [2:0] p_pass = p_ride[470:468];
wire p_smooth = p_ride[471];
wire p_fogged = p_ride[472];
wire p_textured = p_ride[473];
wire [7:0] p_slot = p_ride[481:474];
wire [4:0] p_shift = p_ride[486:482];

// card stage, build the card, write it, hand it to binning
// the card is slot A (512 bits) and for smooth or textured triangles slot B too
// 4 groups of registers, each loaded from one place
reg [463:0] card_main;                   // slot A bits 0-463, the triangle itself
reg [47:0] card_texture;                 // slot A bits 464-511, texture slot, shift, too steep, top of the planes
reg [383:0] card_b_colours;              // slot B bits 0-383, the 4 colour planes
reg [127:0] card_b_top;                  // slot B bits 384-511, low bits of the texture planes
wire [511:0] card = {card_texture, card_main};
wire [511:0] card_b = {card_b_top, card_b_colours};
reg [287:0] collecting;                  // the colour planes so far
reg [80:0] texture_u;                    // the U plane {B, A, C}, 27 bits each
reg steep_u;                             // and whether it was too steep
// both texture planes once V is at the card
wire [161:0] texture_planes = {p_plane_b[26:0], p_plane_a[26:0], p_plane_c[26:0], texture_u};
reg collect_keep;                        // the triangle being collected is kept
reg [1:0] burst;                         // which burst of the card is written next
reg four_bursts;                         // slot B too
reg wrote_second, handed;

wire full_frame = (cards_made == MAX_CARDS);
wire keep = !p_flat && !p_back_hidden && !p_misses && !full_frame;

// slot A of the card
wire [511:0] new_card = {
    34'd0,                                         // top of the texture planes, filled in at pass 6
    1'b0,                                          // too steep, filled in at pass 6
    13'd0,                                         // texture slot and shift, filled in at pass 6
    1'b0, p_textured, p_smooth, 1'b1,              // textured, smooth, slot A used
    p_fogged, p_switches[2:0],                     // fogged and the switches
    p_colour,
    p_bottom, p_top, p_right, p_left,              // the box
    p_plane_b, p_plane_a, p_plane_c,               // the depth plane
    p_lines                                        // lines 0 1 2 (c a b each)
};

wire card_done = card_full && wrote_second && handed;

reg frame_ending;
assign busy = (full != 0) || h_full || card_full || frame_ending;

// the pipeline registers, no reset here since only full says if a stage counts
integer j;
always @(posedge clk) begin
    if (advance_g0) begin
        // stage 0 take
        t_x0 <= hx0;  t_y0 <= hy0;  t_x1 <= hx1;  t_y1 <= hy1;  t_x2 <= hx2;  t_y2 <= hy2;
        // passes 5 and 6 use the texture values
        t_z0 <= (h_pass == 3'd5) ? {5'd0, tu0} : (h_pass == 3'd6) ? {5'd0, tv0} : pass_value(hz0, h_colour[31:0], h_pass);
        t_z1 <= (h_pass == 3'd5) ? {5'd0, tu1} : (h_pass == 3'd6) ? {5'd0, tv1} : pass_value(hz1, h_colour[63:32], h_pass);
        t_z2 <= (h_pass == 3'd5) ? {5'd0, tu2} : (h_pass == 3'd6) ? {5'd0, tv2} : pass_value(hz2, h_colour[95:64], h_pass);
        t_colour <= h_colour[31:0];  t_switches <= h_switches;  t_fogged <= h_fogged;
        t_pass <= h_pass;  t_smooth <= h_smooth;
        t_textured <= h_textured;  t_slot <= h_slot;  t_shift <= texture_shift;

        // stage 1 lines, area and box
        l_area <= (t_x1 - t_x0) * (t_y2 - t_y0) - (t_y1 - t_y0) * (t_x2 - t_x0);
        l_c0 <= line_c(t_x1, t_y1, t_x2, t_y2);
        l_c1 <= line_c(t_x2, t_y2, t_x0, t_y0);
        l_c2 <= line_c(t_x0, t_y0, t_x1, t_y1);
        l_a0 <= (t_y1 - t_y2) <<< 4;   l_b0 <= (t_x2 - t_x1) <<< 4;
        l_a1 <= (t_y2 - t_y0) <<< 4;   l_b1 <= (t_x0 - t_x2) <<< 4;
        l_a2 <= (t_y0 - t_y1) <<< 4;   l_b2 <= (t_x1 - t_x0) <<< 4;
        l_left   <= smallest(t_x0, t_x1, t_x2) >>> 4;      // to whole pixels
        l_right  <= largest(t_x0, t_x1, t_x2)  >>> 4;
        l_top    <= smallest(t_y0, t_y1, t_y2) >>> 4;
        l_bottom <= largest(t_y0, t_y1, t_y2)  >>> 4;
        l_z0 <= t_z0;  l_z1 <= t_z1;  l_z2 <= t_z2;
        l_x0 <= t_x0;  l_y0 <= t_y0;
        l_colour <= t_colour;  l_switches <= t_switches;  l_fogged <= t_fogged;
        l_pass <= t_pass;  l_smooth <= t_smooth;
        l_textured <= t_textured;  l_slot <= t_slot;  l_shift <= t_shift;

        // stage 2 the 6 multiplies for the plane
        q_a0 <= times_z(l_a0, l_z0);  q_a1 <= times_z(l_a1, l_z1);  q_a2 <= times_z(l_a2, l_z2);
        q_b0 <= times_z(l_b0, l_z0);  q_b1 <= times_z(l_b1, l_z1);  q_b2 <= times_z(l_b2, l_z2);
        q_negative <= (l_area < 0);
        q_size <= (l_area < 0) ? -l_area : l_area;

        // stage 3 the sums
        s_negative <= q_negative;
        s_sum_a <= q_a0 + q_a1 + q_a2;
        s_sum_b <= q_b0 + q_b1 + q_b2;
        s_size <= q_size;
    end
end

always @(posedge clk) begin
    if (advance_g1) begin
        // stages 4-14 wait for the reciprocal
        waiting[4] <= {s_negative, s_sum_b, s_sum_a};
        for (j = 5; j <= RECIP_OUT; j = j + 1) waiting[j] <= waiting[j - 1];
    end
end

always @(posedge clk) begin
    if (advance_g2) begin
        // stage 15 pieces
        h_a_th <= top_piece(w_sum_a, recip_r[35:18]);  h_a_tl <= top_piece(w_sum_a, recip_r[17:0]);
        h_a_lh <= low_piece(w_sum_a, recip_r[35:18]);  h_a_ll <= low_piece(w_sum_a, recip_r[17:0]);
        h_b_th <= top_piece(w_sum_b, recip_r[35:18]);  h_b_tl <= top_piece(w_sum_b, recip_r[17:0]);
        h_b_lh <= low_piece(w_sum_b, recip_r[35:18]);  h_b_ll <= low_piece(w_sum_b, recip_r[17:0]);
        h_p <= recip_p;  h_negative <= w_negative;

        // stage 16 pairs
        g_a_top <= top_pair(h_a_th, h_a_tl);  g_a_low <= low_pair(h_a_lh, h_a_ll);
        g_b_top <= top_pair(h_b_th, h_b_tl);  g_b_low <= low_pair(h_b_lh, h_b_ll);
        g_p <= h_p;  g_negative <= h_negative;

        // stage 17 join
        j_a <= join_pairs(g_a_top, g_a_low);
        j_b <= join_pairs(g_b_top, g_b_low);
        j_p <= g_p;  j_negative <= g_negative;
        j_half <= 128'sd1 <<< (6'd34 + g_p);

        // stage 18 round
        o_a <= j_negative ? j_half - j_a : j_a + j_half;
        o_b <= j_negative ? j_half - j_b : j_b + j_half;
        o_shift <= 7'd35 + j_p;

        // stage 19 coarse shift
        k_a <= o_a_coarse[46:0];
        k_b <= o_b_coarse[46:0];
        k_fine <= o_shift[3:0];
        k_over <= !fits_47(o_a_coarse) || !fits_47(o_b_coarse);
    end
end

always @(posedge clk) begin
    if (advance_g3) begin
        // stage 20 fine shift, A and B
        n_ride <= ride_at_19;                // from the block ram
        n_a <= k_a_moved[31:0];
        n_b <= k_b_moved[31:0];
        n_steep <= k_over || !fits_27(k_a_moved) || !fits_27(k_b_moved);

        // stage 21 tilt
        u_ride <= n_ride;
        u_a <= n_a;  u_b <= n_b;
        u_steep <= n_steep;
        u_tilt_x <= n_a * (n_x0 - 16'sd8);
        u_tilt_y <= n_b * (n_y0 - 16'sd8);

        // stage 22 sum
        v_ride <= u_ride;
        v_a <= u_a;  v_b <= u_b;
        v_steep <= u_steep;
        v_sum <= u_tilt_x[35:0] + u_tilt_y[35:0] + 36'd8;
        v_turned <= u_turned;

        // stage 23 C and the keep or drop bits
        p_ride <= v_ride;
        p_plane_a <= v_a;
        p_plane_b <= v_b;
        p_plane_c <= v_z0 - v_sum[35:4];
        p_steep <= v_steep;
        p_flat <= is_flat;
        p_back_hidden <= is_back && hide_back;
        p_misses <= misses_screen;
        p_lines <= {f_b2, f_a2, r_c2, f_b1, f_a1, r_c1, f_b0, f_a0, r_c0};
        p_left <= cut_left;  p_right <= cut_right;  p_top <= cut_top;  p_bottom <= cut_bottom;
    end
end

// the cards texture bits and slot B
wire at_card = full[LAST] && !card_full;                             // a pass is at the card stage and gets taken
wire card_begins = at_card && p_pass == 3'd0 && keep;                // pass 0 of a kept triangle
wire colours_in = at_card && p_pass == 3'd4 && collect_keep;         // pass 4, the colour planes are complete
wire textures_in = at_card && p_pass == 3'd6 && collect_keep;        // pass 6, both texture planes are here
always @(posedge clk) begin
    // slot B colour planes, 0 for a flat textured triangle
    if (textures_in && !p_smooth) card_b_colours <= 384'd0;
    else if (colours_in) card_b_colours <= {p_plane_b, p_plane_a, p_plane_c, collecting[287:0]};
    // slot B top, 0 unless textured
    if (colours_in) card_b_top <= 128'd0;
    else if (textures_in) card_b_top <= texture_planes[127:0];
    // slot A texture bits, 0 from pass 0 then filled in at pass 6
    if (card_begins) card_texture <= 48'd0;
    else if (textures_in) card_texture <= {texture_planes[161:128], steep_u || p_steep, p_shift, p_slot};
end

integer i;
// the burst being written, picked straight from the card registers
assign mem_wr_data = (burst == 2'd0) ? card[255:0]   : (burst == 2'd1) ? card[511:256] :
                     (burst == 2'd2) ? card_b[255:0] : card_b[511:256];

always @(posedge clk) begin
    if (reset) begin
        full <= 0;
        card_full <= 1'b0;
        last_full_c <= 4'b0000;
        card_full_c <= 4'b0000;
        card_valid <= 1'b0;
        mem_req <= 1'b0;
        frame_flushed <= 1'b0;
        frame_ending <= 1'b0;
        overflow <= 1'b0;
        cards_made <= 0;
        dropped_back <= 0;  dropped_flat <= 0;  dropped_off_screen <= 0;
    end else begin
        frame_flushed <= 1'b0;

        // frame control
        if (frame_begin) begin
            cards_area <= cards_start;
            cards_made <= 0;
            overflow <= 1'b0;
            dropped_back <= 0;  dropped_flat <= 0;  dropped_off_screen <= 0;
        end
        if (frame_end) frame_ending <= 1'b1;
        if (frame_ending && full == 0 && !h_full && !card_full && !tri_valid) begin
            frame_ending <= 1'b0;
            frame_flushed <= 1'b1;
        end

        // the pipeline moves one stage
        if (advance) begin
            full <= {full[LAST-1:0], take_new};
            last_full_c <= {4{full[LAST-1]}};

        end

        // card stage, take the pass at the end of the pipeline
        if (full[LAST] && !card_full) begin
            if (p_pass == 3'd0) begin
                // pass 0 slot A, keep or drop is decided here
                if (keep) begin
                    card_main <= new_card[463:0];
                    collect_keep <= 1'b1;
                    if (!p_smooth && !p_textured) begin          // flat and plain, write it now
                        card_full <= 1'b1;
                        card_full_c <= 4'b1111;
                        four_bursts <= 1'b0;
                        burst <= 2'd0;  wrote_second <= 1'b0;  handed <= 1'b0;
                        // card n is at cards start + n x 8 bursts
                        mem_addr <= {1'b0, cards_area + {cards_made, 3'b000}, 3'b000};
                        mem_req <= 1'b1;
                        // binning gets it at the same time
                        card_number <= cards_made;
                        box_left <= p_left;  box_right <= p_right;  box_top <= p_top;  box_bottom <= p_bottom;
                        card_valid <= 1'b1;
                        cards_made <= cards_made + 1'b1;
                    end
                end else begin
                    collect_keep <= 1'b0;
                    if (p_flat)                        dropped_flat <= dropped_flat + 1;
                    else if (p_back_hidden)            dropped_back <= dropped_back + 1;
                    else if (p_misses)                 dropped_off_screen <= dropped_off_screen + 1;
                    else                               overflow <= 1'b1;            // no card numbers left
                end
            end else if (p_pass == 3'd1 || p_pass == 3'd2 || p_pass == 3'd3) begin
                // passes 1-3 colour channels 0-2, collected
                case (p_pass)
                    3'd1:    collecting[95:0]    <= {p_plane_b, p_plane_a, p_plane_c};
                    3'd2:    collecting[191:96]  <= {p_plane_b, p_plane_a, p_plane_c};
                    default: collecting[287:192] <= {p_plane_b, p_plane_a, p_plane_c};
                endcase
            end else if (p_pass == 3'd4) begin
                // pass 4 the last channel (alpha)
                if (collect_keep) begin
                    if (!p_textured) begin                       // smooth and plain, write it now (4 bursts)
                        card_full <= 1'b1;
                        card_full_c <= 4'b1111;
                        four_bursts <= 1'b1;
                        burst <= 2'd0;  wrote_second <= 1'b0;  handed <= 1'b0;
                        mem_addr <= {1'b0, cards_area + {cards_made, 3'b000}, 3'b000};
                        mem_req <= 1'b1;
                        card_number <= cards_made;
                        box_left <= p_left;  box_right <= p_right;  box_top <= p_top;  box_bottom <= p_bottom;
                        card_valid <= 1'b1;
                        cards_made <= cards_made + 1'b1;
                    end
                end
            end else if (p_pass == 3'd5) begin
                // pass 5 the U plane, kept until V arrives
                texture_u <= {p_plane_b[26:0], p_plane_a[26:0], p_plane_c[26:0]};
                steep_u <= p_steep;
            end else if (collect_keep) begin
                // pass 6 the V plane, the card is written now (4 bursts)
                card_full <= 1'b1;
                card_full_c <= 4'b1111;
                four_bursts <= 1'b1;
                burst <= 2'd0;  wrote_second <= 1'b0;  handed <= 1'b0;
                mem_addr <= {1'b0, cards_area + {cards_made, 3'b000}, 3'b000};
                mem_req <= 1'b1;
                card_number <= cards_made;
                box_left <= p_left;  box_right <= p_right;  box_top <= p_top;  box_bottom <= p_bottom;
                card_valid <= 1'b1;
                cards_made <= cards_made + 1'b1;
            end
        end

        // the cards bursts, slot A then slot B if it has one
        if (card_full && mem_req && mem_grant) begin
            if (burst == (four_bursts ? 2'd3 : 2'd1)) begin  // that was the last one
                wrote_second <= 1'b1;
                mem_req <= 1'b0;
            end else begin                                  // offer the next one
                mem_addr <= mem_addr + 29'd8;                // addresses count 8 per burst
                burst <= burst + 1'b1;
            end
        end
        // binning takes the number and box
        if (card_valid && card_ready) begin
            card_valid <= 1'b0;
            handed <= 1'b1;
        end
        if (card_done) begin card_full <= 1'b0;  card_full_c <= 4'b0000; end
    end
end

endmodule

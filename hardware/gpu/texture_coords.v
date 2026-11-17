// texture_coords.v
// for one quad of a textured triangle works out u and v for its 4 pixels and the mip level
// perspective correct, U = (u x q) >> s comes in and gets multiplied by 1/q

module texture_coords (
    input wire clk,
    input wire signed [26:0] us, vs,         // U and V planes at one sample point inside the triangle
    input wire [2:0] pick,                   // which slot that sample point is (pixel x 2 + sample)
    input wire signed [26:0] au, bu, av, bv, // U and V change per pixel right / down
    input wire signed [31:0] za, zb,         // q change per pixel right / down
    input wire [16:0] r,                     // 1/q at the quad centre = r / 2^(16 + p)
    input wire [5:0] p,
    input wire [4:0] s,                      // the triangles shift
    input wire steep,                        // too steep, use the smallest mip
    input wire textured,                     // rides along, 1 = this quad has a texture
    input wire [7:0] slot,                   // rides along, which texture
    output reg [4*22-1:0] u,                 // pixel i at [i x 22], 1/256 texel (0 top left 1 top right 2 bottom left 3 bottom right)
    output reg [4*22-1:0] v,
    output reg [3:0] level,                  // mip level, 15 if too steep
    output reg textured_out,
    output reg [7:0] slot_out
);

// clamps, squeeze a signed number into fewer bits
function signed [21:0] clamp22(input signed [48:0] x);
    clamp22 = (x[48:21] == {28{x[48]}}) ? x[21:0] : {x[48], {21{!x[48]}}};
endfunction
function signed [23:0] clamp24(input signed [48:0] x);
    clamp24 = (x[48:23] == {26{x[48]}}) ? x[23:0] : {x[48], {23{!x[48]}}};
endfunction
function signed [26:0] clamp27(input signed [31:0] x);
    clamp27 = (x[31:26] == {6{x[31]}}) ? x[26:0] : {x[31], {26{!x[31]}}};
endfunction
function signed [17:0] clamp18(input signed [45:0] x);
    clamp18 = (x[45:17] == {29{x[45]}}) ? x[17:0] : {x[45], {17{!x[45]}}};
endfunction
// absolute value of a slope
function [23:0] size_of(input signed [23:0] x);
    size_of = x[23] ? (~x + 24'd1) : x;
endfunction
// rough length of a step, the bigger part + half the smaller
function [24:0] length_of(input [23:0] a, input [23:0] b);
    length_of = (a > b) ? ({1'b0, a} + {2'b00, b[23:1]}) : ({1'b0, b} + {2'b00, a[23:1]});
endfunction
// where the top 1 bit is
function [4:0] top_bit(input [25:0] x);
    integer i;
    begin
        top_bit = 5'd0;
        for (i = 1; i < 26; i = i + 1)
            if (x[i]) top_bit = i;
    end
endfunction
// one pixel = the centre plus or minus half of each slope
function signed [21:0] pixel_of(input signed [21:0] centre, input signed [23:0] dx, input signed [23:0] dy,
                                input right, input down_);
    reg signed [28:0] sum;
    begin
        sum = $signed({centre, 5'd0}) + (right ? dx : -dx) + (down_ ? dy : -dy);
        pixel_of = clamp22(sum >>> 5);
    end
endfunction

// stage 0 register the inputs
reg signed [26:0] t0_us, t0_vs, t0_au, t0_bu, t0_av, t0_bv;
reg [2:0] t0_pick;
reg signed [31:0] t0_za, t0_zb;
reg [16:0] t0_r;
reg [5:0] t0_p;
reg [4:0] t0_s;
reg t0_steep, t0_textured;
reg [7:0] t0_slot;
always @(posedge clk) begin
    t0_pick <= pick;
    t0_us <= us;  t0_vs <= vs;  t0_au <= au;  t0_bu <= bu;  t0_av <= av;  t0_bv <= bv;
    t0_za <= za;  t0_zb <= zb;
    t0_r <= r;  t0_p <= p;  t0_s <= s;
    t0_steep <= steep;  t0_textured <= textured;  t0_slot <= slot;
end

// stage 1 multiply by r, narrow the q steps, work out how far to shift down
// (U x r) / 2^(16 + p - s) = u in 1/256 texel
wire signed [17:0] t0_r_signed = {1'b0, t0_r};
wire signed [7:0] t0_down = $signed({2'b00, t0_p}) + 8'sd16 - $signed({3'b000, t0_s});
// when q is big the low bits of its steps dont matter so drop them to fit 27 bits
wire [2:0] t0_drop = (t0_p > 6'd25) ? (t0_p - 6'd25) : 3'd0;
reg signed [44:0] t1_us, t1_vs, t1_au, t1_bu, t1_av, t1_bv;
reg [2:0] t1_pick;
reg signed [26:0] t1_za, t1_zb;
reg [16:0] t1_r;
reg [5:0] t1_down;
reg [4:0] t1_g_down;                     // shift for g
reg t1_steep, t1_textured;
reg [7:0] t1_slot;
always @(posedge clk) begin
    t1_us <= t0_us * t0_r_signed;  t1_vs <= t0_vs * t0_r_signed;
    t1_pick <= t0_pick;
    t1_au <= t0_au * t0_r_signed;  t1_bu <= t0_bu * t0_r_signed;
    t1_av <= t0_av * t0_r_signed;  t1_bv <= t0_bv * t0_r_signed;
    t1_za <= clamp27(t0_za >>> t0_drop);
    t1_zb <= clamp27(t0_zb >>> t0_drop);
    t1_r <= t0_r;
    t1_down <= t0_down[7] ? 6'd0 : t0_down[5:0];
    t1_g_down <= (t0_p > 6'd25) ? 5'd25 : t0_p[4:0];
    t1_steep <= t0_steep;  t1_textured <= t0_textured;  t1_slot <= t0_slot;
end

// stage 2 first half of the shift (multiples of 8), and za zb x r
// slopes keep 4 more fraction bits than u and v
wire [5:0] t1_coarse = {t1_down[5:3], 3'b000};
wire signed [17:0] t1_r_signed = {1'b0, t1_r};
reg signed [44:0] t2_us, t2_vs;
reg [2:0] t2_pick;
reg signed [48:0] t2_au, t2_bu, t2_av, t2_bv;
reg signed [44:0] t2_gx, t2_gy;
reg [2:0] t2_fine;
reg [4:0] t2_g_down;
reg t2_steep, t2_textured;
reg [7:0] t2_slot;
always @(posedge clk) begin
    t2_us <= t1_us >>> t1_coarse;
    t2_vs <= t1_vs >>> t1_coarse;
    t2_pick <= t1_pick;
    t2_au <= $signed({t1_au, 4'd0}) >>> t1_coarse;
    t2_bu <= $signed({t1_bu, 4'd0}) >>> t1_coarse;
    t2_av <= $signed({t1_av, 4'd0}) >>> t1_coarse;
    t2_bv <= $signed({t1_bv, 4'd0}) >>> t1_coarse;
    t2_gx <= t1_za * t1_r_signed;
    t2_gy <= t1_zb * t1_r_signed;
    t2_fine <= t1_down[2:0];
    t2_g_down <= t1_g_down;
    t2_steep <= t1_steep;  t2_textured <= t1_textured;  t2_slot <= t1_slot;
end

// stage 3 second half of the shift (0 to 7) and the clamps
// g = how fast q changes per pixel divided by q
wire signed [48:0] t2_us_moved = t2_us >>> t2_fine;
wire signed [48:0] t2_vs_moved = t2_vs >>> t2_fine;
wire signed [48:0] t2_au_moved = t2_au >>> t2_fine;
wire signed [48:0] t2_bu_moved = t2_bu >>> t2_fine;
wire signed [48:0] t2_av_moved = t2_av >>> t2_fine;
wire signed [48:0] t2_bv_moved = t2_bv >>> t2_fine;
wire signed [45:0] t2_gx_moved = $signed({t2_gx, 1'b0}) >>> t2_g_down;
wire signed [45:0] t2_gy_moved = $signed({t2_gy, 1'b0}) >>> t2_g_down;
reg signed [21:0] t3_us, t3_vs;          // u v at the sample point, 1/256 texel
reg [2:0] t3_pick;
reg signed [23:0] t3_au, t3_bu, t3_av, t3_bv;    // slopes if q stood still, 1/4096 texel
reg signed [17:0] t3_gx, t3_gy;
reg t3_steep, t3_textured;
reg [7:0] t3_slot;
always @(posedge clk) begin
    t3_us <= clamp22(t2_us_moved);  t3_vs <= clamp22(t2_vs_moved);
    t3_pick <= t2_pick;
    t3_au <= clamp24(t2_au_moved);  t3_bu <= clamp24(t2_bu_moved);
    t3_av <= clamp24(t2_av_moved);  t3_bv <= clamp24(t2_bv_moved);
    t3_gx <= clamp18(t2_gx_moved);  t3_gy <= clamp18(t2_gy_moved);
    t3_steep <= t2_steep;  t3_textured <= t2_textured;  t3_slot <= t2_slot;
end

// stage 4 step from the sample point to the quad centre
// the sample point is used because the quad centre can be outside the triangle, where U could wrap
// the step is 3, 1, -1 or -3 quarter pixels each way depending on the slot
function signed [26:0] quarters(input signed [23:0] slope, input far_side, input second_sample);
    reg signed [26:0] once, three;
    begin
        once = slope;
        three = once + (once <<< 1);
        case ({far_side, second_sample})
            2'b00: quarters = three;
            2'b01: quarters = once;
            2'b10: quarters = -once;
            default: quarters = -three;
        endcase
    end
endfunction
function signed [21:0] to_centre(input signed [21:0] at_sample, input signed [26:0] across, input signed [26:0] down_);
    reg signed [27:0] step;
    begin
        step = across + down_;
        to_centre = clamp22(at_sample + (step >>> 6));
    end
endfunction
// stage 4a the two steps
reg signed [26:0] ta_ux, ta_uy, ta_vx, ta_vy;
reg signed [21:0] ta_us, ta_vs;
reg signed [23:0] ta_au, ta_bu, ta_av, ta_bv;
reg signed [17:0] ta_gx, ta_gy;
reg ta_steep, ta_textured;
reg [7:0] ta_slot;
always @(posedge clk) begin
    ta_ux <= quarters(t3_au, t3_pick[1], t3_pick[0]);  ta_uy <= quarters(t3_bu, t3_pick[2], t3_pick[0]);
    ta_vx <= quarters(t3_av, t3_pick[1], t3_pick[0]);  ta_vy <= quarters(t3_bv, t3_pick[2], t3_pick[0]);
    ta_us <= t3_us;  ta_vs <= t3_vs;
    ta_au <= t3_au;  ta_bu <= t3_bu;  ta_av <= t3_av;  ta_bv <= t3_bv;
    ta_gx <= t3_gx;  ta_gy <= t3_gy;
    ta_steep <= t3_steep;  ta_textured <= t3_textured;  ta_slot <= t3_slot;
end
// stage 4b u v at the centre
reg signed [21:0] t4_uc, t4_vc;          // 1/256 texel
reg signed [23:0] t4_au, t4_bu, t4_av, t4_bv;
reg signed [17:0] t4_gx, t4_gy;
reg t4_steep, t4_textured;
reg [7:0] t4_slot;
always @(posedge clk) begin
    t4_uc <= to_centre(ta_us, ta_ux, ta_uy);
    t4_vc <= to_centre(ta_vs, ta_vx, ta_vy);
    t4_au <= ta_au;  t4_bu <= ta_bu;  t4_av <= ta_av;  t4_bv <= ta_bv;
    t4_gx <= ta_gx;  t4_gy <= ta_gy;
    t4_steep <= ta_steep;  t4_textured <= ta_textured;  t4_slot <= ta_slot;
end

// stage 5 centre u v times g
reg signed [39:0] t5_ugx, t5_ugy, t5_vgx, t5_vgy;
reg signed [21:0] t5_uc, t5_vc;
reg signed [23:0] t5_au, t5_bu, t5_av, t5_bv;
reg t5_steep, t5_textured;
reg [7:0] t5_slot;
always @(posedge clk) begin
    t5_ugx <= t4_uc * t4_gx;  t5_ugy <= t4_uc * t4_gy;
    t5_vgx <= t4_vc * t4_gx;  t5_vgy <= t4_vc * t4_gy;
    t5_uc <= t4_uc;  t5_vc <= t4_vc;
    t5_au <= t4_au;  t5_bu <= t4_bu;  t5_av <= t4_av;  t5_bv <= t4_bv;
    t5_steep <= t4_steep;  t5_textured <= t4_textured;  t5_slot <= t4_slot;
end

// stage 6 the true slopes, du/dx = a_u - u_c x g_x
function signed [23:0] true_slope(input signed [23:0] still, input signed [39:0] product);
    reg signed [48:0] difference;
    begin
        difference = still - (product >>> 13);
        true_slope = clamp24(difference);
    end
endfunction
reg signed [23:0] t6_dudx, t6_dudy, t6_dvdx, t6_dvdy;
reg signed [21:0] t6_uc, t6_vc;
reg t6_steep, t6_textured;
reg [7:0] t6_slot;
always @(posedge clk) begin
    t6_dudx <= true_slope(t5_au, t5_ugx);  t6_dudy <= true_slope(t5_bu, t5_ugy);
    t6_dvdx <= true_slope(t5_av, t5_vgx);  t6_dvdy <= true_slope(t5_bv, t5_vgy);
    t6_uc <= t5_uc;  t6_vc <= t5_vc;
    t6_steep <= t5_steep;  t6_textured <= t5_textured;  t6_slot <= t5_slot;
end

// stage 7 how long one pixel right / down is in the texture, and the 4 pixels u v
reg [24:0] t7_length_x, t7_length_y;     // 1/4096 texel
reg [4*22-1:0] t7_u, t7_v;
reg t7_steep, t7_textured;
reg [7:0] t7_slot;
always @(posedge clk) begin
    t7_length_x <= length_of(size_of(t6_dudx), size_of(t6_dvdx));
    t7_length_y <= length_of(size_of(t6_dudy), size_of(t6_dvdy));
    t7_u[0 * 22 +: 22] <= pixel_of(t6_uc, t6_dudx, t6_dudy, 1'b0, 1'b0);
    t7_u[1 * 22 +: 22] <= pixel_of(t6_uc, t6_dudx, t6_dudy, 1'b1, 1'b0);
    t7_u[2 * 22 +: 22] <= pixel_of(t6_uc, t6_dudx, t6_dudy, 1'b0, 1'b1);
    t7_u[3 * 22 +: 22] <= pixel_of(t6_uc, t6_dudx, t6_dudy, 1'b1, 1'b1);
    t7_v[0 * 22 +: 22] <= pixel_of(t6_vc, t6_dvdx, t6_dvdy, 1'b0, 1'b0);
    t7_v[1 * 22 +: 22] <= pixel_of(t6_vc, t6_dvdx, t6_dvdy, 1'b1, 1'b0);
    t7_v[2 * 22 +: 22] <= pixel_of(t6_vc, t6_dvdx, t6_dvdy, 1'b0, 1'b1);
    t7_v[3 * 22 +: 22] <= pixel_of(t6_vc, t6_dvdx, t6_dvdy, 1'b1, 1'b1);
    t7_steep <= t6_steep;  t7_textured <= t6_textured;  t7_slot <= t6_slot;
end

// stage 8 the longer step times about sqrt 2 so the top bit rounds log2
wire [24:0] t7_longest = (t7_length_x > t7_length_y) ? t7_length_x : t7_length_y;
reg [25:0] t8_scaled;
reg [4*22-1:0] t8_u, t8_v;
reg t8_steep, t8_textured;
reg [7:0] t8_slot;
always @(posedge clk) begin
    t8_scaled <= {1'b0, t7_longest} + {3'b000, t7_longest[24:2]} + {4'b0000, t7_longest[24:3]} + {6'b000000, t7_longest[24:5]};
    t8_u <= t7_u;  t8_v <= t7_v;
    t8_steep <= t7_steep;  t8_textured <= t7_textured;  t8_slot <= t7_slot;
end

// stage 9 the mip level = top bit - 12 (bit 12 is 1 texel per pixel)
wire [4:0] t8_top = top_bit(t8_scaled);
always @(posedge clk) begin
    level <= t8_steep ? 4'd15 : (t8_top < 5'd12) ? 4'd0 : (t8_top - 5'd12);
    u <= t8_u;  v <= t8_v;
    textured_out <= t8_textured;
    slot_out <= t8_slot;
end

endmodule

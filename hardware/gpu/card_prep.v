// card_prep.v
// gets one triangle card ready for the raster for one tile
// trims the box to the tile and moves every plane (edges depth colour u v) to the start pixel
// also works out the 2x aa sample offsets so the raster only has to add

module card_prep (
    input wire clk,
    input wire start,                       // 1 for one clock, prepare this card for this tile
    input wire [1023:0] card,               // the triangle card, slot a is bits 0-511, slot b is 512-1023
    input wire [4:0] tile_x,                // which tile across
    input wire [4:0] tile_y,                // which tile down
    output reg done,                        // 1 for one clock, outputs are ready and stay until the next start
    output reg empty,                       // 1 = nothing of this triangle in this tile

    // for the raster
    output reg [4:0] box_qx0, box_qx1, box_qy0, box_qy1,   // the box in quads
    output reg signed [39:0] e0, e1, e2,                   // edge values at the start pixel
    output wire signed [39:0] a0, a1, a2, b0, b1, b2,      // edge steps per pixel right / down
    output reg [31:0] z,                                   // depth at the start pixel
    output wire signed [31:0] za, zb,                      // depth steps
    output wire [31:0] colour,
    output wire depth_test, depth_write, colour_write,
    // 2x aa, each slots offset from the quads top left pixel centre (slot t = pixel x 2 + sample)
    output reg [3*8*28-1:0] slot_edge,      // edge k slot t at bits (k x 8 + t) x 28, signed
    output reg [8*32-1:0] slot_depth,       // slot t at bits t x 32
    // smooth shading, the 4 colour planes at the start pixel and their steps
    output wire smooth,
    output wire fogged,                     // fog this triangle
    output reg [127:0] colour_p,            // channel h at h x 32
    output wire [127:0] colour_pa, colour_pb,   // steps per pixel right / down
    // textures, u and v planes at the start pixel and their steps
    output wire textured,
    output wire [7:0] texture_slot,         // which texture
    output wire [4:0] texture_shift,        // the triangles shift
    output wire texture_steep,              // too steep, use the smallest mipmap
    output reg [26:0] tex_u, tex_v,
    output wire signed [26:0] tex_ua, tex_ub, tex_va, tex_vb     // steps per pixel right / down
);

// sample points are in 1/16 pixel from the pixel centre, sample 0 = (-4, -4) sample 1 = (4, 4)

// the cards pieces
wire signed [39:0] card_c0 = card[39:0],      card_c1 = card[127:88],    card_c2 = card[215:176];
wire signed [23:0] card_a0 = card[63:40],     card_a1 = card[151:128],   card_a2 = card[239:216];
wire signed [23:0] card_b0 = card[87:64],     card_b1 = card[175:152],   card_b2 = card[263:240];
wire [31:0] card_z0 = card[295:264];
wire signed [31:0] card_za = card[327:296], card_zb = card[359:328];
wire [15:0] card_left = card[375:360], card_right = card[391:376], card_top = card[407:392], card_bottom = card[423:408];
wire [161:0] card_texture_planes = {card[511:478], card[1023:896]};      // {V.B, V.A, V.C, U.B, U.A, U.C}

// the box inside this tile
// tiles are 64 x 32 pixels
wire [15:0] tile_left   = {5'd0, tile_x, 6'd0};
wire [15:0] tile_right  = {5'd0, tile_x, 6'd63};
wire [15:0] tile_top    = {6'd0, tile_y, 5'd0};
wire [15:0] tile_bottom = {6'd0, tile_y, 5'd31};

// overlap of the triangles box and the tile
wire [15:0] left   = (card_left > tile_left)       ? card_left   : tile_left;
wire [15:0] right  = (card_right < tile_right)     ? card_right  : tile_right;
wire [15:0] top    = (card_top > tile_top)         ? card_top    : tile_top;
wire [15:0] bottom = (card_bottom < tile_bottom)   ? card_bottom : tile_bottom;

// the card is copied into registers at stage 1 so the input can change after
reg signed [39:0] c0, c1, c2;
reg signed [23:0] s_a0, s_a1, s_a2, s_b0, s_b1, s_b2;
reg [31:0] z0;
reg signed [31:0] s_za, s_zb;
reg [31:0] s_colour;
reg [7:0] switches;
reg [15:0] t_left, t_right, t_top, t_bottom;     // stage 1 the trimmed box
reg [10:0] start_x;                              // stage 2 the start pixel
reg [9:0] start_y;
reg signed [63:0] m_ax0, m_ax1, m_ax2, m_by0, m_by1, m_by2;    // stage 3 the products
reg signed [63:0] m_zx, m_zy;
reg [6:0] going;                                 // which stages are busy
// smooth shading colour planes, channel h at [h x 32] / [h x 64]
reg [127:0] s_cc;                                // value at pixel (0, 0)
reg [127:0] s_ca, s_cb;                          // steps
reg s_smooth;
reg [4*64-1:0] m_cx, m_cy;                       // stage 3 products
// texture planes
reg [26:0] s_uc, s_vc;                           // value at pixel (0, 0)
reg signed [26:0] s_ua, s_ub, s_va, s_vb;
reg s_textured, s_steep;
reg [7:0] s_slot;
reg [4:0] s_shift;
reg signed [38:0] m_ux, m_uy, m_vx, m_vy;        // stage 3 products
integer h;
// stages 5-7 the aa offsets, edge k at [k x W +: W]
// plain vectors not arrays so they stay registers
reg signed [3*28-1:0] p_e4;                       // stage 5 per edge (a / 16 + b / 16) x 4, sample 1s offset
reg signed [3*28-1:0] p_ab;                       // per edge a + b
reg signed [35:0] p_z4;                           // (za + zb) x 4
reg signed [32:0] p_zab;                          // za + zb
reg signed [3*2*28-1:0] q_e;                      // stage 6 edge k sample s at [(k x 2 + s) x 28 +: 28]
reg signed [2*32-1:0] q_z;                        // sample s depth offset at [s x 32 +: 32]
integer k, t;

wire signed [11:0] sx = $signed({1'b0, start_x});
wire signed [10:0] sy = $signed({1'b0, start_y});

always @(posedge clk) begin
    going <= {going[5:0], start};
    done <= going[6];

    // stage 1 trim the box and keep the card
    if (start) begin
        t_left <= left;  t_right <= right;  t_top <= top;  t_bottom <= bottom;
        c0 <= card_c0;  c1 <= card_c1;  c2 <= card_c2;
        s_a0 <= card_a0;  s_a1 <= card_a1;  s_a2 <= card_a2;
        s_b0 <= card_b0;  s_b1 <= card_b1;  s_b2 <= card_b2;
        z0 <= card_z0;  s_za <= card_za;  s_zb <= card_zb;
        s_colour <= card[455:424];
        switches <= card[463:456];
        for (h = 0; h < 4; h = h + 1) begin
            s_cc[h * 32 +: 32] <= card[512 + h * 96 +: 32];
            s_ca[h * 32 +: 32] <= card[512 + h * 96 + 32 +: 32];
            s_cb[h * 32 +: 32] <= card[512 + h * 96 + 64 +: 32];
        end
        s_smooth <= card[461];
        s_uc <= card_texture_planes[26:0];     s_ua <= card_texture_planes[53:27];    s_ub <= card_texture_planes[80:54];
        s_vc <= card_texture_planes[107:81];   s_va <= card_texture_planes[134:108];  s_vb <= card_texture_planes[161:135];
        s_textured <= card[462];
        s_slot <= card[471:464];  s_shift <= card[476:472];  s_steep <= card[477];
    end

    // stage 2 empty or not, the box in quads, the start pixel
    if (going[0]) begin
        empty <= (t_left > t_right) || (t_top > t_bottom);
        // a pixels place inside its tile is its low 6 / 5 bits, drop the lowest bit for the quad
        box_qx0 <= t_left[5:1];             box_qx1 <= t_right[5:1];
        box_qy0 <= {1'b0, t_top[4:1]};      box_qy1 <= {1'b0, t_bottom[4:1]};
        start_x <= {t_left[10:1], 1'b0};        // rounded down to an even pixel
        start_y <= {t_top[9:1], 1'b0};
    end

    // stage 3 multiply, step right x start x and step down x start y
    if (going[1]) begin
        m_ax0 <= s_a0 * sx;  m_ax1 <= s_a1 * sx;  m_ax2 <= s_a2 * sx;
        m_by0 <= s_b0 * sy;  m_by1 <= s_b1 * sy;  m_by2 <= s_b2 * sy;
        m_zx <= s_za * sx;   m_zy <= s_zb * sy;
        for (h = 0; h < 4; h = h + 1) begin
            m_cx[h * 64 +: 64] <= $signed(s_ca[h * 32 +: 32]) * sx;
            m_cy[h * 64 +: 64] <= $signed(s_cb[h * 32 +: 32]) * sy;
        end
        m_ux <= s_ua * sx;  m_uy <= s_ub * sy;
        m_vx <= s_va * sx;  m_vy <= s_vb * sy;
    end

    // stage 4 add, value at (0, 0) + both products = value at the start pixel
    if (going[2]) begin
        e0 <= c0 + m_ax0 + m_by0;
        e1 <= c1 + m_ax1 + m_by1;
        e2 <= c2 + m_ax2 + m_by2;
        z  <= z0 + m_zx + m_zy;                 // wraps at 32 bits like the rasters steps
        for (h = 0; h < 4; h = h + 1)
            colour_p[h * 32 +: 32] <= s_cc[h * 32 +: 32] + m_cx[h * 64 +: 32] + m_cy[h * 64 +: 32];
        tex_u <= s_uc + m_ux[26:0] + m_uy[26:0];        // wraps at 27 bits
        tex_v <= s_vc + m_vx[26:0] + m_vy[26:0];
    end

    // stage 5 sample offsets, shifts and adds only
    if (going[3]) begin
        for (k = 0; k < 3; k = k + 1) begin
            p_e4[k * 28 +: 28] <= ((edge_a(k) >>> 4) + (edge_b(k) >>> 4)) <<< 2;
            p_ab[k * 28 +: 28] <= edge_a(k) + edge_b(k);
        end
        p_z4 <= ($signed({{4{s_za[31]}}, s_za}) + $signed({{4{s_zb[31]}}, s_zb})) <<< 2;
        p_zab <= s_za + s_zb;
    end

    // stage 6 the change from the pixel centre to each sample
    if (going[4]) begin
        for (k = 0; k < 3; k = k + 1) begin
            q_e[(k * 2 + 0) * 28 +: 28] <= -$signed(p_e4[k * 28 +: 28]);     // sample 0
            q_e[(k * 2 + 1) * 28 +: 28] <=  $signed(p_e4[k * 28 +: 28]);     // sample 1
        end
        q_z[0 * 32 +: 32] <= (-p_z4 + 36'sd8) >>> 4;      // + 8 rounds to nearest
        q_z[1 * 32 +: 32] <= ( p_z4 + 36'sd8) >>> 4;
    end

    // stage 7 add the pixels place in the quad (+0, +a, +b, +a+b)
    if (going[5]) begin
        for (k = 0; k < 3; k = k + 1)
            for (t = 0; t < 2; t = t + 1) begin
                slot_edge[(k * 8 + 0 * 2 + t) * 28 +: 28] <= $signed(q_e[(k * 2 + t) * 28 +: 28]);
                slot_edge[(k * 8 + 1 * 2 + t) * 28 +: 28] <= $signed(q_e[(k * 2 + t) * 28 +: 28]) + edge_a(k);
                slot_edge[(k * 8 + 2 * 2 + t) * 28 +: 28] <= $signed(q_e[(k * 2 + t) * 28 +: 28]) + edge_b(k);
                slot_edge[(k * 8 + 3 * 2 + t) * 28 +: 28] <= $signed(q_e[(k * 2 + t) * 28 +: 28]) + $signed(p_ab[k * 28 +: 28]);
            end
        for (t = 0; t < 2; t = t + 1) begin
            slot_depth[(0 * 2 + t) * 32 +: 32] <= q_z[t * 32 +: 32];
            slot_depth[(1 * 2 + t) * 32 +: 32] <= q_z[t * 32 +: 32] + s_za;
            slot_depth[(2 * 2 + t) * 32 +: 32] <= q_z[t * 32 +: 32] + s_zb;
            slot_depth[(3 * 2 + t) * 32 +: 32] <= q_z[t * 32 +: 32] + p_zab[31:0];
        end
    end
end

// passed straight through
// edge k steps for stages 5-7
function signed [27:0] edge_a(input integer k);
    edge_a = (k == 0) ? s_a0 : (k == 1) ? s_a1 : s_a2;
endfunction
function signed [27:0] edge_b(input integer k);
    edge_b = (k == 0) ? s_b0 : (k == 1) ? s_b1 : s_b2;
endfunction

assign a0 = s_a0;  assign a1 = s_a1;  assign a2 = s_a2;      // sign extended to 40 bits
assign b0 = s_b0;  assign b1 = s_b1;  assign b2 = s_b2;
assign za = s_za;  assign zb = s_zb;
assign colour = s_colour;
assign smooth = s_smooth;
assign colour_pa = s_ca;
assign colour_pb = s_cb;
assign textured = s_textured;
assign texture_slot = s_slot;
assign texture_shift = s_shift;
assign texture_steep = s_steep;
assign tex_ua = s_ua;  assign tex_ub = s_ub;
assign tex_va = s_va;  assign tex_vb = s_vb;
assign depth_test = switches[0];
assign depth_write = switches[1];
assign colour_write = switches[2];
assign fogged = switches[3];

endmodule

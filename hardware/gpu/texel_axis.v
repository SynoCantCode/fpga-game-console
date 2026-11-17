// texel_axis.v
// one axis of a texture lookup
// takes a pixels u (or v) and gives the 2 texels to blend and the weight between them

module texel_axis (
    input wire clk,
    input wire signed [21:0] place,      // u or v in 1/256 texel at level 0
    input wire [3:0] level,              // mip level, already clamped
    input wire [3:0] log2_size,          // log2 of texture width or height
    input wire [1:0] rule,               // 0 repeat 1 clamp 2 mirror
    input wire bilinear,                 // 1 = blend 2 texels, 0 = nearest
    output reg [9:0] first,              // first texel
    output reg [9:0] second,             // second texel
    output reg [4:0] weight              // how far toward second, 0-31
);

localparam REPEAT = 2'd0, CLAMP = 2'd1, MIRROR = 2'd2;

// stage 1 scale down to the mip level
reg signed [21:0] s1_place;
reg [3:0] s1_log2;                       // size of this level
reg [1:0] s1_rule;
reg s1_bilinear;
always @(posedge clk) begin
    s1_place <= place >>> level;
    s1_log2 <= (log2_size > level) ? (log2_size - level) : 4'd0;
    s1_rule <= rule;
    s1_bilinear <= bilinear;
end

// stage 2 pick the texels and wrap them at the edge
function [9:0] at_edge(input signed [14:0] x, input [3:0] log2, input [1:0] how);
    reg [9:0] mask;                      // size - 1
    reg [9:0] low;
    reg above;                           // odd repeat, used by mirror
    reg signed [14:0] moved;
    begin
        mask = (10'd1 << log2) - 10'd1;
        low = x[9:0] & mask;
        moved = x >>> log2;
        above = moved[0];
        case (how)
            CLAMP:   at_edge = x[14] ? 10'd0 : (moved != 15'sd0) ? mask : low;
            MIRROR:  at_edge = above ? (mask - low) : low;
            default: at_edge = low;
        endcase
    end
endfunction

// texel centers sit at .5 so go back half a texel first
// one bit wider so it cant wrap
wire signed [22:0] s1_back = $signed({s1_place[21], s1_place}) - 23'sd128;
wire signed [14:0] s1_first = s1_bilinear ? s1_back[22:8] : {s1_place[21], s1_place[21:8]};
wire signed [14:0] s1_second = s1_bilinear ? (s1_first + 15'sd1) : s1_first;
always @(posedge clk) begin
    first <= at_edge(s1_first, s1_log2, s1_rule);
    second <= at_edge(s1_second, s1_log2, s1_rule);
    weight <= s1_bilinear ? s1_back[7:3] : 5'd0;
end

endmodule

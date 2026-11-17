// cache_address.v
// for one 4x4 texel block of a mip level
// gives its place in the texture cache, its tag and the ddr3 burst that holds it

module cache_address (
    input wire clk,
    input wire [7:0] slot,  // which texture
    input wire [3:0] level,  // mip level, already clamped
    input wire [3:0] log2w, log2h,  // texture size
    input wire [24:0] start,  // textures first burst in ddr3
    input wire [7:0] bx, by,  // block x and y (texel >> 2)
    output reg [9:0] place,  // cache place, 5 bits down 5 bits across
    output reg [17:0] tag,  // what the tag memory holds for this block
    output reg [24:0] burst  // the blocks burst in ddr3
);

// stage 1 place, tag and the parts of the burst
// mix = 7*slot + 3*level so small textures and levels dont land on the same places
wire [4:0] seven_slots = {slot[1:0], 3'b000} - slot[4:0];             // 8*slot - slot
wire [4:0] three_levels = {level[3:0], 1'b0} + {1'b0, level};         // 2*level + level
wire [4:0] mix = seven_slots + three_levels;
wire [4:0] five_mix = {mix[2:0], 2'b00} + mix;                        // 4*mix + mix
wire [4:0] eleven_mix = {mix[1:0], 3'b000} + {mix[3:0], 1'b0} + mix;  // 8*mix + 2*mix + mix
// a group is 8x8 blocks, these are log2 of how many groups
wire [2:0] groups_across0 = (log2w > 4'd5) ? (log2w - 4'd5) : 3'd0;
wire [2:0] groups_down0 = (log2h > 4'd5) ? (log2h - 4'd5) : 3'd0;
wire [4:0] level_and_5 = {1'b0, level} + 5'd5;
wire [2:0] groups_across = ({1'b0, log2w} > level_and_5) ? ({1'b0, log2w} - level_and_5) : 3'd0;
wire [3:0] groups_both0 = {1'b0, groups_across0} + {1'b0, groups_down0};
wire [17:0] twice_room = 18'd128 << groups_both0;                     // 2x the bursts of level 0
wire [9:0] group_number = ({5'd0, by[7:3]} << groups_across) | {5'd0, bx[7:3]};

reg [24:0] s1_start;
reg [17:0] s1_level_start;
reg [15:0] s1_inside;
reg [9:0] s1_place;
reg [17:0] s1_tag;
always @(posedge clk) begin
    s1_place <= {by[4:0] + eleven_mix, bx[4:0] + five_mix};
    s1_tag <= {slot, level, by[7:5], bx[7:5]};
    s1_start <= start;
    s1_level_start <= twice_room - (twice_room >> level);
    s1_inside <= {group_number, by[2:0], bx[2:0]};
end

// stage 2 add up the burst
always @(posedge clk) begin
    place <= s1_place;
    tag <= s1_tag;
    burst <= s1_start + {7'd0, s1_level_start} + {9'd0, s1_inside};
end

endmodule

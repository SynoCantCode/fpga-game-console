// gpu_registers.v
// the gpus registers, the cpu reads and writes them
// doorbell queue of command lists, error bits, near limit, background, fog, lamp tables, texture slots

module gpu_registers (
    input wire clk,
    input wire reset,

    // the register port, one access at a time
    input wire write,                   // 1 for one clock
    input wire read,                    // 1 for one clock, rdata shows up next clock
    input wire [5:0] offset,            // byte offset
    input wire [31:0] wdata,
    output reg [31:0] rdata,

    // to the gpu
    output wire list_waiting,           // a command list is queued
    output wire [24:0] next_list,       // its address in bursts, oldest first
    input wire list_taken,              // 1 for one clock, the gpu took it
    output reg switch_wanted,           // leave the current list at its next end frame
    input wire switch_done,             // 1 for one clock, switch happened
    input wire front_begin,             // 1 for one clock, front half starts a frame
    input wire draw_begin,              // 1 for one clock, back half starts drawing one
    output reg [31:0] near,             // near limit the gpu uses
    output reg [31:0] clear_colour,  // background colour the gpu uses
    output reg [23:0] fog_colour,       // colour fogged triangles fade to
    output reg fog_table_write,         // 1 for one clock, write a fog table row
    output reg [7:0] fog_table_row,
    output reg [15:0] fog_table_word,
    output reg [1:0] lamp_table_write,  // bit k = 1 for one clock, write a row of lamp k
    output reg [7:0] lamp_table_row,
    output reg [15:0] lamp_table_word,
    output reg texture_slot_write,      // 1 for one clock, write a texture slot
    output reg [7:0] texture_slot_number,
    output reg [41:0] texture_slot_description,

    // from the gpu
    input wire stopped,
    input wire frame_finished,          // 1 for one clock
    input wire overflow,                // overflow flag for this frame
    input wire [31:0] dropped_near,     // counts of dropped triangles
    input wire [31:0] dropped_too_far_out,
    output reg [2:0] perf_select,       // which speed counter a read shows
    input wire [31:0] perf_value
);

localparam DOORBELL = 6'h00, FRAMES_DRAWN = 6'h04, ERRORS = 6'h08, NEAR_LIMIT = 6'h0C, BACKGROUND = 6'h10,  // register offsets
           MISC = 6'h14, SWITCH = 6'h18, PERF = 6'h1C, FOG_COLOUR = 6'h20, FOG_TABLE = 6'h24,
           LAMP_TABLE = 6'h28, TEXTURE_BASE = 6'h2C, TEXTURE_SLOT = 6'h30;

// doorbell queue, 4 list addresses
reg [24:0] queue [0:3];
reg [1:0] q_in, q_out;
reg [2:0] q_count;                      // 0 to 4
assign list_waiting = (q_count != 0);
assign next_list = queue[q_out];
wire ring = write && (offset == DOORBELL);
wire q_push = ring && (q_count != 3'd4);

// settings as written, the gpu takes them at its next frame start so a frame never mixes old and new
reg [31:0] near_written, background_written;
reg [23:0] fog_colour_written;
reg [24:0] texture_base_written;        // in bursts

reg [31:0] frames_drawn;
reg [3:0] errors;                       // sticky until cleared
reg [31:0] misc;
reg [31:0] last_near, last_far;         // drop counts last time we looked

always @(posedge clk) begin
    if (reset) begin
        q_in <= 0;  q_out <= 0;  q_count <= 0;
        switch_wanted <= 1'b0;
        near <= 32'd19661;              near_written <= 32'd19661;
        clear_colour <= 32'hFF1C_2230;  background_written <= 32'hFF1C_2230;
        fog_colour <= 24'h1C_2230;      fog_colour_written <= 24'h1C_2230;
        fog_table_write <= 1'b0;
        lamp_table_write <= 2'b00;
        texture_slot_write <= 1'b0;
        texture_base_written <= 0;
        frames_drawn <= 0;
        errors <= 4'b0000;
        misc <= 0;
        perf_select <= 0;
        last_near <= 0;
        last_far <= 0;
        rdata <= 0;
    end else begin
        // doorbell queue
        if (q_push) begin
            queue[q_in] <= wdata[29:5];                 // bytes to bursts of 32
            q_in <= q_in + 1'b1;
        end
        if (list_taken) q_out <= q_out + 1'b1;
        q_count <= q_count + q_push - list_taken;

        // settings take effect at frame starts
        if (front_begin) near <= near_written;
        if (draw_begin) clear_colour <= background_written;
        if (draw_begin) fog_colour <= fog_colour_written;
        fog_table_write <= write && (offset == FOG_TABLE);      // table writes go out a clock after the write
        fog_table_row <= wdata[23:16];
        fog_table_word <= wdata[15:0];
        lamp_table_write <= (write && (offset == LAMP_TABLE)) ? (wdata[24] ? 2'b10 : 2'b01) : 2'b00;
        lamp_table_row <= wdata[23:16];
        lamp_table_word <= wdata[15:0];
        // slot description = the written bits on top of the texture base
        texture_slot_write <= write && (offset == TEXTURE_SLOT);
        texture_slot_number <= wdata[7:0];
        texture_slot_description <= {wdata[24:8], texture_base_written};
        if (switch_done) switch_wanted <= 1'b0;

        // writes
        if (write) begin
            case (offset)
                ERRORS:     errors <= errors & ~wdata[3:0];     // 1s clear
                NEAR_LIMIT: near_written <= wdata;
                BACKGROUND: background_written <= wdata;
                MISC:       misc <= wdata;
                SWITCH:     if (wdata[0]) switch_wanted <= 1'b1;
                PERF:       perf_select <= wdata[2:0];
                FOG_COLOUR: fog_colour_written <= wdata[23:0];
                TEXTURE_BASE: texture_base_written <= wdata[29:5];      // bytes to bursts of 32
                default: ;
            endcase
        end

        // gpu reports, after the writes so a new error isnt lost to a clear
        if (frame_finished) frames_drawn <= frames_drawn + 1;
        last_near <= dropped_near;
        last_far <= dropped_too_far_out;
        if (overflow) errors[0] <= 1'b1;
        if (dropped_near != last_near) errors[1] <= 1'b1;
        if (dropped_too_far_out != last_far) errors[2] <= 1'b1;
        if (ring && !q_push) errors[3] <= 1'b1;         // queue was full, list dropped

        // reads
        if (read) begin
            case (offset)
                DOORBELL:     rdata <= {28'd0, q_count, !stopped};
                FRAMES_DRAWN: rdata <= frames_drawn;
                ERRORS:       rdata <= {28'd0, errors};
                NEAR_LIMIT:   rdata <= near_written;
                BACKGROUND:   rdata <= background_written;
                MISC:         rdata <= misc;
                SWITCH:       rdata <= {31'd0, switch_wanted};
                PERF:         rdata <= perf_value;
                FOG_COLOUR:   rdata <= {8'd0, fog_colour_written};
                TEXTURE_BASE: rdata <= {2'd0, texture_base_written, 5'd0};
                default:      rdata <= 0;
            endcase
        end
    end
end

endmodule

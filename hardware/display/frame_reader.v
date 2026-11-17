// frame_reader.v
// reads the frame buffer from ddr3 and gives the display one pixel per tick
// memory side asks the arbiter for bursts ahead of the display, a fifo carries them to the pixel clock
// pixels are 0xAARRGGBB, a burst is 8 pixels with the leftmost in the low 32 bits

module frame_reader #(
    parameter FRAME_BURSTS = 115_200              // bursts per frame, 1280 x 720 / 8
) (
    // memory side
    input wire mem_clk,
    input wire mem_reset,
    input wire [24:0] show_start,       // start of the frame buffer to show, in bursts
    output reg switched,                // pulse, a frame just started from show_start
    output reg req,                     // asking the arbiter for a read
    output wire [2:0] cmd,              // always a read
    output wire [28:0] addr,            // address of the next burst
    input wire grant,                   // the read went out
    input wire rd_valid,                // rd_data is our answer
    input wire [255:0] rd_data,

    // display side
    input wire pixel_clk,
    input wire pixel_reset,
    input wire visible,                 // 1 = a pixel is needed this tick
    input wire below_picture,           // 1 = hidden rows below the picture
    output wire [7:0] red,
    output wire [7:0] green,
    output wire [7:0] blue,
    output reg [31:0] underruns         // pixels shown black because the fifo was empty, should stay 0
);

localparam CMD_READ = 3'b001;
localparam FIFO_ENTRIES = 256;

// memory side
reg [24:0] next_burst;        // which burst of the frame to ask for next
reg [24:0] next_address;      // its address in ddr3
reg [24:0] answer_burst;      // which burst the next answer is, answers come back in order
reg [9:0] on_the_way;         // reads sent with no answer yet
wire [8:0] fifo_count;        // entries in the fifo as the memory side sees it

// only ask if the answer will have room in the fifo
// req is decided a tick early so keep a few slots spare
localparam SPARE = 4;
// start a run only when theres room for RUN reads, then go until full
// neighbouring reads in a row are faster for ddr3
localparam RUN = 8;
assign cmd = CMD_READ;
assign addr = {1'b0, next_address, 3'b000};

always @(posedge mem_clk) begin
    if (mem_reset) begin
        next_burst <= 0;
        next_address <= show_start;
        answer_burst <= 0;
        on_the_way <= 0;
        req <= 0;
        switched <= 0;
    end else begin
        req <= req ? ((fifo_count + on_the_way) < (FIFO_ENTRIES - SPARE))           // in a run, until full
                   : ((fifo_count + on_the_way) < (FIFO_ENTRIES - SPARE - RUN));    // start, room for a whole run
        switched <= 0;
        if (grant) begin
            if (next_burst == FRAME_BURSTS - 1) begin
                next_burst <= 0;                      // top of the picture, switch buffers only here
                next_address <= show_start;
                switched <= 1;
            end else begin
                next_burst <= next_burst + 1;
                next_address <= next_address + 1;
            end
        end
        if (rd_valid)
            answer_burst <= (answer_burst == FRAME_BURSTS - 1) ? 0 : answer_burst + 1;
        on_the_way <= on_the_way + grant - rd_valid;
    end
end

// the fifo, each entry is a burst + 1 bit for first burst of a frame
wire [256:0] front;           // front entry
wire fifo_empty;
wire take_entry;

async_fifo #(.WIDTH(257), .ADDR_BITS(8)) fifo (
    .write_clk(mem_clk), .write_reset(mem_reset),
    .write_en(rd_valid), .write_data({answer_burst == 0, rd_data}),
    .full(), .write_count(fifo_count),
    .read_clk(pixel_clk), .read_reset(pixel_reset),
    .read_en(take_entry), .read_data(front), .empty(fifo_empty)
);

// display side
reg [2:0] pixel_in_entry;      // which of the 8 pixels in the front entry is next
wire frame_start_in_front = front[256];

// below the picture throw entries away until the front one starts a frame
wire skipping = below_picture && !fifo_empty && !frame_start_in_front;
wire last_pixel_of_entry = (pixel_in_entry == 3'd7);
assign take_entry = skipping || (visible && !fifo_empty && last_pixel_of_entry);

// the pixel, black if the fifo is empty
wire [31:0] pixel = front[pixel_in_entry*32 +: 32];
wire have_pixel = visible && !fifo_empty;
assign red   = have_pixel ? pixel[23:16] : 8'd0;
assign green = have_pixel ? pixel[15:8]  : 8'd0;
assign blue  = have_pixel ? pixel[7:0]   : 8'd0;

always @(posedge pixel_clk) begin
    if (pixel_reset) begin
        pixel_in_entry <= 0;
        underruns <= 0;
    end else begin
        if (below_picture)
            pixel_in_entry <= 0;                          // line up for the next frame
        else if (have_pixel)
            pixel_in_entry <= pixel_in_entry + 1;         // wraps after 7
        if (visible && fifo_empty)
            underruns <= underruns + 1;
    end
end
endmodule

// frame_reader_tb.v
// frame reader on the real memory path with a hungry fake gpu competing the whole time
// small fake screen with a known picture, checks every pixel, no underruns, no fifo overflow,
// recovery after a glitch, and that a buffer switch only happens at the top of a frame
`timescale 1ns / 1ps

module frame_reader_tb;

    // the fake screen
    localparam WIDTH = 64, HEIGHT = 16;                 // visible pixels
    localparam ROW_TICKS = 100;                         // 64 visible + 36 hidden ticks per row
    localparam ROWS = 20;                               // 16 visible + 4 hidden rows per frame
    localparam FRAME_BURSTS = WIDTH * HEIGHT / 8;
    localparam FRAMES = 8;

    reg mem_clk = 0, pixel_clk = 0;
    always #5     mem_clk = ~mem_clk;                   // 100 MHz
    always #6.741 pixel_clk = ~pixel_clk;               // 74.17 MHz
    reg mem_reset = 1, pixel_reset = 1;

    // what each pixel should be, made from its spot
    function [31:0] picture(input integer px, input integer py);
        picture = {8'hFF, px[7:0] * 8'd4, py[7:0] * 8'd16, (px[7:0] + py[7:0]) ^ 8'h5A};
    endfunction

    // the memory path
    wire [4:0] req, grant, rd_valid;
    wire [255:0] rd_data;
    wire [2:0] fr_cmd;  wire [28:0] fr_addr;
    reg gpu_req = 0;  reg [28:0] gpu_addr = 0;

    wire calibrated, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, mem_rd_valid;
    wire [2:0] cmd;  wire [28:0] addr;  wire [255:0] wr_data, mem_rd_data;  wire [31:0] wr_data_mask;

    // the frame reader
    wire visible, below_picture;
    wire [7:0] red, green, blue;
    wire [31:0] underruns;
    reg [24:0] show_start = 0;
    wire switched;
    frame_reader #(.FRAME_BURSTS(FRAME_BURSTS)) reader (
        .mem_clk(mem_clk), .mem_reset(mem_reset), .show_start(show_start), .switched(switched),
        .req(req[1]), .cmd(fr_cmd), .addr(fr_addr), .grant(grant[1]), .rd_valid(rd_valid[1]), .rd_data(rd_data),
        .pixel_clk(pixel_clk), .pixel_reset(pixel_reset),
        .visible(visible), .below_picture(below_picture),
        .red(red), .green(green), .blue(blue), .underruns(underruns)
    );

    // arbiter, port 1 is the frame reader and port 2 the hungry gpu, the rest unused
    assign req[0] = 0;  assign req[2] = gpu_req;  assign req[3] = 0;  assign req[4] = 0;
    memory_arbiter #(.PORTS(5)) arbiter (
        .clk(mem_clk), .reset(mem_reset),
        .req(req),
        .port_cmd({3'b001, 3'b001, 3'b000, fr_cmd, 3'b001}),
        .port_addr({29'd0, 29'd0, gpu_addr, fr_addr, 29'd0}),
        .port_wr_data({256'd0, 256'd0, {8{32'hDEADBEEF}}, 256'd0, 256'd0}),
        .port_wr_mask(160'd0),
        .grant(grant), .rd_valid(rd_valid), .rd_data(rd_data),
        .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr), .wr_data_rdy(wr_data_rdy),
        .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data), .wr_data_mask(wr_data_mask),
        .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data)
    );

    fake_memory_controller #(.BLOCKS(1024)) memory (
        .clk(mem_clk), .calibrated(calibrated), .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data(wr_data),
        .wr_data_mask(wr_data_mask), .rd_data_valid(mem_rd_valid), .rd_data(mem_rd_data)
    );

    // fill the frame buffer in the fake memory with the picture
    integer b, k, px, py;
    initial begin
        #1;   // after the fake memory has cleared itself
        for (b = 0; b < FRAME_BURSTS; b = b + 1)
            for (k = 0; k < 8; k = k + 1) begin
                px = (b * 8 + k) % WIDTH;
                py = (b * 8 + k) / WIDTH;
                memory.memory[b][k*32 +: 32] = picture(px, py);
                memory.memory[256 + b][k*32 +: 32] = picture(px, py);     // second buffer gets the same picture
            end
    end

    // switch buffers at random moments and check each frame is read from one buffer only
    integer flips = 0, frames_from_b = 0, mixed_reads = 0;
    reg [24:0] frame_base = 0;
    always @(posedge mem_clk) begin
        if (!mem_reset && ($urandom % 300) == 0) begin show_start <= (show_start == 0) ? 25'd256 : 25'd0; flips = flips + 1; end
        if (!mem_reset && grant[1]) begin
            if (reader.next_burst == 0) begin                       // first burst of a frame tells which buffer
                frame_base = fr_addr[27:3];
                if (frame_base == 256) frames_from_b = frames_from_b + 1;
            end else if (fr_addr[27:3] != frame_base + reader.next_burst)
                mixed_reads = mixed_reads + 1;                       // a burst from another buffer mid frame
        end
    end

    // hungry gpu, writes nonstop to blocks that arent the frame buffer
    always @(posedge mem_clk) begin
        #1;
        if (!mem_reset && calibrated) begin
            if (grant[2]) gpu_addr = {1'b0, 25'd500 + ((gpu_addr[27:3] - 25'd500 + 25'd1) % 25'd500), 3'b000};
            gpu_req = 1;
        end
    end
    initial gpu_addr = {1'b0, 25'd500, 3'b000};

    // the fake displays timing
    integer tick_in_row = 0, row = 0, frame = 0;
    reg glitch_now = 0;                        // 1 for one tick = take one pixel too many
    reg running = 0;
    assign visible = ((tick_in_row < WIDTH) && (row < HEIGHT) && running) || glitch_now;
    assign below_picture = (row >= HEIGHT) && running;

    always @(posedge pixel_clk) if (running) begin
        if (tick_in_row == ROW_TICKS - 1) begin
            tick_in_row <= 0;
            if (row == ROWS - 1) begin row <= 0; frame <= frame + 1; end
            else row <= row + 1;
        end else tick_in_row <= tick_in_row + 1;
    end

    // check every visible pixel
    integer wrong [0:FRAMES];
    integer checked = 0;
    initial for (k = 0; k <= FRAMES; k = k + 1) wrong[k] = 0;

    always @(posedge pixel_clk) begin
        if (running && visible && !glitch_now && frame >= 1 && frame < FRAMES) begin
            if ({red, green, blue} !== (picture(tick_in_row, row) & 32'h00FFFFFF)) begin   // screen shows rgb not alpha
                if (wrong[frame] < 3) $display("        frame %0d, pixel (%0d, %0d): got %h, expected %h",
                                               frame, tick_in_row, row, {red, green, blue}, picture(tick_in_row, row) & 32'h00FFFFFF);
                wrong[frame] = wrong[frame] + 1;
            end
            checked = checked + 1;
        end
    end

    // the fifo must never be written while full
    integer overflows = 0;
    always @(posedge mem_clk) if (reader.fifo.full && rd_valid[1]) overflows = overflows + 1;

    // count runs, the readers grants should come in runs of neighbouring reads
    // a run ends when another ports command goes to memory in between
    integer runs = 0, run_grants = 0;
    reg last_was_reader = 0;
    always @(posedge mem_clk) if (running && grant != 0) begin
        if (grant[1]) begin
            run_grants = run_grants + 1;
            if (!last_was_reader) runs = runs + 1;
        end
        last_was_reader = grant[1];
    end

    // check helper
    integer failures = 0;

    task check(input string what, input integer got, input integer low, input integer high);
        if (got >= low && got <= high) begin
            $display("  ok    %0s: %0d", what, got);
        end else begin
            $display("  FAIL  %0s: got %0d, expected %0d .. %0d", what, got, low, high);
            failures = failures + 1;
        end
    endtask

    // the test
    integer underruns_after_start, glitch_frame;

    initial begin
        $display("frame_reader test: 64 x 16 pretend screen, %0d frames, a hungry GPU competing for memory", FRAMES);
        repeat (5) @(posedge mem_clk);
        mem_reset = 0;
        pixel_reset = 0;
        wait (calibrated);
        repeat (2000) @(posedge mem_clk);    // let the frame reader fill the fifo
        @(negedge pixel_clk);
        running = 1;

        wait (frame == 1);
        underruns_after_start = underruns;

        // the glitch, halfway through frame 4 the display takes one pixel too many
        wait (frame == 4 && row == 8 && tick_in_row == 80);   // in the hidden part of the row
        @(negedge pixel_clk); glitch_now = 1;
        @(negedge pixel_clk); glitch_now = 0;
        glitch_frame = 4;

        wait (frame == FRAMES);
        running = 0;

        $display("Every visible pixel (frames 1 .. %0d):", FRAMES - 1);
        check("pixels checked", checked, (FRAMES - 1) * WIDTH * HEIGHT - 1, (FRAMES - 1) * WIDTH * HEIGHT);
        check("wrong pixels in frames 1 - 3", wrong[1] + wrong[2] + wrong[3], 0, 0);
        check("wrong pixels in frame 4 (the glitch: the rest of that frame is shifted, expected)", wrong[4] > 0, 1, 1);
        check("wrong pixels in frames 5 - 7 (lined up again at the next frame)", wrong[5] + wrong[6] + wrong[7], 0, 0);
        $display("Keeping up:");
        check("underruns once running (frames 1 ..)", underruns - underruns_after_start, 0, 0);
        check("times the FIFO was written while full", overflows, 0, 0);
        check("reads per run x 10 (runs of neighbouring reads; at least 6 a run)", (run_grants * 10) / (runs > 0 ? runs : 1), 60, 1000);
        check("GPU writes that went through meanwhile (it really was competing)", memory.writes_taken > 1000, 1, 1);
        check("buffer flips asked for (many, at random moments)", flips > 10, 1, 1);
        check("frames read from the second buffer (switching really happened)", frames_from_b > 0, 1, 1);
        check("bursts read from the wrong buffer mid-frame", mixed_reads, 0, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

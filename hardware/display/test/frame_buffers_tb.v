// frame_buffers_tb.v
// triple buffering test, a fake gpu draws frames of random length and a fake tv switches at a steady pace
// checks the gpu never draws into a buffer the tv is using, the tv only gets the newest finished frame,
// and the gpu never has to wait
`timescale 1ns / 1ps

module frame_buffers_tb;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    wire [24:0] show_start, draw_start;
    wire draw_ok;
    reg switched = 0, draw_begin = 0, draw_end = 0;
    wire [1:0] showing, ready, drawing;
    wire ready_valid, drawing_valid;

    frame_buffers #(.BUFFER0(25'd0), .BUFFER1(25'd1000), .BUFFER2(25'd2000)) keeper (
        .clk(clk), .reset(reset), .show_start(show_start), .switched(switched),
        .draw_ok(draw_ok), .draw_start(draw_start), .draw_begin(draw_begin), .draw_end(draw_end),
        .showing(showing), .ready_valid(ready_valid), .ready(ready), .drawing_valid(drawing_valid), .drawing(drawing));

    integer failures = 0;
    task check(input [8*64-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    function integer index_of(input [24:0] start);
        index_of = start / 1000;
    endfunction

    // what each buffer holds, a frame number and if its finished
    integer frame_in [0:2];
    integer finished [0:2];
    integer next_frame = 1, newest_finished = 0, last_shown = 0;
    integer bad_draw = 0, bad_show = 0, stale_show = 0, kept_waiting = 0, frames_shown = 0, frames_skipped = 0;
    integer gpu_left = 0, tv_left = 0, t, b;
    reg gpu_busy = 0;

    initial begin
        for (b = 0; b < 3; b = b + 1) begin frame_in[b] = 0; finished[b] = 1; end
        $display("frame_buffers test: triple buffering, a GPU of random speed against a steady TV");
        repeat (3) @(posedge clk);
        reset = 0;

        for (t = 0; t < 200000; t = t + 1) begin
            @(negedge clk);
            // tv switches every 167 ticks
            switched = (tv_left == 0);
            tv_left = (tv_left == 0) ? 166 : tv_left - 1;
            // gpu starts when allowed, each frame takes a random time
            draw_begin = 0;  draw_end = 0;
            if (gpu_busy) begin
                gpu_left = gpu_left - 1;
                if (gpu_left == 0) draw_end = 1;
            end else if (draw_ok) begin
                draw_begin = 1;
            end else
                kept_waiting = kept_waiting + 1;

            // checks before the tick
            // never drawing into the showing buffer or the one about to be shown
            if (drawing_valid && (drawing == showing || drawing == index_of(show_start))) bad_draw = bad_draw + 1;
            if (draw_begin && (index_of(draw_start) == showing || index_of(draw_start) == index_of(show_start)))
                bad_draw = bad_draw + 1;
            // what the tv is about to take
            if (switched) begin
                b = index_of(show_start);
                if (!finished[b]) bad_show = bad_show + 1;
                if (frame_in[b] < last_shown) bad_show = bad_show + 1;
                if (frame_in[b] != newest_finished) stale_show = stale_show + 1;
                if (frame_in[b] > last_shown) begin
                    frames_skipped = frames_skipped + (frame_in[b] - last_shown - 1);
                    frames_shown = frames_shown + 1;
                end
                last_shown = frame_in[b];
            end

            // the tests own bookkeeping on the tick
            if (draw_end) begin
                finished[drawing] = 1;
                newest_finished = frame_in[drawing];
                gpu_busy = 0;
            end
            if (draw_begin) begin
                b = index_of(draw_start);
                frame_in[b] = next_frame;  finished[b] = 0;
                next_frame = next_frame + 1;
                gpu_busy = 1;
                gpu_left = (t / 20000) % 2 == 0 ? 20 + $urandom % 120 : 150 + $urandom % 350;   // fast spells and slow spells
            end
        end

        $display("200,000 ticks; %0d frames drawn, %0d shown, %0d skipped (the GPU was faster than the TV)",
                 next_frame - 1, frames_shown, frames_skipped);
        check("times the GPU drew into the showing (or next) buffer", bad_draw, 0);
        check("times the TV got an unfinished or older frame", bad_show, 0);
        check("times the TV got a frame that wasn't the newest finished", stale_show, 0);
        check("ticks the GPU was kept waiting", kept_waiting, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

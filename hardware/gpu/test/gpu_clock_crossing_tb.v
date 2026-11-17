// gpu_clock_crossing_tb.v
// tests gpu_clock_crossing.v with the gpu and memory side on unrelated clocks
// fake parts on both sides, checks every read answer comes back right and in order
// and that frames get drawn and shown without drawing into the buffer on the tv
`timescale 1ns / 1ps

module gpu_clock_crossing_tb;

    reg gpu_clk = 0, mem_clk = 0;
`ifndef GPU_HALF
`define GPU_HALF 6.25
`endif
`ifndef GPU_START
`define GPU_START 3.7
`endif
    // gpu clock, starts at an odd moment so the edges slide past each other
    initial begin #(`GPU_START); forever #(`GPU_HALF) gpu_clk = ~gpu_clk; end
    always #5 mem_clk = ~mem_clk;                                    // 100 MHz
    reg gpu_reset = 1, mem_reset = 1;

    // the crossing
    reg g_req = 0;
    reg [2:0] g_cmd = 0;
    reg [28:0] g_addr = 0;
    reg [255:0] g_wr_data = 0;
    wire g_grant, g_rd_valid, g_buffer_ok, g_tv_frame;
    wire [255:0] g_rd_data;
    wire [24:0] g_buffer_start;
    reg g_buffer_begin = 0, g_buffer_end = 0;
    wire m_req, m_rd_valid_unused;
    wire [2:0] m_cmd;
    wire [28:0] m_addr;
    wire [255:0] m_wr_data;
    wire [31:0] m_wr_mask;
    reg m_grant = 0, m_rd_valid = 0;
    reg [255:0] m_rd_data = 0;
    wire m_buffer_ok, m_buffer_begin, m_buffer_end;
    wire [24:0] m_buffer_start, show_start;
    reg m_tv_frame = 0;

    gpu_clock_crossing dut (
        .gpu_clk(gpu_clk), .gpu_reset(gpu_reset),
        .g_req(g_req), .g_cmd(g_cmd), .g_addr(g_addr), .g_wr_data(g_wr_data), .g_wr_mask(32'd0),
        .g_grant(g_grant), .g_rd_valid(g_rd_valid), .g_rd_data(g_rd_data),
        .g_buffer_ok(g_buffer_ok), .g_buffer_start(g_buffer_start), .g_buffer_begin(g_buffer_begin),
        .g_buffer_end(g_buffer_end), .g_tv_frame(g_tv_frame),
        .mem_clk(mem_clk), .mem_reset(mem_reset),
        .m_req(m_req), .m_cmd(m_cmd), .m_addr(m_addr), .m_wr_data(m_wr_data), .m_wr_mask(m_wr_mask),
        .m_grant(m_grant), .m_rd_valid(m_rd_valid), .m_rd_data(m_rd_data),
        .m_buffer_ok(m_buffer_ok), .m_buffer_start(m_buffer_start), .m_buffer_begin(m_buffer_begin),
        .m_buffer_end(m_buffer_end), .m_tv_frame(m_tv_frame)
    );

    wire [1:0] showing;
    frame_buffers #(.BUFFER0(25'd0), .BUFFER1(25'd115200), .BUFFER2(25'd230400)) keeper (
        .clk(mem_clk), .reset(mem_reset),
        .show_start(show_start), .switched(m_tv_frame),
        .draw_ok(m_buffer_ok), .draw_start(m_buffer_start), .draw_begin(m_buffer_begin), .draw_end(m_buffer_end),
        .showing(showing), .ready_valid(), .ready(), .drawing_valid(), .drawing()
    );

    integer failures = 0;
    task check(input [8*60-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    function [255:0] random256(input integer unused);
        integer k;
        for (k = 0; k < 8; k = k + 1) random256[k * 32 +: 32] = $urandom;
    endfunction

    // gpu side, a fake memory port doing random reads and writes
    reg [255:0] model [0:63];              // what memory holds, in the order the gpu asked
    reg [255:0] expected [0:65535];        // each reads answer in order
    integer reads_asked = 0, writes_asked = 0, answers = 0, wrong = 0, door_on = 1;
    integer i;
    initial for (i = 0; i < 64; i = i + 1) model[i] = 0;

    always @(posedge gpu_clk) begin
        if (!gpu_reset) begin
            if (g_req && g_grant) begin                     // taken this tick
                if (g_cmd == 3'b001) begin
                    expected[reads_asked % 65536] = model[g_addr[5:0]];
                    reads_asked = reads_asked + 1;
                end else begin
                    model[g_addr[5:0]] = g_wr_data;
                    writes_asked = writes_asked + 1;
                end
                g_req <= 1'b0;
            end
            // new request only when none is waiting
            if (!(g_req && !g_grant) && door_on && ($urandom % 4 != 0)) begin
                g_req <= 1'b1;
                g_cmd <= ($urandom % 3 == 0) ? 3'b000 : 3'b001;
                g_addr <= $urandom % 64;
                g_wr_data <= random256(0);
            end
            if (g_rd_valid) begin
                if (g_rd_data !== expected[answers % 65536]) begin
                    if (wrong < 5) $display("        wrong answer %0d: got %h", answers, g_rd_data[31:0]);
                    wrong = wrong + 1;
                end
                answers = answers + 1;
            end
        end
    end

    // gpu side, a fake command processor that draws for a random time
    integer gpu_tv_ticks = 0, frames_begun = 0, frames_ended = 0, draw_left = 0, waiting = 1, tv_seen = 0;
    reg [24:0] drawing_into;
    reg drawing = 0;
    always @(posedge gpu_clk) begin
        g_buffer_begin <= 1'b0;
        g_buffer_end <= 1'b0;
        if (!gpu_reset) begin
            if (g_tv_frame) begin gpu_tv_ticks = gpu_tv_ticks + 1; tv_seen = 1; end
            if (!drawing && g_buffer_ok && tv_seen && !g_buffer_begin) begin
                drawing <= 1'b1;
                drawing_into <= g_buffer_start;
                g_buffer_begin <= 1'b1;
                tv_seen = 0;
                draw_left = 200 + $urandom % 2500;           // sometimes longer than a tv frame
                frames_begun = frames_begun + 1;
            end else if (drawing) begin
                if (draw_left == 0) begin
                    drawing <= 1'b0;
                    g_buffer_end <= 1'b1;
                    frames_ended = frames_ended + 1;
                end else draw_left = draw_left - 1;
            end
        end
    end

    // memory side, a fake arbiter and DDR3
    reg [255:0] memory [0:63];
    reg [255:0] queue_data [0:1023];
    integer queue_time [0:1023];
    integer q_in = 0, q_out = 0, mem_tick = 0, bad_buffer = 0, fifo_full = 0, tv_ticks = 0, show_changes = 0;
    integer next_tv = 1500, grant_mode = 0, slow_answers = 0, most_out = 0;
    reg [1:0] last_showing = 0;
    initial for (i = 0; i < 64; i = i + 1) memory[i] = 0;

    always @(posedge mem_clk) begin
        mem_tick = mem_tick + 1;
        m_rd_valid <= 1'b0;
        m_tv_frame <= 1'b0;
        if (!mem_reset) begin
            // take a request, sometimes every tick sometimes rarely
            if (mem_tick % 3000 == 0) begin grant_mode = $urandom % 3; slow_answers = ($urandom % 3 == 0); end
            if (m_req && m_grant) begin
                if (m_cmd == 3'b001) begin
                    queue_data[q_in % 1024] = memory[m_addr[5:0]];
                    queue_time[q_in % 1024] = mem_tick + ((grant_mode == 0 && slow_answers) ? 3000 : 5 + $urandom % 36);
                    q_in = q_in + 1;
                end else memory[m_addr[5:0]] = m_wr_data;
            end
            m_grant <= (grant_mode == 0) ? 1'b1 : (grant_mode == 1) ? ($urandom % 2) : ($urandom % 8 == 0);
            // answer reads in order once their time comes
            if (q_out < q_in && queue_time[q_out % 1024] <= mem_tick) begin
                m_rd_valid <= 1'b1;
                m_rd_data <= queue_data[q_out % 1024];
                q_out = q_out + 1;
            end
`ifndef NETLIST         // looks inside the crossing, cant do that on a netlist
            if (dut.answers.full) fifo_full = fifo_full + 1;
            if (dut.reads_out > most_out) most_out = dut.reads_out;
`endif
            // the tv
            if (mem_tick == next_tv) begin
                m_tv_frame <= 1'b1;
                tv_ticks = tv_ticks + 1;
                next_tv = mem_tick + 1400 + $urandom % 200;
            end
            if (showing != last_showing) show_changes = show_changes + 1;
            last_showing = showing;
            // the gpu must never draw into the buffer on the tv
            if (drawing && drawing_into == show_start) bad_buffer = bad_buffer + 1;
        end
    end

    // a finished frame must reach frame_buffers only after every request sent before it
    integer tb_taken = 0, tb_delivered = 0, ends_said = 0, ends_seen = 0, early_ends = 0, end_waits_total = 0;
    integer end_mark [0:4095];
    always @(posedge gpu_clk) begin
        if (!gpu_reset && g_buffer_end) begin                 // its own count
            end_mark[ends_said % 4096] = tb_taken + ((g_req && g_grant) ? 1 : 0);
            ends_said = ends_said + 1;
        end
        if (!gpu_reset && g_req && g_grant) tb_taken = tb_taken + 1;
    end
    always @(posedge mem_clk) begin
        if (!mem_reset && m_req && m_grant) tb_delivered = tb_delivered + 1;
        if (!mem_reset && m_buffer_end) begin
            if (tb_delivered < end_mark[ends_seen % 4096]) early_ends = early_ends + 1;
            ends_seen = ends_seen + 1;
        end
`ifndef OLD_CROSSING
`ifndef NETLIST
        if (!mem_reset && dut.m_end_waits) end_waits_total = end_waits_total + 1;
`endif
`endif
    end

    // every buffer the gpu gets must be one of the 3
    integer bad_start = 0;
    always @(posedge gpu_clk)
        if (g_buffer_begin && !(drawing_into == 0 || drawing_into == 115200 || drawing_into == 230400)) bad_start = bad_start + 1;

    initial begin
        $display("gpu_clock_crossing test: GPU half-tick %0.4f ns, memory side at 100 MHz, unrelated", `GPU_HALF);
        #200; mem_reset = 0;
        #95; gpu_reset = 0;
        #3000000;                                       // 3 ms
        door_on = 0;
        #100000;                                        // let the last answers come back
        $display("Memory: %0d reads, %0d writes asked", reads_asked, writes_asked);
        check("answers (one per read)", answers, reads_asked);
        check("wrong answers", wrong, 0);
        check("ticks the answer FIFO was full", fifo_full, 0);
        // make sure there was enough traffic
        check("reads asked > 40,000", reads_asked > 40000, 1);
        // the read limit must have been reached but not passed
`ifndef NETLIST
        check("most reads in flight 100 .. 114 (limit 112 + 2 a tick late)", (most_out >= 100) && (most_out <= 114), 1);
        $display("        (most reads in flight: %0d)", most_out);
`else
        $display("        (reads in flight: not looked at on a netlist)");
`endif
        $display("Frames: %0d begun, %0d ended, %0d TV ticks, the TV moved on %0d times", frames_begun, frames_ended, tv_ticks, show_changes);
        check("ticks the GPU drew into the buffer on the TV", bad_buffer, 0);
        check("buffers that aren't one of the 3", bad_start, 0);
        check("frames begun > 80", frames_begun > 80, 1);
        check("frames shown > 80", show_changes > 80, 1);
        check("TV ticks the GPU saw", gpu_tv_ticks, tv_ticks);
        check("frames passed on before all their requests reached memory", early_ends, 0);
        check("finished frames the keeper heard > 80", ends_seen > 80, 1);
        $display("        (ticks a finished frame waited for its requests: %0d in all)", end_waits_total);
        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

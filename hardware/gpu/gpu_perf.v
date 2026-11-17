// gpu_perf.v
// speed counters, count gpu clock ticks per frame
// the cpu picks one of 8 and reads the last whole frames number

module gpu_perf (
    input wire clk,
    input wire reset,
    input wire draw_start,              // 1 for one clock, back half starts a frame
    input wire draw_done,               // 1 for one clock, back half finished
    input wire front_begin,             // 1 for one clock, front half starts a frame
    input wire front_done,              // 1 for one clock, front half finished
    input wire [4:0] state_bits,        // {tile end, shelf wait, waiting for raster, no card ready, writeout busy}
    input wire [2:0] select,            // which counter the cpu reads
    output reg [31:0] value             // that counter for the last whole frame
);

reg [4:0] bits;                         // state_bits registered
reg draw_on, front_on;
reg [31:0] back_n, front_n, period_n;
reg [31:0] c2, c3, c4, c5, c6;          // running counts
reg [31:0] last0, last1, last2, last3, last4, last5, last6, last7;   // last whole frame

always @(posedge clk) begin
    if (reset) begin
        draw_on <= 1'b0;
        front_on <= 1'b0;
        back_n <= 0; front_n <= 0; period_n <= 0;
        c2 <= 0; c3 <= 0; c4 <= 0; c5 <= 0; c6 <= 0;
        last0 <= 0; last1 <= 0; last2 <= 0; last3 <= 0; last4 <= 0; last5 <= 0; last6 <= 0; last7 <= 0;
        bits <= 0;
    end else begin
        bits <= state_bits;
        // back half frame
        period_n <= period_n + 1;
        if (draw_start) begin
            draw_on <= 1'b1;
            back_n <= 0;
            c2 <= 0; c3 <= 0; c4 <= 0; c5 <= 0; c6 <= 0;
            last7 <= period_n;                  // time since the previous start
            period_n <= 1;
        end else if (draw_on) begin
            back_n <= back_n + 1;
            if (bits[4]) c2 <= c2 + 1;
            if (bits[3]) c3 <= c3 + 1;
            if (bits[2]) c4 <= c4 + 1;
            if (bits[1]) c5 <= c5 + 1;
            if (bits[0]) c6 <= c6 + 1;
            if (draw_done) begin
                draw_on <= 1'b0;
                last0 <= back_n + 1;
                last2 <= c2; last3 <= c3; last4 <= c4; last5 <= c5; last6 <= c6;
            end
        end
        // front half frame
        if (front_begin) begin
            front_on <= 1'b1;
            front_n <= 0;
        end else if (front_on) begin
            front_n <= front_n + 1;
            if (front_done) begin
                front_on <= 1'b0;
                last1 <= front_n + 1;
            end
        end
        // the one the cpu picked
        case (select)
            3'd0: value <= last0;
            3'd1: value <= last1;
            3'd2: value <= last2;
            3'd3: value <= last3;
            3'd4: value <= last4;
            3'd5: value <= last5;
            3'd6: value <= last6;
            default: value <= last7;
        endcase
    end
end

endmodule

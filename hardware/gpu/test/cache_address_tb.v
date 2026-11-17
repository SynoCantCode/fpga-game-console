// cache_address_tb.v
// test for cache_address against the python model, bit for bit
// a new block goes in every clock and each answer is compared when it comes out
`timescale 1ns / 1ps
module cache_address_tb;

localparam COUNT = 6000;
localparam LATENCY = 2;

reg clk = 0;
always #5 clk = ~clk;

reg [60:0] cases [0:COUNT-1];
reg [52:0] answers [0:COUNT-1];
reg [60:0] now;
wire [9:0] place;
wire [17:0] tag;
wire [24:0] burst;

cache_address dut (
    .clk(clk), .slot(now[7:0]), .level(now[11:8]), .log2w(now[15:12]), .log2h(now[19:16]), .start(now[44:20]),
    .bx(now[52:45]), .by(now[60:53]), .place(place), .tag(tag), .burst(burst)
);

integer sent = 0, checked = 0, wrong = 0;
wire [52:0] got = {burst, tag, place};

always @(posedge clk) begin
    now <= (sent < COUNT) ? cases[sent] : 61'd0;
    sent <= sent + 1;
    // answer of the block sent LATENCY + 1 clocks ago, now is one register in front of the unit
    if (sent > LATENCY && checked < COUNT) begin
        if (got !== answers[checked]) begin
            wrong = wrong + 1;
            if (wrong <= 5)
                $display("FAIL: case %0d (%h): got place %h tag %h burst %h, the model says %h %h %h", checked, cases[checked],
                         place, tag, burst, answers[checked][9:0], answers[checked][27:10], answers[checked][52:28]);
        end
        checked <= checked + 1;
    end
    if (checked == COUNT) begin
        if (wrong == 0) $display("PASSED: every check is right (%0d blocks, bit for bit)", checked);
        else $display("FAILED: %0d of %0d blocks differ from the model", wrong, checked);
        $finish;
    end
end

initial begin
    $readmemh("build/cache_address/in.hex", cases);
    $readmemh("build/cache_address/out.hex", answers);
end

endmodule

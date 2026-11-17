// texel_axis_tb.v
// test for texel_axis against the python model, bit for bit
// a new case goes in every clock and each answer is compared when it comes out
`timescale 1ns / 1ps
module texel_axis_tb;

localparam COUNT = 6000;
localparam LATENCY = 2;

reg clk = 0;
always #5 clk = ~clk;

reg [32:0] cases [0:COUNT-1];
reg [24:0] answers [0:COUNT-1];
reg [32:0] now;
wire [9:0] first, second;
wire [4:0] weight;

texel_axis dut (
    .clk(clk), .place(now[21:0]), .level(now[25:22]), .log2_size(now[29:26]), .rule(now[31:30]), .bilinear(now[32]),
    .first(first), .second(second), .weight(weight)
);

integer sent = 0, checked = 0, wrong = 0;
wire [24:0] got = {weight, second, first};

always @(posedge clk) begin
    now <= (sent < COUNT) ? cases[sent] : 33'd0;
    sent <= sent + 1;
    // answer of the case sent LATENCY + 1 clocks ago, now is one register in front of the unit
    if (sent > LATENCY && checked < COUNT) begin
        if (got !== answers[checked]) begin
            wrong = wrong + 1;
            if (wrong <= 5)
                $display("FAIL: case %0d (%h): got first %0d second %0d weight %0d, the model says %0d %0d %0d", checked,
                         cases[checked], first, second, weight, answers[checked][9:0], answers[checked][19:10], answers[checked][24:20]);
        end
        checked <= checked + 1;
    end
    if (checked == COUNT) begin
        if (wrong == 0) $display("PASSED: every check is right (%0d cases, bit for bit)", checked);
        else $display("FAILED: %0d of %0d cases differ from the model", wrong, checked);
        $finish;
    end
end

initial begin
    $readmemh("build/texel_axis/in.hex", cases);
    $readmemh("build/texel_axis/out.hex", answers);
end

endmodule

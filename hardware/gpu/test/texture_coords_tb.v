// texture_coords_tb.v
// test for texture_coords against the python model, bit for bit
// a new quad goes in every clock and each answer is compared when it comes out
`timescale 1ns / 1ps
module texture_coords_tb;

localparam COUNT = 4000;
localparam LATENCY = 11;

reg clk = 0;
always #5 clk = ~clk;

reg [266:0] quads [0:COUNT-1];
reg [188:0] answers [0:COUNT-1];
reg [266:0] now;
wire [87:0] u, v;
wire [3:0] level;
wire textured_out;
wire [7:0] slot_out;

texture_coords dut (
    .clk(clk),
    .us(now[26:0]), .vs(now[53:27]), .pick(now[266:264]), .au(now[80:54]), .bu(now[107:81]), .av(now[134:108]), .bv(now[161:135]),
    .za(now[193:162]), .zb(now[225:194]), .r(now[242:226]), .p(now[248:243]), .s(now[253:249]),
    .steep(now[254]), .textured(now[255]), .slot(now[263:256]),
    .u(u), .v(v), .level(level), .textured_out(textured_out), .slot_out(slot_out)
);

integer sent = 0, checked = 0, wrong = 0;
wire [188:0] got = {slot_out, textured_out, level, v, u};

always @(posedge clk) begin
    // next quad in
    now <= (sent < COUNT) ? quads[sent] : 267'd0;
    sent <= sent + 1;
    // answer of the quad sent LATENCY + 1 clocks ago, now is one register in front of the unit
    if (sent > LATENCY && checked < COUNT) begin
        if (got !== answers[checked]) begin
            wrong = wrong + 1;
            if (wrong <= 5)
                $display("FAIL: quad %0d: got level %0d u %h v %h, the model says level %0d u %h v %h", checked,
                         level, u, v, answers[checked][179:176], answers[checked][87:0], answers[checked][175:88]);
        end
        checked <= checked + 1;
    end
    if (checked == COUNT) begin
        if (wrong == 0) $display("PASSED: every check is right (%0d quads, bit for bit)", checked);
        else $display("FAILED: %0d of %0d quads differ from the model", wrong, checked);
        $finish;
    end
end

initial begin
    $readmemh("build/texture_coords/in.hex", quads);
    $readmemh("build/texture_coords/out.hex", answers);
end

endmodule

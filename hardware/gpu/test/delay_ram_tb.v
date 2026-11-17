// delay_ram_tb.v
// test for delay_ram against a plain chain of registers fed the same random numbers
// three lines of different lengths at once, the outputs must match on every tick
`timescale 1ns / 1ps
module delay_ram_tb;

reg clk = 0;
always #5 clk = ~clk;

reg advance = 1;
reg [519:0] in = 0;
integer failures = 0, advances = 0;

task check(input [8*60-1:0] what, input integer got_value, input integer expected);
    if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
    else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
endtask

// one delay_ram next to a register chain, compared once the memory has filled
`define ONE_LINE(NAME, W, D) \
    wire [W-1:0] NAME``_out; \
    delay_ram #(.WIDTH(W), .DELAY(D)) NAME (.clk(clk), .advance(advance), .in(in[W-1:0]), .out(NAME``_out)); \
    reg [W-1:0] NAME``_chain [0:D-1]; \
    integer NAME``_k, NAME``_wrong = 0; \
    always @(posedge clk) if (advance) begin \
        NAME``_chain[0] <= in[W-1:0]; \
        for (NAME``_k = 1; NAME``_k < D; NAME``_k = NAME``_k + 1) NAME``_chain[NAME``_k] <= NAME``_chain[NAME``_k - 1]; \
    end \
    always @(negedge clk) if (advances > D + 1 && NAME``_out !== NAME``_chain[D-1]) NAME``_wrong = NAME``_wrong + 1;

`ONE_LINE(two, 9, 2)
`ONE_LINE(eighteen, 487, 18)
`ONE_LINE(thirtytwo, 40, 32)

integer n;
always @(posedge clk) if (advance) advances <= advances + 1;

initial begin
    $display("delay_ram test: 3 lines beside plain register chains");
    for (n = 0; n < 8000; n = n + 1) begin
        @(negedge clk);
        in = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
              $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
        if (n < 2000) advance = 1;                       // never waits
        else if (n < 6000) advance = $urandom % 2;       // waits at random
        else if (n < 6100) advance = 0;                  // held still
        else advance = ($urandom % 8) != 0;
    end
    @(negedge clk);
    check("ticks with the line moving > 4,000", advances > 4000, 1);
    check("delay 2, 9 bits: outputs different from the register chain", two_wrong, 0);
    check("delay 18, 487 bits (setup's ride): different", eighteen_wrong, 0);
    check("delay 32, 40 bits (the longest): different", thirtytwo_wrong, 0);
    if (failures == 0) $display("PASSED: every check is right");
    else $display("FAILED: %0d check(s) wrong", failures);
    $finish;
end

endmodule

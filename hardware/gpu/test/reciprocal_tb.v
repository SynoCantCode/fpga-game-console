// reciprocal_tb.v
// test for reciprocal, sends lots of areas one per clock and checks area x (1 / area) comes out as 1
// also holding advance at 0 must freeze everything
`timescale 1ns / 1ps

module reciprocal_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg advance = 1;
    reg [35:0] area = 1;
    wire [35:0] r;
    wire [5:0] p;

    reciprocal recip (.clk(clk), .advance(advance), .area(area), .r(r), .p(p));

    integer failures = 0;
    task check(input [8*60-1:0] what, input integer got_value, input integer expected);
        if (got_value == expected) $display("  ok    %0s: %0d", what, got_value);
        else begin $display("  FAIL  %0s: got %0d, expected %0d", what, got_value, expected); failures = failures + 1; end
    endtask

    // the areas sent in order so each answer can be matched with its question
    reg [35:0] sent [0:9999];
    integer n_sent = 0, n_checked = 0, bad = 0, worst_shift = 0;
    reg [127:0] product, one, error;

    // check one answer, area x r should be 2^(35 + p)
    task check_answer(input [35:0] a);
        begin
            product = a * r;
            one = 128'd1 << (35 + p);
            error = (product > one) ? product - one : one - product;
            if ((error << 30) > one) begin                    // off by more than 1 part in 2^30
                if (bad < 5) $display("        area %0d: r = %0d, p = %0d (off by %0d / 2^%0d)", a, r, p, error, 35 + p);
                bad = bad + 1;
            end
            n_checked = n_checked + 1;
        end
    endtask

    integer i, k;

    initial begin
        $display("reciprocal test: 1 / area by Newton's method, an answer every clock");
        // every power of 2 and its neighbours then random ones of every size
        for (k = 0; k < 36; k = k + 1) begin
            sent[n_sent] = 36'd1 << k;  n_sent = n_sent + 1;
            sent[n_sent] = (36'd1 << k) + 1;  n_sent = n_sent + 1;
            if (k > 0) begin sent[n_sent] = (36'd1 << k) - 1;  n_sent = n_sent + 1; end
        end
        while (n_sent < 10000) begin
            k = $urandom % 36;
            sent[n_sent] = ({$urandom, $urandom} >> (64 - k - 1)) | 36'd1;
            n_sent = n_sent + 1;
        end

        // push one per clock, answers come out 11 clocks later
        for (i = 0; i < n_sent + 11; i = i + 1) begin
            @(negedge clk);
            if (i < n_sent) area = sent[i];
            if (i >= 11) check_answer(sent[i - 11]);
            if (i == 5000) begin                   // freeze for a while in the middle
                advance = 0;
                repeat (20) @(negedge clk);
                advance = 1;
                area = sent[i];
            end
        end

        $display("10,000 areas, from 1 to 2^36, one per clock (with a 20-clock freeze in the middle):");
        check("answers checked", n_checked, n_sent);
        check("answers off by more than a billionth", bad, 0);

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

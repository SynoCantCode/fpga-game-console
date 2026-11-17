// display_pll_tb.v
// feeds the pll 50 MHz, waits for lock, then measures the 2 clocks it makes
`timescale 1ns / 1ps

module display_pll_tb;

    GSR GSR (.GSRI(1'b1));   // gowins global reset, the sim models need it (1 = not resetting)

    // 50 MHz crystal
    reg crystal = 0;
    always #10 crystal = ~crystal;

    // the pll being tested
    wire lock, pixel_clk, serial_clk;
    display_pll pll (.clkin(crystal), .lock(lock), .clkout0(pixel_clk), .clkout1(serial_clk));

    // check helper
    // allows a tiny error because the sim pll model rounds to whole picoseconds
    integer failures = 0;

    task check_mhz(input string what, input real got_mhz, input real expected_mhz);
        if (got_mhz > expected_mhz * 0.9995 && got_mhz < expected_mhz * 1.0005) begin
            $display("  ok    %0s: %0.3f MHz", what, got_mhz);
        end else begin
            $display("  FAIL  %0s: got %0.3f MHz, expected %0.3f MHz", what, got_mhz, expected_mhz);
            failures = failures + 1;
        end
    endtask

    // measure a clock by timing 1000 rising edges
    realtime start, stop;

    task measure(input integer which, output real mhz);
        begin
            if (which == 0) begin
                @(posedge pixel_clk); start = $realtime;
                repeat (1000) @(posedge pixel_clk); stop = $realtime;
            end else begin
                @(posedge serial_clk); start = $realtime;
                repeat (1000) @(posedge serial_clk); stop = $realtime;
            end
            mhz = 1000.0 / ((stop - start) / 1000.0);   // 1000 ticks in (stop - start) ns
        end
    endtask

    // the test
    real pixel_mhz, serial_mhz;

    initial begin
        $display("display_pll test: 50 MHz in");

        fork
            begin wait (lock === 1'b1); end
            begin #200000; end   // give up after 200 microseconds
        join_any
        if (lock !== 1'b1) begin
            $display("  FAIL  the PLL never locked");
            failures = failures + 1;
        end else begin
            $display("  ok    locked after %0.1f microseconds", $realtime / 1000.0);
            measure(0, pixel_mhz);  check_mhz("clkout0 (pixel clock)", pixel_mhz, 74.1667);
            measure(1, serial_mhz); check_mhz("clkout1 (serial clock, 5x)", serial_mhz, 370.8333);
        end

        $display("");
        if (failures == 0) $display("PASSED: every check is right");
        else               $display("FAILED: %0d check(s) wrong", failures);
        $finish;
    end

endmodule

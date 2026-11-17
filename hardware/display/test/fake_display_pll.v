// fake_display_pll.v
// test only stand in for the display pll, same name and ports
// makes the serial clock and builds the pixel clock from it so they never drift apart in sim
`timescale 1ns / 1ps

module display_pll (lock, clkout0, clkout1, clkin);

    output reg lock = 0;
    output reg clkout0 = 0;   // pixel clock, flips every 5 flips of the serial clock
    output reg clkout1 = 0;   // serial clock
    input clkin;              // ignored, this fake makes its own clocks

    always #1.3468 clkout1 = ~clkout1;

    integer flips = 0;
    always @(clkout1) begin
        flips = flips + 1;
        if (flips == 5) begin
            clkout0 = ~clkout0;
            flips = 0;
        end
    end

    initial #1000 lock = 1;   // locks after 1 microsecond

endmodule

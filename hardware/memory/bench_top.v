// bench_top.v
// ddr3 benchmark top for the real board
// gowins ddr3 controller + memory_benchmark + the results over serial

module bench_top (
    input wire clk_50,                 // 50 MHz crystal
    output wire uart_tx,               // serial to the pc
    output wire led,                   // on = finished, lit when the pin is 0

    // ddr3 pins
    output wire [14:0] ddr_addr,       // row or column
    output wire [2:0] ddr_bank,        // which bank
    output wire ddr_cs,                // the 4 command wires
    output wire ddr_ras,
    output wire ddr_cas,
    output wire ddr_we,
    output wire ddr_ck,                // memory clock pair
    output wire ddr_ck_n,
    output wire ddr_cke,               // clock enable
    output wire ddr_odt,               // on die termination
    output wire ddr_reset_n,           // reset
    output wire [3:0] ddr_dm,          // data mask, one per 8 data wires
    inout wire [31:0] ddr_dq,          // 32 data wires
    inout wire [3:0] ddr_dqs,          // data strobes, one pair per 8 data wires
    inout wire [3:0] ddr_dqs_n
);

// power on, hold the pll and memory controller in reset for a bit
reg [7:0] power_on_count = 0;
wire powered_up = (power_on_count == 8'd255);

always @(posedge clk_50) begin
    if (!powered_up)
        power_on_count <= power_on_count + 1;
end

// ddr3 clock from the crystal
wire memory_clk, pll_lock, pll_stop;

Gowin_PLL ddr_pll (
    .clkin(clk_50), .init_clk(clk_50), .reset(!powered_up),
    .enclk0(1'b1), .enclk1(1'b1), .enclk2(pll_stop),
    .clkout0(), .clkout1(), .clkout2(memory_clk),
    .lock(pll_lock)
);

// gowins ddr3 memory controller
wire clk_100;                   // everything on our side runs on this
wire calibrated;
wire cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, rd_data_valid;
wire [2:0] cmd;
wire [28:0] addr;
wire [255:0] wr_data, rd_data;
wire [31:0] wr_data_mask;

DDR3_Memory_Interface_Top memory_controller (
    .clk(clk_50), .memory_clk(memory_clk), .pll_lock(pll_lock), .pll_stop(pll_stop), .rst_n(powered_up),
    .clk_out(clk_100), .ddr_rst(), .init_calib_complete(calibrated),
    .cmd_ready(cmd_ready), .cmd(cmd), .cmd_en(cmd_en), .addr(addr),
    .wr_data_rdy(wr_data_rdy), .wr_data(wr_data), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end),
    .wr_data_mask(wr_data_mask),
    .rd_data(rd_data), .rd_data_valid(rd_data_valid), .rd_data_end(),
    .sr_req(1'b0), .ref_req(1'b0), .sr_ack(), .ref_ack(), .burst(1'b0),
    .O_ddr_addr(ddr_addr), .O_ddr_ba(ddr_bank), .O_ddr_cs_n(ddr_cs), .O_ddr_ras_n(ddr_ras),
    .O_ddr_cas_n(ddr_cas), .O_ddr_we_n(ddr_we), .O_ddr_clk(ddr_ck), .O_ddr_clk_n(ddr_ck_n),
    .O_ddr_cke(ddr_cke), .O_ddr_odt(ddr_odt), .O_ddr_reset_n(ddr_reset_n), .O_ddr_dqm(ddr_dm),
    .IO_ddr_dq(ddr_dq), .IO_ddr_dqs(ddr_dqs), .IO_ddr_dqs_n(ddr_dqs_n)
);

// reset for our side, on clk_100
reg [1:0] reset_delay = 2'b11;

always @(posedge clk_100)
    reset_delay <= {reset_delay[0], !powered_up};

wire reset = reset_delay[1];

// the benchmark
wire done;
wire [32*16-1:0] results;

memory_benchmark bench (
    .clk(clk_100), .reset(reset), .calibrated(calibrated),
    .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
    .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end),
    .wr_data(wr_data), .wr_data_mask(wr_data_mask),
    .rd_data_valid(rd_data_valid), .rd_data(rd_data),
    .done(done), .results(results)
);

// results to the pc over serial
wire uart_send, uart_busy;
wire [7:0] uart_byte;

bench_report report (
    .clk(clk_100), .reset(reset), .done(done), .results(results),
    .uart_busy(uart_busy), .uart_send(uart_send), .uart_byte(uart_byte)
);

uart_tx serial (
    .clk(clk_100), .rst(reset), .send(uart_send), .byte_to_send(uart_byte), .busy(uart_busy), .tx(uart_tx)
);

// led on once all 16 tests have run
assign led = !done;

endmodule

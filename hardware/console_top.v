// console_top.v
// the top file, owns the board pins and wires the parts together
// cpu, gpu, display and ddr3 memory
// arbiter ports  1 = frame reader  2 = gpu  3 = cpu

module console_top (
    input wire clk_50,                 // 50 MHz crystal
    output wire uart_tx,               // serial to the pc
    input wire uart_rx,                // serial from the pc
    output wire led,                   // cpu gpio pin 0, lit when 0

    // flash chip, the cpu boots from it
    inout wire flash_clk,
    inout wire flash_cs_n,
    inout wire flash_mosi,
    inout wire flash_miso,
    inout wire flash_wp_n,
    inout wire flash_hold_n,

    // hdmi
    output wire [2:0] tmds_data_p,
    output wire [2:0] tmds_data_n,
    output wire tmds_clock_p,
    output wire tmds_clock_n,

    // ddr3
    output wire [14:0] ddr_addr,
    output wire [2:0] ddr_bank,
    output wire ddr_cs,
    output wire ddr_ras,
    output wire ddr_cas,
    output wire ddr_we,
    output wire ddr_ck,
    output wire ddr_ck_n,
    output wire ddr_cke,
    output wire ddr_odt,
    output wire ddr_reset_n,
    output wire [3:0] ddr_dm,
    inout wire [31:0] ddr_dq,
    inout wire [3:0] ddr_dqs,
    inout wire [3:0] ddr_dqs_n
);

// power on, hold the plls and memory controller in reset for a bit
reg [7:0] power_on_count = 0;
wire powered_up = (power_on_count == 8'd255);

always @(posedge clk_50) begin
    if (!powered_up)
        power_on_count <= power_on_count + 1;
end

// display clocks, pixel and serial
wire pixel_clk, serial_clk, display_pll_locked;

display_pll pll (
    .clkin(clk_50), .clkout0(pixel_clk), .clkout1(serial_clk), .lock(display_pll_locked)
);

reg [1:0] pixel_reset_delay = 2'b11;

always @(posedge pixel_clk or negedge display_pll_locked) begin
    if (!display_pll_locked)
        pixel_reset_delay <= 2'b11;
    else
        pixel_reset_delay <= {pixel_reset_delay[0], 1'b0};
end

wire pixel_reset = pixel_reset_delay[1];

// memory side, ddr3 pll and gowins memory controller (gives clk_100)
wire memory_clk, ddr_pll_lock, pll_stop;

Gowin_PLL ddr_pll (
    .clkin(clk_50), .init_clk(clk_50), .reset(!powered_up),
    .enclk0(1'b1), .enclk1(1'b1), .enclk2(pll_stop),
    .clkout0(), .clkout1(), .clkout2(memory_clk),
    .lock(ddr_pll_lock)
);

wire clk_100;
wire calibrated;
wire cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, mem_rd_valid;
wire [2:0] cmd;
wire [28:0] addr;
wire [255:0] wr_data, mem_rd_data;
wire [31:0] wr_data_mask;

DDR3_Memory_Interface_Top memory_controller (
    .clk(clk_50), .memory_clk(memory_clk), .pll_lock(ddr_pll_lock), .pll_stop(pll_stop), .rst_n(powered_up),
    .clk_out(clk_100), .ddr_rst(), .init_calib_complete(calibrated),
    .cmd_ready(cmd_ready), .cmd(cmd), .cmd_en(cmd_en), .addr(addr),
    .wr_data_rdy(wr_data_rdy), .wr_data(wr_data), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end),
    .wr_data_mask(wr_data_mask),
    .rd_data(mem_rd_data), .rd_data_valid(mem_rd_valid), .rd_data_end(),
    .sr_req(1'b0), .ref_req(1'b0), .sr_ack(), .ref_ack(), .burst(1'b0),
    .O_ddr_addr(ddr_addr), .O_ddr_ba(ddr_bank), .O_ddr_cs_n(ddr_cs), .O_ddr_ras_n(ddr_ras),
    .O_ddr_cas_n(ddr_cas), .O_ddr_we_n(ddr_we), .O_ddr_clk(ddr_ck), .O_ddr_clk_n(ddr_ck_n),
    .O_ddr_cke(ddr_cke), .O_ddr_odt(ddr_odt), .O_ddr_reset_n(ddr_reset_n), .O_ddr_dqm(ddr_dm),
    .IO_ddr_dq(ddr_dq), .IO_ddr_dqs(ddr_dqs), .IO_ddr_dqs_n(ddr_dqs_n)
);

// memory side stays in reset until the controller is calibrated
reg [1:0] mem_reset_delay = 2'b11;

always @(posedge clk_100)
    mem_reset_delay <= {mem_reset_delay[0], !(powered_up && calibrated)};

wire mem_reset = mem_reset_delay[1];

// the arbiter, 5 ports
wire [4:0] req, grant, rd_valid;
wire [255:0] rd_data;
wire [2:0] reader_cmd, cpu_cmd;
wire [28:0] reader_addr, cpu_addr;
wire [255:0] cpu_data;
wire [31:0] cpu_mask;
wire [2:0] gpu_cmd;
wire [28:0] gpu_addr;
wire [255:0] gpu_data;
wire [31:0] gpu_mask;

assign req[0] = 1'b0;      // refresh is done inside gowins controller
assign req[4] = 1'b0;      // dma, not built yet

memory_arbiter #(.PORTS(5)) arbiter (
    .clk(clk_100), .reset(mem_reset),
    .req(req),
    .port_cmd({3'b001, cpu_cmd, gpu_cmd, reader_cmd, 3'b001}),
    .port_addr({29'd0, cpu_addr, gpu_addr, reader_addr, 29'd0}),
    .port_wr_data({256'd0, cpu_data, gpu_data, 256'd0, 256'd0}),
    .port_wr_mask({32'd0, cpu_mask, gpu_mask, 32'd0, 32'd0}),
    .grant(grant), .rd_valid(rd_valid), .rd_data(rd_data),
    .cmd_ready(cmd_ready), .cmd_en(cmd_en), .cmd(cmd), .addr(addr),
    .wr_data_rdy(wr_data_rdy), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end),
    .wr_data(wr_data), .wr_data_mask(wr_data_mask),
    .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data)
);

// port 3 the cpu (gowins AE350) through the memory bridge
// its memory bus runs on clk_100 so no clock crossing needed
wire cpu_core_clk, cpu_bus_clk, cpu_apb_clk, cpu_rtc_clk;

cpu_pll cpu_clocks (
    .clkin(clk_50),
    .clkout0(), .clkout1(cpu_core_clk), .clkout2(cpu_bus_clk), .clkout3(cpu_apb_clk), .clkout4(cpu_rtc_clk),
    .enclk0(1'b1), .enclk1(1'b1), .enclk2(1'b1), .enclk3(1'b1), .enclk4(1'b1)
);

// cpu starts once memory is ready
wire cpu_reset_n = !mem_reset;

// cpu device window (ahb, 32 bit) to the device hub
wire hub_hsel, hub_hwrite, hub_hready, hub_hresp, hub_hrstn;
wire [31:0] hub_haddr, hub_hwdata, hub_hrdata;
wire [1:0] hub_htrans;

// cpu memory bus (ahb, 64 bit)
wire [31:0] cpu_haddr;
wire [1:0] cpu_htrans;
wire cpu_hwrite;
wire [2:0] cpu_hsize;
wire [63:0] cpu_hwdata, cpu_hrdata;
wire cpu_hready, cpu_hresp;

wire [31:0] cpu_gpio_out;

RiscV_AE350_SOC_Top cpu (
    // instruction memory, the flash chip
    .FLASH_SPI_CSN(flash_cs_n), .FLASH_SPI_MISO(flash_miso), .FLASH_SPI_MOSI(flash_mosi),
    .FLASH_SPI_CLK(flash_clk), .FLASH_SPI_HOLDN(flash_hold_n), .FLASH_SPI_WPN(flash_wp_n),
    // data memory, our bridge
    .DDR_HRDATA(cpu_hrdata), .DDR_HREADY(cpu_hready), .DDR_HRESP(cpu_hresp),
    .DDR_HADDR(cpu_haddr), .DDR_HBURST(), .DDR_HPROT(), .DDR_HSIZE(cpu_hsize), .DDR_HTRANS(cpu_htrans),
    .DDR_HWDATA(cpu_hwdata), .DDR_HWRITE(cpu_hwrite), .DDR_HCLK(), .DDR_HRSTN(),
    // jtag not connected, held idle
    .TCK_IN(1'b0), .TMS_IN(1'b1), .TRST_IN(1'b1), .TDI_IN(1'b1), .TDO_OUT(), .TDO_OE(),
    // interrupt lines, none yet
    .EXT_INT(16'd0),
    // device window at 0xE800_0000, goes to the device hub
    .EXTS_HRDATA(hub_hrdata), .EXTS_HREADYIN(hub_hready), .EXTS_HRESP(hub_hresp),
    .EXTS_HADDR(hub_haddr), .EXTS_HBURST(), .EXTS_HPROT(), .EXTS_HSEL(hub_hsel), .EXTS_HSIZE(), .EXTS_HTRANS(hub_htrans),
    .EXTS_HWDATA(hub_hwdata), .EXTS_HWRITE(hub_hwrite), .EXTS_HCLK(), .EXTS_HRSTN(hub_hrstn),
    // simple device window at 0xF800_0000, nothing there, answers 0
    .APB_PRDATA(32'd0), .APB_PREADY(1'b1), .APB_PSLVERR(1'b0),
    .APB_PADDR(), .APB_PENABLE(), .APB_PSEL(), .APB_PWDATA(), .APB_PWRITE(), .APB_PPROT(), .APB_PSTRB(),
    .APB_PCLK(), .APB_PRSTN(),
    // serial port
    .UART2_TXD(uart_tx), .UART2_RTSN(), .UART2_RXD(uart_rx),
    .UART2_CTSN(1'b0), .UART2_DCDN(1'b0), .UART2_DSRN(1'b0), .UART2_RIN(1'b0),
    .UART2_DTRN(), .UART2_OUT1N(), .UART2_OUT2N(),
    // gpio, output 0 drives the led
    .GPIO_IN(32'd0), .GPIO_OE(), .GPIO_OUT(cpu_gpio_out),
    // clocks and resets
    .CORE_CLK(cpu_core_clk), .DDR_CLK(clk_100), .AHB_CLK(cpu_bus_clk),
    // apb clock has to be the same wire as the ahb clock or the cpu can freeze
    .APB_CLK(cpu_bus_clk),
    .RTC_CLK(cpu_rtc_clk),
    .POR_RSTN(cpu_reset_n), .HW_RSTN(cpu_reset_n)
);

// bridge side of the request buffers
wire cpu_door_req, cpu_door_grant;
wire [2:0] cpu_door_cmd;
wire [28:0] cpu_door_addr;
wire [255:0] cpu_door_data;
wire [31:0] cpu_door_mask;

cpu_memory_bridge bridge (
    .clk(clk_100), .reset(mem_reset),
    .haddr(cpu_haddr), .htrans(cpu_htrans), .hwrite(cpu_hwrite), .hsize(cpu_hsize), .hwdata(cpu_hwdata),
    .hrdata(cpu_hrdata), .hready(cpu_hready), .hresp(cpu_hresp),
    .req(cpu_door_req), .cmd(cpu_door_cmd), .addr(cpu_door_addr), .wr_data(cpu_door_data), .wr_mask(cpu_door_mask),
    .grant(cpu_door_grant), .rd_valid(rd_valid[3]), .rd_data(rd_data)
);

// bridge requests go through 2 small buffers to arbiter port 3
// the bridge sits by the cpu and the arbiter by the ddr3 controller, far apart
// so the long wire runs register to register. requests stay in order
wire cpu_mid_valid, cpu_mid_room;                 // between the two buffers
wire [3 + 29 + 256 + 32 - 1:0] cpu_mid_data;
request_buffer #(.WIDTH(3 + 29 + 256 + 32)) cpu_to_arbiter (
    .clk(clk_100), .reset(mem_reset),
    .in_valid(cpu_door_req), .in_data({cpu_door_cmd, cpu_door_addr, cpu_door_data, cpu_door_mask}),
    .in_ready(cpu_door_grant),
    .out_valid(cpu_mid_valid), .out_data(cpu_mid_data), .out_ready(cpu_mid_room)
);
// second buffer, next to the arbiter
request_buffer #(.WIDTH(3 + 29 + 256 + 32)) cpu_at_arbiter (
    .clk(clk_100), .reset(mem_reset),
    .in_valid(cpu_mid_valid), .in_data(cpu_mid_data), .in_ready(cpu_mid_room),
    .out_valid(req[3]), .out_data({cpu_cmd, cpu_addr, cpu_data, cpu_mask}), .out_ready(grant[3])
);

// gpu clock, 80 MHz
// everything between the gpu and the memory side goes through gpu_clock_crossing
wire gpu_clk, gpu_pll_lock;

gpu_pll gpu_clocks (.clkin(clk_50), .clkout0(gpu_clk), .lock(gpu_pll_lock));

// gpu reset, 2 flip flops to bring it onto gpu_clk
reg [1:0] gpu_reset_delay = 2'b11;

always @(posedge gpu_clk)
    gpu_reset_delay <= {gpu_reset_delay[0], mem_reset || !gpu_pll_lock};

wire gpu_reset = gpu_reset_delay[1];

// the gpu (port 2, through the crossing) and its 3 frame buffers
// the frame buffer keeper runs on clk_100 with the frame reader
wire [24:0] show_start;           // frame buffer the tv should show
wire tv_frame;                    // pulse, the frame reader just started a tv frame
wire buffer_ok, buffer_begin, buffer_end;                  // gpu side (gpu_clk)
wire [24:0] buffer_start;
wire m_buffer_ok, m_buffer_begin, m_buffer_end;            // keeper side (clk_100)
wire [24:0] m_buffer_start;
wire gpu_tv_frame;                                         // tv_frame crossed to gpu_clk

frame_buffers #(.BUFFER0(25'd0), .BUFFER1(25'd115200), .BUFFER2(25'd230400)) buffers (
    .clk(clk_100), .reset(mem_reset),
    .show_start(show_start), .switched(tv_frame),
    .draw_ok(m_buffer_ok), .draw_start(m_buffer_start), .draw_begin(m_buffer_begin), .draw_end(m_buffer_end),
    .showing(), .ready_valid(), .ready(), .drawing_valid(), .drawing()
);

// device hub, cpu device window 0xE80n_xxxx to device n registers
wire dev_write, dev_read;
wire [3:0] dev_select;
wire [15:0] dev_offset;
wire [31:0] dev_wdata;
wire [31:0] gpu_reg_rdata;
wire [31:0] screen_rdata;
// slot 3 = gpu, slot 5 = screen check, the rest answer 0
wire [16*32-1:0] dev_rdata = {320'd0, screen_rdata, 32'd0, gpu_reg_rdata, 96'd0};

device_hub hub (
    .bus_clk(cpu_bus_clk), .bus_reset(!hub_hrstn),
    .hsel(hub_hsel), .haddr(hub_haddr), .htrans(hub_htrans), .hwrite(hub_hwrite), .hwdata(hub_hwdata),
    .hrdata(hub_hrdata), .hready(hub_hready), .hresp(hub_hresp),
    .dev_clk(gpu_clk), .dev_reset(gpu_reset),              // devices run on gpu_clk
    .dev_write(dev_write), .dev_read(dev_read), .dev_select(dev_select), .dev_offset(dev_offset),
    .dev_wdata(dev_wdata), .dev_rdata(dev_rdata)
);

// gpu memory port, on the gpu side of the crossing
wire g_req, g_grant, g_rd_valid;
wire [2:0] g_cmd;
wire [28:0] g_addr;
wire [255:0] g_data, g_rd_data;
wire [31:0] g_mask;

// gpu registers, written by the cpu through the hub (slot 3)
wire cpu_to_gpu = (dev_select == 4'd3);
wire gpu_reg_write = dev_write && cpu_to_gpu;
wire gpu_reg_read = dev_read && cpu_to_gpu;
wire [5:0] gpu_reg_offset = dev_offset[5:0];
wire [31:0] gpu_reg_wdata = dev_wdata;

gpu #(.CARDS_A(25'd6291456), .SHELVES_A(25'd4194304), .CARDS_B(25'd7340032), .SHELVES_B(25'd5242880)) the_gpu (
    .clk(gpu_clk), .reset(gpu_reset),
    .reg_write(gpu_reg_write), .reg_read(gpu_reg_read), .reg_offset(gpu_reg_offset), .reg_wdata(gpu_reg_wdata),
    .reg_rdata(gpu_reg_rdata), .stopped(),
    .buffer_ok(buffer_ok), .buffer_start(buffer_start), .buffer_begin(buffer_begin), .buffer_end(buffer_end),
    .tv_frame(gpu_tv_frame),
    .front_busy(), .draw_busy(), .dropped_near(), .dropped_too_far_out(), .dropped_back(), .dropped_flat(),
    .dropped_off_screen(), .cards_made(), .overflow(),
    .mem_req(g_req), .mem_cmd(g_cmd), .mem_addr(g_addr), .mem_wr_data(g_data), .mem_wr_mask(g_mask),
    .mem_grant(g_grant), .mem_rd_valid(g_rd_valid), .mem_rd_data(g_rd_data)
);

// between the gpu (gpu_clk) and the memory side (clk_100)
gpu_clock_crossing gpu_crossing (
    .gpu_clk(gpu_clk), .gpu_reset(gpu_reset),
    .g_req(g_req), .g_cmd(g_cmd), .g_addr(g_addr), .g_wr_data(g_data), .g_wr_mask(g_mask),
    .g_grant(g_grant), .g_rd_valid(g_rd_valid), .g_rd_data(g_rd_data),
    .g_buffer_ok(buffer_ok), .g_buffer_start(buffer_start), .g_buffer_begin(buffer_begin), .g_buffer_end(buffer_end),
    .g_tv_frame(gpu_tv_frame),
    .mem_clk(clk_100), .mem_reset(mem_reset),
    .m_req(req[2]), .m_cmd(gpu_cmd), .m_addr(gpu_addr), .m_wr_data(gpu_data), .m_wr_mask(gpu_mask),
    .m_grant(grant[2]), .m_rd_valid(rd_valid[2]), .m_rd_data(rd_data),
    .m_buffer_ok(m_buffer_ok), .m_buffer_start(m_buffer_start), .m_buffer_begin(m_buffer_begin),
    .m_buffer_end(m_buffer_end), .m_tv_frame(tv_frame)
);

// display: timing, frame reader (port 1), encoders, hdmi output
wire [10:0] x;
wire [9:0] y;
wire visible, hsync, vsync;

video_timing timing (
    .clk(pixel_clk), .reset(pixel_reset),
    .x(x), .y(y), .visible(visible), .hsync(hsync), .vsync(vsync)
);

wire [7:0] red, green, blue;
wire [31:0] underruns;

// 3 register stages between the timing and the encoders, the wires are long
// color, visible and syncs all get the same 3 so they stay lined up
reg visible_in, below_in, hsync_in, vsync_in;             // stage 1, timing signals
always @(posedge pixel_clk)
    {visible_in, below_in, hsync_in, vsync_in} <= {visible, y >= 720, hsync, vsync};

frame_reader reader (
    .mem_clk(clk_100), .mem_reset(mem_reset),
    .show_start(show_start), .switched(tv_frame),        // which buffer to show
    .req(req[1]), .cmd(reader_cmd), .addr(reader_addr), .grant(grant[1]), .rd_valid(rd_valid[1]), .rd_data(rd_data),
    .pixel_clk(pixel_clk), .pixel_reset(pixel_reset),
    .visible(visible_in), .below_picture(below_in),
    .red(red), .green(green), .blue(blue), .underruns(underruns)
);

reg [7:0] red_mid, green_mid, blue_mid;                   // stage 2, the readers color
reg visible_mid, hsync_mid, vsync_mid;
reg [7:0] red_late, green_late, blue_late;                // stage 3
reg visible_late, hsync_late, vsync_late;

always @(posedge pixel_clk) begin
    {visible_mid, hsync_mid, vsync_mid} <= {visible_in, hsync_in, vsync_in};
    {red_mid, green_mid, blue_mid} <= {red, green, blue};
    {visible_late, hsync_late, vsync_late} <= {visible_mid, hsync_mid, vsync_mid};
    {red_late, green_late, blue_late} <= {red_mid, green_mid, blue_mid};
end

// screen check, sums each row as it goes to the tv (device slot 5)
screen_check screen (
    .pixel_clk(pixel_clk), .pixel_reset(pixel_reset), .visible(visible_late), .vsync(vsync_late),
    .red(red_late), .green(green_late), .blue(blue_late),
    .dev_clk(gpu_clk), .dev_reset(gpu_reset),
    .reg_write(dev_write && dev_select == 4'd5), .reg_read(dev_read && dev_select == 4'd5),
    .reg_offset(dev_offset[4:0]), .reg_wdata(dev_wdata), .reg_rdata(screen_rdata)
);

wire [9:0] blue_code, green_code, red_code;

tmds_encoder encode_blue  (.clk(pixel_clk), .visible(visible_late), .color(blue_late),  .control({vsync_late, hsync_late}), .tmds(blue_code));
tmds_encoder encode_green (.clk(pixel_clk), .visible(visible_late), .color(green_late), .control(2'b00),                    .tmds(green_code));
tmds_encoder encode_red   (.clk(pixel_clk), .visible(visible_late), .color(red_late),   .control(2'b00),                    .tmds(red_code));

hdmi_output out (
    .pixel_clk(pixel_clk), .serial_clk(serial_clk), .reset(pixel_reset),
    .blue_code(blue_code), .green_code(green_code), .red_code(red_code),
    .data_p(tmds_data_p), .data_n(tmds_data_n),
    .clock_p(tmds_clock_p), .clock_n(tmds_clock_n)
);

// led
assign led = !cpu_gpio_out[0];

endmodule

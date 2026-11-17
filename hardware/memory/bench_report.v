// bench_report.v
// sends the ddr3 benchmark results to the pc over serial every 2 seconds
// one line per test, B + test number + space + its ticks as 8 hex digits, then END

module bench_report #(
    parameter TICKS_BETWEEN = 200_000_000    // 2 seconds at 100 MHz
) (
    input wire clk,
    input wire reset,
    input wire done,                         // 1 = results are ready
    input wire [32*16-1:0] results,          // test k is at bits k*32
    input wire uart_busy,
    output wire uart_send,
    output wire [7:0] uart_byte
);

localparam CR = 8'd13;
localparam LF = 8'd10;

// one hex digit as its character
function [7:0] hex_char(input [3:0] digit);
    hex_char = (digit < 10) ? ("0" + digit) : ("A" + digit - 10);
endfunction

// which line (0-15 = a test, 16 = END) and which character in it
reg sending;
reg [4:0] line;
reg [3:0] pos;
reg [27:0] wait_ticks;

// this lines number
reg [31:0] value;
integer k;
always @(*) begin
    value = 32'd0;
    for (k = 0; k < 16; k = k + 1)
        if (k == line) value = results[k*32 +: 32];
end

// the character at (line, pos)
reg [7:0] ch;
always @(*) begin
    if (line == 16) begin
        case (pos)
            0: ch = "E";
            1: ch = "N";
            2: ch = "D";
            3: ch = CR;
            default: ch = LF;
        endcase
    end else begin
        case (pos)
            0: ch = "B";
            1: ch = hex_char(line[3:0]);
            2: ch = " ";
            11: ch = CR;
            12: ch = LF;
            default: ch = hex_char(value[4*(10 - pos) +: 4]);   // pos 3 is the biggest digit
        endcase
    end
end

wire [3:0] last_pos = (line == 16) ? 4'd4 : 4'd12;

assign uart_send = sending && !uart_busy;
assign uart_byte = ch;

always @(posedge clk) begin
    if (reset) begin
        sending <= 0;
        line <= 0;
        pos <= 0;
        wait_ticks <= 0;
    end else if (!sending) begin
        if (done) begin
            if (wait_ticks == TICKS_BETWEEN - 1) begin
                wait_ticks <= 0;
                line <= 0;
                pos <= 0;
                sending <= 1;
            end else
                wait_ticks <= wait_ticks + 1;
        end
    end else if (uart_send) begin
        if (pos == last_pos) begin
            pos <= 0;
            if (line == 16) sending <= 0;
            else line <= line + 1;
        end else
            pos <= pos + 1;
    end
end

endmodule

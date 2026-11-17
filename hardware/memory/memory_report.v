// memory_report.v
// sends the memory test result to the pc over serial once a second
// MEMORY OK, or MEMORY FAIL + the number of bad blocks in hex

module memory_report #(
    parameter TICKS_BETWEEN = 100_000_000    // ticks between messages, 1 second at 100 MHz
) (
    input wire clk,
    input wire reset,
    input wire done,                 // 1 = the result is ready
    input wire [31:0] errors,        // how many blocks were wrong
    input wire uart_busy,            // 1 = uart is still sending
    output wire uart_send,           // 1 = send this character now
    output wire [7:0] uart_byte      // the character
);

// the text, first character at the top
localparam [8*9-1:0]  TEXT_OK   = "MEMORY OK";
localparam [8*12-1:0] TEXT_FAIL = "MEMORY FAIL ";
localparam CR = 8'd13;   // carriage return
localparam LF = 8'd10;   // line feed

// one hex digit as its character
function [7:0] hex_char(input [3:0] digit);
    hex_char = (digit < 10) ? ("0" + digit) : ("A" + digit - 10);
endfunction

// character i of the message
function [7:0] message_char(input [4:0] i, input passed, input [31:0] count);
    if (passed) begin
        if (i < 9)       message_char = TEXT_OK[8*(8 - i) +: 8];
        else if (i == 9) message_char = CR;
        else             message_char = LF;
    end else begin
        if (i < 12)       message_char = TEXT_FAIL[8*(11 - i) +: 8];
        else if (i < 20)  message_char = hex_char(count[4*(19 - i) +: 4]);   // 8 hex digits, biggest first
        else if (i == 20) message_char = CR;
        else              message_char = LF;
    end
endfunction

// the result decides which message
wire passed = (errors == 0);
wire [4:0] length = passed ? 5'd11 : 5'd22;   // message length with CR LF

// where the reporter is
reg sending;             // 1 = in the middle of a message
reg [4:0] index;         // which character goes next
reg [26:0] wait_ticks;   // time between messages

// a character goes out when were sending and the uart is free
assign uart_send = sending && !uart_busy;
assign uart_byte = message_char(index, passed, errors);

always @(posedge clk) begin
    if (reset) begin
        sending <= 0;
        index <= 0;
        wait_ticks <= 0;
    end else if (!sending) begin
        // waiting, once theres a result count to the next message
        if (done) begin
            if (wait_ticks == TICKS_BETWEEN - 1) begin
                wait_ticks <= 0;
                index <= 0;
                sending <= 1;
            end else begin
                wait_ticks <= wait_ticks + 1;
            end
        end
    end else if (uart_send) begin
        // this character went out, move to the next one
        if (index == length - 1)
            sending <= 0;
        index <= index + 1;
    end
end

endmodule

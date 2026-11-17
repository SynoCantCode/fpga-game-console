// tmds_encoder.v
// turns one lanes 8 bit color into the 10 bits hdmi sends
// one encoder per color channel

module tmds_encoder (
    input wire clk,
    input wire visible, // 1 send color, 0 send control code
    input wire [7:0] color,
    input wire [1:0] control, // lane 0: {vsync, hsync}, lanes 1 and 2: always 0
    output reg [9:0] tmds
);

// the 4 control codes, sent in the hidden parts
localparam CONTROL_00 = 10'b1101010100; // no sync
localparam CONTROL_01 = 10'b0010101011; // hsync
localparam CONTROL_10 = 10'b0101010100; // vsync
localparam CONTROL_11 = 10'b1010101011; // hsync and vsync

// pick the control code for the current sync signals
reg [9:0] control_code;

always @(*) begin
    case (control)
        2'b00: control_code = CONTROL_00;
        2'b01: control_code = CONTROL_01;
        2'b10: control_code = CONTROL_10;
        2'b11: control_code = CONTROL_11;
    endcase
end

// color recipe
wire [3:0] ones_in_color = color[0] + color[1] + color[2] + color[3]
    + color[4] + color[5] + color[6] + color[7];

wire use_xnor = (ones_in_color > 4) || (ones_in_color == 4 && color[0] == 0);

reg [8:0] step1;
integer i;

always @(*) begin
    step1[0] = color[0];
    for (i = 1; i < 8; i = i + 1) begin
        if (use_xnor)
            step1[i] = ~(step1[i-1] ^ color[i]);
        else
            step1[i] = step1[i-1] ^ color[i];

    end
    step1[8] = ~use_xnor; // 1 = method a used, 0 = method b
end

// color recipe step 2: keep 1 and 0 balanced over time

wire[3:0] ones_in_step1 = step1[0] + step1[1] + step1[2] + step1[3]
    + step1[4] + step1[5] + step1[6] + step1[7];

wire signed [5:0] word_balance = 2 * ones_in_step1 - 8; // 1s minus 0s in this word
reg signed [5:0] score; // 1s sent minus 0s sent so far (0 = perfectly balanced)

// which of the standards 3 cases applies
wire score_is_even = (score == 0) || (word_balance == 0);
wire would_get_worse = (score > 0 && word_balance > 0) || (score < 0 && word_balance < 0);

// the clocked part: once per pixel, send either the color code or the control code
always @(posedge clk) begin
    if (!visible) begin
        tmds <= control_code;
        score <= 0;
    end else if (score_is_even) begin
        if (step1[8]) begin
            tmds <= {2'b01, step1[7:0]};
            score <= score + word_balance;
        end else begin
            tmds <= {2'b10, ~step1[7:0]};
            score <= score - word_balance;
        end
    end else if (would_get_worse) begin
        tmds <= {1'b1, step1[8], ~step1[7:0]};
        score <= score + (step1[8] ? 2 : 0) - word_balance;
    end else begin
        tmds <= {1'b0, step1[8], step1[7:0]};
        score <= score - (step1[8] ? 0 : 2) + word_balance;
    end
end
endmodule

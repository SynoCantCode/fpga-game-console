// command_processor.v
// reads the command list the game wrote into ddr3, one 64 byte command at a time
// sends matrices, triangles and lights to projection and runs the frame timing
// commands: 1 matrix 2 triangle 3 end frame 4 jump 5 draw 6 sun lights 7 lamps 8 texture F stop

module command_processor #(
    parameter [24:0] CARDS_A = 25'd0,          // the two sets of cards and shelves, in bursts
    parameter [24:0] SHELVES_A = 25'd0,
    parameter [24:0] CARDS_B = 25'd0,
    parameter [24:0] SHELVES_B = 25'd0
) (
    input wire clk,
    input wire reset,

    // orders
    input wire list_waiting,                   // a command list is queued
    input wire [24:0] next_list,               // its address in bursts
    output reg list_taken,                     // 1 for one clock, took it
    input wire switch_wanted,                  // leave the current list at its next end frame
    output reg switch_done,                    // 1 for one clock, did that
    output reg stopped,                        // 1 = hit a stop command or not started yet

    // reading ddr3
    output wire mem_req,
    output wire [2:0] mem_cmd,
    output wire [28:0] mem_addr,
    input wire mem_grant,
    input wire mem_rd_valid,
    input wire [255:0] mem_rd_data,

    // to projection
    output reg matrix_valid,
    input wire matrix_ready,
    output reg [415:0] matrix,                 // the 12 matrix numbers plus the normal scale on top
    output reg tri_valid,
    input wire tri_ready,
    output reg [287:0] corners,
    output reg [95:0] colour,                  // 3 corner colours
    output reg [3:0] switches,
    output reg [89:0] normals,                 // 3 corner normals
    output reg lit,                            // lit switch
    output reg fogged,                         // fogged switch
    output reg textured,                       // this triangle is textured
    output reg [7:0] texture_slot,
    output reg [191:0] uvs,                    // the corners u and v
    output reg lights_valid,                   // a sun lights command
    input wire lights_ready,
    output reg [311:0] lights,
    output reg lamps_valid,                    // a lamps command
    input wire lamps_ready,
    output reg [255:0] lamps,

    // the front halfs frame
    output reg front_begin,
    output wire [24:0] front_cards,
    output wire [24:0] front_shelves,
    output reg front_end,
    input wire front_done,

    // the back halfs frame
    output reg draw_start,
    output reg [24:0] draw_cards,
    output reg [24:0] draw_shelves,
    output reg [24:0] frame_buffer,
    input wire draw_done,
    input wire draw_busy,

    // the frame buffers and the tv
    input wire buffer_ok,                      // a buffer is free to draw into
    input wire [24:0] buffer_start,            // which one
    output reg buffer_begin,                   // 1 for one clock, drawing into it starts
    output reg buffer_end,                     // 1 for one clock, drawing into it is done
    input wire tv_frame                        // 1 for one clock, the tv started a new frame
);

localparam CMD_READ = 3'b001;
localparam K_MATRIX = 4'h1, K_TRIANGLE = 4'h2, K_END_FRAME = 4'h3, K_JUMP = 4'h4, K_DRAW = 4'h5, K_LIGHTS = 4'h6, K_LAMPS = 4'h7,
           K_TEXTURE = 4'h8, K_STOP = 4'hF;

// the stream, reads bursts ahead into a 16 burst queue
reg streaming;
reg [24:0] stream_address;               // next burst to ask for
reg [4:0] outstanding;                   // asked for, not answered yet
reg [4:0] discard;                       // answers still coming from an old place, thrown away
reg [255:0] queue [0:15];
reg [3:0] q_in, q_out;
reg [4:0] q_count;
reg room;                                // room to ask for one more, worked out a clock ahead

assign mem_cmd = CMD_READ;
assign mem_addr = {1'b0, stream_address, 3'b000};
assign mem_req = streaming && room;

// the decoder asks the stream to go somewhere else
reg redirect;
reg [24:0] redirect_to;
reg pop2;                                // the decoder takes two bursts (one command) this clock

wire keep_answer = mem_rd_valid && (discard == 0) && !redirect;
wire [4:0] outstanding_next = outstanding + (mem_req && mem_grant) - mem_rd_valid;
wire [4:0] q_count_next = redirect ? 5'd0 : q_count + keep_answer - (pop2 ? 5'd2 : 5'd0);
// counts this clocks request as granted so the grant isnt part of the sum
wire [4:0] outstanding_guess = outstanding + mem_req - mem_rd_valid;

always @(posedge clk) begin
    if (reset) begin
        streaming <= 1'b0;
        outstanding <= 0;
        discard <= 0;
        q_in <= 0;  q_out <= 0;  q_count <= 0;
        room <= 1'b1;
    end else begin
        outstanding <= outstanding_next;
        room <= (q_count_next + outstanding_guess < 5'd15);
        if (redirect) begin
            // empty the queue, whats already asked for gets thrown away when it arrives
            stream_address <= redirect_to;
            streaming <= 1'b1;
            discard <= outstanding_next;
            q_in <= 0;  q_out <= 0;  q_count <= 0;
        end else begin
            if (mem_req && mem_grant) stream_address <= stream_address + 1'b1;
            if (mem_rd_valid && discard != 0) discard <= discard - 1'b1;
            if (keep_answer) begin
                queue[q_in] <= mem_rd_data;
                q_in <= q_in + 1'b1;
            end
            if (pop2) q_out <= q_out + 2'd2;
            q_count <= q_count + keep_answer - (pop2 ? 5'd2 : 5'd0);
        end
    end
end

// the command at the front of the queue, two bursts
wire have_command = (q_count >= 2);
wire [511:0] command = {queue[q_out + 1'b1], queue[q_out]};
wire [3:0] kind = command[511:508];

// the decoder and the frame timing
localparam IDLE        = 4'd0;
localparam READ_NEXT   = 4'd1;     // take the next command from the list or from a shape
localparam SEND_MATRIX = 4'd2;
localparam SEND_TRI    = 4'd3;
localparam END_WAIT    = 4'd4;     // end frame, wait for the front half to finish
localparam DRAW_WAIT   = 4'd5;     // then wait for the back half, a free buffer and the tvs next frame
localparam BEGIN_NEXT  = 4'd6;     // then start the back half on it and the front half on the next frame
localparam STOPPED     = 4'd7;
localparam SEND_LIGHTS = 4'd8;     // until projection takes them
localparam SEND_LAMPS  = 4'd9;     // until projection takes them
localparam READ_UV     = 4'd10;    // triangle with a uv record, take that record too
reg [3:0] state;

reg [24:0] here;                   // address of the command at the front of the queue
reg in_shape;                      // reading a shapes triangles, not the list
reg [31:0] shape_left;             // triangles of the shape still to come
reg shape_done;                    // shape_left == 0 kept as a bit
reg [24:0] back_to;                // where the list carries on after the shape
reg front_set;                     // which set the front half is filling, 0 = a 1 = b
reg tv_ticked;                     // the tv started a frame since the last draw began
reg front_finished;
reg texture_on;                    // a texture is on
reg [7:0] slot_now;                // its slot

assign front_cards = front_set ? CARDS_B : CARDS_A;

// copied every tick in READ_NEXT and held once the command is taken
// projection only looks when the valid goes up
always @(posedge clk) begin
    if (state == READ_NEXT) begin
        corners <= command[287:0];
        colour <= command[383:288];
        switches <= command[387:384];
        lit <= command[388];
        fogged <= command[389];
        normals <= command[481:392];
        matrix <= command[415:0];
        lights <= command[311:0];
        lamps <= command[255:0];
        textured <= command[390] && texture_on;     // has a uv record and a texture is on
        texture_slot <= slot_now;
    end
    // same for the uv record
    if (state == READ_UV)
        uvs <= command[191:0];
end
assign front_shelves = front_set ? SHELVES_B : SHELVES_A;

always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;
        stopped <= 1'b1;
        matrix_valid <= 1'b0;
        tri_valid <= 1'b0;
        lights_valid <= 1'b0;
        lamps_valid <= 1'b0;
        front_begin <= 1'b0;  front_end <= 1'b0;
        draw_start <= 1'b0;
        buffer_begin <= 1'b0;  buffer_end <= 1'b0;
        redirect <= 1'b0;
        pop2 <= 1'b0;
        list_taken <= 1'b0;
        switch_done <= 1'b0;
        in_shape <= 1'b0;
        front_set <= 1'b0;
        tv_ticked <= 1'b1;
        front_finished <= 1'b0;
        texture_on <= 1'b0;
    end else begin
        front_begin <= 1'b0;  front_end <= 1'b0;
        draw_start <= 1'b0;
        buffer_begin <= 1'b0;  buffer_end <= 1'b0;
        redirect <= 1'b0;
        pop2 <= 1'b0;
        list_taken <= 1'b0;
        switch_done <= 1'b0;

        if (tv_frame) tv_ticked <= 1'b1;
        if (draw_done) buffer_end <= 1'b1;               // back half finished, its buffer is ready
        if (front_done) front_finished <= 1'b1;

        case (state)
            IDLE: begin
                // first list since power on, also starts the first frame
                if (list_waiting && !list_taken) begin
                    list_taken <= 1'b1;
                    redirect <= 1'b1;  redirect_to <= next_list;
                    here <= next_list;
                    in_shape <= 1'b0;
                    stopped <= 1'b0;
                    front_set <= 1'b0;
                    front_begin <= 1'b1;                  // first frame fills set a
                    state <= READ_NEXT;
                end
            end

            READ_NEXT: begin
                if (in_shape && shape_done) begin
                    // shape is done, back to the list
                    in_shape <= 1'b0;
                    redirect <= 1'b1;  redirect_to <= back_to;
                    here <= back_to;
                end else if (have_command && !redirect && !pop2) begin
                    pop2 <= 1'b1;                         // take the command off the queue
                    if (in_shape) begin
                        // a shapes triangle record
                        shape_left <= shape_left - 1'b1;
                        shape_done <= (shape_left == 32'd1);
                        if (command[390])
                            state <= READ_UV;             // its uv record comes next
                        else begin
                            tri_valid <= 1'b1;
                            state <= SEND_TRI;
                        end
                    end else begin
                        here <= here + 2'd2;
                        case (kind)
                            K_MATRIX: begin
                                matrix_valid <= 1'b1;
                                state <= SEND_MATRIX;
                            end
                            K_TRIANGLE: begin
                                if (command[390])
                                    state <= READ_UV;     // its uv record comes next
                                else begin
                                    tri_valid <= 1'b1;
                                    state <= SEND_TRI;
                                end
                            end
                            K_TEXTURE: begin              // kept here, goes with each triangle after it
                                texture_on <= command[8];
                                slot_now <= command[7:0];
                            end
                            K_LIGHTS: begin
                                lights_valid <= 1'b1;
                                state <= SEND_LIGHTS;
                            end
                            K_LAMPS: begin
                                lamps_valid <= 1'b1;
                                state <= SEND_LAMPS;
                            end
                            K_END_FRAME: begin
                                front_end <= 1'b1;
                                state <= END_WAIT;
                            end
                            K_JUMP: begin
                                redirect <= 1'b1;  redirect_to <= command[24:0];
                                here <= command[24:0];
                            end
                            K_DRAW: begin
                                in_shape <= 1'b1;
                                shape_left <= command[63:32];
                                shape_done <= (command[63:32] == 32'd0);
                                back_to <= here + 2'd2;
                                redirect <= 1'b1;  redirect_to <= command[24:0];
                            end
                            default: begin                // stop or anything unknown
                                stopped <= 1'b1;
                                state <= STOPPED;
                            end
                        endcase
                    end
                end
            end

            READ_UV: begin
                // take the uv record once its at the front, then send the triangle
                if (have_command && !redirect && !pop2) begin
                    pop2 <= 1'b1;
                    if (!in_shape) here <= here + 2'd2;
                    tri_valid <= 1'b1;
                    state <= SEND_TRI;
                end
            end

            SEND_MATRIX: begin
                if (matrix_ready) begin                   // projection takes it
                    matrix_valid <= 1'b0;
                    state <= READ_NEXT;
                end
            end
            SEND_TRI: begin
                if (tri_ready) begin
                    tri_valid <= 1'b0;
                    state <= READ_NEXT;
                end
            end
            SEND_LIGHTS: begin
                if (lights_ready) begin
                    lights_valid <= 1'b0;
                    state <= READ_NEXT;
                end
            end
            SEND_LAMPS: begin
                if (lamps_ready) begin
                    lamps_valid <= 1'b0;
                    state <= READ_NEXT;
                end
            end

            END_WAIT: begin
                if (front_finished || front_done) begin
                    front_finished <= 1'b0;
                    state <= DRAW_WAIT;
                end
            end
            DRAW_WAIT: begin
                if (!draw_busy && !draw_start && buffer_ok && tv_ticked) begin
                    // back half draws this frame from the set just filled into the free buffer
                    draw_start <= 1'b1;
                    draw_cards <= front_cards;  draw_shelves <= front_shelves;
                    frame_buffer <= buffer_start;
                    buffer_begin <= 1'b1;
                    tv_ticked <= 1'b0;
                    state <= BEGIN_NEXT;
                end
            end
            BEGIN_NEXT: begin
                // front half moves to the other set for the next frame
                front_set <= !front_set;
                front_begin <= 1'b1;
                state <= READ_NEXT;
                // switch, the next frame comes from the next queued list
                if (switch_wanted && list_waiting) begin
                    list_taken <= 1'b1;
                    switch_done <= 1'b1;
                    redirect <= 1'b1;  redirect_to <= next_list;
                    here <= next_list;
                    in_shape <= 1'b0;
                end
            end

            STOPPED: begin
                // the next queued list carries on, its frame was already begun
                if (list_waiting && !list_taken) begin
                    list_taken <= 1'b1;
                    redirect <= 1'b1;  redirect_to <= next_list;
                    here <= next_list;
                    in_shape <= 1'b0;
                    stopped <= 1'b0;
                    state <= READ_NEXT;
                end
            end
            default: state <= IDLE;
        endcase
    end
end

endmodule

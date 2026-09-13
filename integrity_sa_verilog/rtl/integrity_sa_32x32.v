`timescale 1ns/1ps
// Verilog-2001, output-stationary INT8 GEMM with independent mod-7/mod-15 MACs.
// One tile at a time. Feed boundary cycle t with A[r][t-r], B[t-c][c].
// step_en freezes the ENTIRE compute wave, including the stream checkers.
// Drain: all 32 rows shift east together on out_valid && out_ready.
// Outputs are speculative until tile_commit. See README.md for the contract.
// Raw-data transport fingerprints run alongside GEMM. No memory/buffer or
// SRAM-tag interface is assumed; protection starts at the accepted SA input.
module integrity_sa_32x32 #(
    parameter integer K_DEPTH = 32
) (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire step_en,
    input wire [255:0] a_west_flat,
    input wire [255:0] b_north_flat,
    input wire [31:0] a_valid_west,
    input wire [31:0] b_valid_north,
    output wire busy,
    output wire input_ready,
    output wire [6:0] wave_index,
    input wire out_ready,
    output wire out_valid,
    output wire [4:0] out_col,
    output wire [1023:0] out_data_flat,
    output wire [95:0] out_r7_flat,
    output wire [127:0] out_r15_flat,
    output wire [31:0] out_bad,
    output wire transport_error,
    output reg arithmetic_error,
    output reg protocol_error,
    output wire tile_error,
    output reg done,
    output reg tile_commit,
    output reg replay_request
);
    localparam [2:0] ST_IDLE = 3'd0, ST_RUN = 3'd1,
                     ST_VERIFY = 3'd2, ST_DRAIN = 3'd3, ST_REPORT = 3'd4;
    // Last MAC is t=K+61. t=K+62 captures the last egress register at checker.
    localparam integer LAST_WAVE = K_DEPTH + 62;
    reg [2:0] state;
    reg [6:0] wave;
    reg [4:0] drain_index;
    reg sideband_error;

    wire clear_tile = (state == ST_IDLE) && start;
    wire run_step = (state == ST_RUN) && step_en;
    wire drain_step = (state == ST_DRAIN) && out_ready;
    wire check_streams = (state == ST_VERIFY);
    assign busy = (state != ST_IDLE);
    assign input_ready = run_step;
    assign wave_index = wave;
    assign out_valid = (state == ST_DRAIN);
    assign out_col = 5'd31 - drain_index;

    wire signed [7:0] a_link [0:1023];
    wire signed [7:0] b_link [0:1023];
    wire av_link [0:1023];
    wire bv_link [0:1023];
    wire [2:0] a7_link [0:1023];
    wire [2:0] b7_link [0:1023];
    wire [3:0] a15_link [0:1023];
    wire [3:0] b15_link [0:1023];
    wire signed [31:0] acc_link [0:1023];
    wire [2:0] s7_link [0:1023];
    wire [3:0] s15_link [0:1023];
    wire [1023:0] pair_bad;
    wire [31:0] input_schedule_bad;
    wire [31:0] egress_sideband_bad;
    wire [31:0] a_stream_error;
    wire [31:0] b_stream_error;
    wire [2:0] a7_ingress [0:31];
    wire [2:0] b7_ingress [0:31];
    wire [3:0] a15_ingress [0:31];
    wire [3:0] b15_ingress [0:31];

    assign transport_error = (|a_stream_error) | (|b_stream_error) | sideband_error;
    assign tile_error = transport_error | arithmetic_error | protocol_error;

    genvar lane;
    genvar row;
    genvar col;
    generate
        if ((K_DEPTH < 1) || (K_DEPTH > 32)) begin : INVALID_K
            ISA_K_DEPTH_MUST_BE_BETWEEN_1_AND_32 invalid_configuration();
        end
        for (lane = 0; lane < 32; lane = lane + 1) begin : LANES
            wire [2:0] a7_egress, b7_egress, actual_s7;
            wire [3:0] a15_egress, b15_egress, actual_s15;
            wire expected_valid = (wave >= lane) && (wave < lane + K_DEPTH);
            localparam integer A_EDGE = lane*32 + 31;
            localparam integer B_EDGE = 31*32 + lane;

            isa_residue8 a_ingress (.data(a_west_flat[lane*8 +: 8]),
                .r7(a7_ingress[lane]), .r15(a15_ingress[lane]));
            isa_residue8 b_ingress (.data(b_north_flat[lane*8 +: 8]),
                .r7(b7_ingress[lane]), .r15(b15_ingress[lane]));
            // These converters validate the arithmetic residue sidebands.
            // Transport fingerprints below use the raw INT8 bytes directly.
            isa_residue8 a_egress (.data(a_link[A_EDGE]), .r7(a7_egress), .r15(a15_egress));
            isa_residue8 b_egress (.data(b_link[B_EDGE]), .r7(b7_egress), .r15(b15_egress));

            isa_stream_checker #(.TOKENS(K_DEPTH)) a_checker (
                .clk(clk), .rst_n(rst_n), .clear(clear_tile), .advance(run_step),
                .check(check_streams), .in_valid(a_valid_west[lane]), .out_valid(av_link[A_EDGE]),
                .in_token(a_west_flat[lane*8 +: 8]),
                .out_token(a_link[A_EDGE]), .error(a_stream_error[lane]),
                .xor_mismatch(), .rotation_mismatch(), .count_mismatch());
            isa_stream_checker #(.TOKENS(K_DEPTH)) b_checker (
                .clk(clk), .rst_n(rst_n), .clear(clear_tile), .advance(run_step),
                .check(check_streams), .in_valid(b_valid_north[lane]), .out_valid(bv_link[B_EDGE]),
                .in_token(b_north_flat[lane*8 +: 8]),
                .out_token(b_link[B_EDGE]), .error(b_stream_error[lane]),
                .xor_mismatch(), .rotation_mismatch(), .count_mismatch());

            assign input_schedule_bad[lane] = (a_valid_west[lane] != expected_valid) |
                                             (b_valid_north[lane] != expected_valid);
            assign egress_sideband_bad[lane] =
                (av_link[A_EDGE] && ({a15_egress,a7_egress} != {a15_link[A_EDGE],a7_link[A_EDGE]})) |
                (bv_link[B_EDGE] && ({b15_egress,b7_egress} != {b15_link[B_EDGE],b7_link[B_EDGE]}));

            // Exactly one pair of INT32 converters and comparators per row edge.
            isa_residue32 output_residue (.data(acc_link[A_EDGE]), .r7(actual_s7), .r15(actual_s15));
            assign out_data_flat[lane*32 +: 32] = acc_link[A_EDGE];
            assign out_r7_flat[lane*3 +: 3] = actual_s7;
            assign out_r15_flat[lane*4 +: 4] = actual_s15;
            assign out_bad[lane] = (actual_s7 != s7_link[A_EDGE]) | (actual_s15 != s15_link[A_EDGE]);
        end

        for (row = 0; row < 32; row = row + 1) begin : ROWS
            for (col = 0; col < 32; col = col + 1) begin : COLS
                localparam integer IDX = row*32 + col;
                wire signed [7:0] a_in, b_in;
                wire av_in, bv_in;
                wire [2:0] a7_in, b7_in;
                wire [3:0] a15_in, b15_in;
                wire signed [31:0] drain_acc;
                wire [2:0] drain_s7;
                wire [3:0] drain_s15;
                if (col == 0) begin : WEST
                    assign a_in = a_west_flat[row*8 +: 8];
                    assign av_in = a_valid_west[row];
                    assign a7_in = a7_ingress[row];
                    assign a15_in = a15_ingress[row];
                    assign drain_acc = 32'sd0;
                    assign drain_s7 = 3'd0;
                    assign drain_s15 = 4'd0;
                end else begin : LEFT
                    assign a_in = a_link[IDX-1];
                    assign av_in = av_link[IDX-1];
                    assign a7_in = a7_link[IDX-1];
                    assign a15_in = a15_link[IDX-1];
                    assign drain_acc = acc_link[IDX-1];
                    assign drain_s7 = s7_link[IDX-1];
                    assign drain_s15 = s15_link[IDX-1];
                end
                if (row == 0) begin : NORTH
                    assign b_in = b_north_flat[col*8 +: 8];
                    assign bv_in = b_valid_north[col];
                    assign b7_in = b7_ingress[col];
                    assign b15_in = b15_ingress[col];
                end else begin : ABOVE
                    assign b_in = b_link[IDX-32];
                    assign bv_in = bv_link[IDX-32];
                    assign b7_in = b7_link[IDX-32];
                    assign b15_in = b15_link[IDX-32];
                end
                assign pair_bad[IDX] = av_in ^ bv_in;
                isa_pe pe (
                    .clk(clk), .rst_n(rst_n), .clear(clear_tile), .compute_en(run_step), .drain_en(drain_step),
                    .a_in(a_in), .b_in(b_in), .av_in(av_in), .bv_in(bv_in),
                    .a7_in(a7_in), .b7_in(b7_in), .a15_in(a15_in), .b15_in(b15_in),
                    .a_out(a_link[IDX]), .b_out(b_link[IDX]), .av_out(av_link[IDX]), .bv_out(bv_link[IDX]),
                    .a7_out(a7_link[IDX]), .b7_out(b7_link[IDX]),
                    .a15_out(a15_link[IDX]), .b15_out(b15_link[IDX]),
                    .acc_out(acc_link[IDX]), .s7_out(s7_link[IDX]), .s15_out(s15_link[IDX]),
                    .drain_acc_in(drain_acc), .drain_s7_in(drain_s7), .drain_s15_in(drain_s15));
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            wave <= 7'd0;
            drain_index <= 5'd0;
            done <= 1'b0;
            tile_commit <= 1'b0;
            replay_request <= 1'b0;
            arithmetic_error <= 1'b0;
            protocol_error <= 1'b0;
            sideband_error <= 1'b0;
        end else begin
            done <= 1'b0;
            tile_commit <= 1'b0;
            replay_request <= 1'b0;
            if (clear_tile) begin
                state <= ST_RUN;
                wave <= 7'd0;
                drain_index <= 5'd0;
                arithmetic_error <= 1'b0;
                protocol_error <= 1'b0;
                sideband_error <= 1'b0;
            end else begin
                if (run_step) begin
                    if ((|input_schedule_bad) || (|pair_bad)) protocol_error <= 1'b1;
                    if (|egress_sideband_bad) sideband_error <= 1'b1;
                end
                case (state)
                    ST_RUN: if (step_en) begin
                        if (wave == LAST_WAVE) state <= ST_VERIFY;
                        else wave <= wave + 1'b1;
                    end
                    ST_VERIFY: begin
                        state <= ST_DRAIN;
                        drain_index <= 5'd0;
                    end
                    ST_DRAIN: if (out_ready) begin
                        if (|out_bad) arithmetic_error <= 1'b1;
                        if (drain_index == 5'd31) state <= ST_REPORT;
                        else drain_index <= drain_index + 1'b1;
                    end
                    ST_REPORT: begin
                        done <= 1'b1;
                        tile_commit <= !tile_error;
                        replay_request <= tile_error;
                        state <= ST_IDLE;
                    end
                    default: state <= ST_IDLE;
                endcase
            end
        end
    end
endmodule

`timescale 1ns/1ps

module isa_pe (
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire compute_en,
    input wire drain_en,
    input wire signed [7:0] a_in,
    input wire signed [7:0] b_in,
    input wire av_in,
    input wire bv_in,
    input wire [2:0] a7_in,
    input wire [2:0] b7_in,
    input wire [3:0] a15_in,
    input wire [3:0] b15_in,
    output reg signed [7:0] a_out,
    output reg signed [7:0] b_out,
    output reg av_out,
    output reg bv_out,
    output reg [2:0] a7_out,
    output reg [2:0] b7_out,
    output reg [3:0] a15_out,
    output reg [3:0] b15_out,
    output reg signed [31:0] acc_out,
    output reg [2:0] s7_out,
    output reg [3:0] s15_out,
    input wire signed [31:0] drain_acc_in,
    input wire [2:0] drain_s7_in,
    input wire [3:0] drain_s15_in
);
    wire signed [15:0] product;
    wire signed [31:0] product_extended;
    wire [5:0] product7;
    wire [7:0] product15;
    wire [5:0] total7;
    wire [7:0] total15;
    wire [2:0] next7;
    wire [3:0] next15;

    assign product = a_in * b_in;
    assign product_extended = {{16{product[15]}}, product};
    // Each shadow product has its own low-width operands and result.
    assign product7 = a7_in * b7_in;
    assign product15 = a15_in * b15_in;
    assign total7 = product7 + {3'b000, s7_out};
    assign total15 = product15 + {4'b0000, s15_out};
    isa_mod7_reduce6 fold7 (.data(total7), .residue(next7));
    isa_mod15_reduce8 fold15 (.data(total15), .residue(next15));

    // Synchronous reset. Draining has priority over computing; forwarding
    // registers hold during drain and during global compute stalls.
    always @(posedge clk) begin
        if (!rst_n || clear) begin
            a_out <= 8'd0;
            b_out <= 8'd0;
            av_out <= 1'b0;
            bv_out <= 1'b0;
            a7_out <= 3'd0;
            b7_out <= 3'd0;
            a15_out <= 4'd0;
            b15_out <= 4'd0;
            acc_out <= 32'sd0;
            s7_out <= 3'd0;
            s15_out <= 4'd0;
        end else if (drain_en) begin
            acc_out <= drain_acc_in;
            s7_out <= drain_s7_in;
            s15_out <= drain_s15_in;
        end else if (compute_en) begin
            a_out <= a_in;
            b_out <= b_in;
            av_out <= av_in;
            bv_out <= bv_in;
            a7_out <= a7_in;
            b7_out <= b7_in;
            a15_out <= a15_in;
            b15_out <= b15_in;
            if (av_in && bv_in) begin
                acc_out <= acc_out + product_extended;
                s7_out <= next7;
                s15_out <= next15;
            end
        end
    end
endmodule

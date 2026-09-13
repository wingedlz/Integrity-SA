`timescale 1ns/1ps

// One transaction contains TOKENS accepted values on each stream. Assert check
// after the final accepted values; clear starts the next independent frame.
// Tokens are RAW 8-bit operand bit patterns, not compressed residues or tags.
module isa_stream_checker #(
    parameter integer TOKENS = 32
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clear,
    input  wire       advance,
    input  wire       check,
    input  wire       in_valid,
    input  wire       out_valid,
    input  wire [7:0] in_token,
    input  wire [7:0] out_token,
    output reg        error,
    output wire       xor_mismatch,
    output wire       rotation_mismatch,
    output wire       count_mismatch
);
    // Supported frame lengths are 1..32; six bits prevent a 32-token wrap.
    localparam [5:0] EXPECTED_TOKENS = TOKENS;

    reg [7:0]  in_xor;
    reg [7:0]  out_xor;
    reg [31:0] in_rotation;
    reg [31:0] out_rotation;
    reg [5:0]  in_count;
    reg [5:0]  out_count;

    assign xor_mismatch = (in_xor != out_xor);
    assign rotation_mismatch = (in_rotation != out_rotation);
    assign count_mismatch = (in_count != EXPECTED_TOKENS) ||
                            (out_count != EXPECTED_TOKENS);

    always @(posedge clk) begin
        if (!rst_n) begin
            in_xor       <= 8'd0;
            out_xor      <= 8'd0;
            in_rotation  <= 32'd0;
            out_rotation <= 32'd0;
            in_count     <= 6'd0;
            out_count    <= 6'd0;
            error        <= 1'b0;
        end else if (clear) begin
            in_xor       <= 8'd0;
            out_xor      <= 8'd0;
            in_rotation  <= 32'd0;
            out_rotation <= 32'd0;
            in_count     <= 6'd0;
            out_count    <= 6'd0;
            error        <= 1'b0;
        end else begin
            if (advance && in_valid) begin
                in_xor <= in_xor ^ in_token;
                // Constant rotation is a wire permutation, not a barrel shift.
                in_rotation <= {in_rotation[22:0], in_rotation[31:23]} ^
                               {24'd0, in_token};
                if (in_count < 6'd32)
                    in_count <= in_count + 6'd1;
                if (in_count >= EXPECTED_TOKENS)
                    error <= 1'b1;
            end
            if (advance && out_valid) begin
                out_xor <= out_xor ^ out_token;
                out_rotation <= {out_rotation[22:0], out_rotation[31:23]} ^
                                {24'd0, out_token};
                if (out_count < 6'd32)
                    out_count <= out_count + 6'd1;
                if (out_count >= EXPECTED_TOKENS)
                    error <= 1'b1;
            end
            if (check && (xor_mismatch || rotation_mismatch || count_mismatch))
                error <= 1'b1;
        end
    end
endmodule

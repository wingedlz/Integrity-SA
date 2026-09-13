`timescale 1ns/1ps

// Canonical residues. Constant folding implements the reduction;
// these modules contain neither division nor remainder operators.
module isa_mod7_reduce6 (
    input  wire [5:0] data,
    output wire [2:0] residue
);
    wire [3:0] sum;
    wire [2:0] folded;
    assign sum = {1'b0, data[2:0]} + {1'b0, data[5:3]};
    assign folded = sum[2:0] + {2'b00, sum[3]};
    assign residue = (folded == 3'd7) ? 3'd0 : folded;
endmodule

module isa_mod15_reduce8 (
    input  wire [7:0] data,
    output wire [3:0] residue
);
    wire [4:0] sum;
    wire [3:0] folded;
    assign sum = {1'b0, data[3:0]} + {1'b0, data[7:4]};
    assign folded = sum[3:0] + {3'b000, sum[4]};
    assign residue = (folded == 4'd15) ? 4'd0 : folded;
endmodule

module isa_residue8 (
    input  wire [7:0] data,
    output wire [2:0] r7,
    output wire [3:0] r15
);
    wire [3:0] sum7_pair;
    wire [4:0] sum7;
    wire [2:0] unsigned7;
    wire [3:0] unsigned15;

    assign sum7_pair = {1'b0, data[2:0]} + {1'b0, data[5:3]};
    assign sum7 = {1'b0, sum7_pair} + {3'b000, data[7:6]};
    isa_mod7_reduce6 fold7 (.data({1'b0, sum7}), .residue(unsigned7));
    isa_mod15_reduce8 fold15 (.data(data), .residue(unsigned15));

    // Signed x = unsigned(data) - sign * 256. The residues of 256 are 4
    // and 1 respectively. Explicit correction preserves canonical zero.
    assign r7 = !data[7] ? unsigned7 :
                (unsigned7 >= 3'd4 ? unsigned7 - 3'd4 : unsigned7 + 3'd3);
    assign r15 = !data[7] ? unsigned15 :
                 (unsigned15 == 4'd0 ? 4'd14 : unsigned15 - 4'd1);
endmodule

module isa_residue32 (
    input  wire [31:0] data,
    output wire [2:0] r7,
    output wire [3:0] r15
);
    wire [3:0] s7_0, s7_1, s7_2, s7_3, s7_4;
    wire [4:0] s7_01, s7_23, s7_4top;
    wire [5:0] s7_0123;
    wire [6:0] s7_all;
    wire [3:0] s7_fold_pair;
    wire [4:0] s7_fold;
    wire [2:0] unsigned7;

    wire [4:0] s15_0, s15_1, s15_2, s15_3;
    wire [5:0] s15_01, s15_23;
    wire [6:0] s15_all;
    wire [3:0] unsigned15;

    // A balanced sum of three-bit digits exploits 2^3 == 1 modulo 7.
    assign s7_0 = {1'b0, data[2:0]}   + {1'b0, data[5:3]};
    assign s7_1 = {1'b0, data[8:6]}   + {1'b0, data[11:9]};
    assign s7_2 = {1'b0, data[14:12]} + {1'b0, data[17:15]};
    assign s7_3 = {1'b0, data[20:18]} + {1'b0, data[23:21]};
    assign s7_4 = {1'b0, data[26:24]} + {1'b0, data[29:27]};
    assign s7_01 = {1'b0, s7_0} + {1'b0, s7_1};
    assign s7_23 = {1'b0, s7_2} + {1'b0, s7_3};
    assign s7_4top = {1'b0, s7_4} + {3'b000, data[31:30]};
    assign s7_0123 = {1'b0, s7_01} + {1'b0, s7_23};
    assign s7_all = {1'b0, s7_0123} + {2'b00, s7_4top};
    assign s7_fold_pair = {1'b0, s7_all[2:0]} + {1'b0, s7_all[5:3]};
    assign s7_fold = {1'b0, s7_fold_pair} + {4'b0000, s7_all[6]};
    isa_mod7_reduce6 fold7 (.data({1'b0, s7_fold}), .residue(unsigned7));

    // Eight four-bit digits, reduced with end-around carry.
    assign s15_0 = {1'b0, data[3:0]}   + {1'b0, data[7:4]};
    assign s15_1 = {1'b0, data[11:8]}  + {1'b0, data[15:12]};
    assign s15_2 = {1'b0, data[19:16]} + {1'b0, data[23:20]};
    assign s15_3 = {1'b0, data[27:24]} + {1'b0, data[31:28]};
    assign s15_01 = {1'b0, s15_0} + {1'b0, s15_1};
    assign s15_23 = {1'b0, s15_2} + {1'b0, s15_3};
    assign s15_all = {1'b0, s15_01} + {1'b0, s15_23};
    isa_mod15_reduce8 fold15 (.data({1'b0, s15_all}), .residue(unsigned15));

    // 2^32 has the same residues (4,1) as 2^8 under (7,15).
    assign r7 = !data[31] ? unsigned7 :
                (unsigned7 >= 3'd4 ? unsigned7 - 3'd4 : unsigned7 + 3'd3);
    assign r15 = !data[31] ? unsigned15 :
                 (unsigned15 == 4'd0 ? 4'd14 : unsigned15 - 4'd1);
endmodule

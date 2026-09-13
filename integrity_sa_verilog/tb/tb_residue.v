`timescale 1ns/1ps

module tb_residue;
    reg clk;
    reg rst_n, clear, compute_en, drain_en;
    reg [7:0] data8;
    reg [31:0] data32;
    wire [2:0] r8_7, r32_7;
    wire [3:0] r8_15, r32_15;
    reg [5:0] fold6_data;
    reg [7:0] fold8_data;
    wire [2:0] fold7_result;
    wire [3:0] fold15_result;
    reg signed [7:0] a_in, b_in;
    reg av_in, bv_in;
    reg [2:0] a7_in, b7_in;
    reg [3:0] a15_in, b15_in;
    wire signed [7:0] a_out, b_out;
    wire av_out, bv_out;
    wire [2:0] a7_out, b7_out;
    wire [3:0] a15_out, b15_out;
    wire signed [31:0] acc_out;
    wire [2:0] s7_out;
    wire [3:0] s15_out;
    reg signed [31:0] drain_acc_in;
    reg [2:0] drain_s7_in;
    reg [3:0] drain_s15_in;

    integer errors, checks;
    integer i, j, k, tile;
    integer expected7, expected15, expected_acc;
    integer signed8_value;
    integer random_seed;
    reg [31:0] random_word;

    isa_residue8 conv8 (.data(data8), .r7(r8_7), .r15(r8_15));
    isa_residue32 conv32 (.data(data32), .r7(r32_7), .r15(r32_15));
    isa_mod7_reduce6 fold7 (.data(fold6_data), .residue(fold7_result));
    isa_mod15_reduce8 fold15 (.data(fold8_data), .residue(fold15_result));
    isa_pe pe (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .compute_en(compute_en), .drain_en(drain_en),
        .a_in(a_in), .b_in(b_in), .av_in(av_in), .bv_in(bv_in),
        .a7_in(a7_in), .b7_in(b7_in), .a15_in(a15_in), .b15_in(b15_in),
        .a_out(a_out), .b_out(b_out), .av_out(av_out), .bv_out(bv_out),
        .a7_out(a7_out), .b7_out(b7_out), .a15_out(a15_out), .b15_out(b15_out),
        .acc_out(acc_out), .s7_out(s7_out), .s15_out(s15_out),
        .drain_acc_in(drain_acc_in), .drain_s7_in(drain_s7_in),
        .drain_s15_in(drain_s15_in)
    );

    function integer ref7;
        input [31:0] value;
        reg signed [31:0] signed_value;
        integer remainder;
        begin
            signed_value = value;
            remainder = signed_value % 7;
            ref7 = (remainder < 0) ? remainder + 7 : remainder;
        end
    endfunction

    function integer ref15;
        input [31:0] value;
        reg signed [31:0] signed_value;
        integer remainder;
        begin
            signed_value = value;
            remainder = signed_value % 15;
            ref15 = (remainder < 0) ? remainder + 15 : remainder;
        end
    endfunction

    task check;
        input condition;
        input [511:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("FAIL: %0s at t=%0t", message, $time);
            end
        end
    endtask

    task step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task check32;
        input [31:0] value;
        begin
            data32 = value;
            #1;
            check(r32_7 == ref7(value), "signed32 modulo 7");
            check(r32_15 == ref15(value), "signed32 modulo 15");
        end
    endtask

    task drive_pair;
        input integer aa;
        input integer bb;
        begin
            a_in = aa;
            b_in = bb;
            a7_in = ref7(aa);
            b7_in = ref7(bb);
            a15_in = ref15(aa);
            b15_in = ref15(bb);
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        errors = 0;
        checks = 0;
        random_seed = 32'h52455349;
        rst_n = 1'b0;
        clear = 1'b0;
        compute_en = 1'b0;
        drain_en = 1'b0;
        data8 = 8'd0;
        data32 = 32'd0;
        fold6_data = 6'd0;
        fold8_data = 8'd0;
        a_in = 8'd0;
        b_in = 8'd0;
        av_in = 1'b0;
        bv_in = 1'b0;
        a7_in = 3'd0;
        b7_in = 3'd0;
        a15_in = 4'd0;
        b15_in = 4'd0;
        drain_acc_in = 32'd0;
        drain_s7_in = 3'd0;
        drain_s15_in = 4'd0;

        // Exhaust every input code, including negative values and canonical zero.
        for (i = 0; i < 256; i = i + 1) begin
            data8 = i;
            signed8_value = (i < 128) ? i : i - 256;
            #1;
            check(r8_7 == ref7(signed8_value), "exhaustive signed8 modulo 7");
            check(r8_15 == ref15(signed8_value), "exhaustive signed8 modulo 15");
        end
        for (i = 0; i < 64; i = i + 1) begin
            fold6_data = i;
            #1;
            check(fold7_result == (i % 7), "exhaustive unsigned6 fold modulo 7");
        end
        for (i = 0; i < 256; i = i + 1) begin
            fold8_data = i;
            #1;
            check(fold15_result == (i % 15), "exhaustive unsigned8 fold modulo 15");
        end

        check32(32'h00000000);
        check32(32'hffffffff);
        check32(32'h80000000);
        check32(32'h7fffffff);
        check32(32'haaaaaaaa);
        check32(32'h55555555);
        check32(32'h00080000);
        check32(32'hfff80000);
        for (i = 0; i < 32; i = i + 1) begin
            check32(32'h00000001 << i);
            check32(~(32'h00000001 << i));
            check32((32'h00000001 << i) - 1);
        end
        for (i = 0; i < 10000; i = i + 1) begin
            random_word = $random(random_seed);
            check32(random_word);
        end

        step;
        check(acc_out == 0 && s7_out == 0 && s15_out == 0, "synchronous reset clears accumulators");
        rst_n = 1'b1;

        // Exhaust every canonical residue MAC tuple. Drain seeds the shadow
        // state; raw inputs are zero because this unit test isolates shadow ops.
        av_in = 1'b1;
        bv_in = 1'b1;
        for (i = 0; i < 7; i = i + 1)
            for (j = 0; j < 7; j = j + 1)
                for (k = 0; k < 7; k = k + 1) begin
                    drain_en = 1'b1;
                    compute_en = 1'b0;
                    drain_acc_in = 0;
                    drain_s7_in = k;
                    drain_s15_in = 0;
                    step;
                    drain_en = 1'b0;
                    compute_en = 1'b1;
                    a7_in = i;
                    b7_in = j;
                    a15_in = 0;
                    b15_in = 0;
                    step;
                    check(s7_out == ((i*j+k) % 7), "exhaustive 3x3 residue MAC");
                end
        for (i = 0; i < 15; i = i + 1)
            for (j = 0; j < 15; j = j + 1)
                for (k = 0; k < 15; k = k + 1) begin
                    drain_en = 1'b1;
                    compute_en = 1'b0;
                    drain_acc_in = 0;
                    drain_s7_in = 0;
                    drain_s15_in = k;
                    step;
                    drain_en = 1'b0;
                    compute_en = 1'b1;
                    a7_in = 0;
                    b7_in = 0;
                    a15_in = i;
                    b15_in = j;
                    step;
                    check(s15_out == ((i*j+k) % 15), "exhaustive 4x4 residue MAC");
                end

        // Negative extrema, signed product width, and accumulator sign extension.
        clear = 1'b1;
        step;
        clear = 1'b0;
        drive_pair(-128, -128);
        step;
        check(acc_out == 32'sd16384, "signed -128 times -128");
        check(s7_out == ref7(16384) && s15_out == ref15(16384), "positive extreme product residues");
        drive_pair(-128, 127);
        step;
        check(acc_out == 32'sd128, "signed negative product accumulation");
        check(s7_out == ref7(128) && s15_out == ref15(128), "signed accumulated residues");
        drive_pair(-128, 127);
        step;
        check(acc_out == -32'sd16128, "negative accumulator");
        check(s7_out == ref7(-16128) && s15_out == ref15(-16128), "negative accumulator residues");

        // A bubble forwards token metadata but does not update any accumulator.
        av_in = 1'b1;
        bv_in = 1'b0;
        drive_pair(5, -3);
        step;
        check(acc_out == -32'sd16128 && s7_out == ref7(-16128) && s15_out == ref15(-16128), "unpaired valid inhibits every MAC");
        check(a_out == 5 && b_out == -3 && av_out && !bv_out, "bubble data and valids forward");
        check(a7_out == ref7(5) && b7_out == ref7(-3) && a15_out == ref15(5) && b15_out == ref15(-3), "residues forward with their raw tokens");

        compute_en = 1'b0;
        av_in = 1'b0;
        bv_in = 1'b1;
        drive_pair(21, 22);
        step;
        check(a_out == 5 && b_out == -3 && av_out && !bv_out, "global stall holds forwarding state");
        check(acc_out == -32'sd16128, "global stall holds accumulator");

        drain_acc_in = -32'sd12345;
        drain_s7_in = ref7(-12345);
        drain_s15_in = ref15(-12345);
        drain_en = 1'b1;
        compute_en = 1'b1;
        av_in = 1'b1;
        bv_in = 1'b1;
        step;
        check(acc_out == -32'sd12345 && s7_out == ref7(-12345) && s15_out == ref15(-12345), "drain shifts all accumulator states with priority");
        check(a_out == 5 && b_out == -3, "drain holds forwarding state");
        clear = 1'b1;
        step;
        check(acc_out == 0 && s7_out == 0 && s15_out == 0 && !av_out && !bv_out, "clear wins over drain and compute");
        check(a_out == 0 && b_out == 0 && a7_out == 0 && b7_out == 0 && a15_out == 0 && b15_out == 0, "clear zeros all forwarding data");
        clear = 1'b0;
        drain_en = 1'b0;

        // One hundred bounded 32-step signed tiles with stalls and bubbles.
        for (tile = 0; tile < 100; tile = tile + 1) begin
            clear = 1'b1;
            step;
            clear = 1'b0;
            expected_acc = 0;
            for (k = 0; k < 32; k = k + 1) begin
                random_word = $random(random_seed);
                i = random_word[7:0];
                j = random_word[15:8];
                if (i >= 128) i = i - 256;
                if (j >= 128) j = j - 256;
                drive_pair(i, j);
                compute_en = random_word[16] | random_word[17];
                av_in = random_word[18];
                bv_in = random_word[19];
                if (compute_en && av_in && bv_in)
                    expected_acc = expected_acc + i*j;
                step;
                check(acc_out == expected_acc, "random signed main MAC sequence");
                check(s7_out == ref7(expected_acc), "random independent mod7 sequence");
                check(s15_out == ref15(expected_acc), "random independent mod15 sequence");
            end
        end

        if (errors == 0)
            $display("PASS tb_residue: %0d checks; signed8 exhaustive, signed32 10104 vectors, folds exhaustive, 3718 residue MAC tuples, 100 signed tiles and controls", checks);
        else
            $display("FAIL tb_residue: %0d errors in %0d checks", errors, checks);
        $finish;
    end
endmodule

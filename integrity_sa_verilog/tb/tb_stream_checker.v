`timescale 1ns/1ps

module tb_stream_checker;
    reg clk;
    reg rst_n;
    reg clear;
    reg advance;
    reg check;
    reg in_valid;
    reg out_valid;
    reg [7:0] in_token;
    reg [7:0] out_token;
    wire error;
    wire xor_mismatch;
    wire rotation_mismatch;
    wire count_mismatch;
    wire one_token_error;
    wire tail_frame_error;

    reg [7:0] stimulus [0:31];
    integer failures;
    integer i;
    integer trial;
    integer in_index;
    integer out_index;
    integer cycles;
    reg [31:0] rng;
    reg drive_advance;
    reg drive_in;
    reg drive_out;

    isa_stream_checker #(.TOKENS(32)) dut (
        .clk(clk), .rst_n(rst_n), .clear(clear), .advance(advance),
        .check(check), .in_valid(in_valid), .out_valid(out_valid),
        .in_token(in_token), .out_token(out_token), .error(error),
        .xor_mismatch(xor_mismatch),
        .rotation_mismatch(rotation_mismatch),
        .count_mismatch(count_mismatch)
    );

    // The same traffic also exercises the minimum and a partial-frame length.
    isa_stream_checker #(.TOKENS(1)) one_token_dut (
        .clk(clk), .rst_n(rst_n), .clear(clear), .advance(advance),
        .check(check), .in_valid(in_valid), .out_valid(out_valid),
        .in_token(in_token), .out_token(out_token), .error(one_token_error),
        .xor_mismatch(), .rotation_mismatch(), .count_mismatch()
    );
    isa_stream_checker #(.TOKENS(7)) tail_frame_dut (
        .clk(clk), .rst_n(rst_n), .clear(clear), .advance(advance),
        .check(check), .in_valid(in_valid), .out_valid(out_valid),
        .in_token(in_token), .out_token(out_token), .error(tail_frame_error),
        .xor_mismatch(), .rotation_mismatch(), .count_mismatch()
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task require;
        input condition;
        input [511:0] message;
        begin
            if (condition !== 1'b1) begin
                $display("FAIL: %0s", message);
                failures = failures + 1;
            end
        end
    endtask

    task tick;
        input step;
        input iv;
        input ov;
        input [7:0] a;
        input [7:0] b;
        begin
            @(negedge clk);
            advance = step;
            in_valid = iv;
            out_valid = ov;
            in_token = a;
            out_token = b;
            @(posedge clk);
            #1;
        end
    endtask

    task start_frame;
        begin
            @(negedge clk);
            clear = 1'b1;
            advance = 1'b0;
            check = 1'b0;
            in_valid = 1'b0;
            out_valid = 1'b0;
            @(posedge clk);
            #1;
            require(!error, "clear removes sticky error");
            @(negedge clk);
            clear = 1'b0;
        end
    endtask

    task finish_frame;
        begin
            @(negedge clk);
            advance = 1'b0;
            in_valid = 1'b0;
            out_valid = 1'b0;
            check = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            check = 1'b0;
        end
    endtask

    initial begin
        failures = 0;
        rng = 32'h91c5a731;
        rst_n = 1'b0;
        clear = 1'b0;
        advance = 1'b0;
        check = 1'b0;
        in_valid = 1'b0;
        out_valid = 1'b0;
        in_token = 8'd0;
        out_token = 8'd0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Independent ingress/egress bubbles and global stalls preserve order.
        for (trial = 0; trial < 20; trial = trial + 1) begin
            start_frame;
            for (i = 0; i < 32; i = i + 1)
                stimulus[i] = (i * 37 + trial * 11) & 255;
            in_index = 0;
            out_index = 0;
            cycles = 0;
            while ((in_index < 32 || out_index < 32) && cycles < 1000) begin
                rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
                drive_advance = rng[0] | rng[4];
                drive_in = (in_index < 32) && (rng[5] | rng[8]);
                drive_out = (out_index < in_index) && (rng[9] | rng[13]);
                tick(drive_advance, drive_in, drive_out,
                     stimulus[in_index % 32], stimulus[out_index % 32]);
                if (drive_advance && drive_in)
                    in_index = in_index + 1;
                if (drive_advance && drive_out)
                    out_index = out_index + 1;
                cycles = cycles + 1;
            end
            require(cycles < 1000, "randomized transfer completes");
            finish_frame;
            require(!error, "matching interleaved frames survive stalls");
            require(!xor_mismatch && !rotation_mismatch && !count_mismatch,
                    "matching frame signatures and counts agree");
        end

        start_frame;
        for (i = 0; i < 32; i = i + 1)
            tick(1'b1, 1'b1, 1'b1, 8'd0, (i == 9) ? 8'd1 : 8'd0);
        finish_frame;
        require(error && xor_mismatch && rotation_mismatch,
                "single corrupted token detected by both signatures");
        tick(1'b0, 1'b0, 1'b0, 8'd0, 8'd0);
        require(error, "detected error remains sticky");

        // Every raw byte bit, including the sign/MSB bit, reaches both checks.
        for (trial = 0; trial < 8; trial = trial + 1) begin
            start_frame;
            for (i = 0; i < 32; i = i + 1)
                tick(1'b1, 1'b1, 1'b1, 8'd0,
                     (i == 9) ? (8'd1 << trial) : 8'd0);
            finish_frame;
            require(error && xor_mismatch && rotation_mismatch,
                    "all eight raw data bits are protected");
        end

        start_frame;
        for (i = 0; i < 32; i = i + 1)
            tick(1'b1, 1'b1, 1'b1, 8'd1, (i == 9) ? 8'd106 : 8'd1);
        finish_frame;
        require(error && xor_mismatch && rotation_mismatch,
                "raw fingerprint distinguishes equal modulo-7/modulo-15 values");

        start_frame;
        for (i = 0; i < 32; i = i + 1)
            tick(1'b1, 1'b1, 1'b1, 8'd0,
                 (i == 3 || i == 11) ? 8'h80 : 8'd0);
        finish_frame;
        require(error && !xor_mismatch && rotation_mismatch,
                "rotation detects two equal errors canceled by plain XOR");

        start_frame;
        for (i = 0; i < 32; i = i + 1) begin
            if (i == 0)
                tick(1'b1, 1'b1, 1'b1, 8'd1, 8'd2);
            else if (i == 1)
                tick(1'b1, 1'b1, 1'b1, 8'd2, 8'd1);
            else
                tick(1'b1, 1'b1, 1'b1, 8'd0, 8'd0);
        end
        finish_frame;
        require(error && !xor_mismatch && rotation_mismatch,
                "rotation detects a selected token reordering");

        start_frame;
        for (i = 0; i < 32; i = i + 1)
            tick(1'b1, 1'b1, i < 31, 8'd0, 8'd0);
        finish_frame;
        require(error && count_mismatch && !xor_mismatch && !rotation_mismatch,
                "count checking detects a missing zero token");

        start_frame;
        for (i = 0; i < 32; i = i + 1)
            tick(1'b1, 1'b1, 1'b1, 8'd0, 8'd0);
        tick(1'b1, 1'b0, 1'b1, 8'd0, 8'd0);
        require(error, "extra egress token immediately raises sticky error");
        finish_frame;
        require(error, "saturating count cannot hide an extra zero token");

        start_frame;
        for (i = 0; i < 65; i = i + 1)
            tick(1'b1, 1'b1, 1'b1, 8'd0, 8'd0);
        require(dut.in_count == 6'd32 && dut.out_count == 6'd32,
                "counters saturate at 32 rather than wrap");
        finish_frame;
        require(error, "extra tokens on both streams remain an error");

        start_frame;
        tick(1'b1, 1'b1, 1'b0, 8'd97, 8'd0);
        tick(1'b0, 1'b1, 1'b1, 8'd12, 8'd33);
        tick(1'b1, 1'b0, 1'b1, 8'd0, 8'd97);
        finish_frame;
        require(!one_token_error, "TOKENS=1 accepts one matched token");

        start_frame;
        for (i = 0; i < 7; i = i + 1)
            tick(1'b1, 1'b1, 1'b1, i, i);
        finish_frame;
        require(!tail_frame_error, "TOKENS=7 accepts a matched partial frame");
        tick(1'b1, 1'b1, 1'b1, 8'd0, 8'd0);
        require(tail_frame_error, "partial frame rejects an eighth token");

        if (failures == 0)
            $display("PASS: tb_stream_checker");
        else
            $display("FAIL: tb_stream_checker (%0d checks)", failures);
        $finish;
    end

    initial begin
        #1000000;
        $display("FAIL: tb_stream_checker timeout");
        $finish;
    end
endmodule

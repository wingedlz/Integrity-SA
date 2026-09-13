`timescale 1ns/1ps
// Pure Verilog-2001 regression. Fault injection is TB-only hierarchical deposit
// or a one-cycle force on an internal product net; it adds no hardware ports.
module tb_integrity_sa;
    parameter integer K_DEPTH = 32;
    parameter integer NUM_GEMMS = 128;
    parameter integer RUN_FAULTS = 1;
    reg clk, rst_n, start, step_en, out_ready;
    reg [255:0] a_west_flat, b_north_flat;
    reg [31:0] a_valid_west, b_valid_north;
    wire busy, input_ready, out_valid, done, tile_commit, replay_request;
    wire [6:0] wave_index;
    wire [4:0] out_col;
    wire [1023:0] out_data_flat;
    wire [95:0] out_r7_flat;
    wire [127:0] out_r15_flat;
    wire [31:0] out_bad;
    wire transport_error, arithmetic_error, protocol_error, tile_error;
    reg signed [7:0] a_mem [0:32*K_DEPTH-1];
    reg signed [7:0] b_mem [0:K_DEPTH*32-1];
    reg signed [31:0] expected [0:1023];
    reg [31:0] rng;
    integer failures, clean_passed, injected_passed, alias_passed, checked_values;
    integer unprotected_input_cases;
    integer compute_stalls, drain_stalls, id, fault_mode;
    reg previous_done;

    integrity_sa_32x32 #(.K_DEPTH(K_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .step_en(step_en),
        .a_west_flat(a_west_flat), .b_north_flat(b_north_flat),
        .a_valid_west(a_valid_west), .b_valid_north(b_valid_north),
        .busy(busy),
        .input_ready(input_ready), .wave_index(wave_index), .out_ready(out_ready),
        .out_valid(out_valid), .out_col(out_col), .out_data_flat(out_data_flat),
        .out_r7_flat(out_r7_flat), .out_r15_flat(out_r15_flat), .out_bad(out_bad),
        .transport_error(transport_error), .arithmetic_error(arithmetic_error),
        .protocol_error(protocol_error), .tile_error(tile_error),
        .done(done), .tile_commit(tile_commit), .replay_request(replay_request));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk) begin
        #2;
        if (!rst_n) previous_done=0;
        else begin
            if (done && previous_done) fail("done lasted more than one cycle");
            if (!done && (tile_commit || replay_request)) fail("commit/replay without done");
            if (done && ((tile_commit ^ replay_request) !== 1'b1))
                fail("done requires exactly one of commit or replay");
            previous_done=done;
        end
    end

    function [31:0] rand32;
        input unused;
        begin
            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);
            rand32 = rng;
        end
    endfunction

    task fail;
        input [767:0] message;
        begin
            failures = failures + 1;
            $display("FAIL: %0s", message);
        end
    endtask

    task make_matrix;
        input integer pattern;
        integer r,c,k,va,vb,sum;
        reg [31:0] random_value;
        begin
            for (r=0; r<32; r=r+1) begin
                for (k=0; k<K_DEPTH; k=k+1) begin
                    random_value = rand32(0);
                    case (pattern)
                        0: a_mem[r*K_DEPTH+k] = 0;
                        1: a_mem[r*K_DEPTH+k] = (r==k) ? 1 : 0;
                        2,4: a_mem[r*K_DEPTH+k] = -128;
                        3: a_mem[r*K_DEPTH+k] = 127;
                        5: a_mem[r*K_DEPTH+k] = ((r+k)%2) ? -128 : 127;
                        6: a_mem[r*K_DEPTH+k] = (random_value[2:0]==0) ? random_value[15:8] : 0;
                        1000: a_mem[r*K_DEPTH+k] = 1;
                        default: a_mem[r*K_DEPTH+k] = random_value[7:0];
                    endcase
                end
            end
            for (k=0; k<K_DEPTH; k=k+1) begin
                for (c=0; c<32; c=c+1) begin
                    random_value = rand32(0);
                    case (pattern)
                        0: b_mem[k*32+c] = 0;
                        2: b_mem[k*32+c] = -128;
                        3,4: b_mem[k*32+c] = 127;
                        5: b_mem[k*32+c] = ((k+c)%2) ? 127 : -128;
                        6: b_mem[k*32+c] = (random_value[2:0]==0) ? random_value[15:8] : 0;
                        1000: b_mem[k*32+c] = 1;
                        default: b_mem[k*32+c] = random_value[7:0];
                    endcase
                end
            end
            // Golden reference uses host-style signed integer arithmetic only.
            for (r=0; r<32; r=r+1) begin
                for (c=0; c<32; c=c+1) begin
                    sum = 0;
                    for (k=0; k<K_DEPTH; k=k+1) begin
                        va = $signed(a_mem[r*K_DEPTH+k]);
                        vb = $signed(b_mem[k*32+c]);
                        sum = sum + va*vb;
                    end
                    expected[r*32+c] = sum;
                end
            end
        end
    endtask

    task drive_boundary;
        input integer t;
        integer lane,k;
        begin
            a_west_flat=0; b_north_flat=0;
            a_valid_west=0; b_valid_north=0;
            for (lane=0; lane<32; lane=lane+1) begin
                k=t-lane;
                if (k>=0 && k<K_DEPTH) begin
                    a_west_flat[lane*8 +: 8]=a_mem[lane*K_DEPTH+k];
                    b_north_flat[lane*8 +: 8]=b_mem[k*32+lane];
                    a_valid_west[lane]=1;
                    b_valid_north[lane]=1;
                end
            end
        end
    endtask

    // Fault modes: 1 A-forward MSB, 2 A-forward LSB, 3 product, 4 accumulator,
    // 5 shadow accumulator, 6 forwarding-valid, 7 A-forward +105, 8 acc alias,
    // 9 boundary-valid, 10 drain-data, 11 sideband, 12 last drain beat,
    // 13 unprotected ingress data (expected non-detection), 14 B-forward +105.
    task run_tile;
        input integer matrix_id;
        input integer mode;
        integer wall,beats,r,changed,bad_beats,finished,injected,force_active;
        integer got,ref7,ref15;
        reg [31:0] random_value;
        reg held;
        reg [1023:0] held_data;
        reg [95:0] held7;
        reg [127:0] held15;
        reg [31:0] held_bad;
        reg [4:0] held_col;
        begin
            wall=0; beats=0; changed=0; bad_beats=0; finished=0;
            injected=0; force_active=0; held=0;
            @(negedge clk);
            start=1; step_en=0; out_ready=0;
            a_valid_west=0; b_valid_north=0;
            @(posedge clk); #1;
            if (busy !== 1'b1) fail("start did not enter busy");
            if (done || tile_commit || replay_request) fail("stale completion on new start");
            @(negedge clk);
            start=0;
            while (!finished && wall<4096) begin
                random_value=rand32(0);
                step_en=(random_value[1:0]!=0);
                out_ready=(random_value[4:2]!=0);
                drive_boundary(wave_index);
                if (dut.state==3'd1 && !step_en) compute_stalls=compute_stalls+1;
                if (out_valid && !out_ready) drain_stalls=drain_stalls+1;
                #1; // Let ready/state-derived combinational signals settle.

                if (!injected && step_en && input_ready && wave_index==0) begin
                    if (mode==13) begin a_west_flat[0]=~a_west_flat[0]; injected=1; end
                    if (mode==9) begin a_valid_west[0]=0; injected=1; end
                end
                if (!injected && step_en && input_ready && wave_index==9) begin
                    if (mode==1) begin
                        dut.ROWS[3].COLS[5].pe.a_out=dut.ROWS[3].COLS[5].pe.a_out ^ 8'h80;
                        injected=1;
                    end
                    if (mode==2) begin
                        dut.ROWS[3].COLS[5].pe.a_out=dut.ROWS[3].COLS[5].pe.a_out ^ 8'h01;
                        injected=1;
                    end
                    if (mode==6) begin dut.ROWS[3].COLS[5].pe.av_out=0; injected=1; end
                    if (mode==7) begin
                        if (dut.ROWS[3].COLS[5].pe.a_out !== 8'd1) fail("A +105 injection precondition");
                        dut.ROWS[3].COLS[5].pe.a_out=8'd106;
                        injected=1;
                    end
                    if (mode==14) begin
                        if (dut.ROWS[5].COLS[3].pe.b_out !== 8'd1) fail("B +105 injection precondition");
                        dut.ROWS[5].COLS[3].pe.b_out=8'd106;
                        injected=1;
                    end
                    if (mode==11) begin
                        dut.ROWS[3].COLS[5].pe.a7_out=dut.ROWS[3].COLS[5].pe.a7_out ^ 3'b001;
                        injected=1;
                    end
                end
                if (!injected && mode==3 && step_en && input_ready && wave_index==12) begin
                    force dut.ROWS[4].COLS[7].pe.product=16'sd0;
                    force_active=1; injected=1;
                end
                if (!injected && out_valid && beats==0) begin
                    if (mode==4) begin
                        dut.ROWS[2].COLS[10].pe.acc_out=dut.ROWS[2].COLS[10].pe.acc_out ^ 32'd1;
                        injected=1;
                    end
                    if (mode==5) begin
                        dut.ROWS[6].COLS[12].pe.s7_out=dut.ROWS[6].COLS[12].pe.s7_out ^ 3'd1;
                        injected=1;
                    end
                    if (mode==8) begin
                        dut.ROWS[2].COLS[10].pe.acc_out=dut.ROWS[2].COLS[10].pe.acc_out + 32'sd105;
                        injected=1;
                    end
                end
                if (!injected && mode==10 && out_valid && beats==8) begin
                    dut.ROWS[5].COLS[31].pe.acc_out=dut.ROWS[5].COLS[31].pe.acc_out ^ 32'd1;
                    injected=1;
                end
                if (!injected && mode==12 && out_valid && beats==31) begin
                    dut.ROWS[31].COLS[31].pe.acc_out=dut.ROWS[31].COLS[31].pe.acc_out ^ 32'd1;
                    injected=1;
                end
                @(posedge clk);
                if (mode==0 && held && (!out_valid || out_col!==held_col ||
                    out_data_flat!==held_data || out_r7_flat!==held7 || out_r15_flat!==held15 || out_bad!==held_bad))
                    fail("output changed during backpressure");
                held=out_valid && !out_ready;
                held_data=out_data_flat; held7=out_r7_flat; held15=out_r15_flat;
                held_bad=out_bad; held_col=out_col;
                if (out_valid && out_ready) begin
                    if (out_col !== (31-beats)) fail("wrong output column/drain order");
                    if (out_bad !== 32'b0) bad_beats=bad_beats+1;
                    for (r=0; r<32; r=r+1) begin
                        got=$signed(out_data_flat[r*32 +: 32]);
                        if (out_data_flat[r*32 +: 32] !== expected[r*32+31-beats]) begin
                            changed=changed+1;
                            if (mode==0 && changed<=3)
                                $display("GEMM mismatch id=%0d row=%0d col=%0d got=%0d want=%0d",
                                    matrix_id,r,31-beats,got,expected[r*32+31-beats]);
                        end
                        ref7=got%7; if(ref7<0) ref7=ref7+7;
                        ref15=got%15; if(ref15<0) ref15=ref15+15;
                        if (out_r7_flat[r*3 +: 3] !== ref7[2:0] ||
                            out_r15_flat[r*4 +: 4] !== ref15[3:0]) fail("incorrect output residue");
                        if (mode==0) checked_values=checked_values+1;
                    end
                    beats=beats+1;
                end
                #1;
                if (force_active) begin
                    release dut.ROWS[4].COLS[7].pe.product;
                    force_active=0;
                end
                if (done) begin
                    finished=1;
                    if (busy !== 1'b0 || out_valid !== 1'b0 || beats!=32) fail("completion/drain handshake error");
                    if (mode==0) begin
                        if (changed || bad_beats || tile_error !== 1'b0 || tile_commit !== 1'b1 || replay_request !== 1'b0)
                            fail("clean GEMM rejected or incorrect");
                        else clean_passed=clean_passed+1;
                    end else if (mode==8) begin
                        if (!injected || changed!=1 || bad_beats || tile_error !== 1'b0 || tile_commit !== 1'b1 || replay_request !== 1'b0)
                            fail("known modulo-105 alias did not match specified model");
                        else begin
                            alias_passed=alias_passed+1;
                            $display("EXPECTED_ALIAS: accumulator +105 evades both residues (not a clean GEMM pass)");
                        end
                    end else if (mode==13) begin
                        // No upstream reference exists: the SA computes the accepted input.
                        if (!injected || changed!=32 || bad_beats || tile_error !== 1'b0 || tile_commit !== 1'b1 || replay_request !== 1'b0)
                            fail("unprotected ingress data did not match the protection boundary");
                        else begin
                            unprotected_input_cases=unprotected_input_cases+1;
                            $display("EXPECTED_UNPROTECTED_INPUT: changed ingress data is accepted (no SRAM/tag checker)");
                        end
                    end else begin
                        if (!injected || tile_error !== 1'b1 || tile_commit !== 1'b0 || replay_request !== 1'b1)
                            fail("injected fault failed to reject tile");
                        case (mode)
                            1,2: if (transport_error !== 1'b1 || arithmetic_error !== 1'b1 || dut.LANES[3].a_checker.error !== 1'b1)
                                     fail("raw A forwarding fault coverage");
                            3,4,5,10,12: if (arithmetic_error !== 1'b1) fail("arithmetic fault not detected at edge");
                            6,9: if (protocol_error !== 1'b1 || transport_error !== 1'b1) fail("valid/token fault coverage");
                            11: if (transport_error !== 1'b1 || arithmetic_error !== 1'b1) fail("residue sideband fault coverage");
                            7,14: begin
                                if (changed!=26 || bad_beats || transport_error !== 1'b1 || arithmetic_error !== 1'b0 || protocol_error !== 1'b0)
                                    fail("raw fingerprint must detect forwarding +105 without arithmetic mismatch");
                                if (mode==7 && dut.LANES[3].a_checker.error !== 1'b1) fail("A raw fingerprint missed +105");
                                if (mode==14 && dut.LANES[3].b_checker.error !== 1'b1) fail("B raw fingerprint missed +105");
                            end
                        endcase
                        injected_passed=injected_passed+1;
                        $display("FAULT_CASE: mode=%0d changed=%0d bad_beats=%0d errors[T,A,P]=%b%b%b replay=%b",
                            mode,changed,bad_beats,transport_error,arithmetic_error,protocol_error,replay_request);
                    end
                end
                wall=wall+1;
                if (!finished) @(negedge clk);
            end
            if (!finished) fail("tile timeout");
        end
    endtask

    task reset_during_compute;
        integer t;
        begin
            @(negedge clk); start=1; step_en=0;
            @(negedge clk); start=0; step_en=1;
            for(t=0;t<8;t=t+1) begin drive_boundary(wave_index); @(negedge clk); end
            rst_n=0;
            @(posedge clk); #1;
            if(busy || done || tile_commit || replay_request || tile_error) fail("reset did not abort active tile");
            @(negedge clk); rst_n=1; step_en=0; a_valid_west=0; b_valid_north=0;
        end
    endtask

    initial begin
        rst_n=0; start=0; step_en=0; out_ready=0;
        a_west_flat=0; b_north_flat=0; a_valid_west=0; b_valid_north=0;
        rng=32'h71815ace;
        failures=0; clean_passed=0; injected_passed=0; alias_passed=0; checked_values=0;
        compute_stalls=0; drain_stalls=0;
        unprotected_input_cases=0;
        repeat(3) @(negedge clk);
        rst_n=1;
        for(id=0;id<NUM_GEMMS;id=id+1) begin
            make_matrix(id);
            run_tile(id,0);
            if((id+1)%16==0) $display("PROGRESS: K=%0d clean GEMMs=%0d",K_DEPTH,clean_passed);
        end
        if(RUN_FAULTS && K_DEPTH==32) begin
            for(fault_mode=1;fault_mode<=14;fault_mode=fault_mode+1) begin
                make_matrix(1000);
                run_tile(1000+fault_mode,fault_mode);
                // TB resubmission. Modes 8 and 13 do not request recovery themselves.
                run_tile(2000+fault_mode,0);
            end
            reset_during_compute;
            make_matrix(3000);
            run_tile(3000,0);
        end
        repeat(2) @(negedge clk);
        if(done || tile_commit || replay_request) fail("completion pulse persisted while idle");
        if(clean_passed<NUM_GEMMS || compute_stalls==0 || drain_stalls==0) fail("coverage counters incomplete");
        if(RUN_FAULTS && K_DEPTH==32 && (injected_passed!=12 || alias_passed!=1 || unprotected_input_cases!=1))
            fail("directed fault coverage counters incomplete");
        if(failures==0)
            $display("PASS: tb_integrity_sa K=%0d clean_gemms=%0d checked_values=%0d detected_fault_cases=%0d expected_aliases=%0d unprotected_input_cases=%0d compute_stalls=%0d drain_stalls=%0d",
                K_DEPTH,clean_passed,checked_values,injected_passed,alias_passed,unprotected_input_cases,compute_stalls,drain_stalls);
        else $display("FAIL: tb_integrity_sa failures=%0d",failures);
        $finish;
    end

    initial begin
        #20000000;
        $display("FAIL: global watchdog timeout");
        $finish;
    end
endmodule

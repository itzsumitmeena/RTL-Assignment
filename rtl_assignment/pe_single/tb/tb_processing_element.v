`timescale 1ns/1ps
// ============================================================================
// tb_processing_element
//   Self-checking testbench for one PE.
//   Every test feeds a 16-term dot product (k = 0..15) and compares the
//   accumulator with a behavioural reference  sum_k A_k * B_k.
//   Operands carry random garbage above the active width, and random idle
//   (valid = 0) cycles are inserted, to prove isolation and hold behaviour.
//   Tests in INT4, INT8, INT16: zero, identity, positive, negative, mixed,
//   max positive, max negative, max neg x max pos, random.
//   Extra: same numbers in INT4 -> INT8 -> INT16, reserved mode 11.
// ============================================================================
module tb_processing_element;

    // ---------------- clock 300 MHz, DUT signals -------------------------
    reg clk = 1'b0;
    always #1.6665 clk = ~clk;

    reg         rst, valid_in, first_in;
    reg  [1:0]  mode;
    reg  [15:0] a_in, b_in;
    wire [15:0] a_out, b_out;
    wire        valid_out, first_out;
    wire [35:0] acc_out;

    processing_element dut (
        .clk(clk), .rst(rst), .mode(mode),
        .a_in(a_in), .b_in(b_in), .valid_in(valid_in), .first_in(first_in),
        .a_out(a_out), .b_out(b_out), .valid_out(valid_out), .first_out(first_out),
        .acc_out(acc_out)
    );

    // ---------------- test data and bookkeeping ---------------------------
    reg [15:0] av [0:15];
    reg [15:0] bv [0:15];
    integer seed, errs, tests, k;
    integer m_err [0:2];
    integer m_tot [0:2];

    // ---------------- helpers --------------------------------------------
    // operand width and accumulator width of a mode
    function integer opw;  input [1:0] m; opw  = (m == 2'b00) ? 4  : (m == 2'b01) ? 8  : 16; endfunction
    function integer accw; input [1:0] m; accw = (m == 2'b00) ? 12 : (m == 2'b01) ? 20 : 36; endfunction

    // sign-extend the low n bits of v to 64 bits
    function signed [63:0] sext;
        input [63:0] v;
        input integer n;
        reg   [63:0] t;
        begin
            t = v & ((64'd1 << n) - 64'd1);
            if (t[n-1]) t = t - (64'd1 << n);
            sext = t;
        end
    endfunction

    // n-bit value placed in the low bits, random garbage above it
    function [15:0] with_garbage;
        input [15:0] val;
        input integer n;
        reg   [15:0] mask;
        begin
            mask         = (n == 16) ? 16'hFFFF : ((16'd1 << n) - 16'd1);
            with_garbage = (val & mask) | ($random(seed) & ~mask);
        end
    endfunction

    // ---------------- one 16-term dot product ----------------------------
    task run_dot;
        input [8*20-1:0] name;
        reg signed [63:0] exp_v, got_v;
        integer n, w, idx, kk;
        begin
            n = opw(mode);  w = accw(mode);  idx = mode;

            // reference result
            exp_v = 0;
            for (kk = 0; kk < 16; kk = kk + 1)
                exp_v = exp_v + sext(av[kk], n) * sext(bv[kk], n);

            // drive k = 0..15, random idle cycles in between
            for (kk = 0; kk < 16; kk = kk + 1) begin
                if (($random(seed) & 3) == 0) begin
                    @(negedge clk);
                    a_in = $random(seed);  b_in = $random(seed);
                    valid_in = 1'b0;       first_in = $random(seed);
                end
                @(negedge clk);
                a_in = with_garbage(av[kk], n);  b_in = with_garbage(bv[kk], n);
                valid_in = 1'b1;                 first_in = (kk == 0);
            end

            // two more edges: register operands, then accumulate
            @(negedge clk);
            valid_in = 1'b0;  first_in = 1'b0;
            a_in = $random(seed);  b_in = $random(seed);
            @(negedge clk);
            @(negedge clk);

            // compare the active accumulator width only
            got_v = sext(acc_out, w);
            tests = tests + 1;  m_tot[idx] = m_tot[idx] + 1;
            if (got_v !== exp_v) begin
                errs = errs + 1;  m_err[idx] = m_err[idx] + 1;
                $display("FAIL  %0s  mode=%0d  got=%0d  exp=%0d", name, mode, got_v, exp_v);
            end
        end
    endtask

    // ---------------- operand pattern generator --------------------------
    // kind: 0 zero, 1 identity, 2 positive, 3 negative, 4 mixed,
    //       5 max positive, 6 max negative, 7 max neg x max pos
    task fill;
        input integer kind;
        integer n, i;
        reg [15:0] maxp, maxn, lowm;
        begin
            n    = opw(mode);
            maxp = (16'd1 << (n-1)) - 16'd1;          // 0111..1
            maxn = (16'd1 << (n-1));                  // 1000..0
            lowm = maxp;
            for (i = 0; i < 16; i = i + 1) begin
                case (kind)
                    0: begin av[i] = 0;                      bv[i] = $random(seed); end
                    1: begin av[i] = (i == 5);               bv[i] = $random(seed); end
                    2: begin av[i] = $random(seed) & lowm;   bv[i] = $random(seed) & lowm; end
                    3: begin av[i] = maxn | ($random(seed) & lowm);
                             bv[i] = maxn | ($random(seed) & lowm); end
                    5: begin av[i] = maxp;                   bv[i] = maxp; end
                    6: begin av[i] = maxn;                   bv[i] = maxn; end
                    7: begin av[i] = maxn;                   bv[i] = maxp; end
                    default: begin av[i] = $random(seed);    bv[i] = $random(seed); end
                endcase
            end
        end
    endtask

    // ---------------- main sequence --------------------------------------
    integer md, kind, r;
    reg [35:0]        acc_before;
    reg signed [63:0] same_res [0:2];

    initial begin
        seed = 32'h5EED1234;  errs = 0;  tests = 0;
        for (md = 0; md < 3; md = md + 1) begin m_err[md] = 0; m_tot[md] = 0; end

        rst = 1'b1;  mode = 2'b10;  valid_in = 1'b0;  first_in = 1'b0;
        a_in = 16'd0;  b_in = 16'd0;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // ---- directed + random tests in every mode (INT16 first, so the
        //      upper bands hold stale data when INT4/INT8 run afterwards) ----
        for (md = 2; md >= 0; md = md - 1) begin
            @(negedge clk);  mode = md;
            for (kind = 0; kind < 8; kind = kind + 1) begin
                fill(kind);  run_dot("directed");
            end
            for (r = 0; r < 200; r = r + 1) begin
                fill(4);  run_dot("random");
            end
        end

        // ---- same numbers in INT4 -> INT8 -> INT16 (values fit in 4 bits) ----
        for (k = 0; k < 16; k = k + 1) begin
            av[k] = sext($random(seed) % 8, 4);          // -7 .. 7, sign-extended to 16 bit
            bv[k] = sext(-($random(seed) & 7), 4);       // -7 .. 0
        end
        for (md = 0; md < 3; md = md + 1) begin
            @(negedge clk);  mode = md;
            run_dot("mode-switch");
            same_res[md] = sext(acc_out, accw(mode));
        end
        if ((same_res[0] !== same_res[1]) || (same_res[1] !== same_res[2])) begin
            errs = errs + 1;
            $display("FAIL  mode-switch results differ: %0d %0d %0d", same_res[0], same_res[1], same_res[2]);
        end else
            $display("mode-switch INT4 -> INT8 -> INT16 : %0d %0d %0d (equal)", same_res[0], same_res[1], same_res[2]);

        // ---- reserved mode 11 must not change the accumulator ----
        acc_before = acc_out;
        @(negedge clk);  mode = 2'b11;
        for (k = 0; k < 16; k = k + 1) begin
            @(negedge clk);
            a_in = $random(seed);  b_in = $random(seed);  valid_in = 1'b1;  first_in = (k == 0);
        end
        @(negedge clk);  valid_in = 1'b0;  first_in = 1'b0;
        repeat (2) @(negedge clk);
        tests = tests + 1;
        if (acc_out !== acc_before) begin
            errs = errs + 1;
            $display("FAIL  reserved mode changed the accumulator");
        end

        // ---- summary ----
        $display("--------------------------------------------------");
        $display("INT4  : %0d tests, %0d errors", m_tot[0], m_err[0]);
        $display("INT8  : %0d tests, %0d errors", m_tot[1], m_err[1]);
        $display("INT16 : %0d tests, %0d errors", m_tot[2], m_err[2]);
        $display("TOTAL : %0d tests, %0d errors -> %s", tests, errs, (errs == 0) ? "PASS" : "FAIL");
        $display("--------------------------------------------------");
        $finish;
    end
endmodule

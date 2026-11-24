`timescale 1ns/1ps
// ============================================================================
// tb_pe_power
//   Power-analysis testbench for one PE: one run = one mode = one VCD.
//   Back-to-back 16-term dot products at 300 MHz (valid every cycle).
//   Same seed in every mode -> statistically equivalent uniform n-bit data.
//   Upper operand bits are held at 0 (as in the array, where the upstream
//   PE register holds them); +GARBAGE=1 makes them random instead.
//   Results are still self-checked, so no power number comes from a
//   wrong computation.
//
//   Plusargs: +MODE=0|1|2  +N=<dot products>  +VCD=<file>  +GARBAGE=0|1
// ============================================================================
module tb_pe_power;

    // ---------------- clock, DUT ------------------------------------------
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

    // ---------------- run parameters --------------------------------------
    integer m, ndot, garbage, seed, errs, t, d, n, w;
    reg [8*64-1:0]    vcdname;
    reg [15:0]        mask, av, bv;
    reg signed [63:0] expv [0:4095];

    // sign-extend the low nb bits of v to 64 bits
    function signed [63:0] sext;
        input [63:0] v;
        input integer nb;
        reg   [63:0] tt;
        begin
            tt = v & ((64'd1 << nb) - 64'd1);
            if (tt[nb-1]) tt = tt - (64'd1 << nb);
            sext = tt;
        end
    endfunction

    initial begin
        if (!$value$plusargs("MODE=%d", m))       m = 2;
        if (!$value$plusargs("N=%d", ndot))       ndot = 200;
        if (!$value$plusargs("GARBAGE=%d", garbage)) garbage = 0;
        if (!$value$plusargs("VCD=%s", vcdname))  vcdname = "pe_power.vcd";

        // ---- widths of this mode ----
        n    = (m == 0) ? 4  : (m == 1) ? 8  : 16;
        w    = (m == 0) ? 12 : (m == 1) ? 20 : 36;
        mask = (n == 16) ? 16'hFFFF : ((16'd1 << n) - 16'd1);
        seed = 32'h1A2B3C4D;  errs = 0;

        // ---- reset, then fix the mode before dumping starts ----
        rst = 1'b1;  mode = m[1:0];  valid_in = 1'b0;  first_in = 1'b0;
        a_in = 16'd0;  b_in = 16'd0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        $dumpfile(vcdname);
        $dumpvars(0, tb_pe_power.dut);

        // ---- cycle t drives element k = t%16 of dot product d = t/16 ----
        //      the result of dot d is in acc_out two edges after its k = 15
        for (t = 0; t <= 16*ndot + 1; t = t + 1) begin
            @(negedge clk);

            if ((t >= 17) && (((t - 17) % 16) == 0)) begin
                d = (t - 17) / 16;
                if (sext(acc_out, w) !== expv[d]) begin
                    errs = errs + 1;
                    if (errs <= 5) $display("MISMATCH dot %0d: got %0d exp %0d", d, sext(acc_out, w), expv[d]);
                end
            end

            if (t < 16*ndot) begin
                d  = t / 16;
                av = ($random(seed) & mask) | (garbage ? ($random(seed) & ~mask) : 16'd0);
                bv = ($random(seed) & mask) | (garbage ? ($random(seed) & ~mask) : 16'd0);
                if ((t % 16) == 0) expv[d] = 0;
                expv[d]  = expv[d] + sext(av, n) * sext(bv, n);
                a_in     = av;    b_in     = bv;
                valid_in = 1'b1;  first_in = ((t % 16) == 0);
            end else begin
                valid_in = 1'b0;  first_in = 1'b0;
            end
        end

        // flush and close cleanly: no $dumpoff, its all-x block can be cut
        // off by $finish and leave an incomplete VCD
        $dumpflush;
        #1;
        $display("MODE=%0d  dot products=%0d  errors=%0d -> %s  (VCD %0s, end %0t)",
                 m, ndot, errs, (errs == 0) ? "PASS" : "FAIL", vcdname, $time);
        $finish;
    end
endmodule

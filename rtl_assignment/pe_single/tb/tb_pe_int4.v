`timescale 1ns/1ps
// ============================================================================
// tb_pe_int4
//   Near-exhaustive INT4 verification of processing_element (mode = 00).
//   Signed 4-bit operands: -8 .. 7, products -56 .. 64, 12-bit accumulator.
//
//   Checkers
//     - golden model: every cycle ALL outputs (acc_out 36 bit, a_out, b_out,
//       valid_out, first_out) are compared; X on any output is an error
//     - expected value: every dot product / partial sum has a computed
//       expected value that is compared when it appears on acc_out
//
//   Tests
//     T01 directed products, expected and got printed
//     T02 all 256 products (+ printed 16 x 16 product table, sign quadrants)
//     T03 all 256 products with 4 garbage patterns in bits [15:4]
//     T04 all 65,536 sums of two products
//     T05 16 x the same product, for all 256 products (range limits)
//     T06 accumulator walk: every 12-bit value, wrap-around, big carries
//     T07 structured 16-term dot products, expected and got printed
//     T08 random 16-term dot products, idle gaps, garbage, back to back
//     T09 hold: long idle stretches inside and after a dot product
//     T10 upper bits [35:12] of ACC and [15:4] of A/B never touched
//     T11 reserved mode 11 in between INT4 work
//     T12 asynchronous reset in the middle of a dot product
//
//   Plusargs: +SEED=<n>  +NRAND=<random dots>  +VERBOSE=1 (all 256 products)
// ============================================================================
module tb_pe_int4;

    // ------------------------------------------------------------------
    // Clock (300 MHz) and DUT
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // Bookkeeping
    // ------------------------------------------------------------------
    localparam NT = 13;                          // tests T01..T12 (index 0 unused)
    integer seed, seed0, nrand, verbose;
    integer tcyc, cur_t, nprint;
    integer t_chk [0:NT-1];                      // expected-value checks per test
    integer t_err [0:NT-1];                      // errors per test
    integer g_chk, g_err;                        // golden-model cycle checks / errors
    integer q_tot [0:4], q_err [0:4];            // T02 quadrants: ++ +- -+ -- zero
    integer got_tab [0:255];                     // T02 product table
    reg     chk_en;

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    // sign-extend the low n bits of v
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

    // 4-bit operand pattern with chosen bits [15:4]
    function [15:0] op4;
        input integer v;                          // -8 .. 7
        input [15:0]  upper;
        op4 = (upper & 16'hFFF0) | (v & 15);
    endfunction

    function [15:0] opmask;  input [1:0] m;
        opmask  = (m == 2'b00) ? 16'h000F : (m == 2'b01) ? 16'h00FF : (m == 2'b10) ? 16'hFFFF : 16'h0000;
    endfunction
    function [35:0] accmask; input [1:0] m;
        accmask = (m == 2'b00) ? 36'h000000FFF : (m == 2'b01) ? 36'h0000FFFFF :
                  (m == 2'b10) ? 36'hFFFFFFFFF : 36'h000000000;
    endfunction
    function integer opw; input [1:0] m; opw = (m == 2'b00) ? 4 : (m == 2'b01) ? 8 : 16; endfunction

    // ------------------------------------------------------------------
    // Golden model (behavioural, independent of the RTL)
    // ------------------------------------------------------------------
    function [35:0] mac_next;
        input [35:0] acc;
        input [15:0] a, b;
        input        f;
        input [1:0]  m;
        reg signed [63:0] p;
        reg        [63:0] s;
        begin
            if (m == 2'b11) mac_next = acc;
            else begin
                p = sext(a, opw(m)) * sext(b, opw(m));
                s = (f ? 64'd0 : {28'd0, acc}) + p;
                mac_next = (acc & ~accmask(m)) | (s[35:0] & accmask(m));
            end
        end
    endfunction

    reg [15:0] m_a, m_b;
    reg        m_v, m_f;
    reg [35:0] m_acc;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            m_a <= 16'd0;  m_b <= 16'd0;  m_v <= 1'b0;  m_f <= 1'b0;  m_acc <= 36'd0;
        end else begin
            if (m_v) m_acc <= mac_next(m_acc, m_a, m_b, m_f, mode);
            if (valid_in) begin
                m_a <= (m_a & ~opmask(mode)) | (a_in & opmask(mode));
                m_b <= (m_b & ~opmask(mode)) | (b_in & opmask(mode));
            end
            m_v <= valid_in;
            m_f <= first_in & valid_in;
        end
    end

    task golden_check;
        begin
            g_chk = g_chk + 1;
            if (((^{acc_out, a_out, b_out, valid_out, first_out}) === 1'bx) ||
                ({acc_out, a_out, b_out, valid_out, first_out} !== {m_acc, m_a, m_b, m_v, m_f})) begin
                g_err = g_err + 1;  t_err[cur_t] = t_err[cur_t] + 1;
                if (nprint < 12) begin
                    nprint = nprint + 1;
                    $display("[%0t] T%0d GOLDEN mismatch  acc %h/%h  a %h/%h  b %h/%h  v %b/%b  f %b/%b", $time, cur_t,
                             acc_out, m_acc, a_out, m_a, b_out, m_b, valid_out, m_v, first_out, m_f);
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Expected-value queue: a value expected on acc_out at cycle "due"
    //   tag >= 0 : T02 table index, mod = 1 : compare modulo 2^12
    // ------------------------------------------------------------------
    integer q_exp [0:15], q_due [0:15], q_tst [0:15], q_tag [0:15], q_mod [0:15];
    integer q_head, q_tail, q_cnt;

    task expect_acc;                              // call right after the last cyc
        input integer exp_v, mod, tag;
        begin
            q_exp[q_tail] = exp_v;  q_due[q_tail] = tcyc + 2;  q_tst[q_tail] = cur_t;
            q_tag[q_tail] = tag;    q_mod[q_tail] = mod;
            q_tail = (q_tail + 1) % 16;  q_cnt = q_cnt + 1;
        end
    endtask

    task pop_expected;
        integer got, e, tg, tt, bad, ai, bi, qi;
        begin
            while ((q_cnt > 0) && (q_due[q_head] == tcyc)) begin
                e   = q_exp[q_head];  tg = q_tag[q_head];  tt = q_tst[q_head];
                got = sext(acc_out, 12);
                bad = q_mod[q_head] ? ((acc_out[11:0]) !== (e & 12'hFFF)) : (got !== e);
                t_chk[tt] = t_chk[tt] + 1;
                if (bad) begin
                    t_err[tt] = t_err[tt] + 1;
                    if (nprint < 12) begin
                        nprint = nprint + 1;
                        $display("[%0t] T%0d EXPECTED mismatch  got %0d  exp %0d", $time, tt, got, e);
                    end
                end
                if (tg >= 0) begin                        // T02 table and quadrants
                    got_tab[tg] = got;
                    ai = tg / 16 - 8;  bi = tg % 16 - 8;
                    qi = ((ai == 0) || (bi == 0)) ? 4 : ((ai < 0) ? 2 : 0) + ((bi < 0) ? 1 : 0);
                    q_tot[qi] = q_tot[qi] + 1;
                    if (bad) q_err[qi] = q_err[qi] + 1;
                end
                q_head = (q_head + 1) % 16;  q_cnt = q_cnt - 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // One cycle: golden check, expected-value check, then drive (negedge)
    // ------------------------------------------------------------------
    task cyc;
        input [15:0] a, b;
        input        v, f;
        begin
            @(negedge clk);
            tcyc = tcyc + 1;
            if (chk_en) golden_check;
            pop_expected;
            a_in = a;  b_in = b;  valid_in = v;  first_in = f;
        end
    endtask

    task idle;
        begin
            cyc($random(seed), $random(seed), 1'b0, $random(seed));
        end
    endtask

    task drain;                                   // let every pending value appear
        begin
            idle;  idle;  idle;
        end
    endtask

    // random value -8 .. 7 and random upper garbage
    function integer r4;
        input integer dummy;
        r4 = ($unsigned($random(seed)) % 16) - 8;
    endfunction

    // ------------------------------------------------------------------
    // T01 / T07: drained dot product with printed expected and got
    // ------------------------------------------------------------------
    integer da [0:15], db [0:15];

    task print_dot;
        input [8*30-1:0] name;
        input integer    len;
        integer k, e, got;
        begin
            e = 0;
            for (k = 0; k < len; k = k + 1) e = e + da[k] * db[k];
            for (k = 0; k < len; k = k + 1)
                cyc(op4(da[k], $random(seed)), op4(db[k], $random(seed)), 1'b1, (k == 0));
            idle;  idle;
            got = sext(acc_out, 12);
            t_chk[cur_t] = t_chk[cur_t] + 1;
            if (got !== e) t_err[cur_t] = t_err[cur_t] + 1;
            $display("  %s expected %6d   got %6d   %s", name, e, got, (got === e) ? "PASS" : "FAIL");
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    integer i, j, k, p, n, e, walk, len, step;
    integer pa, pb, qa, qb;
    reg [35:0] keep_acc;
    reg [15:0] keep_a, keep_b;
    reg [15:0] gpat [0:3];
    integer total_err;
    integer dl_a [0:19], dl_b [0:19];            // T01 directed operand list

    initial begin
        if (!$value$plusargs("SEED=%d", seed))       seed = 32'h4B1D0004;
        if (!$value$plusargs("NRAND=%d", nrand))     nrand = 5000;
        if (!$value$plusargs("VERBOSE=%d", verbose)) verbose = 0;
        seed0 = seed;

        tcyc = 0;  cur_t = 0;  nprint = 0;  g_chk = 0;  g_err = 0;  chk_en = 1'b0;
        q_head = 0;  q_tail = 0;  q_cnt = 0;
        for (i = 0; i < NT; i = i + 1) begin t_chk[i] = 0; t_err[i] = 0; end
        for (i = 0; i < 5; i = i + 1)  begin q_tot[i] = 0; q_err[i] = 0; end
        for (i = 0; i < 256; i = i + 1) got_tab[i] = 0;
        gpat[0] = 16'h0000;  gpat[1] = 16'hFFF0;  gpat[2] = 16'hA5A0;  gpat[3] = 16'h5A50;

        // ---- reset ----
        rst = 1'b1;  mode = 2'b10;  valid_in = 1'b0;  first_in = 1'b0;  a_in = 16'd0;  b_in = 16'd0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        chk_en = 1'b1;

        // ---- prelude: an INT16 dot product leaves non-zero upper state ----
        for (k = 0; k < 16; k = k + 1)
            cyc(16'h8000 | $random(seed), 16'h8000 | $random(seed), 1'b1, (k == 0));
        drain;
        keep_acc = acc_out;  keep_a = a_out;  keep_b = b_out;
        $display("prelude INT16: ACC = %h, A = %h, B = %h (upper bits must survive INT4)", keep_acc, keep_a, keep_b);
        mode = 2'b00;                                    // INT4 from here on

        // ================= T01 directed products =================
        cur_t = 1;
        $display("");
        $display("T01 directed products (A x B)");
        begin
            dl_a[0]=0;  dl_b[0]=0;   dl_a[1]=1;  dl_b[1]=1;   dl_a[2]=7;  dl_b[2]=7;   dl_a[3]=-8; dl_b[3]=-8;
            dl_a[4]=-8; dl_b[4]=7;   dl_a[5]=7;  dl_b[5]=-8;  dl_a[6]=-1; dl_b[6]=-1;  dl_a[7]=-1; dl_b[7]=7;
            dl_a[8]=3;  dl_b[8]=-5;  dl_a[9]=-8; dl_b[9]=1;   dl_a[10]=-8;dl_b[10]=0;  dl_a[11]=5; dl_b[11]=-3;
            dl_a[12]=-4;dl_b[12]=-4; dl_a[13]=2; dl_b[13]=-8; dl_a[14]=-7;dl_b[14]=-7; dl_a[15]=6; dl_b[15]=-6;
            dl_a[16]=-3;dl_b[16]=5;  dl_a[17]=4; dl_b[17]=7;  dl_a[18]=-2;dl_b[18]=-8; dl_a[19]=-5;dl_b[19]=6;
            for (i = 0; i < 20; i = i + 1) begin
                da[0] = dl_a[i];  db[0] = dl_b[i];
                print_dot("product", 1);
                $display("        (A = %0d, B = %0d)", dl_a[i], dl_b[i]);
            end
        end

        // ================= T02 all 256 products =================
        cur_t = 2;
        for (pa = -8; pa < 8; pa = pa + 1)
            for (pb = -8; pb < 8; pb = pb + 1) begin
                cyc(op4(pa, $random(seed)), op4(pb, $random(seed)), 1'b1, 1'b1);
                expect_acc(pa * pb, 0, (pa + 8) * 16 + (pb + 8));
            end
        drain;
        $display("");
        $display("T02 INT4 product table (got values, '!' = mismatch)");
        $write("   A\\B |");
        for (pb = -8; pb < 8; pb = pb + 1) $write("%4d ", pb);
        $display("");
        for (pa = -8; pa < 8; pa = pa + 1) begin
            $write("  %4d |", pa);
            for (pb = -8; pb < 8; pb = pb + 1)
                $write("%4d%s", got_tab[(pa + 8) * 16 + (pb + 8)],
                       (got_tab[(pa + 8) * 16 + (pb + 8)] == pa * pb) ? " " : "!");
            $display("");
        end
        if (verbose)
            for (pa = -8; pa < 8; pa = pa + 1)
                for (pb = -8; pb < 8; pb = pb + 1)
                    $display("  A=%3d B=%3d expected %4d got %4d", pa, pb, pa * pb, got_tab[(pa + 8) * 16 + (pb + 8)]);

        // ================= T03 products with garbage in [15:4] =================
        cur_t = 3;
        for (i = 0; i < 4; i = i + 1)
            for (pa = -8; pa < 8; pa = pa + 1)
                for (pb = -8; pb < 8; pb = pb + 1) begin
                    cyc(op4(pa, (i == 3) ? $random(seed) : gpat[i]),
                        op4(pb, (i == 3) ? $random(seed) : ~gpat[i]), 1'b1, 1'b1);
                    expect_acc(pa * pb, 0, -1);
                end
        drain;

        // ================= T04 all sums of two products =================
        cur_t = 4;
        $display("");
        $display("T04 all 65,536 two-term sums (running)");
        for (i = 0; i < 256; i = i + 1)
            for (j = 0; j < 256; j = j + 1) begin
                pa = i / 16 - 8;  pb = i % 16 - 8;  qa = j / 16 - 8;  qb = j % 16 - 8;
                cyc(op4(pa, $random(seed)), op4(pb, $random(seed)), 1'b1, 1'b1);
                cyc(op4(qa, $random(seed)), op4(qb, $random(seed)), 1'b1, 1'b0);
                expect_acc(pa * pb + qa * qb, 0, -1);
            end
        drain;

        // ================= T05 16 x the same product =================
        cur_t = 5;
        for (pa = -8; pa < 8; pa = pa + 1)
            for (pb = -8; pb < 8; pb = pb + 1) begin
                for (k = 0; k < 16; k = k + 1)
                    cyc(op4(pa, $random(seed)), op4(pb, $random(seed)), 1'b1, (k == 0));
                expect_acc(16 * pa * pb, 0, -1);
            end
        drain;

        // ================= T06 accumulator walk =================
        cur_t = 6;
        walk = 0;                                        // start: 0 x 0, first
        cyc(op4(0, 0), op4(0, 0), 1'b1, 1'b1);           expect_acc(0, 1, -1);
        for (k = 0; k < 4096; k = k + 1) begin           // +1 through every value, wraps once
            cyc(op4(1, 0), op4(1, 0), 1'b1, 1'b0);        walk = walk + 1;  expect_acc(walk, 1, -1);
        end
        for (k = 0; k < 4096; k = k + 1) begin           // -1 back through every value
            cyc(op4(1, 0), op4(-1, 0), 1'b1, 1'b0);       walk = walk - 1;  expect_acc(walk, 1, -1);
        end
        for (k = 0; k < 300; k = k + 1) begin            // big steps: +64 / -56, many carries
            step = (k % 3 == 2) ? -56 : 64;
            if (step == 64) cyc(op4(-8, 0), op4(-8, 0), 1'b1, 1'b0);
            else            cyc(op4(-8, 0), op4(7, 0),  1'b1, 1'b0);
            walk = walk + step;  expect_acc(walk, 1, -1);
        end
        drain;

        // ================= T07 structured 16-term dot products =================
        cur_t = 7;
        $display("");
        $display("T07 structured 16-term dot products");
        for (k = 0; k < 16; k = k + 1) begin da[k] = 0;  db[k] = r4(0); end          print_dot("zero A                        ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = r4(0); db[k] = 0;  end          print_dot("zero B                        ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = (k == 9) ? 1 : 0; db[k] = r4(0); end    print_dot("identity (picks B[9])         ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 7;  db[k] = 7;  end             print_dot("all  7 x  7  (max positive)   ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = -8; db[k] = -8; end             print_dot("all -8 x -8  (largest sum)    ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = -8; db[k] = 7;  end             print_dot("all -8 x  7  (most negative)  ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 7;  db[k] = -8; end             print_dot("all  7 x -8                   ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 1 + ($unsigned($random(seed)) % 7); db[k] = 1 + ($unsigned($random(seed)) % 7); end
                                                                                       print_dot("positive x positive           ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = -1 - ($unsigned($random(seed)) % 8); db[k] = -1 - ($unsigned($random(seed)) % 8); end
                                                                                       print_dot("negative x negative           ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 1 + ($unsigned($random(seed)) % 7); db[k] = -1 - ($unsigned($random(seed)) % 8); end
                                                                                       print_dot("positive x negative           ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = (k % 2) ? 7 : -8; db[k] = -8; end print_dot("alternating sign, sum ~ 0     ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = r4(0); db[k] = r4(0); end       print_dot("random                        ", 16);

        // ================= T08 random dot products =================
        cur_t = 8;
        for (i = 0; i < nrand; i = i + 1) begin
            len = 1 + ($unsigned($random(seed)) % 16);
            e = 0;
            for (k = 0; k < len; k = k + 1) begin
                pa = r4(0);  pb = r4(0);  e = e + pa * pb;
                if (($random(seed) & 3) == 0) idle;
                cyc(op4(pa, $random(seed)), op4(pb, $random(seed)), 1'b1, (k == 0));
            end
            expect_acc(e, 0, -1);
            if ($random(seed) & 1) idle;
        end
        drain;

        // ================= T09 hold during long idle =================
        cur_t = 9;
        for (i = 0; i < 20; i = i + 1) begin
            e = 0;
            for (k = 0; k < 16; k = k + 1) begin
                pa = r4(0);  pb = r4(0);  e = e + pa * pb;
                cyc(op4(pa, $random(seed)), op4(pb, $random(seed)), 1'b1, (k == 0));
                if (k == 7) for (j = 0; j < 30; j = j + 1) idle;       // stall in the middle
            end
            expect_acc(e, 0, -1);
            for (j = 0; j < 30; j = j + 1) idle;                       // result must stay
            t_chk[9] = t_chk[9] + 1;
            if (sext(acc_out, 12) !== e) t_err[9] = t_err[9] + 1;
        end
        drain;

        // ================= T10 upper bits never touched by INT4 =================
        cur_t = 10;
        t_chk[10] = t_chk[10] + 3;
        if (acc_out[35:12] !== keep_acc[35:12]) t_err[10] = t_err[10] + 1;
        if (a_out[15:4]    !== keep_a[15:4])    t_err[10] = t_err[10] + 1;
        if (b_out[15:4]    !== keep_b[15:4])    t_err[10] = t_err[10] + 1;
        $display("");
        $display("T10 upper state after all INT4 tests: ACC[35:12] %h (was %h), A[15:4] %h (was %h), B[15:4] %h (was %h)",
                 acc_out[35:12], keep_acc[35:12], a_out[15:4], keep_a[15:4], b_out[15:4], keep_b[15:4]);

        // ================= T11 reserved mode in between =================
        cur_t = 11;
        keep_acc = acc_out;
        mode = 2'b11;
        for (k = 0; k < 40; k = k + 1) cyc($random(seed), $random(seed), $random(seed), $random(seed));
        drain;
        t_chk[11] = t_chk[11] + 1;
        if (acc_out !== keep_acc) t_err[11] = t_err[11] + 1;
        mode = 2'b00;
        for (k = 0; k < 16; k = k + 1) begin da[k] = r4(0); db[k] = r4(0); end
        $display("");
        $display("T11 after 40 reserved-mode cycles (ACC unchanged: %s)", (acc_out === keep_acc) ? "yes" : "NO");
        print_dot("INT4 dot right after reserved ", 16);

        // ================= T12 reset in the middle of a dot product =================
        cur_t = 12;
        for (i = 0; i < 20; i = i + 1) begin
            n = 1 + ($unsigned($random(seed)) % 15);
            for (k = 0; k < n; k = k + 1) cyc(op4(r4(0), $random(seed)), op4(r4(0), $random(seed)), 1'b1, (k == 0));
            @(negedge clk);  tcyc = tcyc + 1;  golden_check;
            rst = 1'b1;  valid_in = 1'b0;  first_in = 1'b0;
            @(negedge clk);  tcyc = tcyc + 1;  golden_check;
            t_chk[12] = t_chk[12] + 1;
            if ({acc_out, a_out, b_out, valid_out, first_out} !== 70'd0) t_err[12] = t_err[12] + 1;
            rst = 1'b0;
            e = 0;
            for (k = 0; k < 16; k = k + 1) begin
                pa = r4(0);  pb = r4(0);  e = e + pa * pb;
                cyc(op4(pa, $random(seed)), op4(pb, $random(seed)), 1'b1, (k == 0));
            end
            expect_acc(e, 0, -1);
            drain;
        end

        // ---------------- summary ----------------
        total_err = g_err;
        for (i = 1; i < NT; i = i + 1) total_err = total_err + t_err[i];
        $display("");
        $display("==================================================================");
        $display(" PE INT4 verification   seed = %0d", seed0);
        $display("==================================================================");
        $display(" Test                                        checks   errors");
        $display(" T01 directed products                     %8d %8d  %s", t_chk[1],  t_err[1],  (t_err[1]  == 0) ? "PASS" : "FAIL");
        $display(" T02 all 256 products                      %8d %8d  %s", t_chk[2],  t_err[2],  (t_err[2]  == 0) ? "PASS" : "FAIL");
        $display(" T03 256 products x 4 garbage patterns     %8d %8d  %s", t_chk[3],  t_err[3],  (t_err[3]  == 0) ? "PASS" : "FAIL");
        $display(" T04 all two-term sums                     %8d %8d  %s", t_chk[4],  t_err[4],  (t_err[4]  == 0) ? "PASS" : "FAIL");
        $display(" T05 16 x each product (range limits)      %8d %8d  %s", t_chk[5],  t_err[5],  (t_err[5]  == 0) ? "PASS" : "FAIL");
        $display(" T06 accumulator walk (all 4096 values)    %8d %8d  %s", t_chk[6],  t_err[6],  (t_err[6]  == 0) ? "PASS" : "FAIL");
        $display(" T07 structured dot products               %8d %8d  %s", t_chk[7],  t_err[7],  (t_err[7]  == 0) ? "PASS" : "FAIL");
        $display(" T08 random dot products                   %8d %8d  %s", t_chk[8],  t_err[8],  (t_err[8]  == 0) ? "PASS" : "FAIL");
        $display(" T09 hold during long idle                 %8d %8d  %s", t_chk[9],  t_err[9],  (t_err[9]  == 0) ? "PASS" : "FAIL");
        $display(" T10 upper bits untouched                  %8d %8d  %s", t_chk[10], t_err[10], (t_err[10] == 0) ? "PASS" : "FAIL");
        $display(" T11 reserved mode in between              %8d %8d  %s", t_chk[11], t_err[11], (t_err[11] == 0) ? "PASS" : "FAIL");
        $display(" T12 async reset mid-dot                   %8d %8d  %s", t_chk[12], t_err[12], (t_err[12] == 0) ? "PASS" : "FAIL");
        $display("------------------------------------------------------------------");
        $display(" T02 sign quadrants         products   errors");
        $display("   (+) x (+)                %8d %8d", q_tot[0], q_err[0]);
        $display("   (+) x (-)                %8d %8d", q_tot[1], q_err[1]);
        $display("   (-) x (+)                %8d %8d", q_tot[2], q_err[2]);
        $display("   (-) x (-)                %8d %8d", q_tot[3], q_err[3]);
        $display("   zero operand             %8d %8d", q_tot[4], q_err[4]);
        $display("------------------------------------------------------------------");
        $display(" golden-model cycle checks : %0d   errors : %0d", g_chk, g_err);
        $display(" RESULT : %s", (total_err == 0) ? "PASS" : "FAIL");
        $display("==================================================================");
        $finish;
    end

    // watchdog
    initial begin
        #100_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule

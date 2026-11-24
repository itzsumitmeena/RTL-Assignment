`timescale 1ns/1ps
// ============================================================================
// tb_pe_int8
//   Near-exhaustive INT8 verification of processing_element (mode = 01).
//   Signed 8-bit operands: -128 .. 127, products -16256 .. 16384,
//   20-bit accumulator (16-term sums -260096 .. 262144).
//
//   Checkers
//     - golden model: every cycle ALL outputs (acc_out 36 bit, a_out, b_out,
//       valid_out, first_out) are compared; X on any output is an error
//     - expected value: every product / dot product / partial sum has a
//       computed expected value, compared when it appears on acc_out
//
//   Tests
//     T01 directed products, expected and got printed
//     T02 all 65,536 products (+ printed corner table, sign quadrants)
//     T03 all 65,536 products again, fixed garbage patterns in bits [15:8]
//     T04 two-term sums: all pairs of 256 corner products + random pairs
//     T05 16 x the same product (range limits)
//     T06 accumulator walk across every bit boundary 2^0 .. 2^19, wrap-around
//     T07 structured 16-term dot products, expected and got printed
//     T08 random 16-term dot products, idle gaps, garbage, back to back
//     T09 hold: long idle stretches inside and after a dot product
//     T10 upper bits [35:20] of ACC and [15:8] of A/B never touched
//     T11 reserved mode 11 in between INT8 work
//     T12 asynchronous reset in the middle of a dot product
//     T13 same 4-bit data: INT4 result = INT8 result
//
//   Plusargs: +SEED=<n>  +NRAND=<random dots>  +NPAIR=<random two-term sums>
//             +VERBOSE=1 (print every product)
// ============================================================================
module tb_pe_int8;

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
    localparam NT = 14;                          // tests T01..T13 (index 0 unused)
    localparam AW = 20;                          // INT8 accumulator width
    integer seed, seed0, nrand, npair, verbose;
    integer tcyc, cur_t, nprint;
    integer t_chk [0:NT-1];
    integer t_err [0:NT-1];
    integer g_chk, g_err;
    integer q_tot [0:4], q_err [0:4];            // T02 quadrants: ++ +- -+ -- zero
    integer cval  [0:15];                        // corner operand values
    integer ctab  [0:255];                       // T02 got values for corner x corner
    integer cidx  [0:255];                       // value+128 -> corner index, -1 if none
    reg     chk_en;

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
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

    // 8-bit operand pattern with chosen bits [15:8]
    function [15:0] op8;
        input integer v;                          // -128 .. 127
        input [15:0]  upper;
        op8 = (upper & 16'hFF00) | (v & 255);
    endfunction

    // random value -128 .. 127
    function integer r8;
        input integer dummy;
        r8 = ($unsigned($random(seed)) % 256) - 128;
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
    //   tag >= 0 : T02 product index (a+128)*256 + (b+128)
    //   mod = 1  : compare modulo 2^20 (walks longer than 16 terms)
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
                got = sext(acc_out, AW);
                bad = q_mod[q_head] ? ((acc_out[AW-1:0]) !== (e & 20'hFFFFF)) : (got !== e);
                t_chk[tt] = t_chk[tt] + 1;
                if (bad) begin
                    t_err[tt] = t_err[tt] + 1;
                    if (nprint < 12) begin
                        nprint = nprint + 1;
                        $display("[%0t] T%0d EXPECTED mismatch  got %0d  exp %0d", $time, tt, got, e);
                    end
                end
                if (tg >= 0) begin                        // T02: quadrants, corner table, verbose
                    ai = tg / 256 - 128;  bi = tg % 256 - 128;
                    qi = ((ai == 0) || (bi == 0)) ? 4 : ((ai < 0) ? 2 : 0) + ((bi < 0) ? 1 : 0);
                    q_tot[qi] = q_tot[qi] + 1;
                    if (bad) q_err[qi] = q_err[qi] + 1;
                    if ((cidx[ai + 128] >= 0) && (cidx[bi + 128] >= 0))
                        ctab[cidx[ai + 128]*16 + cidx[bi + 128]] = got;
                    if (verbose) $display("  A=%4d B=%4d expected %6d got %6d", ai, bi, e, got);
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

    task drain;
        begin
            idle;  idle;  idle;
        end
    endtask

    // ------------------------------------------------------------------
    // Walk helper: add one product (a x b) to the running sum
    // ------------------------------------------------------------------
    integer walk;

    task walk_step;
        input integer a, b;
        begin
            cyc(op8(a, 0), op8(b, 0), 1'b1, 1'b0);
            walk = walk + a * b;
            expect_acc(walk, 1, -1);
        end
    endtask

    // move the running sum to target: big steps, then q*127 + r (|q|, |r| <= 127)
    task walk_to;
        input integer target;
        integer d, q, r;
        begin
            d = target - walk;
            while (d >  16129) begin walk_step(-128, -128); d = target - walk; end   // +16384
            while (d < -16129) begin walk_step(-128,  127); d = target - walk; end   // -16256
            q = d / 127;
            if (q != 0) walk_step(q, 127);
            r = target - walk;
            if (r != 0) walk_step(r, 1);
        end
    endtask

    // ------------------------------------------------------------------
    // Drained dot product with printed expected and got (T01, T07, T11, T13)
    // ------------------------------------------------------------------
    integer da [0:15], db [0:15];
    integer last_got;

    task print_dot;
        input [8*30-1:0] name;
        input integer    len;
        integer k, e, got, n, w;
        begin
            n = opw(mode);  w = (mode == 2'b00) ? 12 : AW;
            e = 0;
            for (k = 0; k < len; k = k + 1) e = e + da[k] * db[k];
            for (k = 0; k < len; k = k + 1)
                cyc((($random(seed)) & ~opmask(mode)) | (da[k] & opmask(mode)),
                    (($random(seed)) & ~opmask(mode)) | (db[k] & opmask(mode)), 1'b1, (k == 0));
            idle;  idle;
            got = sext(acc_out, w);  last_got = got;
            t_chk[cur_t] = t_chk[cur_t] + 1;
            if (got !== e) t_err[cur_t] = t_err[cur_t] + 1;
            $display("  %s expected %8d   got %8d   %s", name, e, got, (got === e) ? "PASS" : "FAIL");
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    integer i, j, k, n, e, len, total_err, res4;
    integer pa, pb, qa, qb;
    reg [35:0] keep_acc;
    reg [15:0] keep_a, keep_b;
    reg [15:0] gpat [0:3];
    integer dl_a [0:19], dl_b [0:19];

    initial begin
        if (!$value$plusargs("SEED=%d", seed))       seed = 32'h4B1D0008;
        if (!$value$plusargs("NRAND=%d", nrand))     nrand = 5000;
        if (!$value$plusargs("NPAIR=%d", npair))     npair = 100000;
        if (!$value$plusargs("VERBOSE=%d", verbose)) verbose = 0;
        seed0 = seed;

        tcyc = 0;  cur_t = 0;  nprint = 0;  g_chk = 0;  g_err = 0;  chk_en = 1'b0;
        q_head = 0;  q_tail = 0;  q_cnt = 0;
        for (i = 0; i < NT; i = i + 1)  begin t_chk[i] = 0; t_err[i] = 0; end
        for (i = 0; i < 5; i = i + 1)   begin q_tot[i] = 0; q_err[i] = 0; end
        for (i = 0; i < 256; i = i + 1) ctab[i] = 0;
        gpat[0] = 16'h0000;  gpat[1] = 16'hFF00;  gpat[2] = 16'hAA00;  gpat[3] = 16'h5500;

        // corner operand values (sorted, used for the printed table and T04)
        cval[0]  = -128; cval[1]  = -127; cval[2]  = -100; cval[3]  = -64;
        cval[4]  = -16;  cval[5]  = -8;   cval[6]  = -2;   cval[7]  = -1;
        cval[8]  = 0;    cval[9]  = 1;    cval[10] = 2;    cval[11] = 15;
        cval[12] = 16;   cval[13] = 64;   cval[14] = 85;   cval[15] = 127;
        for (i = 0; i < 256; i = i + 1) cidx[i] = -1;
        for (i = 0; i < 16; i = i + 1)  cidx[cval[i] + 128] = i;

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
        $display("prelude INT16: ACC = %h, A = %h, B = %h (upper bits must survive INT8)", keep_acc, keep_a, keep_b);
        mode = 2'b01;                                    // INT8 from here on

        // ================= T01 directed products =================
        cur_t = 1;
        $display("");
        $display("T01 directed products (A x B)");
        dl_a[0]=-128; dl_b[0]=-128;  dl_a[1]=-128; dl_b[1]=127;   dl_a[2]=127;  dl_b[2]=-128;
        dl_a[3]=127;  dl_b[3]=127;   dl_a[4]=-1;   dl_b[4]=-1;    dl_a[5]=-128; dl_b[5]=1;
        dl_a[6]=-128; dl_b[6]=-1;    dl_a[7]=0;    dl_b[7]=-128;  dl_a[8]=15;   dl_b[8]=16;
        dl_a[9]=-16;  dl_b[9]=16;    dl_a[10]=85;  dl_b[10]=-86;  dl_a[11]=-86; dl_b[11]=-86;
        dl_a[12]=64;  dl_b[12]=-2;   dl_a[13]=-127;dl_b[13]=-127; dl_a[14]=100; dl_b[14]=-100;
        dl_a[15]=17;  dl_b[15]=-17;  dl_a[16]=-15; dl_b[16]=-15;  dl_a[17]=120; dl_b[17]=3;
        dl_a[18]=-65; dl_b[18]=63;   dl_a[19]=7;   dl_b[19]=-9;
        for (i = 0; i < 20; i = i + 1) begin
            da[0] = dl_a[i];  db[0] = dl_b[i];
            print_dot("product", 1);
            $display("        (A = %0d, B = %0d)", dl_a[i], dl_b[i]);
        end

        // ================= T02 all 65,536 products =================
        cur_t = 2;
        $display("");
        $display("T02 all 65,536 INT8 products (running)");
        for (pa = -128; pa < 128; pa = pa + 1)
            for (pb = -128; pb < 128; pb = pb + 1) begin
                cyc(op8(pa, $random(seed)), op8(pb, $random(seed)), 1'b1, 1'b1);
                expect_acc(pa * pb, 0, (pa + 128) * 256 + (pb + 128));
            end
        drain;
        $display("T02 corner table (got values, '!' = mismatch)");
        $write("   A\\B |");
        for (j = 0; j < 16; j = j + 1) $write("%7d", cval[j]);
        $display("");
        for (i = 0; i < 16; i = i + 1) begin
            $write("  %4d |", cval[i]);
            for (j = 0; j < 16; j = j + 1)
                $write("%6d%s", ctab[i*16 + j], (ctab[i*16 + j] == cval[i] * cval[j]) ? " " : "!");
            $display("");
        end

        // ================= T03 products with fixed garbage in [15:8] =================
        cur_t = 3;
        for (pa = -128; pa < 128; pa = pa + 1)
            for (pb = -128; pb < 128; pb = pb + 1) begin
                i = ((pa + pb) & 3);
                cyc(op8(pa, gpat[i]), op8(pb, ~gpat[i]), 1'b1, 1'b1);
                expect_acc(pa * pb, 0, -1);
            end
        drain;

        // ================= T04 two-term sums =================
        cur_t = 4;
        $display("T04 two-term sums: 65,536 corner pairs + %0d random pairs (running)", npair);
        for (i = 0; i < 256; i = i + 1)                  // every pair of corner products
            for (j = 0; j < 256; j = j + 1) begin
                pa = cval[i / 16];  pb = cval[i % 16];  qa = cval[j / 16];  qb = cval[j % 16];
                cyc(op8(pa, $random(seed)), op8(pb, $random(seed)), 1'b1, 1'b1);
                cyc(op8(qa, $random(seed)), op8(qb, $random(seed)), 1'b1, 1'b0);
                expect_acc(pa * pb + qa * qb, 0, -1);
            end
        for (i = 0; i < npair; i = i + 1) begin          // random pairs
            pa = r8(0);  pb = r8(0);  qa = r8(0);  qb = r8(0);
            cyc(op8(pa, $random(seed)), op8(pb, $random(seed)), 1'b1, 1'b1);
            cyc(op8(qa, $random(seed)), op8(qb, $random(seed)), 1'b1, 1'b0);
            expect_acc(pa * pb + qa * qb, 0, -1);
        end
        drain;

        // ================= T05 16 x the same product =================
        cur_t = 5;
        for (i = 0; i < 4096; i = i + 1) begin
            if (i < 256) begin pa = cval[i / 16];  pb = cval[i % 16]; end    // all corner pairs
            else         begin pa = r8(0);         pb = r8(0);        end
            for (k = 0; k < 16; k = k + 1)
                cyc(op8(pa, $random(seed)), op8(pb, $random(seed)), 1'b1, (k == 0));
            expect_acc(16 * pa * pb, 0, -1);
        end
        drain;

        // ================= T06 accumulator walk across every bit boundary =================
        cur_t = 6;
        walk = 0;
        cyc(op8(0, 0), op8(0, 0), 1'b1, 1'b1);  expect_acc(0, 1, -1);      // first: start at 0
        for (k = 0; k < 20; k = k + 1) begin
            walk_to((1 << k) - 40);                                         // up across +2^k
            for (j = 0; j < 80; j = j + 1) walk_step(1, 1);
            walk_to(-(1 << k) + 40);                                        // down across -2^k
            for (j = 0; j < 80; j = j + 1) walk_step(1, -1);
        end
        walk_to(0);
        for (j = 0; j < 300; j = j + 1) begin                              // big steps, many carries
            if (j % 3 == 2) walk_step(-128, 127);                           // -16256
            else            walk_step(-128, -128);                          // +16384
        end
        drain;

        // ================= T07 structured 16-term dot products =================
        cur_t = 7;
        $display("");
        $display("T07 structured 16-term dot products");
        for (k = 0; k < 16; k = k + 1) begin da[k] = 0;  db[k] = r8(0); end            print_dot("zero A                        ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = r8(0); db[k] = 0;  end            print_dot("zero B                        ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = (k == 11) ? 1 : 0; db[k] = r8(0); end     print_dot("identity (picks B[11])        ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 127;  db[k] = 127;  end           print_dot("all  127 x  127 (max positive)", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = -128; db[k] = -128; end           print_dot("all -128 x -128 (largest sum) ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = -128; db[k] = 127;  end           print_dot("all -128 x  127 (most negative", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 127;  db[k] = -128; end           print_dot("all  127 x -128               ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 1 + ($unsigned($random(seed)) % 127); db[k] = 1 + ($unsigned($random(seed)) % 127); end
                                                                                         print_dot("positive x positive           ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = -1 - ($unsigned($random(seed)) % 128); db[k] = -1 - ($unsigned($random(seed)) % 128); end
                                                                                         print_dot("negative x negative           ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 1 + ($unsigned($random(seed)) % 127); db[k] = -1 - ($unsigned($random(seed)) % 128); end
                                                                                         print_dot("positive x negative           ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = (k % 2) ? 127 : -128; db[k] = -128; end
                                                                                         print_dot("alternating sign, sum ~ 0     ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = (k % 2) ? 15 : -16; db[k] = (k % 2) ? -16 : 15; end
                                                                                         print_dot("nibble boundary 0x0F / 0xF0   ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = r8(0); db[k] = r8(0); end         print_dot("random                        ", 16);

        // ================= T08 random dot products =================
        cur_t = 8;
        for (i = 0; i < nrand; i = i + 1) begin
            len = 1 + ($unsigned($random(seed)) % 16);
            e = 0;
            for (k = 0; k < len; k = k + 1) begin
                pa = r8(0);  pb = r8(0);  e = e + pa * pb;
                if (($random(seed) & 3) == 0) idle;
                cyc(op8(pa, $random(seed)), op8(pb, $random(seed)), 1'b1, (k == 0));
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
                pa = r8(0);  pb = r8(0);  e = e + pa * pb;
                cyc(op8(pa, $random(seed)), op8(pb, $random(seed)), 1'b1, (k == 0));
                if (k == 7) for (j = 0; j < 30; j = j + 1) idle;        // stall in the middle
            end
            expect_acc(e, 0, -1);
            for (j = 0; j < 30; j = j + 1) idle;                        // result must stay
            t_chk[9] = t_chk[9] + 1;
            if (sext(acc_out, AW) !== e) t_err[9] = t_err[9] + 1;
        end
        drain;

        // ================= T10 upper bits never touched by INT8 =================
        cur_t = 10;
        t_chk[10] = t_chk[10] + 3;
        if (acc_out[35:20] !== keep_acc[35:20]) t_err[10] = t_err[10] + 1;
        if (a_out[15:8]    !== keep_a[15:8])    t_err[10] = t_err[10] + 1;
        if (b_out[15:8]    !== keep_b[15:8])    t_err[10] = t_err[10] + 1;
        $display("");
        $display("T10 upper state after all INT8 tests: ACC[35:20] %h (was %h), A[15:8] %h (was %h), B[15:8] %h (was %h)",
                 acc_out[35:20], keep_acc[35:20], a_out[15:8], keep_a[15:8], b_out[15:8], keep_b[15:8]);

        // ================= T11 reserved mode in between =================
        cur_t = 11;
        keep_acc = acc_out;
        mode = 2'b11;
        for (k = 0; k < 40; k = k + 1) cyc($random(seed), $random(seed), $random(seed), $random(seed));
        drain;
        t_chk[11] = t_chk[11] + 1;
        if (acc_out !== keep_acc) t_err[11] = t_err[11] + 1;
        mode = 2'b01;
        $display("");
        $display("T11 after 40 reserved-mode cycles (ACC unchanged: %s)", (acc_out === keep_acc) ? "yes" : "NO");
        for (k = 0; k < 16; k = k + 1) begin da[k] = r8(0); db[k] = r8(0); end
        print_dot("INT8 dot right after reserved ", 16);

        // ================= T12 reset in the middle of a dot product =================
        cur_t = 12;
        for (i = 0; i < 20; i = i + 1) begin
            n = 1 + ($unsigned($random(seed)) % 15);
            for (k = 0; k < n; k = k + 1) cyc(op8(r8(0), $random(seed)), op8(r8(0), $random(seed)), 1'b1, (k == 0));
            @(negedge clk);  tcyc = tcyc + 1;  golden_check;
            rst = 1'b1;  valid_in = 1'b0;  first_in = 1'b0;
            @(negedge clk);  tcyc = tcyc + 1;  golden_check;
            t_chk[12] = t_chk[12] + 1;
            if ({acc_out, a_out, b_out, valid_out, first_out} !== 70'd0) t_err[12] = t_err[12] + 1;
            rst = 1'b0;
            e = 0;
            for (k = 0; k < 16; k = k + 1) begin
                pa = r8(0);  pb = r8(0);  e = e + pa * pb;
                cyc(op8(pa, $random(seed)), op8(pb, $random(seed)), 1'b1, (k == 0));
            end
            expect_acc(e, 0, -1);
            drain;
        end

        // ================= T13 same 4-bit data in INT4 and INT8 =================
        cur_t = 13;
        $display("");
        $display("T13 same 4-bit data, INT4 vs INT8");
        for (i = 0; i < 10; i = i + 1) begin
            for (k = 0; k < 16; k = k + 1) begin
                da[k] = ($unsigned($random(seed)) % 16) - 8;  db[k] = ($unsigned($random(seed)) % 16) - 8;
            end
            mode = 2'b00;  print_dot("INT4                          ", 16);  res4 = last_got;
            mode = 2'b01;  print_dot("INT8 (same numbers)           ", 16);
            t_chk[13] = t_chk[13] + 1;
            if (res4 !== last_got) t_err[13] = t_err[13] + 1;
        end

        // ---------------- summary ----------------
        total_err = g_err;
        for (i = 1; i < NT; i = i + 1) total_err = total_err + t_err[i];
        $display("");
        $display("==================================================================");
        $display(" PE INT8 verification   seed = %0d", seed0);
        $display("==================================================================");
        $display(" Test                                        checks   errors");
        $display(" T01 directed products                     %8d %8d  %s", t_chk[1],  t_err[1],  (t_err[1]  == 0) ? "PASS" : "FAIL");
        $display(" T02 all 65,536 products                   %8d %8d  %s", t_chk[2],  t_err[2],  (t_err[2]  == 0) ? "PASS" : "FAIL");
        $display(" T03 all products, garbage in [15:8]       %8d %8d  %s", t_chk[3],  t_err[3],  (t_err[3]  == 0) ? "PASS" : "FAIL");
        $display(" T04 two-term sums                         %8d %8d  %s", t_chk[4],  t_err[4],  (t_err[4]  == 0) ? "PASS" : "FAIL");
        $display(" T05 16 x same product (range limits)      %8d %8d  %s", t_chk[5],  t_err[5],  (t_err[5]  == 0) ? "PASS" : "FAIL");
        $display(" T06 walk across bit boundaries 2^0..2^19  %8d %8d  %s", t_chk[6],  t_err[6],  (t_err[6]  == 0) ? "PASS" : "FAIL");
        $display(" T07 structured dot products               %8d %8d  %s", t_chk[7],  t_err[7],  (t_err[7]  == 0) ? "PASS" : "FAIL");
        $display(" T08 random dot products                   %8d %8d  %s", t_chk[8],  t_err[8],  (t_err[8]  == 0) ? "PASS" : "FAIL");
        $display(" T09 hold during long idle                 %8d %8d  %s", t_chk[9],  t_err[9],  (t_err[9]  == 0) ? "PASS" : "FAIL");
        $display(" T10 upper bits untouched                  %8d %8d  %s", t_chk[10], t_err[10], (t_err[10] == 0) ? "PASS" : "FAIL");
        $display(" T11 reserved mode in between              %8d %8d  %s", t_chk[11], t_err[11], (t_err[11] == 0) ? "PASS" : "FAIL");
        $display(" T12 async reset mid-dot                   %8d %8d  %s", t_chk[12], t_err[12], (t_err[12] == 0) ? "PASS" : "FAIL");
        $display(" T13 same data INT4 = INT8                 %8d %8d  %s", t_chk[13], t_err[13], (t_err[13] == 0) ? "PASS" : "FAIL");
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
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule

`timescale 1ns/1ps
// ============================================================================
// tb_pe_int16
//   Rigorous INT16 verification of processing_element (mode = 10).
//   Signed 16-bit operands: -32768 .. 32767, products up to 2^30,
//   36-bit accumulator (16-term sums -17179344896 .. 17179869184).
//   All expected values are 64-bit (they do not fit a 32-bit integer).
//
//   Checkers
//     - golden model: every cycle ALL outputs (acc_out, a_out, b_out,
//       valid_out, first_out) are compared; X on any output is an error
//     - expected value: every product / dot product / partial sum has a
//       computed expected value, compared when it appears on acc_out
//
//   Tests
//     T01 directed products, expected and got printed
//     T02 32 x 32 corner products (+ printed 16 x 16 table)
//     T03 full sweeps: every A against 4 fixed B values, every B against 4 A
//     T04 random products: uniform + corner-weighted (sign quadrants)
//     T05 every 4x4 multiplier P_ij exhaustively (A only nibble i, B only
//         nibble j), once with zero and once with random other nibbles
//     T06 two-term sums: all pairs of 256 corner products + random pairs
//     T07 16 x the same product (range limits, 2^34)
//     T08 accumulator walk across every bit boundary 2^0 .. 2^35, wrap-around
//     T09 structured 16-term dot products, expected and got printed
//     T10 random 16-term dot products, idle gaps, back to back
//     T11 hold: long idle stretches inside and after a dot product
//     T12 reserved mode 11 in between INT16 work
//     T13 asynchronous reset in the middle of a dot product
//     T14 same data: INT4 = INT8 = INT16, INT8 = INT16
//
//   Plusargs: +SEED=<n> +NRAND=<random dots> +NPROD=<random products>
//             +NPAIR=<random two-term sums> +SWEEP=0 (skip T03 sweeps)
// ============================================================================
module tb_pe_int16;

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
    localparam NT = 15;                          // tests T01..T14 (index 0 unused)
    integer seed, seed0, nrand, nprod, npair, sweep;
    integer tcyc, cur_t, nprint;
    integer t_chk [0:NT-1];
    integer t_err [0:NT-1];
    integer g_chk, g_err;
    integer q_tot [0:4], q_err [0:4];            // T04 quadrants: ++ +- -+ -- zero
    integer cval  [0:31];                        // corner operand values
    reg signed [63:0] ctab [0:255];              // T02 table (first 16 corners)
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

    // random signed 16-bit value
    function signed [63:0] r16;
        input integer dummy;
        r16 = sext($random(seed), 16);
    endfunction

    // corner-weighted random value: 1 in 4 is a corner value
    function signed [63:0] w16;
        input integer dummy;
        w16 = (($random(seed) & 3) == 0) ? cval[$unsigned($random(seed)) % 32] : sext($random(seed), 16);
    endfunction

    function [15:0] opmask;  input [1:0] m;
        opmask  = (m == 2'b00) ? 16'h000F : (m == 2'b01) ? 16'h00FF : (m == 2'b10) ? 16'hFFFF : 16'h0000;
    endfunction
    function [35:0] accmask; input [1:0] m;
        accmask = (m == 2'b00) ? 36'h000000FFF : (m == 2'b01) ? 36'h0000FFFFF :
                  (m == 2'b10) ? 36'hFFFFFFFFF : 36'h000000000;
    endfunction
    function integer opw;  input [1:0] m; opw  = (m == 2'b00) ? 4  : (m == 2'b01) ? 8  : 16; endfunction
    function integer accw; input [1:0] m; accw = (m == 2'b00) ? 12 : (m == 2'b01) ? 20 : 36; endfunction

    // sign quadrant of a product: 0 ++, 1 +-, 2 -+, 3 --, 4 zero operand
    function integer quad;
        input signed [63:0] a, b;
        quad = ((a == 0) || (b == 0)) ? 4 : ((a < 0) ? 2 : 0) + ((b < 0) ? 1 : 0);
    endfunction

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
    // Expected-value queue (64-bit values)
    //   tag 0..4   : T04 sign quadrant
    //   tag 100+i  : T02 table index i
    //   mod = 1    : compare modulo 2^36 (walks longer than 16 terms)
    // ------------------------------------------------------------------
    reg signed [63:0] q_exp [0:15];
    integer q_due [0:15], q_tst [0:15], q_tag [0:15], q_mod [0:15];
    integer q_head, q_tail, q_cnt;

    task expect_acc;                              // call right after the last cyc
        input signed [63:0] exp_v;
        input integer       mod, tag;
        begin
            q_exp[q_tail] = exp_v;  q_due[q_tail] = tcyc + 2;  q_tst[q_tail] = cur_t;
            q_tag[q_tail] = tag;    q_mod[q_tail] = mod;
            q_tail = (q_tail + 1) % 16;  q_cnt = q_cnt + 1;
        end
    endtask

    task pop_expected;
        reg signed [63:0] got, e;
        integer tg, tt, bad;
        begin
            while ((q_cnt > 0) && (q_due[q_head] == tcyc)) begin
                e   = q_exp[q_head];  tg = q_tag[q_head];  tt = q_tst[q_head];
                got = sext(acc_out, 36);
                bad = q_mod[q_head] ? (acc_out !== e[35:0]) : (got !== e);
                t_chk[tt] = t_chk[tt] + 1;
                if (bad) begin
                    t_err[tt] = t_err[tt] + 1;
                    if (nprint < 12) begin
                        nprint = nprint + 1;
                        $display("[%0t] T%0d EXPECTED mismatch  got %0d  exp %0d", $time, tt, got, e);
                    end
                end
                if ((tg >= 0) && (tg < 5)) begin
                    q_tot[tg] = q_tot[tg] + 1;
                    if (bad) q_err[tg] = q_err[tg] + 1;
                end
                if (tg >= 100) ctab[tg - 100] = got;
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

    // one product a x b as a single-term dot product (first = 1)
    task prod1;
        input signed [63:0] a, b;
        input integer       tag;
        begin
            cyc(a[15:0], b[15:0], 1'b1, 1'b1);
            expect_acc(a * b, 0, tag);
        end
    endtask

    // ------------------------------------------------------------------
    // Walk helpers: running sum, modulo 2^36
    // ------------------------------------------------------------------
    reg signed [63:0] walk;

    task walk_step;
        input signed [63:0] a, b;
        begin
            cyc(a[15:0], b[15:0], 1'b1, 1'b0);
            walk = walk + a * b;
            expect_acc(walk, 1, -1);
        end
    endtask

    // big steps of +2^30 / -(2^30 - 2^15), then q*32767 + r (|q|, |r| <= 32767)
    task walk_to;
        input signed [63:0] target;
        reg signed [63:0] d, q, r;
        begin
            d = target - walk;
            while (d >  64'sd1073676289) begin walk_step(-32768, -32768); d = target - walk; end
            while (d < -64'sd1073676289) begin walk_step(-32768,  32767); d = target - walk; end
            q = d / 32767;
            if (q != 0) walk_step(q, 32767);
            r = target - walk;
            if (r != 0) walk_step(r, 1);
        end
    endtask

    // ------------------------------------------------------------------
    // Drained dot product with printed expected and got
    // ------------------------------------------------------------------
    reg signed [63:0] da [0:15];
    reg signed [63:0] db [0:15];
    reg signed [63:0] last_got;

    task print_dot;
        input [8*30-1:0] name;
        input integer    len;
        reg signed [63:0] e, got;
        reg        [15:0] am, bm;
        integer k;
        begin
            e = 0;
            for (k = 0; k < len; k = k + 1) e = e + da[k] * db[k];
            for (k = 0; k < len; k = k + 1) begin
                am = da[k];  bm = db[k];
                cyc(($random(seed) & ~opmask(mode)) | (am & opmask(mode)),
                    ($random(seed) & ~opmask(mode)) | (bm & opmask(mode)), 1'b1, (k == 0));
            end
            idle;  idle;
            got = sext(acc_out, accw(mode));  last_got = got;
            t_chk[cur_t] = t_chk[cur_t] + 1;
            if (got !== e) t_err[cur_t] = t_err[cur_t] + 1;
            $display("  %s expected %13d   got %13d   %s", name, e, got, (got === e) ? "PASS" : "FAIL");
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    integer i, j, k, n, ni, nj, x, y, len, total_err;
    reg signed [63:0] pa, pb, qa, qb, e, res4, res8;
    reg        [15:0] oth;
    integer fixv [0:3];
    integer dl_a [0:19], dl_b [0:19];

    initial begin
        if (!$value$plusargs("SEED=%d", seed))   seed  = 32'h4B1D0010;
        if (!$value$plusargs("NRAND=%d", nrand)) nrand = 5000;
        if (!$value$plusargs("NPROD=%d", nprod)) nprod = 200000;
        if (!$value$plusargs("NPAIR=%d", npair)) npair = 100000;
        if (!$value$plusargs("SWEEP=%d", sweep)) sweep = 1;
        seed0 = seed;

        tcyc = 0;  cur_t = 0;  nprint = 0;  g_chk = 0;  g_err = 0;  chk_en = 1'b0;
        q_head = 0;  q_tail = 0;  q_cnt = 0;
        for (i = 0; i < NT; i = i + 1)  begin t_chk[i] = 0; t_err[i] = 0; end
        for (i = 0; i < 5; i = i + 1)   begin q_tot[i] = 0; q_err[i] = 0; end
        for (i = 0; i < 256; i = i + 1) ctab[i] = 0;

        // corner values: first 16 form the printed table
        cval[0]  = -32768; cval[1]  = -32767; cval[2]  = -16384; cval[3]  = -256;
        cval[4]  = -255;   cval[5]  = -16;    cval[6]  = -1;     cval[7]  = 0;
        cval[8]  = 1;      cval[9]  = 15;     cval[10] = 16;     cval[11] = 255;
        cval[12] = 256;    cval[13] = 16384;  cval[14] = 21845;  cval[15] = 32767;
        cval[16] = -21846; cval[17] = -2;     cval[18] = 2;      cval[19] = -4096;
        cval[20] = 4096;   cval[21] = 4095;   cval[22] = -4097;  cval[23] = 3855;
        cval[24] = -3856;  cval[25] = 32640;  cval[26] = -32640; cval[27] = 257;
        cval[28] = -257;   cval[29] = 8191;   cval[30] = -8192;  cval[31] = 12345;

        // ---- reset ----
        rst = 1'b1;  mode = 2'b10;  valid_in = 1'b0;  first_in = 1'b0;  a_in = 16'd0;  b_in = 16'd0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        chk_en = 1'b1;

        // ================= T01 directed products =================
        cur_t = 1;
        $display("");
        $display("T01 directed products (A x B)");
        dl_a[0]=-32768; dl_b[0]=-32768;  dl_a[1]=-32768; dl_b[1]=32767;   dl_a[2]=32767;  dl_b[2]=-32768;
        dl_a[3]=32767;  dl_b[3]=32767;   dl_a[4]=-1;     dl_b[4]=-1;      dl_a[5]=-32768; dl_b[5]=1;
        dl_a[6]=-32768; dl_b[6]=-1;      dl_a[7]=0;      dl_b[7]=-32768;  dl_a[8]=255;    dl_b[8]=256;
        dl_a[9]=-256;   dl_b[9]=256;     dl_a[10]=21845; dl_b[10]=-21846; dl_a[11]=-21846;dl_b[11]=-21846;
        dl_a[12]=16384; dl_b[12]=-2;     dl_a[13]=-32767;dl_b[13]=-32767; dl_a[14]=4095;  dl_b[14]=4096;
        dl_a[15]=-4097; dl_b[15]=4097;   dl_a[16]=15;    dl_b[16]=-4096;  dl_a[17]=12345; dl_b[17]=-6789;
        dl_a[18]=-255;  dl_b[18]=-255;   dl_a[19]=32640; dl_b[19]=-32640;
        for (i = 0; i < 20; i = i + 1) begin
            da[0] = dl_a[i];  db[0] = dl_b[i];
            print_dot("product", 1);
            $display("        (A = %0d, B = %0d)", dl_a[i], dl_b[i]);
        end

        // ================= T02 corner products =================
        cur_t = 2;
        for (i = 0; i < 32; i = i + 1)
            for (j = 0; j < 32; j = j + 1)
                prod1(cval[i], cval[j], ((i < 16) && (j < 16)) ? (100 + i*16 + j) : -1);
        drain;
        $display("");
        $display("T02 corner table (got values, '!' = mismatch)");
        $write("    A\\B |");
        for (j = 0; j < 16; j = j + 1) $write("%12d", cval[j]);
        $display("");
        for (i = 0; i < 16; i = i + 1) begin
            pa = cval[i];
            $write("  %6d |", cval[i]);
            for (j = 0; j < 16; j = j + 1) begin
                pb = cval[j];
                $write("%11d%s", ctab[i*16 + j], (ctab[i*16 + j] == pa * pb) ? " " : "!");
            end
            $display("");
        end

        // ================= T03 full operand sweeps =================
        cur_t = 3;
        if (sweep) begin
            fixv[0] = -32768;  fixv[1] = 32767;  fixv[2] = -1;  fixv[3] = 21845;
            $display("");
            $display("T03 full sweeps: every A x {-32768, 32767, -1, 21845}, every B x the same (running)");
            for (j = 0; j < 4; j = j + 1)
                for (i = 0; i < 65536; i = i + 1) begin
                    pa = sext(i, 16);  pb = fixv[j];
                    prod1(pa, pb, -1);                        // sweep A
                    prod1(pb, pa, -1);                        // sweep B
                end
            drain;
        end

        // ================= T04 random products =================
        cur_t = 4;
        $display("T04 %0d uniform + %0d corner-weighted random products (running)", nprod, nprod / 2);
        for (i = 0; i < nprod; i = i + 1) begin
            pa = r16(0);  pb = r16(0);  prod1(pa, pb, quad(pa, pb));
        end
        for (i = 0; i < nprod / 2; i = i + 1) begin
            pa = w16(0);  pb = w16(0);  prod1(pa, pb, quad(pa, pb));
        end
        drain;

        // ================= T05 every 4x4 multiplier exhaustively =================
        cur_t = 5;
        for (k = 0; k < 2; k = k + 1)                         // k = 1: random other nibbles
            for (ni = 0; ni < 4; ni = ni + 1)
                for (nj = 0; nj < 4; nj = nj + 1)
                    for (x = 0; x < 16; x = x + 1)
                        for (y = 0; y < 16; y = y + 1) begin
                            oth = k ? $random(seed) : 16'd0;
                            pa  = sext((oth & ~(16'hF << (4*ni))) | (x << (4*ni)), 16);
                            oth = k ? $random(seed) : 16'd0;
                            pb  = sext((oth & ~(16'hF << (4*nj))) | (y << (4*nj)), 16);
                            prod1(pa, pb, -1);
                        end
        drain;

        // ================= T06 two-term sums =================
        cur_t = 6;
        $display("T06 two-term sums: 65,536 corner pairs + %0d random pairs (running)", npair);
        for (i = 0; i < 256; i = i + 1)
            for (j = 0; j < 256; j = j + 1) begin
                pa = cval[i / 16];  pb = cval[i % 16];  qa = cval[j / 16];  qb = cval[j % 16];
                cyc(pa[15:0], pb[15:0], 1'b1, 1'b1);
                cyc(qa[15:0], qb[15:0], 1'b1, 1'b0);
                expect_acc(pa * pb + qa * qb, 0, -1);
            end
        for (i = 0; i < npair; i = i + 1) begin
            pa = w16(0);  pb = w16(0);  qa = w16(0);  qb = w16(0);
            cyc(pa[15:0], pb[15:0], 1'b1, 1'b1);
            cyc(qa[15:0], qb[15:0], 1'b1, 1'b0);
            expect_acc(pa * pb + qa * qb, 0, -1);
        end
        drain;

        // ================= T07 16 x the same product =================
        cur_t = 7;
        for (i = 0; i < 2024; i = i + 1) begin
            if (i < 1024) begin pa = cval[i / 32];  pb = cval[i % 32]; end    // all corner pairs
            else          begin pa = r16(0);        pb = r16(0);       end
            for (k = 0; k < 16; k = k + 1) cyc(pa[15:0], pb[15:0], 1'b1, (k == 0));
            expect_acc(16 * pa * pb, 0, -1);
        end
        drain;

        // ================= T08 accumulator walk across every bit boundary =================
        cur_t = 8;
        walk = 0;
        cyc(16'd0, 16'd0, 1'b1, 1'b1);  expect_acc(0, 1, -1);
        for (k = 0; k < 36; k = k + 1) begin
            walk_to((64'sd1 << k) - 40);                                    // up across +2^k
            for (j = 0; j < 80; j = j + 1) walk_step(1, 1);
            walk_to(-(64'sd1 << k) + 40);                                   // down across -2^k
            for (j = 0; j < 80; j = j + 1) walk_step(1, -1);
        end
        walk_to(0);
        for (j = 0; j < 300; j = j + 1) begin                              // big steps, long carries
            if (j % 3 == 2) walk_step(-32768, 32767);
            else            walk_step(-32768, -32768);
        end
        drain;

        // ================= T09 structured 16-term dot products =================
        cur_t = 9;
        $display("");
        $display("T09 structured 16-term dot products");
        for (k = 0; k < 16; k = k + 1) begin da[k] = 0;  db[k] = r16(0); end              print_dot("zero A                        ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = r16(0); db[k] = 0;  end              print_dot("zero B                        ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = (k == 13) ? 64'sd1 : 64'sd0; db[k] = r16(0); end       print_dot("identity (picks B[13])        ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 32767;  db[k] = 32767;  end          print_dot("all 32767 x 32767             ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = -32768; db[k] = -32768; end          print_dot("all -32768 x -32768 (2^34)    ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = -32768; db[k] = 32767;  end          print_dot("all -32768 x 32767 (most neg) ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 32767;  db[k] = -32768; end          print_dot("all 32767 x -32768            ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 1 + ($unsigned($random(seed)) % 32767); db[k] = 1 + ($unsigned($random(seed)) % 32767); end
                                                                                           print_dot("positive x positive           ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = -1 - ($unsigned($random(seed)) % 32768); db[k] = -1 - ($unsigned($random(seed)) % 32768); end
                                                                                           print_dot("negative x negative           ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = 1 + ($unsigned($random(seed)) % 32767); db[k] = -1 - ($unsigned($random(seed)) % 32768); end
                                                                                           print_dot("positive x negative           ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = (k % 2) ? 32767 : -32768; db[k] = -32768; end
                                                                                           print_dot("alternating sign, sum ~ 0     ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = (k % 2) ? 255 : -256; db[k] = (k % 2) ? -256 : 255; end
                                                                                           print_dot("byte boundary 0x00FF / 0xFF00 ", 16);
        for (k = 0; k < 16; k = k + 1) begin da[k] = r16(0); db[k] = r16(0); end          print_dot("random                        ", 16);

        // ================= T10 random dot products =================
        cur_t = 10;
        for (i = 0; i < nrand; i = i + 1) begin
            len = 1 + ($unsigned($random(seed)) % 16);
            e = 0;
            for (k = 0; k < len; k = k + 1) begin
                pa = w16(0);  pb = w16(0);  e = e + pa * pb;
                if (($random(seed) & 3) == 0) idle;
                cyc(pa[15:0], pb[15:0], 1'b1, (k == 0));
            end
            expect_acc(e, 0, -1);
            if ($random(seed) & 1) idle;
        end
        drain;

        // ================= T11 hold during long idle =================
        cur_t = 11;
        for (i = 0; i < 20; i = i + 1) begin
            e = 0;
            for (k = 0; k < 16; k = k + 1) begin
                pa = r16(0);  pb = r16(0);  e = e + pa * pb;
                cyc(pa[15:0], pb[15:0], 1'b1, (k == 0));
                if (k == 7) for (j = 0; j < 30; j = j + 1) idle;
            end
            expect_acc(e, 0, -1);
            for (j = 0; j < 30; j = j + 1) idle;
            t_chk[11] = t_chk[11] + 1;
            if (sext(acc_out, 36) !== e) t_err[11] = t_err[11] + 1;
        end
        drain;

        // ================= T12 reserved mode in between =================
        cur_t = 12;
        $display("");
        for (i = 0; i < 1; i = i + 1) begin
            pa = acc_out;                                     // keep the accumulator
            mode = 2'b11;
            for (k = 0; k < 40; k = k + 1) cyc($random(seed), $random(seed), $random(seed), $random(seed));
            drain;
            t_chk[12] = t_chk[12] + 1;
            if (acc_out !== pa[35:0]) t_err[12] = t_err[12] + 1;
            $display("T12 after 40 reserved-mode cycles (ACC unchanged: %s)", (acc_out === pa[35:0]) ? "yes" : "NO");
            mode = 2'b10;
            for (k = 0; k < 16; k = k + 1) begin da[k] = r16(0); db[k] = r16(0); end
            print_dot("INT16 dot right after reserved", 16);
        end

        // ================= T13 reset in the middle of a dot product =================
        cur_t = 13;
        for (i = 0; i < 20; i = i + 1) begin
            n = 1 + ($unsigned($random(seed)) % 15);
            for (k = 0; k < n; k = k + 1) cyc($random(seed), $random(seed), 1'b1, (k == 0));
            @(negedge clk);  tcyc = tcyc + 1;  golden_check;
            rst = 1'b1;  valid_in = 1'b0;  first_in = 1'b0;
            @(negedge clk);  tcyc = tcyc + 1;  golden_check;
            t_chk[13] = t_chk[13] + 1;
            if ({acc_out, a_out, b_out, valid_out, first_out} !== 70'd0) t_err[13] = t_err[13] + 1;
            rst = 1'b0;
            e = 0;
            for (k = 0; k < 16; k = k + 1) begin
                pa = r16(0);  pb = r16(0);  e = e + pa * pb;
                cyc(pa[15:0], pb[15:0], 1'b1, (k == 0));
            end
            expect_acc(e, 0, -1);
            drain;
        end

        // ================= T14 same data in several modes =================
        cur_t = 14;
        $display("");
        $display("T14 same data in several modes");
        for (i = 0; i < 10; i = i + 1) begin                  // 4-bit data: INT4 = INT8 = INT16
            for (k = 0; k < 16; k = k + 1) begin
                da[k] = ($unsigned($random(seed)) % 16) - 8;  db[k] = ($unsigned($random(seed)) % 16) - 8;
            end
            mode = 2'b00;  print_dot("4-bit data in INT4            ", 16);  res4 = last_got;
            mode = 2'b01;  print_dot("4-bit data in INT8            ", 16);  res8 = last_got;
            mode = 2'b10;  print_dot("4-bit data in INT16           ", 16);
            t_chk[14] = t_chk[14] + 1;
            if ((res4 !== res8) || (res8 !== last_got)) t_err[14] = t_err[14] + 1;
        end
        for (i = 0; i < 10; i = i + 1) begin                  // 8-bit data: INT8 = INT16
            for (k = 0; k < 16; k = k + 1) begin
                da[k] = ($unsigned($random(seed)) % 256) - 128;  db[k] = ($unsigned($random(seed)) % 256) - 128;
            end
            mode = 2'b01;  print_dot("8-bit data in INT8            ", 16);  res8 = last_got;
            mode = 2'b10;  print_dot("8-bit data in INT16           ", 16);
            t_chk[14] = t_chk[14] + 1;
            if (res8 !== last_got) t_err[14] = t_err[14] + 1;
        end

        // ---------------- summary ----------------
        total_err = g_err;
        for (i = 1; i < NT; i = i + 1) total_err = total_err + t_err[i];
        $display("");
        $display("==================================================================");
        $display(" PE INT16 verification   seed = %0d", seed0);
        $display("==================================================================");
        $display(" Test                                        checks   errors");
        $display(" T01 directed products                     %8d %8d  %s", t_chk[1],  t_err[1],  (t_err[1]  == 0) ? "PASS" : "FAIL");
        $display(" T02 32 x 32 corner products               %8d %8d  %s", t_chk[2],  t_err[2],  (t_err[2]  == 0) ? "PASS" : "FAIL");
        $display(" T03 full A / B sweeps                     %8d %8d  %s", t_chk[3],  t_err[3],  (t_err[3]  == 0) ? "PASS" : "FAIL");
        $display(" T04 random products                       %8d %8d  %s", t_chk[4],  t_err[4],  (t_err[4]  == 0) ? "PASS" : "FAIL");
        $display(" T05 each 4x4 multiplier exhaustive        %8d %8d  %s", t_chk[5],  t_err[5],  (t_err[5]  == 0) ? "PASS" : "FAIL");
        $display(" T06 two-term sums                         %8d %8d  %s", t_chk[6],  t_err[6],  (t_err[6]  == 0) ? "PASS" : "FAIL");
        $display(" T07 16 x same product (range limits)      %8d %8d  %s", t_chk[7],  t_err[7],  (t_err[7]  == 0) ? "PASS" : "FAIL");
        $display(" T08 walk across bit boundaries 2^0..2^35  %8d %8d  %s", t_chk[8],  t_err[8],  (t_err[8]  == 0) ? "PASS" : "FAIL");
        $display(" T09 structured dot products               %8d %8d  %s", t_chk[9],  t_err[9],  (t_err[9]  == 0) ? "PASS" : "FAIL");
        $display(" T10 random dot products                   %8d %8d  %s", t_chk[10], t_err[10], (t_err[10] == 0) ? "PASS" : "FAIL");
        $display(" T11 hold during long idle                 %8d %8d  %s", t_chk[11], t_err[11], (t_err[11] == 0) ? "PASS" : "FAIL");
        $display(" T12 reserved mode in between              %8d %8d  %s", t_chk[12], t_err[12], (t_err[12] == 0) ? "PASS" : "FAIL");
        $display(" T13 async reset mid-dot                   %8d %8d  %s", t_chk[13], t_err[13], (t_err[13] == 0) ? "PASS" : "FAIL");
        $display(" T14 same data INT4 = INT8 = INT16         %8d %8d  %s", t_chk[14], t_err[14], (t_err[14] == 0) ? "PASS" : "FAIL");
        $display("------------------------------------------------------------------");
        $display(" T04 sign quadrants         products   errors");
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
        #500_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule

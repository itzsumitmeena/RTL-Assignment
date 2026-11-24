`timescale 1ns/1ps
// ============================================================================
// tb_pe_rigorous
//   Rigorous self-checking testbench for processing_element.
//
//   Two independent checkers run at the same time:
//   1. Cycle-accurate golden model (behavioural, uses * and +).
//      Every clock cycle ALL outputs are compared: acc_out (all 36 bits,
//      including the bands that must hold), a_out, b_out, valid_out,
//      first_out. Any X on an output is an error.
//   2. Mathematical dot-product check: sum_k A_k*B_k computed from the
//      operand values, compared with acc_out after the dot product.
//
//   Test groups (per mode where it applies):
//     zero, identity, positive, negative, mixed, max positive,
//     max negative, max neg x max pos, random 1/2/3   (Section 13)
//     exhaustive products: all 256 INT4 pairs, all 65536 INT8 pairs,
//       INT16 corner cross-product + weighted random products
//     accumulation extremes (largest |sum| that must not overflow)
//     same data in INT4 -> INT8 -> INT16                (Section 14)
//     random stress: random mode, length 1..20, idle cycles, garbage in
//       unused bits, back-to-back dot products, mode switch mid-flight
//     reserved mode 11, asynchronous reset in the middle of a dot product
//
//   Plusargs: +SEED=<n>  +NDOT=<dots per category>  +NRAND16=<n>  +NSTRESS=<n>
// ============================================================================
module tb_pe_rigorous;

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
    // Test categories
    // ------------------------------------------------------------------
    localparam CAT_ZERO  = 0,  CAT_IDENT = 1,  CAT_POS   = 2,  CAT_NEG  = 3;
    localparam CAT_MIX   = 4,  CAT_MAXP  = 5,  CAT_MAXN  = 6,  CAT_MNP  = 7;
    localparam CAT_RND1  = 8,  CAT_RND2  = 9,  CAT_RND3  = 10, CAT_EXH  = 11;
    localparam CAT_EXTR  = 12, CAT_SAME  = 13, CAT_STRS  = 14, CAT_RSVD = 15;
    localparam CAT_RST   = 16, NCAT      = 17;

    // ------------------------------------------------------------------
    // Counters
    // ------------------------------------------------------------------
    integer seed, seed0, ndot, nrand16, nstress;
    integer ncheck, ndots, err_acc, err_fwd, err_x, err_sem, nprint;
    integer cur_cat;
    integer cat_err [0:NCAT-1][0:3];         // [category][mode, 3 = reserved]
    integer cat_tot [0:NCAT-1][0:3];
    integer vcnt    [0:2];                   // valid products per mode
    integer sgn_cov [0:11];                  // [mode*4 + {sign_a, sign_b}]
    integer minmin  [0:2];                   // (min neg) x (min neg) products seen
    reg signed [63:0] maxabs [0:2];          // largest |dot product| checked
    reg chk_en;

    // ------------------------------------------------------------------
    // Mode helpers
    // ------------------------------------------------------------------
    function integer opw;  input [1:0] m; opw  = (m == 2'b00) ? 4  : (m == 2'b01) ? 8  : 16; endfunction
    function integer accw; input [1:0] m; accw = (m == 2'b00) ? 12 : (m == 2'b01) ? 20 : 36; endfunction

    function [15:0] opmask;  input [1:0] m;
        opmask  = (m == 2'b00) ? 16'h000F : (m == 2'b01) ? 16'h00FF : (m == 2'b10) ? 16'hFFFF : 16'h0000;
    endfunction
    function [35:0] accmask; input [1:0] m;
        accmask = (m == 2'b00) ? 36'h000000FFF : (m == 2'b01) ? 36'h0000FFFFF :
                  (m == 2'b10) ? 36'hFFFFFFFFF : 36'h000000000;
    endfunction

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

    // ------------------------------------------------------------------
    // Golden model: next accumulator value (independent of the RTL)
    //   active W bits: (first ? 0 : ACC) + A*B  mod 2^W ; other bits hold
    // ------------------------------------------------------------------
    function [35:0] mac_next;
        input [35:0] acc;
        input [15:0] a, b;
        input        f;
        input [1:0]  m;
        reg signed [63:0] p;
        reg        [63:0] s;
        begin
            if (m == 2'b11)
                mac_next = acc;                          // reserved: no arithmetic
            else begin
                p = sext(a, opw(m)) * sext(b, opw(m));
                s = (f ? 64'd0 : {28'd0, acc}) + p;
                mac_next = (acc & ~accmask(m)) | (s[35:0] & accmask(m));
            end
        end
    endfunction

    // ---- golden registers, same clock / reset as the DUT ----
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

    // ------------------------------------------------------------------
    // Operand generators
    // ------------------------------------------------------------------
    // corner values of an n-bit signed operand
    function [15:0] corner;
        input integer idx;
        input integer n;
        reg [15:0] nm, maxp, minn;
        begin
            nm   = (n == 16) ? 16'hFFFF : ((16'd1 << n) - 16'd1);
            maxp = (16'd1 << (n-1)) - 16'd1;
            minn = (16'd1 << (n-1));
            case (idx)
                0: corner = 16'd0;              1: corner = 16'd1;
                2: corner = nm;                 3: corner = 16'd2;          // -1, 2
                4: corner = nm - 16'd1;         5: corner = maxp;           // -2, max
                6: corner = maxp - 16'd1;       7: corner = minn;           // max-1, min
                8: corner = minn + 16'd1;       9: corner = 16'h5555 & nm;  // min+1, 0101..
                10: corner = 16'hAAAA & nm;     default: corner = (16'd1 << (n-2));
            endcase
        end
    endfunction

    // kind: 0 zero, 2 positive (1..max), 3 negative, 4 any,
    //       5 max positive, 6 max negative, 8 corner-weighted random
    function [15:0] gen_val;
        input integer kind;
        input integer n;
        reg [15:0] nm, maxp, minn, r;
        begin
            nm   = (n == 16) ? 16'hFFFF : ((16'd1 << n) - 16'd1);
            maxp = (16'd1 << (n-1)) - 16'd1;
            minn = (16'd1 << (n-1));
            r    = $random(seed);
            case (kind)
                0: gen_val = 16'd0;
                2: gen_val = ($unsigned($random(seed)) % maxp) + 16'd1;
                3: gen_val = minn | (r & maxp);
                5: gen_val = maxp;
                6: gen_val = minn;
                8: gen_val = ((r & 3) == 0) ? corner($unsigned($random(seed)) % 12, n) : ($random(seed) & nm);
                default: gen_val = r & nm;
            endcase
        end
    endfunction

    // random garbage above the active width (must be ignored by the PE)
    function [15:0] with_garbage;
        input [15:0] val;
        input integer n;
        input integer g;
        reg   [15:0] nm;
        begin
            nm = (n == 16) ? 16'hFFFF : ((16'd1 << n) - 16'd1);
            with_garbage = (val & nm) | (g ? ($random(seed) & ~nm) : 16'd0);
        end
    endfunction

    // ------------------------------------------------------------------
    // Per-cycle checker: compares every DUT output with the golden model
    // ------------------------------------------------------------------
    task check_outputs;
        integer mi;
        begin
            mi = (mode == 2'b11) ? 3 : mode;
            ncheck = ncheck + 1;
            if ((^{acc_out, a_out, b_out, valid_out, first_out}) === 1'bx) begin
                err_x = err_x + 1;  cat_err[cur_cat][mi] = cat_err[cur_cat][mi] + 1;
                if (nprint < 10) begin
                    nprint = nprint + 1;
                    $display("[%0t] X on outputs  cat=%0d mode=%0d", $time, cur_cat, mode);
                end
            end else begin
                if (acc_out !== m_acc) begin
                    err_acc = err_acc + 1;  cat_err[cur_cat][mi] = cat_err[cur_cat][mi] + 1;
                    if (nprint < 10) begin
                        nprint = nprint + 1;
                        $display("[%0t] ACC mismatch cat=%0d mode=%0d  dut=%h  model=%h", $time, cur_cat, mode, acc_out, m_acc);
                    end
                end
                if ({a_out, b_out, valid_out, first_out} !== {m_a, m_b, m_v, m_f}) begin
                    err_fwd = err_fwd + 1;  cat_err[cur_cat][mi] = cat_err[cur_cat][mi] + 1;
                    if (nprint < 10) begin
                        nprint = nprint + 1;
                        $display("[%0t] FWD mismatch cat=%0d mode=%0d  a=%h/%h b=%h/%h v=%b/%b f=%b/%b", $time, cur_cat, mode,
                                 a_out, m_a, b_out, m_b, valid_out, m_v, first_out, m_f);
                    end
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // One clock cycle: check outputs, then drive new inputs (at negedge)
    // ------------------------------------------------------------------
    task cyc;
        input [15:0] a, b;
        input        v, f;
        integer n, mi;
        begin
            @(negedge clk);
            if (chk_en) check_outputs;
            a_in = a;  b_in = b;  valid_in = v;  first_in = f;

            // functional coverage of valid products
            if (v && (mode != 2'b11)) begin
                mi = mode;  n = opw(mode);
                vcnt[mi] = vcnt[mi] + 1;
                sgn_cov[mi*4 + {a[n-1], b[n-1]}] = sgn_cov[mi*4 + {a[n-1], b[n-1]}] + 1;
                if (((a & opmask(mode)) == (16'd1 << (n-1))) && ((b & opmask(mode)) == (16'd1 << (n-1))))
                    minmin[mi] = minmin[mi] + 1;
            end
        end
    endtask

    // idle cycle: random data and random first, valid = 0
    task idle;
        begin
            cyc($random(seed), $random(seed), 1'b0, $random(seed));
        end
    endtask

    // ------------------------------------------------------------------
    // Dot product of va/vb[0..len-1] with the mathematical check
    // ------------------------------------------------------------------
    reg [15:0] va [0:63];
    reg [15:0] vb [0:63];
    reg signed [63:0] last_got;

    task run_dot;
        input integer len, gaps, garb;
        reg signed [63:0] exp_v, got_v, mag;
        reg        [35:0] mw;
        integer k, n, w, mi;
        begin
            n = opw(mode);  w = accw(mode);  mi = mode;  mw = accmask(mode);

            // mathematical reference
            exp_v = 0;
            for (k = 0; k < len; k = k + 1)
                exp_v = exp_v + sext(va[k], n) * sext(vb[k], n);

            // drive, optional idle cycles and garbage
            for (k = 0; k < len; k = k + 1) begin
                if (gaps && (($random(seed) & 3) == 0)) idle;
                cyc(with_garbage(va[k], n, garb), with_garbage(vb[k], n, garb), 1'b1, (k == 0));
            end
            idle;  idle;                                  // register, then accumulate

            // exact for <= 16 terms (no overflow allowed), modulo 2^W beyond
            got_v = sext(acc_out, w);
            ndots = ndots + 1;  cat_tot[cur_cat][mi] = cat_tot[cur_cat][mi] + 1;
            if ((len <= 16) ? (got_v !== exp_v) : ((acc_out & mw) !== (exp_v[35:0] & mw))) begin
                err_sem = err_sem + 1;  cat_err[cur_cat][mi] = cat_err[cur_cat][mi] + 1;
                if (nprint < 10) begin
                    nprint = nprint + 1;
                    $display("[%0t] DOT mismatch cat=%0d mode=%0d len=%0d  got=%0d exp=%0d", $time, cur_cat, mode, len, got_v, exp_v);
                end
            end
            last_got = got_v;
            mag = (exp_v < 0) ? -exp_v : exp_v;
            if ((len <= 16) && (mag > maxabs[mi])) maxabs[mi] = mag;
        end
    endtask

    // fill 16 terms with generator kinds ka (A) and kb (B)
    task fill;
        input integer ka, kb;
        integer k;
        begin
            for (k = 0; k < 16; k = k + 1) begin
                va[k] = gen_val(ka, opw(mode));
                vb[k] = gen_val(kb, opw(mode));
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Section 13 categories, current mode
    // ------------------------------------------------------------------
    task run_category;
        input integer cat;
        integer d, k, len;
        begin
            cur_cat = cat;
            for (d = 0; d < ((cat == CAT_IDENT) ? 16 : ndot); d = d + 1) begin
                len = 16;
                case (cat)
                    CAT_ZERO:  if (d % 2) fill(0, 4); else fill(4, 0);
                    CAT_IDENT: begin
                                   fill(4, 4);
                                   for (k = 0; k < 16; k = k + 1) va[k] = (k == d) ? 16'd1 : 16'd0;
                               end
                    CAT_POS:   fill(2, 2);
                    CAT_NEG:   fill(3, 3);
                    CAT_MIX:   begin
                                   fill(2, 3);
                                   for (k = 1; k < 16; k = k + 2) begin
                                       va[k] = gen_val(3, opw(mode));  vb[k] = gen_val(2, opw(mode));
                                   end
                               end
                    CAT_MAXP:  fill(5, 5);
                    CAT_MAXN:  fill(6, 6);
                    CAT_MNP:   fill(6, 5);
                    CAT_RND1:  fill(4, 4);
                    CAT_RND2:  fill(8, 8);
                    default:   begin                                   // CAT_RND3
                                   fill(4, 4);
                                   len = 1 + ($unsigned($random(seed)) % 16);
                               end
                endcase
                run_dot(len, 1, 1);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Exhaustive / corner products: one product per cycle (first = 1)
    // ------------------------------------------------------------------
    task run_exhaustive;
        integer i, j, n;
        begin
            cur_cat = CAT_EXH;  n = opw(mode);
            if (n <= 8) begin
                for (i = 0; i < (1 << n); i = i + 1)
                    for (j = 0; j < (1 << n); j = j + 1)
                        cyc(with_garbage(i, n, 1), with_garbage(j, n, 1), 1'b1, 1'b1);
            end else begin
                for (i = 0; i < 12; i = i + 1)
                    for (j = 0; j < 12; j = j + 1)
                        cyc(corner(i, 16), corner(j, 16), 1'b1, 1'b1);
                for (i = 0; i < nrand16; i = i + 1)
                    cyc(gen_val(8, 16), gen_val(8, 16), 1'b1, 1'b1);
            end
            idle;  idle;
            cat_tot[CAT_EXH][mode] = cat_tot[CAT_EXH][mode] + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // Accumulation extremes: largest |sum| of 16 terms (exact check)
    // ------------------------------------------------------------------
    task run_extremes;
        integer p, k, n;
        reg [15:0] maxp, minn;
        begin
            cur_cat = CAT_EXTR;  n = opw(mode);
            maxp = (16'd1 << (n-1)) - 16'd1;  minn = (16'd1 << (n-1));
            for (p = 0; p < 5; p = p + 1) begin
                for (k = 0; k < 16; k = k + 1) begin
                    case (p)
                        0: begin va[k] = minn; vb[k] = minn; end            // most positive
                        1: begin va[k] = maxp; vb[k] = maxp; end
                        2: begin va[k] = minn; vb[k] = maxp; end            // most negative
                        3: begin va[k] = maxp; vb[k] = minn; end
                        default: begin va[k] = minn; vb[k] = (k % 2) ? maxp : minn; end
                    endcase
                end
                run_dot(16, 0, 1);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Section 14: same numbers in INT4 -> INT8 -> INT16
    // ------------------------------------------------------------------
    reg [3:0]         a4  [0:15];                 // shared 4-bit test data
    reg [3:0]         b4  [0:15];
    reg signed [63:0] res [0:2];                  // result per mode

    task run_same_data;
        integer d, k, md;
        begin
            cur_cat = CAT_SAME;
            for (d = 0; d < ndot; d = d + 1) begin
                for (k = 0; k < 16; k = k + 1) begin a4[k] = $random(seed); b4[k] = $random(seed); end
                for (md = 0; md < 3; md = md + 1) begin
                    mode = md;
                    for (k = 0; k < 16; k = k + 1) begin
                        va[k] = sext({60'd0, a4[k]}, 4);
                        vb[k] = sext({60'd0, b4[k]}, 4);
                    end
                    run_dot(16, 1, 1);
                    res[md] = last_got;
                end
                if ((res[0] !== res[1]) || (res[1] !== res[2])) begin
                    err_sem = err_sem + 1;  cat_err[CAT_SAME][0] = cat_err[CAT_SAME][0] + 1;
                    if (nprint < 10) begin
                        nprint = nprint + 1;
                        $display("[%0t] SAME-DATA mismatch  %0d %0d %0d", $time, res[0], res[1], res[2]);
                    end
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Random stress (golden model checks every cycle)
    // ------------------------------------------------------------------
    task run_stress;
        integer d, k, len, n, drain, midsw;
        begin
            cur_cat = CAT_STRS;
            for (d = 0; d < nstress; d = d + 1) begin
                mode  = (($unsigned($random(seed)) % 16) == 0) ? 2'b11 : ($unsigned($random(seed)) % 3);
                len   = 1 + ($unsigned($random(seed)) % 20);
                drain = $random(seed) & 1;
                midsw = (($unsigned($random(seed)) % 8) == 0);
                for (k = 0; k < len; k = k + 1) begin
                    n = opw(mode);
                    if (($random(seed) & 3) == 0) idle;
                    cyc(with_garbage(gen_val(8, n), n, 1), with_garbage(gen_val(8, n), n, 1), 1'b1, (k == 0));
                    if (midsw && (k == len / 2)) mode = $unsigned($random(seed)) % 3;
                end
                if (drain) begin idle; idle; end
                cat_tot[CAT_STRS][0] = cat_tot[CAT_STRS][0] + 1;
            end
            idle;  idle;
        end
    endtask

    // ------------------------------------------------------------------
    // Reserved mode 11: valid data must change nothing but the tags
    // ------------------------------------------------------------------
    task run_reserved;
        integer k;
        begin
            cur_cat = CAT_RSVD;
            mode = 2'b11;
            for (k = 0; k < 40; k = k + 1)
                cyc($random(seed), $random(seed), $random(seed), $random(seed));
            idle;  idle;
            mode = 2'b10;                                 // normal operation afterwards
            fill(4, 4);  run_dot(16, 1, 1);
            cat_tot[CAT_RSVD][3] = cat_tot[CAT_RSVD][3] + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // Asynchronous reset in the middle of a dot product
    // ------------------------------------------------------------------
    task run_reset;
        integer t, k, stop, n;
        begin
            cur_cat = CAT_RST;
            for (t = 0; t < 20; t = t + 1) begin
                mode = $unsigned($random(seed)) % 3;  n = opw(mode);
                stop = 1 + ($unsigned($random(seed)) % 15);
                for (k = 0; k < stop; k = k + 1)
                    cyc(gen_val(8, n), gen_val(8, n), 1'b1, (k == 0));
                @(negedge clk);  check_outputs;           // reset pulse of one cycle
                rst = 1'b1;  valid_in = 1'b0;  first_in = 1'b0;
                @(negedge clk);  check_outputs;
                rst = 1'b0;
                fill(4, 4);  run_dot(16, 1, 1);           // must work right after reset
                cat_tot[CAT_RST][3] = cat_tot[CAT_RST][3] + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Report helpers
    // ------------------------------------------------------------------
    function [8*24-1:0] cat_name;
        input integer c;
        case (c)
            CAT_ZERO:  cat_name = "Zero matrix             ";
            CAT_IDENT: cat_name = "Identity matrix         ";
            CAT_POS:   cat_name = "Positive operands       ";
            CAT_NEG:   cat_name = "Negative operands       ";
            CAT_MIX:   cat_name = "Mixed signs             ";
            CAT_MAXP:  cat_name = "Maximum positive        ";
            CAT_MAXN:  cat_name = "Maximum negative        ";
            CAT_MNP:   cat_name = "Max neg x max pos       ";
            CAT_RND1:  cat_name = "Random test 1 (uniform) ";
            CAT_RND2:  cat_name = "Random test 2 (corners) ";
            CAT_RND3:  cat_name = "Random test 3 (length)  ";
            CAT_EXH:   cat_name = "Exhaustive / corner prod";
            CAT_EXTR:  cat_name = "Accumulation extremes   ";
            CAT_SAME:  cat_name = "Same data, 3 modes      ";
            CAT_STRS:  cat_name = "Random stress           ";
            CAT_RSVD:  cat_name = "Reserved mode 11        ";
            default:   cat_name = "Async reset mid-dot     ";
        endcase
    endfunction

    function [8*4-1:0] st;
        input integer e, t;
        st = (t == 0) ? "  - " : (e == 0) ? "PASS" : "FAIL";
    endfunction

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    integer c, md, i, total_err;

    initial begin
        if (!$value$plusargs("SEED=%d", seed))       seed = 32'h0C0FFEE1;
        if (!$value$plusargs("NDOT=%d", ndot))       ndot = 25;
        if (!$value$plusargs("NRAND16=%d", nrand16)) nrand16 = 20000;
        if (!$value$plusargs("NSTRESS=%d", nstress)) nstress = 2000;
        seed0 = seed;

        ncheck = 0;  ndots = 0;  err_acc = 0;  err_fwd = 0;  err_x = 0;  err_sem = 0;  nprint = 0;
        cur_cat = CAT_ZERO;  chk_en = 1'b0;
        for (c = 0; c < NCAT; c = c + 1)
            for (md = 0; md < 4; md = md + 1) begin cat_err[c][md] = 0; cat_tot[c][md] = 0; end
        for (md = 0; md < 3; md = md + 1) begin vcnt[md] = 0; minmin[md] = 0; maxabs[md] = 0; end
        for (i = 0; i < 12; i = i + 1) sgn_cov[i] = 0;

        // ---- reset ----
        rst = 1'b1;  mode = 2'b10;  valid_in = 1'b0;  first_in = 1'b0;  a_in = 16'd0;  b_in = 16'd0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        chk_en = 1'b1;                                    // golden model checks from here on

        // ---- INT16 first, so INT8 / INT4 run on stale upper bits ----
        for (md = 2; md >= 0; md = md - 1) begin
            mode = md;
            $display("[%0t] mode %0d: categories", $time, md);
            for (c = CAT_ZERO; c <= CAT_RND3; c = c + 1) run_category(c);
            $display("[%0t] mode %0d: exhaustive / corner products", $time, md);
            run_exhaustive;
            run_extremes;
        end

        $display("[%0t] same data INT4 -> INT8 -> INT16", $time);
        run_same_data;
        $display("[%0t] random stress (%0d dot products)", $time, nstress);
        run_stress;
        $display("[%0t] reserved mode and asynchronous reset", $time);
        run_reserved;
        run_reset;

        // ---------------- summary ----------------
        total_err = err_acc + err_fwd + err_x + err_sem;
        $display("");
        $display("====================================================================");
        $display(" PE rigorous verification   seed = %0d", seed0);
        $display("====================================================================");
        $display(" Test                     | INT4         | INT8         | INT16");
        $display("--------------------------------------------------------------------");
        for (c = CAT_ZERO; c <= CAT_EXTR; c = c + 1)
            $display(" %s | %s %7d | %s %7d | %s %7d", cat_name(c),
                     st(cat_err[c][0], cat_tot[c][0]), cat_tot[c][0],
                     st(cat_err[c][1], cat_tot[c][1]), cat_tot[c][1],
                     st(cat_err[c][2], cat_tot[c][2]), cat_tot[c][2]);
        $display("--------------------------------------------------------------------");
        $display(" %s | %s  (%0d dot products per mode)", cat_name(CAT_SAME),
                 st(cat_err[CAT_SAME][0] + cat_err[CAT_SAME][1] + cat_err[CAT_SAME][2], cat_tot[CAT_SAME][0]), cat_tot[CAT_SAME][0]);
        $display(" %s | %s  (%0d dot products)", cat_name(CAT_STRS),
                 st(cat_err[CAT_STRS][0] + cat_err[CAT_STRS][1] + cat_err[CAT_STRS][2] + cat_err[CAT_STRS][3], cat_tot[CAT_STRS][0]),
                 cat_tot[CAT_STRS][0]);
        $display(" %s | %s", cat_name(CAT_RSVD),
                 st(cat_err[CAT_RSVD][0] + cat_err[CAT_RSVD][1] + cat_err[CAT_RSVD][2] + cat_err[CAT_RSVD][3], cat_tot[CAT_RSVD][3]));
        $display(" %s | %s  (%0d resets)", cat_name(CAT_RST),
                 st(cat_err[CAT_RST][0] + cat_err[CAT_RST][1] + cat_err[CAT_RST][2] + cat_err[CAT_RST][3], cat_tot[CAT_RST][3]),
                 cat_tot[CAT_RST][3]);
        $display("--------------------------------------------------------------------");
        $display(" Coverage                 |        INT4  |        INT8  |       INT16");
        $display(" valid products           | %12d | %12d | %12d", vcnt[0], vcnt[1], vcnt[2]);
        $display(" (+)x(+) products         | %12d | %12d | %12d", sgn_cov[0], sgn_cov[4], sgn_cov[8]);
        $display(" (+)x(-) products         | %12d | %12d | %12d", sgn_cov[1], sgn_cov[5], sgn_cov[9]);
        $display(" (-)x(+) products         | %12d | %12d | %12d", sgn_cov[2], sgn_cov[6], sgn_cov[10]);
        $display(" (-)x(-) products         | %12d | %12d | %12d", sgn_cov[3], sgn_cov[7], sgn_cov[11]);
        $display(" min x min products       | %12d | %12d | %12d", minmin[0], minmin[1], minmin[2]);
        $display(" largest |dot product|    | %12d | %12d | %12d", maxabs[0], maxabs[1], maxabs[2]);
        $display("--------------------------------------------------------------------");
        $display(" cycles checked against golden model : %0d", ncheck);
        $display(" dot products checked mathematically : %0d", ndots);
        $display(" errors: acc %0d, forwarding %0d, X %0d, dot/same-data %0d", err_acc, err_fwd, err_x, err_sem);
        $display(" RESULT : %s", (total_err == 0) ? "PASS" : "FAIL");
        $display("====================================================================");
        $finish;
    end

    // ------------------------------------------------------------------
    // Watchdog
    // ------------------------------------------------------------------
    initial begin
        #50_000_000;
        $display("TIMEOUT: simulation did not finish");
        $finish;
    end
endmodule

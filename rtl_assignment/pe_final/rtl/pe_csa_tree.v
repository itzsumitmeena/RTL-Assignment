// ============================================================================
// pe_csa_tree
//   Reduces the 20 rows of one MAC operation to 2 vectors (sum, carry):
//     16 nibble products P_ij << 4(i+j)
//      3 signed-correction rows (row_a, row_b, row_k)
//      1 accumulator value (acc_in)
//   18 x pe_csa36, 6 levels after the products arrive.
//
//   Rows are grouped by precision so that a reduced mode switches as few
//   compressors as possible:
//     H : 12 INT16-only products        M : P01 P10 P11 (INT8)
//     E : acc, row_a, row_b, row_k      L : P00 + reduced E (all modes)
//   E is reduced in parallel with the 4x4 multipliers (early rows), and
//   the low group joins the tree only at level 2.
//   Active compressors:  INT4  : e1 e2 l2 l3 b4 c5 d6           (7 of 18)
//                        INT8  : INT4 set + m1 x2 x3 a4          (11 of 18)
//                        INT16 : all 18
// ============================================================================
module pe_csa_tree (
    input  wire [127:0] pp,
    input  wire [35:0]  row_a,
    input  wire [35:0]  row_b,
    input  wire [35:0]  row_k,
    input  wire [35:0]  acc_in,
    input  wire         en_mid,
    input  wire         en_hi,
    output wire [35:0]  vs,
    output wire [35:0]  vc
);
    // ------------------------------------------------------------------
    // 1. Place every 8-bit product at bit 4(i+j) of a 36-bit row
    //    pv[36*(4i+j) +: 36] = P_ij << 4(i+j)
    // ------------------------------------------------------------------
    wire [575:0] pv;

    genvar i, j;
    generate
        for (i = 0; i < 4; i = i + 1) begin : PROW
            for (j = 0; j < 4; j = j + 1) begin : PCOL
                assign pv[36*(4*i+j) +: 36] = {28'b0, pp[8*(4*i+j) +: 8]} << (4*(i+j));
            end
        end
    endgenerate

    wire [35:0] p00 = pv[36*0  +: 36], p01 = pv[36*1  +: 36], p02 = pv[36*2  +: 36], p03 = pv[36*3  +: 36];
    wire [35:0] p10 = pv[36*4  +: 36], p11 = pv[36*5  +: 36], p12 = pv[36*6  +: 36], p13 = pv[36*7  +: 36];
    wire [35:0] p20 = pv[36*8  +: 36], p21 = pv[36*9  +: 36], p22 = pv[36*10 +: 36], p23 = pv[36*11 +: 36];
    wire [35:0] p30 = pv[36*12 +: 36], p31 = pv[36*13 +: 36], p32 = pv[36*14 +: 36], p33 = pv[36*15 +: 36];

    // ------------------------------------------------------------------
    // 2. Early group E: 4 rows -> 2 (runs while the products are computed)
    // ------------------------------------------------------------------
    wire [35:0] e1_s, e1_c, e2_s, e2_c;

    pe_csa36 u_e1 (.x(acc_in), .y(row_a), .z(row_b), .en_mid(en_mid), .en_hi(en_hi), .s(e1_s), .c(e1_c));
    pe_csa36 u_e2 (.x(e1_s),   .y(e1_c),  .z(row_k), .en_mid(en_mid), .en_hi(en_hi), .s(e2_s), .c(e2_c));

    // ------------------------------------------------------------------
    // 3. Level 1: H (12 -> 8) and M (3 -> 2)
    // ------------------------------------------------------------------
    wire [35:0] h1a_s, h1a_c, h1b_s, h1b_c, h1c_s, h1c_c, h1d_s, h1d_c, m1_s, m1_c;

    pe_csa36 u_h1a (.x(p02), .y(p03), .z(p12), .en_mid(en_mid), .en_hi(en_hi), .s(h1a_s), .c(h1a_c));
    pe_csa36 u_h1b (.x(p13), .y(p20), .z(p21), .en_mid(en_mid), .en_hi(en_hi), .s(h1b_s), .c(h1b_c));
    pe_csa36 u_h1c (.x(p22), .y(p23), .z(p30), .en_mid(en_mid), .en_hi(en_hi), .s(h1c_s), .c(h1c_c));
    pe_csa36 u_h1d (.x(p31), .y(p32), .z(p33), .en_mid(en_mid), .en_hi(en_hi), .s(h1d_s), .c(h1d_c));
    pe_csa36 u_m1  (.x(p01), .y(p10), .z(p11), .en_mid(en_mid), .en_hi(en_hi), .s(m1_s),  .c(m1_c));

    // ------------------------------------------------------------------
    // 4. Level 2: 13 rows -> 9   (low group L enters here, m1_c waits)
    // ------------------------------------------------------------------
    wire [35:0] h2a_s, h2a_c, h2b_s, h2b_c, x2_s, x2_c, l2_s, l2_c;

    pe_csa36 u_h2a (.x(h1a_s), .y(h1a_c), .z(h1b_s), .en_mid(en_mid), .en_hi(en_hi), .s(h2a_s), .c(h2a_c));
    pe_csa36 u_h2b (.x(h1b_c), .y(h1c_s), .z(h1c_c), .en_mid(en_mid), .en_hi(en_hi), .s(h2b_s), .c(h2b_c));
    pe_csa36 u_x2  (.x(h1d_s), .y(h1d_c), .z(m1_s),  .en_mid(en_mid), .en_hi(en_hi), .s(x2_s),  .c(x2_c));
    pe_csa36 u_l2  (.x(p00),   .y(e2_s),  .z(e2_c),  .en_mid(en_mid), .en_hi(en_hi), .s(l2_s),  .c(l2_c));

    // ------------------------------------------------------------------
    // 5. Level 3: 9 rows -> 6
    // ------------------------------------------------------------------
    wire [35:0] h3_s, h3_c, x3_s, x3_c, l3_s, l3_c;

    pe_csa36 u_h3 (.x(h2a_s), .y(h2a_c), .z(h2b_s), .en_mid(en_mid), .en_hi(en_hi), .s(h3_s), .c(h3_c));
    pe_csa36 u_x3 (.x(h2b_c), .y(x2_s),  .z(x2_c),  .en_mid(en_mid), .en_hi(en_hi), .s(x3_s), .c(x3_c));
    pe_csa36 u_l3 (.x(l2_s),  .y(l2_c),  .z(m1_c),  .en_mid(en_mid), .en_hi(en_hi), .s(l3_s), .c(l3_c));

    // ------------------------------------------------------------------
    // 6. Levels 4-6: 6 -> 4 -> 3 -> 2
    // ------------------------------------------------------------------
    wire [35:0] a4_s, a4_c, b4_s, b4_c, c5_s, c5_c;

    pe_csa36 u_a4 (.x(h3_s), .y(h3_c), .z(x3_s), .en_mid(en_mid), .en_hi(en_hi), .s(a4_s), .c(a4_c));
    pe_csa36 u_b4 (.x(x3_c), .y(l3_s), .z(l3_c), .en_mid(en_mid), .en_hi(en_hi), .s(b4_s), .c(b4_c));
    pe_csa36 u_c5 (.x(a4_s), .y(a4_c), .z(b4_s), .en_mid(en_mid), .en_hi(en_hi), .s(c5_s), .c(c5_c));
    pe_csa36 u_d6 (.x(c5_s), .y(c5_c), .z(b4_c), .en_mid(en_mid), .en_hi(en_hi), .s(vs),   .c(vc));
endmodule

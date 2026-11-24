// ============================================================================
// pe_add36
//   The single carry-propagate adder of the PE:  s = a + b  (mod 2^36).
//   Split into the three accumulator bands, each with its own Brent-Kung
//   prefix network; the bands are joined by two band carries:
//     band 0 : bits [11:0]   12-bit prefix, carry-in 0
//     band 1 : bits [19:12]   8-bit prefix, carry-in c12 = G0 & en_mid
//     band 2 : bits [35:20]  16-bit prefix, carry-in c20 = G1|P1&c12 & en_hi
//   The en_mid / en_hi terms are the carry kill: in INT4 / INT8 no carry
//   enters a disabled band, and its inputs are zero, so the band is idle.
// ============================================================================
module pe_add36 (
    input  wire [35:0] a,
    input  wire [35:0] b,
    input  wire        en_mid,
    input  wire        en_hi,
    output wire [35:0] s
);
    // ---- bit propagate / generate ----
    wire [35:0] p = a ^ b;
    wire [35:0] g = a & b;

    // ---- band prefix networks (group [i:band start]) ----
    wire [11:0] G0;                     // band 0 propagate not needed (carry-in 0)
    wire [7:0]  G1, P1;
    wire [15:0] G2, P2;

    pe_bk_prefix #(.N(12), .L(4)) u_band0 (.g(g[11:0]),  .p(p[11:0]),  .G(G0), .P());
    pe_bk_prefix #(.N(8),  .L(3)) u_band1 (.g(g[19:12]), .p(p[19:12]), .G(G1), .P(P1));
    pe_bk_prefix #(.N(16), .L(4)) u_band2 (.g(g[35:20]), .p(p[35:20]), .G(G2), .P(P2));

    // ---- band carries with precision carry kill ----
    wire c12 = G0[11] & en_mid;
    wire c20 = (G1[7] | (P1[7] & c12)) & en_hi;

    // ---- carry into every bit ----
    wire [35:0] cy;

    assign cy[0]     = 1'b0;
    assign cy[11:1]  = G0[10:0];
    assign cy[12]    = c12;
    assign cy[19:13] = G1[6:0]  | (P1[6:0]  & {7{c12}});
    assign cy[20]    = c20;
    assign cy[35:21] = G2[14:0] | (P2[14:0] & {15{c20}});

    // ---- sum ----
    assign s = p ^ cy;
endmodule

// ============================================================================
// pe_sign_rows
//   Turns the unsigned product Au*Bu into a signed product inside the
//   accumulator width W (12 / 20 / 36), without any adder of its own.
//   With n = 4 / 8 / 16, sa = A[n-1], sb = B[n-1]:
//
//     A*B (signed) = Au*Bu - 2^n*(sa*Bu) - 2^n*(sb*Au) + 2^(2n)*(sa*sb)
//
//   and modulo 2^W each negative term is rewritten as
//     -(X << n) = (~X << n) + ones[W-1:2n] + 2^n          (X is n bit)
//
//   This module therefore only produces three extra rows for the CSA tree:
//     row_a = ~corr_a << n            corr_a = sa ? Bu : 0
//     row_b = ~corr_b << n            corr_b = sb ? Au : 0
//     row_k = K(mode) | (sa & sb) << 2n
//   K(mode) = 2*ones[W-1:2n] + 2^(n+1) (mod 2^W) is constant per mode:
//     INT4 : 0x000000E20   INT8 : 0x0000E0200   INT16 : 0xE00020000
//   Bit 2n of K is always 0, so the sa*sb bit can be ORed into the same row.
// ============================================================================
module pe_sign_rows (
    input  wire [15:0] a,
    input  wire [15:0] b,
    input  wire        is4,
    input  wire        is8,
    input  wire        is16,
    input  wire        en_lo,
    input  wire        en_mid,
    input  wire        en_hi,
    output wire [35:0] row_a,
    output wire [35:0] row_b,
    output wire [35:0] row_k
);
    // ---- operand width mask (n bits) and isolated unsigned operands ----
    wire [15:0] m16 = {{8{en_hi}}, {4{en_mid}}, {4{en_lo}}};
    wire [15:0] a_u = a & m16;
    wire [15:0] b_u = b & m16;

    // ---- sign bits of the selected precision ----
    wire sa  = (a[3] & is4) | (a[7] & is8) | (a[15] & is16);
    wire sb  = (b[3] & is4) | (b[7] & is8) | (b[15] & is16);
    wire sab = sa & sb;

    // ---- correction terms, inverted and limited to n bits ----
    wire [15:0] nca = ~(b_u & {16{sa}}) & m16;
    wire [15:0] ncb = ~(a_u & {16{sb}}) & m16;

    // ---- place the inverted terms at bit n (AND-OR select) ----
    assign row_a = ({28'b0, nca[3:0],  4'b0} & {36{is4}})
                 | ({20'b0, nca[7:0],  8'b0} & {36{is8}})
                 | ({4'b0,  nca,      16'b0} & {36{is16}});

    assign row_b = ({28'b0, ncb[3:0],  4'b0} & {36{is4}})
                 | ({20'b0, ncb[7:0],  8'b0} & {36{is8}})
                 | ({4'b0,  ncb,      16'b0} & {36{is16}});

    // ---- constant row plus the sa*sb bit at position 2n (8 / 16 / 32) ----
    assign row_k = (36'h000000E20 & {36{is4}})
                 | (36'h0000E0200 & {36{is8}})
                 | (36'hE00020000 & {36{is16}})
                 | {3'b0, sab & is16, 15'b0, sab & is8, 7'b0, sab & is4, 8'b0};
endmodule

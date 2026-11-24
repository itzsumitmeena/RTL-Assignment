// ============================================================================
// mult4x4_dadda
//   4x4 unsigned multiplier, p = a * b (8 bit).
//   16 AND partial-product bits -> 2 Dadda stages (height 4 -> 3 -> 2)
//   -> one 6-bit lookahead adder. 16 of these build the 16x16 product.
// ============================================================================
module mult4x4_dadda (
    input  wire [3:0] a,
    input  wire [3:0] b,
    output wire [7:0] p
);
    // ---- partial-product bits: row k = a AND b[k], weight 2^k ----
    wire [3:0] row0 = a & {4{b[0]}};
    wire [3:0] row1 = a & {4{b[1]}};
    wire [3:0] row2 = a & {4{b[2]}};
    wire [3:0] row3 = a & {4{b[3]}};

    // ---- Dadda stage 1: max column height 4 -> 3 (half adders) ----
    wire s13, c13, s14, c14;

    full_adder ha13 (.a(row0[3]), .b(row1[2]), .cin(1'b0), .sum(s13), .cout(c13));
    full_adder ha14 (.a(row1[3]), .b(row2[2]), .cin(1'b0), .sum(s14), .cout(c14));

    // ---- Dadda stage 2: max column height 3 -> 2 ----
    wire s22, c22, s23, c23, s24, c24, s25, c25;

    full_adder fa22 (.a(row0[2]), .b(row1[1]), .cin(row2[0]), .sum(s22), .cout(c22));
    full_adder fa23 (.a(s13),     .b(row2[1]), .cin(row3[0]), .sum(s23), .cout(c23));
    full_adder fa24 (.a(s14),     .b(row3[1]), .cin(c13),     .sum(s24), .cout(c24));
    full_adder fa25 (.a(row2[3]), .b(row3[2]), .cin(c14),     .sum(s25), .cout(c25));

    // ---- two final rows (columns 1..6) and the 6-bit final adder ----
    wire [5:0] x = {row3[3], s25, s24, s23, s22, row0[1]};
    wire [5:0] y = {c25,     c24, c23, c22, 1'b0, row1[0]};
    wire [5:0] fsum;
    wire       fcout;

    cla4_cla2_rca u_final (.x(x), .y(y), .sum(fsum), .cout(fcout));

    // column 0 needs no addition
    assign p = {fcout, fsum, row0[0]};
endmodule

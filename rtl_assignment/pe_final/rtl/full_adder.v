// ============================================================================
// full_adder
//   Gate-level 1-bit full adder. The only adder cell of the whole PE:
//   used by the 4x4 Dadda multipliers and by every 3:2 compressor row.
//   With cin = 0 it acts as a half adder (constant is removed in synthesis).
// ============================================================================
module full_adder (
    input  wire a,
    input  wire b,
    input  wire cin,
    output wire sum,
    output wire cout
);
    wire x;             // a XOR b, shared by sum and carry
    wire n1, n2;        // NAND terms of the carry

    // sum = a ^ b ^ cin
    xor  (x,   a, b);
    xor  (sum, x, cin);

    // cout = (a & b) | ((a ^ b) & cin), built as NAND-NAND
    nand (n1, a, b);
    nand (n2, x, cin);
    nand (cout, n1, n2);
endmodule

// ============================================================================
// pe_pp_gen
//   Splits A and B into 4-bit nibbles and builds the 16 unsigned nibble
//   products  P_ij = A_i * B_j  (8 bit each, weight 2^(4(i+j))).
//   Operand isolation: both inputs of a 4x4 multiplier are ANDed with its
//   enable, so a multiplier that is not needed sees constant zeros.
//     INT4  : P00                     (nibble 0 only)
//     INT8  : P00 P01 P10 P11         (nibbles 0-1)
//     INT16 : all 16                  (nibbles 0-3)
//   Output packing: pp[8*(4i+j) +: 8] = P_ij
// ============================================================================
module pe_pp_gen (
    input  wire [15:0]  a,
    input  wire [15:0]  b,
    input  wire         en_lo,
    input  wire         en_mid,
    input  wire         en_hi,
    output wire [127:0] pp
);
    // ---- enable of each nibble position ----
    wire [3:0] nib_en = {en_hi, en_hi, en_mid, en_lo};

    genvar i, j;
    generate
        for (i = 0; i < 4; i = i + 1) begin : ROW
            for (j = 0; j < 4; j = j + 1) begin : COL
                // product active only if both of its nibbles are active
                wire       en    = nib_en[i] & nib_en[j];
                wire [3:0] a_iso = a[4*i +: 4] & {4{en}};
                wire [3:0] b_iso = b[4*j +: 4] & {4{en}};

                mult4x4_dadda u_mul (
                    .a (a_iso),
                    .b (b_iso),
                    .p (pp[8*(4*i+j) +: 8])
                );
            end
        end
    endgenerate
endmodule

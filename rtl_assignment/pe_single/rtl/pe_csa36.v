// ============================================================================
// pe_csa36
//   One 36-bit 3:2 compressor row: x + y + z = s + c   (mod 2^36),
//   36 full adders, no carry propagation. c is already shifted left by 1.
//   Carry kill at the accumulator band boundaries:
//     carry into bit 12 passes only if en_mid (INT8 / INT16)
//     carry into bit 20 passes only if en_hi  (INT16)
//   Dropping these carries is exact, because the result is only needed
//   modulo 2^12 (INT4) or 2^20 (INT8); it keeps the upper bands at zero.
// ============================================================================
module pe_csa36 (
    input  wire [35:0] x,
    input  wire [35:0] y,
    input  wire [35:0] z,
    input  wire        en_mid,
    input  wire        en_hi,
    output wire [35:0] s,
    output wire [35:0] c
);
    wire [35:0] co;     // carry out of every bit position

    // ---- 36 independent full adders ----
    genvar i;
    generate
        for (i = 0; i < 36; i = i + 1) begin : FA
            full_adder u_fa (
                .a   (x[i]),
                .b   (y[i]),
                .cin (z[i]),
                .sum (s[i]),
                .cout(co[i])
            );
        end
    endgenerate

    // ---- shift carries left, kill at bits 12 and 20, drop bit 35 ----
    assign c = {co[34:20], co[19] & en_hi, co[18:12], co[11] & en_mid, co[10:0], 1'b0};
endmodule

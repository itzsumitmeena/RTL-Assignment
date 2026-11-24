// ============================================================================
// pe_mode_ctrl
//   Decodes the 2-bit precision mode into one-hot flags and band enables.
//     mode 00 : INT4      mode 01 : INT8      mode 10 : INT16
//     mode 11 : reserved  -> every enable is 0, so no register of the PE
//                            can load and no arithmetic is started.
//   Band enables are shared by operands, partial products and accumulator:
//     en_lo  : operand bits [3:0]  / accumulator bits [11:0]   (all modes)
//     en_mid : operand bits [7:4]  / accumulator bits [19:12]  (INT8, INT16)
//     en_hi  : operand bits [15:8] / accumulator bits [35:20]  (INT16)
// ============================================================================
module pe_mode_ctrl (
    input  wire [1:0] mode,
    output wire       is4,
    output wire       is8,
    output wire       is16,
    output wire       en_lo,
    output wire       en_mid,
    output wire       en_hi
);
    // ---- one-hot precision flags (11 decodes to all zero) ----
    assign is4  = ~mode[1] & ~mode[0];
    assign is8  = ~mode[1] &  mode[0];
    assign is16 =  mode[1] & ~mode[0];

    // ---- nested band enables ----
    assign en_lo  = is4 | is8 | is16;
    assign en_mid = is8 | is16;
    assign en_hi  = is16;
endmodule

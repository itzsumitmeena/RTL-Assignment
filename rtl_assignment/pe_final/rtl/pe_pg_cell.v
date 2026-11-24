// ============================================================================
// pe_pg_cell
//   Prefix ("black") cell: combines a higher group (hi) with the adjacent
//   lower group (lo) into one larger group.
//     g_out = g_hi | (p_hi & g_lo)        group generate
//     p_out = p_hi & p_lo                 group propagate
// ============================================================================
module pe_pg_cell (
    input  wire g_hi,
    input  wire p_hi,
    input  wire g_lo,
    input  wire p_lo,
    output wire g_out,
    output wire p_out
);
    assign g_out = g_hi | (p_hi & g_lo);
    assign p_out = p_hi & p_lo;
endmodule

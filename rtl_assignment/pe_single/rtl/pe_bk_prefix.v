// ============================================================================
// pe_bk_prefix
//   N-bit Brent-Kung parallel-prefix network.
//   Input : bit generate g[i] and propagate p[i]
//   Output: G[i] = generate of group [i:0], P[i] = propagate of group [i:0]
//   Structure (L = ceil(log2 N), 2L-1 stages):
//     up-sweep   stage s (d = 2^s)      : cell at i = 2d-1, 4d-1, ...  (lo = i-d)
//     down-sweep stage s (d = 2^(2L-2-s)): cell at i = 3d-1, 5d-1, ... (lo = i-d)
//   Brent-Kung is used instead of Kogge-Stone: about half the cells and
//   short wires (lower power), a few more levels (fine at 300 MHz).
//   Stage data is kept in flat vectors: stage k occupies bits [N*k +: N].
// ============================================================================
module pe_bk_prefix #(
    parameter N = 16,                    // width of the band
    parameter L = 4                      // ceil(log2(N))
) (
    input  wire [N-1:0] g,
    input  wire [N-1:0] p,
    output wire [N-1:0] G,
    output wire [N-1:0] P
);
    localparam S = 2*L - 1;              // number of prefix stages

    wire [N*(S+1)-1:0] gs;               // generate after each stage
    wire [N*(S+1)-1:0] ps;               // propagate after each stage

    assign gs[N-1:0] = g;
    assign ps[N-1:0] = p;

    genvar st, i;
    generate
        for (st = 0; st < S; st = st + 1) begin : STAGE
            // distance of this stage (up-sweep: 1,2,4..  down-sweep: ..4,2,1)
            localparam D = (st < L) ? (1 << st) : (1 << (2*L - 2 - st));

            for (i = 0; i < N; i = i + 1) begin : BIT
                // does bit i get a prefix cell in this stage?
                localparam CELL = (st < L) ? ((i % (2*D)) == (2*D - 1))
                                           : ((i >= 3*D - 1) && ((i % (2*D)) == (D - 1)));
                if (CELL) begin : PG
                    pe_pg_cell u_pg (
                        .g_hi (gs[N*st + i]),
                        .p_hi (ps[N*st + i]),
                        .g_lo (gs[N*st + i - D]),
                        .p_lo (ps[N*st + i - D]),
                        .g_out(gs[N*(st+1) + i]),
                        .p_out(ps[N*(st+1) + i])
                    );
                end else begin : PASS
                    assign gs[N*(st+1) + i] = gs[N*st + i];
                    assign ps[N*(st+1) + i] = ps[N*st + i];
                end
            end
        end
    endgenerate

    assign G = gs[N*S +: N];
    assign P = ps[N*S +: N];
endmodule

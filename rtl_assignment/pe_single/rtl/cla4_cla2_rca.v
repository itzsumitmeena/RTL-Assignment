// ============================================================================
// cla4_cla2_rca
//   6-bit adder (carry-in = 0) used as the final adder of mult4x4_dadda.
//   Lower 4 bits: one carry-lookahead block.
//   Upper 2 bits: 2-bit lookahead block fed by the lower block carry.
// ============================================================================
module cla4_cla2_rca (
    input  wire [5:0] x,
    input  wire [5:0] y,
    output wire [5:0] sum,
    output wire       cout
);
    wire [3:0] p4, g4;          // lower block propagate / generate
    wire [1:0] p2, g2;          // upper block propagate / generate
    wire c1, c2, c3, c4;        // lower block carries
    wire c5, c6;                // upper block carries

    // ---- lower 4-bit lookahead block (cin = 0) ----
    assign p4 = x[3:0] ^ y[3:0];
    assign g4 = x[3:0] & y[3:0];

    assign c1 = g4[0];
    assign c2 = g4[1] | (p4[1] & g4[0]);
    assign c3 = g4[2] | (p4[2] & g4[1]) | (p4[2] & p4[1] & g4[0]);
    assign c4 = g4[3] | (p4[3] & g4[2]) | (p4[3] & p4[2] & g4[1])
                      | (p4[3] & p4[2] & p4[1] & g4[0]);

    assign sum[3:0] = p4 ^ {c3, c2, c1, 1'b0};

    // ---- upper 2-bit lookahead block (cin = c4) ----
    assign p2 = x[5:4] ^ y[5:4];
    assign g2 = x[5:4] & y[5:4];

    assign c5 = g2[0] | (p2[0] & c4);
    assign c6 = g2[1] | (p2[1] & g2[0]) | (p2[1] & p2[0] & c4);

    assign sum[5:4] = p2 ^ {c5, c4};
    assign cout     = c6;
endmodule

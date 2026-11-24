// ============================================================================
// pe_seg_reg
//   Register split into three precision bands, each with its own load enable.
//   A band that is not used by the current mode keeps its old value, so its
//   flip-flops and everything they drive do not switch.
//   Used for: A/B operand + forwarding registers (W0=4,  W1=4, W2=8)
//             accumulator register                (W0=12, W1=8, W2=16)
//   The "if (load) q <= d" form lets the synthesis tool infer clock gating.
// ============================================================================
module pe_seg_reg #(
    parameter W0 = 4,                    // low band  (all modes)
    parameter W1 = 4,                    // mid band  (INT8, INT16)
    parameter W2 = 8                     // high band (INT16)
) (
    input  wire                clk,
    input  wire                rst,      // asynchronous, active high
    input  wire                load,     // valid data present this cycle
    input  wire                en_lo,
    input  wire                en_mid,
    input  wire                en_hi,
    input  wire [W0+W1+W2-1:0] d,
    output wire [W0+W1+W2-1:0] q
);
    // ---- one storage register per band ----
    reg [W0-1:0] q_lo;
    reg [W1-1:0] q_mid;
    reg [W2-1:0] q_hi;

    // ---- band load enables ----
    wire ld_lo  = load & en_lo;
    wire ld_mid = load & en_mid;
    wire ld_hi  = load & en_hi;

    // ---- low band ----
    always @(posedge clk or posedge rst) begin
        if (rst)        q_lo <= {W0{1'b0}};
        else if (ld_lo) q_lo <= d[W0-1:0];
    end

    // ---- mid band ----
    always @(posedge clk or posedge rst) begin
        if (rst)         q_mid <= {W1{1'b0}};
        else if (ld_mid) q_mid <= d[W0+W1-1:W0];
    end

    // ---- high band ----
    always @(posedge clk or posedge rst) begin
        if (rst)        q_hi <= {W2{1'b0}};
        else if (ld_hi) q_hi <= d[W0+W1+W2-1:W0+W1];
    end

    assign q = {q_hi, q_mid, q_lo};
endmodule

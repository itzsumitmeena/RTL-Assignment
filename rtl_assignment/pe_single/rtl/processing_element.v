// ============================================================================
// processing_element
//   One PE of the 16x16 precision-scalable systolic tensor unit.
//   Fused signed MAC:   ACC <- ACC + A*B    (INT4 / INT8 / INT16)
//
//   Datapath (one clock cycle, a single carry-propagate adder):
//     A/B operand registers -> 16 nibble products  \
//                           -> signed-correction rows -> CSA tree -> pe_add36 -> ACC
//     ACC register ----------------------------------/
//
//   Ports / timing
//     a_in, b_in, valid_in, first_in are captured on the rising edge.
//     The same registers drive the right / lower neighbour (systolic
//     forwarding) and this PE's datapath in the following cycle.
//     first_in marks k = 0 of a dot product: the accumulator is loaded with
//     the product instead of ACC + product (no separate clear cycle).
//     mode must stay constant during one matrix multiplication.
//
//   Accumulator format (acc_out): valid width 12 / 20 / 36 bits for
//   INT4 / INT8 / INT16, signed. Bits above the active width are not
//   updated; sign extension is done once, when the result is read out.
//
//   Power management
//     - band-wise register enables (operands, accumulator)
//     - operand isolation of the unused 4x4 multipliers and rows
//     - carry kill at bits 12 / 20 in every CSA row and in the adder
//     - no update of anything while valid is low
// ============================================================================
module processing_element (
    input  wire        clk,
    input  wire        rst,              // asynchronous, active high
    input  wire [1:0]  mode,             // 00 INT4, 01 INT8, 10 INT16, 11 reserved
    input  wire [15:0] a_in,
    input  wire [15:0] b_in,
    input  wire        valid_in,
    input  wire        first_in,
    output wire [15:0] a_out,
    output wire [15:0] b_out,
    output wire        valid_out,
    output wire        first_out,
    output wire [35:0] acc_out
);
    // ------------------------------------------------------------------
    // 1. Precision control
    // ------------------------------------------------------------------
    wire is4, is8, is16, en_lo, en_mid, en_hi;

    pe_mode_ctrl u_mode (
        .mode(mode), .is4(is4), .is8(is8), .is16(is16),
        .en_lo(en_lo), .en_mid(en_mid), .en_hi(en_hi)
    );

    // ------------------------------------------------------------------
    // 2. Operand / forwarding registers (bands [3:0], [7:4], [15:8])
    // ------------------------------------------------------------------
    wire [15:0] a_q, b_q;

    pe_seg_reg #(.W0(4), .W1(4), .W2(8)) u_a_reg (
        .clk(clk), .rst(rst), .load(valid_in),
        .en_lo(en_lo), .en_mid(en_mid), .en_hi(en_hi),
        .d(a_in), .q(a_q)
    );

    pe_seg_reg #(.W0(4), .W1(4), .W2(8)) u_b_reg (
        .clk(clk), .rst(rst), .load(valid_in),
        .en_lo(en_lo), .en_mid(en_mid), .en_hi(en_hi),
        .d(b_in), .q(b_q)
    );

    // ---- valid / first tags travel with the operands ----
    reg v_q, f_q;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            v_q <= 1'b0;
            f_q <= 1'b0;
        end else begin
            v_q <= valid_in;
            f_q <= first_in & valid_in;      // no stray first while idle
        end
    end

    // ------------------------------------------------------------------
    // 3. Unsigned nibble products and signed-correction rows
    // ------------------------------------------------------------------
    wire [127:0] pp;
    wire [35:0]  row_a, row_b, row_k;

    pe_pp_gen u_pp (
        .a(a_q), .b(b_q),
        .en_lo(en_lo), .en_mid(en_mid), .en_hi(en_hi),
        .pp(pp)
    );

    pe_sign_rows u_sign (
        .a(a_q), .b(b_q),
        .is4(is4), .is8(is8), .is16(is16),
        .en_lo(en_lo), .en_mid(en_mid), .en_hi(en_hi),
        .row_a(row_a), .row_b(row_b), .row_k(row_k)
    );

    // ------------------------------------------------------------------
    // 4. Accumulator feedback: active bands only, zero on first
    // ------------------------------------------------------------------
    wire [35:0] acc_q;
    wire g_lo  = en_lo  & ~f_q;
    wire g_mid = en_mid & ~f_q;
    wire g_hi  = en_hi  & ~f_q;
    wire [35:0] acc_in = acc_q & {{16{g_hi}}, {8{g_mid}}, {12{g_lo}}};

    // ------------------------------------------------------------------
    // 5. CSA tree (20 rows -> 2) and the single carry-propagate adder
    // ------------------------------------------------------------------
    wire [35:0] vs, vc, mac_sum;

    pe_csa_tree u_tree (
        .pp(pp), .row_a(row_a), .row_b(row_b), .row_k(row_k), .acc_in(acc_in),
        .en_mid(en_mid), .en_hi(en_hi),
        .vs(vs), .vc(vc)
    );

    pe_add36 u_add (
        .a(vs), .b(vc), .en_mid(en_mid), .en_hi(en_hi), .s(mac_sum)
    );

    // ------------------------------------------------------------------
    // 6. Accumulator register (bands [11:0], [19:12], [35:20])
    // ------------------------------------------------------------------
    pe_seg_reg #(.W0(12), .W1(8), .W2(16)) u_acc_reg (
        .clk(clk), .rst(rst), .load(v_q),
        .en_lo(en_lo), .en_mid(en_mid), .en_hi(en_hi),
        .d(mac_sum), .q(acc_q)
    );

    // ------------------------------------------------------------------
    // 7. Outputs
    // ------------------------------------------------------------------
    assign a_out     = a_q;
    assign b_out     = b_q;
    assign valid_out = v_q;
    assign first_out = f_q;
    assign acc_out   = acc_q;
endmodule

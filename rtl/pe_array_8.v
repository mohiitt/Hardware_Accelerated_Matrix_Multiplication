/*
 * Phase 11: 8-PE Array Module
 *
 * 8 parallel PEs that share the same A input (broadcast)
 * but each receives a different B input.
 * Computes 8 columns of C simultaneously.
 */
module pe_array_8 (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              clear,
    input  wire              enable,
    input  wire signed [7:0] a_broadcast,       // shared A value
    input  wire signed [7:0] b_in [0:7],        // 8 different B values
    output wire signed [31:0] acc_out [0:7]     // 8 accumulators
);

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : pe_gen
            pe u_pe (
                .clk(clk),
                .rst_n(rst_n),
                .clear(clear),
                .enable(enable),
                .a(a_broadcast),
                .b(b_in[g]),
                .acc(acc_out[g])
            );
        end
    endgenerate

endmodule

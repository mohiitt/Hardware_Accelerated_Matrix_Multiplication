/*
 * Phase 6: Hardcoded PL Matrix Multiply — Custom logic
 *
 * Same wizard-generated AXI-Lite slave as Phase 5.
 * REPLACE the Phase 5 custom logic with this block.
 *
 * This adds:
 *   - Hardcoded A[4][4] and B[4][4] matrices
 *   - FSM that computes C = A * B
 *   - Uses pe.v for MAC operations
 *   - RESULT register holds checksum (sum of all C values)
 *
 * PREREQUISITES:
 *   - pe.v must be added as an additional source to the IP project
 *   - slv_reg1 (STATUS) and slv_reg5 (RESULT) must NOT be written by
 *     the auto-generated software-write logic (same as Phase 5)
 */

// ---- PASTE THIS BEFORE endmodule IN THE GENERATED S00_AXI FILE ----
// (Replace the Phase 5 custom logic)

// Hardcoded matrices (same as software_model/main.c)
// A[4][4] stored row-major: A[i*4+k]
wire signed [7:0] A_mem [0:15];
assign A_mem[ 0] = 8'sd1;  assign A_mem[ 1] = 8'sd2;
assign A_mem[ 2] = 8'sd3;  assign A_mem[ 3] = 8'sd4;
assign A_mem[ 4] = 8'sd5;  assign A_mem[ 5] = 8'sd6;
assign A_mem[ 6] = 8'sd7;  assign A_mem[ 7] = 8'sd8;
assign A_mem[ 8] = 8'sd1;  assign A_mem[ 9] = 8'sd1;
assign A_mem[10] = 8'sd1;  assign A_mem[11] = 8'sd1;
assign A_mem[12] = -8'sd1; assign A_mem[13] = 8'sd2;
assign A_mem[14] = -8'sd3; assign A_mem[15] = 8'sd4;

// B[4][4] stored row-major: B[k*4+j]
wire signed [7:0] B_mem [0:15];
assign B_mem[ 0] = 8'sd1;  assign B_mem[ 1] = 8'sd0;
assign B_mem[ 2] = 8'sd2;  assign B_mem[ 3] = 8'sd1;
assign B_mem[ 4] = 8'sd0;  assign B_mem[ 5] = 8'sd1;
assign B_mem[ 6] = 8'sd2;  assign B_mem[ 7] = 8'sd1;
assign B_mem[ 8] = 8'sd1;  assign B_mem[ 9] = 8'sd1;
assign B_mem[10] = 8'sd0;  assign B_mem[11] = 8'sd1;
assign B_mem[12] = 8'sd2;  assign B_mem[13] = 8'sd0;
assign B_mem[14] = 8'sd1;  assign B_mem[15] = 8'sd1;

// Result memory
reg signed [31:0] C_mem [0:15];

// FSM
localparam S_IDLE    = 3'd0;
localparam S_CLEAR   = 3'd1;
localparam S_COMPUTE = 3'd2;
localparam S_CHECKSUM= 3'd3;
localparam S_DONE    = 3'd4;

reg [2:0]  fsm_state;
reg [3:0]  cnt_i, cnt_j, cnt_k;
reg [3:0]  cs_idx;

// PE signals
reg         pe_clear, pe_enable;
reg  signed [7:0] pe_a, pe_b;
wire signed [31:0] pe_acc;

pe u_pe (
    .clk(S_AXI_ACLK),
    .rst_n(S_AXI_ARESETN),
    .clear(pe_clear),
    .enable(pe_enable),
    .a(pe_a),
    .b(pe_b),
    .acc(pe_acc)
);

// Start detection
reg start_prev;
wire start_pulse = slv_reg0[0] & ~start_prev;

always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN)
        start_prev <= 1'b0;
    else
        start_prev <= slv_reg0[0];
end

// Checksum accumulator
reg signed [31:0] checksum;

// Main FSM
always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
        fsm_state <= S_IDLE;
        slv_reg1  <= 32'd0;
        slv_reg5  <= 32'd0;
        pe_clear  <= 1'b0;
        pe_enable <= 1'b0;
        pe_a      <= 8'd0;
        pe_b      <= 8'd0;
        cnt_i     <= 0;
        cnt_j     <= 0;
        cnt_k     <= 0;
        cs_idx    <= 0;
        checksum  <= 0;
    end else begin
        pe_clear  <= 1'b0;
        pe_enable <= 1'b0;

        case (fsm_state)
            S_IDLE: begin
                if (start_pulse) begin
                    slv_reg1  <= 32'd2;  // busy
                    cnt_i     <= 0;
                    cnt_j     <= 0;
                    cnt_k     <= 0;
                    fsm_state <= S_CLEAR;
                end
            end

            S_CLEAR: begin
                pe_clear  <= 1'b1;
                fsm_state <= S_COMPUTE;
            end

            S_COMPUTE: begin
                pe_enable <= 1'b1;
                pe_a <= A_mem[cnt_i * 4 + cnt_k];
                pe_b <= B_mem[cnt_k * 4 + cnt_j];

                if (cnt_k == 4'd3) begin
                    // After this cycle, PE has final accumulated value
                    // We need one more cycle to read it, handled below
                    cnt_k <= 0;

                    // Store result (pe_acc includes this cycle's MAC
                    // but the PE updates on next posedge, so we store
                    // at the transition)
                    // Actually: pe_acc is registered, so it lags by 1.
                    // We need to wait one cycle after last MAC.
                    fsm_state <= S_CLEAR; // temporary: go store result

                    // Store current accumulated value + this last product
                    C_mem[cnt_i * 4 + cnt_j] <= pe_acc + (pe_a * pe_b);

                    // Advance i, j
                    if (cnt_j == 4'd3) begin
                        cnt_j <= 0;
                        if (cnt_i == 4'd3) begin
                            // All done computing
                            fsm_state <= S_CHECKSUM;
                            cs_idx    <= 0;
                            checksum  <= 0;
                        end else begin
                            cnt_i     <= cnt_i + 1;
                            fsm_state <= S_CLEAR;
                        end
                    end else begin
                        cnt_j     <= cnt_j + 1;
                        fsm_state <= S_CLEAR;
                    end
                end else begin
                    cnt_k <= cnt_k + 1;
                end
            end

            S_CHECKSUM: begin
                checksum <= checksum + C_mem[cs_idx];
                if (cs_idx == 4'd15) begin
                    slv_reg5  <= checksum + C_mem[15];
                    fsm_state <= S_DONE;
                end else begin
                    cs_idx <= cs_idx + 1;
                end
            end

            S_DONE: begin
                slv_reg1  <= 32'd1;  // done
                fsm_state <= S_IDLE;
            end
        endcase
    end
end

// ---- END OF CUSTOM LOGIC ----

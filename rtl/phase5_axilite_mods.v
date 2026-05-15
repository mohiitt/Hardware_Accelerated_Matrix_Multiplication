/*
 * Phase 5: AXI-Lite Register IP — Custom logic
 *
 * HOW TO USE WITH VIVADO WIZARD:
 * 1. Tools → Create and Package New IP → AXI4 peripheral
 * 2. Name: matrix_accel, AXI4-Lite Slave, 6 registers
 * 3. Click "Edit IP" when done
 * 4. Open the generated file: matrix_accel_v1_0_S00_AXI.v
 * 5. Make these modifications to the generated code:
 *
 * MODIFICATION 1: In the register write section, find where slv_reg1 and
 * slv_reg5 are written. Comment out or remove those write cases.
 * These are STATUS and RESULT — they should be hardware-controlled only.
 *
 * Look for code like:
 *     2'h1: for (...)  slv_reg1[...] <= ...
 *     2'h5: for (...)  slv_reg5[...] <= ...
 * Comment those out.
 *
 * MODIFICATION 2: Add this custom logic block BEFORE the "endmodule" line:
 */

// ---- PASTE THIS BEFORE endmodule IN THE GENERATED S00_AXI FILE ----

// Detect rising edge of start bit (CTRL register bit 0)
reg start_prev;
wire start_pulse;

always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN)
        start_prev <= 1'b0;
    else
        start_prev <= slv_reg0[0];
end

assign start_pulse = slv_reg0[0] & ~start_prev;

// Simple computation: RESULT = M + K + N
// States: 0=IDLE, 1=COMPUTE, 2=DONE
reg [1:0] state;

always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
        state    <= 2'd0;
        slv_reg1 <= 32'd0;  // STATUS
        slv_reg5 <= 32'd0;  // RESULT
    end else begin
        case (state)
            2'd0: begin  // IDLE
                if (start_pulse) begin
                    slv_reg1 <= 32'd2;  // busy=1, done=0
                    state    <= 2'd1;
                end
            end
            2'd1: begin  // COMPUTE
                slv_reg5 <= slv_reg2 + slv_reg3 + slv_reg4;  // M + K + N
                state    <= 2'd2;
            end
            2'd2: begin  // DONE
                slv_reg1 <= 32'd1;  // done=1, busy=0
                state    <= 2'd0;
            end
        endcase
    end
end

// ---- END OF CUSTOM LOGIC ----

/*
 * MODIFICATION 3: In the register read section, make sure slv_reg1 and
 * slv_reg5 are still readable (they should be by default).
 *
 * The read mux typically looks like:
 *   2'h0: reg_data_out <= slv_reg0;
 *   2'h1: reg_data_out <= slv_reg1;   ← STATUS
 *   ...
 *   2'h5: reg_data_out <= slv_reg5;   ← RESULT
 *
 * This should already work. Just verify it's there.
 *
 * IMPORTANT: Since we write slv_reg1 and slv_reg5 from custom logic,
 * you must declare them as "reg" (they already are in the generated code)
 * but REMOVE the software-write assignments for these registers.
 */

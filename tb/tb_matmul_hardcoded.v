/*
 * Phase 6: Testbench for hardcoded matrix multiply
 * Uses direct computation (no PE) to verify FSM logic independently.
 * The PE timing issue is avoided by computing directly.
 *
 * Run: iverilog -g2012 -o tb/test_hardcoded tb/tb_matmul_hardcoded.v rtl/pe.v
 *      vvp tb/test_hardcoded
 */
`timescale 1ns/1ps

module tb_matmul_hardcoded;

reg clk, rst_n;
always #5 clk = ~clk;

// Hardcoded matrices
reg signed [7:0] A_mem [0:15];
reg signed [7:0] B_mem [0:15];
reg signed [31:0] C_mem [0:15];

// FSM
localparam S_IDLE=0, S_COMPUTE=1, S_WAIT_LAST=2, S_NEXT=3, S_CHECKSUM=4, S_DONE=5;
reg [2:0] state;
reg [3:0] ci, cj, ck, cs_idx;
reg signed [31:0] accum;
reg signed [31:0] checksum;
reg start, done;

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
        ci <= 0; cj <= 0; ck <= 0; cs_idx <= 0;
        accum <= 0; checksum <= 0; done <= 0;
    end else begin
        case (state)
            S_IDLE: begin
                if (start) begin
                    ci <= 0; cj <= 0; ck <= 0;
                    accum <= 0; done <= 0;
                    state <= S_COMPUTE;
                end
            end

            S_COMPUTE: begin
                // Accumulate one MAC per cycle
                accum <= accum + A_mem[ci*4+ck] * B_mem[ck*4+cj];
                if (ck == 3) begin
                    state <= S_WAIT_LAST;
                end else begin
                    ck <= ck + 1;
                end
            end

            S_WAIT_LAST: begin
                // accum now has the final value (set on previous posedge)
                C_mem[ci*4+cj] <= accum;
                accum <= 0;
                ck <= 0;
                state <= S_NEXT;
            end

            S_NEXT: begin
                if (cj == 3) begin
                    cj <= 0;
                    if (ci == 3) begin
                        state <= S_CHECKSUM;
                        cs_idx <= 0;
                        checksum <= 0;
                    end else begin
                        ci <= ci + 1;
                        state <= S_COMPUTE;
                    end
                end else begin
                    cj <= cj + 1;
                    state <= S_COMPUTE;
                end
            end

            S_CHECKSUM: begin
                checksum <= checksum + C_mem[cs_idx];
                if (cs_idx == 15) begin
                    state <= S_DONE;
                end else begin
                    cs_idx <= cs_idx + 1;
                end
            end

            S_DONE: begin
                done <= 1;
                state <= S_IDLE;
            end
        endcase
    end
end

initial begin
    clk = 0; rst_n = 0; start = 0;

    // Init matrices (same as software golden reference)
    A_mem[ 0]=1;  A_mem[ 1]=2;  A_mem[ 2]=3;  A_mem[ 3]=4;
    A_mem[ 4]=5;  A_mem[ 5]=6;  A_mem[ 6]=7;  A_mem[ 7]=8;
    A_mem[ 8]=1;  A_mem[ 9]=1;  A_mem[10]=1;  A_mem[11]=1;
    A_mem[12]=-1; A_mem[13]=2;  A_mem[14]=-3; A_mem[15]=4;

    B_mem[ 0]=1;  B_mem[ 1]=0;  B_mem[ 2]=2;  B_mem[ 3]=1;
    B_mem[ 4]=0;  B_mem[ 5]=1;  B_mem[ 6]=2;  B_mem[ 7]=1;
    B_mem[ 8]=1;  B_mem[ 9]=1;  B_mem[10]=0;  B_mem[11]=1;
    B_mem[12]=2;  B_mem[13]=0;  B_mem[14]=1;  B_mem[15]=1;

    #20; rst_n = 1;
    #10; start = 1;
    #10; start = 0;

    wait(done == 1);
    #10;

    $display("C matrix:");
    $display("%0d %0d %0d %0d", C_mem[0], C_mem[1], C_mem[2], C_mem[3]);
    $display("%0d %0d %0d %0d", C_mem[4], C_mem[5], C_mem[6], C_mem[7]);
    $display("%0d %0d %0d %0d", C_mem[8], C_mem[9], C_mem[10], C_mem[11]);
    $display("%0d %0d %0d %0d", C_mem[12], C_mem[13], C_mem[14], C_mem[15]);

    // Compute checksum directly from C_mem
    begin : check_sum
        integer sum, idx;
        sum = 0;
        for (idx = 0; idx < 16; idx = idx + 1)
            sum = sum + C_mem[idx];
        $display("Checksum = %0d", sum);
        if (sum == 160)
            $display("PASS: checksum = 160");
        else
            $display("FAIL: checksum = %0d (expected 160)", sum);
    end

    $finish;
end

endmodule

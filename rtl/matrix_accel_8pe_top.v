/*
 * Phase 11: 8-PE Matrix Multiply Accelerator Top
 *
 * Same AXI-Lite + AXI-Stream interface as Phase 9, but uses 8 PEs
 * to compute 8 output columns in parallel.
 *
 * Compute loop:
 *   for each row i:
 *     for each column block j_block (step 8):
 *       clear 8 accumulators
 *       for each k:
 *         broadcast A[i][k]
 *         feed B[k][j_block+0..7] to 8 PEs
 *       store 8 C values
 *
 * N MUST be a multiple of 8.
 * Supports up to 64x64 (MAX_DIM=64).
 */
module matrix_accel_8pe_top #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5,
    parameter integer AXIS_DATA_WIDTH    = 32,
    parameter integer MAX_DIM            = 64
)(
    // AXI-Lite Slave
    input  wire                                s_axi_aclk,
    input  wire                                s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire [2:0]                          s_axi_awprot,
    input  wire                                s_axi_awvalid,
    output reg                                 s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]     s_axi_wstrb,
    input  wire                                s_axi_wvalid,
    output reg                                 s_axi_wready,
    output reg  [1:0]                          s_axi_bresp,
    output reg                                 s_axi_bvalid,
    input  wire                                s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire [2:0]                          s_axi_arprot,
    input  wire                                s_axi_arvalid,
    output reg                                 s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]       s_axi_rdata,
    output reg  [1:0]                          s_axi_rresp,
    output reg                                 s_axi_rvalid,
    input  wire                                s_axi_rready,

    // AXI-Stream Slave (from DMA MM2S)
    input  wire [AXIS_DATA_WIDTH-1:0]          s_axis_tdata,
    input  wire                                s_axis_tvalid,
    output reg                                 s_axis_tready,
    input  wire                                s_axis_tlast,

    // AXI-Stream Master (to DMA S2MM)
    output reg  [AXIS_DATA_WIDTH-1:0]          m_axis_tdata,
    output reg                                 m_axis_tvalid,
    input  wire                                m_axis_tready,
    output reg                                 m_axis_tlast
);

    // ========== AXI-Lite Registers ==========
    reg [31:0] reg_ctrl, reg_status, reg_m, reg_k, reg_n, reg_result;

    wire aw_w_valid = s_axi_awvalid && s_axi_wvalid;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0; s_axi_wready <= 0;
            s_axi_bvalid <= 0; s_axi_bresp <= 0;
            reg_ctrl <= 0; reg_m <= 0; reg_k <= 0; reg_n <= 0;
        end else begin
            s_axi_awready <= 0; s_axi_wready <= 0;
            if (aw_w_valid && !s_axi_awready) begin
                s_axi_awready <= 1; s_axi_wready <= 1;
                case (s_axi_awaddr[4:2])
                    3'h0: reg_ctrl <= s_axi_wdata;
                    3'h2: reg_m <= s_axi_wdata;
                    3'h3: reg_k <= s_axi_wdata;
                    3'h4: reg_n <= s_axi_wdata;
                endcase
            end
            if (s_axi_awready && s_axi_wready && !s_axi_bvalid) begin
                s_axi_bvalid <= 1; s_axi_bresp <= 2'b00;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
        end
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 0; s_axi_rvalid <= 0;
            s_axi_rresp <= 0; s_axi_rdata <= 0;
        end else begin
            s_axi_arready <= 0;
            if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
                s_axi_arready <= 1; s_axi_rvalid <= 1; s_axi_rresp <= 0;
                case (s_axi_araddr[4:2])
                    3'h0: s_axi_rdata <= reg_ctrl;
                    3'h1: s_axi_rdata <= reg_status;
                    3'h2: s_axi_rdata <= reg_m;
                    3'h3: s_axi_rdata <= reg_k;
                    3'h4: s_axi_rdata <= reg_n;
                    3'h5: s_axi_rdata <= reg_result;
                    default: s_axi_rdata <= 0;
                endcase
            end
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
        end
    end

    // ========== Computation Core with 8 PEs ==========

    reg signed [7:0]  A_mem [0:MAX_DIM*MAX_DIM-1];
    reg signed [7:0]  B_mem [0:MAX_DIM*MAX_DIM-1];
    reg signed [31:0] C_mem [0:MAX_DIM*MAX_DIM-1];

    reg [7:0] dim_m, dim_k, dim_n;

    localparam FSM_IDLE=0, FSM_LOAD_A=1, FSM_LOAD_B=2,
               FSM_CLEAR_PE=3, FSM_COMPUTE=4,
               FSM_STORE=5, FSM_SEND_C=6, FSM_DONE=7;
    reg [2:0] fsm_state;

    reg [15:0] load_byte_cnt, load_total_bytes;
    reg [7:0]  ci, cj_block, ck;
    reg [15:0] send_cnt, send_total;

    // Start pulse
    reg start_prev;
    wire start_pulse = reg_ctrl[0] & ~start_prev;
    always @(posedge s_axi_aclk)
        if (!s_axi_aresetn) start_prev <= 0;
        else start_prev <= reg_ctrl[0];

    // 8 PE signals
    reg         pe_clear, pe_enable;
    reg signed [7:0] pe_a_broadcast;
    reg signed [7:0] pe_b [0:7];
    wire signed [31:0] pe_acc [0:7];

    // Instantiate 8 PEs
    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : pe_gen
            pe u_pe (
                .clk(s_axi_aclk),
                .rst_n(s_axi_aresetn),
                .clear(pe_clear),
                .enable(pe_enable),
                .a(pe_a_broadcast),
                .b(pe_b[g]),
                .acc(pe_acc[g])
            );
        end
    endgenerate

    // Store counter for writing PE results to C_mem
    reg [2:0] store_idx;

    // Main FSM
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            fsm_state <= FSM_IDLE;
            reg_status <= 0; reg_result <= 0;
            s_axis_tready <= 0;
            m_axis_tdata <= 0; m_axis_tvalid <= 0; m_axis_tlast <= 0;
            pe_clear <= 0; pe_enable <= 0;
            pe_a_broadcast <= 0;
            load_byte_cnt <= 0;
            ci <= 0; cj_block <= 0; ck <= 0;
            send_cnt <= 0;
        end else begin
            pe_clear <= 0;
            pe_enable <= 0;

            case (fsm_state)
                FSM_IDLE: begin
                    s_axis_tready <= 0;
                    m_axis_tvalid <= 0; m_axis_tlast <= 0;
                    if (start_pulse) begin
                        dim_m <= reg_m[7:0]; dim_k <= reg_k[7:0]; dim_n <= reg_n[7:0];
                        reg_status <= 32'd2;
                        load_byte_cnt <= 0;
                        load_total_bytes <= reg_m[7:0] * reg_k[7:0];
                        fsm_state <= FSM_LOAD_A;
                        s_axis_tready <= 1;
                    end
                end

                FSM_LOAD_A: begin
                    s_axis_tready <= 1;
                    if (s_axis_tvalid && s_axis_tready) begin
                        A_mem[load_byte_cnt+0] <= $signed(s_axis_tdata[7:0]);
                        if (load_byte_cnt+1 < load_total_bytes)
                            A_mem[load_byte_cnt+1] <= $signed(s_axis_tdata[15:8]);
                        if (load_byte_cnt+2 < load_total_bytes)
                            A_mem[load_byte_cnt+2] <= $signed(s_axis_tdata[23:16]);
                        if (load_byte_cnt+3 < load_total_bytes)
                            A_mem[load_byte_cnt+3] <= $signed(s_axis_tdata[31:24]);
                        load_byte_cnt <= load_byte_cnt + 4;
                        if (load_byte_cnt + 4 >= load_total_bytes) begin
                            load_byte_cnt <= 0;
                            load_total_bytes <= dim_k * dim_n;
                            fsm_state <= FSM_LOAD_B;
                        end
                    end
                end

                FSM_LOAD_B: begin
                    s_axis_tready <= 1;
                    if (s_axis_tvalid && s_axis_tready) begin
                        B_mem[load_byte_cnt+0] <= $signed(s_axis_tdata[7:0]);
                        if (load_byte_cnt+1 < load_total_bytes)
                            B_mem[load_byte_cnt+1] <= $signed(s_axis_tdata[15:8]);
                        if (load_byte_cnt+2 < load_total_bytes)
                            B_mem[load_byte_cnt+2] <= $signed(s_axis_tdata[23:16]);
                        if (load_byte_cnt+3 < load_total_bytes)
                            B_mem[load_byte_cnt+3] <= $signed(s_axis_tdata[31:24]);
                        load_byte_cnt <= load_byte_cnt + 4;
                        if (load_byte_cnt + 4 >= load_total_bytes) begin
                            s_axis_tready <= 0;
                            ci <= 0; cj_block <= 0; ck <= 0;
                            pe_clear <= 1;
                            fsm_state <= FSM_CLEAR_PE;
                        end
                    end
                end

                FSM_CLEAR_PE: begin
                    pe_clear <= 1;
                    fsm_state <= FSM_COMPUTE;
                end

                FSM_COMPUTE: begin
                    pe_enable <= 1;
                    pe_a_broadcast <= A_mem[ci * dim_k + ck];

                    // Feed 8 B values: B[k][j_block+0..7]
                    begin : feed_b
                        integer p;
                        for (p = 0; p < 8; p = p + 1) begin
                            pe_b[p] <= B_mem[ck * dim_n + cj_block + p];
                        end
                    end

                    if (ck == dim_k - 1) begin
                        ck <= 0;
                        // Store results: need one cycle for last MAC
                        fsm_state <= FSM_STORE;
                        store_idx <= 0;
                    end else begin
                        ck <= ck + 1;
                    end
                end

                FSM_STORE: begin
                    pe_enable <= 0;
                    // Store all 8 results (pe_acc has final values after last MAC)
                    begin : store_results
                        integer p;
                        for (p = 0; p < 8; p = p + 1) begin
                            C_mem[ci * dim_n + cj_block + p] <= pe_acc[p];
                        end
                    end

                    // Advance to next column block or row
                    if (cj_block + 8 >= dim_n) begin
                        cj_block <= 0;
                        if (ci + 1 >= dim_m) begin
                            // All done
                            send_cnt <= 0;
                            send_total <= dim_m * dim_n;
                            fsm_state <= FSM_SEND_C;
                        end else begin
                            ci <= ci + 1;
                            pe_clear <= 1;
                            fsm_state <= FSM_CLEAR_PE;
                        end
                    end else begin
                        cj_block <= cj_block + 8;
                        pe_clear <= 1;
                        fsm_state <= FSM_CLEAR_PE;
                    end
                end

                FSM_SEND_C: begin
                    pe_enable <= 0;
                    m_axis_tdata  <= C_mem[send_cnt];
                    m_axis_tvalid <= 1;
                    m_axis_tlast  <= (send_cnt == send_total - 1) ? 1'b1 : 1'b0;
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (send_cnt == send_total - 1) begin
                            m_axis_tvalid <= 0; m_axis_tlast <= 0;
                            fsm_state <= FSM_DONE;
                        end else
                            send_cnt <= send_cnt + 1;
                    end
                end

                FSM_DONE: begin
                    m_axis_tvalid <= 0;
                    reg_status <= 32'd1;
                    fsm_state <= FSM_IDLE;
                end
            endcase
        end
    end

endmodule

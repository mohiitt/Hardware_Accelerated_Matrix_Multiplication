/*
 * Phase 9: Matrix Multiply Accelerator Top Module
 *
 * Combines AXI-Lite (control registers) + AXI-Stream (data I/O).
 * FSM: IDLE → LOAD_A → LOAD_B → COMPUTE → SEND_C → DONE
 *
 * Supports matrices up to 16x16 with internal BRAM.
 * For larger matrices, increase MEM_DEPTH parameter.
 *
 * AXI-Lite Registers:
 *   0x00 CTRL    - bit 0: start (write)
 *   0x04 STATUS  - bit 0: done, bit 1: busy (read)
 *   0x08 DIM_M   - M dimension (write)
 *   0x0C DIM_K   - K dimension (write)
 *   0x10 DIM_N   - N dimension (write)
 *   0x14 RESULT  - debug/checksum (read)
 *
 * AXI-Stream Input (32-bit):
 *   First M*K/4 words: A matrix (int8 packed, 4 per word)
 *   Next  K*N/4 words: B matrix (int8 packed, 4 per word)
 *
 * AXI-Stream Output (32-bit):
 *   M*N words: C matrix (int32, one per word, row-major)
 */
module matrix_accel_top #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5,  // 6 regs * 4 bytes = need 5 bits
    parameter integer AXIS_DATA_WIDTH    = 32,
    parameter integer MAX_DIM            = 16   // max matrix dimension
)(
    // AXI-Lite Slave Interface
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

    // AXI-Stream Slave (input data from DMA MM2S)
    input  wire [AXIS_DATA_WIDTH-1:0]          s_axis_tdata,
    input  wire                                s_axis_tvalid,
    output reg                                 s_axis_tready,
    input  wire                                s_axis_tlast,

    // AXI-Stream Master (output data to DMA S2MM)
    output reg  [AXIS_DATA_WIDTH-1:0]          m_axis_tdata,
    output reg                                 m_axis_tvalid,
    input  wire                                m_axis_tready,
    output reg                                 m_axis_tlast
);

    // ========== AXI-Lite Registers ==========
    reg [31:0] reg_ctrl;     // 0x00
    reg [31:0] reg_status;   // 0x04
    reg [31:0] reg_m;        // 0x08
    reg [31:0] reg_k;        // 0x0C
    reg [31:0] reg_n;        // 0x10
    reg [31:0] reg_result;   // 0x14

    // AXI-Lite write logic
    reg aw_ready_r, w_ready_r;
    reg [C_S_AXI_ADDR_WIDTH-1:0] aw_addr;
    wire aw_w_valid = s_axi_awvalid && s_axi_wvalid;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0;
            s_axi_wready  <= 0;
            s_axi_bvalid  <= 0;
            s_axi_bresp   <= 0;
            reg_ctrl <= 0;
            reg_m <= 0; reg_k <= 0; reg_n <= 0;
        end else begin
            // Default
            s_axi_awready <= 0;
            s_axi_wready  <= 0;

            // Write address + data handshake
            if (aw_w_valid && !s_axi_awready) begin
                s_axi_awready <= 1;
                s_axi_wready  <= 1;
                aw_addr <= s_axi_awaddr;

                case (s_axi_awaddr[4:2])
                    3'h0: reg_ctrl <= s_axi_wdata;  // CTRL
                    // 3'h1: STATUS is read-only
                    3'h2: reg_m    <= s_axi_wdata;
                    3'h3: reg_k    <= s_axi_wdata;
                    3'h4: reg_n    <= s_axi_wdata;
                    // 3'h5: RESULT is read-only
                endcase
            end

            // Write response
            if (s_axi_awready && s_axi_wready && !s_axi_bvalid) begin
                s_axi_bvalid <= 1;
                s_axi_bresp  <= 2'b00; // OKAY
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 0;
        end
    end

    // AXI-Lite read logic
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 0;
            s_axi_rvalid  <= 0;
            s_axi_rresp   <= 0;
            s_axi_rdata   <= 0;
        end else begin
            s_axi_arready <= 0;

            if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
                s_axi_arready <= 1;
                s_axi_rvalid  <= 1;
                s_axi_rresp   <= 2'b00;

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

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 0;
        end
    end

    // ========== Computation Core ==========

    // Internal memories
    reg signed [7:0]  A_mem [0:MAX_DIM*MAX_DIM-1];
    reg signed [7:0]  B_mem [0:MAX_DIM*MAX_DIM-1];
    reg signed [31:0] C_mem [0:MAX_DIM*MAX_DIM-1];

    // Dimension registers (latched at start)
    reg [7:0] dim_m, dim_k, dim_n;

    // FSM states
    localparam FSM_IDLE    = 3'd0;
    localparam FSM_LOAD_A  = 3'd1;
    localparam FSM_LOAD_B  = 3'd2;
    localparam FSM_COMPUTE = 3'd3;
    localparam FSM_SEND_C  = 3'd4;
    localparam FSM_DONE    = 3'd5;

    reg [2:0] fsm_state;

    // Counters
    reg [15:0] load_byte_cnt;  // byte counter for loading
    reg [15:0] load_word_cnt;  // word counter for loading
    reg [15:0] load_total_bytes;
    reg [7:0]  ci, cj, ck;    // compute loop counters
    reg [15:0] send_cnt;       // send counter
    reg [15:0] send_total;

    // Start pulse detection
    reg start_prev;
    wire start_pulse = reg_ctrl[0] & ~start_prev;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn)
            start_prev <= 0;
        else
            start_prev <= reg_ctrl[0];
    end

    // Direct accumulator (avoids PE registered-output timing issues)
    reg signed [31:0] acc;

    // Temporary register for stream data unpacking
    reg [31:0] stream_word;

    // Main FSM
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            fsm_state      <= FSM_IDLE;
            reg_status     <= 0;
            reg_result     <= 0;
            s_axis_tready  <= 0;
            m_axis_tdata   <= 0;
            m_axis_tvalid  <= 0;
            m_axis_tlast   <= 0;
            acc            <= 0;
            load_byte_cnt  <= 0;
            load_word_cnt  <= 0;
            ci <= 0; cj <= 0; ck <= 0;
            send_cnt       <= 0;
        end else begin

            case (fsm_state)
                // --------------------------------------------------
                FSM_IDLE: begin
                    s_axis_tready <= 0;
                    m_axis_tvalid <= 0;
                    m_axis_tlast  <= 0;

                    if (start_pulse) begin
                        dim_m <= reg_m[7:0];
                        dim_k <= reg_k[7:0];
                        dim_n <= reg_n[7:0];
                        reg_status <= 32'd2; // busy
                        load_byte_cnt <= 0;
                        load_word_cnt <= 0;
                        load_total_bytes <= reg_m[7:0] * reg_k[7:0];
                        fsm_state <= FSM_LOAD_A;
                        s_axis_tready <= 1;
                    end
                end

                // --------------------------------------------------
                FSM_LOAD_A: begin
                    s_axis_tready <= 1;
                    if (s_axis_tvalid && s_axis_tready) begin
                        // Unpack 4 bytes from 32-bit word
                        A_mem[load_byte_cnt + 0] <= $signed(s_axis_tdata[ 7: 0]);
                        if (load_byte_cnt + 1 < load_total_bytes)
                            A_mem[load_byte_cnt + 1] <= $signed(s_axis_tdata[15: 8]);
                        if (load_byte_cnt + 2 < load_total_bytes)
                            A_mem[load_byte_cnt + 2] <= $signed(s_axis_tdata[23:16]);
                        if (load_byte_cnt + 3 < load_total_bytes)
                            A_mem[load_byte_cnt + 3] <= $signed(s_axis_tdata[31:24]);

                        load_byte_cnt <= load_byte_cnt + 4;

                        if (load_byte_cnt + 4 >= load_total_bytes) begin
                            // Done loading A, prepare for B
                            load_byte_cnt <= 0;
                            load_total_bytes <= dim_k * dim_n;
                            fsm_state <= FSM_LOAD_B;
                        end
                    end
                end

                // --------------------------------------------------
                FSM_LOAD_B: begin
                    s_axis_tready <= 1;
                    if (s_axis_tvalid && s_axis_tready) begin
                        B_mem[load_byte_cnt + 0] <= $signed(s_axis_tdata[ 7: 0]);
                        if (load_byte_cnt + 1 < load_total_bytes)
                            B_mem[load_byte_cnt + 1] <= $signed(s_axis_tdata[15: 8]);
                        if (load_byte_cnt + 2 < load_total_bytes)
                            B_mem[load_byte_cnt + 2] <= $signed(s_axis_tdata[23:16]);
                        if (load_byte_cnt + 3 < load_total_bytes)
                            B_mem[load_byte_cnt + 3] <= $signed(s_axis_tdata[31:24]);

                        load_byte_cnt <= load_byte_cnt + 4;

                        if (load_byte_cnt + 4 >= load_total_bytes) begin
                            s_axis_tready <= 0;
                            ci <= 0; cj <= 0; ck <= 0;
                            acc <= 0;
                            fsm_state <= FSM_COMPUTE;
                        end
                    end
                end

                // --------------------------------------------------
                FSM_COMPUTE: begin
                    s_axis_tready <= 0;

                    // Direct multiply-accumulate (combinational multiply, registered accumulate)
                    acc <= acc + A_mem[ci * dim_k + ck] * B_mem[ck * dim_n + cj];

                    if (ck == dim_k - 1) begin
                        // Store result: acc has sum through k-1, this cycle adds k
                        // Since acc is registered, we compute the final value combinationally
                        C_mem[ci * dim_n + cj] <= acc + A_mem[ci * dim_k + ck] * B_mem[ck * dim_n + cj];
                        ck <= 0;
                        acc <= 0;

                        if (cj == dim_n - 1) begin
                            cj <= 0;
                            if (ci == dim_m - 1) begin
                                // All done
                                send_cnt  <= 0;
                                send_total <= dim_m * dim_n;
                                fsm_state <= FSM_SEND_C;
                            end else begin
                                ci <= ci + 1;
                            end
                        end else begin
                            cj <= cj + 1;
                        end
                    end else begin
                        ck <= ck + 1;
                    end
                end

                // --------------------------------------------------
                // --------------------------------------------------
                FSM_SEND_C: begin
                    m_axis_tdata  <= C_mem[send_cnt];
                    m_axis_tvalid <= 1;
                    m_axis_tlast  <= (send_cnt == send_total - 1) ? 1'b1 : 1'b0;

                    if (m_axis_tvalid && m_axis_tready) begin
                        // This word was accepted. Move to next.
                        if (send_cnt == send_total - 1) begin
                            m_axis_tvalid <= 0;
                            m_axis_tlast  <= 0;
                            fsm_state <= FSM_DONE;
                        end else begin
                            send_cnt <= send_cnt + 1;
                            // Pre-load next word for next cycle
                            m_axis_tdata <= C_mem[send_cnt + 1];
                            m_axis_tlast <= (send_cnt + 1 == send_total - 1) ? 1'b1 : 1'b0;
                        end
                    end
                end

                // --------------------------------------------------
                FSM_DONE: begin
                    m_axis_tvalid <= 0;
                    reg_status <= 32'd1; // done
                    fsm_state  <= FSM_IDLE;
                end
            endcase
        end
    end

endmodule

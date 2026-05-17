`timescale 1 ns / 1 ps

/*
 * ============================================================================
 * Module Name:  matrix_accel_v1_0_S00_AXI
 * Project:      Hardware-Accelerated Matrix Multiplication
 * Description:  The core computational and AXI interface engine.
 *               This block manages:
 *                 1. AXI4-Lite registers for configuration and flow control.
 *                 2. 64-bit AXI-Stream loading/storing interface.
 *                 3. Ping-pong double-buffering (A0/A1 and B0/B1 memories) in BRAM.
 *                 4. Banked BRAM organization (8 banks of B and C memories) to 
 *                    support 8 parallel Processing Elements (PEs) or columns.
 *                 5. An independent background prefetch loader FSM that fetches the
 *                    next K-tile from DDR via AXI DMA concurrently with MAC execution.
 *                 6. A 64-bit fast dual-read output FSM that merges two 32-bit outputs
 *                    into a single 64-bit stream transfer to maximize bus efficiency.
 * ============================================================================
 */
module matrix_accel_v1_0_S00_AXI #
(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)
(
    // AXI-Lite ports for register access
    input wire S_AXI_ACLK,
    input wire S_AXI_ARESETN,

    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
    input wire [2 : 0] S_AXI_AWPROT,
    input wire S_AXI_AWVALID,
    output wire S_AXI_AWREADY,

    input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
    input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
    input wire S_AXI_WVALID,
    output wire S_AXI_WREADY,

    output wire [1 : 0] S_AXI_BRESP,
    output wire S_AXI_BVALID,
    input wire S_AXI_BREADY,

    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
    input wire [2 : 0] S_AXI_ARPROT,
    input wire S_AXI_ARVALID,
    output wire S_AXI_ARREADY,

    output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
    output wire [1 : 0] S_AXI_RRESP,
    output wire S_AXI_RVALID,
    input wire S_AXI_RREADY,

    // AXI-Stream slave ports: Receive packed inputs (8 x int8 elements per 64-bit beat)
    input wire [63:0] s_axis_tdata,
    input wire        s_axis_tvalid,
    output wire       s_axis_tready,
    input wire        s_axis_tlast,

    // AXI-Stream master ports: Stream out packed results (2 x int32 elements per 64-bit beat)
    output wire [63:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input wire         m_axis_tready,
    output wire        m_axis_tlast
);

    // Address Decode LSBs (for 32-bit register alignment)
    localparam ADDR_LSB = 2;
    localparam OPT_MEM_ADDR_BITS = 2;

    // Architectural Dimensions & Sizing Constants
    localparam DIM = 32;          // Tile dimension size (32x32 elements)
    localparam MATRIX_WORDS = 128;// Number of 64-bit words per 32x32 int8 tile (1024 bytes / 8 bytes)
    localparam OUT_WORDS = 512;   // Number of 64-bit words per 32x32 int32 output tile (4096 bytes / 8 bytes)
    localparam C_BANK_DEPTH = 128;// Depth of each banked BRAM memory (1024 elements / 8 banks)

    // FSM State Definitions
    localparam ST_IDLE          = 5'd0; // Wait for start pulse from PS
    localparam ST_CLEAR_C       = 5'd1; // Zero out C accumulator memories
    localparam ST_LOAD_A_WAIT   = 5'd2; // Wait for incoming AXI-Stream word for tile A
    localparam ST_LOAD_A_WRITE  = 5'd3; // Unpack and write A bytes into BRAM
    localparam ST_LOAD_B_WAIT   = 5'd4; // Wait for incoming AXI-Stream word for tile B
    localparam ST_LOAD_B_WRITE  = 5'd5; // Unpack and write B bytes into banked BRAMs
    localparam ST_COMPUTE_INIT  = 5'd6; // Initialize hardware accumulators for the MAC iteration
    localparam ST_COMPUTE_ADDR  = 5'd7; // Setup read addresses for BRAMs A and B
    localparam ST_COMPUTE_WAIT  = 5'd8; // Wait 1 cycle for BRAM read latency (address latching)
    localparam ST_COMPUTE_MAC   = 5'd9; // Perform 8 parallel multiply-accumulates (MAC)
    localparam ST_STORE_ADDR    = 5'd10;// Setup address to load current partial C value from BRAM
    localparam ST_STORE_WAIT    = 5'd11;// Wait 1 cycle for C BRAM read latency
    localparam ST_STORE_C       = 5'd12;// Accumulate MAC results with prior partials and write back
    localparam ST_NEXT_BLOCK    = 5'd13;// Transition column/row indices, or proceed to next K-tile/done
    localparam ST_SEND_ADDR0    = 5'd14;// Setup read address for low 32-bit element of the 64-bit stream beat
    localparam ST_SEND_WAIT0    = 5'd15;// Wait 1 cycle for low element read latency
    localparam ST_SEND_LATCH0   = 5'd16;// Latch the low 32-bit output element
    localparam ST_SEND_ADDR1    = 5'd17;// Setup read address for high 32-bit element of the 64-bit stream beat
    localparam ST_SEND_WAIT1    = 5'd18;// Wait 1 cycle for high element read latency
    localparam ST_SEND_LATCH1   = 5'd19;// Latch and concatenate low/high elements into the 64-bit output register
    localparam ST_SEND_DATA     = 5'd20;// Handshake with AXI-Stream Master interface to output results
    localparam ST_DONE          = 5'd21;// Indicate completion to the PS
    localparam ST_WAIT_PREFETCH = 5'd22;// Wait state if MAC computation finishes before next prefetch load completes

    // AXI-Lite Internal Registers & Handshake Signals
    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_awaddr;
    reg axi_awready;
    reg axi_wready;
    reg [1 : 0] axi_bresp;
    reg axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_araddr;
    reg axi_arready;
    reg [C_S_AXI_DATA_WIDTH-1 : 0] axi_rdata;
    reg [1 : 0] axi_rresp;
    reg axi_rvalid;
    reg aw_en;

    // Registers mapped to AXI-Lite offsets
    reg [31:0] slv_reg0; // CTRL register: bit 0 is Start, bit 1 is Reset
    reg [31:0] slv_reg1; // STATUS register: bit 0 is Done, bit 1 is Busy
    reg [31:0] slv_reg2; // DIM_M register
    reg [31:0] slv_reg3; // DIM_K register
    reg [31:0] slv_reg4; // DIM_N register
    reg [31:0] slv_reg5; // REG_NUM_KTILES: Total number of K-tiles to process in hardware

    wire slv_reg_wren;
    wire slv_reg_rden;
    reg [31:0] reg_data_out;
    integer byte_index;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    assign slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;
    assign slv_reg_rden = axi_arready && S_AXI_ARVALID && ~axi_rvalid;

    // Detect when Start pulse (writing bit 0 of register 0) is written
    wire start_pulse =
        slv_reg_wren &&
        (axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h0) &&
        S_AXI_WDATA[0];

    // ============================================================================
    // Memory Buffers & Storage Layout
    // ============================================================================

    // Double-buffered A-tile memory (1KB each, stores 32x32 int8 elements)
    (* ram_style = "block" *) reg signed [7:0] A0_mem [0:1023];
    (* ram_style = "block" *) reg signed [7:0] A1_mem [0:1023];

    // Double-buffered B-tile memory partitioned into 8 parallel BRAM banks (B0_x to B7_x).
    // Bank assignment is mapped as (Column % 8). This structure enables reading 8 consecutive
    // columns of B (a single element per bank) in a single clock cycle to feed the 8 MAC units.
    (* ram_style = "block" *) reg signed [7:0] B0_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B1_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B2_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B3_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B4_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B5_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B6_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B7_0_mem [0:C_BANK_DEPTH-1];

    (* ram_style = "block" *) reg signed [7:0] B0_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B1_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B2_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B3_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B4_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B5_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B6_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B7_1_mem [0:C_BANK_DEPTH-1];

    // Banked C output accumulator memory (8 banks, 128 x 32-bit words each).
    // Stores partial accumulations in int32 to prevent overflows during nested MAC sums.
    (* ram_style = "block" *) reg signed [31:0] C0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C2_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C3_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C4_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C5_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C6_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C7_mem [0:C_BANK_DEPTH-1];

    reg [4:0] state;

    // Buffer selectors to manage ping-pong buffer swaps
    reg load_buf_sel;       // Buffer currently being written by main loader
    reg compute_buf_sel;    // Buffer currently being read by MAC engine

    // Background Prefetcher registers
    reg bg_load_active;     // High when background prefetcher is loading stream data
    reg bg_word_valid;      // High when a 64-bit word is fetched and being unpacked byte-by-byte
    reg bg_phase;           // 0 = Loading A-tile, 1 = Loading B-tile
    reg bg_load_buf_sel;    // Ping-pong buffer index targeted by prefetcher
    reg bg_next_ready;      // High when next K-tile is fully loaded and ready for compute
    reg [8:0] bg_word_count;// Counter of 64-bit words processed by prefetcher
    reg [2:0] bg_byte_count;// Index of byte (0-7) unpacked from current 64-bit word
    reg [63:0] bg_word_reg; // Temporary register holding prefetched 64-bit stream word

    // Main Stream Loader registers
    reg [8:0] load_word_count;
    reg [2:0] load_byte_count;
    reg [63:0] load_word_reg;

    reg [6:0] clear_addr;

    // Computational loop index trackers
    reg [4:0] i_count;  // Iterates rows (0 to 31)
    reg [4:0] j_base;   // Iterates columns in blocks of 8 (0, 8, 16, 24)
    reg [4:0] k_count;  // Iterates inner K dimension (0 to 31)

    reg [7:0] num_ktiles;  // Configured total K-tiles
    reg [7:0] ktile_count; // Tracks current K-tile under computation

    reg [8:0] send_count;

    // Address and data latches for BRAM accesses
    reg [9:0] a_rd_addr;
    reg [6:0] b_rd_addr;
    reg [6:0] c_rd_addr;
    reg [2:0] c_rd_bank;

    reg signed [7:0] a_dout;
    reg signed [7:0] b0_dout;
    reg signed [7:0] b1_dout;
    reg signed [7:0] b2_dout;
    reg signed [7:0] b3_dout;
    reg signed [7:0] b4_dout;
    reg signed [7:0] b5_dout;
    reg signed [7:0] b6_dout;
    reg signed [7:0] b7_dout;

    reg signed [31:0] c0_dout;
    reg signed [31:0] c1_dout;
    reg signed [31:0] c2_dout;
    reg signed [31:0] c3_dout;
    reg signed [31:0] c4_dout;
    reg signed [31:0] c5_dout;
    reg signed [31:0] c6_dout;
    reg signed [31:0] c7_dout;

    // Hardware Accumulators
    reg signed [31:0] acc0;
    reg signed [31:0] acc1;
    reg signed [31:0] acc2;
    reg signed [31:0] acc3;
    reg signed [31:0] acc4;
    reg signed [31:0] acc5;
    reg signed [31:0] acc6;
    reg signed [31:0] acc7;

    // Output Packing registers
    reg [31:0] send_lo_reg;
    reg [31:0] send_hi_reg;
    reg [63:0] m_axis_tdata_reg;
    reg m_axis_tvalid_reg;
    reg m_axis_tlast_reg;

    assign m_axis_tdata  = m_axis_tdata_reg;
    assign m_axis_tvalid = m_axis_tvalid_reg;
    assign m_axis_tlast  = m_axis_tlast_reg;

    // Stream Handshake Conditionals
    wire main_axis_ready =
        (state == ST_LOAD_A_WAIT) ||
        (state == ST_LOAD_B_WAIT);

    wire bg_axis_ready = bg_load_active && !bg_word_valid && !main_axis_ready;

    assign s_axis_tready = main_axis_ready || bg_axis_ready;

    wire s_fire = s_axis_tvalid && main_axis_ready;
    wire bg_fire = s_axis_tvalid && bg_axis_ready;
    wire m_fire = m_axis_tvalid && m_axis_tready;

    // Byte address calculation helpers for main stream unpack
    wire [11:0] load_byte_addr_wide = {load_word_count, 3'b000} + load_byte_count;
    wire [9:0] load_byte_addr = load_byte_addr_wide[9:0];

    // Byte address calculation helpers for background prefetch stream unpack
    wire [11:0] bg_byte_addr_wide = {bg_word_count, 3'b000} + bg_byte_count;
    wire [9:0] bg_byte_addr = bg_byte_addr_wide[9:0];

    // Bank and sub-address mapping for B background prefetch
    wire [4:0] bg_b_load_row  = bg_byte_addr[9:5];
    wire [4:0] bg_b_load_col  = bg_byte_addr[4:0];
    wire [2:0] bg_b_load_bank = bg_b_load_col[2:0];
    wire [6:0] bg_b_load_addr = {bg_b_load_row, bg_b_load_col[4:3]};

    // Bank and sub-address mapping for B main stream loader
    wire [4:0] b_load_row  = load_byte_addr[9:5];
    wire [4:0] b_load_col  = load_byte_addr[4:0];
    wire [2:0] b_load_bank = b_load_col[2:0];
    wire [6:0] b_load_addr = {b_load_row, b_load_col[4:3]};

    // Memory address helpers during MAC compute and store cycles
    wire [6:0] c_store_addr   = {i_count, j_base[4:3]};
    wire [6:0] b_compute_addr = {k_count, j_base[4:3]};

    // Dual-element address tracking for fast 64-bit output packing FSM
    wire [9:0] send_elem0 = {send_count, 1'b0};
    wire [9:0] send_elem1 = {send_count, 1'b0} + 10'd1;

    wire [6:0] send_addr0 = {send_elem0[9:5], send_elem0[4:3]};
    wire [2:0] send_bank0 = send_elem0[2:0];
    wire [6:0] send_addr1 = {send_elem1[9:5], send_elem1[4:3]};
    wire [2:0] send_bank1 = send_elem1[2:0];

    // Helper function to extract a targeted byte out of a 64-bit word
    function signed [7:0] selected_byte;
        input [63:0] word;
        input [2:0] index;
        begin
            case (index)
                3'd0: selected_byte = word[7:0];
                3'd1: selected_byte = word[15:8];
                3'd2: selected_byte = word[23:16];
                3'd3: selected_byte = word[31:24];
                3'd4: selected_byte = word[39:32];
                3'd5: selected_byte = word[47:40];
                3'd6: selected_byte = word[55:48];
                default: selected_byte = word[63:56];
            endcase
        end
    endfunction

    // Helper function to mux output registers (C0-C7) based on bank index
    function [31:0] selected_c;
        input [2:0] bank;
        begin
            case (bank)
                3'd0: selected_c = c0_dout;
                3'd1: selected_c = c1_dout;
                3'd2: selected_c = c2_dout;
                3'd3: selected_c = c3_dout;
                3'd4: selected_c = c4_dout;
                3'd5: selected_c = c5_dout;
                3'd6: selected_c = c6_dout;
                default: selected_c = c7_dout;
            endcase
        end
    endfunction

    // Dual-port synchronous BRAM read block with 1 cycle address latch latency
    always @(posedge S_AXI_ACLK) begin
        if (compute_buf_sel == 1'b0) begin
            a_dout <= A0_mem[a_rd_addr];

            b0_dout <= B0_0_mem[b_rd_addr];
            b1_dout <= B1_0_mem[b_rd_addr];
            b2_dout <= B2_0_mem[b_rd_addr];
            b3_dout <= B3_0_mem[b_rd_addr];
            b4_dout <= B4_0_mem[b_rd_addr];
            b5_dout <= B5_0_mem[b_rd_addr];
            b6_dout <= B6_0_mem[b_rd_addr];
            b7_dout <= B7_0_mem[b_rd_addr];
        end else begin
            a_dout <= A1_mem[a_rd_addr];

            b0_dout <= B0_1_mem[b_rd_addr];
            b1_dout <= B1_1_mem[b_rd_addr];
            b2_dout <= B2_1_mem[b_rd_addr];
            b3_dout <= B3_1_mem[b_rd_addr];
            b4_dout <= B4_1_mem[b_rd_addr];
            b5_dout <= B5_1_mem[b_rd_addr];
            b6_dout <= B6_1_mem[b_rd_addr];
            b7_dout <= B7_1_mem[b_rd_addr];
        end

        c0_dout <= C0_mem[c_rd_addr];
        c1_dout <= C1_mem[c_rd_addr];
        c2_dout <= C2_mem[c_rd_addr];
        c3_dout <= C3_mem[c_rd_addr];
        c4_dout <= C4_mem[c_rd_addr];
        c5_dout <= C5_mem[c_rd_addr];
        c6_dout <= C6_mem[c_rd_addr];
        c7_dout <= C7_mem[c_rd_addr];
    end

    // Core Control FSM and Memory Processing Loop
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            state <= ST_IDLE;

            load_word_count <= 0;
            load_byte_count <= 0;
            load_word_reg <= 0;
            clear_addr <= 0;

            i_count <= 0;
            j_base <= 0;
            k_count <= 0;

            ktile_count <= 0;
            num_ktiles <= 1;

            send_count <= 0;

            a_rd_addr <= 0;
            b_rd_addr <= 0;
            c_rd_addr <= 0;
            c_rd_bank <= 0;

            acc0 <= 0;
            acc1 <= 0;
            acc2 <= 0;
            acc3 <= 0;
            acc4 <= 0;
            acc5 <= 0;
            acc6 <= 0;
            acc7 <= 0;

            send_lo_reg <= 0;
            send_hi_reg <= 0;
            m_axis_tdata_reg <= 0;
            m_axis_tvalid_reg <= 0;
            m_axis_tlast_reg <= 0;

            load_buf_sel <= 1'b0;
            compute_buf_sel <= 1'b0;

            bg_load_active <= 1'b0;
            bg_word_valid <= 1'b0;
            bg_phase <= 1'b0;
            bg_load_buf_sel <= 1'b1;
            bg_next_ready <= 1'b0;
            bg_word_count <= 0;
            bg_byte_count <= 0;
            bg_word_reg <= 0;

            slv_reg1 <= 32'd0;
        end else begin

            // ============================================================================
            // Background Prefetch Loader (Phase 17B Overlapped Execution)
            // ============================================================================
            // While the MAC pipeline (compute) is chewing through the current tile pair in
            // memory (e.g. A0/B0), this independent loader works in the background to grab
            // the next K-tile pair (A1/B1) over AXI-Stream. Once the compute FSM finishes,
            // it can swap buffers immediately without waiting on DMA loading!
            if (bg_fire) begin
                bg_word_reg <= s_axis_tdata;
                bg_word_valid <= 1'b1;
                bg_byte_count <= 0;
            end else if (bg_word_valid) begin
                if (bg_phase == 1'b0) begin
                    if (bg_load_buf_sel == 1'b0)
                        A0_mem[bg_byte_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                    else
                        A1_mem[bg_byte_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                end else begin
                    if (bg_load_buf_sel == 1'b0) begin
                        case (bg_b_load_bank)
                            3'd0: B0_0_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd1: B1_0_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd2: B2_0_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd3: B3_0_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd4: B4_0_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd5: B5_0_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd6: B6_0_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            default: B7_0_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                        endcase
                    end else begin
                        case (bg_b_load_bank)
                            3'd0: B0_1_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd1: B1_1_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd2: B2_1_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd3: B3_1_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd4: B4_1_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd5: B5_1_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            3'd6: B6_1_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                            default: B7_1_mem[bg_b_load_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                        endcase
                    end
                end

                if (bg_byte_count == 3'd7) begin
                    bg_byte_count <= 0;
                    bg_word_valid <= 1'b0;

                    if (bg_word_count == MATRIX_WORDS - 1) begin
                        bg_word_count <= 0;

                        if (bg_phase == 1'b0) begin
                            bg_phase <= 1'b1; // Switch from loading A to B
                        end else begin
                            bg_phase <= 1'b0;
                            bg_load_active <= 1'b0;
                            bg_next_ready <= 1'b1; // Signal that the prefetched tile is ready
                        end
                    end else begin
                        bg_word_count <= bg_word_count + 1'b1;
                    end
                end else begin
                    bg_byte_count <= bg_byte_count + 1'b1;
                end
            end

            // ============================================================================
            // Core FSM Execution Path
            // ============================================================================
            case (state)

                ST_IDLE: begin
                    m_axis_tvalid_reg <= 1'b0;
                    m_axis_tlast_reg <= 1'b0;

                    if (start_pulse) begin
                        slv_reg1 <= 32'd2; // Set BUSY state
                        load_word_count <= 0;
                        load_byte_count <= 0;
                        clear_addr <= 0;
                        i_count <= 0;
                        j_base <= 0;
                        k_count <= 0;
                        ktile_count <= 0;
                        num_ktiles <= (slv_reg5[7:0] == 0) ? 8'd1 : slv_reg5[7:0];
                        send_count <= 0;

                        load_buf_sel <= 1'b0;
                        compute_buf_sel <= 1'b0;
                        bg_load_active <= 1'b0;
                        bg_word_valid <= 1'b0;
                        bg_phase <= 1'b0;
                        bg_load_buf_sel <= 1'b1;
                        bg_next_ready <= 1'b0;
                        bg_word_count <= 0;
                        bg_byte_count <= 0;
                        bg_word_reg <= 0;

                        state <= ST_CLEAR_C;
                    end
                end

                ST_CLEAR_C: begin
                    // Zero out the C accumulator memories (partial sums) at start.
                    C0_mem[clear_addr] <= 32'sd0;
                    C1_mem[clear_addr] <= 32'sd0;
                    C2_mem[clear_addr] <= 32'sd0;
                    C3_mem[clear_addr] <= 32'sd0;
                    C4_mem[clear_addr] <= 32'sd0;
                    C5_mem[clear_addr] <= 32'sd0;
                    C6_mem[clear_addr] <= 32'sd0;
                    C7_mem[clear_addr] <= 32'sd0;

                    if (clear_addr == C_BANK_DEPTH - 1) begin
                        clear_addr <= 0;
                        load_word_count <= 0;
                        load_byte_count <= 0;
                        state <= ST_LOAD_A_WAIT;
                    end else begin
                        clear_addr <= clear_addr + 1'b1;
                    end
                end

                ST_LOAD_A_WAIT: begin
                    // First K-tile A buffer load sequence (Initial Load)
                    if (s_fire) begin
                        load_word_reg <= s_axis_tdata;
                        load_byte_count <= 0;
                        state <= ST_LOAD_A_WRITE;
                    end
                end

                ST_LOAD_A_WRITE: begin
                    if (load_buf_sel == 1'b0)
                        A0_mem[load_byte_addr] <= selected_byte(load_word_reg, load_byte_count);
                    else
                        A1_mem[load_byte_addr] <= selected_byte(load_word_reg, load_byte_count);

                    if (load_byte_count == 3'd7) begin
                        load_byte_count <= 0;
                        if (load_word_count == MATRIX_WORDS - 1) begin
                            load_word_count <= 0;
                            state <= ST_LOAD_B_WAIT;
                        end else begin
                            load_word_count <= load_word_count + 1'b1;
                            state <= ST_LOAD_A_WAIT;
                        end
                    end else begin
                        load_byte_count <= load_byte_count + 1'b1;
                    end
                end

                ST_LOAD_B_WAIT: begin
                    // First K-tile B buffer load sequence (Initial Load)
                    if (s_fire) begin
                        load_word_reg <= s_axis_tdata;
                        load_byte_count <= 0;
                        state <= ST_LOAD_B_WRITE;
                    end
                end

                ST_LOAD_B_WRITE: begin
                    if (load_buf_sel == 1'b0) begin
                        case (b_load_bank)
                            3'd0: B0_0_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd1: B1_0_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd2: B2_0_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd3: B3_0_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd4: B4_0_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd5: B5_0_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd6: B6_0_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            default: B7_0_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                        endcase
                    end else begin
                        case (b_load_bank)
                            3'd0: B0_1_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd1: B1_1_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd2: B2_1_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd3: B3_1_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd4: B4_1_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd5: B5_1_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            3'd6: B6_1_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                            default: B7_1_mem[b_load_addr] <= selected_byte(load_word_reg, load_byte_count);
                        endcase
                    end

                    if (load_byte_count == 3'd7) begin
                        load_byte_count <= 0;
                        if (load_word_count == MATRIX_WORDS - 1) begin
                            load_word_count <= 0;
                            i_count <= 0;
                            j_base <= 0;

                            // Kick off the background loader to fetch next K-tile pair.
                            if ((ktile_count + 1'b1) < num_ktiles) begin
                                bg_load_active <= 1'b1;
                                bg_word_valid <= 1'b0;
                                bg_phase <= 1'b0;
                                bg_load_buf_sel <= ~load_buf_sel;
                                bg_next_ready <= 1'b0;
                                bg_word_count <= 0;
                                bg_byte_count <= 0;
                            end

                            state <= ST_COMPUTE_INIT;
                        end else begin
                            load_word_count <= load_word_count + 1'b1;
                            state <= ST_LOAD_B_WAIT;
                        end
                    end else begin
                        load_byte_count <= load_byte_count + 1'b1;
                    end
                end

                ST_COMPUTE_INIT: begin
                    acc0 <= 0;
                    acc1 <= 0;
                    acc2 <= 0;
                    acc3 <= 0;
                    acc4 <= 0;
                    acc5 <= 0;
                    acc6 <= 0;
                    acc7 <= 0;
                    k_count <= 0;
                    state <= ST_COMPUTE_ADDR;
                end

                ST_COMPUTE_ADDR: begin
                    a_rd_addr <= {i_count, 5'b00000} + k_count;
                    b_rd_addr <= b_compute_addr;
                    state <= ST_COMPUTE_WAIT;
                end

                ST_COMPUTE_WAIT: begin
                    state <= ST_COMPUTE_MAC; // Hold state to allow BRAM output lines to stabilize
                end

                ST_COMPUTE_MAC: begin
                    // 8-way parallel MAC array. Computes 8 columns in parallel.
                    acc0 <= acc0 + ($signed(a_dout) * $signed(b0_dout));
                    acc1 <= acc1 + ($signed(a_dout) * $signed(b1_dout));
                    acc2 <= acc2 + ($signed(a_dout) * $signed(b2_dout));
                    acc3 <= acc3 + ($signed(a_dout) * $signed(b3_dout));
                    acc4 <= acc4 + ($signed(a_dout) * $signed(b4_dout));
                    acc5 <= acc5 + ($signed(a_dout) * $signed(b5_dout));
                    acc6 <= acc6 + ($signed(a_dout) * $signed(b6_dout));
                    acc7 <= acc7 + ($signed(a_dout) * $signed(b7_dout));

                    if (k_count == DIM - 1) begin
                        state <= ST_STORE_ADDR;
                    end else begin
                        k_count <= k_count + 1'b1;
                        state <= ST_COMPUTE_ADDR;
                    end
                end

                ST_STORE_ADDR: begin
                    c_rd_addr <= c_store_addr;
                    state <= ST_STORE_WAIT;
                end

                ST_STORE_WAIT: begin
                    state <= ST_STORE_C; // Wait for old C partial value to read from BRAM
                end

                ST_STORE_C: begin
                    // Write back the accumulated sum (old C value + new inner product result)
                    C0_mem[c_store_addr] <= c0_dout + acc0;
                    C1_mem[c_store_addr] <= c1_dout + acc1;
                    C2_mem[c_store_addr] <= c2_dout + acc2;
                    C3_mem[c_store_addr] <= c3_dout + acc3;
                    C4_mem[c_store_addr] <= c4_dout + acc4;
                    C5_mem[c_store_addr] <= c5_dout + acc5;
                    C6_mem[c_store_addr] <= c6_dout + acc6;
                    C7_mem[c_store_addr] <= c7_dout + acc7;
                    state <= ST_NEXT_BLOCK;
                end

                ST_NEXT_BLOCK: begin
                    if (j_base == DIM - 8) begin
                        j_base <= 0;
                        if (i_count == DIM - 1) begin
                            // Check if this was the last K-tile of the outer block
                            if (ktile_count == num_ktiles - 1) begin
                                send_count <= 0;
                                state <= ST_SEND_ADDR0; // Shift to output stream FSM
                            end else begin
                                // Double Buffering Buffer Swap Control
                                if (bg_next_ready) begin
                                    ktile_count <= ktile_count + 1'b1;

                                    // Swap execution buffers immediately
                                    compute_buf_sel <= ~compute_buf_sel;
                                    load_buf_sel <= ~load_buf_sel;

                                    bg_next_ready <= 1'b0;

                                    // If there are more K-tiles left, launch the next background load
                                    if ((ktile_count + 8'd2) < num_ktiles) begin
                                        bg_load_active <= 1'b1;
                                        bg_word_valid <= 1'b0;
                                        bg_phase <= 1'b0;
                                        bg_load_buf_sel <= compute_buf_sel;
                                        bg_word_count <= 0;
                                        bg_byte_count <= 0;
                                    end

                                    load_word_count <= 0;
                                    load_byte_count <= 0;
                                    i_count <= 0;
                                    j_base <= 0;
                                    k_count <= 0;
                                    state <= ST_COMPUTE_INIT;
                                end else begin
                                    state <= ST_WAIT_PREFETCH; // Wait for background loader if slow
                                end
                            end
                        end else begin
                            i_count <= i_count + 1'b1;
                            state <= ST_COMPUTE_INIT;
                        end
                    end else begin
                        j_base <= j_base + 5'd8; // Advance column address by 8 banks
                        state <= ST_COMPUTE_INIT;
                    end
                end

                ST_WAIT_PREFETCH: begin
                    // Active wait for background prefetcher to signal completion
                    if (bg_next_ready) begin
                        ktile_count <= ktile_count + 1'b1;

                        compute_buf_sel <= ~compute_buf_sel;
                        load_buf_sel <= ~load_buf_sel;

                        bg_next_ready <= 1'b0;

                        if ((ktile_count + 8'd2) < num_ktiles) begin
                            bg_load_active <= 1'b1;
                            bg_word_valid <= 1'b0;
                            bg_phase <= 1'b0;
                            bg_load_buf_sel <= compute_buf_sel;
                            bg_word_count <= 0;
                            bg_byte_count <= 0;
                        end

                        load_word_count <= 0;
                        load_byte_count <= 0;
                        i_count <= 0;
                        j_base <= 0;
                        k_count <= 0;
                        state <= ST_COMPUTE_INIT;
                    end
                end

                // ============================================================================
                // Output Packing & Stream Out FSM (64-bit Master Stream)
                // ============================================================================
                // Read two consecutive 32-bit accumulated elements from banked C memory and
                // package them into a single 64-bit output stream word to double system throughput.
                ST_SEND_ADDR0: begin
                    c_rd_addr <= send_addr0;
                    c_rd_bank <= send_bank0;
                    state <= ST_SEND_WAIT0;
                end

                ST_SEND_WAIT0: begin
                    state <= ST_SEND_LATCH0;
                end

                ST_SEND_LATCH0: begin
                    send_lo_reg <= selected_c(c_rd_bank); // Latch lower 32-bit element
                    state <= ST_SEND_ADDR1;
                end

                ST_SEND_ADDR1: begin
                    c_rd_addr <= send_addr1;
                    c_rd_bank <= send_bank1;
                    state <= ST_SEND_WAIT1;
                end

                ST_SEND_WAIT1: begin
                    state <= ST_SEND_LATCH1;
                end

                ST_SEND_LATCH1: begin
                    send_hi_reg <= selected_c(c_rd_bank); // Latch upper 32-bit element
                    m_axis_tdata_reg <= {selected_c(c_rd_bank), send_lo_reg}; // Pack high + low
                    m_axis_tvalid_reg <= 1'b1;
                    m_axis_tlast_reg <= (send_count == OUT_WORDS - 1);
                    state <= ST_SEND_DATA;
                end

                ST_SEND_DATA: begin
                    if (m_fire) begin
                        m_axis_tvalid_reg <= 1'b0;
                        m_axis_tlast_reg <= 1'b0;
                        if (send_count == OUT_WORDS - 1) begin
                            state <= ST_DONE;
                        end else begin
                            send_count <= send_count + 1'b1;
                            state <= ST_SEND_ADDR0;
                        end
                    end
                end

                ST_DONE: begin
                    slv_reg1 <= 32'd1; // Flag Done status to AXI-Lite Status register
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end

            endcase
        end
    end

    // ============================================================================
    // Standard AXI-Lite Slave Interface Logic
    // ============================================================================
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            aw_en <= 1'b1;
        end else begin
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
                axi_awready <= 1'b1;
                aw_en <= 1'b0;
            end else if (S_AXI_BREADY && axi_bvalid) begin
                aw_en <= 1'b1;
                axi_awready <= 1'b0;
            end else begin
                axi_awready <= 1'b0;
            end
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awaddr <= 0;
        end else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
            axi_awaddr <= S_AXI_AWADDR;
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_wready <= 1'b0;
        end else begin
            if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en) begin
                axi_wready <= 1'b1;
            end else begin
                axi_wready <= 1'b0;
            end
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            slv_reg0 <= 0;
            slv_reg2 <= 0;
            slv_reg3 <= 0;
            slv_reg4 <= 0;
            slv_reg5 <= 1; // Default to 1 K-tile
        end else if (slv_reg_wren) begin
            case (axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB])
                3'h0: begin
                    for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                        if (S_AXI_WSTRB[byte_index])
                            slv_reg0[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                end
                3'h2: begin
                    for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                        if (S_AXI_WSTRB[byte_index])
                            slv_reg2[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                end
                3'h3: begin
                    for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                        if (S_AXI_WSTRB[byte_index])
                            slv_reg3[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                end
                3'h4: begin
                    for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                        if (S_AXI_WSTRB[byte_index])
                            slv_reg4[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                end
                3'h5: begin
                    for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                        if (S_AXI_WSTRB[byte_index])
                            slv_reg5[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                end
                default: begin
                end
            endcase
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_bvalid <= 0;
            axi_bresp <= 2'b0;
        end else begin
            if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
                axi_bvalid <= 1'b1;
                axi_bresp <= 2'b0;
            end else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_araddr <= 0;
        end else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                axi_araddr <= S_AXI_ARADDR;
            end else begin
                axi_arready <= 1'b0;
            end
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rvalid <= 0;
            axi_rresp <= 0;
        end else begin
            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp <= 2'b0;
            end else if (axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    always @(*) begin
        case (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB])
            3'h0: reg_data_out = slv_reg0;
            3'h1: reg_data_out = slv_reg1;
            3'h2: reg_data_out = slv_reg2;
            3'h3: reg_data_out = slv_reg3;
            3'h4: reg_data_out = slv_reg4;
            3'h5: reg_data_out = slv_reg5;
            default: reg_data_out = 0;
        endcase
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rdata <= 0;
        end else if (slv_reg_rden) begin
            axi_rdata <= reg_data_out;
        end
    end

endmodule

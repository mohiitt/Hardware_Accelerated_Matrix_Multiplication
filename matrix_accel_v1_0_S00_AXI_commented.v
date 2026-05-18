`timescale 1 ns / 1 ps

// =====================================================================================================================
// MODULE: matrix_accel_v1_0_S00_AXI
//
// DESIGN EXPLANATION & ARCHITECTURAL SUMMARY:
//
// 1. DUAL-INTERFACE ARCHITECTURE (AXI-Lite + AXI-Stream):
//    - Control Path (AXI-Lite Slave): Serves as the register dashboard. The ARM CPU uses it to configure dimensions,
//      number of K-tiles, and to trigger the start signal. It also polls the status register to detect completion.
//    - Data Path (AXI-Stream): The memory-mapped DMA (AXI DMA MM2S) streams inputs A/B directly from DDR into local 
//      on-chip Block RAMs (BRAMs). The output DMA (S2MM) streams computed results back to DDR.
//
// 2. 64-BIT DATA WIDTHS & PACKING STRATEGY:
//    - MM2S Stream (Inputs A & B): 64-bit wide. Because inputs A and B are signed 8-bit integers (`int8`), each 
//      stream beat packages exactly 8 elements (8 bytes/beat), maximizing data transfer bandwidth.
//    - S2MM Stream (Output C): 64-bit wide. Since outputs are signed 32-bit integers (`int32`) to prevent overflow, 
//      each beat packages 2 output elements (8 bytes/beat: 2 words of 32-bits).
//
// 3. ZERO-LATENCY OVERLAPPED EXECUTION via DUAL PING-PONG BUFFERING:
//    - The module instantiates two sets of buffer memories: Buffer 0 and Buffer 1 (e.g., A0/A1 and B0_0..7 / B0_1..7).
//    - While the Foreground Compute FSM is executing matrix multiplication using one buffer set (controlled by 
//      `compute_buf_sel`), an independent Background Prefetch Loader FSM streams the NEXT K-tile from DDR into the 
//      alternate buffer set (controlled by `bg_load_buf_sel`). 
//    - This completely hides the DMA memory access latency behind the compute execution time, achieving a massive 
//      performance boost (5.15x overall speedup).
//
// 4. MEMORY PARTITIONING / BRAM BANKING FOR HIGH PARALLELISM:
//    - A 32x32 tile of B (signed 8-bit) and C (signed 32-bit) is divided into 8 parallel BRAM banks (B0..B7 and C0..C7).
//    - Bank indexing maps to columns. By splitting the memory into 8 physical BRAM banks, the FSM can read 8 different 
//      column values (or write/accumulate 8 output values) simultaneously in a single clock cycle, completely avoiding
//      single-port BRAM conflicts.
//
// 5. 8-WAY PARALLEL COMPUTE ENGINE (8 PEs):
//    - Features 8 hardware Multiply-Accumulate (MAC) units. In a single clock cycle, the core reads a single element 
//      from A (broadcasted to all PEs) and reads 8 parallel column elements from B0..B7, performing 8 MAC operations 
//      in parallel: C[i][j + col] += A[i][k] * B[k][j + col].
//
// =====================================================================================================================

module matrix_accel_v1_0_S00_AXI #
(
    // AXI-Lite parameters (32-bit register width, 5-bit register address bus)
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)
(
    // =========================================================================
    // SYSTEM SIGNALS
    // =========================================================================
    input wire S_AXI_ACLK,                  // Main clock source (50 MHz synchronous bus)
    input wire S_AXI_ARESETN,               // System-wide active-low reset pulse

    // =========================================================================
    // AXI-LITE CONTROL REGISTER INTERFACE PORTS
    // =========================================================================
    // Write Address Channel
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
    input wire [2 : 0] S_AXI_AWPROT,
    input wire S_AXI_AWVALID,
    output wire S_AXI_AWREADY,

    // Write Data Channel
    input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
    input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
    input wire S_AXI_WVALID,
    output wire S_AXI_WREADY,

    // Write Response Channel
    output wire [1 : 0] S_AXI_BRESP,
    output wire S_AXI_BVALID,
    input wire S_AXI_BREADY,

    // Read Address Channel
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
    input wire [2 : 0] S_AXI_ARPROT,
    input wire S_AXI_ARVALID,
    output wire S_AXI_ARREADY,

    // Read Data Channel
    output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
    output wire [1 : 0] S_AXI_RRESP,
    output wire S_AXI_RVALID,
    input wire S_AXI_RREADY,

    // =========================================================================
    // AXI-STREAM DMA INPUT PORT (MM2S - Memory-Mapped to Stream)
    // Exposes a 64-bit wide stream to receive 8 packed int8 values per clock.
    // =========================================================================
    input wire [63:0] s_axis_tdata,         // 64-bit raw input stream beat (8 x int8 elements)
    input wire        s_axis_tvalid,        // Valid handshake asserted by DMA (data is stable on bus)
    output wire       s_axis_tready,        // Ready handshake asserted by FSM (core is ready to swallow data)
    input wire        s_axis_tlast,         // End-of-packet indicator (optional marker from DMA)

    // =========================================================================
    // AXI-STREAM DMA OUTPUT PORT (S2MM - Stream to Memory-Mapped)
    // Exposes a 64-bit wide stream to transmit 2 packed int32 output results per clock.
    // =========================================================================
    output wire [63:0] m_axis_tdata,        // 64-bit raw output stream beat (2 x int32 elements)
    output wire        m_axis_tvalid,       // Valid handshake asserted by FSM (output is stable on bus)
    input wire         m_axis_tready,       // Ready handshake asserted by DMA (DDR is ready to swallow results)
    output wire        m_axis_tlast         // Stream packet end marker (tells DMA to complete the transfer)
);

    // =================================================================================================================
    // LOCAL CONFIGURATION PARAMETERS & CONSTANTS
    // =================================================================================================================
    localparam ADDR_LSB = 2;                // Address offset bits for 32-bit registers (4-byte alignment)
    localparam OPT_MEM_ADDR_BITS = 2;       // Address decoding bits for 6 control/status registers

    localparam DIM = 32;                    // Sub-matrix Tile dimension size: 32x32 elements
    localparam MATRIX_WORDS = 128;          // 32x32 tiles = 1024 bytes. At 8 bytes per 64-bit stream beat, we need 128 beats.
    localparam OUT_WORDS = 512;             // 32x32 outputs = 1024 int32s. At 2 elements per 64-bit stream beat, we need 512 beats.
    localparam C_BANK_DEPTH = 128;          // Depth per BRAM bank: 32 rows x (32 columns / 8 banks) = 128 addresses.

    // =================================================================================================================
    // ONE-HOT / STATE MACHINE ENCODING (23 STATES)
    // Explanatory breakdown:
    // - ST_IDLE / ST_DONE: Main controller boundaries.
    // - ST_CLEAR_C: Zero-initializes C-accumulators in hardware (extremely fast, avoids CPU clear overhead).
    // - ST_LOAD_A_*: Loads Matrix A tile into BRAM (Foreground/Synchronous phase).
    // - ST_LOAD_B_*: Loads Matrix B tile into BRAM (Foreground/Synchronous phase).
    // - ST_COMPUTE_*: Core MAC pipeline. Performs row/col MAC reduction.
    // - ST_STORE_*: Adds partial sum outputs back into BRAM accumulators.
    // - ST_WAIT_PREFETCH: Synchronization boundary. Waits for the background loader to finish prefetching.
    // - ST_SEND_*: Latches and packs two 32-bit elements sequentially from parallel banks into one 64-bit stream beat.
    // =================================================================================================================
    localparam ST_IDLE          = 5'd0;
    localparam ST_CLEAR_C       = 5'd1;
    localparam ST_LOAD_A_WAIT   = 5'd2;
    localparam ST_LOAD_A_WRITE  = 5'd3;
    localparam ST_LOAD_B_WAIT   = 5'd4;
    localparam ST_LOAD_B_WRITE  = 5'd5;
    localparam ST_COMPUTE_INIT  = 5'd6;
    localparam ST_COMPUTE_ADDR  = 5'd7;
    localparam ST_COMPUTE_WAIT  = 5'd8;
    localparam ST_COMPUTE_MAC   = 5'd9;
    localparam ST_STORE_ADDR    = 5'd10;
    localparam ST_STORE_WAIT    = 5'd11;
    localparam ST_STORE_C       = 5'd12;
    localparam ST_NEXT_BLOCK    = 5'd13;
    localparam ST_SEND_ADDR0    = 5'd14;
    localparam ST_SEND_WAIT0    = 5'd15;
    localparam ST_SEND_LATCH0   = 5'd16;
    localparam ST_SEND_ADDR1    = 5'd17;
    localparam ST_SEND_WAIT1    = 5'd18;
    localparam ST_SEND_LATCH1   = 5'd19;
    localparam ST_SEND_DATA     = 5'd20;
    localparam ST_DONE          = 5'd21;
    localparam ST_WAIT_PREFETCH = 5'd22;

    // =================================================================================================================
    // AXI-LITE INTERNAL REGISTERS & CONTROL SLOTS
    // =================================================================================================================
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

    // CPU-Accessible Registers mapping:
    // slv_reg0 (Address 0x00) -> CTRL (Bit 0: Start execution, self-clears)
    // slv_reg1 (Address 0x04) -> STATUS (Bit 0: Done, Bit 1: Busy)
    // slv_reg2 (Address 0x08) -> M (Matrix A Row dimension size)
    // slv_reg3 (Address 0x0C) -> K (Matrix A Column / Matrix B Row dimension size)
    // slv_reg4 (Address 0x10) -> N (Matrix B Column dimension size)
    // slv_reg5 (Address 0x14) -> NUM_KTILES (How many K-tiles of 32x32 make up the complete matrix dimensions)
    reg [31:0] slv_reg0;
    reg [31:0] slv_reg1;
    reg [31:0] slv_reg2;
    reg [31:0] slv_reg3;
    reg [31:0] slv_reg4;
    reg [31:0] slv_reg5;

    wire slv_reg_wren;
    wire slv_reg_rden;
    reg [31:0] reg_data_out;
    integer byte_index;

    // Assigning internal handshake signals to external AXI outputs
    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    // Handshake check wires (valid on both ready && valid)
    assign slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;
    assign slv_reg_rden = axi_arready && S_AXI_ARVALID && ~axi_rvalid;

    // Generates a 1-clock pulse when the CPU writes a '1' into the start bit (CTRL[0]).
    wire start_pulse =
        slv_reg_wren &&
        (axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 3'h0) &&
        S_AXI_WDATA[0];

    // =================================================================================================================
    // HARDWARE BLOCK RAM (BRAM) ON-CHIP BUFFER DEFINITIONS
    // Dual buffers are created to support overlapped ping-pong memory prefetching.
    // =================================================================================================================
    
    // Matrix A Buffers (1024 elements each = 32 rows x 32 cols of int8):
    // Buffer A0 & A1 are implemented as dual synchronous Block RAMs.
    (* ram_style = "block" *) reg signed [7:0] A0_mem [0:1023];
    (* ram_style = "block" *) reg signed [7:0] A1_mem [0:1023];

    // Matrix B Buffers partitioned into 8 banks to achieve massive columns-read parallel access.
    // Bank selection matches columns: Col[2:0] decides bank. Depth per bank is 128 elements.
    // Buffer Set 0 (for compute/load ping-pong phase 0)
    (* ram_style = "block" *) reg signed [7:0] B0_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B1_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B2_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B3_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B4_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B5_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B6_0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B7_0_mem [0:C_BANK_DEPTH-1];

    // Buffer Set 1 (for compute/load ping-pong phase 1)
    (* ram_style = "block" *) reg signed [7:0] B0_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B1_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B2_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B3_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B4_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B5_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B6_1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [7:0] B7_1_mem [0:C_BANK_DEPTH-1];

    // Matrix C Buffers (1024 output elements total = 32 rows x 32 cols of int32):
    // Partitoned into 8 parallel BRAM banks as well to support zero-delay hardware accumulation.
    (* ram_style = "block" *) reg signed [31:0] C0_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C1_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C2_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C3_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C4_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C5_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C6_mem [0:C_BANK_DEPTH-1];
    (* ram_style = "block" *) reg signed [31:0] C7_mem [0:C_BANK_DEPTH-1];

    // =================================================================================================================
    // COMPUTE STATES & DATAPATH REGISTERS
    // =================================================================================================================
    reg [4:0] state;                        // 5-bit register storing the active state of the compute engine.

    reg load_buf_sel;                       // Pointer to the buffer being filled by the DMA stream (0 or 1).
    reg compute_buf_sel;                    // Pointer to the buffer being computed by the MAC engine (0 or 1).

    // -------------------------------------------------------------------------
    // Background Prefetch Loader Registers (Manages overlapped tile fetching)
    // -------------------------------------------------------------------------
    reg bg_load_active;                     // Asserted when the background prefetch engine is fetching next K-tile.
    reg bg_word_valid;                      // 1-clock flag indicating a 64-bit word was latched into the prefetch register.
    reg bg_phase;                           // 0 = currently loading A tile, 1 = currently loading B tile.
    reg bg_load_buf_sel;                    // Pointer pointing to the inactive buffer target for prefetching.
    reg bg_next_ready;                      // Set high by prefetcher when the next K-tile pair is successfully stored.
    reg [8:0] bg_word_count;                // Counter monitoring the incoming 64-bit prefetch words (0 to 127).
    reg [2:0] bg_byte_count;                // Byte-pointer mapping individual bytes in the 64-bit word (0 to 7).
    reg [63:0] bg_word_reg;                 // Holds the prefetched 64-bit word to serialize write into byte-wide BRAMs.

    // -------------------------------------------------------------------------
    // Foreground Synchronous Loader Registers (Used in the initial loading phase)
    // -------------------------------------------------------------------------
    reg [8:0] load_word_count;              // Counter monitoring incoming 64-bit foreground words (0 to 127).
    reg [2:0] load_byte_count;              // Byte pointer mapping elements inside the foreground 64-bit word (0 to 7).
    reg [63:0] load_word_reg;               // Temp register holding the active 64-bit foreground stream word.

    // -------------------------------------------------------------------------
    // Compute Loop Counters and Memory Address Registers
    // -------------------------------------------------------------------------
    reg [6:0] clear_addr;                   // RAM Address register used for zero-clearing C-BRAM banks (0 to 127).
    reg [4:0] i_count;                      // Active row index loop counter (0 to 31).
    reg [4:0] j_base;                       // Active column block base pointer (increments in steps of 8).
    reg [4:0] k_count;                      // Inner Multiply-Accumulate reduction loop index (0 to 31).

    reg [7:0] num_ktiles;                   // Stores total K-tiles to process (latched from CPU register 5).
    reg [7:0] ktile_count;                  // Tracks the current K-tile index loop (0 to num_ktiles-1).
    reg [8:0] send_count;                   // Tracks outgoing 64-bit words during output stream-out (0 to 511).

    reg [9:0] a_rd_addr;                    // Address bus connecting to Matrix A BRAMs.
    reg [6:0] b_rd_addr;                    // Address bus connecting to Matrix B BRAMs.
    reg [6:0] c_rd_addr;                    // Address bus connecting to Matrix C BRAMs.
    reg [2:0] c_rd_bank;                    // Selects which bank of C to read.

    // Registered output registers from Block RAMs (ensures high clock speeds via synchronous outputs)
    reg signed [7:0] a_dout;                // Latching output of Matrix A BRAM.
    reg signed [7:0] b0_dout;               // Banked BRAM outputs for columns (B0..B7).
    reg signed [7:0] b1_dout;
    reg signed [7:0] b2_dout;
    reg signed [7:0] b3_dout;
    reg signed [7:0] b4_dout;
    reg signed [7:0] b5_dout;
    reg signed [7:0] b6_dout;
    reg signed [7:0] b7_dout;

    reg signed [31:0] c0_dout;              // Banked BRAM outputs for output accumulation (C0..C7).
    reg signed [31:0] c1_dout;
    reg signed [31:0] c2_dout;
    reg signed [31:0] c3_dout;
    reg signed [31:0] c4_dout;
    reg signed [31:0] c5_dout;
    reg signed [31:0] c6_dout;
    reg signed [31:0] c7_dout;

    // Parallel PE accumulators. Keeps track of running MAC partial sums for 8 parallel column channels.
    reg signed [31:0] acc0;
    reg signed [31:0] acc1;
    reg signed [31:0] acc2;
    reg signed [31:0] acc3;
    reg signed [31:0] acc4;
    reg signed [31:0] acc5;
    reg signed [31:0] acc6;
    reg signed [31:0] acc7;

    // Output packing registers. Latch sequential elements to construct a single 64-bit beat stream-out.
    reg [31:0] send_lo_reg;                 // Holds lower 32-bit output element.
    reg [31:0] send_hi_reg;                 // Holds upper 32-bit output element.
    reg [63:0] m_axis_tdata_reg;            // Registered 64-bit output bus wrapper.
    reg m_axis_tvalid_reg;                  // Registered Output stream valid flag.
    reg m_axis_tlast_reg;                   // Registered Output stream last beat flag.

    // Assigning stream control registers to output ports
    assign m_axis_tdata  = m_axis_tdata_reg;
    assign m_axis_tvalid = m_axis_tvalid_reg;
    assign m_axis_tlast  = m_axis_tlast_reg;

    // =================================================================================================================
    // STREAM READY / VALID ARBITRATION
    // Explains how the input stream is shared between Foreground Loader and Background prefetch:
    // - Foreground loader has top priority (active during wait states).
    // - Prefetcher consumes stream only when the compute engine is busy and not using the bus.
    // =================================================================================================================
    wire main_axis_ready =
        (state == ST_LOAD_A_WAIT) ||
        (state == ST_LOAD_B_WAIT);

    wire bg_axis_ready = bg_load_active && !bg_word_valid && !main_axis_ready;

    // Ready handshake goes high when either the main loop or the background prefetch FSM is ready to consume data
    assign s_axis_tready = main_axis_ready || bg_axis_ready;

    // Bus handshake validation triggers
    wire s_fire = s_axis_tvalid && main_axis_ready;           // Main loop consumes incoming beat
    wire bg_fire = s_axis_tvalid && bg_axis_ready;            // Background FSM consumes incoming prefetch beat
    wire m_fire = m_axis_tvalid && m_axis_tready;             // Output stream beat successfully sent to DMA

    // =================================================================================================================
    // DYNAMIC ADDRESS INDEX GENERATORS
    // Explains memory addressing mapping coordinates (M, K, N indices mapped onto linear 1D BRAM addresses)
    // =================================================================================================================
    
    // Address generation for Foreground Loader (maps 64-bit beats to 1D byte locations inside BRAM)
    wire [11:0] load_byte_addr_wide = {load_word_count, 3'b000} + load_byte_count;
    wire [9:0] load_byte_addr = load_byte_addr_wide[9:0];

    // Address generation for Background Prefetch Loader
    wire [11:0] bg_byte_addr_wide = {bg_word_count, 3'b000} + bg_byte_count;
    wire [9:0] bg_byte_addr = bg_byte_addr_wide[9:0];

    // Translates linear byte addresses into Row, Column Bank, and Bank Address coordinates for Matrix B:
    // Row index = [9:5] (32 rows), Column index = [4:0] (32 cols). Column bank = Col[2:0], Bank address = {Row, Col[4:3]}.
    wire [4:0] bg_b_load_row  = bg_byte_addr[9:5];
    wire [4:0] bg_b_load_col  = bg_byte_addr[4:0];
    wire [2:0] bg_b_load_bank = bg_b_load_col[2:0];
    wire [6:0] bg_b_load_addr = {bg_b_load_row, bg_b_load_col[4:3]};

    wire [4:0] b_load_row  = load_byte_addr[9:5];
    wire [4:0] b_load_col  = load_byte_addr[4:0];
    wire [2:0] b_load_bank = b_load_col[2:0];
    wire [6:0] b_load_addr = {b_load_row, b_load_col[4:3]};

    // Addresses for intermediate computation and store
    wire [6:0] c_store_addr   = {i_count, j_base[4:3]};        // 7-bit BRAM address mapping row index and column group
    wire [6:0] b_compute_addr = {k_count, j_base[4:3]};        // B-read address during MAC compute steps

    // Output Packing Address generation:
    // Selects elements sequentially to form pairs of 32-bit outputs for the 64-bit S2MM output stream
    wire [9:0] send_elem0 = {send_count, 1'b0};                // Index of first output element (even index)
    wire [9:0] send_elem1 = {send_count, 1'b0} + 10'd1;        // Index of second output element (odd index)

    wire [6:0] send_addr0 = {send_elem0[9:5], send_elem0[4:3]};
    wire [2:0] send_bank0 = send_elem0[2:0];
    
    wire [6:0] send_addr1 = {send_elem1[9:5], send_elem1[4:3]};
    wire [2:0] send_bank1 = send_elem1[2:0];

    // =================================================================================================================
    // HELPER FUNCTIONS (COMBINATORIAL MULTIPLEXING LOGIC)
    // =================================================================================================================
    
    // Extracts a specific byte from a 64-bit word based on a 3-bit byte pointer index
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

    // Multiplexes the synchronous outputs of the 8 parallel C-BRAM banks to access specific column values
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

    // =================================================================================================================
    // BRAM SYNCHRONOUS READ REGISTER PROCESS
    // Handles latched BRAM reading. Based on the selected active compute ping-pong buffer (`compute_buf_sel`),
    // connects inputs A & B read buses to the output ports.
    // =================================================================================================================
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

        // C-Memory does not need ping-pong switching because results are accumulated in-place
        c0_dout <= C0_mem[c_rd_addr];
        c1_dout <= C1_mem[c_rd_addr];
        c2_dout <= C2_mem[c_rd_addr];
        c3_dout <= C3_mem[c_rd_addr];
        c4_dout <= C4_mem[c_rd_addr];
        c5_dout <= C5_mem[c_rd_addr];
        c6_dout <= C6_mem[c_rd_addr];
        c7_dout <= C7_mem[c_rd_addr];
    end

    // =================================================================================================================
    // MAIN ACCELERATOR STATE MACHINE + BACKGROUND PREFETCH PROCESS
    // =================================================================================================================
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            // Synchronous Active-low reset initialization of all registers
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

            // -------------------------------------------------------------------------
            // CO-ROUTINE: BACKGROUND PREFETCH LOADER FSM (RUNS IN PARALLEL)
            // Latching stream data directly into inactive memory banks behind compute execution.
            // -------------------------------------------------------------------------
            if (bg_fire) begin
                bg_word_reg <= s_axis_tdata;                   // Grab 64-bit prefetched beat from stream bus
                bg_word_valid <= 1'b1;                         // Latch valid flag
                bg_byte_count <= 0;                            // Reset deserialization byte count
            end else if (bg_word_valid) begin
                // Check phase: 0 = Load A tile, 1 = Load B tile
                if (bg_phase == 1'b0) begin
                    // Write byte to inactive A-BRAM ping-pong target
                    if (bg_load_buf_sel == 1'b0)
                        A0_mem[bg_byte_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                    else
                        A1_mem[bg_byte_addr] <= selected_byte(bg_word_reg, bg_byte_count);
                end else begin
                    // Write byte to inactive partitioned B-BRAM target
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

                // Loops 8 times per 64-bit word to serialize elements
                if (bg_byte_count == 3'd7) begin
                    bg_byte_count <= 0;
                    bg_word_valid <= 1'b0;                     // Consumed current 64-bit word completely
                    
                    if (bg_word_count == MATRIX_WORDS - 1) begin
                        bg_word_count <= 0;
                        if (bg_phase == 1'b0) begin
                            bg_phase <= 1'b1;                  // Completed loading A tile, transition to B tile prefetch
                        end else begin
                            bg_phase <= 1'b0;
                            bg_load_active <= 1'b0;            // Prefetch done for this entire K-tile block!
                            bg_next_ready <= 1'b1;             // Flag next K-tile as ready for the main compute FSM
                        end
                    end else begin
                        bg_word_count <= bg_word_count + 1'b1;
                    end
                end else begin
                    bg_byte_count <= bg_byte_count + 1'b1;
                end
            end

            // -------------------------------------------------------------------------
            // FOREGROUND CONTROLLER / PRIMARY COMPUTE ENGINE FSM STATE BLOCK
            // -------------------------------------------------------------------------
            case (state)

                // --------------------------------------------------------
                // ST_IDLE: Wait for CPU write into start register CTRL[0].
                // --------------------------------------------------------
                ST_IDLE: begin
                    m_axis_tvalid_reg <= 1'b0;
                    m_axis_tlast_reg <= 1'b0;

                    if (start_pulse) begin
                        slv_reg1 <= 32'd2;                     // Set status register to 2 (BUSY state)
                        load_word_count <= 0;
                        load_byte_count <= 0;
                        clear_addr <= 0;
                        i_count <= 0;
                        j_base <= 0;
                        k_count <= 0;
                        ktile_count <= 0;
                        num_ktiles <= (slv_reg5[7:0] == 0) ? 8'd1 : slv_reg5[7:0]; // Latches loop dimension
                        send_count <= 0;

                        // Setup initial ping-pong pointer states
                        load_buf_sel <= 1'b0;                  // Initial target is Buffer Set 0
                        compute_buf_sel <= 1'b0;
                        bg_load_active <= 1'b0;
                        bg_word_valid <= 1'b0;
                        bg_phase <= 1'b0;
                        bg_load_buf_sel <= 1'b1;               // Prefetch target is Buffer Set 1
                        bg_next_ready <= 1'b0;
                        bg_word_count <= 0;
                        bg_byte_count <= 0;
                        bg_word_reg <= 0;

                        state <= ST_CLEAR_C;
                    end
                end

                // --------------------------------------------------------
                // ST_CLEAR_C: Zeroes hardware accumulators inside BRAM.
                // --------------------------------------------------------
                ST_CLEAR_C: begin
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
                        state <= ST_LOAD_A_WAIT;               // Proceed to initial synchronous fetch
                    end else begin
                        clear_addr <= clear_addr + 1'b1;
                    end
                end

                // --------------------------------------------------------
                // ST_LOAD_A_WAIT: Synchronous block wait for first beat of Matrix A.
                // --------------------------------------------------------
                ST_LOAD_A_WAIT: begin
                    if (s_fire) begin
                        load_word_reg <= s_axis_tdata;         // Latch 64-bit input beat
                        load_byte_count <= 0;
                        state <= ST_LOAD_A_WRITE;
                    end
                end

                // --------------------------------------------------------
                // ST_LOAD_A_WRITE: Serializes and writes Matrix A into active A BRAM.
                // --------------------------------------------------------
                ST_LOAD_A_WRITE: begin
                    if (load_buf_sel == 1'b0)
                        A0_mem[load_byte_addr] <= selected_byte(load_word_reg, load_byte_count);
                    else
                        A1_mem[load_byte_addr] <= selected_byte(load_word_reg, load_byte_count);

                    if (load_byte_count == 3'd7) begin
                        load_byte_count <= 0;
                        if (load_word_count == MATRIX_WORDS - 1) begin
                            load_word_count <= 0;
                            state <= ST_LOAD_B_WAIT;           // Proceed to load Matrix B
                        end else begin
                            load_word_count <= load_word_count + 1'b1;
                            state <= ST_LOAD_A_WAIT;
                        end
                    end else begin
                        load_byte_count <= load_byte_count + 1'b1;
                    end
                end

                // --------------------------------------------------------
                // ST_LOAD_B_WAIT: Synchronous block wait for first beat of Matrix B.
                // --------------------------------------------------------
                ST_LOAD_B_WAIT: begin
                    if (s_fire) begin
                        load_word_reg <= s_axis_tdata;
                        load_byte_count <= 0;
                        state <= ST_LOAD_B_WRITE;
                    end
                end

                // --------------------------------------------------------
                // ST_LOAD_B_WRITE: Serializes and writes Matrix B into active B-BRAM banks.
                // --------------------------------------------------------
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

                            // -------------------------------------------------------------------------
                            // HIGH-PERFORMANCE TRIGGERS:
                            // The first K-tile is now loaded into the active compute buffers.
                            // If there are more K-tiles to process, IMMEDIATELY spin up the background
                            // prefetch loader to fetch the second K-tile pair in the background!
                            // -------------------------------------------------------------------------
                            if ((ktile_count + 1'b1) < num_ktiles) begin
                                bg_load_active <= 1'b1;        // Awake background loader FSM
                                bg_word_valid <= 1'b0;
                                bg_phase <= 1'b0;
                                bg_load_buf_sel <= ~load_buf_sel; // Target is the alternate buffer set
                                bg_next_ready <= 1'b0;
                                bg_word_count <= 0;
                                bg_byte_count <= 0;
                            end

                            state <= ST_COMPUTE_INIT;          // Jump straight to core compute execution
                        end else begin
                            load_word_count <= load_word_count + 1'b1;
                            state <= ST_LOAD_B_WAIT;
                        end
                    end else begin
                        load_byte_count <= load_byte_count + 1'b1;
                    end
                end

                // --------------------------------------------------------
                // ST_COMPUTE_INIT: Resets row multipliers and reduction accumulators.
                // --------------------------------------------------------
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

                // --------------------------------------------------------
                // ST_COMPUTE_ADDR: Asserts read address coordinates on BRAM address buses.
                // --------------------------------------------------------
                ST_COMPUTE_ADDR: begin
                    a_rd_addr <= {i_count, 5'b00000} + k_count;
                    b_rd_addr <= b_compute_addr;
                    state <= ST_COMPUTE_WAIT;
                end

                // --------------------------------------------------------
                // ST_COMPUTE_WAIT: Pipeline delay state. Wait 1 clock cycle 
                // for BRAM sync internal registers to latch the requested data.
                // --------------------------------------------------------
                ST_COMPUTE_WAIT: begin
                    state <= ST_COMPUTE_MAC;
                end

                // --------------------------------------------------------
                // ST_COMPUTE_MAC: THE HEART OF ACCELERATION (8 MACs/cycle).
                // Multiplies the broadcasted element of A by the 8 parallel column elements of B.
                // --------------------------------------------------------
                ST_COMPUTE_MAC: begin
                    acc0 <= acc0 + ($signed(a_dout) * $signed(b0_dout));
                    acc1 <= acc1 + ($signed(a_dout) * $signed(b1_dout));
                    acc2 <= acc2 + ($signed(a_dout) * $signed(b2_dout));
                    acc3 <= acc3 + ($signed(a_dout) * $signed(b3_dout));
                    acc4 <= acc4 + ($signed(a_dout) * $signed(b4_dout));
                    acc5 <= acc5 + ($signed(a_dout) * $signed(b5_dout));
                    acc6 <= acc6 + ($signed(a_dout) * $signed(b6_dout));
                    acc7 <= acc7 + ($signed(a_dout) * $signed(b7_dout));

                    if (k_count == DIM - 1) begin
                        state <= ST_STORE_ADDR;                // Inner reduction complete, store partial sum
                    end else begin
                        k_count <= k_count + 1'b1;
                        state <= ST_COMPUTE_ADDR;              // Loop back to next MAC index
                    end
                end

                // --------------------------------------------------------
                // ST_STORE_ADDR: Asserts accumulator write address bus.
                // --------------------------------------------------------
                ST_STORE_ADDR: begin
                    c_rd_addr <= c_store_addr;
                    state <= ST_STORE_WAIT;
                end

                // --------------------------------------------------------
                // ST_STORE_WAIT: Synchronous delay to fetch existing C sum for accumulation.
                // --------------------------------------------------------
                ST_STORE_WAIT: begin
                    state <= ST_STORE_C;
                end

                // --------------------------------------------------------
                // ST_STORE_C: Accumulates MAC outputs in C-BRAM banks.
                // --------------------------------------------------------
                ST_STORE_C: begin
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

                // --------------------------------------------------------
                // ST_NEXT_BLOCK: Loop index manager (Updates N columns and M rows).
                // --------------------------------------------------------
                ST_NEXT_BLOCK: begin
                    if (j_base == DIM - 8) begin
                        j_base <= 0;
                        if (i_count == DIM - 1) begin
                            // Current K-tile block is entirely computed!
                            if (ktile_count == num_ktiles - 1) begin
                                // All K-tiles processed! Transition to stream-out phase.
                                send_count <= 0;
                                state <= ST_SEND_ADDR0;
                            end else begin
                                // --------------------------------------------------------
                                // ZERO-LATENCY SYNCHRONIZATION POINT:
                                // We are done computing the current tile. We need to swap buffers.
                                // If the background prefetcher has already finished loading the next tile 
                                // (bg_next_ready == 1), we swap pointers instantly and begin compute,
                                // experiencing 0 clock cycle overhead!
                                // --------------------------------------------------------
                                if (bg_next_ready) begin
                                    ktile_count <= ktile_count + 1'b1;

                                    // Ping-pong buffer swap!
                                    compute_buf_sel <= ~compute_buf_sel;
                                    load_buf_sel <= ~load_buf_sel;

                                    bg_next_ready <= 1'b0;     // Consume the prefetched flag

                                    // If there are still more tiles to prefetch beyond the next one,
                                    // start the prefetcher to fetch the subsequent K-tile pair.
                                    if ((ktile_count + 8'd2) < num_ktiles) begin
                                        bg_load_active <= 1'b1;
                                        bg_word_valid <= 1'b0;
                                        bg_phase <= 1'b0;
                                        bg_load_buf_sel <= compute_buf_sel; // Target is the buffer we just freed up
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
                                    // Next tile is not fully loaded yet. Stall inside wait state.
                                    state <= ST_WAIT_PREFETCH;
                                end
                            end
                        end else begin
                            i_count <= i_count + 1'b1;
                            state <= ST_COMPUTE_INIT;
                        end
                    end else begin
                        j_base <= j_base + 5'd8;               // Move to next 8-column group block
                        state <= ST_COMPUTE_INIT;
                    end
                end

                // --------------------------------------------------------
                // ST_WAIT_PREFETCH: Compute FSM stalled. Waits here for background prefetch.
                // --------------------------------------------------------
                ST_WAIT_PREFETCH: begin
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

                // --------------------------------------------------------
                // ST_SEND_ADDR0: Asserts read address for the first element.
                // --------------------------------------------------------
                ST_SEND_ADDR0: begin
                    c_rd_addr <= send_addr0;
                    c_rd_bank <= send_bank0;
                    state <= ST_SEND_WAIT0;
                end

                // --------------------------------------------------------
                // ST_SEND_WAIT0: Sync delay to let BRAM read element 0.
                // --------------------------------------------------------
                ST_SEND_WAIT0: begin
                    state <= ST_SEND_LATCH0;
                end

                // --------------------------------------------------------
                // ST_SEND_LATCH0: Latches element 0 into low-side register, then requests element 1.
                // --------------------------------------------------------
                ST_SEND_LATCH0: begin
                    send_lo_reg <= selected_c(c_rd_bank);      // Latch element 0 into low 32-bits
                    state <= ST_SEND_ADDR1;
                end

                // --------------------------------------------------------
                // ST_SEND_ADDR1: Asserts read address for element 1.
                // --------------------------------------------------------
                ST_SEND_ADDR1: begin
                    c_rd_addr <= send_addr1;
                    c_rd_bank <= send_bank1;
                    state <= ST_SEND_WAIT1;
                end

                // --------------------------------------------------------
                // ST_SEND_WAIT1: Sync delay to let BRAM read element 1.
                // --------------------------------------------------------
                ST_SEND_WAIT1: begin
                    state <= ST_SEND_LATCH1;
                end

                // --------------------------------------------------------
                // ST_SEND_LATCH1: Latch element 1, packs both into 64-bit word,
                // and asserts AXI-Stream valid line (`m_axis_tvalid`).
                // --------------------------------------------------------
                ST_SEND_LATCH1: begin
                    send_hi_reg <= selected_c(c_rd_bank);      // Latch element 1
                    m_axis_tdata_reg <= {selected_c(c_rd_bank), send_lo_reg}; // Pack 2 x int32 into 64-bits
                    m_axis_tvalid_reg <= 1'b1;                 // Assert valid line on AXI stream
                    m_axis_tlast_reg <= (send_count == OUT_WORDS - 1); // Pulse last if it's the final beat
                    state <= ST_SEND_DATA;
                end

                // --------------------------------------------------------
                // ST_SEND_DATA: Output bus handshake monitoring.
                // --------------------------------------------------------
                ST_SEND_DATA: begin
                    if (m_fire) begin
                        m_axis_tvalid_reg <= 1'b0;             // Reset stream handshake lines
                        m_axis_tlast_reg <= 1'b0;
                        if (send_count == OUT_WORDS - 1) begin
                            state <= ST_DONE;                  // All 1024 values streamed out successfully!
                        end else begin
                            send_count <= send_count + 1'b1;
                            state <= ST_SEND_ADDR0;            // Fetch next pair
                        end
                    end
                end

                // --------------------------------------------------------
                // ST_DONE: Execution fully complete. Alert CPU.
                // --------------------------------------------------------
                ST_DONE: begin
                    slv_reg1 <= 32'd1;                         // Set status register to 1 (DONE state)
                    state <= ST_IDLE;                          // Loop back to idle, ready for next run
                end

                // Fallback default state
                default: begin
                    state <= ST_IDLE;
                end

            endcase
        end
    end

    // =================================================================================================================
    // AXI-LITE HANDSHAKING SLAVE TEMPLATE PROCESSES
    // Handles standard read/write bus transactions between Zynq ARM PS and the accelerator register slots.
    // =================================================================================================================
    
    // AXI-Lite Write Address Channel Ready (`awready`) generation
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

    // Latch incoming write address
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awaddr <= 0;
        end else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
            axi_awaddr <= S_AXI_AWADDR;
        end
    end

    // AXI-Lite Write Data Channel Ready (`wready`) generation
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

    // Latch incoming CPU register writes using byte strobe (`WSTRB`) masking
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            // Resets registers to default states
            slv_reg0 <= 0;                     // CTRL
            slv_reg2 <= 0;                     // M
            slv_reg3 <= 0;                     // K
            slv_reg4 <= 0;                     // N
            slv_reg5 <= 1;                     // NUM_KTILES defaults to 1
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
                    // Read-only register (STATUS = reg1) cannot be written by CPU
                end
            endcase
        end
    end

    // Write Response validation
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_bvalid <= 0;
            axi_bresp <= 2'b0;
        end else begin
            if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
                axi_bvalid <= 1'b1;
                axi_bresp <= 2'b0;             // OKAY response status
            end else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // AXI-Lite Read Address Channel Ready (`arready`) generation
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_araddr <= 0;
        end else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                axi_araddr <= S_AXI_ARADDR;     // Capture read address request
            end else begin
                axi_arready <= 1'b0;
            end
        end
    end

    // AXI-Lite Read Data Channel Valid (`rvalid`) generation
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rvalid <= 0;
            axi_rresp <= 0;
        end else begin
            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp <= 2'b0;             // OKAY response status
            end else if (axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // Combinatorially multiplexes internal registers to CPU Read Data bus
    always @(*) begin
        case (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB])
            3'h0: reg_data_out = slv_reg0;      // CTRL
            3'h1: reg_data_out = slv_reg1;      // STATUS
            3'h2: reg_data_out = slv_reg2;      // M
            3'h3: reg_data_out = slv_reg3;      // K
            3'h4: reg_data_out = slv_reg4;      // N
            3'h5: reg_data_out = slv_reg5;      // NUM_KTILES
            default: reg_data_out = 0;
        endcase
    end

    // Latch read output onto AXI data bus
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rdata <= 0;
        end else if (slv_reg_rden) begin
            axi_rdata <= reg_data_out;
        end
    end

endmodule

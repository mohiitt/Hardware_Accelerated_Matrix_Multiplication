`timescale 1 ns / 1 ps

/*
 * ============================================================================
 * Module Name:  matrix_accel_v1_0
 * Project:      Hardware-Accelerated Matrix Multiplication
 * Description:  Top-level Verilog wrapper for the Matrix Accelerator IP.
 *               This block integrates the AXI4-Lite control interface and the
 *               high-performance 64-bit AXI4-Stream interfaces for bulk data transfer.
 *               
 * Architecture:
 *   - Control Plane: AXI4-Lite interface (s00_axi_*) allows the ARM PS to configure
 *                    dimensions (M, K, N, num_ktiles), trigger execution, and poll status.
 *   - Data Plane:
 *       - s_axis_*: 64-bit slave stream (MM2S) feeds packed matrix data (int8 elements)
 *                   from DDR to the PL accelerator.
 *       - m_axis_*: 64-bit master stream (S2MM) returns computed, packed matrix results
 *                   (int32 elements) back to DDR via DMA.
 * ============================================================================
 */
module matrix_accel_v1_0 #
(
    // Parameters of AXI-Lite Slave Bus Interface S00_AXI
    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 5
)
(
    // AXI-Stream slave input interface: DDR -> DMA MM2S -> PL Accelerator
    // 64-bit wide data bus allows packing 8 x int8 elements per clock cycle for maximum throughput.
    input wire [63:0] s_axis_tdata,
    input wire        s_axis_tvalid,
    output wire       s_axis_tready,
    input wire        s_axis_tlast, // Signals the last packet of the DMA transfer block

    // AXI-Stream master output interface: PL Accelerator -> DMA S2MM -> DDR
    // 64-bit wide data bus allows returning 2 x int32 accumulated outputs per clock cycle.
    output wire [63:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input wire         m_axis_tready,
    output wire        m_axis_tlast, // Driven high on the final result word to notify DMA S2MM channel

    // Ports of AXI-Lite Slave Bus Interface S00_AXI (Register Configuration & Status)
    input wire s00_axi_aclk,             // System Clock (Synchronized with PL/DMA domain, targeting 100MHz)
    input wire s00_axi_aresetn,          // Active-low synchronous system reset
    input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
    input wire [2 : 0] s00_axi_awprot,
    input wire s00_axi_awvalid,
    output wire s00_axi_awready,
    input wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
    input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
    input wire s00_axi_wvalid,
    output wire s00_axi_wready,
    output wire [1 : 0] s00_axi_bresp,
    output wire s00_axi_bvalid,
    input wire s00_axi_bready,
    input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
    input wire [2 : 0] s00_axi_arprot,
    input wire s00_axi_arvalid,
    output wire s00_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
    output wire [1 : 0] s00_axi_rresp,
    output wire s00_axi_rvalid,
    input wire s00_axi_rready
);

// Instantiate the core AXI AXI-Lite & Stream engine.
// All execution FSMs, memory buffers, and parallel PEs reside in this sub-module.
matrix_accel_v1_0_S00_AXI #(
    .C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
    .C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
) matrix_accel_v1_0_S00_AXI_inst (
    .S_AXI_ACLK(s00_axi_aclk),
    .S_AXI_ARESETN(s00_axi_aresetn),
    .S_AXI_AWADDR(s00_axi_awaddr),
    .S_AXI_AWPROT(s00_axi_awprot),
    .S_AXI_AWVALID(s00_axi_awvalid),
    .S_AXI_AWREADY(s00_axi_awready),
    .S_AXI_WDATA(s00_axi_wdata),
    .S_AXI_WSTRB(s00_axi_wstrb),
    .S_AXI_WVALID(s00_axi_wvalid),
    .S_AXI_WREADY(s00_axi_wready),
    .S_AXI_BRESP(s00_axi_bresp),
    .S_AXI_BVALID(s00_axi_bvalid),
    .S_AXI_BREADY(s00_axi_bready),
    .S_AXI_ARADDR(s00_axi_araddr),
    .S_AXI_ARPROT(s00_axi_arprot),
    .S_AXI_ARVALID(s00_axi_arvalid),
    .S_AXI_ARREADY(s00_axi_arready),
    .S_AXI_RDATA(s00_axi_rdata),
    .S_AXI_RRESP(s00_axi_rresp),
    .S_AXI_RVALID(s00_axi_rvalid),
    .S_AXI_RREADY(s00_axi_rready),

    // Stream inputs mapped directly to the core
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),

    // Stream outputs mapped directly to the core
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast)
);

endmodule

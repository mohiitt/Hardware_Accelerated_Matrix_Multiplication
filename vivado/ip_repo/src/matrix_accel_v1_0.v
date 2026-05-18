`timescale 1 ns / 1 ps

// =====================================================
// Top-level wrapper for custom matrix accelerator IP.
//
// Responsibilities:
// - expose AXI-Lite control interface
// - expose AXI-Stream DMA interfaces
// - instantiate internal accelerator module
//
// Actual matrix multiplication logic exists inside:
// matrix_accel_v1_0_S00_AXI
// =====================================================

module matrix_accel_v1_0 #
(
    // AXI-Lite configuration
    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 5
)
(
    // =================================================
    // AXI-Stream slave input from DMA MM2S
    // Carries packed int8 matrix data
    // =================================================

    input wire [63:0] s_axis_tdata,
    input wire        s_axis_tvalid,
    output wire       s_axis_tready,
    input wire        s_axis_tlast,

    // =================================================
    // AXI-Stream master output to DMA S2MM
    // Carries packed int32 output values
    // =================================================

    output wire [63:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input wire         m_axis_tready,
    output wire        m_axis_tlast,

    // =================================================
    // AXI-Lite slave interface for ARM ↔ accelerator communication.
    // Used for CTRL, STATUS, dimensions, NUM_KTILES
    // =================================================

    input wire s00_axi_aclk,
    input wire s00_axi_aresetn,

    // AXI-Lite write address channel
    input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
    input wire [2 : 0] s00_axi_awprot,
    input wire s00_axi_awvalid,
    output wire s00_axi_awready,

    // AXI-Lite write data channel
    input wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
    input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
    input wire s00_axi_wvalid,
    output wire s00_axi_wready,

    // AXI-Lite write response channel
    output wire [1 : 0] s00_axi_bresp,
    output wire s00_axi_bvalid,
    input wire s00_axi_bready,

    // AXI-Lite read address channel
    input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
    input wire [2 : 0] s00_axi_arprot,
    input wire s00_axi_arvalid,
    output wire s00_axi_arready,

    // AXI-Lite read data channel
    output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
    output wire [1 : 0] s00_axi_rresp,
    output wire s00_axi_rvalid,
    input wire s00_axi_rready
);

// =====================================================
// Instantiate internal accelerator module
// Contains:
// - FSM
// - BRAM tile buffers
// - MAC datapath
// - AXI register logic
// - overlap scheduling
// =====================================================

matrix_accel_v1_0_S00_AXI #(
    .C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
    .C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
) matrix_accel_v1_0_S00_AXI_inst (

    // AXI-Lite connections
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

    // AXI-Stream input connections
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),

    // AXI-Stream output connections
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast)
);

endmodule
```

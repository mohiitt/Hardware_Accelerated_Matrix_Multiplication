/*
 * Phase 8: AXI-Stream Pass-Through Module
 *
 * Simply forwards AXI-Stream input to output unchanged.
 * This tests that your custom IP can handle AXI-Stream handshaking.
 *
 * IN VIVADO:
 *   Option A: Add this as RTL source and create a block design wrapper.
 *   Option B: Create an AXI peripheral with the wizard, then manually
 *             add these stream ports to the generated top module.
 *
 * CONNECTIONS:
 *   AXI DMA M_AXIS_MM2S → this module s_axis_*
 *   This module m_axis_* → AXI DMA S_AXIS_S2MM
 */
module axis_passthrough #(
    parameter DATA_WIDTH = 32
)(
    input  wire                    aclk,
    input  wire                    aresetn,

    // AXI-Stream Slave (input from DMA MM2S)
    input  wire [DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire                    s_axis_tvalid,
    output wire                    s_axis_tready,
    input  wire                    s_axis_tlast,

    // AXI-Stream Master (output to DMA S2MM)
    output wire [DATA_WIDTH-1:0]   m_axis_tdata,
    output wire                    m_axis_tvalid,
    input  wire                    m_axis_tready,
    output wire                    m_axis_tlast
);

    // Direct pass-through: just wire input to output
    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tvalid = s_axis_tvalid;
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tlast  = s_axis_tlast;

endmodule

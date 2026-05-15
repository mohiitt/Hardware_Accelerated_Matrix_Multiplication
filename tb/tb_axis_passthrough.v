/*
 * Phase 8: Testbench for AXI-Stream pass-through
 * Sends 8 words through the passthrough and verifies output matches input.
 */
`timescale 1ns/1ps

module tb_axis_passthrough;

reg clk, aresetn;
reg [31:0] s_tdata;
reg s_tvalid, s_tlast;
wire s_tready;
wire [31:0] m_tdata;
wire m_tvalid, m_tlast;
reg m_tready;

axis_passthrough #(.DATA_WIDTH(32)) dut (
    .aclk(clk), .aresetn(aresetn),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
    .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready), .m_axis_tlast(m_tlast)
);

always #5 clk = ~clk;

integer i;
reg [31:0] received [0:7];
integer rx_count;

initial begin
    clk = 0; aresetn = 0;
    s_tdata = 0; s_tvalid = 0; s_tlast = 0; m_tready = 1;
    rx_count = 0;

    #20; aresetn = 1; #10;

    // Send 8 words
    for (i = 0; i < 8; i = i + 1) begin
        s_tdata = 32'hCAFE0000 | i;
        s_tvalid = 1;
        s_tlast = (i == 7) ? 1 : 0;
        #10;
        if (m_tvalid && m_tready) begin
            received[rx_count] = m_tdata;
            rx_count = rx_count + 1;
        end
    end
    s_tvalid = 0; s_tlast = 0;
    #20;

    // Verify
    begin : check
        integer err;
        err = 0;
        for (i = 0; i < 8; i = i + 1) begin
            if (received[i] !== (32'hCAFE0000 | i)) begin
                $display("FAIL at %0d: got 0x%08X expected 0x%08X",
                         i, received[i], 32'hCAFE0000 | i);
                err = 1;
            end
        end
        if (!err) $display("PASS: all 8 words passed through correctly");
    end

    $finish;
end

endmodule

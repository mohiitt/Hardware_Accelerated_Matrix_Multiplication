/*
 * Phase 9 Testbench: Full matrix_accel_top simulation
 * Tests 4x4 matrix multiply with AXI-Stream I/O.
 *
 * Run: iverilog -g2012 -o tb/test_accel tb/tb_matrix_accel_4x4.v rtl/matrix_accel_top.v rtl/pe.v
 *      vvp tb/test_accel
 */
`timescale 1ns/1ps

module tb_matrix_accel_4x4;

    reg clk, resetn;
    always #5 clk = ~clk;

    // AXI-Lite
    reg  [4:0]  awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid; reg bready;
    reg  [4:0]  araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    // AXI-Stream
    reg  [31:0] s_tdata; reg s_tvalid, s_tlast; wire s_tready;
    wire [31:0] m_tdata; wire m_tvalid, m_tlast; reg m_tready;

    matrix_accel_top #(
        .C_S_AXI_DATA_WIDTH(32), .C_S_AXI_ADDR_WIDTH(5),
        .AXIS_DATA_WIDTH(32), .MAX_DIM(16)
    ) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast)
    );

    // Simple AXI-Lite write: hold signals until handshake completes
    task axi_write(input [4:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            awaddr  = addr;
            awvalid = 1;
            wdata   = data;
            wstrb   = 4'hF;
            wvalid  = 1;
            bready  = 1;
            // Wait for write to be accepted
            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);
            @(negedge clk);
            awvalid = 0;
            wvalid  = 0;
            // Wait for write response
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            bready = 0;
            @(posedge clk);
        end
    endtask

    // Send one stream word, wait for tready
    task stream_send(input [31:0] data, input last);
        begin
            @(negedge clk);
            s_tdata  = data;
            s_tvalid = 1;
            s_tlast  = last;
            @(posedge clk);
            while (!s_tready) @(posedge clk);
            // Data accepted on this rising edge
            @(negedge clk);
            s_tvalid = 0;
            s_tlast  = 0;
        end
    endtask

    // Expected C
    integer C_exp [0:15];
    reg [31:0] C_rx [0:15];
    integer rx_cnt;

    // Input data packed as 32-bit words (little-endian)
    // A row-major: 1,2,3,4, 5,6,7,8, 1,1,1,1, -1,2,-3,4
    reg [31:0] A_words [0:3];
    reg [31:0] B_words [0:3];

    integer i;

    initial begin
        clk = 0; resetn = 0;
        awaddr = 0; awvalid = 0;
        wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;
        s_tdata = 0; s_tvalid = 0; s_tlast = 0;
        m_tready = 0;
        rx_cnt = 0;

        // Pack A: bytes in little-endian within each 32-bit word
        A_words[0] = 32'h04030201; // 1, 2, 3, 4
        A_words[1] = 32'h08070605; // 5, 6, 7, 8
        A_words[2] = 32'h01010101; // 1, 1, 1, 1
        A_words[3] = 32'h04FD02FF; // -1, 2, -3, 4

        // Pack B: 1,0,2,1, 0,1,2,1, 1,1,0,1, 2,0,1,1
        B_words[0] = 32'h01020001; // 1, 0, 2, 1
        B_words[1] = 32'h01020100; // 0, 1, 2, 1
        B_words[2] = 32'h01000101; // 1, 1, 0, 1
        B_words[3] = 32'h01010002; // 2, 0, 1, 1

        C_exp[0]=12; C_exp[1]=5;  C_exp[2]=10; C_exp[3]=10;
        C_exp[4]=28; C_exp[5]=13; C_exp[6]=30; C_exp[7]=26;
        C_exp[8]=4;  C_exp[9]=2;  C_exp[10]=5; C_exp[11]=4;
        C_exp[12]=4; C_exp[13]=-1; C_exp[14]=6; C_exp[15]=2;

        // Reset
        #30; resetn = 1; #20;

        // Write dimensions
        axi_write(5'h08, 32'd4);  // M
        axi_write(5'h0C, 32'd4);  // K
        axi_write(5'h10, 32'd4);  // N

        // Start
        axi_write(5'h00, 32'd1);  // CTRL.start

        // Now the FSM should be in LOAD_A, ready to accept stream data
        #20;

        // Send A (4 words)
        for (i = 0; i < 4; i = i + 1)
            stream_send(A_words[i], 1'b0);

        // Send B (4 words, last word has tlast)
        for (i = 0; i < 4; i = i + 1)
            stream_send(B_words[i], (i == 3) ? 1'b1 : 1'b0);

        $display("Input data sent, waiting for output...");

        // Receive C (16 int32 words)
        m_tready = 1;
        while (rx_cnt < 16) begin
            @(posedge clk);
            if (m_tvalid && m_tready) begin
                C_rx[rx_cnt] = m_tdata;
                rx_cnt = rx_cnt + 1;
            end
        end
        m_tready = 0;

        #20;

        // Verify
        $display("C[0..3]  = %0d %0d %0d %0d",
                 $signed(C_rx[0]), $signed(C_rx[1]),
                 $signed(C_rx[2]), $signed(C_rx[3]));
        $display("C[4..7]  = %0d %0d %0d %0d",
                 $signed(C_rx[4]), $signed(C_rx[5]),
                 $signed(C_rx[6]), $signed(C_rx[7]));
        $display("C[8..11] = %0d %0d %0d %0d",
                 $signed(C_rx[8]), $signed(C_rx[9]),
                 $signed(C_rx[10]), $signed(C_rx[11]));
        $display("C[12..15]= %0d %0d %0d %0d",
                 $signed(C_rx[12]), $signed(C_rx[13]),
                 $signed(C_rx[14]), $signed(C_rx[15]));

        begin : verify
            integer errs;
            errs = 0;
            for (i = 0; i < 16; i = i + 1) begin
                if ($signed(C_rx[i]) !== C_exp[i]) begin
                    $display("MISMATCH idx=%0d got=%0d exp=%0d",
                             i, $signed(C_rx[i]), C_exp[i]);
                    errs = errs + 1;
                end
            end
            if (errs == 0) $display("PASS: 4x4 matrix multiply");
            else $display("FAIL: %0d mismatches", errs);
        end

        #10;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

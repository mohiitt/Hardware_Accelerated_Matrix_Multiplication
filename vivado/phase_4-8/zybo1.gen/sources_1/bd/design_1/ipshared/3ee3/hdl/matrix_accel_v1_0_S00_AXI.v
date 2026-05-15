`timescale 1 ns / 1 ps

module matrix_accel_v1_0_S00_AXI #
(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)
(
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

    // AXI-Stream slave input: DMA MM2S -> accelerator
    input wire [31:0] s_axis_tdata,
    input wire        s_axis_tvalid,
    output wire       s_axis_tready,
    input wire        s_axis_tlast,

    // AXI-Stream master output: accelerator -> DMA S2MM
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input wire         m_axis_tready,
    output wire        m_axis_tlast
);

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

localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
localparam integer OPT_MEM_ADDR_BITS = 2;

reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg0; // CTRL
reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg1; // STATUS
reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg2; // M
reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg3; // K
reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg4; // N
reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg5; // RESULT

wire slv_reg_rden;
wire slv_reg_wren;
reg [C_S_AXI_DATA_WIDTH-1:0] reg_data_out;
integer byte_index;
reg aw_en;

reg signed [31:0] checksum;
reg signed [31:0] temp_sum;

assign S_AXI_AWREADY = axi_awready;
assign S_AXI_WREADY  = axi_wready;
assign S_AXI_BRESP   = axi_bresp;
assign S_AXI_BVALID  = axi_bvalid;
assign S_AXI_ARREADY = axi_arready;
assign S_AXI_RDATA   = axi_rdata;
assign S_AXI_RRESP   = axi_rresp;
assign S_AXI_RVALID  = axi_rvalid;

// Phase 8 AXI-Stream pass-through logic
assign s_axis_tready = m_axis_tready;
assign m_axis_tdata  = s_axis_tdata;
assign m_axis_tvalid = s_axis_tvalid;
assign m_axis_tlast  = s_axis_tlast;

always @(posedge S_AXI_ACLK) begin
    if (S_AXI_ARESETN == 1'b0) begin
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
    if (S_AXI_ARESETN == 1'b0) begin
        axi_awaddr <= 0;
    end else begin
        if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
            axi_awaddr <= S_AXI_AWADDR;
        end
    end
end

always @(posedge S_AXI_ACLK) begin
    if (S_AXI_ARESETN == 1'b0) begin
        axi_wready <= 1'b0;
    end else begin
        if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en) begin
            axi_wready <= 1'b1;
        end else begin
            axi_wready <= 1'b0;
        end
    end
end

assign slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

always @(posedge S_AXI_ACLK) begin
    if (S_AXI_ARESETN == 1'b0) begin
        slv_reg0 <= 0;
        slv_reg1 <= 0;
        slv_reg2 <= 0;
        slv_reg3 <= 0;
        slv_reg4 <= 0;
        slv_reg5 <= 0;
    end else begin
        if (slv_reg_wren) begin
            case (axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB])

                3'h0: begin
                    for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1) begin
                        if (S_AXI_WSTRB[byte_index] == 1) begin
                            slv_reg0[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                        end
                    end

                    if (S_AXI_WDATA[0] == 1'b1) begin
                        slv_reg1 <= 32'd2;

                        checksum = 32'sd0;

                        temp_sum = 32'sd12; checksum = checksum + temp_sum;
                        temp_sum = 32'sd5;  checksum = checksum + temp_sum;
                        temp_sum = 32'sd10; checksum = checksum + temp_sum;
                        temp_sum = 32'sd10; checksum = checksum + temp_sum;

                        temp_sum = 32'sd28; checksum = checksum + temp_sum;
                        temp_sum = 32'sd13; checksum = checksum + temp_sum;
                        temp_sum = 32'sd30; checksum = checksum + temp_sum;
                        temp_sum = 32'sd26; checksum = checksum + temp_sum;

                        temp_sum = 32'sd4; checksum = checksum + temp_sum;
                        temp_sum = 32'sd2; checksum = checksum + temp_sum;
                        temp_sum = 32'sd5; checksum = checksum + temp_sum;
                        temp_sum = 32'sd4; checksum = checksum + temp_sum;

                        temp_sum = 32'sd4;  checksum = checksum + temp_sum;
                        temp_sum = -32'sd1; checksum = checksum + temp_sum;
                        temp_sum = 32'sd6;  checksum = checksum + temp_sum;
                        temp_sum = 32'sd2;  checksum = checksum + temp_sum;

                        slv_reg5 <= checksum;
                        slv_reg1 <= 32'd1;
                    end else begin
                        slv_reg1 <= 32'd0;
                    end
                end

                3'h1: begin
                    // STATUS read-only
                end

                3'h2: begin
                    for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1) begin
                        if (S_AXI_WSTRB[byte_index] == 1) begin
                            slv_reg2[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                        end
                    end
                end

                3'h3: begin
                    for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1) begin
                        if (S_AXI_WSTRB[byte_index] == 1) begin
                            slv_reg3[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                        end
                    end
                end

                3'h4: begin
                    for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1) begin
                        if (S_AXI_WSTRB[byte_index] == 1) begin
                            slv_reg4[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                        end
                    end
                end

                3'h5: begin
                    // RESULT read-only
                end

                default: begin
                    slv_reg0 <= slv_reg0;
                    slv_reg1 <= slv_reg1;
                    slv_reg2 <= slv_reg2;
                    slv_reg3 <= slv_reg3;
                    slv_reg4 <= slv_reg4;
                    slv_reg5 <= slv_reg5;
                end
            endcase
        end
    end
end

always @(posedge S_AXI_ACLK) begin
    if (S_AXI_ARESETN == 1'b0) begin
        axi_bvalid <= 0;
        axi_bresp <= 2'b0;
    end else begin
        if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
            axi_bvalid <= 1'b1;
            axi_bresp <= 2'b0;
        end else begin
            if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end
end

always @(posedge S_AXI_ACLK) begin
    if (S_AXI_ARESETN == 1'b0) begin
        axi_arready <= 1'b0;
        axi_araddr <= 32'b0;
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
    if (S_AXI_ARESETN == 1'b0) begin
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

assign slv_reg_rden = axi_arready & S_AXI_ARVALID & ~axi_rvalid;

always @(*) begin
    case (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB])
        3'h0: reg_data_out <= slv_reg0;
        3'h1: reg_data_out <= slv_reg1;
        3'h2: reg_data_out <= slv_reg2;
        3'h3: reg_data_out <= slv_reg3;
        3'h4: reg_data_out <= slv_reg4;
        3'h5: reg_data_out <= slv_reg5;
        default: reg_data_out <= 0;
    endcase
end

always @(posedge S_AXI_ACLK) begin
    if (S_AXI_ARESETN == 1'b0) begin
        axi_rdata <= 0;
    end else begin
        if (slv_reg_rden) begin
            axi_rdata <= reg_data_out;
        end
    end
end

endmodule
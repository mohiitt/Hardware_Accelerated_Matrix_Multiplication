module pe (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              clear,
    input  wire              enable,
    input  wire signed [7:0] a,
    input  wire signed [7:0] b,
    output reg  signed [31:0] acc
);

always @(posedge clk) begin
    if (!rst_n) begin
        acc <= 32'sd0;
    end else if (clear) begin
        acc <= 32'sd0;
    end else if (enable) begin
        acc <= acc + (a * b);
    end
end

endmodule

`timescale 1ns/1ps

module tb_pe;

reg clk;
reg rst_n;
reg clear;
reg enable;
reg signed [7:0] a;
reg signed [7:0] b;
wire signed [31:0] acc;

pe dut (
    .clk(clk),
    .rst_n(rst_n),
    .clear(clear),
    .enable(enable),
    .a(a),
    .b(b),
    .acc(acc)
);

always #5 clk = ~clk;

initial begin
    clk = 0;
    rst_n = 0;
    clear = 0;
    enable = 0;
    a = 0;
    b = 0;

    // Hold reset for 2 clock cycles
    #20;
    rst_n = 1;

    // Clear the accumulator
    clear = 1;
    #10;
    clear = 0;

    // First MAC: acc = 0 + 2*3 = 6
    enable = 1;
    a = 8'sd2;
    b = 8'sd3;
    #10;

    // Second MAC: acc = 6 + (-4)*5 = 6 - 20 = -14
    a = -8'sd4;
    b = 8'sd5;
    #10;

    // Disable and check result
    enable = 0;
    #10;

    if (acc == -14)
        $display("PASS: acc = %0d", acc);
    else
        $display("FAIL: acc = %0d (expected -14)", acc);

    $finish;
end

endmodule

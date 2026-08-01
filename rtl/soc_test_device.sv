`timescale 1ns/1ps

// Simulation-visible tohost device. Firmware writes 1 for PASS and any other
// value for FAIL. Keeping it as a normal MMIO slave exercises a real CPU store.
module soc_test_device (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        bus_valid,
    input  logic [31:0] bus_wdata,
    input  logic [3:0]  bus_wstrb,
    output logic        bus_ready,
    output logic [31:0] bus_rdata,
    output logic        test_done,
    output logic        test_pass,
    output logic [31:0] test_code
);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bus_ready <= 1'b0;
            bus_rdata <= 32'd0;
            test_done <= 1'b0;
            test_pass <= 1'b0;
            test_code <= 32'd0;
        end else begin
            bus_ready <= 1'b0;

            if (bus_valid && !bus_ready) begin
                bus_ready <= 1'b1;
                bus_rdata <= test_code;

                if (|bus_wstrb) begin
                    test_done <= 1'b1;
                    test_pass <= (bus_wdata == 32'd1);
                    test_code <= bus_wdata;
                end
            end
        end
    end

endmodule


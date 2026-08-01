`timescale 1ns/1ps

// Single-port word-addressed RAM with PicoRV32-style valid/ready handshake.
module simple_ram #(
    parameter integer MEM_WORDS = 16384,
    parameter         MEM_INIT_FILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        bus_valid,
    input  logic [31:0] bus_addr,
    input  logic [31:0] bus_wdata,
    input  logic [3:0]  bus_wstrb,
    output logic        bus_ready,
    output logic [31:0] bus_rdata
);

    localparam integer WORD_ADDR_BITS = $clog2(MEM_WORDS);

    logic [31:0] memory [0:MEM_WORDS-1];
    integer byte_lane;

    initial begin
        if (MEM_INIT_FILE != "") begin
            $display("RAM_INIT: loading %s", MEM_INIT_FILE);
            $readmemh(MEM_INIT_FILE, memory);
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bus_ready <= 1'b0;
            bus_rdata <= 32'd0;
        end else begin
            bus_ready <= 1'b0;

            if (bus_valid && !bus_ready) begin
                bus_ready <= 1'b1;

                if (|bus_wstrb) begin
                    for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1) begin
                        if (bus_wstrb[byte_lane]) begin
                            memory[bus_addr[WORD_ADDR_BITS+1:2]][byte_lane*8 +: 8]
                                <= bus_wdata[byte_lane*8 +: 8];
                        end
                    end
                end else begin
                    bus_rdata <= memory[bus_addr[WORD_ADDR_BITS+1:2]];
                end
            end
        end
    end

endmodule


`timescale 1ns/1ps

// PicoRV32 valid/ready wrapper around PicoSoC's simpleuart.
//
// Register map relative to UART_BASE:
//   0x00 RW CLKDIV - system-clock cycles per UART bit (1085 at 125 MHz/115200)
//   0x04 RW DATA   - read: received byte or 0xffffffff when empty
//                    write: transmit low byte, stalling while TX is busy
module uart_mmio #(
    parameter integer DEFAULT_DIV = 1085
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        bus_valid,
    input  logic [7:0]  bus_addr,
    input  logic [31:0] bus_wdata,
    input  logic [3:0]  bus_wstrb,
    output logic        bus_ready,
    output logic [31:0] bus_rdata,

    input  logic        uart_rx,
    output logic        uart_tx
);

    localparam logic [7:0] ADDR_CLKDIV = 8'h00;
    localparam logic [7:0] ADDR_DATA   = 8'h04;

    // UART RX is asynchronous to the 125 MHz PL clock. Only the first stage
    // may become metastable; the second stage is consumed by the receiver.
    // Reset to the UART idle level (logic high), not zero/start-bit level.
    (* ASYNC_REG = "TRUE" *)
    logic [1:0] uart_rx_sync;

    logic        clkdiv_sel;
    logic        data_sel;
    logic [3:0]  clkdiv_we;
    logic [31:0] clkdiv_rdata;
    logic        data_we;
    logic        data_re;
    logic [31:0] data_rdata;
    logic        data_wait;

    always_ff @(posedge clk) begin
        if (!rst_n)
            uart_rx_sync <= 2'b11;
        else
            uart_rx_sync <= {uart_rx_sync[0], uart_rx};
    end

    assign clkdiv_sel = bus_valid && (bus_addr == ADDR_CLKDIV);
    assign data_sel   = bus_valid && (bus_addr == ADDR_DATA);

    assign clkdiv_we = clkdiv_sel ? bus_wstrb : 4'b0000;
    // Keep reg_dat_we asserted while the CPU transaction is stalled. The
    // simpleuart core raises data_wait while its transmitter is busy; gating
    // reg_dat_we with data_wait would create a combinational feedback loop.
    assign data_we   = data_sel && bus_wstrb[0];
    assign data_re   = data_sel && !(|bus_wstrb);

    always_comb begin
        bus_ready = 1'b0;
        bus_rdata = 32'd0;

        if (bus_valid) begin
            case (bus_addr)
                ADDR_CLKDIV: begin
                    bus_ready = 1'b1;
                    bus_rdata = clkdiv_rdata;
                end

                ADDR_DATA: begin
                    bus_rdata = data_rdata;
                    // Reads always complete: 0xffffffff means RX empty.
                    // Writes hold PicoRV32 until simpleuart can accept a byte.
                    bus_ready = !(|bus_wstrb) || !data_wait;
                end

                default: begin
                    // Complete unknown accesses so firmware bugs do not hang
                    // the complete SoC bus.
                    bus_ready = 1'b1;
                    bus_rdata = 32'd0;
                end
            endcase
        end
    end

    simpleuart #(
        .DEFAULT_DIV (DEFAULT_DIV)
    ) uart_core (
        .clk          (clk),
        .resetn       (rst_n),
        .ser_tx       (uart_tx),
        .ser_rx       (uart_rx_sync[1]),
        .reg_div_we   (clkdiv_we),
        .reg_div_di   (bus_wdata),
        .reg_div_do   (clkdiv_rdata),
        .reg_dat_we   (data_we),
        .reg_dat_re   (data_re),
        .reg_dat_di   (bus_wdata),
        .reg_dat_do   (data_rdata),
        .reg_dat_wait (data_wait)
    );

endmodule

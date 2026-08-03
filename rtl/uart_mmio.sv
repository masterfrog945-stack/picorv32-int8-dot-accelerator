`timescale 1ns/1ps

// PicoRV32 valid/ready UART peripheral with single-clock RX and TX FIFOs.
//
// Register map relative to UART_BASE:
//   0x00 RW CLKDIV          - system-clock cycles per UART bit
//   0x04 RW DATA            - read RX byte or 0xffffffff when empty;
//                             write enqueues low byte, stalls only when TX full
//   0x08 RO STATUS          - [0] RX empty, [1] RX full, [2] TX empty,
//                             [3] TX full, [4] overflow seen,
//                             [5] framing error seen, [6] false start seen
//   0x0c RO RX_LEVEL        - queued receive bytes
//   0x10 RO TX_LEVEL        - queued transmit bytes
//   0x14 RO RX_OVERFLOW     - dropped byte count
//   0x18 RO FRAMING_ERRORS  - invalid stop-bit count
//   0x1c RO FALSE_STARTS    - rejected start-glitch count
//   0x20 WO CONTROL         - write bit 0 to clear all error counters
module uart_mmio #(
    parameter integer DEFAULT_DIV = 1085,
    parameter integer FIFO_DEPTH  = 32
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

    localparam logic [7:0] ADDR_CLKDIV         = 8'h00;
    localparam logic [7:0] ADDR_DATA           = 8'h04;
    localparam logic [7:0] ADDR_STATUS         = 8'h08;
    localparam logic [7:0] ADDR_RX_LEVEL       = 8'h0c;
    localparam logic [7:0] ADDR_TX_LEVEL       = 8'h10;
    localparam logic [7:0] ADDR_RX_OVERFLOW    = 8'h14;
    localparam logic [7:0] ADDR_FRAMING_ERRORS = 8'h18;
    localparam logic [7:0] ADDR_FALSE_STARTS   = 8'h1c;
    localparam logic [7:0] ADDR_CONTROL        = 8'h20;
    localparam integer LEVEL_WIDTH = $clog2(FIFO_DEPTH + 1);

    // Only this pair crosses from the asynchronous header pin into sysclk.
    // Everything after uart_rx_sync[1], including both FIFOs, is synchronous.
    (* ASYNC_REG = "TRUE" *)
    logic [1:0] uart_rx_sync;

    // 16 bits cover divisors up to 65535. At 125 MHz this reaches about
    // 1908 baud while shortening the UART terminal-count timing path.
    logic [15:0] clkdiv_q;
    logic [7:0]  rx_byte;
    logic        rx_byte_valid;
    logic        rx_framing_error;
    logic        rx_false_start;
    logic [7:0]  rx_fifo_data;
    logic        rx_fifo_empty;
    logic        rx_fifo_full;
    logic [LEVEL_WIDTH-1:0] rx_fifo_level;
    logic        rx_fifo_pop;
    logic [7:0]  tx_fifo_data;
    logic        tx_fifo_empty;
    logic        tx_fifo_full;
    logic [LEVEL_WIDTH-1:0] tx_fifo_level;
    logic        tx_fifo_push;
    logic        tx_fifo_pop;
    logic        tx_core_ready;
    logic [31:0] rx_overflow_count;
    logic [31:0] framing_error_count;
    logic [31:0] false_start_count;
    logic        clear_errors;
    logic        data_select;
    logic        data_read;
    logic        bus_accept;
    integer      byte_lane;

    always_ff @(posedge clk) begin
        if (!rst_n)
            uart_rx_sync <= 2'b11;
        else
            uart_rx_sync <= {uart_rx_sync[0], uart_rx};
    end

    assign data_select = bus_valid && (bus_addr == ADDR_DATA);
    assign data_read   = data_select && !(|bus_wstrb);
    // Match the registered one-cycle valid/ready handshake used by RAM and
    // the accelerator CSR. A DATA write is the only request allowed to wait.
    assign bus_accept = bus_valid && !bus_ready
                      && !(data_select && (|bus_wstrb) && tx_fifo_full);
    assign rx_fifo_pop  = bus_accept && data_read && !rx_fifo_empty;
    assign tx_fifo_push = bus_accept && data_select && bus_wstrb[0];
    assign tx_fifo_pop  = !tx_fifo_empty && tx_core_ready;
    assign clear_errors = bus_accept
                       && (bus_addr == ADDR_CONTROL)
                       && bus_wstrb[0] && bus_wdata[0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bus_ready            <= 1'b0;
            bus_rdata            <= 32'd0;
            clkdiv_q            <= DEFAULT_DIV[15:0];
            rx_overflow_count   <= 32'd0;
            framing_error_count <= 32'd0;
            false_start_count   <= 32'd0;
        end else begin
            bus_ready <= 1'b0;

            if (bus_accept) begin
                bus_ready <= 1'b1;
                case (bus_addr)
                    ADDR_CLKDIV:
                        bus_rdata <= {16'd0, clkdiv_q};
                    ADDR_DATA:
                        bus_rdata <= rx_fifo_empty
                                   ? 32'hffff_ffff
                                   : {24'd0, rx_fifo_data};
                    ADDR_STATUS: begin
                        bus_rdata       <= 32'd0;
                        bus_rdata[0]    <= rx_fifo_empty;
                        bus_rdata[1]    <= rx_fifo_full;
                        bus_rdata[2]    <= tx_fifo_empty;
                        bus_rdata[3]    <= tx_fifo_full;
                        bus_rdata[4]    <= (rx_overflow_count != 0);
                        bus_rdata[5]    <= (framing_error_count != 0);
                        bus_rdata[6]    <= (false_start_count != 0);
                    end
                    ADDR_RX_LEVEL:
                        bus_rdata <= {{(32-LEVEL_WIDTH){1'b0}}, rx_fifo_level};
                    ADDR_TX_LEVEL:
                        bus_rdata <= {{(32-LEVEL_WIDTH){1'b0}}, tx_fifo_level};
                    ADDR_RX_OVERFLOW:
                        bus_rdata <= rx_overflow_count;
                    ADDR_FRAMING_ERRORS:
                        bus_rdata <= framing_error_count;
                    ADDR_FALSE_STARTS:
                        bus_rdata <= false_start_count;
                    default:
                        bus_rdata <= 32'd0;
                endcase
            end

            if (bus_accept && (bus_addr == ADDR_CLKDIV) && (|bus_wstrb)) begin
                for (byte_lane = 0; byte_lane < 2; byte_lane = byte_lane + 1) begin
                    if (bus_wstrb[byte_lane])
                        clkdiv_q[byte_lane*8 +: 8]
                            <= bus_wdata[byte_lane*8 +: 8];
                end
            end

            if (clear_errors) begin
                rx_overflow_count   <= 32'd0;
                framing_error_count <= 32'd0;
                false_start_count   <= 32'd0;
            end

            if (rx_byte_valid && rx_fifo_full && !rx_fifo_pop
                    && rx_overflow_count != 32'hffff_ffff)
                rx_overflow_count <= rx_overflow_count + 1'b1;

            if (rx_framing_error && framing_error_count != 32'hffff_ffff)
                framing_error_count <= framing_error_count + 1'b1;

            if (rx_false_start && false_start_count != 32'hffff_ffff)
                false_start_count <= false_start_count + 1'b1;
        end
    end

    uart_rx_core rx_core (
        .clk            (clk),
        .rst_n          (rst_n),
        .clocks_per_bit (clkdiv_q),
        .serial_rx      (uart_rx_sync[1]),
        .data           (rx_byte),
        .data_valid     (rx_byte_valid),
        .framing_error  (rx_framing_error),
        .false_start    (rx_false_start)
    );

    sync_fifo #(
        .DATA_WIDTH (8),
        .DEPTH      (FIFO_DEPTH)
    ) rx_fifo (
        .clk       (clk),
        .rst_n     (rst_n),
        .push      (rx_byte_valid),
        .push_data (rx_byte),
        .pop       (rx_fifo_pop),
        .pop_data  (rx_fifo_data),
        .empty     (rx_fifo_empty),
        .full      (rx_fifo_full),
        .level     (rx_fifo_level)
    );

    uart_tx_core tx_core (
        .clk            (clk),
        .rst_n          (rst_n),
        .clocks_per_bit (clkdiv_q),
        .data           (tx_fifo_data),
        .data_valid     (!tx_fifo_empty),
        .data_ready     (tx_core_ready),
        .serial_tx      (uart_tx)
    );

    sync_fifo #(
        .DATA_WIDTH (8),
        .DEPTH      (FIFO_DEPTH)
    ) tx_fifo (
        .clk       (clk),
        .rst_n     (rst_n),
        .push      (tx_fifo_push),
        .push_data (bus_wdata[7:0]),
        .pop       (tx_fifo_pop),
        .pop_data  (tx_fifo_data),
        .empty     (tx_fifo_empty),
        .full      (tx_fifo_full),
        .level     (tx_fifo_level)
    );

endmodule

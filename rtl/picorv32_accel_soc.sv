`timescale 1ns/1ps

module picorv32_accel_soc #(
    parameter integer RAM_WORDS = 16384,
    parameter         MEM_INIT_FILE = ""
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        uart_rx,
    output logic        uart_tx,
    output logic        trap,
    output logic        accel_irq,
    output logic        test_done,
    output logic        test_pass,
    output logic [31:0] test_code
);

    localparam logic [31:0] RAM_BASE   = 32'h0000_0000;
    localparam logic [31:0] RAM_MASK   = 32'hffff_0000;
    localparam logic [31:0] HOST_BASE  = 32'h1000_0000;
    localparam logic [31:0] HOST_MASK  = 32'hffff_f000;
    localparam logic [31:0] UART_BASE  = 32'h2000_0000;
    localparam logic [31:0] UART_MASK  = 32'hffff_f000;
    localparam logic [31:0] ACCEL_BASE = 32'h4000_0000;
    localparam logic [31:0] ACCEL_MASK = 32'hffff_f000;

    logic        mem_valid;
    logic        mem_instr;
    logic        mem_ready;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [3:0]  mem_wstrb;
    logic [31:0] mem_rdata;

    logic        ram_sel;
    logic        host_sel;
    logic        uart_sel;
    logic        accel_sel;
    logic        ram_valid;
    logic        host_valid;
    logic        uart_valid;
    logic        accel_valid;

    logic        ram_ready;
    logic [31:0] ram_rdata;
    logic        host_ready;
    logic [31:0] host_rdata;
    logic        uart_ready;
    logic [31:0] uart_rdata;
    logic        accel_ready;
    logic [31:0] accel_rdata;

    logic        mem_la_read;
    logic        mem_la_write;
    logic [31:0] mem_la_addr;
    logic [31:0] mem_la_wdata;
    logic [3:0]  mem_la_wstrb;
    logic        pcpi_valid;
    logic [31:0] pcpi_insn;
    logic [31:0] pcpi_rs1;
    logic [31:0] pcpi_rs2;
    logic [31:0] eoi;
    logic        trace_valid;
    logic [35:0] trace_data;

    assign ram_sel   = ((mem_addr & RAM_MASK)   == RAM_BASE);
    assign host_sel  = ((mem_addr & HOST_MASK)  == HOST_BASE);
    assign uart_sel  = ((mem_addr & UART_MASK)  == UART_BASE);
    assign accel_sel = ((mem_addr & ACCEL_MASK) == ACCEL_BASE);

    assign ram_valid   = mem_valid && ram_sel;
    assign host_valid  = mem_valid && host_sel;
    assign uart_valid  = mem_valid && uart_sel;
    assign accel_valid = mem_valid && accel_sel;

    always_comb begin
        mem_ready = 1'b0;
        mem_rdata = 32'd0;

        if (ram_sel) begin
            mem_ready = ram_ready;
            mem_rdata = ram_rdata;
        end else if (host_sel) begin
            mem_ready = host_ready;
            mem_rdata = host_rdata;
        end else if (uart_sel) begin
            mem_ready = uart_ready;
            mem_rdata = uart_rdata;
        end else if (accel_sel) begin
            mem_ready = accel_ready;
            mem_rdata = accel_rdata;
        end else if (mem_valid) begin
            // PicoRV32 has no bus-error response. Finish unmapped accesses with
            // zero data so a software bug cannot deadlock the whole simulation.
            mem_ready = 1'b1;
            mem_rdata = 32'd0;
        end
    end

    picorv32 #(
        .PROGADDR_RESET  (32'h0000_0000),
        .STACKADDR       (32'h0001_0000),
        .ENABLE_COUNTERS (0),
        .ENABLE_IRQ      (0),
        .COMPRESSED_ISA  (0)
    ) cpu (
        .clk          (clk),
        .resetn       (resetn),
        .trap         (trap),
        .mem_valid    (mem_valid),
        .mem_instr    (mem_instr),
        .mem_ready    (mem_ready),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_wstrb    (mem_wstrb),
        .mem_rdata    (mem_rdata),
        .mem_la_read  (mem_la_read),
        .mem_la_write (mem_la_write),
        .mem_la_addr  (mem_la_addr),
        .mem_la_wdata (mem_la_wdata),
        .mem_la_wstrb (mem_la_wstrb),
        .pcpi_valid   (pcpi_valid),
        .pcpi_insn    (pcpi_insn),
        .pcpi_rs1     (pcpi_rs1),
        .pcpi_rs2     (pcpi_rs2),
        .pcpi_wr      (1'b0),
        .pcpi_rd      (32'd0),
        .pcpi_wait    (1'b0),
        .pcpi_ready   (1'b0),
        .irq          (32'd0),
        .eoi          (eoi),
        .trace_valid  (trace_valid),
        .trace_data   (trace_data)
    );

    simple_ram #(
        .MEM_WORDS     (RAM_WORDS),
        .MEM_INIT_FILE (MEM_INIT_FILE)
    ) ram (
        .clk       (clk),
        .rst_n     (resetn),
        .bus_valid (ram_valid),
        .bus_addr  (mem_addr),
        .bus_wdata (mem_wdata),
        .bus_wstrb (mem_wstrb),
        .bus_ready (ram_ready),
        .bus_rdata (ram_rdata)
    );

    accel_csr accelerator (
        .clk       (clk),
        .rst_n     (resetn),
        .bus_valid (accel_valid),
        .bus_addr  (mem_addr[7:0]),
        .bus_wdata (mem_wdata),
        .bus_wstrb (mem_wstrb),
        .bus_ready (accel_ready),
        .bus_rdata (accel_rdata),
        .irq       (accel_irq)
    );

    // 0x2000_0000: divider; 0x2000_0004: RX/TX data.  The wrapper also
    // synchronizes the asynchronous board RX pin before simpleuart samples it.
    uart_mmio #(
        .DEFAULT_DIV (1085)
    ) uart (
        .clk       (clk),
        .rst_n     (resetn),
        .bus_valid (uart_valid),
        .bus_addr  (mem_addr[7:0]),
        .bus_wdata (mem_wdata),
        .bus_wstrb (mem_wstrb),
        .bus_ready (uart_ready),
        .bus_rdata (uart_rdata),
        .uart_rx   (uart_rx),
        .uart_tx   (uart_tx)
    );

    soc_test_device host (
        .clk       (clk),
        .rst_n     (resetn),
        .bus_valid (host_valid),
        .bus_wdata (mem_wdata),
        .bus_wstrb (mem_wstrb),
        .bus_ready (host_ready),
        .bus_rdata (host_rdata),
        .test_done (test_done),
        .test_pass (test_pass),
        .test_code (test_code)
    );

endmodule

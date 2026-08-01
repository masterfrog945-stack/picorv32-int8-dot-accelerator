`timescale 1ns/1ps

// Self-checking PicoRV32 smoke test that does not require a RISC-V compiler.
// The tiny hand-encoded program computes 5 + 7 and stores 12 to address 0x100.
module tb_picorv32_smoke;

    logic        clk;
    logic        resetn;
    logic        trap;
    logic        mem_valid;
    logic        mem_instr;
    logic        mem_ready;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [3:0]  mem_wstrb;
    logic [31:0] mem_rdata;

    logic [31:0] memory [0:255];
    logic        expected_store_seen;
    int          cycle_count;
    integer      init_i;
    integer      byte_i;

    picorv32 #(
        .PROGADDR_RESET  (32'h0000_0000),
        .STACKADDR       (32'h0000_0400),
        .ENABLE_COUNTERS (0),
        .ENABLE_IRQ      (0)
    ) dut (
        .clk        (clk),
        .resetn     (resetn),
        .trap       (trap),
        .mem_valid  (mem_valid),
        .mem_instr  (mem_instr),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // One-cycle-latency memory model using the native PicoRV32 interface.
    always @(posedge clk) begin
        if (!resetn) begin
            mem_ready           <= 1'b0;
            mem_rdata           <= 32'd0;
            expected_store_seen <= 1'b0;
        end else begin
            mem_ready <= 1'b0;

            if (mem_valid && !mem_ready) begin
                mem_ready <= 1'b1;

                if (|mem_wstrb) begin
                    for (byte_i = 0; byte_i < 4; byte_i = byte_i + 1) begin
                        if (mem_wstrb[byte_i]) begin
                            memory[mem_addr[9:2]][byte_i*8 +: 8]
                                <= mem_wdata[byte_i*8 +: 8];
                        end
                    end

                    if (mem_addr == 32'h0000_0100) begin
                        if (mem_wstrb !== 4'b1111 || mem_wdata !== 32'd12) begin
                            $fatal(1,
                                "Unexpected store: strobe=%b data=%0d",
                                mem_wstrb, mem_wdata);
                        end
                        expected_store_seen <= 1'b1;
                    end
                end else begin
                    mem_rdata <= memory[mem_addr[9:2]];
                end
            end
        end
    end

    initial begin
        resetn     = 1'b0;
        cycle_count = 0;

        // Fill unused memory with NOPs (addi x0, x0, 0).
        for (init_i = 0; init_i < 256; init_i = init_i + 1) begin
            memory[init_i] = 32'h0000_0013;
        end

        // addi x1, x0, 5
        memory[0] = 32'h0050_0093;
        // addi x2, x0, 7
        memory[1] = 32'h0070_0113;
        // add x3, x1, x2
        memory[2] = 32'h0020_81b3;
        // sw x3, 0x100(x0)
        memory[3] = 32'h1030_2023;
        // jal x0, 0 (stop here after the observable store)
        memory[4] = 32'h0000_006f;

        repeat (5) @(posedge clk);
        resetn = 1'b1;

        while (!expected_store_seen && cycle_count < 300) begin
            @(posedge clk);
            cycle_count++;
            if (trap) begin
                $fatal(1, "PicoRV32 asserted trap before completing program");
            end
        end

        if (!expected_store_seen) begin
            $fatal(1, "Timeout waiting for PicoRV32 result store");
        end

        $display(
            "TEST_PASS: PicoRV32 executed RV32I smoke program in %0d cycles",
            cycle_count
        );
        $finish;
    end

endmodule

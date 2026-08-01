`timescale 1ns/1ps

module tb_picorv32_accel_soc;

    logic        clk;
    logic        resetn;
    logic        uart_rx;
    logic        uart_tx;
    logic        trap;
    logic        accel_irq;
    logic        test_done;
    logic        test_pass;
    logic [31:0] test_code;

    int cycle_count;
    logic [7:0] received_byte;

    localparam time UART_BIT_TIME = 8680ns;

    picorv32_accel_soc #(
        .RAM_WORDS     (16384),
        .MEM_INIT_FILE ("firmware.hex")
    ) dut (
        .clk       (clk),
        .resetn    (resetn),
        .uart_rx   (uart_rx),
        .uart_tx   (uart_tx),
        .trap      (trap),
        .accel_irq (accel_irq),
        .test_done (test_done),
        .test_pass (test_pass),
        .test_code (test_code)
    );

    initial clk = 1'b0;
    always #4 clk = ~clk;

    task automatic uart_send_byte(input logic [7:0] value);
        int bit_index;
        begin
            uart_rx = 1'b0;
            #(UART_BIT_TIME);
            for (bit_index = 0; bit_index < 8; bit_index++) begin
                uart_rx = value[bit_index];
                #(UART_BIT_TIME);
            end
            uart_rx = 1'b1;
            #(UART_BIT_TIME);
        end
    endtask

    task automatic uart_receive_byte(output logic [7:0] value);
        int bit_index;
        begin
            @(negedge uart_tx);
            #(UART_BIT_TIME + UART_BIT_TIME/2);
            for (bit_index = 0; bit_index < 8; bit_index++) begin
                value[bit_index] = uart_tx;
                #(UART_BIT_TIME);
            end
            if (uart_tx !== 1'b1)
                $fatal(1, "UART stop bit was not high");
            #(UART_BIT_TIME/2);
        end
    endtask

    task automatic check_uart_echo(input logic [7:0] value);
        begin
            fork
                uart_send_byte(value);
                uart_receive_byte(received_byte);
            join
            if (received_byte !== value)
                $fatal(1, "UART echo mismatch: sent %02h, received %02h", value, received_byte);
        end
    endtask

    initial begin
        resetn     = 1'b0;
        uart_rx     = 1'b1;
        cycle_count = 0;

        repeat (10) @(posedge clk);
        resetn = 1'b1;

        while (!test_done && cycle_count < 500000) begin
            @(posedge clk);
            cycle_count++;
            if (trap)
                $fatal(1, "PicoRV32 trapped at cycle %0d", cycle_count);
        end

        if (!test_done)
            $fatal(1, "SoC firmware timeout after %0d cycles", cycle_count);
        if (!test_pass)
            $fatal(1, "SoC firmware reported failure code %08h", test_code);

        $display(
            "TEST_PASS: PicoRV32 C firmware called INT8 accelerator successfully in %0d cycles",
            cycle_count
        );

        // Exercise edge cases and alternating patterns through the complete
        // serial receiver -> firmware/MMIO -> serial transmitter path.
        check_uart_echo(8'h00);
        check_uart_echo(8'h55);
        check_uart_echo(8'ha5);
        check_uart_echo(8'hff);
        $display("UART_ECHO_PASS: 4 bytes echoed at 115200 baud, 8N1");
        $finish;
    end

    initial begin
        #20ms;
        $fatal(1, "Global SoC/UART simulation watchdog expired");
    end

endmodule

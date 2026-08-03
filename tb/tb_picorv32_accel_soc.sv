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
    logic [7:0] request_payload  [0:63];
    logic [7:0] response_payload [0:64];
    logic [7:0] response_command;
    logic [7:0] response_sequence;
    integer     response_length;

    localparam time UART_BIT_TIME = 8680ns;
    localparam logic [7:0] MAGIC0 = 8'ha5;
    localparam logic [7:0] MAGIC1 = 8'h5a;
    localparam logic [7:0] VERSION = 8'h01;
    localparam logic [7:0] CMD_PING = 8'h01;
    localparam logic [7:0] CMD_ECHO = 8'h03;
    localparam logic [7:0] CMD_DOT4_ACCEL = 8'h10;

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

    function automatic [15:0] crc16_byte(
        input [15:0] crc_in,
        input [7:0]  value
    );
        integer bit_index;
        reg [15:0] crc;
        begin
            crc = crc_in ^ {value, 8'h00};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (crc[15])
                    crc = (crc << 1) ^ 16'h1021;
                else
                    crc = crc << 1;
            end
            crc16_byte = crc;
        end
    endfunction

    task automatic uart_send_byte(input logic [7:0] value);
        int bit_index;
        begin
            uart_rx = 1'b0;
            #(UART_BIT_TIME);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
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
            wait (uart_tx === 1'b0);
            #(UART_BIT_TIME + UART_BIT_TIME/2);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                value[bit_index] = uart_tx;
                #(UART_BIT_TIME);
            end
            if (uart_tx !== 1'b1)
                $fatal(1, "UART stop bit was not high");
            #(UART_BIT_TIME/2);
        end
    endtask

    task automatic send_request(
        input logic [7:0] command,
        input logic [7:0] sequence_id,
        input integer payload_length,
        input logic corrupt_crc
    );
        integer index;
        reg [15:0] crc;
        begin
            crc = 16'hffff;
            uart_send_byte(MAGIC0);
            uart_send_byte(MAGIC1);

            uart_send_byte(VERSION);
            crc = crc16_byte(crc, VERSION);
            uart_send_byte(command);
            crc = crc16_byte(crc, command);
            uart_send_byte(sequence_id);
            crc = crc16_byte(crc, sequence_id);
            uart_send_byte(payload_length[7:0]);
            crc = crc16_byte(crc, payload_length[7:0]);
            uart_send_byte(payload_length[15:8]);
            crc = crc16_byte(crc, payload_length[15:8]);

            for (index = 0; index < payload_length; index = index + 1) begin
                uart_send_byte(request_payload[index]);
                crc = crc16_byte(crc, request_payload[index]);
            end
            if (corrupt_crc)
                crc = crc ^ 16'h0100;
            uart_send_byte(crc[7:0]);
            uart_send_byte(crc[15:8]);
        end
    endtask

    task automatic receive_response;
        integer index;
        reg [7:0] value;
        reg [7:0] length_low;
        reg [7:0] length_high;
        reg [7:0] crc_low;
        reg [7:0] crc_high;
        reg [15:0] crc;
        begin
            uart_receive_byte(value);
            if (value !== MAGIC0)
                $fatal(1, "Bad response magic[0]: %02h", value);
            uart_receive_byte(value);
            if (value !== MAGIC1)
                $fatal(1, "Bad response magic[1]: %02h", value);

            crc = 16'hffff;
            uart_receive_byte(value);
            if (value !== VERSION)
                $fatal(1, "Bad response protocol version: %02h", value);
            crc = crc16_byte(crc, value);

            uart_receive_byte(response_command);
            crc = crc16_byte(crc, response_command);
            uart_receive_byte(response_sequence);
            crc = crc16_byte(crc, response_sequence);
            uart_receive_byte(length_low);
            crc = crc16_byte(crc, length_low);
            uart_receive_byte(length_high);
            crc = crc16_byte(crc, length_high);
            response_length = {length_high, length_low};
            if (response_length > 65)
                $fatal(1, "Response payload is too large: %0d", response_length);

            for (index = 0; index < response_length; index = index + 1) begin
                uart_receive_byte(response_payload[index]);
                crc = crc16_byte(crc, response_payload[index]);
            end
            uart_receive_byte(crc_low);
            uart_receive_byte(crc_high);
            if ({crc_high, crc_low} !== crc)
                $fatal(1, "Response CRC mismatch: got %04h expected %04h",
                       {crc_high, crc_low}, crc);
        end
    endtask

    task automatic transact_and_receive(
        input logic [7:0] command,
        input logic [7:0] sequence_id,
        input integer payload_length,
        input logic corrupt_crc
    );
        begin
            fork
                send_request(command, sequence_id, payload_length, corrupt_crc);
                receive_response();
            join
            if (response_command !== (command | 8'h80))
                $fatal(1, "Response command mismatch: %02h", response_command);
            if (response_sequence !== sequence_id)
                $fatal(1, "Response sequence mismatch: %02h", response_sequence);
        end
    endtask

    initial begin : run_test
        integer index;

        resetn      = 1'b0;
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

        // PING validates framing, CRC, command dispatch, and a short response.
        transact_and_receive(CMD_PING, 8'h11, 0, 1'b0);
        if (response_length != 5 || response_payload[0] !== 8'h00
                || response_payload[1] !== "P" || response_payload[2] !== "O"
                || response_payload[3] !== "N" || response_payload[4] !== "G")
            $fatal(1, "PING response was invalid");

        // A payload equal to FIFO depth stresses streaming receive/consume and
        // forces the TX FIFO/full backpressure path in the larger response.
        for (index = 0; index < 32; index = index + 1)
            request_payload[index] = (index * 7 + 3) & 8'hff;
        transact_and_receive(CMD_ECHO, 8'h22, 32, 1'b0);
        if (response_length != 33 || response_payload[0] !== 8'h00)
            $fatal(1, "ECHO response header/status was invalid");
        for (index = 0; index < 32; index = index + 1) begin
            if (response_payload[index + 1] !== request_payload[index])
                $fatal(1, "ECHO mismatch at byte %0d", index);
        end

        // Signed INT8 vectors: [1,-2,3,-4] dot [5,6,7,8] = -18.
        request_payload[0] = 8'h01;
        request_payload[1] = 8'hfe;
        request_payload[2] = 8'h03;
        request_payload[3] = 8'hfc;
        request_payload[4] = 8'h05;
        request_payload[5] = 8'h06;
        request_payload[6] = 8'h07;
        request_payload[7] = 8'h08;
        transact_and_receive(CMD_DOT4_ACCEL, 8'h33, 8, 1'b0);
        if (response_length != 9 || response_payload[0] !== 8'h00
                || {response_payload[4], response_payload[3],
                    response_payload[2], response_payload[1]} !== 32'hffff_ffee)
            $fatal(1, "DOT4 accelerator response was invalid");

        // A corrupted request must be rejected, proving CRC is checked rather
        // than merely appended by the host and ignored by firmware.
        transact_and_receive(CMD_PING, 8'h44, 0, 1'b1);
        if (response_length != 1 || response_payload[0] !== 8'h03)
            $fatal(1, "Corrupted request CRC was not rejected");

        $display("UART_ECHO_PASS: framed FIFO echo, CRC rejection, and DOT4 command passed");
        $finish;
    end

    initial begin
        #30ms;
        $fatal(1, "Global SoC/UART simulation watchdog expired");
    end

endmodule

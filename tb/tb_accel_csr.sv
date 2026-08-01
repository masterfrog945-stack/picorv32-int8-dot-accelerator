`timescale 1ns/1ps

module tb_accel_csr;

    localparam logic [7:0] ADDR_CTRL       = 8'h00;
    localparam logic [7:0] ADDR_STATUS     = 8'h04;
    localparam logic [7:0] ADDR_VECTOR_A   = 8'h08;
    localparam logic [7:0] ADDR_VECTOR_B   = 8'h0c;
    localparam logic [7:0] ADDR_RESULT     = 8'h10;
    localparam logic [7:0] ADDR_IRQ_ENABLE = 8'h14;
    localparam logic [7:0] ADDR_IRQ_STATUS = 8'h18;

    logic        clk;
    logic        rst_n;
    logic        bus_valid;
    logic [7:0]  bus_addr;
    logic [31:0] bus_wdata;
    logic [3:0]  bus_wstrb;
    logic        bus_ready;
    logic [31:0] bus_rdata;
    logic        irq;

    int pass_count;

    accel_csr dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .bus_valid (bus_valid),
        .bus_addr  (bus_addr),
        .bus_wdata (bus_wdata),
        .bus_wstrb (bus_wstrb),
        .bus_ready (bus_ready),
        .bus_rdata (bus_rdata),
        .irq       (irq)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic logic signed [31:0] reference_dot(
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic signed [7:0] av;
        logic signed [7:0] bv;
        logic signed [31:0] sum;
        begin
            sum = 32'sd0;
            for (int i = 0; i < 4; i++) begin
                av = $signed(a[i*8 +: 8]);
                bv = $signed(b[i*8 +: 8]);
                sum = sum + av * bv;
            end
            reference_dot = sum;
        end
    endfunction

    task automatic bus_write(
        input logic [7:0]  addr,
        input logic [31:0] data,
        input logic [3:0]  strb
    );
        int timeout;
        begin
            @(negedge clk);
            bus_valid = 1'b1;
            bus_addr  = addr;
            bus_wdata = data;
            bus_wstrb = strb;

            timeout = 0;
            while (!bus_ready && timeout < 10) begin
                @(negedge clk);
                timeout++;
            end
            if (!bus_ready) $fatal(1, "CSR write timeout at %02h", addr);

            bus_valid = 1'b0;
            bus_wstrb = 4'b0000;
            @(negedge clk);
        end
    endtask

    task automatic bus_read(
        input  logic [7:0]  addr,
        output logic [31:0] data
    );
        int timeout;
        begin
            @(negedge clk);
            bus_valid = 1'b1;
            bus_addr  = addr;
            bus_wdata = 32'd0;
            bus_wstrb = 4'b0000;

            timeout = 0;
            while (!bus_ready && timeout < 10) begin
                @(negedge clk);
                timeout++;
            end
            if (!bus_ready) $fatal(1, "CSR read timeout at %02h", addr);
            data = bus_rdata;

            bus_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic run_mmio_case(
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic [31:0] status;
        logic [31:0] actual;
        logic signed [31:0] expected;
        int polls;
        begin
            expected = reference_dot(a, b);

            bus_write(ADDR_IRQ_STATUS, 32'h1, 4'b0001);
            bus_write(ADDR_VECTOR_A, a, 4'b1111);
            bus_write(ADDR_VECTOR_B, b, 4'b1111);
            bus_write(ADDR_CTRL, 32'h1, 4'b0001);

            status = 32'd0;
            polls  = 0;
            while (!status[1] && polls < 20) begin
                bus_read(ADDR_STATUS, status);
                polls++;
            end
            if (!status[1]) $fatal(1, "CSR operation did not complete");

            bus_read(ADDR_RESULT, actual);
            if ($signed(actual) !== expected) begin
                $fatal(1,
                    "CSR result mismatch: a=%08h b=%08h expected=%0d actual=%0d",
                    a, b, expected, $signed(actual));
            end
            if (!irq) $fatal(1, "IRQ was not asserted for completed operation");

            bus_write(ADDR_IRQ_STATUS, 32'h1, 4'b0001);
            bus_read(ADDR_STATUS, status);
            if (status[1] || irq)
                $fatal(1, "W1C did not clear done_pending/irq");

            pass_count++;
        end
    endtask

    initial begin
        logic [31:0] readback;
        logic [31:0] random_a;
        logic [31:0] random_b;

        rst_n      = 1'b0;
        bus_valid  = 1'b0;
        bus_addr   = 8'd0;
        bus_wdata  = 32'd0;
        bus_wstrb  = 4'd0;
        pass_count = 0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // Verify byte strobes independently from computation.
        bus_write(ADDR_VECTOR_A, 32'h0000_0000, 4'b1111);
        bus_write(ADDR_VECTOR_A, 32'haa00_cc00, 4'b1010);
        bus_read(ADDR_VECTOR_A, readback);
        if (readback !== 32'haa00_cc00)
            $fatal(1, "Byte strobe merge failed: %08h", readback);

        bus_read(8'hfc, readback);
        if (readback !== 32'd0)
            $fatal(1, "Unmapped CSR read must return zero");

        bus_write(ADDR_IRQ_ENABLE, 32'h1, 4'b0001);
        run_mmio_case(32'hfc03_fe01, 32'h08f9_0605);
        run_mmio_case(32'h8080_8080, 32'h8080_8080);
        run_mmio_case(32'h7f7f_7f7f, 32'h8080_8080);

        for (int test_id = 0; test_id < 200; test_id++) begin
            random_a = $urandom;
            random_b = $urandom;
            run_mmio_case(random_a, random_b);
        end

        $display("TEST_PASS: accel_csr passed %0d MMIO operations", pass_count);
        $finish;
    end

endmodule


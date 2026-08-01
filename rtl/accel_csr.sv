`timescale 1ns/1ps

// Memory-mapped CSR wrapper for int8_dot_accel.
//
// Bus protocol: the master holds bus_valid/address/data until bus_ready is
// observed. A non-zero bus_wstrb denotes a write; zero denotes a read.
module accel_csr (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        bus_valid,
    input  logic [7:0]  bus_addr,
    input  logic [31:0] bus_wdata,
    input  logic [3:0]  bus_wstrb,
    output logic        bus_ready,
    output logic [31:0] bus_rdata,

    output logic        irq
);

    localparam logic [7:0] ADDR_CTRL       = 8'h00;
    localparam logic [7:0] ADDR_STATUS     = 8'h04;
    localparam logic [7:0] ADDR_VECTOR_A   = 8'h08;
    localparam logic [7:0] ADDR_VECTOR_B   = 8'h0c;
    localparam logic [7:0] ADDR_RESULT     = 8'h10;
    localparam logic [7:0] ADDR_IRQ_ENABLE = 8'h14;
    localparam logic [7:0] ADDR_IRQ_STATUS = 8'h18;

    logic [31:0] vector_a_q;
    logic [31:0] vector_b_q;
    logic        irq_enable_q;
    logic        done_pending_q;

    logic               core_start;
    logic               core_busy;
    logic               core_done;
    logic signed [31:0] core_result;

    integer byte_lane;

    int8_dot_accel core (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (core_start),
        .vector_a (vector_a_q),
        .vector_b (vector_b_q),
        .busy     (core_busy),
        .done     (core_done),
        .result   (core_result)
    );

    assign irq = irq_enable_q && done_pending_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            vector_a_q     <= 32'd0;
            vector_b_q     <= 32'd0;
            irq_enable_q   <= 1'b0;
            done_pending_q <= 1'b0;
            core_start     <= 1'b0;
            bus_ready      <= 1'b0;
            bus_rdata      <= 32'd0;
        end else begin
            bus_ready  <= 1'b0;
            core_start <= 1'b0;

            if (bus_valid && !bus_ready) begin
                bus_ready <= 1'b1;

                // Read data is registered and held until the next request.
                case (bus_addr)
                    ADDR_CTRL:       bus_rdata <= 32'd0;
                    ADDR_STATUS:     bus_rdata <= {30'd0, done_pending_q, core_busy};
                    ADDR_VECTOR_A:   bus_rdata <= vector_a_q;
                    ADDR_VECTOR_B:   bus_rdata <= vector_b_q;
                    ADDR_RESULT:     bus_rdata <= core_result;
                    ADDR_IRQ_ENABLE: bus_rdata <= {31'd0, irq_enable_q};
                    ADDR_IRQ_STATUS: bus_rdata <= {31'd0, done_pending_q};
                    default:         bus_rdata <= 32'd0;
                endcase

                if (|bus_wstrb) begin
                    case (bus_addr)
                        ADDR_CTRL: begin
                            if (bus_wstrb[0] && bus_wdata[0] && !core_busy)
                                core_start <= 1'b1;
                        end

                        ADDR_STATUS: begin
                            // STATUS[1] is write-one-to-clear.
                            if (bus_wstrb[0] && bus_wdata[1])
                                done_pending_q <= 1'b0;
                        end

                        ADDR_VECTOR_A: begin
                            for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1) begin
                                if (bus_wstrb[byte_lane])
                                    vector_a_q[byte_lane*8 +: 8]
                                        <= bus_wdata[byte_lane*8 +: 8];
                            end
                        end

                        ADDR_VECTOR_B: begin
                            for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1) begin
                                if (bus_wstrb[byte_lane])
                                    vector_b_q[byte_lane*8 +: 8]
                                        <= bus_wdata[byte_lane*8 +: 8];
                            end
                        end

                        ADDR_IRQ_ENABLE: begin
                            if (bus_wstrb[0])
                                irq_enable_q <= bus_wdata[0];
                        end

                        ADDR_IRQ_STATUS: begin
                            // IRQ_STATUS[0] is write-one-to-clear.
                            if (bus_wstrb[0] && bus_wdata[0])
                                done_pending_q <= 1'b0;
                        end

                        default: begin
                            // Read-only and unmapped writes have no effect.
                        end
                    endcase
                end
            end

            // Completion wins over a simultaneous software clear, preventing
            // a newly completed operation from being lost.
            if (core_done)
                done_pending_q <= 1'b1;
        end
    end

endmodule


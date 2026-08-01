`timescale 1ns/1ps

// Four-lane signed INT8 dot-product accelerator.
//
// The module deliberately keeps the compute core independent from any bus.
// A later AXI/CSR wrapper can reuse this block without mixing protocol and
// arithmetic logic.
module int8_dot_accel (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               start,
    input  logic        [31:0] vector_a,
    input  logic        [31:0] vector_b,

    output logic               busy,
    output logic               done,
    output logic signed [31:0] result
);

    logic signed [7:0]  a_q       [0:3];
    logic signed [7:0]  b_q       [0:3];
    logic signed [15:0] product_q [0:3];

    logic stage1_valid;
    logic stage2_valid;
    logic signed [31:0] product_sum;

    integer lane;

    // Sign-extend every product before addition. Adding the 16-bit products
    // directly could overflow before the value is assigned to the 32-bit
    // result register.
    always_comb begin
        product_sum = 32'sd0;
        for (int i = 0; i < 4; i++) begin
            product_sum = product_sum
                        + {{16{product_q[i][15]}}, product_q[i]};
        end
    end

    // Three logical stages:
    //   accept/latch input -> four parallel multiplies -> accumulation/output
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy         <= 1'b0;
            done         <= 1'b0;
            result       <= 32'sd0;
            stage1_valid <= 1'b0;
            stage2_valid <= 1'b0;

            for (lane = 0; lane < 4; lane = lane + 1) begin
                a_q[lane]       <= 8'sd0;
                b_q[lane]       <= 8'sd0;
                product_q[lane] <= 16'sd0;
            end
        end else begin
            // done is a one-cycle completion pulse.
            done         <= 1'b0;
            stage1_valid <= 1'b0;
            stage2_valid <= stage1_valid;

            // Requests presented while busy are intentionally ignored. The
            // future CSR wrapper will expose busy so software cannot overwrite
            // an in-flight operation.
            if (start && !busy) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    a_q[lane] <= $signed(vector_a[lane*8 +: 8]);
                    b_q[lane] <= $signed(vector_b[lane*8 +: 8]);
                end
                busy         <= 1'b1;
                stage1_valid <= 1'b1;
            end

            if (stage1_valid) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    product_q[lane] <= a_q[lane] * b_q[lane];
                end
            end

            if (stage2_valid) begin
                result <= product_sum;
                busy   <= 1'b0;
                done   <= 1'b1;
            end
        end
    end

endmodule


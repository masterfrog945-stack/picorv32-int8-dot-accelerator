`timescale 1ns/1ps

module tb_int8_dot_accel;

    logic               clk;
    logic               rst_n;
    logic               start;
    logic        [31:0] vector_a;
    logic        [31:0] vector_b;
    logic               busy;
    logic               done;
    logic signed [31:0] result;

    int pass_count;
    int cov_zero_result;
    int cov_positive_result;
    int cov_negative_result;
    int cov_min_value;
    int cov_max_value;
    int cov_mixed_sign;
    int cov_busy_restart;
    int cov_reset_abort;

    int8_dot_accel dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .vector_a (vector_a),
        .vector_b (vector_b),
        .busy     (busy),
        .done     (done),
        .result   (result)
    );

`ifdef ENABLE_SVA
    int8_dot_assertions protocol_assertions (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (start),
        .busy   (busy),
        .done   (done),
        .result (result)
    );
`endif

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic logic [31:0] pack4(
        input logic signed [7:0] x0,
        input logic signed [7:0] x1,
        input logic signed [7:0] x2,
        input logic signed [7:0] x3
    );
        pack4 = {x3, x2, x1, x0};
    endfunction

    function automatic logic signed [31:0] reference_dot(
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic signed [7:0]  av;
        logic signed [7:0]  bv;
        logic signed [31:0] sum;
        int i;
        begin
            sum = 32'sd0;
            for (i = 0; i < 4; i++) begin
                av  = $signed(a[i*8 +: 8]);
                bv  = $signed(b[i*8 +: 8]);
                sum = sum + av * bv;
            end
            reference_dot = sum;
        end
    endfunction

    function automatic bit contains_byte(
        input logic [31:0] value,
        input logic [7:0] target
    );
        contains_byte = (value[7:0]   == target)
                     || (value[15:8]  == target)
                     || (value[23:16] == target)
                     || (value[31:24] == target);
    endfunction

    task automatic sample_functional_coverage(
        input logic [31:0] a,
        input logic [31:0] b,
        input logic signed [31:0] expected
    );
        bit has_negative;
        bit has_nonnegative;
        logic signed [7:0] av;
        logic signed [7:0] bv;
        begin
            has_negative    = 1'b0;
            has_nonnegative = 1'b0;
            for (int i = 0; i < 4; i++) begin
                av = $signed(a[i*8 +: 8]);
                bv = $signed(b[i*8 +: 8]);
                if (av < 0 || bv < 0) has_negative = 1'b1;
                if (av >= 0 || bv >= 0) has_nonnegative = 1'b1;
            end

            if (expected == 0) cov_zero_result++;
            if (expected > 0)  cov_positive_result++;
            if (expected < 0)  cov_negative_result++;
            if (contains_byte(a, 8'h80) || contains_byte(b, 8'h80))
                cov_min_value++;
            if (contains_byte(a, 8'h7f) || contains_byte(b, 8'h7f))
                cov_max_value++;
            if (has_negative && has_nonnegative) cov_mixed_sign++;
        end
    endtask

    task automatic run_case(
        input logic [31:0] a,
        input logic [31:0] b,
        input logic signed [31:0] expected
    );
        int timeout;
        begin
            while (busy) @(negedge clk);

            @(negedge clk);
            vector_a = a;
            vector_b = b;
            start    = 1'b1;

            @(negedge clk);
            start = 1'b0;

            timeout = 0;
            while (!done && timeout < 10) begin
                @(negedge clk);
                timeout++;
            end

            if (!done) begin
                $fatal(1, "Timeout: accelerator did not assert done");
            end
            if (busy) begin
                $fatal(1, "Protocol error: busy remained high with done");
            end
            if (result !== expected) begin
                $fatal(1,
                    "Mismatch: a=%08h b=%08h expected=%0d actual=%0d",
                    a, b, expected, result);
            end

            pass_count++;
            sample_functional_coverage(a, b, expected);
            @(negedge clk);
            if (done) begin
                $fatal(1, "Protocol error: done must be a one-cycle pulse");
            end
        end
    endtask

    task automatic test_busy_rejects_second_start;
        logic [31:0] original_a;
        logic [31:0] original_b;
        logic signed [31:0] expected;
        int timeout;
        begin
            original_a = pack4(8'sd1, -8'sd2, 8'sd3, -8'sd4);
            original_b = pack4(8'sd5,  8'sd6, -8'sd7, 8'sd8);
            expected   = reference_dot(original_a, original_b);

            @(negedge clk);
            vector_a = original_a;
            vector_b = original_b;
            start    = 1'b1;

            // The first request is accepted at the intervening rising edge.
            // Present a different request while busy; it must be ignored.
            @(negedge clk);
            vector_a = pack4(8'sd9, 8'sd9, 8'sd9, 8'sd9);
            vector_b = pack4(8'sd9, 8'sd9, 8'sd9, 8'sd9);
            start    = 1'b1;

            @(negedge clk);
            start = 1'b0;

            timeout = 0;
            while (!done && timeout < 10) begin
                @(negedge clk);
                timeout++;
            end

            if (!done || result !== expected) begin
                $fatal(1,
                    "Busy handling failed: expected=%0d actual=%0d",
                    expected, result);
            end
            pass_count++;
            cov_busy_restart++;
            @(negedge clk);
        end
    endtask

    task automatic test_reset_aborts_operation;
        begin
            @(negedge clk);
            vector_a = 32'h7f7f7f7f;
            vector_b = 32'h7f7f7f7f;
            start    = 1'b1;

            @(negedge clk);
            start = 1'b0;
            rst_n = 1'b0;

            @(negedge clk);
            if (busy || done) begin
                $fatal(1, "Reset did not clear busy/done");
            end
            cov_reset_abort++;
            rst_n = 1'b1;
            @(negedge clk);

            // Prove that a new operation works after the aborted operation.
            run_case(
                pack4(8'sd2, 8'sd3, 8'sd4, 8'sd5),
                pack4(8'sd6, 8'sd7, 8'sd8, 8'sd9),
                32'sd110
            );
        end
    endtask

    initial begin
        logic [31:0] random_a;
        logic [31:0] random_b;

        rst_n      = 1'b0;
        start      = 1'b0;
        vector_a   = 32'd0;
        vector_b   = 32'd0;
        pass_count = 0;
        cov_zero_result     = 0;
        cov_positive_result = 0;
        cov_negative_result = 0;
        cov_min_value       = 0;
        cov_max_value       = 0;
        cov_mixed_sign      = 0;
        cov_busy_restart    = 0;
        cov_reset_abort     = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        run_case(32'd0, 32'd0, 32'sd0);
        run_case(
            pack4(8'sd1, 8'sd1, 8'sd1, 8'sd1),
            pack4(8'sd1, 8'sd1, 8'sd1, 8'sd1),
            32'sd4
        );
        run_case(
            pack4(8'sd1, -8'sd2, 8'sd3, -8'sd4),
            pack4(8'sd5,  8'sd6, -8'sd7, 8'sd8),
            -32'sd60
        );
        run_case(
            pack4(-8'sd128, -8'sd128, -8'sd128, -8'sd128),
            pack4(-8'sd128, -8'sd128, -8'sd128, -8'sd128),
            32'sd65536
        );
        run_case(
            pack4(-8'sd128, -8'sd128, -8'sd128, -8'sd128),
            pack4(8'sd127, 8'sd127, 8'sd127, 8'sd127),
            -32'sd65024
        );

        test_busy_rejects_second_start();
        test_reset_aborts_operation();

        for (int test_id = 0; test_id < 1000; test_id++) begin
            random_a = $urandom;
            random_b = $urandom;
            run_case(random_a, random_b, reference_dot(random_a, random_b));
        end

        if (cov_zero_result == 0 || cov_positive_result == 0
            || cov_negative_result == 0 || cov_min_value == 0
            || cov_max_value == 0 || cov_mixed_sign == 0
            || cov_busy_restart == 0 || cov_reset_abort == 0) begin
            $fatal(1,
                "Coverage goal missing: zero=%0d pos=%0d neg=%0d min=%0d max=%0d mixed=%0d busy=%0d reset=%0d",
                cov_zero_result, cov_positive_result, cov_negative_result,
                cov_min_value, cov_max_value, cov_mixed_sign,
                cov_busy_restart, cov_reset_abort);
        end

        $display("COVERAGE_PASS: 8/8 functional coverage goals hit");
        $display("TEST_PASS: int8_dot_accel passed %0d cases", pass_count);
        $finish;
    end

endmodule

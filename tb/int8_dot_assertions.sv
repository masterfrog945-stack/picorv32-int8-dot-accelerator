`timescale 1ns/1ps

// Protocol/timing assertions for the current fixed-latency compute core.
// Keep these outside the synthesizable DUT so the same core can be reused
// without verification-only code.
module int8_dot_assertions (
    input logic               clk,
    input logic               rst_n,
    input logic               start,
    input logic               busy,
    input logic               done,
    input logic signed [31:0] result
);

    // A request accepted while idle remains busy at the next two SVA sampling
    // points. done is visible at the following sampling point because the DUT
    // updates it in the NBA region of the completion edge.
    property p_accepted_request_completes;
        @(posedge clk) disable iff (!rst_n)
        (start && !busy) |=> busy ##1 busy ##1 done;
    endproperty

    property p_done_is_single_cycle;
        @(posedge clk) disable iff (!rst_n)
        done |=> !done;
    endproperty

    property p_done_implies_idle;
        @(posedge clk) disable iff (!rst_n)
        done |-> !busy;
    endproperty

    property p_result_stable_during_compute;
        @(posedge clk) disable iff (!rst_n)
        busy |-> $stable(result);
    endproperty

    property p_reset_clears_protocol_state;
        @(posedge clk)
        !rst_n |=> (!busy && !done);
    endproperty

    assert property (p_accepted_request_completes)
        else $fatal(1, "ASSERT: accepted request did not complete on schedule");
    assert property (p_done_is_single_cycle)
        else $fatal(1, "ASSERT: done was high for more than one cycle");
    assert property (p_done_implies_idle)
        else $fatal(1, "ASSERT: done and busy were high together");
    assert property (p_result_stable_during_compute)
        else $fatal(1, "ASSERT: result changed before completion");
    assert property (p_reset_clears_protocol_state)
        else $fatal(1, "ASSERT: reset did not clear busy/done");

endmodule

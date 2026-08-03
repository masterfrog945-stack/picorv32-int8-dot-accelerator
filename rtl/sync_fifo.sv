`timescale 1ns/1ps

// Small single-clock FIFO used by the UART MMIO peripheral.
// The producer and consumer both run on clk, so no Gray-code pointers or
// clock-domain-crossing logic are required.
module sync_fifo #(
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH      = 32
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          push,
    input  logic [DATA_WIDTH-1:0]         push_data,
    input  logic                          pop,
    output logic [DATA_WIDTH-1:0]         pop_data,
    output logic                          empty,
    output logic                          full,
    output logic [$clog2(DEPTH+1)-1:0]    level
);

    localparam integer PTR_WIDTH = $clog2(DEPTH);

    logic [DATA_WIDTH-1:0] storage [0:DEPTH-1];
    logic [PTR_WIDTH-1:0]  write_ptr;
    logic [PTR_WIDTH-1:0]  read_ptr;
    logic                  do_push;
    logic                  do_pop;

    assign empty    = (level == 0);
    assign full     = (level == DEPTH);
    assign pop_data = storage[read_ptr];

    // A simultaneous pop makes room for a push even when the FIFO was full.
    assign do_pop  = pop && !empty;
    assign do_push = push && (!full || do_pop);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_ptr <= '0;
            read_ptr  <= '0;
            level     <= '0;
        end else begin
            if (do_push) begin
                storage[write_ptr] <= push_data;
                write_ptr <= write_ptr + 1'b1;
            end

            if (do_pop)
                read_ptr <= read_ptr + 1'b1;

            case ({do_push, do_pop})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: level <= level;
            endcase
        end
    end

endmodule

`timescale 1ns/1ps

// 8N1 UART transmitter with a ready/valid byte interface.
module uart_tx_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] clocks_per_bit,
    input  logic [7:0]  data,
    input  logic        data_valid,
    output logic        data_ready,
    output logic        serial_tx
);

    logic [9:0]  shift_reg;
    logic [3:0]  bit_index;
    logic [15:0] clock_count;
    logic [15:0] bit_cycles;
    logic        busy;

    assign bit_cycles = (clocks_per_bit < 16'd4) ? 16'd4 : clocks_per_bit;
    assign data_ready = !busy;
    assign serial_tx  = busy ? shift_reg[0] : 1'b1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            shift_reg   <= 10'h3ff;
            bit_index   <= 4'd0;
            clock_count <= 16'd0;
            busy        <= 1'b0;
        end else begin
            if (!busy) begin
                clock_count <= 16'd0;
                bit_index   <= 4'd0;
                if (data_valid) begin
                    // start, eight LSB-first data bits, stop
                    shift_reg <= {1'b1, data, 1'b0};
                    busy      <= 1'b1;
                end
            end else if (clock_count >= bit_cycles - 1'b1) begin
                clock_count <= 16'd0;
                if (bit_index == 4'd9) begin
                    busy <= 1'b0;
                end else begin
                    shift_reg <= {1'b1, shift_reg[9:1]};
                    bit_index <= bit_index + 1'b1;
                end
            end else begin
                clock_count <= clock_count + 1'b1;
            end
        end
    end

endmodule

`timescale 1ns/1ps

// 8N1 UART receiver. serial_rx must already be synchronized to clk.
// A byte-valid pulse is produced only after a valid high stop bit.
module uart_rx_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] clocks_per_bit,
    input  logic        serial_rx,
    output logic [7:0]  data,
    output logic        data_valid,
    output logic        framing_error,
    output logic        false_start
);

    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_t;

    rx_state_t  state;
    logic [15:0] clock_count;
    logic [2:0]  bit_index;
    logic [7:0]  shift_reg;
    logic [15:0] bit_cycles;
    logic [15:0] half_cycles;
    logic        sample_early;
    logic        sample_middle;
    logic        sample_majority;

    always_comb begin
        bit_cycles  = (clocks_per_bit < 16'd4) ? 16'd4 : clocks_per_bit;
        half_cycles = bit_cycles >> 1;
        sample_majority = (sample_early & sample_middle)
                        | (sample_early & serial_rx)
                        | (sample_middle & serial_rx);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state         <= RX_IDLE;
            clock_count   <= 16'd0;
            bit_index     <= 3'd0;
            shift_reg     <= 8'd0;
            sample_early  <= 1'b1;
            sample_middle <= 1'b1;
            data          <= 8'd0;
            data_valid    <= 1'b0;
            framing_error <= 1'b0;
            false_start   <= 1'b0;
        end else begin
            data_valid    <= 1'b0;
            framing_error <= 1'b0;
            false_start   <= 1'b0;

            case (state)
                RX_IDLE: begin
                    clock_count <= 16'd0;
                    bit_index   <= 3'd0;
                    if (!serial_rx)
                        state <= RX_START;
                end

                RX_START: begin
                    if (clock_count >= half_cycles - 1'b1) begin
                        clock_count <= 16'd0;
                        if (!serial_rx) begin
                            state <= RX_DATA;
                        end else begin
                            // The line returned high before the middle of the
                            // start bit, so this was a glitch rather than data.
                            false_start <= 1'b1;
                            state       <= RX_IDLE;
                        end
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end

                RX_DATA: begin
                    // Vote three adjacent sysclk samples around the nominal
                    // bit centre. This rejects a one-sample input glitch while
                    // preserving the same clocks-per-bit timing and 8N1 wire
                    // format as the original single-sample receiver.
                    if (clock_count == bit_cycles - 16'd3)
                        sample_early <= serial_rx;
                    if (clock_count == bit_cycles - 16'd2)
                        sample_middle <= serial_rx;

                    if (clock_count >= bit_cycles - 1'b1) begin
                        clock_count         <= 16'd0;
                        shift_reg[bit_index] <= sample_majority;
                        if (bit_index == 3'd7) begin
                            state <= RX_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end

                RX_STOP: begin
                    if (clock_count == bit_cycles - 16'd3)
                        sample_early <= serial_rx;
                    if (clock_count == bit_cycles - 16'd2)
                        sample_middle <= serial_rx;

                    if (clock_count >= bit_cycles - 1'b1) begin
                        clock_count <= 16'd0;
                        state       <= RX_IDLE;
                        if (sample_majority) begin
                            data       <= shift_reg;
                            data_valid <= 1'b1;
                        end else begin
                            framing_error <= 1'b1;
                        end
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end

                default: state <= RX_IDLE;
            endcase
        end
    end

endmodule

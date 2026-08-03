`timescale 1ns/1ps

// Minimal PL-only board wrapper for the PYNQ-Z2.
//
// The existing PicoRV32 firmware runs a deterministic accelerator self-test.
// Software accesses the accelerator over the SoC's internal MMIO bus.  The
// sticky self-test result is shown on LEDs; a 115200-8N1 UART is exposed on the
// Raspberry Pi header for the framed CRC command protocol.
module pynqz2_accel_top #(
    parameter MEM_INIT_FILE = "firmware.hex"
) (
    input  logic       sysclk,
    input  logic       btn_rst,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [3:0] led
);

    // BTN0 is active high and asynchronous to sysclk. Synchronize the manual
    // button first, then generate an entirely synchronous active-low SoC reset.
    // Keeping reset synchronous avoids placing asynchronous controls on the
    // inferred block RAM enable/reset network.
    (* ASYNC_REG = "TRUE" *)
    logic [1:0] btn_rst_sync = 2'b00;
    logic [17:0] reset_count = 18'd0;
    logic        resetn;
    logic        trap;
    logic        test_done;
    logic        test_pass;

    always_ff @(posedge sysclk) begin
        btn_rst_sync <= {btn_rst_sync[0], btn_rst};

        if (btn_rst_sync[1]) begin
            reset_count <= 18'd0;
        end else if (!reset_count[17]) begin
            reset_count <= reset_count + 18'd1;
        end
    end

    assign resetn = reset_count[17];


    picorv32_accel_soc #(
        .MEM_INIT_FILE (MEM_INIT_FILE)
    ) soc (
        .clk        (sysclk),
        .resetn     (resetn),
        .uart_rx    (uart_rx),
        .uart_tx    (uart_tx),
        .trap       (trap),
        .accel_irq  (),
        .test_done  (test_done),
        .test_pass  (test_pass),
        .test_code  ()
    );

    // LED meanings are intentionally sticky/easy to photograph:
    // led[0] lights when firmware writes its final result.
    // led[1] lights only for the PASS code (1).
    // led[2] exposes an unexpected CPU trap.
    // led[3] lights when firmware completed with a non-PASS diagnostic code.
    always_comb begin
        led[0] = test_done;
        led[1] = test_done && test_pass;
        led[2] = trap;
        led[3] = test_done && !test_pass;
    end

endmodule

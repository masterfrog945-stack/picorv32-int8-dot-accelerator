#include <stdint.h>

#define UART_BASE       0x20000000u
#define UART_CLKDIV     (*(volatile uint32_t *)(UART_BASE + 0x00u))
#define UART_DATA       (*(volatile uint32_t *)(UART_BASE + 0x04u))

#define UART_EMPTY      0xffffffffu
#define UART_DIV_115200 1085u

// Called by start.S only after the existing accelerator self-test has written
// PASS to the tohost device. UART_DATA writes stall in hardware while TX is
// busy, so no separate transmit-ready polling loop is required.
void uart_echo_loop(void)
{
    UART_CLKDIV = UART_DIV_115200;

    for (;;) {
        uint32_t value = UART_DATA;

        if (value != UART_EMPTY)
            UART_DATA = value;
    }
}

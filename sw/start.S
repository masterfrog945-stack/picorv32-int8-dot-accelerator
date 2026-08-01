    .section .text.start
    .globl _start
    .option norvc

_start:
    la      sp, _stack_top
    call    main

    # main returns 1 for PASS or a diagnostic failure code.
    li      t0, 0x10000000
    sw      a0, 0(t0)

    # Preserve a failure code on the LEDs.  Only a passing accelerator
    # self-test is allowed to continue into the UART echo service.
    li      t1, 1
    bne     a0, t1, 1f
    call    uart_echo_loop

1:
    j       1b

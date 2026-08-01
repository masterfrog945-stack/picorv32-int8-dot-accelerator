#include "accel.h"

#define ACCEL_BASE        0x40000000u
#define ACCEL_CTRL        (*(volatile uint32_t *)(ACCEL_BASE + 0x00u))
#define ACCEL_STATUS      (*(volatile uint32_t *)(ACCEL_BASE + 0x04u))
#define ACCEL_VECTOR_A    (*(volatile uint32_t *)(ACCEL_BASE + 0x08u))
#define ACCEL_VECTOR_B    (*(volatile uint32_t *)(ACCEL_BASE + 0x0cu))
#define ACCEL_RESULT      (*(volatile int32_t  *)(ACCEL_BASE + 0x10u))
#define ACCEL_IRQ_ENABLE  (*(volatile uint32_t *)(ACCEL_BASE + 0x14u))
#define ACCEL_IRQ_STATUS  (*(volatile uint32_t *)(ACCEL_BASE + 0x18u))

#define STATUS_DONE       (1u << 1)
#define ACCEL_TIMEOUT     10000u

int accel_dot4(uint32_t packed_a, uint32_t packed_b, int32_t *result)
{
    ACCEL_IRQ_ENABLE = 1u;
    ACCEL_IRQ_STATUS = 1u;
    ACCEL_VECTOR_A   = packed_a;
    ACCEL_VECTOR_B   = packed_b;
    ACCEL_CTRL       = 1u;

    for (uint32_t timeout = 0; timeout < ACCEL_TIMEOUT; ++timeout) {
        if ((ACCEL_STATUS & STATUS_DONE) != 0u) {
            *result = ACCEL_RESULT;
            ACCEL_IRQ_STATUS = 1u;
            return 1;
        }
    }

    return 0;
}


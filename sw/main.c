#include <stdint.h>

#include "accel.h"

static int32_t software_dot4(uint32_t packed_a, uint32_t packed_b)
{
    int32_t result = 0;

    for (uint32_t lane = 0; lane < 4u; ++lane) {
        int8_t a = (int8_t)(packed_a >> (lane * 8u));
        int8_t b = (int8_t)(packed_b >> (lane * 8u));
        result += (int32_t)a * (int32_t)b;
    }

    return result;
}

static uint32_t xorshift32(uint32_t value)
{
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return value;
}

static int run_case(uint32_t a, uint32_t b)
{
    int32_t hardware_result = 0;
    int32_t software_result = software_dot4(a, b);

    if (!accel_dot4(a, b, &hardware_result))
        return 0;

    return hardware_result == software_result;
}

int main(void)
{
    static const uint32_t directed_a[] = {
        0x00000000u,
        0x01010101u,
        0xfc03fe01u,
        0x80808080u,
        0x7f7f7f7fu
    };
    static const uint32_t directed_b[] = {
        0x00000000u,
        0x01010101u,
        0x08f90605u,
        0x80808080u,
        0x80808080u
    };

    for (uint32_t i = 0; i < 5u; ++i) {
        if (!run_case(directed_a[i], directed_b[i]))
            return (int)(0xbad00000u | i);
    }

    uint32_t state_a = 0x13579bdfu;
    uint32_t state_b = 0x2468ace1u;

    for (uint32_t i = 0; i < 16u; ++i) {
        state_a = xorshift32(state_a);
        state_b = xorshift32(state_b);
        if (!run_case(state_a, state_b))
            return (int)(0xbad00100u | i);
    }

    return 1;
}


#include <stdint.h>

#include "accel.h"

#define UART_BASE             0x20000000u
#define UART_CLKDIV           (*(volatile uint32_t *)(UART_BASE + 0x00u))
#define UART_DATA             (*(volatile uint32_t *)(UART_BASE + 0x04u))
#define UART_STATUS           (*(volatile uint32_t *)(UART_BASE + 0x08u))
#define UART_RX_LEVEL         (*(volatile uint32_t *)(UART_BASE + 0x0cu))
#define UART_TX_LEVEL         (*(volatile uint32_t *)(UART_BASE + 0x10u))
#define UART_RX_OVERFLOW      (*(volatile uint32_t *)(UART_BASE + 0x14u))
#define UART_FRAMING_ERRORS   (*(volatile uint32_t *)(UART_BASE + 0x18u))
#define UART_FALSE_STARTS     (*(volatile uint32_t *)(UART_BASE + 0x1cu))
#define UART_CONTROL          (*(volatile uint32_t *)(UART_BASE + 0x20u))

#define UART_EMPTY            0xffffffffu
#define UART_DIV_115200       1085u
#define UART_BYTE_TIMEOUT     12500000u

#define PROTOCOL_MAGIC0       0xa5u
#define PROTOCOL_MAGIC1       0x5au
#define PROTOCOL_VERSION      0x01u
#define PROTOCOL_MAX_PAYLOAD  64u

#define CMD_PING              0x01u
#define CMD_GET_INFO          0x02u
#define CMD_ECHO              0x03u
#define CMD_DOT4_ACCEL        0x10u
#define CMD_DOT4_CPU          0x11u
#define CMD_GET_STATS         0x20u
#define CMD_CLEAR_STATS       0x21u
#define RESPONSE_FLAG         0x80u

#define STATUS_OK             0x00u
#define STATUS_BAD_VERSION    0x01u
#define STATUS_BAD_LENGTH     0x02u
#define STATUS_BAD_CRC        0x03u
#define STATUS_UNKNOWN_CMD    0x04u
#define STATUS_ACCEL_TIMEOUT  0x05u

static uint32_t read_cycle(void)
{
    uint32_t value;
    __asm__ volatile ("rdcycle %0" : "=r" (value));
    return value;
}

static uint16_t crc16_update(uint16_t crc, uint8_t value)
{
    crc ^= (uint16_t)value << 8;
    for (uint32_t bit = 0; bit < 8u; ++bit) {
        if ((crc & 0x8000u) != 0u)
            crc = (uint16_t)((crc << 1) ^ 0x1021u);
        else
            crc = (uint16_t)(crc << 1);
    }
    return crc;
}

static int uart_try_read(uint8_t *value)
{
    uint32_t word = UART_DATA;
    if (word == UART_EMPTY)
        return 0;
    *value = (uint8_t)word;
    return 1;
}

static int uart_read_timeout(uint8_t *value)
{
    uint32_t start = read_cycle();
    while ((uint32_t)(read_cycle() - start) < UART_BYTE_TIMEOUT) {
        if (uart_try_read(value))
            return 1;
    }
    return 0;
}

static uint8_t uart_read_magic(void)
{
    uint8_t value;
    for (;;) {
        if (uart_try_read(&value) && value == PROTOCOL_MAGIC0)
            return value;
    }
}

static void uart_write(uint8_t value)
{
    // The MMIO transaction stalls only if the 32-byte TX FIFO is full.
    UART_DATA = value;
}

static void send_response(
    uint8_t command,
    uint8_t sequence,
    uint8_t status,
    const uint8_t *data,
    uint16_t data_length
)
{
    uint16_t payload_length = (uint16_t)(data_length + 1u);
    uint8_t response_command = (uint8_t)(command | RESPONSE_FLAG);
    uint16_t crc = 0xffffu;

    uart_write(PROTOCOL_MAGIC0);
    uart_write(PROTOCOL_MAGIC1);

    uart_write(PROTOCOL_VERSION);
    crc = crc16_update(crc, PROTOCOL_VERSION);
    uart_write(response_command);
    crc = crc16_update(crc, response_command);
    uart_write(sequence);
    crc = crc16_update(crc, sequence);
    uart_write((uint8_t)payload_length);
    crc = crc16_update(crc, (uint8_t)payload_length);
    uart_write((uint8_t)(payload_length >> 8));
    crc = crc16_update(crc, (uint8_t)(payload_length >> 8));

    uart_write(status);
    crc = crc16_update(crc, status);
    for (uint16_t i = 0; i < data_length; ++i) {
        uart_write(data[i]);
        crc = crc16_update(crc, data[i]);
    }

    uart_write((uint8_t)crc);
    uart_write((uint8_t)(crc >> 8));
}

static void store_u32_le(uint8_t *destination, uint32_t value)
{
    destination[0] = (uint8_t)value;
    destination[1] = (uint8_t)(value >> 8);
    destination[2] = (uint8_t)(value >> 16);
    destination[3] = (uint8_t)(value >> 24);
}

static uint32_t load_u32_le(const uint8_t *source)
{
    return (uint32_t)source[0]
         | ((uint32_t)source[1] << 8)
         | ((uint32_t)source[2] << 16)
         | ((uint32_t)source[3] << 24);
}

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

static uint8_t receive_request(
    uint8_t *command,
    uint8_t *sequence,
    uint8_t *payload,
    uint16_t *payload_length
)
{
    uint8_t version;
    uint8_t length_low;
    uint8_t length_high;
    uint8_t crc_low;
    uint8_t crc_high;
    uint8_t second_magic;
    uint16_t crc = 0xffffu;

    (void)uart_read_magic();
    if (!uart_read_timeout(&second_magic) || second_magic != PROTOCOL_MAGIC1)
        return STATUS_BAD_CRC;
    if (!uart_read_timeout(&version)
            || !uart_read_timeout(command)
            || !uart_read_timeout(sequence)
            || !uart_read_timeout(&length_low)
            || !uart_read_timeout(&length_high))
        return STATUS_BAD_CRC;

    *payload_length = (uint16_t)length_low | ((uint16_t)length_high << 8);
    if (*payload_length > PROTOCOL_MAX_PAYLOAD)
        return STATUS_BAD_LENGTH;

    crc = crc16_update(crc, version);
    crc = crc16_update(crc, *command);
    crc = crc16_update(crc, *sequence);
    crc = crc16_update(crc, length_low);
    crc = crc16_update(crc, length_high);

    for (uint16_t i = 0; i < *payload_length; ++i) {
        if (!uart_read_timeout(&payload[i]))
            return STATUS_BAD_CRC;
        crc = crc16_update(crc, payload[i]);
    }

    if (!uart_read_timeout(&crc_low) || !uart_read_timeout(&crc_high))
        return STATUS_BAD_CRC;

    if (crc != ((uint16_t)crc_low | ((uint16_t)crc_high << 8)))
        return STATUS_BAD_CRC;
    if (version != PROTOCOL_VERSION)
        return STATUS_BAD_VERSION;
    return STATUS_OK;
}

static void dispatch_request(
    uint8_t command,
    uint8_t sequence,
    const uint8_t *payload,
    uint16_t payload_length
)
{
    uint8_t response[16];

    switch (command) {
        case CMD_PING:
            if (payload_length != 0u) {
                send_response(command, sequence, STATUS_BAD_LENGTH, 0, 0);
                return;
            }
            response[0] = 'P';
            response[1] = 'O';
            response[2] = 'N';
            response[3] = 'G';
            send_response(command, sequence, STATUS_OK, response, 4);
            return;

        case CMD_GET_INFO:
            if (payload_length != 0u) {
                send_response(command, sequence, STATUS_BAD_LENGTH, 0, 0);
                return;
            }
            response[0] = PROTOCOL_VERSION;
            response[1] = 4u;   // lanes
            response[2] = 8u;   // operand width
            response[3] = 32u;  // result width
            store_u32_le(&response[4], 125000000u);
            send_response(command, sequence, STATUS_OK, response, 8);
            return;

        case CMD_ECHO:
            send_response(command, sequence, STATUS_OK, payload, payload_length);
            return;

        case CMD_DOT4_ACCEL:
        case CMD_DOT4_CPU: {
            uint32_t packed_a;
            uint32_t packed_b;
            uint32_t start;
            uint32_t cycles;
            int32_t result;

            if (payload_length != 8u) {
                send_response(command, sequence, STATUS_BAD_LENGTH, 0, 0);
                return;
            }

            packed_a = load_u32_le(&payload[0]);
            packed_b = load_u32_le(&payload[4]);
            start = read_cycle();
            if (command == CMD_DOT4_ACCEL) {
                if (!accel_dot4(packed_a, packed_b, &result)) {
                    send_response(command, sequence, STATUS_ACCEL_TIMEOUT, 0, 0);
                    return;
                }
            } else {
                result = software_dot4(packed_a, packed_b);
            }
            cycles = read_cycle() - start;

            store_u32_le(&response[0], (uint32_t)result);
            store_u32_le(&response[4], cycles);
            send_response(command, sequence, STATUS_OK, response, 8);
            return;
        }

        case CMD_GET_STATS:
            if (payload_length != 0u) {
                send_response(command, sequence, STATUS_BAD_LENGTH, 0, 0);
                return;
            }
            store_u32_le(&response[0], UART_RX_OVERFLOW);
            store_u32_le(&response[4], UART_FRAMING_ERRORS);
            store_u32_le(&response[8], UART_FALSE_STARTS);
            response[12] = (uint8_t)UART_RX_LEVEL;
            response[13] = (uint8_t)UART_TX_LEVEL;
            send_response(command, sequence, STATUS_OK, response, 14);
            return;

        case CMD_CLEAR_STATS:
            if (payload_length != 0u) {
                send_response(command, sequence, STATUS_BAD_LENGTH, 0, 0);
                return;
            }
            UART_CONTROL = 1u;
            send_response(command, sequence, STATUS_OK, 0, 0);
            return;

        default:
            send_response(command, sequence, STATUS_UNKNOWN_CMD, 0, 0);
            return;
    }
}

// Called by start.S after the accelerator power-on self-test has passed.
// The historical name is retained so existing startup assembly stays stable.
void uart_echo_loop(void)
{
    uint8_t command = 0u;
    uint8_t sequence = 0u;
    uint8_t payload[PROTOCOL_MAX_PAYLOAD];
    uint16_t payload_length = 0u;

    UART_CLKDIV = UART_DIV_115200;
    UART_CONTROL = 1u;

    for (;;) {
        uint8_t status = receive_request(
            &command, &sequence, payload, &payload_length
        );
        if (status != STATUS_OK) {
            send_response(command, sequence, status, 0, 0);
            continue;
        }
        dispatch_request(command, sequence, payload, payload_length);
    }
}

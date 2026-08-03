#!/usr/bin/env python3
"""UART protocol, echo, and INT8 DOT4 validation for PYNQ-Z2 + CP2102.

The FPGA firmware implements a framed, CRC-protected command protocol.  This
program validates the completed host-to-accelerator path:

    Python -> USB/CP2102 -> PYNQ UART RX FIFO -> PicoRV32
           -> INT8 accelerator -> UART TX FIFO -> Python

Exit codes:
    0: selected test passed
    1: functional mismatch or hardware-reported UART error
    2: setup, usage, serial-port, timeout, or protocol error
"""

from __future__ import annotations

import argparse
import json
import random
import struct
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable


# Some Windows terminals still expose a legacy code page. Keep diagnostics
# printable even when a serial-port description contains Chinese characters.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(errors="backslashreplace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(errors="backslashreplace")


SILICON_LABS_VID = 0x10C4

MAGIC = b"\xA5\x5A"
PROTOCOL_VERSION = 1
MAX_FRAME_PAYLOAD = 256
CMD_PING = 0x01
CMD_GET_INFO = 0x02
CMD_ECHO = 0x03
CMD_DOT4_ACCEL = 0x10
CMD_DOT4_CPU = 0x11
CMD_GET_STATS = 0x20
CMD_CLEAR_STATS = 0x21
RESPONSE_FLAG = 0x80
STATUS_OK = 0x00
STATUS_BAD_VERSION = 0x01
STATUS_BAD_LENGTH = 0x02
STATUS_BAD_CRC = 0x03
STATUS_UNKNOWN_CMD = 0x04


@dataclass
class TestResult:
    passed: bool
    port: str
    baud: int
    framing: str
    pattern: str
    seed: int
    requested_bytes: int
    chunk_size: int
    sent_bytes: int
    received_bytes: int
    byte_errors: int
    extra_bytes: int
    timed_out: bool
    elapsed_seconds: float
    payload_bytes_per_second: float
    first_error_offset: int | None
    link_retries: int
    link_retry_errors: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate framed UART echo and the PicoRV32 INT8 DOT4 accelerator."
    )
    parser.add_argument(
        "--mode",
        choices=("echo", "ping", "stats", "dot4"),
        default="echo",
        help="Test mode: framed echo, protocol ping, UART stats, or accelerator accuracy (default: echo).",
    )
    parser.add_argument(
        "--port",
        help="Serial port, for example COM5. If omitted, one CP210x port is auto-selected.",
    )
    parser.add_argument("--baud", type=int, default=115200, help="Baud rate (default: 115200).")
    parser.add_argument(
        "--count", type=int, default=10_000, help="Number of bytes to test (default: 10000)."
    )
    parser.add_argument(
        "--chunk-size",
        type=int,
        default=32,
        help=(
            "Application payload bytes per framed ECHO request (default: 32, maximum: 64). "
            "Ignored by ping and dot4 modes."
        ),
    )
    parser.add_argument(
        "--cpu-samples",
        type=int,
        default=256,
        help="DOT4 vectors also measured with PicoRV32 software (default: 256).",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=1.0,
        help="Minimum receive timeout per chunk in seconds (default: 1.0).",
    )
    parser.add_argument(
        "--settle",
        type=float,
        default=0.25,
        help="Delay after opening the port before buffers are cleared (default: 0.25).",
    )
    parser.add_argument(
        "--inter-frame-delay",
        type=float,
        default=0.0,
        help="Optional quiet time after each completed request, in seconds (default: 0).",
    )
    parser.add_argument(
        "--pattern",
        choices=("counter", "random"),
        default="counter",
        help="Payload pattern (default: counter, covers every byte value).",
    )
    parser.add_argument("--seed", type=int, default=0x5A17, help="Pattern seed.")
    parser.add_argument("--report", type=Path, help="Optional JSON result file.")
    parser.add_argument("--list", action="store_true", help="List serial ports and exit.")
    parser.add_argument(
        "--no-resync",
        action="store_true",
        help="Deprecated compatibility option; startup recovery is now the normal settle delay.",
    )
    args = parser.parse_args()

    if args.baud <= 0:
        parser.error("--baud must be positive")
    if args.count <= 0:
        parser.error("--count must be positive")
    if args.chunk_size < 0:
        parser.error("--chunk-size cannot be negative")
    if args.mode == "echo" and not 1 <= args.chunk_size <= 64:
        parser.error("framed echo --chunk-size must be between 1 and 64")
    if args.cpu_samples < 0:
        parser.error("--cpu-samples cannot be negative")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.settle < 0:
        parser.error("--settle cannot be negative")
    if args.inter_frame_delay < 0:
        parser.error("--inter-frame-delay cannot be negative")
    return args


def load_pyserial() -> tuple[Any, Any]:
    try:
        import serial
        from serial.tools import list_ports
    except ImportError:
        print(
            "ERROR: pyserial is not installed. Run: py -m pip install pyserial",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return serial, list_ports


def port_description(port: Any) -> str:
    vid_pid = ""
    if port.vid is not None and port.pid is not None:
        vid_pid = f" VID:PID={port.vid:04X}:{port.pid:04X}"
    return f"{port.device}: {port.description}{vid_pid} {port.hwid}"


def show_ports(ports: Iterable[Any]) -> None:
    ports = list(ports)
    if not ports:
        print("No serial ports found.")
        return
    print("Available serial ports:")
    for port in ports:
        print(f"  {port_description(port)}")


def select_port(list_ports: Any, requested: str | None) -> tuple[str, str]:
    ports = list(list_ports.comports())

    if requested:
        for port in ports:
            if port.device.casefold() == requested.casefold():
                return port.device, port.description
        show_ports(ports)
        raise RuntimeError(f"requested port {requested!r} was not found")

    candidates = [
        port
        for port in ports
        if port.vid == SILICON_LABS_VID
        or "cp210" in port.description.casefold()
        or "cp210" in port.hwid.casefold()
    ]

    if len(candidates) == 1:
        return candidates[0].device, candidates[0].description

    show_ports(ports)
    if not candidates:
        raise RuntimeError("no CP210x serial port found; specify one with --port COMx")
    names = ", ".join(port.device for port in candidates)
    raise RuntimeError(f"multiple CP210x ports found ({names}); select one with --port")


def make_payload(count: int, pattern: str, seed: int) -> bytes:
    if pattern == "counter":
        # Offset the counter by the seed while still covering 0x00..0xFF.
        return bytes(((index + seed) & 0xFF) for index in range(count))

    rng = random.Random(seed)
    return bytes(rng.randrange(256) for _ in range(count))


def iter_chunks(payload: bytes, chunk_size: int) -> Iterable[tuple[int, bytes]]:
    if chunk_size == 0 or chunk_size >= len(payload):
        yield 0, payload
        return
    for offset in range(0, len(payload), chunk_size):
        yield offset, payload[offset : offset + chunk_size]


def read_exact(port: Any, count: int, deadline: float) -> bytes:
    received = bytearray()
    while len(received) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        port.timeout = min(0.050, remaining)
        block = port.read(count - len(received))
        if block:
            received.extend(block)
    return bytes(received)


def first_difference(expected: bytes, actual: bytes) -> int | None:
    for index, (lhs, rhs) in enumerate(zip(expected, actual)):
        if lhs != rhs:
            return index
    if len(expected) != len(actual):
        return min(len(expected), len(actual))
    return None


def context_hex(data: bytes, index: int, radius: int = 8) -> str:
    start = max(0, index - radius)
    end = min(len(data), index + radius + 1)
    return " ".join(f"{value:02X}" for value in data[start:end])


def save_report(path: Path, result: TestResult) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(result), indent=2) + "\n", encoding="utf-8")


def save_json_report(path: Path, result: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


def crc16_ccitt(data: bytes, initial: int = 0xFFFF) -> int:
    """CRC-16/CCITT-FALSE used by both host and PicoRV32 firmware."""
    crc = initial
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode_frame(command: int, sequence: int, payload: bytes) -> bytes:
    if len(payload) > MAX_FRAME_PAYLOAD:
        raise ValueError(f"payload is too large: {len(payload)} > {MAX_FRAME_PAYLOAD}")
    body = struct.pack("<BBBH", PROTOCOL_VERSION, command, sequence, len(payload)) + payload
    return MAGIC + body + struct.pack("<H", crc16_ccitt(body))


def read_protocol_frame(port: Any, deadline: float) -> tuple[int, int, bytes]:
    """Scan for a frame boundary and return command, sequence, and payload."""
    matched = 0
    while matched < len(MAGIC):
        value = read_exact(port, 1, deadline)
        if not value:
            raise TimeoutError("timed out waiting for response frame magic")
        if value[0] == MAGIC[matched]:
            matched += 1
        else:
            matched = 1 if value[0] == MAGIC[0] else 0

    header = read_exact(port, 5, deadline)
    if len(header) != 5:
        raise TimeoutError("timed out while reading response header")
    version, command, sequence, payload_length = struct.unpack("<BBBH", header)
    if version != PROTOCOL_VERSION:
        raise RuntimeError(f"response protocol version {version} is unsupported")
    if payload_length > MAX_FRAME_PAYLOAD:
        raise RuntimeError(f"response payload length {payload_length} exceeds safety limit")

    trailer = read_exact(port, payload_length + 2, deadline)
    if len(trailer) != payload_length + 2:
        raise TimeoutError(
            f"timed out while reading response: expected {payload_length + 2}, got {len(trailer)}"
        )
    payload = trailer[:-2]
    received_crc = struct.unpack("<H", trailer[-2:])[0]
    expected_crc = crc16_ccitt(header + payload)
    if received_crc != expected_crc:
        raise RuntimeError(
            f"response CRC mismatch: received 0x{received_crc:04X}, expected 0x{expected_crc:04X}"
        )
    return command, sequence, payload


def transact(
    port: Any,
    command: int,
    sequence: int,
    payload: bytes,
    timeout: float,
) -> tuple[int, bytes]:
    request = encode_frame(command, sequence, payload)
    last_error: Exception | None = None

    for attempt in range(5):
        if attempt:
            port.protocol_retries += 1
            resynchronize_port(port)

        written = port.write(request)
        port.flush()
        if written != len(request):
            raise RuntimeError(
                f"short protocol write: expected {len(request)}, wrote {written}"
            )

        wire_seconds = (len(request) + 16) * 10.0 / port.baudrate
        deadline = time.monotonic() + max(timeout, 4.0 * wire_seconds + 0.100)
        try:
            response_command, response_sequence, response_payload = read_protocol_frame(
                port, deadline
            )
            if response_command != (command | RESPONSE_FLAG):
                if response_command == command and response_sequence == sequence:
                    raise RuntimeError(
                        "request frame was echoed unchanged; CP2102 TX/RX may be "
                        "shorted, or the FPGA is still running the legacy raw-echo bitstream"
                    )
                status_text = (
                    f"0x{response_payload[0]:02X}" if response_payload else "missing"
                )
                raise RuntimeError(
                    f"response command 0x{response_command:02X} does not match request "
                    f"0x{command:02X}; response sequence={response_sequence}, "
                    f"status={status_text}"
                )
            if response_sequence != sequence:
                raise RuntimeError(
                    f"response sequence {response_sequence} does not match request {sequence}"
                )
            if not response_payload:
                raise RuntimeError("response omitted mandatory status byte")
            if response_payload[0] in (
                STATUS_BAD_VERSION,
                STATUS_BAD_LENGTH,
                STATUS_BAD_CRC,
            ):
                raise RuntimeError(
                    f"firmware rejected damaged request with status "
                    f"{response_payload[0]}"
                )
            return response_payload[0], response_payload[1:]
        except (TimeoutError, RuntimeError) as error:
            last_error = error
            port.protocol_retry_errors.append(str(error))

    raise RuntimeError(f"protocol transaction failed after 5 attempts: {last_error}")


def resynchronize_port(port: Any, reopen: bool = False) -> None:
    """Let the firmware's 100 ms inter-byte timeout abandon a partial frame."""
    if reopen:
        port.close()
        time.sleep(0.050)
        port.open()
        port.dtr = False
        port.rts = False
        time.sleep(0.100)
    # Do not inject filler bytes: doing so can overflow RX FIFO while the CPU
    # is not yet in its magic-search loop. A quiet interval is sufficient
    # because every in-frame firmware read has a 100 ms timeout.
    port.reset_input_buffer()
    time.sleep(0.150)
    port.reset_input_buffer()
    port.reset_output_buffer()


def open_uart(serial: Any, port_name: str, args: argparse.Namespace) -> Any:
    port = serial.Serial(
        port=port_name,
        baudrate=args.baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0.050,
        write_timeout=max(1.0, args.timeout),
        xonxoff=False,
        rtscts=False,
        dsrdtr=False,
    )
    port.dtr = False
    port.rts = False
    time.sleep(args.settle)
    port.reset_input_buffer()
    port.reset_output_buffer()
    port.protocol_retries = 0
    port.protocol_retry_errors = []

    # The settle delay above is already longer than the firmware's 100 ms
    # inter-byte timeout, so it recovers an abandoned partial frame without
    # injecting bytes or performing a second, redundant startup resync.
    return port


def run_ping_test(args: argparse.Namespace, serial: Any, port_name: str, description: str) -> dict[str, Any]:
    with open_uart(serial, port_name, args) as port:
        started = time.perf_counter()
        status, payload = transact(port, CMD_PING, 0, b"", args.timeout)
        elapsed = time.perf_counter() - started
        link_retries = port.protocol_retries
        link_retry_errors = list(port.protocol_retry_errors)
    passed = status == STATUS_OK and payload == b"PONG"
    result = {
        "mode": "ping",
        "passed": passed,
        "port": port_name,
        "description": description,
        "status": status,
        "payload_hex": payload.hex(),
        "elapsed_seconds": elapsed,
        "link_retries": link_retries,
        "link_retry_errors": link_retry_errors,
    }
    print("UART protocol PING")
    print(f"  Port       : {port_name} ({description})")
    print(f"  Status     : {'PASS' if passed else 'FAIL'}")
    print(f"  Response   : {payload!r}")
    print(f"  Retries    : {link_retries}")
    for error in link_retry_errors:
        print(f"  Retry cause: {error}")
    print(f"  Elapsed    : {elapsed:.6f} s")
    return result


def run_stats_test(args: argparse.Namespace, serial: Any, port_name: str, description: str) -> dict[str, Any]:
    """Read UART error counters without clearing the captured failure state."""
    with open_uart(serial, port_name, args) as port:
        status, payload = transact(port, CMD_GET_STATS, 0, b"", args.timeout)
        link_retries = port.protocol_retries
        link_retry_errors = list(port.protocol_retry_errors)
    if status != STATUS_OK or len(payload) != 14:
        raise RuntimeError("GET_STATS returned an invalid response")
    overflow, framing, false_starts = struct.unpack("<III", payload[:12])
    rx_level, tx_level = payload[12:14]
    passed = link_retries == 0
    result = {
        "mode": "stats",
        "passed": passed,
        "port": port_name,
        "description": description,
        "link_retries": link_retries,
        "link_retry_errors": link_retry_errors,
        "uart_stats": {
            "rx_overflow": overflow,
            "framing_errors": framing,
            "false_starts": false_starts,
            "rx_level": rx_level,
            "tx_level": tx_level,
        },
    }
    print("UART hardware statistics (not cleared)")
    print(f"  Port          : {port_name} ({description})")
    print(f"  RX overflow   : {overflow}")
    print(f"  Framing errors: {framing}")
    print(f"  False starts  : {false_starts}")
    print(f"  FIFO levels   : RX={rx_level}, TX={tx_level}")
    print(f"  Link retries  : {link_retries}")
    for error in link_retry_errors:
        print(f"  Retry cause   : {error}")
    return result


def run_framed_echo_test(
    args: argparse.Namespace,
    serial: Any,
    port_name: str,
    description: str,
) -> TestResult:
    payload = make_payload(args.count, args.pattern, args.seed)
    sent_total = 0
    received_total = 0
    byte_errors = 0
    first_error: int | None = None
    timed_out = False
    sequence = 0

    print("Framed UART FIFO echo test")
    print(f"  Port       : {port_name} ({description})")
    print(f"  Format     : {args.baud} baud, 8N1, CRC-16/CCITT")
    print(f"  Bytes      : {args.count}")
    print(f"  Frame data : {args.chunk_size} byte(s)")

    with open_uart(serial, port_name, args) as port:
        started = time.perf_counter()
        clear_status, _ = transact(port, CMD_CLEAR_STATS, 0xFF, b"", args.timeout)
        if clear_status != STATUS_OK:
            raise RuntimeError(f"CLEAR_STATS returned status {clear_status}")
        for base_offset, expected in iter_chunks(payload, args.chunk_size):
            try:
                status, actual = transact(
                    port, CMD_ECHO, sequence, expected, args.timeout
                )
            except TimeoutError as error:
                timed_out = True
                first_error = base_offset
                byte_errors = len(expected)
                print(
                    f"ERROR: frame sequence {sequence} at payload offset "
                    f"{base_offset} timed out: {error}",
                    file=sys.stderr,
                )
                break
            except RuntimeError as error:
                first_error = base_offset
                byte_errors = len(expected)
                print(
                    f"ERROR: frame sequence {sequence} at payload offset "
                    f"{base_offset} failed: {error}",
                    file=sys.stderr,
                )
                break
            sent_total += len(expected)
            received_total += len(actual)
            if status != STATUS_OK or actual != expected:
                local_error = first_difference(expected, actual)
                first_error = base_offset if local_error is None else base_offset + local_error
                byte_errors = max(1, sum(a != b for a, b in zip(expected, actual)))
                byte_errors += abs(len(expected) - len(actual))
                print(
                    f"ERROR: framed echo failed at payload offset {first_error}, status={status}",
                    file=sys.stderr,
                )
                break
            if args.inter_frame_delay:
                time.sleep(args.inter_frame_delay)
            sequence = (sequence + 1) & 0xFF
        elapsed = time.perf_counter() - started
        time.sleep(0.050)
        extra = port.read(port.in_waiting) if port.in_waiting else b""
        link_retries = port.protocol_retries
        link_retry_errors = list(port.protocol_retry_errors)

    if extra:
        byte_errors += len(extra)
        if first_error is None:
            first_error = received_total

    passed = (
        sent_total == args.count
        and received_total == args.count
        and byte_errors == 0
        and not extra
        and not timed_out
    )
    return TestResult(
        passed=passed,
        port=port_name,
        baud=args.baud,
        framing="8N1 framed CRC16",
        pattern=args.pattern,
        seed=args.seed,
        requested_bytes=args.count,
        chunk_size=args.chunk_size,
        sent_bytes=sent_total,
        received_bytes=received_total,
        byte_errors=byte_errors,
        extra_bytes=len(extra),
        timed_out=timed_out,
        elapsed_seconds=elapsed,
        payload_bytes_per_second=received_total / elapsed if elapsed else 0.0,
        first_error_offset=first_error,
        link_retries=link_retries,
        link_retry_errors=link_retry_errors,
    )


def directed_dot4_cases() -> list[tuple[tuple[int, ...], tuple[int, ...]]]:
    return [
        ((0, 0, 0, 0), (0, 0, 0, 0)),
        ((1, 1, 1, 1), (1, 1, 1, 1)),
        ((127, 127, 127, 127), (127, 127, 127, 127)),
        ((-128, -128, -128, -128), (-128, -128, -128, -128)),
        ((-128, 127, -1, 1), (127, -128, 1, -1)),
        ((1, -2, 3, -4), (5, 6, 7, 8)),
    ]


def run_dot4_test(
    args: argparse.Namespace,
    serial: Any,
    port_name: str,
    description: str,
) -> dict[str, Any]:
    rng = random.Random(args.seed)
    cases = directed_dot4_cases()
    cases.extend(
        (
            tuple(rng.randint(-128, 127) for _ in range(4)),
            tuple(rng.randint(-128, 127) for _ in range(4)),
        )
        for _ in range(args.count)
    )

    mismatches = 0
    timeouts = 0
    accel_cycles: list[int] = []
    cpu_cycles: list[int] = []
    first_mismatch: dict[str, Any] | None = None
    sequence = 0

    print("INT8 DOT4 accelerator accuracy test")
    print(f"  Port          : {port_name} ({description})")
    print(f"  Directed cases: {len(directed_dot4_cases())}")
    print(f"  Random vectors: {args.count}")
    print(f"  CPU samples   : {min(args.cpu_samples, len(cases))}")

    with open_uart(serial, port_name, args) as port:
        # Positive protocol test.
        try:
            status, pong = transact(port, CMD_PING, sequence, b"", args.timeout)
        except (TimeoutError, RuntimeError) as error:
            raise RuntimeError(f"initial PING sequence {sequence} failed: {error}") from error
        if status != STATUS_OK or pong != b"PONG":
            raise RuntimeError("PING failed before DOT4 test")
        print("  Protocol PING : PASS")
        sequence = (sequence + 1) & 0xFF

        status, _ = transact(port, CMD_CLEAR_STATS, sequence, b"", args.timeout)
        if status != STATUS_OK:
            raise RuntimeError(f"CLEAR_STATS returned status {status}")
        sequence = (sequence + 1) & 0xFF

        started = time.perf_counter()
        for index, (vector_a, vector_b) in enumerate(cases):
            expected = sum(a * b for a, b in zip(vector_a, vector_b))
            request = struct.pack("<8b", *(vector_a + vector_b))
            try:
                status, response = transact(
                    port, CMD_DOT4_ACCEL, sequence, request, args.timeout
                )
            except (TimeoutError, RuntimeError) as error:
                timeouts += 1
                mismatches += 1
                if first_mismatch is None:
                    first_mismatch = {"index": index, "reason": str(error)}
                raise RuntimeError(
                    f"accelerator vector {index}, sequence {sequence} failed: {error}"
                ) from error
            sequence = (sequence + 1) & 0xFF
            if status != STATUS_OK or len(response) != 8:
                mismatches += 1
                if first_mismatch is None:
                    first_mismatch = {
                        "index": index,
                        "reason": "bad response",
                        "status": status,
                        "length": len(response),
                    }
                break

            actual, cycles = struct.unpack("<iI", response)
            accel_cycles.append(cycles)
            if actual != expected:
                mismatches += 1
                if first_mismatch is None:
                    first_mismatch = {
                        "index": index,
                        "a": vector_a,
                        "b": vector_b,
                        "expected": expected,
                        "actual": actual,
                    }
                break

            if index < args.cpu_samples:
                if args.inter_frame_delay:
                    time.sleep(args.inter_frame_delay)
                try:
                    status, response = transact(
                        port, CMD_DOT4_CPU, sequence, request, args.timeout
                    )
                except (TimeoutError, RuntimeError) as error:
                    raise RuntimeError(
                        f"CPU vector {index}, sequence {sequence} failed: {error}"
                    ) from error
                sequence = (sequence + 1) & 0xFF
                if status != STATUS_OK or len(response) != 8:
                    raise RuntimeError("CPU reference command returned an invalid response")
                cpu_actual, cpu_cycle_count = struct.unpack("<iI", response)
                cpu_cycles.append(cpu_cycle_count)
                if cpu_actual != expected:
                    raise RuntimeError(
                        f"PicoRV32 software result {cpu_actual} != Python result {expected}"
                    )

            if args.inter_frame_delay:
                time.sleep(args.inter_frame_delay)

            if (index + 1) % 1000 == 0:
                print(f"  Progress      : {index + 1}/{len(cases)}")

        elapsed = time.perf_counter() - started

        # Run destructive/negative protocol checks only after all accuracy
        # vectors, so an error-recovery defect cannot masquerade as a DOT4
        # arithmetic failure.
        status, _ = transact(port, 0x7E, sequence, b"", args.timeout)
        if status != STATUS_UNKNOWN_CMD:
            raise RuntimeError(f"unknown-command test returned status {status}")
        sequence = (sequence + 1) & 0xFF

        bad_frame = bytearray(encode_frame(CMD_PING, sequence, b""))
        bad_frame[-1] ^= 0x01
        port.write(bad_frame)
        port.flush()
        deadline = time.monotonic() + args.timeout
        command, response_sequence, response = read_protocol_frame(port, deadline)
        if command != (CMD_PING | RESPONSE_FLAG) or response_sequence != sequence:
            raise RuntimeError("bad-CRC response did not match request")
        if not response or response[0] != STATUS_BAD_CRC:
            raise RuntimeError("firmware did not reject corrupted CRC")
        sequence = (sequence + 1) & 0xFF

        status, stats_payload = transact(port, CMD_GET_STATS, sequence, b"", args.timeout)
        if status != STATUS_OK or len(stats_payload) != 14:
            raise RuntimeError("GET_STATS returned an invalid response")
        overflow, framing, false_starts = struct.unpack("<III", stats_payload[:12])
        rx_level, tx_level = stats_payload[12:14]
        link_retries = port.protocol_retries
        link_retry_errors = list(port.protocol_retry_errors)

    passed = mismatches == 0 and timeouts == 0 and overflow == 0 and framing == 0
    result = {
        "mode": "dot4",
        "passed": passed,
        "port": port_name,
        "description": description,
        "directed_cases": len(directed_dot4_cases()),
        "random_vectors": args.count,
        "tested_vectors": len(accel_cycles),
        "mismatches": mismatches,
        "timeouts": timeouts,
        "link_retries": link_retries,
        "link_retry_errors": link_retry_errors,
        "first_mismatch": first_mismatch,
        "elapsed_seconds": elapsed,
        "accelerator_cycles": {
            "samples": len(accel_cycles),
            "minimum": min(accel_cycles) if accel_cycles else None,
            "maximum": max(accel_cycles) if accel_cycles else None,
            "average": sum(accel_cycles) / len(accel_cycles) if accel_cycles else None,
        },
        "cpu_cycles": {
            "samples": len(cpu_cycles),
            "minimum": min(cpu_cycles) if cpu_cycles else None,
            "maximum": max(cpu_cycles) if cpu_cycles else None,
            "average": sum(cpu_cycles) / len(cpu_cycles) if cpu_cycles else None,
        },
        "uart_stats": {
            "rx_overflow": overflow,
            "framing_errors": framing,
            "false_starts": false_starts,
            "rx_level": rx_level,
            "tx_level": tx_level,
        },
    }

    print()
    print("DOT4 result")
    print(f"  Status        : {'PASS' if passed else 'FAIL'}")
    print(f"  Tested vectors: {len(accel_cycles)}")
    print(f"  Mismatches    : {mismatches}")
    print(f"  Timeouts      : {timeouts}")
    print(f"  Link retries  : {link_retries}")
    for error in link_retry_errors:
        print(f"  Retry cause   : {error}")
    print(f"  UART errors   : overflow={overflow}, framing={framing}, false_start={false_starts}")
    if accel_cycles:
        print(f"  Accelerator   : {sum(accel_cycles) / len(accel_cycles):.2f} cycles average")
    if cpu_cycles:
        cpu_average = sum(cpu_cycles) / len(cpu_cycles)
        accel_for_cpu_samples = accel_cycles[: len(cpu_cycles)]
        accel_average = sum(accel_for_cpu_samples) / len(accel_for_cpu_samples)
        print(f"  PicoRV32 C    : {cpu_average:.2f} cycles average")
        print(f"  Driver speedup: {cpu_average / accel_average:.2f}x")
    print(f"  Elapsed       : {elapsed:.3f} s")
    return result


def run_test(args: argparse.Namespace, serial: Any, port_name: str, description: str) -> TestResult:
    payload = make_payload(args.count, args.pattern, args.seed)
    effective_chunk = args.count if args.chunk_size == 0 else min(args.chunk_size, args.count)

    print("UART echo test")
    print(f"  Port       : {port_name} ({description})")
    print(f"  Format     : {args.baud} baud, 8 data bits, no parity, 1 stop bit")
    print(f"  Bytes      : {args.count}")
    print(f"  Chunk size : {effective_chunk}")
    print(f"  Pattern    : {args.pattern}, seed=0x{args.seed:X}")

    sent_total = 0
    received_total = 0
    byte_errors = 0
    first_error: int | None = None
    timed_out = False
    extra = b""

    with serial.Serial(
        port=port_name,
        baudrate=args.baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0.050,
        write_timeout=max(1.0, args.timeout),
        xonxoff=False,
        rtscts=False,
        dsrdtr=False,
    ) as port:
        # Modem-control pins are unused by the three-wire UART connection.
        port.dtr = False
        port.rts = False
        time.sleep(args.settle)
        port.reset_input_buffer()
        port.reset_output_buffer()

        started = time.perf_counter()

        for base_offset, expected in iter_chunks(payload, args.chunk_size):
            written = port.write(expected)
            port.flush()
            sent_total += written

            if written != len(expected):
                print(
                    f"ERROR: short write at offset {base_offset}: "
                    f"expected {len(expected)}, wrote {written}",
                    file=sys.stderr,
                )
                byte_errors += len(expected) - written
                first_error = base_offset
                break

            # 8N1 uses 10 wire bits per byte. Allow four wire-times plus the
            # requested minimum for USB buffering and host scheduling jitter.
            wire_seconds = len(expected) * 10.0 / args.baud
            deadline = time.monotonic() + max(args.timeout, 4.0 * wire_seconds + 0.100)
            actual = read_exact(port, len(expected), deadline)
            received_total += len(actual)

            local_error = first_difference(expected, actual)
            if local_error is not None:
                absolute_error = base_offset + local_error
                if first_error is None:
                    first_error = absolute_error
                byte_errors += sum(a != b for a, b in zip(expected, actual))
                byte_errors += abs(len(expected) - len(actual))

                print(f"ERROR: echo differs at absolute offset {absolute_error}", file=sys.stderr)
                print(
                    f"  Expected ({len(expected)} bytes): "
                    f"{context_hex(expected, local_error)}",
                    file=sys.stderr,
                )
                print(
                    f"  Received ({len(actual)} bytes): "
                    f"{context_hex(actual, min(local_error, max(0, len(actual) - 1)))}",
                    file=sys.stderr,
                )

                if len(actual) < len(expected):
                    timed_out = True
                    print(
                        f"  Timeout: missing {len(expected) - len(actual)} byte(s) in this chunk.",
                        file=sys.stderr,
                    )
                # Stop at the first bad chunk. Continuing would turn one lost
                # byte into thousands of misleading shifted-byte mismatches.
                break

        elapsed = time.perf_counter() - started

        # Detect unexpected startup text, duplicate bytes, or late data after
        # the expected echo. A raw echo test cannot otherwise classify these.
        time.sleep(0.100)
        waiting = port.in_waiting
        if waiting:
            extra = port.read(waiting)

    extra_count = len(extra)
    if extra_count:
        byte_errors += extra_count
        if first_error is None:
            first_error = received_total
        print(
            f"ERROR: received {extra_count} unexpected trailing byte(s): "
            f"{extra[:32].hex(' ')}",
            file=sys.stderr,
        )

    passed = (
        sent_total == args.count
        and received_total == args.count
        and byte_errors == 0
        and extra_count == 0
        and not timed_out
    )
    rate = received_total / elapsed if elapsed > 0 else 0.0

    return TestResult(
        passed=passed,
        port=port_name,
        baud=args.baud,
        framing="8N1",
        pattern=args.pattern,
        seed=args.seed,
        requested_bytes=args.count,
        chunk_size=effective_chunk,
        sent_bytes=sent_total,
        received_bytes=received_total,
        byte_errors=byte_errors,
        extra_bytes=extra_count,
        timed_out=timed_out,
        elapsed_seconds=elapsed,
        payload_bytes_per_second=rate,
        first_error_offset=first_error,
        link_retries=0,
        link_retry_errors=[],
    )


def main() -> int:
    args = parse_args()
    serial, list_ports = load_pyserial()

    if args.list:
        show_ports(list_ports.comports())
        return 0

    try:
        port_name, description = select_port(list_ports, args.port)
        if args.mode == "ping":
            protocol_result = run_ping_test(args, serial, port_name, description)
            if args.report:
                save_json_report(args.report, protocol_result)
                print(f"  JSON report: {args.report.resolve()}")
            return 0 if protocol_result["passed"] else 1

        if args.mode == "stats":
            protocol_result = run_stats_test(args, serial, port_name, description)
            if args.report:
                save_json_report(args.report, protocol_result)
                print(f"  JSON report: {args.report.resolve()}")
            return 0 if protocol_result["passed"] else 1

        if args.mode == "dot4":
            protocol_result = run_dot4_test(args, serial, port_name, description)
            if args.report:
                save_json_report(args.report, protocol_result)
                print(f"  JSON report: {args.report.resolve()}")
            return 0 if protocol_result["passed"] else 1

        result = run_framed_echo_test(args, serial, port_name, description)
    except (OSError, RuntimeError, TimeoutError, ValueError, serial.SerialException) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    print()
    print("Result")
    print(f"  Status     : {'PASS' if result.passed else 'FAIL'}")
    print(f"  Sent       : {result.sent_bytes}")
    print(f"  Received   : {result.received_bytes}")
    print(f"  Byte errors: {result.byte_errors}")
    print(f"  Extra bytes: {result.extra_bytes}")
    print(f"  Timeout    : {result.timed_out}")
    print(f"  Link retries: {result.link_retries}")
    for error in result.link_retry_errors:
        print(f"  Retry cause : {error}")
    print(f"  Elapsed    : {result.elapsed_seconds:.3f} s")
    print(f"  Payload RX : {result.payload_bytes_per_second:.1f} byte/s")
    if result.first_error_offset is not None:
        print(f"  First error: byte offset {result.first_error_offset}")

    if args.report:
        save_report(args.report, result)
        print(f"  JSON report: {args.report.resolve()}")

    return 0 if result.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

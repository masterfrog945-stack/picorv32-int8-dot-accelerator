#!/usr/bin/env python3
"""Raw UART echo validation for PYNQ-Z2 + CP2102.

The FPGA/firmware must echo every received byte unchanged.  This program does
not implement the board-side UART; it validates the completed echo path:

    Python -> USB/CP2102 -> PYNQ UART RX -> PicoRV32 -> UART TX -> Python

Exit codes:
    0: exact echo, no timeout and no unexpected trailing bytes
    1: data mismatch, timeout or extra received bytes
    2: setup/usage/serial-port error
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable


SILICON_LABS_VID = 0x10C4


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate a byte-for-byte UART echo through a CP2102 adapter."
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
        default=0,
        help=(
            "Bytes sent before waiting for echo. 0 means one continuous burst of --count "
            "bytes (default). Use 1 or 64 while bringing up an unreliable link."
        ),
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
        "--pattern",
        choices=("counter", "random"),
        default="counter",
        help="Payload pattern (default: counter, covers every byte value).",
    )
    parser.add_argument("--seed", type=int, default=0x5A17, help="Pattern seed.")
    parser.add_argument("--report", type=Path, help="Optional JSON result file.")
    parser.add_argument("--list", action="store_true", help="List serial ports and exit.")
    args = parser.parse_args()

    if args.baud <= 0:
        parser.error("--baud must be positive")
    if args.count <= 0:
        parser.error("--count must be positive")
    if args.chunk_size < 0:
        parser.error("--chunk-size cannot be negative")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.settle < 0:
        parser.error("--settle cannot be negative")
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
    )


def main() -> int:
    args = parse_args()
    serial, list_ports = load_pyserial()

    if args.list:
        show_ports(list_ports.comports())
        return 0

    try:
        port_name, description = select_port(list_ports, args.port)
        result = run_test(args, serial, port_name, description)
    except (OSError, RuntimeError, serial.SerialException) as error:
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

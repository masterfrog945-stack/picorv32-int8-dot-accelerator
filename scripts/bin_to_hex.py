#!/usr/bin/env python3
"""Convert a little-endian flat binary to one 32-bit word per readmemh line."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    data = args.input.read_bytes()
    if len(data) % 4:
        data += bytes(4 - len(data) % 4)

    words = [
        int.from_bytes(data[offset : offset + 4], byteorder="little")
        for offset in range(0, len(data), 4)
    ]
    args.output.write_text(
        "".join(f"{word:08x}\n" for word in words), encoding="ascii"
    )
    print(f"HEX_PASS: wrote {len(words)} words to {args.output}")


if __name__ == "__main__":
    main()


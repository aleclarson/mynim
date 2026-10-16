#!/usr/bin/env python3
"""Generate Nim lookup tables from MyGo's pinned CLDR format tables."""

from __future__ import annotations

import argparse
import re
import subprocess
import zlib
from pathlib import Path


SOURCE_REVISION = "7e8688284e4b1fc752169ed9db5f51a5f213a2e6"


def go_unquote(literal: str) -> bytes:
    source = literal[1:-1]
    output = bytearray()
    simple = {
        "a": 7,
        "b": 8,
        "f": 12,
        "n": 10,
        "r": 13,
        "t": 9,
        "v": 11,
        "\\": 92,
        '"': 34,
        "'": 39,
    }
    i = 0
    while i < len(source):
        if source[i] != "\\":
            output.extend(source[i].encode("utf-8"))
            i += 1
            continue
        i += 1
        escape = source[i]
        i += 1
        if escape in simple:
            output.append(simple[escape])
        elif escape == "x":
            output.append(int(source[i : i + 2], 16))
            i += 2
        elif escape in ("u", "U"):
            width = 4 if escape == "u" else 8
            output.extend(chr(int(source[i : i + width], 16)).encode("utf-8"))
            i += width
        elif escape in "01234567":
            digits = escape
            for _ in range(2):
                if i < len(source) and source[i] in "01234567":
                    digits += source[i]
                    i += 1
                else:
                    break
            value = int(digits, 8)
            if value > 255:
                raise ValueError("Go octal escape exceeds one byte")
            output.append(value)
        else:
            raise ValueError(f"unknown Go escape \\{escape}")
    return bytes(output)


def go_string(source: str, name: str) -> bytes:
    match = re.search(rf"const\s+{name}\s*=\s*(.*?)(?=\n\n)", source, re.S)
    if not match:
        raise ValueError(f"missing Go string constant {name}")
    literals = re.findall(r'"(?:\\.|[^"\\])*"', match.group(1), re.S)
    if not literals:
        raise ValueError(f"empty Go string constant {name}")
    return b"".join(go_unquote(literal) for literal in literals)


def go_length(source: str, name: str) -> int:
    match = re.search(rf"\b{name}\s*=\s*(\d+)", source)
    if not match:
        raise ValueError(f"missing Go length {name}")
    return int(match.group(1))


def go_starts(source: str, name: str) -> list[int]:
    match = re.search(
        rf"var\s+{name}\s*=\s*\[\.\.\.\]uint16\s*\{{(.*?)\}}", source, re.S
    )
    if not match:
        raise ValueError(f"missing Go start table {name}")
    body = re.sub(r"//.*", "", match.group(1))
    return [int(value) for value in re.findall(r"\b\d+\b", body)]


def unpack(source: str, name: str, lengths: list[int]) -> list[bytes]:
    raw = zlib.decompress(go_string(source, name), -15)
    result: list[bytes] = []
    offset = 0
    for length in lengths:
        result.append(raw[offset : offset + length])
        offset += length
    if offset != len(raw):
        raise ValueError(f"{name}: consumed {offset} of {len(raw)} bytes")
    return result


def pool_entries(
    packed_entries: bytes,
    starts: list[int],
    parents: bytes,
    lengths: bytes,
    string_pool: bytes,
) -> tuple[list[int], list[int], list[tuple[int, int]], list[str]]:
    if len(packed_entries) % 3:
        raise ValueError("packed entries are not 24-bit aligned")
    if len(starts) != len(parents) // 2 + 1:
        raise ValueError("start table and parent table have different locale counts")
    if starts[0] != 0 or starts[-1] != len(packed_entries) // 3:
        raise ValueError("start table does not cover all packed entries")

    strings = []
    offset = 0
    for length in lengths:
        strings.append(string_pool[offset : offset + length].decode("utf-8"))
        offset += length
    if offset != len(string_pool):
        raise ValueError("string length table does not cover its pool")

    parents_out = [int.from_bytes(parents[i : i + 2], "big") for i in range(0, len(parents), 2)]
    entries: list[tuple[int, int]] = []
    starts_out = [0]
    for locale in range(len(parents_out)):
        local: list[tuple[int, int]] = []
        previous = -1
        for entry in range(starts[locale], starts[locale + 1]):
            at = entry * 3
            value = int.from_bytes(packed_entries[at : at + 3], "big")
            slot, string_index = value >> 15, value & 0x7FFF
            if string_index >= len(lengths):
                raise ValueError(f"locale {locale} references missing string {string_index}")
            if slot <= previous:
                raise ValueError(f"locale {locale} entries are not uniquely sorted")
            previous = slot
            local.append((slot, string_index))
        entries.extend(local)
        starts_out.append(len(entries))
    return parents_out, starts_out, entries, strings


def nim_quote(value: str) -> str:
    escaped: list[str] = []
    for char in value:
        if char == "\\":
            escaped.append("\\\\")
        elif char == '"':
            escaped.append('\\"')
        elif char == "\n":
            escaped.append("\\n")
        elif char == "\r":
            escaped.append("\\r")
        elif char == "\t":
            escaped.append("\\t")
        elif ord(char) < 0x20 or ord(char) == 0x7F:
            escaped.append(f"\\x{ord(char):02X}")
        else:
            escaped.append(char)
    return '"' + "".join(escaped) + '"'


def nim_array(name: str, values: list[str], per_line: int = 6) -> str:
    lines = [f"const {name}* = ["]
    for i in range(0, len(values), per_line):
        lines.append("  " + ", ".join(values[i : i + per_line]) + ",")
    lines.append("]")
    return "\n".join(lines)


def generate(source: str) -> str:
    number_blob = unpack(
        source,
        "fmtPackedNumbers",
        [
            go_length(source, "packedLocalesLen"),
            go_length(source, "packedParentsLen"),
            go_length(source, "packedNumberEntriesLen"),
            go_length(source, "packedNumberLensLen"),
            go_length(source, "packedNumberPoolLen"),
        ],
    )
    locales = [""] + number_blob[0].decode("utf-8").split()
    if len(locales) != go_length(source, "fmtLocaleCount"):
        raise ValueError("locale table count does not match fmtLocaleCount")
    if locales != sorted(locales):
        raise ValueError("locale tags are not sorted for binary search")

    number_parents, number_starts, number_entries, number_strings = pool_entries(
        number_blob[2],
        go_starts(source, "fmtNumberStarts"),
        number_blob[1],
        number_blob[3],
        number_blob[4],
    )
    date_blob = unpack(
        source,
        "fmtPackedDates",
        [
            go_length(source, "packedDateEntriesLen"),
            go_length(source, "packedDateLensLen"),
            go_length(source, "packedDatePoolLen"),
            go_length(source, "packedAutonymTagsLen"),
            go_length(source, "packedAutonymsLen"),
        ],
    )
    date_parents, date_starts, date_entries, date_strings = pool_entries(
        date_blob[0],
        go_starts(source, "fmtDateStarts"),
        number_blob[1],
        date_blob[1],
        date_blob[2],
    )
    if date_parents != number_parents:
        raise ValueError("number and date tables disagree about locale parents")

    skeletons = go_string(source, "fmtSkeletons").decode("utf-8").split()
    header = "\n".join([
        "## Generated from MyGo's CLDR 48.2.0 tables. Do not edit.",
        f"## Source: i18n/format_tables.go at {SOURCE_REVISION}.",
        "## Unicode data licensing: licenses/Unicode-3.0.txt.",
    ])
    sections = [
        header,
        "type FormatEntry* = tuple[slot: uint16, value: uint16]",
        nim_array("formatLocales", [nim_quote(value) for value in locales]),
        nim_array("formatParents", [f"{value}'u16" for value in number_parents], 12),
        nim_array("dateStarts", [f"{value}'u32" for value in date_starts], 12),
        nim_entries("dateEntries", date_entries),
        nim_array("dateStrings", [nim_quote(value) for value in date_strings], 4),
        nim_array("numberStarts", [f"{value}'u32" for value in number_starts], 12),
        nim_entries("numberEntries", number_entries),
        nim_array("numberStrings", [nim_quote(value) for value in number_strings], 4),
        nim_array("skeletons", [nim_quote(value) for value in skeletons], 5),
    ]
    return "\n\n".join(sections) + "\n"


def nim_entries(name: str, entries: list[tuple[int, int]]) -> str:
    lines = [f"const {name}* = ["]
    for i in range(0, len(entries), 6):
        row = entries[i : i + 6]
        lines.append(
            "  "
            + ", ".join(
                f"(slot: {slot}'u16, value: {value}'u16)" for slot, value in row
            )
            + ","
        )
    lines.append("]")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("upstream", type=Path, help="pinned MyGo Git checkout")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("src/mynim/i18n/cldr_format_data.nim"),
    )
    args = parser.parse_args()
    source = subprocess.run(
        [
            "git",
            "-C",
            str(args.upstream),
            "show",
            f"{SOURCE_REVISION}:i18n/format_tables.go",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generate(source))


if __name__ == "__main__":
    main()

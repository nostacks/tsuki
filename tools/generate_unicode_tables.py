#!/usr/bin/env python3
"""Generate compact Nim Unicode 16 tables from official UCD text files."""

from __future__ import annotations

import hashlib
import pathlib
import sys


def code_range(field: str) -> tuple[int, int]:
    values = field.strip().split("..")
    lo = int(values[0], 16)
    return lo, int(values[-1], 16)


def records(path: pathlib.Path):
    for raw in path.read_text(encoding="utf-8").splitlines():
        body = raw.split("#", 1)[0].strip()
        if not body:
            continue
        fields = [field.strip() for field in body.split(";")]
        yield code_range(fields[0]), fields[1:]


def merge(values):
    values = sorted(values)
    result = []
    for lo, hi, prop in values:
        if result and result[-1][2] == prop and result[-1][1] + 1 == lo:
            result[-1] = (result[-1][0], hi, prop)
        else:
            result.append((lo, hi, prop))
    return result


def emit_ranges(name: str, values, type_name: str,
                enum_prefix: str | None = None):
    print(f"const {name}*: array[{len(values)}, {type_name}] = [")
    for index, (lo, hi, prop) in enumerate(values):
        suffix = "," if index + 1 < len(values) else ""
        mapped = f", {enum_prefix}{prop}" if enum_prefix else ""
        print(f"  (0x{lo:X}'u32, 0x{hi:X}'u32{mapped}){suffix}")
    print("]\n")


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit("usage: generator GCB EAW EMOJI DERIVED")
    gcb_path, eaw_path, emoji_path, derived_path = map(pathlib.Path, sys.argv[1:])
    gcb_names = {
        "CR": "CR", "LF": "LF", "Control": "Control",
        "Extend": "Extend", "ZWJ": "ZWJ", "Regional_Indicator": "RI",
        "Prepend": "Prepend", "SpacingMark": "SpacingMark", "L": "L",
        "V": "V", "T": "T", "LV": "LV", "LVT": "LVT",
    }
    gcb = []
    for (lo, hi), fields in records(gcb_path):
        prop = fields[0]
        if prop in gcb_names:
            gcb.append((lo, hi, gcb_names[prop]))
    gcb = merge(gcb)
    width = []
    for (lo, hi), fields in records(eaw_path):
        if fields[0] in {"W", "F", "A"}:
            width.append((lo, hi, "Wide" if fields[0] in {"W", "F"}
                          else "Ambiguous"))
    width = merge(width)
    emoji = []
    for (lo, hi), fields in records(emoji_path):
        if fields[0] == "Extended_Pictographic":
            emoji.append((lo, hi, ""))
    emoji = merge(emoji)
    incb_names = {"Linker": "Linker", "Consonant": "Consonant",
                  "Extend": "Extend"}
    incb = []
    for (lo, hi), fields in records(derived_path):
        if fields[0] == "InCB" and len(fields) > 1 and fields[1] in incb_names:
            incb.append((lo, hi, incb_names[fields[1]]))
    incb = merge(incb)
    digests = []
    for path in (gcb_path, eaw_path, emoji_path, derived_path):
        digests.append(hashlib.sha256(path.read_bytes()).hexdigest())
    print("## Generated Unicode terminal tables. Do not edit manually.")
    print("## Source: Unicode Character Database 16.0.0.")
    print("## SHA-256: " + " ".join(digests))
    print("\nconst unicodeVersion* = \"16.0.0\"\n")
    print("type")
    print("  GraphemeBreak* = enum")
    print("    gbOther, gbCR, gbLF, gbControl, gbExtend, gbZWJ, gbRI,")
    print("    gbPrepend, gbSpacingMark, gbL, gbV, gbT, gbLV, gbLVT")
    print("  EastAsianWidth* = enum eawNeutral, eawWide, eawAmbiguous")
    print("  IndicConjunctBreak* = enum incbNone, incbLinker, incbConsonant, incbExtend")
    print("  UnicodeRange = tuple[lo, hi: uint32]")
    print("  GraphemeRange = tuple[lo, hi: uint32, value: GraphemeBreak]")
    print("  WidthRange = tuple[lo, hi: uint32, value: EastAsianWidth]")
    print("  IndicRange = tuple[lo, hi: uint32, value: IndicConjunctBreak]\n")
    emit_ranges("graphemeRanges", gcb, "GraphemeRange", "gb")
    emit_ranges("widthRanges", width, "WidthRange", "eaw")
    emit_ranges("extendedPictographicRanges", emoji, "UnicodeRange")
    emit_ranges("indicRanges", incb, "IndicRange", "incb")
    print("func lookup[T](value: uint32, ranges: openArray[T], fallback: auto): auto =")
    print("  var low = 0")
    print("  var high = ranges.len")
    print("  while low < high:")
    print("    let middle = (low + high) shr 1")
    print("    if value < ranges[middle].lo: high = middle")
    print("    elif value > ranges[middle].hi: low = middle + 1")
    print("    else: return ranges[middle].value")
    print("  fallback\n")
    print("func inRanges(value: uint32, ranges: openArray[UnicodeRange]): bool =")
    print("  var low = 0")
    print("  var high = ranges.len")
    print("  while low < high:")
    print("    let middle = (low + high) shr 1")
    print("    if value < ranges[middle].lo: high = middle")
    print("    elif value > ranges[middle].hi: low = middle + 1")
    print("    else: return true")
    print("  false\n")
    print("func graphemeBreak*(value: uint32): GraphemeBreak =")
    print("  lookup(value, graphemeRanges, gbOther)\n")
    print("func eastAsianWidth*(value: uint32): EastAsianWidth =")
    print("  lookup(value, widthRanges, eawNeutral)\n")
    print("func indicConjunctBreak*(value: uint32): IndicConjunctBreak =")
    print("  lookup(value, indicRanges, incbNone)\n")
    print("func isExtendedPictographic*(value: uint32): bool =")
    print("  inRanges(value, extendedPictographicRanges)")


if __name__ == "__main__":
    main()

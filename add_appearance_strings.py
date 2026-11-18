#!/usr/bin/env python3
"""Append the appearance settings keys to each Localizable.strings file."""
from __future__ import annotations

import io
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "ThreeOneOSFive"

ENTRIES: dict[str, list[tuple[str, str]]] = {
    "en": [
        ("settings.appearance", "Appearance"),
        ("settings.accent_color", "Accent color"),
        ("settings.reset_color", "Reset color"),
        ("settings.rainbow", "Rainbow RGB"),
        ("settings.rainbow_active", "Rainbow colors are active"),
    ],
    "vi": [
        ("settings.appearance", "Giao diện"),
        ("settings.accent_color", "Màu nhấn"),
        ("settings.reset_color", "Đặt lại màu"),
        ("settings.rainbow", "RGB cầu vồng"),
        ("settings.rainbow_active", "Màu cầu vồng đang bật"),
    ],
    "zh-Hans": [
        ("settings.appearance", "外观"),
        ("settings.accent_color", "强调色"),
        ("settings.reset_color", "重置颜色"),
        ("settings.rainbow", "彩虹 RGB"),
        ("settings.rainbow_active", "彩虹颜色已启用"),
    ],
}


def main() -> int:
    for locale, pairs in ENTRIES.items():
        path = ROOT / f"{locale}.lproj" / "Localizable.strings"
        existing = path.read_text(encoding="utf-8")
        missing = [(k, v) for k, v in pairs if f'"{k}"' not in existing]
        if not missing:
            print(f"{locale}: already present")
            continue
        with io.open(path, "a", encoding="utf-8", newline="") as handle:
            handle.write("\n")
            for key, value in missing:
                handle.write(f'"{key}" = "{value}";\n')
        print(f"{locale}: added {len(missing)} keys")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Packages FS25_FarmAgent into dist/FS25_FarmAgent.zip (and optionally installs it).

    python tools/build.py             # build dist/FS25_FarmAgent.zip
    python tools/build.py --install   # build and copy into the FS25 mods folder

Uses zipfile (forward-slash entry names). PowerShell 5.1's Compress-Archive writes
backslash paths, which the game may not resolve.
"""
import argparse
import math
import pathlib
import shutil
import struct
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = ROOT / "FS25_FarmAgent"
DIST = ROOT / "dist"
ICON = MOD / "icon_farmAgent.dds"


def write_icon(path: pathlib.Path, size: int = 256) -> None:
    """Uncompressed 32-bit BGRA DDS: green field rows under a sun-coloured 'brain' disc."""
    pixels = bytearray()
    cx, cy, r = size / 2, size * 0.42, size * 0.24
    for y in range(size):
        for x in range(size):
            if y > size * 0.62:  # field rows
                stripe = (int((x + (y * 0.6)) / 14) % 2) == 0
                rgb = (70, 140, 50) if stripe else (95, 165, 60)
            else:  # sky
                t = y / (size * 0.62)
                rgb = (int(40 + 60 * t), int(90 + 70 * t), int(160 + 50 * t))
            d = math.hypot(x - cx, y - cy)
            if d < r:
                ring = abs(d - r * 0.62) < size * 0.02 or abs(x - cx) < size * 0.012
                rgb = (255, 255, 255) if ring else (245, 190, 40)
            pixels += bytes((rgb[2], rgb[1], rgb[0], 255))
    header = struct.pack(
        # magic, 7 header dwords, 44 reserved, 8 pixel-format dwords, 4 caps dwords, 4 reserved
        "<4sIIIIIII44xIIIIIIIIIIII4x",
        b"DDS ", 124, 0x100F, size, size, size * 4, 0, 0,
        32, 0x41, 0, 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000,
        0x1000, 0, 0, 0,
    )
    assert len(header) == 128
    path.write_bytes(header + bytes(pixels))


def default_mods_dir() -> pathlib.Path:
    for docs in (pathlib.Path.home() / "Documents", pathlib.Path.home() / "OneDrive" / "Documents"):
        profile = docs / "My Games" / "FarmingSimulator2025"
        if profile.exists():
            return profile / "mods"
    raise SystemExit("FS25 profile folder not found; copy dist/FS25_FarmAgent.zip into your mods folder manually.")


def build() -> pathlib.Path:
    if not ICON.exists():
        write_icon(ICON)
    DIST.mkdir(exist_ok=True)
    target = DIST / "FS25_FarmAgent.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(MOD.rglob("*")):
            if path.is_file():
                z.write(path, path.relative_to(MOD).as_posix())
    return target


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--install", action="store_true", help="copy the zip into the FS25 mods folder")
    args = parser.parse_args()
    target = build()
    with zipfile.ZipFile(target) as z:
        names = z.namelist()
    print(f"Built {target} ({len(names)} files)")
    for name in names:
        print("  " + name)
    if args.install:
        mods = default_mods_dir()
        shutil.copy2(target, mods / target.name)
        print(f"Installed to {mods / target.name}")


if __name__ == "__main__":
    main()

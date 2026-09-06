#!/usr/bin/env python3
"""Downscale oversized PNG/JPG art in place so Godot loads it faster.

The achievement / card tiles are rendered at a few hundred pixels wide but the
source art ships at 1000-1200 px, so every texture costs 3-5x the VRAM and
disk it needs. This shrinks the long edge to a sane cap (default 512 px),
keeps aspect ratio, never upscales, and rewrites the file in place as an
optimised PNG. Re-run `godot --headless --import` afterwards so the .ctex
files regenerate.

Originals are in git, so recovery is `git checkout -- <path>`. Pass --backup
DIR if you'd rather keep copies too.

Usage:
    python scripts/downscale_art.py                        # assets/achievements, cap 512
    python scripts/downscale_art.py --dir assets/cards --max 640
    python scripts/downscale_art.py --dry-run              # report only, write nothing
    python scripts/downscale_art.py --backup .art_backup   # copy originals first

Needs Pillow:  pip install Pillow
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required:  pip install Pillow")

EXTS = {".png", ".jpg", ".jpeg", ".webp"}
REPO_ROOT = Path(__file__).resolve().parent.parent


def _fmt_bytes(n: int) -> str:
    step = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if step < 1024 or unit == "GB":
            return f"{step:.0f} {unit}" if unit == "B" else f"{step:.1f} {unit}"
        step /= 1024
    return f"{step:.1f} GB"


def process(path: Path, max_edge: int, dry_run: bool, backup_dir: Path | None) -> tuple[int, int]:
    """Returns (bytes_before, bytes_after). after == before when skipped."""
    before = path.stat().st_size
    with Image.open(path) as im:
        w, h = im.size
        long_edge = max(w, h)
        if long_edge <= max_edge:
            print(f"  skip  {path.name:<28} {w}x{h}  (already <= {max_edge})")
            return before, before

        scale = max_edge / long_edge
        new_size = (round(w * scale), round(h * scale))
        fmt = im.format
        mode = im.mode

        if dry_run:
            print(f"  would {path.name:<28} {w}x{h} -> {new_size[0]}x{new_size[1]}")
            return before, before

        if backup_dir is not None:
            backup_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, backup_dir / path.name)

        resized = im.resize(new_size, Image.LANCZOS)

        save_kwargs: dict = {}
        if path.suffix.lower() in (".jpg", ".jpeg"):
            save_kwargs.update(quality=90, optimize=True)
            if resized.mode in ("RGBA", "P"):
                resized = resized.convert("RGB")
        elif path.suffix.lower() == ".png":
            save_kwargs.update(optimize=True)
        resized.save(path, format=fmt, **save_kwargs)

    after = path.stat().st_size
    arrow = "->" if after <= before else "->!"  # ->! means it grew (rare)
    print(f"  done  {path.name:<28} {w}x{h} {arrow} {new_size[0]}x{new_size[1]}   "
          f"{_fmt_bytes(before)} -> {_fmt_bytes(after)}")
    return before, after


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default="assets/achievements",
                    help="folder to process, relative to repo root (default: assets/achievements)")
    ap.add_argument("--max", "--max-size", dest="max_edge", type=int, default=512,
                    help="cap for the longer edge in pixels (default: 512)")
    ap.add_argument("--dry-run", action="store_true", help="report what would change, write nothing")
    ap.add_argument("--backup", metavar="DIR", default=None,
                    help="copy originals here before overwriting (relative to repo root)")
    ap.add_argument("--recursive", action="store_true", help="also descend into subfolders")
    args = ap.parse_args()

    target = (REPO_ROOT / args.dir).resolve()
    if not target.is_dir():
        sys.exit(f"not a folder: {target}")

    backup_dir = (REPO_ROOT / args.backup).resolve() if args.backup else None

    globber = target.rglob("*") if args.recursive else target.glob("*")
    files = sorted(p for p in globber if p.suffix.lower() in EXTS and p.is_file())
    if not files:
        sys.exit(f"no images ({', '.join(sorted(EXTS))}) in {target}")

    print(f"{'DRY RUN -- ' if args.dry_run else ''}{len(files)} image(s) in {target}, "
          f"long-edge cap {args.max_edge}px"
          + (f", backup -> {backup_dir}" if backup_dir else ""))

    total_before = total_after = 0
    changed = 0
    for f in files:
        b, a = process(f, args.max_edge, args.dry_run, backup_dir)
        total_before += b
        total_after += a
        if a != b:
            changed += 1

    print(f"\n{changed}/{len(files)} resized. "
          f"total {_fmt_bytes(total_before)} -> {_fmt_bytes(total_after)} "
          f"({_fmt_bytes(total_before - total_after)} saved)")
    if not args.dry_run and changed:
        print("Now run:  godot --headless --import   (regenerates the .ctex files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

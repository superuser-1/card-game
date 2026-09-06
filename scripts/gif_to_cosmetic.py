#!/usr/bin/env python3
"""GIF -> animated Godot cosmetic (avatar frame / background / avatar).

Godot 4 can't load a .gif directly, but an `AnimatedTexture` resource IS a
Texture2D and self-animates wherever it's assigned. This tool takes a GIF,
subsamples + downscales its frames to `assets/<dir>/<id>/frame_NN.png`, and
writes `assets/<dir>/<id>.tres` (the AnimatedTexture). The Frames/Backgrounds/
Avatars lookups prefer a `.tres` over a `.png` of the same id, so the animated
version just shows up everywhere the cosmetic renders.

    python scripts/gif_to_cosmetic.py            # opens the UI
    python scripts/gif_to_cosmetic.py a.gif b.gif --type background --cli

After converting, run:  godot --headless --import

MP4/WebM: convert to GIF first (Pillow can't read video).
Needs: Pillow (installed), tkinter (bundled with the python.org build).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    from PIL import Image, ImageSequence
except ImportError:
    sys.exit("Pillow is required:  pip install Pillow")

REPO_ROOT = Path(__file__).resolve().parent.parent

# Mirrors the DIR consts in client/{frames,backgrounds,avatars}.gd
OUT_DIRS = {
    "frame":      "assets/avatars/avatar_frame",
    "background": "assets/avatars/avatar_bg",
    "avatar":     "assets/avatars",
}
DEFAULTS = {"frame": 22, "background": 24, "avatar": 20}
MAX_ANIM_FRAMES = 256  # AnimatedTexture hard cap


def sanitize_id(name: str) -> str:
    """Match the sanitize() rules in the .gd lookups: [A-Za-z0-9_-] only."""
    return re.sub(r"[^A-Za-z0-9_-]", "_", name).strip("_") or "cosmetic"


def _pick_indices(n_src: int, target: int) -> list[int]:
    if n_src <= target:
        return list(range(n_src))
    return [round(i * (n_src - 1) / (target - 1)) for i in range(target)]


def convert_gif(
    gif_path: Path,
    cosmetic_type: str,
    *,
    cosmetic_id: str | None = None,
    frames: int = 24,
    max_edge: int = 512,
    fps: float = 12.0,
    log=print,
) -> Path:
    """Returns the written .tres path."""
    if cosmetic_type not in OUT_DIRS:
        raise ValueError(f"type must be one of {list(OUT_DIRS)}")
    frames = max(2, min(int(frames), MAX_ANIM_FRAMES))

    cid = sanitize_id(cosmetic_id or gif_path.stem)
    out_dir = REPO_ROOT / OUT_DIRS[cosmetic_type]
    frames_dir = out_dir / cid
    frames_dir.mkdir(parents=True, exist_ok=True)

    with Image.open(gif_path) as im:
        src = [f.convert("RGBA") for f in ImageSequence.Iterator(im)]
    if not src:
        raise ValueError("no frames found in GIF")

    idxs = _pick_indices(len(src), frames)
    w0, h0 = src[0].size
    scale = min(1.0, max_edge / max(w0, h0))
    size = (max(1, round(w0 * scale)), max(1, round(h0 * scale)))

    # Clear any stale frames from a previous, longer run.
    for old in frames_dir.glob("frame_*.png"):
        old.unlink()

    written = []
    for out_i, s_i in enumerate(idxs):
        fr = src[s_i].resize(size, Image.LANCZOS)
        p = frames_dir / f"frame_{out_i:02d}.png"
        fr.save(p, optimize=True)
        written.append(p)

    duration = round(1.0 / max(fps, 0.1), 5)
    tres_path = out_dir / f"{cid}.tres"
    _write_tres(tres_path, frames_dir, written, duration)

    log(f"  {gif_path.name}: {len(src)} src frames -> {len(written)} @ {size[0]}x{size[1]}, {fps:g} fps")
    log(f"    {tres_path.relative_to(REPO_ROOT)}  (+ {len(written)} PNGs in {cid}/)")
    return tres_path


def _write_tres(tres_path: Path, frames_dir: Path, frame_files: list[Path], duration: float) -> None:
    n = len(frame_files)
    lines = [f'[gd_resource type="AnimatedTexture" load_steps={n + 1} format=3]', ""]
    for i, fp in enumerate(frame_files):
        res_path = "res://" + fp.relative_to(REPO_ROOT).as_posix()
        lines.append(f'[ext_resource type="Texture2D" path="{res_path}" id="{i + 1}_f"]')
    lines += ["", "[resource]", f"frames = {n}"]
    for i in range(n):
        lines.append(f'frame_{i}/texture = ExtResource("{i + 1}_f")')
        lines.append(f"frame_{i}/duration = {duration}")
    tres_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------- UI

def run_ui() -> int:
    try:
        import tkinter as tk
        from tkinter import ttk, filedialog, messagebox
        from PIL import ImageTk
    except ImportError as e:
        sys.exit(f"UI needs tkinter + Pillow's ImageTk ({e}). Use --cli instead.")

    root = tk.Tk()
    root.title("GIF -> Godot cosmetic")
    root.geometry("640x560")

    state: dict = {"files": [], "preview_frames": [], "preview_job": None, "preview_i": 0}

    top = ttk.Frame(root, padding=10)
    top.pack(fill="x")

    ttk.Button(top, text="Add GIF(s)…", command=lambda: add_files()).pack(side="left")
    ttk.Button(top, text="Clear", command=lambda: clear_files()).pack(side="left", padx=6)
    files_var = tk.StringVar(value="no files")
    ttk.Label(top, textvariable=files_var).pack(side="left", padx=10)

    body = ttk.Frame(root, padding=(10, 0))
    body.pack(fill="both", expand=True)

    # left: options
    opts = ttk.Frame(body)
    opts.pack(side="left", fill="y")

    ttk.Label(opts, text="Type").grid(row=0, column=0, sticky="w", pady=(6, 0))
    type_var = tk.StringVar(value="background")
    for r, t in enumerate(("background", "frame", "avatar")):
        ttk.Radiobutton(opts, text=t.capitalize(), value=t, variable=type_var,
                        command=lambda: on_type()).grid(row=1 + r, column=0, sticky="w")

    ttk.Label(opts, text="ID (blank = filename)").grid(row=5, column=0, sticky="w", pady=(10, 0))
    id_var = tk.StringVar()
    ttk.Entry(opts, textvariable=id_var, width=24).grid(row=6, column=0, sticky="w")

    ttk.Label(opts, text="Frames").grid(row=7, column=0, sticky="w", pady=(10, 0))
    frames_var = tk.IntVar(value=DEFAULTS["background"])
    ttk.Spinbox(opts, from_=2, to=MAX_ANIM_FRAMES, textvariable=frames_var, width=8).grid(row=8, column=0, sticky="w")

    ttk.Label(opts, text="Max edge (px)").grid(row=9, column=0, sticky="w", pady=(10, 0))
    size_var = tk.IntVar(value=512)
    ttk.Spinbox(opts, from_=64, to=2048, increment=32, textvariable=size_var, width=8).grid(row=10, column=0, sticky="w")

    ttk.Label(opts, text="FPS").grid(row=11, column=0, sticky="w", pady=(10, 0))
    fps_var = tk.DoubleVar(value=12.0)
    ttk.Spinbox(opts, from_=1, to=60, increment=1, textvariable=fps_var, width=8).grid(row=12, column=0, sticky="w")

    ttk.Button(opts, text="Convert", command=lambda: do_convert()).grid(row=13, column=0, sticky="we", pady=16)

    # right: preview + log
    right = ttk.Frame(body)
    right.pack(side="left", fill="both", expand=True, padx=(14, 0))
    preview = ttk.Label(right, text="(preview)", anchor="center", relief="groove")
    preview.pack(fill="both", expand=True, pady=(6, 6))
    log_box = tk.Text(right, height=10, wrap="word")
    log_box.pack(fill="both", expand=True)

    def log(msg: str) -> None:
        log_box.insert("end", msg + "\n")
        log_box.see("end")
        root.update_idletasks()

    def on_type() -> None:
        frames_var.set(DEFAULTS[type_var.get()])
        size_var.set(256 if type_var.get() == "frame" else 512)

    def _stop_preview() -> None:
        if state["preview_job"]:
            root.after_cancel(state["preview_job"])
            state["preview_job"] = None

    def _load_preview(path: Path) -> None:
        _stop_preview()
        try:
            with Image.open(path) as im:
                fr = [f.convert("RGBA").copy() for f in ImageSequence.Iterator(im)]
        except Exception as e:  # noqa: BLE001
            preview.config(image="", text=f"can't read:\n{e}")
            return
        thumbs = []
        for f in fr[:60]:
            f.thumbnail((280, 280), Image.LANCZOS)
            thumbs.append(ImageTk.PhotoImage(f))
        state["preview_frames"] = thumbs
        state["preview_i"] = 0

        def tick() -> None:
            if not state["preview_frames"]:
                return
            i = state["preview_i"] % len(state["preview_frames"])
            preview.config(image=state["preview_frames"][i], text="")
            state["preview_i"] = i + 1
            state["preview_job"] = root.after(80, tick)

        tick()

    def add_files() -> None:
        picked = filedialog.askopenfilenames(title="Pick GIF(s)", filetypes=[("GIF", "*.gif"), ("All", "*.*")])
        for p in picked:
            if p not in state["files"]:
                state["files"].append(p)
        refresh_files()
        if state["files"]:
            _load_preview(Path(state["files"][-1]))

    def clear_files() -> None:
        state["files"].clear()
        refresh_files()
        _stop_preview()
        preview.config(image="", text="(preview)")

    def refresh_files() -> None:
        n = len(state["files"])
        files_var.set("no files" if not n else
                      Path(state["files"][0]).name if n == 1 else f"{n} files")

    def do_convert() -> None:
        if not state["files"]:
            messagebox.showwarning("Nothing to do", "Add at least one GIF.")
            return
        t = type_var.get()
        multi = len(state["files"]) > 1
        log(f"--- converting {len(state['files'])} file(s) as '{t}' ---")
        ok = 0
        for f in state["files"]:
            try:
                convert_gif(
                    Path(f), t,
                    cosmetic_id=None if multi or not id_var.get().strip() else id_var.get().strip(),
                    frames=frames_var.get(), max_edge=size_var.get(), fps=fps_var.get(),
                    log=log,
                )
                ok += 1
            except Exception as e:  # noqa: BLE001
                log(f"  ERROR {Path(f).name}: {e}")
        log(f"done: {ok}/{len(state['files'])}.  Now run:  godot --headless --import\n")

    on_type()
    root.mainloop()
    return 0


# -------------------------------------------------------------------------- CLI

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gifs", nargs="*", help="GIF file(s); omit to open the UI")
    ap.add_argument("--cli", action="store_true", help="convert on the command line instead of opening the UI")
    ap.add_argument("--type", choices=list(OUT_DIRS), default="background")
    ap.add_argument("--id", default=None, help="cosmetic id (single file only; default = filename)")
    ap.add_argument("--frames", type=int, default=24)
    ap.add_argument("--max", dest="max_edge", type=int, default=512)
    ap.add_argument("--fps", type=float, default=12.0)
    args = ap.parse_args()

    if not args.cli and not args.gifs:
        return run_ui()
    if not args.gifs:
        ap.error("pass GIF paths with --cli, or no args for the UI")

    for g in args.gifs:
        convert_gif(
            Path(g), args.type,
            cosmetic_id=args.id if len(args.gifs) == 1 else None,
            frames=args.frames, max_edge=args.max_edge, fps=args.fps,
        )
    print("done. now run:  godot --headless --import")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""GIF -> animated Godot cosmetic (avatar frame / background / avatar).

Godot 4 can't load a .gif directly, but an `AnimatedTexture` resource IS a
Texture2D and self-animates wherever it's assigned. This tool takes a GIF,
lets you edit it (trim, exclude specific frames, rotate, flip, crop/reposition,
brightness/color/contrast), subsamples + downscales the result to
`assets/<dir>/<id>/frame_NN.png`, and writes `assets/<dir>/<id>.tres` (the
AnimatedTexture). The Frames/Backgrounds/Avatars lookups prefer a `.tres` over
a `.png` of the same id, so the animated version just shows up everywhere the
cosmetic renders.

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
    from PIL import Image, ImageSequence, ImageEnhance, ImageChops, ImageDraw
except ImportError:
    _msg = "Pillow is required. Install it with:\n\n    pip install Pillow"
    try:  # double-clicked (no console) -> show a dialog instead of a dead stderr
        import tkinter.messagebox as _mb
        _mb.showerror("gif_to_cosmetic", _msg)
    except Exception:
        pass
    sys.exit(_msg)

REPO_ROOT = Path(__file__).resolve().parent.parent

# Mirrors the DIR consts in client/{frames,backgrounds,avatars}.gd
OUT_DIRS = {
    "frame":            "assets/avatars/avatar_frame",
    "background":       "assets/avatars/avatar_bg",
    "avatar":           "assets/avatars",
    "sleeve":           "assets/avatars/card_backs",
    "table_background": "assets/tables",
}
DEFAULTS = {"frame": 22, "background": 24, "avatar": 20, "sleeve": 24, "table_background": 24}
MAX_ANIM_FRAMES = 256  # AnimatedTexture hard cap


def sanitize_id(name: str) -> str:
    """Match the sanitize() rules in the .gd lookups: [A-Za-z0-9_-] only."""
    return re.sub(r"[^A-Za-z0-9_-]", "_", name).strip("_") or "cosmetic"


def _pick_indices(n_src: int, target: int) -> list[int]:
    if n_src <= target:
        return list(range(n_src))
    return [round(i * (n_src - 1) / (target - 1)) for i in range(target)]


def parse_index_ranges(text: str) -> set[int]:
    """"3, 7, 10-12" -> {3, 7, 10, 11, 12}. Blank/garbage entries are ignored."""
    out: set[int] = set()
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            try:
                lo, hi = int(a), int(b)
            except ValueError:
                continue
            if lo > hi:
                lo, hi = hi, lo
            out.update(range(lo, hi + 1))
        else:
            try:
                out.add(int(part))
            except ValueError:
                continue
    return out


def _enhance_preserving_alpha(img: Image.Image, enhancer_cls, factor: float) -> Image.Image:
    """PIL's Brightness/Contrast enhancers blend toward a degenerate image that
    has alpha=0 — applied directly to RGBA this corrupts transparency (e.g.
    darkening also fades the image out). Enhance the RGB channels only and
    reattach the original alpha untouched."""
    if factor == 1.0:
        return img
    if img.mode == "RGBA":
        alpha = img.split()[3]
        rgb = enhancer_cls(img.convert("RGB")).enhance(factor)
        out = rgb.convert("RGBA")
        out.putalpha(alpha)
        return out
    return enhancer_cls(img).enhance(factor)


def apply_edits(
    frame: Image.Image,
    *,
    rotate_deg: float = 0.0,
    flip_h: bool = False,
    flip_v: bool = False,
    crop_box: tuple[float, float, float, float] | None = None,
    brightness: float = 1.0,
    color: float = 1.0,
    contrast: float = 1.0,
) -> Image.Image:
    """One frame through the full edit pipeline, in a fixed order so combining
    edits behaves predictably: rotate -> flip -> crop -> color adjustments.
    `crop_box` is (left, top, right, bottom) as 0..1 fractions of the frame
    AFTER rotate/flip (so it stays valid across rotation changes — rotation
    can change the frame's pixel size via expand=True, but the fractional box
    still means the same thing relative to whatever that size currently is).
    """
    if rotate_deg % 360 != 0:
        # Negated so positive degrees reads as clockwise in the UI (PIL's
        # rotate() is counter-clockwise-positive).
        frame = frame.rotate(-rotate_deg, expand=True, resample=Image.BICUBIC)
    if flip_h:
        frame = frame.transpose(Image.FLIP_LEFT_RIGHT)
    if flip_v:
        frame = frame.transpose(Image.FLIP_TOP_BOTTOM)
    if crop_box is not None:
        w, h = frame.size
        l, t, r, b = crop_box
        box = (round(l * w), round(t * h), round(r * w), round(b * h))
        if box[2] > box[0] and box[3] > box[1]:
            frame = frame.crop(box)
    frame = _enhance_preserving_alpha(frame, ImageEnhance.Brightness, brightness)
    frame = _enhance_preserving_alpha(frame, ImageEnhance.Contrast, contrast)
    frame = _enhance_preserving_alpha(frame, ImageEnhance.Color, color)
    return frame


# Card backs (sleeves) render with no border overlay of their own in-game
# (client/table_card_view.tscn's BackRect is a single flat texture — unlike
# the face-up art view, which layers a border on top separately) so every
# static card back has the frame hand-painted into the art itself. An
# animated one needs the same border baked into every exported frame.
#
# card_border2.png (not card_border1.png — that one's a different, mismatched
# aspect ratio, kept only for the front-face view that already uses it) is
# authored at exactly 550x800, matching every existing static sleeve and the
# in-game display ratio (both card_view.tscn and table_card_view.tscn show a
# card at 240x340 with 10px margins all around, i.e. an effective ~220x320
# art area — 0.6875, same ratio as 550:800). Since the source is already at
# the right ratio, no stretching or cover-crop is needed to reconcile it —
# SLEEVE_CANVAS_SIZE just IS its native size.
CARD_BORDER_PATH = REPO_ROOT / "assets/cards/card_border2.png"
SLEEVE_CANVAS_SIZE = (550, 800)
_card_border_cache: Image.Image | None = None
_card_border_sized_cache: dict[tuple[int, int], Image.Image] = {}


def _card_border() -> Image.Image:
    global _card_border_cache
    if _card_border_cache is None:
        _card_border_cache = Image.open(CARD_BORDER_PATH).convert("RGBA")
    return _card_border_cache


def _card_border_at(size: tuple[int, int]) -> Image.Image:
    """The border resized to `size` if it's ever asked for at something
    other than its own native size — a no-op today (card_border2.png already
    IS SLEEVE_CANVAS_SIZE) kept as a safety net. Deliberately a plain
    (possibly non-uniform) resize, not cover-fit/cropped: cropping the
    border shifts which pixels land at (0,0) — since the transparent
    "outside the rounded corner" region is fairly shallow before it turns
    opaque, a modest crop is enough to land back inside the opaque ring,
    undoing the corner-clip fix in _card_shape_mask below entirely
    (confirmed the hard way against the old, wrong-ratio card_border1.png).
    A plain resize keeps every corner's alpha exactly where it was."""
    if size not in _card_border_sized_cache:
        _card_border_sized_cache[size] = _card_border().resize(size, Image.LANCZOS)
    return _card_border_sized_cache[size]


_card_shape_mask_cache: dict[tuple[int, int], Image.Image] = {}


def _card_shape_mask(border: Image.Image) -> Image.Image:
    """1-channel "L" mask: 255 for the card's actual silhouette (the border's
    opaque ring, plus whatever it encloses — i.e. the hollow center meant to
    show art), 0 for the four corner triangles that are transparent in the
    border art AND genuinely outside the rounded card (confirmed by
    inspecting the file directly: its true (0,0) pixel is alpha=0) — those
    corners are NOT meant to show anything, but plain alpha-compositing
    can't tell that apart from the equally-transparent hollow center, so a
    rectangular art layer pokes its square corners out past the rounded
    frame there without this mask.

    Derived once per requested `border` size by flood-filling from the four
    image corners through transparent pixels — whatever the fill can't
    reach (walled off by the opaque ring) is the enclosed center, i.e. part
    of the card. Making no assumption about exact corner-radius geometry
    means this keeps working if the border art is ever redrawn differently.
    """
    if border.size in _card_shape_mask_cache:
        return _card_shape_mask_cache[border.size]
    alpha = border.split()[3]
    # Binarize first: treat any meaningfully-transparent pixel as
    # "background" so a flood-fill has clean 0/255 territory to work with,
    # instead of tripping over antialiased edge pixels.
    work = alpha.point(lambda a: 0 if a < 16 else 255).convert("L")
    w, h = work.size
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        if work.getpixel(seed) == 0:
            ImageDraw.floodfill(work, seed, 128)
    # Reached by the corner flood-fill (now 128) => truly outside the card.
    # Everything else — untouched background (the enclosed center) or the
    # ring itself (255) — is part of the card.
    mask = work.point(lambda v: 0 if v == 128 else 255)
    _card_shape_mask_cache[border.size] = mask
    return mask


def cover_resize(img: Image.Image, target_size: tuple[int, int]) -> Image.Image:
    """Scale `img` up/down (uniformly, no stretching) and center-crop it to
    exactly fill `target_size` — same semantics as CSS `background-size:
    cover` / Godot's STRETCH_KEEP_ASPECT_COVERED. Used to fit the art to the
    border's canvas without leaving gaps at the rounded corners (any excess
    is cropped from the center rather than the art being squashed to fit)."""
    tw, th = target_size
    sw, sh = img.size
    scale = max(tw / sw, th / sh)
    nw, nh = max(1, round(sw * scale)), max(1, round(sh * scale))
    resized = img.resize((nw, nh), Image.LANCZOS)
    left, top = (nw - tw) // 2, (nh - th) // 2
    return resized.crop((left, top, left + tw, top + th))


def composite_card_border(frame: Image.Image) -> Image.Image:
    """`frame` cover-fit to SLEEVE_CANVAS_SIZE (the actual in-game display
    ratio — see SLEEVE_CANVAS_SIZE's comment), clipped to the card's actual
    rounded silhouette (see
    _card_shape_mask — otherwise the art's square corners poke out past the
    frame's rounded ones, since the border's own corners are transparent
    same as its hollow center), then the border alpha-composited on top."""
    border = _card_border_at(SLEEVE_CANVAS_SIZE)
    base = cover_resize(frame, SLEEVE_CANVAS_SIZE).convert("RGBA")
    r, g, b, a = base.split()
    clipped_alpha = ImageChops.multiply(a, _card_shape_mask(border))
    base.putalpha(clipped_alpha)
    base.alpha_composite(border)
    return base


def convert_gif(
    gif_path: Path,
    cosmetic_type: str,
    *,
    cosmetic_id: str | None = None,
    frames: int = 24,
    max_edge: int = 512,
    fps: float = 12.0,
    trim_start: int = 0,
    trim_end: int | None = None,
    exclude: set[int] | None = None,
    rotate_deg: float = 0.0,
    flip_h: bool = False,
    flip_v: bool = False,
    crop_box: tuple[float, float, float, float] | None = None,
    brightness: float = 1.0,
    color: float = 1.0,
    contrast: float = 1.0,
    card_border: bool | None = None,
    log=print,
) -> Path:
    """Returns the written .tres path.

    trim_start/trim_end: inclusive source-frame index range to consider
    (before `frames` subsamples that range down to the output frame count).
    exclude: source-frame indices to drop from consideration entirely (e.g.
    a bad frame in the middle of an otherwise-good range).
    crop_box: (left, top, right, bottom), each 0..1, relative to the frame
    after rotate/flip. None = no crop.
    card_border: bake assets/cards/card_border2.png on top of every frame
    (see composite_card_border). None (default) = on automatically for
    type "sleeve" (card backs need it — they get no border overlay from the
    game itself, unlike face-up card art), off for every other type.
    """
    if cosmetic_type not in OUT_DIRS:
        raise ValueError(f"type must be one of {list(OUT_DIRS)}")
    frames = max(2, min(int(frames), MAX_ANIM_FRAMES))
    if card_border is None:
        card_border = cosmetic_type == "sleeve"

    cid = sanitize_id(cosmetic_id or gif_path.stem)
    out_dir = REPO_ROOT / OUT_DIRS[cosmetic_type]
    frames_dir = out_dir / cid
    frames_dir.mkdir(parents=True, exist_ok=True)

    with Image.open(gif_path) as im:
        src = [f.convert("RGBA") for f in ImageSequence.Iterator(im)]
    if not src:
        raise ValueError("no frames found in GIF")

    end = len(src) - 1 if trim_end is None else max(0, min(trim_end, len(src) - 1))
    start = max(0, min(trim_start, end))
    excl = exclude or set()
    selected = [f for i, f in enumerate(src) if start <= i <= end and i not in excl]
    if not selected:
        raise ValueError("no frames left after trim/exclude — check the range")

    edited = [
        apply_edits(
            f, rotate_deg=rotate_deg, flip_h=flip_h, flip_v=flip_v,
            crop_box=crop_box, brightness=brightness, color=color, contrast=contrast,
        )
        for f in selected
    ]

    idxs = _pick_indices(len(edited), frames)
    # With a border, the OUTPUT canvas is SLEEVE_CANVAS_SIZE — the actual
    # in-game display ratio — the art gets cover-fit into it, not the other
    # way around. Max Edge still controls final resolution, just scaling
    # everything together.
    w0, h0 = SLEEVE_CANVAS_SIZE if card_border else edited[0].size
    scale = min(1.0, max_edge / max(w0, h0))
    size = (max(1, round(w0 * scale)), max(1, round(h0 * scale)))

    # Clear any stale frames from a previous, longer run.
    for old in frames_dir.glob("frame_*.png"):
        old.unlink()

    written = []
    for out_i, s_i in enumerate(idxs):
        fr = edited[s_i]
        if card_border:
            fr = composite_card_border(fr)
        fr = fr.resize(size, Image.LANCZOS)
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

# Canvas hit-testing tolerance (px) for grabbing a crop-rect edge/corner
# instead of moving the whole box.
_HANDLE_PX = 10
_PREVIEW_BOX = 320  # the square the preview canvas fits frames into
_MIN_CROP_FRAC = 0.03  # smallest crop box side, as a fraction of the frame


def run_ui() -> int:
    try:
        import tkinter as tk
        from tkinter import ttk, filedialog, messagebox
        from PIL import ImageTk
    except ImportError as e:
        sys.exit(f"UI needs tkinter + Pillow's ImageTk ({e}). Use --cli instead.")

    root = tk.Tk()
    root.title("GIF -> Godot cosmetic")
    root.geometry("880x680")
    root.minsize(820, 620)

    # --- state -----------------------------------------------------------
    # "raw_frames": untouched RGBA frames straight from the currently-loaded
    # GIF. "preview_frames": raw_frames with rotate/flip/color edits applied
    # (NOT cropped — the crop box is drawn as an overlay so you can see
    # what's outside it while positioning it) and thumbnailed for display.
    state: dict = {
        "path": None, "raw_frames": [], "preview_frames": [], "preview_tk": [],
        "preview_i": 0, "preview_job": None,
        "crop": [0.0, 0.0, 1.0, 1.0],  # left, top, right, bottom, 0..1
        "drag_mode": None,  # None | "move" | "nw" | "ne" | "sw" | "se" | "n" | "s" | "e" | "w"
        "drag_start": (0, 0), "drag_crop0": None,
        "canvas_img_box": (0, 0, 0, 0),  # where the current frame is drawn on canvas, in canvas px
    }

    top = ttk.Frame(root, padding=10)
    top.pack(fill="x")
    ttk.Button(top, text="Add GIF(s)…", command=lambda: add_files()).pack(side="left")
    ttk.Button(top, text="Clear", command=lambda: clear_files()).pack(side="left", padx=6)
    files_var = tk.StringVar(value="no files")
    ttk.Label(top, textvariable=files_var).pack(side="left", padx=10)

    body = ttk.Frame(root, padding=(10, 0))
    body.pack(fill="both", expand=True)

    # --- left: options, scrollable (a lot of controls now) ---------------
    opts_outer = ttk.Frame(body, width=280)
    opts_outer.pack(side="left", fill="y")
    opts_outer.pack_propagate(False)
    opts_canvas = tk.Canvas(opts_outer, highlightthickness=0, width=280)
    opts_scroll = ttk.Scrollbar(opts_outer, orient="vertical", command=opts_canvas.yview)
    opts = ttk.Frame(opts_canvas)
    opts.bind("<Configure>", lambda e: opts_canvas.configure(scrollregion=opts_canvas.bbox("all")))
    opts_canvas.create_window((0, 0), window=opts, anchor="nw")
    opts_canvas.configure(yscrollcommand=opts_scroll.set)
    opts_canvas.pack(side="left", fill="both", expand=True)
    opts_scroll.pack(side="left", fill="y")

    def _on_mousewheel(event):
        opts_canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")
    opts_canvas.bind_all("<MouseWheel>", _on_mousewheel)

    row = 0

    def _section(title: str) -> int:
        nonlocal row
        ttk.Separator(opts).grid(row=row, column=0, columnspan=2, sticky="we", pady=(10, 4))
        row += 1
        ttk.Label(opts, text=title, font=("", 9, "bold")).grid(row=row, column=0, columnspan=2, sticky="w")
        row += 1
        return row

    _section("Output")
    ttk.Label(opts, text="Type — pick one (nothing is pre-selected on\npurpose, so a converted file can't silently land\nin the wrong folder if you forget to choose)",
              font=("", 8), foreground="#888").grid(row=row, column=0, columnspan=2, sticky="w", pady=(4, 0))
    row += 1
    type_var = tk.StringVar(value="")  # deliberately no default — see label above
    for t in OUT_DIRS:
        ttk.Radiobutton(opts, text=t.replace("_", " ").capitalize(), value=t, variable=type_var,
                        command=lambda: on_type()).grid(row=row, column=0, sticky="w")
        row += 1

    card_border_var = tk.BooleanVar(value=False)
    ttk.Checkbutton(opts, text="Bake card border on top (sleeves need this —\nsee the 'with border' preview to the right)",
                    variable=card_border_var,
                    command=lambda: (_update_final_preview_visibility(), refresh_preview_frames())
                    ).grid(row=row, column=0, columnspan=2, sticky="w", pady=(4, 0))
    row += 1

    ttk.Label(opts, text="ID (blank = filename)").grid(row=row, column=0, sticky="w", pady=(6, 0))
    row += 1
    id_var = tk.StringVar()
    ttk.Entry(opts, textvariable=id_var, width=22).grid(row=row, column=0, columnspan=2, sticky="we")
    row += 1

    ttk.Label(opts, text="Frames (output count)").grid(row=row, column=0, sticky="w", pady=(6, 0))
    row += 1
    frames_var = tk.IntVar(value=DEFAULTS["background"])
    ttk.Spinbox(opts, from_=2, to=MAX_ANIM_FRAMES, textvariable=frames_var, width=8).grid(row=row, column=0, sticky="w")
    row += 1

    ttk.Label(opts, text="Max edge (px)").grid(row=row, column=0, sticky="w", pady=(6, 0))
    row += 1
    size_var = tk.IntVar(value=512)
    ttk.Spinbox(opts, from_=64, to=2048, increment=32, textvariable=size_var, width=8).grid(row=row, column=0, sticky="w")
    row += 1

    ttk.Label(opts, text="FPS").grid(row=row, column=0, sticky="w", pady=(6, 0))
    row += 1
    fps_var = tk.DoubleVar(value=12.0)
    ttk.Spinbox(opts, from_=1, to=60, increment=1, textvariable=fps_var, width=8).grid(row=row, column=0, sticky="w")
    row += 1

    row = _section("Trim & exclude")
    trim_row = ttk.Frame(opts)
    trim_row.grid(row=row, column=0, columnspan=2, sticky="we")
    row += 1
    ttk.Label(trim_row, text="Start").pack(side="left")
    trim_start_var = tk.IntVar(value=0)
    trim_start_box = ttk.Spinbox(trim_row, from_=0, to=0, textvariable=trim_start_var, width=6,
                                   command=lambda: refresh_preview_frames())
    trim_start_box.pack(side="left", padx=(4, 10))
    ttk.Label(trim_row, text="End").pack(side="left")
    trim_end_var = tk.IntVar(value=0)
    trim_end_box = ttk.Spinbox(trim_row, from_=0, to=0, textvariable=trim_end_var, width=6,
                                 command=lambda: refresh_preview_frames())
    trim_end_box.pack(side="left", padx=4)

    ttk.Label(opts, text="Exclude frames — 0-based like Trim above\n(e.g. 3,7,10-12; a 24-frame clip is 0-23)").grid(row=row, column=0, columnspan=2, sticky="w", pady=(6, 0))
    row += 1
    exclude_var = tk.StringVar(value="")
    exclude_entry = ttk.Entry(opts, textvariable=exclude_var, width=22)
    exclude_entry.grid(row=row, column=0, columnspan=2, sticky="we")
    # Live update on every keystroke — parse_index_ranges silently ignores
    # whatever's not finished typing yet ("3,7,1" mid-edit just becomes {3,7,1}
    # until you finish "10-12"), so there's nothing to wait for a blur/Enter
    # before refreshing.
    exclude_entry.bind("<KeyRelease>", lambda e: refresh_preview_frames())
    exclude_entry.bind("<FocusOut>", lambda e: refresh_preview_frames())
    exclude_entry.bind("<Return>", lambda e: refresh_preview_frames())
    row += 1

    row = _section("Rotate & flip")
    rot_row = ttk.Frame(opts)
    rot_row.grid(row=row, column=0, columnspan=2, sticky="we")
    row += 1
    rotate_var = tk.DoubleVar(value=0.0)
    ttk.Label(rot_row, text="Degrees").pack(side="left")
    rotate_box = ttk.Spinbox(rot_row, from_=-360, to=360, increment=1, textvariable=rotate_var, width=6,
                              command=lambda: refresh_preview_frames())
    rotate_box.pack(side="left", padx=4)
    rotate_box.bind("<Return>", lambda e: refresh_preview_frames())

    quick_row = ttk.Frame(opts)
    quick_row.grid(row=row, column=0, columnspan=2, sticky="we", pady=(4, 0))
    row += 1

    def _bump_rotate(delta):
        rotate_var.set((rotate_var.get() + delta) % 360)
        refresh_preview_frames()

    ttk.Button(quick_row, text="-90°", width=5, command=lambda: _bump_rotate(-90)).pack(side="left")
    ttk.Button(quick_row, text="+90°", width=5, command=lambda: _bump_rotate(90)).pack(side="left", padx=4)
    ttk.Button(quick_row, text="180°", width=5, command=lambda: _bump_rotate(180)).pack(side="left")
    ttk.Button(quick_row, text="Reset", width=6, command=lambda: (rotate_var.set(0), refresh_preview_frames())).pack(side="left", padx=4)

    flip_h_var = tk.BooleanVar(value=False)
    flip_v_var = tk.BooleanVar(value=False)
    ttk.Checkbutton(opts, text="Flip horizontal", variable=flip_h_var,
                    command=lambda: refresh_preview_frames()).grid(row=row, column=0, columnspan=2, sticky="w", pady=(4, 0))
    row += 1
    ttk.Checkbutton(opts, text="Flip vertical", variable=flip_v_var,
                    command=lambda: refresh_preview_frames()).grid(row=row, column=0, columnspan=2, sticky="w")
    row += 1

    row = _section("Crop")
    ttk.Label(opts, text="Drag the box on the preview to move it;\ndrag an edge/corner to resize.",
              foreground="#888", font=("", 8)).grid(row=row, column=0, columnspan=2, sticky="w")
    row += 1
    crop_readout_var = tk.StringVar(value="Crop: full frame")
    ttk.Label(opts, textvariable=crop_readout_var, font=("", 8)).grid(row=row, column=0, columnspan=2, sticky="w", pady=(4, 0))
    row += 1
    ttk.Button(opts, text="Reset crop", command=lambda: reset_crop()).grid(row=row, column=0, sticky="w", pady=(4, 0))
    row += 1

    row = _section("Color adjust")

    def _slider(label, default=1.0, frm=0.0, to=2.0):
        nonlocal row
        ttk.Label(opts, text=label).grid(row=row, column=0, sticky="w", pady=(6, 0))
        row += 1
        var = tk.DoubleVar(value=default)
        s = ttk.Scale(opts, from_=frm, to=to, variable=var, orient="horizontal",
                       command=lambda _v: refresh_preview_frames())
        s.grid(row=row, column=0, columnspan=2, sticky="we")
        row += 1
        return var

    brightness_var = _slider("Brightness")
    color_var = _slider("Color / saturation")
    contrast_var = _slider("Contrast")
    ttk.Button(opts, text="Reset adjustments", command=lambda: reset_adjustments()).grid(row=row, column=0, sticky="w", pady=(4, 0))
    row += 1

    convert_button = ttk.Button(opts, text="Convert", command=lambda: do_convert(), state="disabled")
    convert_button.grid(row=row, column=0, columnspan=2, sticky="we", pady=16)
    row += 1

    # --- right: preview canvas(es) + log ------------------------------------
    right = ttk.Frame(body)
    right.pack(side="left", fill="both", expand=True, padx=(14, 0))
    previews_row = ttk.Frame(right)
    previews_row.pack(pady=(6, 6))

    preview_col = ttk.Frame(previews_row)
    preview_col.pack(side="left")
    ttk.Label(preview_col, text="Edit (drag the crop box)", font=("", 8)).pack()
    canvas = tk.Canvas(preview_col, width=_PREVIEW_BOX, height=_PREVIEW_BOX, background="#202020", highlightthickness=1, highlightbackground="#555")
    canvas.pack()

    # Shown only for sleeves (or whenever "Bake card border" is checked) —
    # the actual final result, border included, so corner-fit problems are
    # visible live while dragging the crop box above instead of only after
    # converting.
    final_col = ttk.Frame(previews_row)
    final_label = ttk.Label(final_col, text="Final (with border)", font=("", 8))
    final_label.pack()
    final_canvas = tk.Canvas(final_col, width=_PREVIEW_BOX, height=_PREVIEW_BOX, background="#202020", highlightthickness=1, highlightbackground="#555")
    final_canvas.pack()

    log_box = tk.Text(right, height=10, wrap="word")
    log_box.pack(fill="both", expand=True)

    def log(msg: str) -> None:
        log_box.insert("end", msg + "\n")
        log_box.see("end")
        root.update_idletasks()

    # --- helpers -----------------------------------------------------------

    def on_type() -> None:
        t = type_var.get()
        if t not in OUT_DIRS:  # startup, before anything is picked yet
            convert_button.configure(state="disabled")
            return
        convert_button.configure(state="normal")
        frames_var.set(DEFAULTS[t])
        size_var.set(256 if t == "frame" else 512)
        card_border_var.set(t == "sleeve")
        _update_final_preview_visibility()
        refresh_preview_frames()

    def _update_final_preview_visibility() -> None:
        if card_border_var.get():
            final_col.pack(side="left", padx=(10, 0))
        else:
            final_col.pack_forget()

    def _invalidate_final_cache() -> None:
        n = len(state.get("preview_frames", []))
        state["final_tk"] = [None] * n

    def reset_crop() -> None:
        state["crop"] = [0.0, 0.0, 1.0, 1.0]
        _update_crop_readout()
        _invalidate_final_cache()
        draw_canvas()

    def reset_adjustments() -> None:
        rotate_var.set(0.0)
        flip_h_var.set(False)
        flip_v_var.set(False)
        brightness_var.set(1.0)
        color_var.set(1.0)
        contrast_var.set(1.0)
        refresh_preview_frames()

    def _update_crop_readout() -> None:
        l, t, r, b = state["crop"]
        if (l, t, r, b) == (0.0, 0.0, 1.0, 1.0):
            crop_readout_var.set("Crop: full frame")
        else:
            crop_readout_var.set(f"Crop: {l*100:.0f}%,{t*100:.0f}% → {r*100:.0f}%,{b*100:.0f}%")

    def _stop_preview() -> None:
        if state["preview_job"]:
            root.after_cancel(state["preview_job"])
            state["preview_job"] = None

    def _current_edit_kwargs() -> dict:
        return dict(
            rotate_deg=rotate_var.get(),
            flip_h=flip_h_var.get(),
            flip_v=flip_v_var.get(),
            brightness=brightness_var.get(),
            color=color_var.get(),
            contrast=contrast_var.get(),
        )

    def _selected_range_frames() -> list[Image.Image]:
        """raw_frames filtered by the current trim range + exclusions. Can be
        genuinely empty (e.g. Exclude covers the whole Trim range) — that's
        deliberately NOT silently patched over here (an earlier version fell
        back to showing frame 0 regardless, which looked like the exclusion
        had no effect at all); refresh_preview_frames() shows a clear message
        instead. The real conversion (convert_gif) already refuses outright
        with "no frames left after trim/exclude" in this situation."""
        raw = state["raw_frames"]
        if not raw:
            return []
        start = max(0, min(trim_start_var.get(), len(raw) - 1))
        end = max(0, min(trim_end_var.get(), len(raw) - 1))
        if end < start:
            start, end = end, start
        excl = parse_index_ranges(exclude_var.get())
        return [f for i, f in enumerate(raw) if start <= i <= end and i not in excl]

    def refresh_preview_frames() -> None:
        """Rebuilds the (rotated/flipped/color-adjusted, NOT cropped) preview
        frame set from the current controls and restarts the animation.
        Previews the FULL selected range, not a truncated prefix — a partial
        prefix would loop from some arbitrary mid-animation frame back to
        frame 0 instead of from the actual last frame, breaking a GIF that's
        genuinely designed to loop seamlessly (a real bug this had: capping
        at 60 frames made a >60-frame source visibly jump on every loop, even
        though the untouched source file looped perfectly everywhere else).
        MAX_ANIM_FRAMES is just the same hard safety ceiling the actual
        conversion is already limited to — not a performance shortcut.
        """
        if not state["raw_frames"]:
            return
        sel = _selected_range_frames()
        if not sel:
            _stop_preview()
            state["preview_frames"] = []
            canvas.delete("all")
            canvas.create_text(_PREVIEW_BOX // 2, _PREVIEW_BOX // 2,
                                text="(no frames left —\nTrim/Exclude removed everything)",
                                fill="#f66", justify="center")
            final_canvas.delete("all")
            return
        kwargs = _current_edit_kwargs()
        edited = [apply_edits(f, crop_box=None, **kwargs) for f in sel[:MAX_ANIM_FRAMES]]
        state["preview_frames"] = edited
        state["preview_tk"] = [None] * len(edited)
        state["final_tk"] = [None] * len(edited)
        state["preview_i"] = 0
        draw_canvas()

    def _fit_box(w: int, h: int) -> tuple[int, int, int, int]:
        """Where a w x h image lands inside the square preview canvas, centered
        and scaled to fit — returns (x0, y0, x1, y1) in canvas px."""
        scale = min(_PREVIEW_BOX / w, _PREVIEW_BOX / h)
        dw, dh = round(w * scale), round(h * scale)
        x0 = (_PREVIEW_BOX - dw) // 2
        y0 = (_PREVIEW_BOX - dh) // 2
        return x0, y0, x0 + dw, y0 + dh

    def draw_final_preview() -> None:
        """The actual final result — current crop applied, cover-fit to the
        card border's canvas, border composited on top — so corner-fit
        problems (art not reaching the rounded edge, or an off-center crop)
        are visible live while dragging the crop box, not just after
        converting.

        Cached per frame index, same as the main preview canvas already is —
        this used to redo the crop + cover-resize + border composite from
        scratch on every single tick, uncached, which is real avoidable
        per-frame CPU cost that can show up as uneven/choppy playback
        (worth ruling out explicitly if a "pause at the loop" is ever
        reported again: does unchecking "Bake card border" make it go away?
        that would confirm this path was the cause rather than something in
        the animation timer itself). The cache is invalidated by resetting
        state["final_tk"] to a fresh all-None list whenever the crop box or
        the frame set changes (reset_crop, on_canvas_drag, and
        refresh_preview_frames all do this)."""
        if not card_border_var.get():
            return
        frames = state["preview_frames"]
        final_canvas.delete("all")
        if not frames:
            final_canvas.create_text(_PREVIEW_BOX // 2, _PREVIEW_BOX // 2, text="(final)", fill="#888")
            return
        i = state["preview_i"] % len(frames)
        cache = state.setdefault("final_tk", [None] * len(frames))
        if len(cache) != len(frames):  # frame set changed size without going through refresh_preview_frames
            cache = state["final_tk"] = [None] * len(frames)
        if cache[i] is None:
            frame = frames[i]
            l, t, r, b = state["crop"]
            w, h = frame.size
            box = (round(l * w), round(t * h), round(r * w), round(b * h))
            cropped = frame.crop(box) if box[2] > box[0] and box[3] > box[1] else frame
            final = composite_card_border(cropped)
            x0, y0, x1, y1 = _fit_box(*final.size)
            disp = final.resize((max(1, x1 - x0), max(1, y1 - y0)), Image.LANCZOS)
            cache[i] = ImageTk.PhotoImage(disp)
        x0, y0, _, _ = _fit_box(*SLEEVE_CANVAS_SIZE)
        final_canvas.create_image(x0, y0, anchor="nw", image=cache[i])

    def draw_canvas() -> None:
        canvas.delete("all")
        frames = state["preview_frames"]
        if not frames:
            canvas.create_text(_PREVIEW_BOX // 2, _PREVIEW_BOX // 2, text="(preview)", fill="#888")
            return
        i = state["preview_i"] % len(frames)
        frame = frames[i]
        x0, y0, x1, y1 = _fit_box(*frame.size)
        state["canvas_img_box"] = (x0, y0, x1, y1)
        if state["preview_tk"][i] is None:
            disp = frame.resize((max(1, x1 - x0), max(1, y1 - y0)), Image.LANCZOS)
            state["preview_tk"][i] = ImageTk.PhotoImage(disp)
        canvas.create_image(x0, y0, anchor="nw", image=state["preview_tk"][i])

        # Crop overlay: dim everything outside the box, outline + handles on it.
        l, t, r, b = state["crop"]
        iw, ih = x1 - x0, y1 - y0
        bx0, by0 = x0 + l * iw, y0 + t * ih
        bx1, by1 = x0 + r * iw, y0 + b * ih
        if (l, t, r, b) != (0.0, 0.0, 1.0, 1.0):
            canvas.create_rectangle(x0, y0, x1, by0, fill="#000000", stipple="gray50", outline="")
            canvas.create_rectangle(x0, by1, x1, y1, fill="#000000", stipple="gray50", outline="")
            canvas.create_rectangle(x0, by0, bx0, by1, fill="#000000", stipple="gray50", outline="")
            canvas.create_rectangle(bx1, by0, x1, by1, fill="#000000", stipple="gray50", outline="")
        canvas.create_rectangle(bx0, by0, bx1, by1, outline="#39d353", width=2)
        hs = 4
        for hx, hy in ((bx0, by0), (bx1, by0), (bx0, by1), (bx1, by1),
                       ((bx0 + bx1) / 2, by0), ((bx0 + bx1) / 2, by1),
                       (bx0, (by0 + by1) / 2), (bx1, (by0 + by1) / 2)):
            canvas.create_rectangle(hx - hs, hy - hs, hx + hs, hy + hs, fill="#39d353", outline="")

        draw_final_preview()

        def tick() -> None:
            if not state["preview_frames"]:
                return
            state["preview_i"] = (state["preview_i"] + 1) % len(state["preview_frames"])
            draw_canvas()
            state["preview_job"] = root.after(int(1000 / max(fps_var.get(), 1)), tick)

        _stop_preview()
        if len(frames) > 1:
            state["preview_job"] = root.after(int(1000 / max(fps_var.get(), 1)), tick)

    # --- crop-box mouse interaction -----------------------------------------

    def _hit_test(cx: int, cy: int) -> str | None:
        x0, y0, x1, y1 = state["canvas_img_box"]
        iw, ih = x1 - x0, y1 - y0
        if iw <= 0 or ih <= 0:
            return None
        l, t, r, b = state["crop"]
        bx0, by0, bx1, by1 = x0 + l * iw, y0 + t * ih, x0 + r * iw, y0 + b * ih
        near_l, near_r = abs(cx - bx0) <= _HANDLE_PX, abs(cx - bx1) <= _HANDLE_PX
        near_t, near_b = abs(cy - by0) <= _HANDLE_PX, abs(cy - by1) <= _HANDLE_PX
        in_x, in_y = bx0 - _HANDLE_PX <= cx <= bx1 + _HANDLE_PX, by0 - _HANDLE_PX <= cy <= by1 + _HANDLE_PX
        if near_l and near_t:
            return "nw"
        if near_r and near_t:
            return "ne"
        if near_l and near_b:
            return "sw"
        if near_r and near_b:
            return "se"
        if near_t and in_x:
            return "n"
        if near_b and in_x:
            return "s"
        if near_l and in_y:
            return "w"
        if near_r and in_y:
            return "e"
        if bx0 <= cx <= bx1 and by0 <= cy <= by1:
            return "move"
        return None

    def on_canvas_press(event) -> None:
        mode = _hit_test(event.x, event.y)
        if mode is None:
            return
        state["drag_mode"] = mode
        state["drag_start"] = (event.x, event.y)
        state["drag_crop0"] = list(state["crop"])

    def on_canvas_drag(event) -> None:
        mode = state["drag_mode"]
        if mode is None:
            return
        x0, y0, x1, y1 = state["canvas_img_box"]
        iw, ih = max(1, x1 - x0), max(1, y1 - y0)
        dx = (event.x - state["drag_start"][0]) / iw
        dy = (event.y - state["drag_start"][1]) / ih
        l0, t0, r0, b0 = state["drag_crop0"]
        l, t, r, b = l0, t0, r0, b0

        if mode == "move":
            w, h = r0 - l0, b0 - t0
            l = min(max(0.0, l0 + dx), 1.0 - w)
            t = min(max(0.0, t0 + dy), 1.0 - h)
            r, b = l + w, t + h
        else:
            if "w" in mode:
                l = min(max(0.0, l0 + dx), r0 - _MIN_CROP_FRAC)
            if "e" in mode:
                r = max(min(1.0, r0 + dx), l0 + _MIN_CROP_FRAC)
            if "n" in mode:
                t = min(max(0.0, t0 + dy), b0 - _MIN_CROP_FRAC)
            if "s" in mode:
                b = max(min(1.0, b0 + dy), t0 + _MIN_CROP_FRAC)

        state["crop"] = [l, t, r, b]
        _update_crop_readout()
        _invalidate_final_cache()
        draw_canvas()

    def on_canvas_release(_event) -> None:
        state["drag_mode"] = None

    canvas.bind("<ButtonPress-1>", on_canvas_press)
    canvas.bind("<B1-Motion>", on_canvas_drag)
    canvas.bind("<ButtonRelease-1>", on_canvas_release)

    # --- file management -----------------------------------------------------

    def load_gif(path: Path) -> None:
        state["path"] = path
        try:
            with Image.open(path) as im:
                state["raw_frames"] = [f.convert("RGBA") for f in ImageSequence.Iterator(im)]
        except Exception as e:  # noqa: BLE001
            state["raw_frames"] = []
            canvas.delete("all")
            canvas.create_text(_PREVIEW_BOX // 2, _PREVIEW_BOX // 2, text=f"can't read:\n{e}", fill="#f66")
            return
        n = len(state["raw_frames"])
        trim_start_box.configure(to=max(0, n - 1))
        trim_end_box.configure(to=max(0, n - 1))
        trim_start_var.set(0)
        trim_end_var.set(max(0, n - 1))
        exclude_var.set("")
        reset_crop()
        reset_adjustments()  # also calls refresh_preview_frames()

    def add_files() -> None:
        picked = filedialog.askopenfilenames(title="Pick GIF(s)", filetypes=[("GIF", "*.gif"), ("All", "*.*")])
        for p in picked:
            if p not in state.setdefault("files", []):
                state["files"].append(p)
        refresh_files()
        if state.get("files"):
            load_gif(Path(state["files"][-1]))

    def clear_files() -> None:
        state["files"] = []
        state["raw_frames"] = []
        state["preview_frames"] = []
        refresh_files()
        _stop_preview()
        canvas.delete("all")
        canvas.create_text(_PREVIEW_BOX // 2, _PREVIEW_BOX // 2, text="(preview)", fill="#888")

    def refresh_files() -> None:
        files = state.get("files", [])
        n = len(files)
        files_var.set("no files" if not n else Path(files[0]).name if n == 1 else f"{n} files")

    def do_convert() -> None:
        if type_var.get() not in OUT_DIRS:  # the button should already be disabled, but just in case
            messagebox.showwarning("Pick a type", "Choose an output Type above before converting.")
            return
        files = state.get("files", [])
        if not files:
            messagebox.showwarning("Nothing to do", "Add at least one GIF.")
            return
        t = type_var.get()
        multi = len(files) > 1
        crop = tuple(state["crop"])
        crop_arg = None if crop == (0.0, 0.0, 1.0, 1.0) else crop
        excl = parse_index_ranges(exclude_var.get())
        log(f"--- converting {len(files)} file(s) as '{t}' ---")
        ok = 0
        for f in files:
            try:
                convert_gif(
                    Path(f), t,
                    cosmetic_id=None if multi or not id_var.get().strip() else id_var.get().strip(),
                    frames=frames_var.get(), max_edge=size_var.get(), fps=fps_var.get(),
                    trim_start=trim_start_var.get(), trim_end=trim_end_var.get(), exclude=excl,
                    rotate_deg=rotate_var.get(), flip_h=flip_h_var.get(), flip_v=flip_v_var.get(),
                    crop_box=crop_arg,
                    brightness=brightness_var.get(), color=color_var.get(), contrast=contrast_var.get(),
                    card_border=card_border_var.get(),
                    log=log,
                )
                ok += 1
            except Exception as e:  # noqa: BLE001
                log(f"  ERROR {Path(f).name}: {e}")
        log(f"done: {ok}/{len(files)}.  Now run:  godot --headless --import\n")

    on_type()
    canvas.create_text(_PREVIEW_BOX // 2, _PREVIEW_BOX // 2, text="(preview)", fill="#888")
    root.mainloop()
    return 0


# -------------------------------------------------------------------------- CLI

def _parse_crop_arg(s: str | None) -> tuple[float, float, float, float] | None:
    if not s:
        return None
    parts = [float(x) for x in s.split(",")]
    if len(parts) != 4:
        raise ValueError("--crop needs 4 comma-separated fractions: left,top,right,bottom")
    return tuple(parts)  # type: ignore[return-value]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gifs", nargs="*", help="GIF file(s); omit to open the UI")
    ap.add_argument("--cli", action="store_true", help="convert on the command line instead of opening the UI")
    ap.add_argument("--type", choices=list(OUT_DIRS), default="background")
    ap.add_argument("--id", default=None, help="cosmetic id (single file only; default = filename)")
    ap.add_argument("--frames", type=int, default=24)
    ap.add_argument("--max", dest="max_edge", type=int, default=512)
    ap.add_argument("--fps", type=float, default=12.0)
    ap.add_argument("--trim-start", type=int, default=0)
    ap.add_argument("--trim-end", type=int, default=None)
    ap.add_argument("--exclude", default="", help='e.g. "3,7,10-12"')
    ap.add_argument("--rotate", type=float, default=0.0, help="degrees, clockwise")
    ap.add_argument("--flip-h", action="store_true")
    ap.add_argument("--flip-v", action="store_true")
    ap.add_argument("--crop", default=None, help='"left,top,right,bottom" as 0..1 fractions')
    ap.add_argument("--brightness", type=float, default=1.0)
    ap.add_argument("--color", dest="color_", type=float, default=1.0)
    ap.add_argument("--contrast", type=float, default=1.0)
    border_group = ap.add_mutually_exclusive_group()
    border_group.add_argument("--card-border", dest="card_border", action="store_true", default=None,
                               help="bake assets/cards/card_border2.png on top (default: on for --type sleeve, off otherwise)")
    border_group.add_argument("--no-card-border", dest="card_border", action="store_false")
    args = ap.parse_args()

    if not args.cli and not args.gifs:
        return run_ui()
    if not args.gifs:
        ap.error("pass GIF paths with --cli, or no args for the UI")

    crop_box = _parse_crop_arg(args.crop)
    exclude = parse_index_ranges(args.exclude)
    for g in args.gifs:
        convert_gif(
            Path(g), args.type,
            cosmetic_id=args.id if len(args.gifs) == 1 else None,
            frames=args.frames, max_edge=args.max_edge, fps=args.fps,
            trim_start=args.trim_start, trim_end=args.trim_end, exclude=exclude,
            rotate_deg=args.rotate, flip_h=args.flip_h, flip_v=args.flip_v,
            crop_box=crop_box,
            brightness=args.brightness, color=args.color_, contrast=args.contrast,
            card_border=args.card_border,
        )
    print("done. now run:  godot --headless --import")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

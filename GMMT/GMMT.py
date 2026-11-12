"""
SMH Face Tracker - webcam tracker with a clean control window

What it does:
  - Reads your webcam and tracks your face with Google MediaPipe
  - Shows a small control window: camera preview, status, live meters
  - Writes the blendshape values (plus eye gaze and head rotation) about 30
    times a second to garrysmod/data/smh_face_tracking.txt for the GMod addon

Setup (Windows, one time):
  1. Install Python from python.org (tick "Add Python to PATH" in the installer)
  2. Open a Command Prompt and run:
         py -m pip install mediapipe opencv-python numpy
  3. Run:
         py face_tracker.py
  4. Click "Browse..." once and pick your garrysmod\\data folder (it is remembered).

Command line (optional):
         py face_tracker.py --data-dir "D:\\...\\garrysmod\\data" --camera 1 --autostart
"""

import argparse
import base64
import json
import math
import os
import sys
import threading
import time
import urllib.request

try:
    import cv2
    import mediapipe as mp
    import numpy as np
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision
except ImportError as exc:
    print("A required package is missing: %s" % exc)
    print("Install everything with:")
    print("    py -m pip install mediapipe opencv-python numpy")
    sys.exit(1)

try:
    import tkinter as tk
    from tkinter import filedialog, ttk
except ImportError:
    print("Python's tkinter is missing. Re-run the Python installer, choose")
    print("'Modify', and make sure 'tcl/tk and IDLE' is ticked.")
    sys.exit(1)

# ---- Settings you may want to change ---------------------------------------

DEFAULT_DATA_DIR = r"E:\SteamLibrary\steamapps\common\GarrysMod\garrysmod\data"
OUTPUT_NAME = "smh_face_tracking.txt"   # .txt on purpose: GMod can always read it

MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/face_landmarker/"
             "face_landmarker/float16/1/face_landmarker.task")

# Meters shown in the window: (label, ARKit blendshape name)
METERS = [
    ("Jaw open", "jawOpen"),
    ("Smile L", "mouthSmileLeft"),
    ("Smile R", "mouthSmileRight"),
    ("Pucker", "mouthPucker"),
    ("Funnel", "mouthFunnel"),
    ("Cheek puff", "cheekPuff"),
    ("Blink L", "eyeBlinkLeft"),
    ("Blink R", "eyeBlinkRight"),
    ("Squint L", "eyeSquintLeft"),
    ("Brow up", "browInnerUp"),
    ("Brow down L", "browDownLeft"),
    ("Brow down R", "browDownRight"),
]

PREVIEW_WIDTH = 320
PREVIEW_EVERY = 2          # send every Nth camera frame to the preview

# Colours (dark theme)
BG = "#16181d"
PANEL = "#1f2229"
EDGE = "#2c313b"
TEXT = "#e6e8ec"
MUTED = "#8b93a1"
ACCENT = "#4c8dff"
GOOD = "#3ecf8e"
WARN = "#f5b83d"
BAD = "#ff5d5d"

# -----------------------------------------------------------------------------

HERE = os.path.dirname(os.path.abspath(__file__))
SETTINGS_PATH = os.path.join(HERE, "face_tracker_settings.json")
MODEL_PATH = os.path.join(HERE, "face_landmarker.task")

DEFAULT_SETTINGS = {
    "data_dir": DEFAULT_DATA_DIR,
    "camera": 0,
    "mirror": True,
    "show_preview": True,
    "flip_gaze_x": False,
    "flip_gaze_y": False,
    "flip_pitch": False,
    "flip_yaw": False,
    "flip_roll": False,
}


def load_settings():
    settings = dict(DEFAULT_SETTINGS)
    try:
        with open(SETTINGS_PATH, "r", encoding="utf-8") as f:
            saved = json.load(f)
        if isinstance(saved, dict):
            for key in DEFAULT_SETTINGS:
                if key in saved:
                    settings[key] = saved[key]
    except (OSError, ValueError):
        pass
    return settings


def save_settings(settings):
    try:
        with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2)
    except OSError:
        pass


def guess_data_dir():
    """Look in the usual Steam places so most people never need to browse."""
    candidates = []
    for drive in "CDEFGH":
        candidates.append(r"%s:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\data" % drive)
        candidates.append(r"%s:\SteamLibrary\steamapps\common\GarrysMod\garrysmod\data" % drive)
        candidates.append(r"%s:\Steam\steamapps\common\GarrysMod\garrysmod\data" % drive)
    for path in candidates:
        if os.path.isdir(path):
            return path
    return None


# ---- Maths helpers -----------------------------------------------------------

def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def gaze_from_shapes(shapes):
    """Eye direction from the eye-look blendshapes, each axis roughly -1..1.
    x > 0: the person looks toward THEIR left.  y > 0: looks up."""
    g = shapes.get
    x = ((g("eyeLookOutLeft", 0) - g("eyeLookInLeft", 0)) +
         (g("eyeLookInRight", 0) - g("eyeLookOutRight", 0))) / 2.0
    y = ((g("eyeLookUpLeft", 0) + g("eyeLookUpRight", 0)) -
         (g("eyeLookDownLeft", 0) + g("eyeLookDownRight", 0))) / 2.0
    return clamp(x, -1.0, 1.0), clamp(y, -1.0, 1.0)


def head_from_matrix(matrix):
    """Pitch / yaw / roll in degrees from MediaPipe's 4x4 face transform."""
    m = np.array(matrix, dtype=float).reshape(4, 4)
    r = m[:3, :3]
    # remove any scale so the rotation is clean
    for i in range(3):
        n = float(np.linalg.norm(r[:, i]))
        if n > 1e-9:
            r[:, i] = r[:, i] / n
    sy = math.sqrt(r[0, 0] ** 2 + r[1, 0] ** 2)
    pitch = math.degrees(math.atan2(r[2, 1], r[2, 2]))
    yaw = math.degrees(math.atan2(-r[2, 0], sy))
    roll = math.degrees(math.atan2(r[1, 0], r[0, 0]))
    # keep angles near zero when the face looks at the camera
    pitch = (pitch + 180.0) % 360.0 - 180.0
    return pitch, yaw, roll


def write_output(path, payload):
    """Write to a temp file first, then swap it in, so GMod never reads a half-written file."""
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(payload, f, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError:
        # GMod may be reading the file at this exact moment; just skip this frame
        pass


def open_camera(index):
    if os.name == "nt":
        return cv2.VideoCapture(index, cv2.CAP_DSHOW)
    return cv2.VideoCapture(index)


# ---- Worker thread -----------------------------------------------------------

class Tracker(threading.Thread):
    """Runs the camera and MediaPipe. The window only reads self.snapshot()."""

    def __init__(self, camera, out_path, flips, mirror):
        super().__init__(daemon=True)
        self.camera = camera
        self.out_path = out_path
        self.flips = flips            # shared dict, window may change it live
        self.mirror = mirror          # shared list [bool]
        self.preview_on = [True]      # shared list [bool]
        self.stop_event = threading.Event()
        self.lock = threading.Lock()
        self._state = {
            "status": "starting",     # starting, downloading, tracking, noface, error
            "message": "Starting...",
            "fps": 0.0,
            "shapes": {},
            "gaze": (0.0, 0.0),
            "head": (0.0, 0.0, 0.0),
            "png": None,
            "png_id": 0,
        }

    def _set(self, **kw):
        with self.lock:
            self._state.update(kw)

    def snapshot(self):
        with self.lock:
            return dict(self._state)

    def stop(self):
        self.stop_event.set()

    def run(self):
        cap = None
        landmarker = None
        try:
            if not os.path.exists(MODEL_PATH):
                self._set(status="downloading", message="Downloading the face model (one time only)...")
                urllib.request.urlretrieve(MODEL_URL, MODEL_PATH + ".part")
                os.replace(MODEL_PATH + ".part", MODEL_PATH)

            options = vision.FaceLandmarkerOptions(
                base_options=mp_python.BaseOptions(model_asset_path=MODEL_PATH),
                running_mode=vision.RunningMode.VIDEO,
                output_face_blendshapes=True,
                output_facial_transformation_matrixes=True,
                num_faces=1,
            )
            landmarker = vision.FaceLandmarker.create_from_options(options)

            cap = open_camera(self.camera)
            if not cap.isOpened():
                self._set(status="error",
                          message="Could not open camera %d. Pick another camera number." % self.camera)
                return

            last_ts = -1
            frames = 0
            fps_time = time.time()
            frame_count = 0
            self._set(status="tracking", message="Tracking")

            while not self.stop_event.is_set():
                ok, frame = cap.read()
                if not ok:
                    self._set(status="error", message="Lost the camera feed.")
                    break

                # Detect on the un-mirrored frame so left/right stay correct
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
                ts = int(time.monotonic() * 1000)
                if ts <= last_ts:
                    ts = last_ts + 1
                last_ts = ts
                result = landmarker.detect_for_video(mp_image, ts)

                shapes = {}
                face_found = bool(result.face_blendshapes)
                gaze = (0.0, 0.0)
                head = (0.0, 0.0, 0.0)
                if face_found:
                    for c in result.face_blendshapes[0]:
                        shapes[c.category_name] = round(c.score, 3)
                    gx, gy = gaze_from_shapes(shapes)
                    if self.flips.get("flip_gaze_x"):
                        gx = -gx
                    if self.flips.get("flip_gaze_y"):
                        gy = -gy
                    gaze = (gx, gy)
                    mats = result.facial_transformation_matrixes
                    if mats is not None and len(mats) > 0:
                        try:
                            p, y, r = head_from_matrix(mats[0])
                            if self.flips.get("flip_pitch"):
                                p = -p
                            if self.flips.get("flip_yaw"):
                                y = -y
                            if self.flips.get("flip_roll"):
                                r = -r
                            head = (p, y, r)
                        except Exception:
                            pass

                write_output(self.out_path, {
                    "t": time.time(),
                    "face": face_found,
                    "shapes": shapes,
                    "gaze": {"x": round(gaze[0], 3), "y": round(gaze[1], 3)},
                    "head": {"pitch": round(head[0], 2), "yaw": round(head[1], 2),
                             "roll": round(head[2], 2)},
                })

                frames += 1
                frame_count += 1
                now = time.time()
                fps = None
                if now - fps_time >= 1.0:
                    fps = frames / (now - fps_time)
                    frames = 0
                    fps_time = now

                update = {
                    "status": "tracking" if face_found else "noface",
                    "message": "Tracking" if face_found else "No face found",
                    "shapes": shapes,
                    "gaze": gaze,
                    "head": head,
                }
                if fps is not None:
                    update["fps"] = fps

                if self.preview_on[0] and frame_count % PREVIEW_EVERY == 0:
                    shown = cv2.flip(frame, 1) if self.mirror[0] else frame
                    h, w = shown.shape[:2]
                    small = cv2.resize(shown, (PREVIEW_WIDTH, int(h * PREVIEW_WIDTH / w)))
                    okp, buf = cv2.imencode(".png", small)
                    if okp:
                        update["png"] = base64.b64encode(buf.tobytes())
                        update["png_id"] = self._state["png_id"] + 1
                self._set(**update)
        except Exception as exc:  # show any surprise in the window instead of dying silently
            self._set(status="error", message="Error: %s" % exc)
        finally:
            # Tell GMod the tracker stopped so it doesn't keep using old values
            write_output(self.out_path, {"t": time.time(), "face": False, "shapes": {}})
            if cap is not None:
                cap.release()
            if landmarker is not None:
                landmarker.close()


# ---- Window ------------------------------------------------------------------

class App:
    def __init__(self, root, settings, autostart):
        self.root = root
        self.settings = settings
        self.tracker = None
        self.photo = None
        self.last_png_id = 0
        self.meter_rows = []
        self.flips = {k: bool(settings[k]) for k in settings if k.startswith("flip_")}
        self.mirror = [bool(settings["mirror"])]

        root.title("SMH Face Tracker")
        root.configure(bg=BG)
        root.resizable(False, False)
        root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.build_style()
        self.build_ui()
        self.refresh_status()
        root.after(33, self.poll)
        if autostart:
            root.after(300, self.toggle)

    # -- styling --
    def build_style(self):
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure(".", background=BG, foreground=TEXT, fieldbackground=PANEL,
                        bordercolor=EDGE, lightcolor=EDGE, darkcolor=EDGE,
                        font=("Segoe UI", 10))
        style.configure("TFrame", background=BG)
        style.configure("Card.TFrame", background=PANEL)
        style.configure("TLabel", background=BG, foreground=TEXT)
        style.configure("Card.TLabel", background=PANEL, foreground=TEXT)
        style.configure("Muted.TLabel", background=PANEL, foreground=MUTED, font=("Segoe UI", 9))
        style.configure("Head.TLabel", background=PANEL, foreground=MUTED,
                        font=("Segoe UI", 8, "bold"))
        style.configure("TCheckbutton", background=PANEL, foreground=TEXT)
        style.map("TCheckbutton", background=[("active", PANEL)])
        style.configure("TButton", background=EDGE, foreground=TEXT, padding=(10, 6), borderwidth=0)
        style.map("TButton", background=[("active", "#3a4150")])
        style.configure("Accent.TButton", background=ACCENT, foreground="white",
                        padding=(10, 9), font=("Segoe UI", 11, "bold"))
        style.map("Accent.TButton", background=[("active", "#6aa0ff")])
        style.configure("Stop.TButton", background=BAD, foreground="white",
                        padding=(10, 9), font=("Segoe UI", 11, "bold"))
        style.map("Stop.TButton", background=[("active", "#ff7c7c")])
        style.configure("TEntry", fieldbackground=BG, foreground=TEXT, insertcolor=TEXT)
        style.configure("TCombobox", fieldbackground=BG, background=EDGE, foreground=TEXT,
                        arrowcolor=TEXT)
        style.map("TCombobox", fieldbackground=[("readonly", BG)],
                  foreground=[("readonly", TEXT)])

    def card(self, parent, title):
        outer = ttk.Frame(parent, style="Card.TFrame", padding=12)
        if title:
            ttk.Label(outer, text=title.upper(), style="Head.TLabel").pack(anchor="w", pady=(0, 8))
        return outer

    # -- layout --
    def build_ui(self):
        pad = 12
        top = ttk.Frame(self.root, padding=(pad, pad, pad, 0))
        top.pack(fill="x")

        # left: preview + status
        left = ttk.Frame(top)
        left.pack(side="left", anchor="n")
        preview_card = self.card(left, "")
        preview_card.pack()
        self.preview = tk.Label(preview_card, bg="#0d0e11", fg=MUTED, width=PREVIEW_WIDTH // 8,
                                height=15, text="Camera preview\n(press Start)", justify="center",
                                font=("Segoe UI", 10))
        self.preview.pack()

        status_card = self.card(left, "Status")
        status_card.pack(fill="x", pady=(10, 0))
        row = ttk.Frame(status_card, style="Card.TFrame")
        row.pack(fill="x")
        self.dot = tk.Canvas(row, width=14, height=14, bg=PANEL, highlightthickness=0)
        self.dot.pack(side="left")
        self.dot_item = self.dot.create_oval(2, 2, 12, 12, fill=MUTED, outline="")
        self.status_label = ttk.Label(row, text="Stopped", style="Card.TLabel",
                                      font=("Segoe UI", 11, "bold"))
        self.status_label.pack(side="left", padx=(8, 0))
        self.fps_label = ttk.Label(row, text="", style="Muted.TLabel")
        self.fps_label.pack(side="right")
        self.detail_label = ttk.Label(status_card, text="", style="Muted.TLabel",
                                      wraplength=PREVIEW_WIDTH - 20, justify="left")
        self.detail_label.pack(anchor="w", pady=(6, 0))

        # right: controls
        right = ttk.Frame(top)
        right.pack(side="left", anchor="n", padx=(pad, 0))

        setup = self.card(right, "Setup")
        setup.pack(fill="x")
        ttk.Label(setup, text="Garry's Mod data folder", style="Card.TLabel").pack(anchor="w")
        path_row = ttk.Frame(setup, style="Card.TFrame")
        path_row.pack(fill="x", pady=(4, 0))
        self.dir_var = tk.StringVar(value=self.settings["data_dir"])
        ttk.Entry(path_row, textvariable=self.dir_var, width=34).pack(side="left", fill="x", expand=True)
        ttk.Button(path_row, text="Browse...", command=self.browse).pack(side="left", padx=(6, 0))
        self.dir_note = ttk.Label(setup, text="", style="Muted.TLabel")
        self.dir_note.pack(anchor="w", pady=(4, 0))
        self.dir_var.trace_add("write", lambda *_: self.check_dir())

        cam_row = ttk.Frame(setup, style="Card.TFrame")
        cam_row.pack(fill="x", pady=(10, 0))
        ttk.Label(cam_row, text="Camera", style="Card.TLabel").pack(side="left")
        self.cam_var = tk.StringVar(value="Camera %d" % int(self.settings["camera"]))
        self.cam_box = ttk.Combobox(cam_row, textvariable=self.cam_var, state="readonly", width=12,
                                    values=["Camera %d" % i for i in range(6)])
        self.cam_box.pack(side="right")

        options = self.card(right, "Options")
        options.pack(fill="x", pady=(10, 0))
        self.mirror_var = tk.BooleanVar(value=self.mirror[0])
        ttk.Checkbutton(options, text="Mirror the preview", variable=self.mirror_var,
                        command=self.on_options).pack(anchor="w")
        self.preview_var = tk.BooleanVar(value=bool(self.settings["show_preview"]))
        ttk.Checkbutton(options, text="Show camera preview (off saves CPU)",
                        variable=self.preview_var, command=self.on_options).pack(anchor="w", pady=(4, 0))

        self.adv_open = False
        self.adv_button = ttk.Button(options, text="Direction fixes  \u25b8", command=self.toggle_adv)
        self.adv_button.pack(anchor="w", pady=(10, 0))
        self.adv_frame = ttk.Frame(options, style="Card.TFrame")
        ttk.Label(self.adv_frame, text="Tick one if the eyes or head move the wrong way in-game.",
                  style="Muted.TLabel", wraplength=250, justify="left").pack(anchor="w", pady=(0, 4))
        self.flip_vars = {}
        for key, label in (("flip_gaze_x", "Flip eyes left/right"),
                           ("flip_gaze_y", "Flip eyes up/down"),
                           ("flip_pitch", "Flip head nod"),
                           ("flip_yaw", "Flip head turn"),
                           ("flip_roll", "Flip head tilt")):
            var = tk.BooleanVar(value=self.flips.get(key, False))
            self.flip_vars[key] = var
            ttk.Checkbutton(self.adv_frame, text=label, variable=var,
                            command=self.on_options).pack(anchor="w")

        self.go_button = ttk.Button(right, text="Start tracking", style="Accent.TButton",
                                    command=self.toggle)
        self.go_button.pack(fill="x", pady=(10, 0))

        # bottom: meters
        meters = self.card(self.root, "Live values")
        meters.pack(fill="x", padx=pad, pady=pad)
        grid = ttk.Frame(meters, style="Card.TFrame")
        grid.pack(fill="x")
        for i, (label, key) in enumerate(METERS):
            col = i % 2
            row = i // 2
            cell = ttk.Frame(grid, style="Card.TFrame")
            cell.grid(row=row, column=col, padx=(0 if col == 0 else 14, 0), pady=2, sticky="w")
            ttk.Label(cell, text=label, style="Muted.TLabel", width=11).pack(side="left")
            canvas = tk.Canvas(cell, width=210, height=10, bg=BG, highlightthickness=0)
            canvas.pack(side="left")
            fill = canvas.create_rectangle(0, 0, 0, 10, fill=ACCENT, outline="")
            self.meter_rows.append((key, canvas, fill))

        extra = ttk.Frame(meters, style="Card.TFrame")
        extra.pack(fill="x", pady=(8, 0))
        self.gaze_label = ttk.Label(extra, text="Eyes  x 0.00   y 0.00", style="Muted.TLabel")
        self.gaze_label.pack(side="left")
        self.head_label = ttk.Label(extra, text="Head  0\u00b0 / 0\u00b0 / 0\u00b0", style="Muted.TLabel")
        self.head_label.pack(side="right")

        self.check_dir()

    # -- actions --
    def toggle_adv(self):
        self.adv_open = not self.adv_open
        if self.adv_open:
            self.adv_frame.pack(anchor="w", pady=(6, 0))
            self.adv_button.configure(text="Direction fixes  \u25be")
        else:
            self.adv_frame.pack_forget()
            self.adv_button.configure(text="Direction fixes  \u25b8")

    def browse(self):
        start = self.dir_var.get() if os.path.isdir(self.dir_var.get()) else None
        chosen = filedialog.askdirectory(title="Pick garrysmod\\data", initialdir=start)
        if chosen:
            self.dir_var.set(os.path.normpath(chosen))

    def check_dir(self):
        path = self.dir_var.get().strip()
        if os.path.isdir(path):
            ok = os.path.basename(os.path.normpath(path)).lower() == "data"
            self.dir_note.configure(
                text="Folder found" if ok else "Folder found (usually named 'data')",
                foreground=GOOD if ok else WARN)
        else:
            guess = guess_data_dir()
            hint = "Folder not found."
            if guess:
                hint += " Try Browse... (found one at %s)" % guess
            self.dir_note.configure(text=hint, foreground=BAD)

    def on_options(self):
        self.mirror[0] = bool(self.mirror_var.get())
        for key, var in self.flip_vars.items():
            self.flips[key] = bool(var.get())
        if self.tracker:
            self.tracker.preview_on[0] = bool(self.preview_var.get())
        if not self.preview_var.get():
            self.show_preview_text("Preview off")
        self.persist()

    def persist(self):
        try:
            camera = int(self.cam_var.get().split()[-1])
        except ValueError:
            camera = 0
        self.settings.update({
            "data_dir": self.dir_var.get().strip(),
            "camera": camera,
            "mirror": bool(self.mirror_var.get()),
            "show_preview": bool(self.preview_var.get()),
        })
        self.settings.update(self.flips)
        save_settings(self.settings)

    def show_preview_text(self, text):
        self.photo = None
        self.preview.configure(image="", text=text, width=PREVIEW_WIDTH // 8, height=15)

    def toggle(self):
        if self.tracker and self.tracker.is_alive():
            self.stop_tracker()
            return
        path = self.dir_var.get().strip()
        if not os.path.isdir(path):
            self.check_dir()
            self.set_status("Stopped", MUTED, "Pick your garrysmod\\data folder first.")
            return
        try:
            camera = int(self.cam_var.get().split()[-1])
        except ValueError:
            camera = 0
        self.persist()
        self.tracker = Tracker(camera, os.path.join(path, OUTPUT_NAME), self.flips, self.mirror)
        self.tracker.preview_on[0] = bool(self.preview_var.get())
        self.last_png_id = 0
        self.tracker.start()
        self.go_button.configure(text="Stop tracking", style="Stop.TButton")
        self.cam_box.configure(state="disabled")

    def stop_tracker(self):
        if self.tracker:
            self.tracker.stop()
            self.tracker.join(timeout=3)
        self.tracker = None
        self.go_button.configure(text="Start tracking", style="Accent.TButton")
        self.cam_box.configure(state="readonly")
        self.show_preview_text("Camera preview\n(press Start)")
        for _key, canvas, fill in self.meter_rows:
            canvas.coords(fill, 0, 0, 0, 10)
        self.gaze_label.configure(text="Eyes  x 0.00   y 0.00")
        self.head_label.configure(text="Head  0\u00b0 / 0\u00b0 / 0\u00b0")
        self.fps_label.configure(text="")
        self.set_status("Stopped", MUTED, "")

    def on_close(self):
        self.persist()
        self.stop_tracker()
        self.root.destroy()

    # -- display --
    def set_status(self, text, colour, detail):
        self.status_label.configure(text=text)
        self.dot.itemconfigure(self.dot_item, fill=colour)
        self.detail_label.configure(text=detail)

    def refresh_status(self):
        self.set_status("Stopped", MUTED, "Press Start tracking, then open Garry's Mod.")

    def poll(self):
        try:
            if self.tracker:
                snap = self.tracker.snapshot()
                status = snap["status"]
                if status == "tracking":
                    self.set_status("Tracking", GOOD, "Sending to Garry's Mod.")
                elif status == "noface":
                    self.set_status("No face found", WARN,
                                    "Look at the camera and make sure your face is well lit.")
                elif status == "error":
                    self.set_status("Problem", BAD, snap["message"])
                    if not self.tracker.is_alive():
                        self.stop_tracker()
                        self.set_status("Problem", BAD, snap["message"])
                else:
                    self.set_status("Starting", ACCENT, snap["message"])

                if snap["fps"]:
                    self.fps_label.configure(text="%.0f fps" % snap["fps"])

                if snap["png"] is not None and snap["png_id"] != self.last_png_id:
                    self.last_png_id = snap["png_id"]
                    try:
                        self.photo = tk.PhotoImage(data=snap["png"])
                        self.preview.configure(image=self.photo, text="", width=0, height=0)
                    except tk.TclError:
                        pass

                shapes = snap["shapes"]
                for key, canvas, fill in self.meter_rows:
                    v = clamp(float(shapes.get(key, 0.0)), 0.0, 1.0)
                    canvas.coords(fill, 0, 0, int(v * 210), 10)
                    canvas.itemconfigure(fill, fill=ACCENT if v < 0.85 else WARN)
                gx, gy = snap["gaze"]
                p, y, r = snap["head"]
                self.gaze_label.configure(text="Eyes  x %+.2f   y %+.2f" % (gx, gy))
                self.head_label.configure(text="Head  %+.0f\u00b0 / %+.0f\u00b0 / %+.0f\u00b0" % (p, y, r))
        finally:
            self.root.after(33, self.poll)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", default=None, help="Garry's Mod data folder to write into")
    parser.add_argument("--camera", type=int, default=None, help="Camera number (0 is the first camera)")
    parser.add_argument("--autostart", action="store_true", help="Start tracking immediately")
    args = parser.parse_args()

    settings = load_settings()
    if args.data_dir:
        settings["data_dir"] = args.data_dir
    elif not os.path.isdir(settings["data_dir"]):
        guess = guess_data_dir()
        if guess:
            settings["data_dir"] = guess
    if args.camera is not None:
        settings["camera"] = args.camera

    root = tk.Tk()
    App(root, settings, args.autostart)
    root.mainloop()


if __name__ == "__main__":
    main()

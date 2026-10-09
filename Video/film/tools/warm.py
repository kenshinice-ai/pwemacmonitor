"""Print when the panel's verdict line turned warm and calm in a panel take, and its length.

    python3 tools/warm.py build/raw/p-en.mov

The edit's times for the wait, the warm moment and the settling come from this: each take runs warm
at its own moment, depending on how hot the Mac was when it started.
"""
import subprocess, sys
import numpy as np

take = sys.argv[1]
pts = [float(p.strip(",")) for p in subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                                                     "-of", "csv=p=0", take], capture_output=True, text=True).stdout.split()]
# The verdict line under the title: amber when a channel is warm, grey when all are calm.
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", take, "-vf", "crop=300:20:236:88", "-fps_mode", "passthrough",
                      "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
a = np.frombuffer(raw, np.uint8).reshape(-1, 20, 300, 3).astype(int)
amber = ((a[..., 0] - a[..., 2]) > 70).sum(axis=(1, 2))
state = None
for t, n in zip(pts, amber):
    warm = n > 40
    if warm != state:
        print(f"{t:6.2f}  {'warm' if warm else 'calm'}")
        state = warm
print(f"{pts[-1]:6.2f}  end")

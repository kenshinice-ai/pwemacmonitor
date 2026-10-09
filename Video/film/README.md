# Film

A 43-second film of PWE Monitor at work, and a silent 11-second loop for the product page.
Vertical 1080 × 1920, captions and music, no voice. English and Chinese: the app's interface is
recorded in each language, and one edit serves both.

Everything on screen is recorded from the app on this Mac (an M4 Max) under a real load. The readings
are real. Nothing is drawn or recoloured afterwards.

Status, 2026-10-10: Lee has reviewed the film. The loop is on pwestudio.site/macmonitor. The film itself has not been posted anywhere.

The pipeline is the one in `07 TOOLS/PWE Loan Bar/Video/tutorial` (its README explains the script
files, the edit list and the recording rig). `tools/build.py` and `tools/winrec.swift` are the same
files as there; what is specific to this film is in `film.json`, `tools/take.py` and `tools/warm.py`.

## What the film shows, and what that took

- **The cores turn amber at once; the wing stays calm.** The feathers answer to heat, not to load.
- **After most of a minute of full load the CPU runs warm, and colour runs out along its feather.**
  That wait is real and is shortened in the edit (`"speed": 8`). The sample tag on screen says so.
- **The menu bar icon is the real menu bar**, enlarged 3.2 times. The recorder follows the icon as
  it moves and notes its width, so the neighbouring icons are never in the picture.
- **The panel is in a plain window, not the popover** (`--panel-window`, a developer flag added for
  this). The popover cannot be recorded while the Mac is in use: opening it takes the keyboard, and
  it closes on the first click anywhere else. The window shows the same view with the same readings.
- **The Network and Processes cards are hidden.** They would show this Mac's address and what it runs.
- **The desktop and fanless layouts are this Mac's readings in another Mac's layout**
  (`PWEMON_HARDWARE`). The captions say what the layout drops; they do not claim another machine.

## What is here

| File | What it is |
|---|---|
| `script.en.json`, `script.zh.json` | Captions, title and end card. Each cue has a `dur`, since nothing is spoken. `overrides` holds the times that depend on when that language's take ran warm. |
| `edit.json` | The edit, with logical take names: `p` panel, `m` menu bar icon, `d` desktop layout, `f` fanless layout. |
| `loop.json`, `script.loop.en.json`, `script.loop.zh.json` | The page loop: the top of the panel through calm, warm and calm again. |
| `film.json` | The label, the icon, and each take's size, width in points and corner radius. |
| `tools/take.py` | Records the four takes in one interface language. |
| `tools/warm.py` | Prints when a panel take ran warm and calm. |
| `tools/build.py`, `winrec.swift`, `activity.py`, `sheet.py`, `tile.py` | As in the Loan Bar film. |
| `build/` | A link to `~/Movies/PWE Films/monitor`. Not in git, not in iCloud. |

## Record the takes again

Do this when the panel changes.

> ⚠️ Let the Mac sit idle for ten minutes first. A Mac that has just been under load is heat-soaked:
> the take then runs warm two seconds into the load and there is no calm to show. `take.py` waits for
> three cool readings in a row, but it cannot cool the Mac for you.

1. Run `./build.sh` in the repository root.
   Success: the last line reads `✓ build/PWE Monitor.app`.
2. Run `swiftc -O tools/winrec.swift -o build/work/winrec`.
   Success: no errors (the `Sendable` warnings are expected).
3. Run `python3 tools/take.py en`, then `python3 tools/take.py zh-Hans`. Each takes about three minutes
   and pins every core for 55 seconds.
   Success: four lines `…: frames written N of M screenshots` with N above zero.
4. Run `python3 tools/warm.py build/raw/p-en.mov` (and `p-zh.mov`).
   Success: the first `warm` is later than 20 s. If it is earlier, the Mac was not cool: wait and repeat step 3.
5. Put the times into the script's `overrides`: the wait ends two seconds before the first `warm`;
   the warm step runs from there for 5.5 s; `bar-warm` sits inside the steady warm stretch;
   `panel-settle` starts a second before the load came off and ends after the next `calm`.
6. For each of the eight takes run
   `ffmpeg -i build/raw/<take>.mov -vf "fps=60,tpad=stop_mode=clone:stop_duration=3" -c:v libx264 -crf 12 -g 30 -pix_fmt yuv444p build/work/<take>.cfr.mp4`.
7. If a take's size changed, correct `size` and `points` in `film.json`.

## Rebuild

1. Copy the licensed music to `build/music.wav` (see the Loan Bar README).
2. Run `python3 tools/build.py script.en.json`, then the same with `script.zh.json`.
   Success: the last line is the path `build/tutorial-<lang>.mp4`.
3. For the loop, cut the top of the panel take:
   `ffmpeg -i build/work/p-en.cfr.mp4 -vf crop=754:736:0:0 -c:v libx264 -crf 12 -g 30 -pix_fmt yuv444p build/work/top-en.cfr.mp4` (and `zh`).
   Then run `python3 tools/build.py script.loop.en.json --edit loop.json --layout loop --silent --name loop-en` (and `zh`).
   Success: the last line is the path `build/loop-<lang>.mp4`.

## Something the takes showed about the app

Near 95 °C the verdict flips between "CPU warm" and "All five channels calm" second by second: one
take changed nine times in a minute. The film cuts around it. The app has no hysteresis on that line.

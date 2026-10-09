"""Record the takes the film is cut from, in one language of the app's interface.

    python3 tools/take.py en
    python3 tools/take.py zh-Hans

A second copy of PWE Monitor is started from build/ with `--panel-window`: the panel in a plain window
that stays open and never takes the keyboard. (The real popover cannot be recorded while the Mac is in
use: opening it takes the focus, and it closes on the first click anywhere else.) Readings are every
second, and the Network and Processes cards are hidden: they would show this Mac's address and what it
is running.
None of that is written to the preferences: it is passed on the command line, so the installed app
is not changed. One recorder takes the panel and the menu bar icon together, following the icon as it moves. Every logical core is then pinned for LOAD seconds and released. Twelve seconds turns the core bars
amber and leaves the wing calm: the feathers answer to heat, not to load, and it takes most of a minute
of full load for this chip to run warm. The colour that then runs out along a feather is the app reading it. Then the same panel is recorded as a
desktop Mac and as a fanless one would lay it out (PWEMON_HARDWARE; every reading is still this Mac's).

Writes build/raw/<take>-<lang>.mov for p (panel), m (menu bar), d (desktop) and f (fanless), and
build/raw/events-<lang>.json. Nothing here takes the pointer or the keyboard; the Mac can be in use.
The load does slow it for a minute.
"""
import json, os, pathlib, signal, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = ROOT.parent.parent
APP = REPO / "build/PWE Monitor.app"
MATCH = "PWE Monitor/build/PWE Monitor.app/Contents/MacOS/pwemon"
WORK, RAW = ROOT / "build/work", ROOT / "build/raw"
lang = sys.argv[1] if len(sys.argv) > 1 else "en"
tag = "zh" if lang.startswith("zh") else "en"
ARGS = ["--panel-window", "-language", lang, "-interval", "1", "-hiddenCards", "(network, processes)"]
PANEL = "PWE Monitor panel"
LOAD = 55                                           # seconds of full load: long enough for the CPU channel to run warm
COOL_AVG, COOL_MAX = 58, 68                         # °C: what the cores must be under before a take starts
events, load, recorders = [], [], []


def film_pid():
    """The film copy's process. Asked again after each wait: the process `open` reports first is not
    always the one that ends up owning the panel."""
    out = subprocess.run(["pgrep", "-f", MATCH], capture_output=True, text=True).stdout.split()
    return int(out[-1]) if out else None


def quit_film():
    subprocess.run(["pkill", "-f", MATCH])
    time.sleep(0.8)


def launch(hardware=None):
    quit_film()
    cmd = ["open", "-n", "-g"]
    if hardware:
        cmd += ["--env", f"PWEMON_HARDWARE={hardware}"]
    subprocess.run(cmd + [str(APP), "--args", *ARGS], check=True)
    for _ in range(60):
        if film_pid():
            break
        time.sleep(0.1)
    return film_pid()


def record(*args):
    movie = next(a for a in args if str(a).endswith(".mov"))
    log = open(RAW / (pathlib.Path(movie).stem + ".log"), "w")
    proc = subprocess.Popen([str(WORK / "winrec"), *map(str, args)], stdout=log, stderr=subprocess.STDOUT)
    recorders.append(proc)
    for _ in range(60):
        if "Recording started" in open(log.name).read():
            return proc
        if proc.poll() is not None:
            sys.exit(f"recorder stopped: {open(log.name).read().strip()}")
        time.sleep(0.1)
    sys.exit("recorder did not start")


def stop(proc):
    proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        proc.kill()


def cleanup():
    for p in load:
        p.kill()
    for p in recorders:
        if p.poll() is None:
            stop(p)
    quit_film()


def core_temps():
    out = subprocess.run([str(APP / "Contents/MacOS/pwemon"), "--json"], capture_output=True, text=True).stdout
    cpu = json.loads(out)["cpu"]
    return cpu["temp_avg"], cpu["temp_max"]


try:
    RAW.mkdir(parents=True, exist_ok=True)
    # Start cool, or there is no calm for the colour to leave. One reading under the line is not cool:
    # a Mac that has just been under load is heat-soaked, and a take started on the first cool reading
    # ran warm two seconds into the load. Three readings in a row, on the average and on the hottest core.
    cool = 0
    for _ in range(100):
        avg, top = core_temps()
        cool = cool + 1 if avg < COOL_AVG and top < COOL_MAX else 0
        if cool == 3:
            break
        print(f"waiting to cool: cores average {avg:.0f}°, hottest {top:.0f}° (want under {COOL_AVG}° and {COOL_MAX}°, three times running)", flush=True)
        time.sleep(15)
    else:
        sys.exit("the Mac did not cool down in twenty-five minutes; something else is working it")
    launch()
    time.sleep(14)                                   # the window opens after 1.5 s; the sensor baseline takes nine readings
    pid = film_pid()
    both = record(pid, RAW / f"p-{tag}.mov", PANEL, "item", pid, RAW / f"m-{tag}.mov")   # one process: two at once get nothing
    t0 = time.time()
    mark = lambda what: (events.append({"t": round(time.time() - t0, 2), "do": what}), print(f"{events[-1]['t']:6.2f}  {what}", flush=True))
    mark("recording")
    time.sleep(5)
    cores = int(subprocess.run(["sysctl", "-n", "hw.logicalcpu"], capture_output=True, text=True).stdout)
    load += [subprocess.Popen(["yes"], stdout=subprocess.DEVNULL) for _ in range(cores)]
    mark(f"load on: {cores} cores")
    time.sleep(LOAD)
    for p in load:
        p.kill()
    load.clear()
    mark("load off")
    time.sleep(16)
    stop(both)
    mark("stopped")
    for hardware, take in (("desktop", "d"), ("fanless", "f")):
        launch(hardware)
        time.sleep(14)
        pid = film_pid()
        r = record(pid, RAW / f"{take}-{tag}.mov", PANEL)
        time.sleep(3.5)
        stop(r)
        print(f"        {hardware} layout recorded", flush=True)
    (RAW / f"events-{tag}.json").write_text(json.dumps(events, indent=1))
    for take in "pdf":
        print((RAW / f"{take}-{tag}.log").read_text().strip().replace("Recording started\n", ""))
finally:
    cleanup()

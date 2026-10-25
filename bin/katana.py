#!/usr/bin/env python3
"""Helper for the Katana Omarchy plugin: Creative Sound BlasterX Katana (USB 041e:3247).

    katana.py status          JSON report of what the plugin shows
    katana.py profile N       select stored profile N (0..5)
    katana.py learn           step through the six profiles twice so the daemon learns what each holds
    katana.py volume N        set the PC volume to bar level N (0..50, 2% each)
    katana.py hw JSON         write the equalizer and enhancements of the Personal profile (see hw_write)
    katana.py daemon          keep PC volume and the Katana's bar in sync and learn what each profile
                              holds; one JSON event per line

The Katana reports its bar (0..50) as `5a 23 03 00 <level>` over HID. Buttons are reported
on interface 3, changes made from the PC on interface 4. The bar follows the ALSA
"Speakers" control (0..128) through a non-linear curve, measured with a sweep (SPEAKERS).
PipeWire's own software gain is pinned to 1.0 so loudness is applied once, by the Katana.

The speaker keeps its own equalizer (preamp + 10 bands) and enhancements per profile. They are
registers read as `5a 11` frames and written with `5a 12 07 01 <page> <register> <float32>`; a write
lands in the active profile and the speaker keeps it. Only the Personal profile is ever written.
"""
import fcntl
import glob
import json
import os
import re
import select
import signal
import struct
import subprocess
import sys
import threading
import time

VID_PID = "041E:3247"
CARD = "Katana"
BAR_MAX = 50
SETTLE = 0.05
PROFILES = 6
PERSONAL_PROFILE = 5  # the only profile the plugin writes to

# bar level -> (first, last) value of the ALSA "Speakers" control that yields it
SPEAKERS = {
    0: (0, 0), 1: (1, 25), 2: (26, 39), 3: (40, 48), 4: (49, 56), 5: (57, 61), 6: (62, 66),
    7: (67, 70), 8: (71, 74), 9: (75, 77), 10: (78, 80), 11: (81, 83), 12: (84, 86),
    13: (87, 88), 14: (89, 90), 15: (91, 92), 16: (93, 94), 17: (95, 96), 18: (97, 97),
    19: (98, 99), 20: (100, 100), 21: (101, 102), 22: (103, 103), 23: (104, 104),
    24: (105, 106), 25: (107, 107), 26: (108, 108), 27: (109, 109), 28: (110, 110),
    29: (111, 111), 30: (112, 112), 31: (113, 113), 32: (114, 114), 33: (115, 115),
    34: (116, 116), 35: (117, 117), 36: (118, 118), 37: (119, 119), 39: (120, 120),
    40: (121, 121), 41: (122, 122), 43: (123, 123), 44: (124, 124), 46: (125, 125),
    47: (126, 126), 49: (127, 127), 50: (128, 128),
}

STATE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "katana-omarchy")
STATE = os.path.join(STATE_DIR, "state.json")

lock = threading.Lock()
timer = None
level = None
node_id = None

# What the speaker holds per profile. It reports a profile as `5a 11 ...` frames carrying only the
# registers that changed since the previous profile, as (page, register, float32) entries, so the
# daemon applies them to a running model and keeps a snapshot per profile in state.json.
device_regs = {}
current_profile = None
snapshot_timer = None
EQ_ON = "9609"
EQ_BANDS = ["96%02x" % (0x0B + i) for i in range(10)]
EQ_PREAMP = "960a"
EQ_LIMIT = 12.0
EFFECTS = {"crystalizer": "9601", "surround": "9671", "smartVolume": "9670", "dialogPlus": "9672"}
WRITABLE_EFFECTS = {"dialogPlus": "9672", "surround": "9671", "smartVolume": "9670"}


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def emit(**event):
    print(json.dumps(event), flush=True)


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def update_state(change):
    """Read-modify-write state.json under a lock shared by the daemon and the commands.

    The file is replaced atomically, so a reader never sees it half written."""
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(os.path.join(STATE_DIR, "state.lock"), "w") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        state = load_state()
        change(state)
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, STATE)


def save_state(**values):
    update_state(lambda state: state.update(values))


def hidraw_paths():
    """Map HID interface number (3 = buttons, 4 = control channel) to its /dev node."""
    found = {}
    for path in glob.glob("/sys/class/hidraw/hidraw*"):
        real = os.path.realpath(os.path.join(path, "device"))
        m = re.search(r":1\.(\d)/", real)
        if m and VID_PID in real.upper():
            found[int(m.group(1))] = "/dev/" + os.path.basename(path)
    return found


def katana_sink():
    for line in run("pactl", "list", "short", "sinks").splitlines():
        if CARD in line:
            return line.split()[1]


def card_number():
    try:
        m = re.search(r"^\s*(\d+) .*" + CARD, open("/proc/asound/cards").read(), re.M)
    except OSError:
        return None
    return m.group(1) if m else None


def sink_percent(sink):
    m = re.search(r"(\d+)%", run("pactl", "get-sink-volume", sink))
    return int(m.group(1)) if m else None


def sink_node_id():
    global node_id
    try:
        nodes = json.loads(run("pw-dump") or "[]")
    except ValueError:
        return node_id
    for node in nodes:
        props = node.get("info", {}).get("props", {})
        if props.get("media.class") == "Audio/Sink" and CARD in props.get("node.name", ""):
            node_id = str(node["id"])
    return node_id


def soft_volume(nid):
    m = re.search(r"softVolumes.*?Float ([\d.]+)", run("pw-cli", "e", nid, "Props"), re.S)
    return float(m.group(1)) if m else None


def pin_software_volume():
    """Keep PipeWire's software gain at 1.0; the Katana's amplifier does the attenuation."""
    nid = node_id or sink_node_id()
    soft = soft_volume(nid) if nid else None
    if soft is None:
        nid = sink_node_id()
        soft = soft_volume(nid) if nid else None
    if soft is not None and abs(soft - 1.0) > 0.001:
        run("pw-cli", "s", nid, "Props", "{ softVolumes = [ 1.0, 1.0 ] }")


def nearest_bar(wanted):
    return min(SPEAKERS, key=lambda b: abs(b - wanted))


def pc_to_bar():
    """The PC volume changed: move the Katana's bar to match."""
    global level
    sink, card = katana_sink(), card_number()
    if not sink or not card:
        return
    with lock:
        pin_software_volume()
        percent = sink_percent(sink)
        if percent is None:
            return
        bar = nearest_bar(min(round(percent / 2), BAR_MAX))
        if bar != level:
            first, last = SPEAKERS[bar]
            run("amixer", "-c", card, "sset", "Speakers", str((first + last) // 2))
            level = bar
            save_state(bar=bar)


def on_volume_event():
    """PipeWire just applied the new volume in software: undo that now, move the hardware next."""
    with lock:
        pin_software_volume()
    global timer
    if timer:
        timer.cancel()
    timer = threading.Timer(SETTLE, pc_to_bar)
    timer.start()


def apply_frame(data):
    body = data[5:3 + data[2]]
    with lock:
        for i in range(0, len(body) - 5, 6):
            if body[i] >= 0x95:
                device_regs["%02x%02x" % (body[i], body[i + 1])] = round(struct.unpack("<f", body[i + 2:i + 6])[0], 3)


def take_snapshot():
    with lock:
        if current_profile is None:
            return
        number, regs = current_profile, dict(device_regs)
    update_state(lambda state: state.setdefault("profiles", {}).__setitem__(str(number), regs))
    emit(event="profileState", profile=number)


def schedule_snapshot():
    global snapshot_timer
    if snapshot_timer:
        snapshot_timer.cancel()
    snapshot_timer = threading.Timer(0.5, take_snapshot)
    snapshot_timer.start()


def follow(path, interface):
    """Read the Katana's HID reports; `5a 23 03 00 NN` is the bar, `5a 1a 02 02 NN` the profile."""
    global level, current_profile
    with open(path, "rb", buffering=0) as dev:
        while True:
            data = dev.read(64)
            if data[:4] == b"\x5a\x23\x03\x00" and data[4] <= BAR_MAX:
                bar = data[4]
                with lock:
                    changed = bar != level
                    level = bar
                if interface == 3:
                    sink = katana_sink()
                    if sink:
                        run("pactl", "set-sink-volume", sink, f"{bar * 2}%")
                        pin_software_volume()
                save_state(bar=bar)
                if changed:
                    emit(event="bar", level=bar, source="buttons" if interface == 3 else "pc")
            elif data[:4] == b"\x5a\x1a\x02\x02":
                profile = data[4] & 0x7F
                if profile < PROFILES:
                    with lock:
                        current_profile = profile
                    save_state(profile=profile)
                    emit(event="profile", profile=profile)
            elif data[:2] == b"\x5a\x11" and interface == 4:
                apply_frame(data)
                schedule_snapshot()


def reader(interface):
    while True:
        try:
            path = hidraw_paths().get(interface)
            if path:
                follow(path, interface)
        except OSError:
            pass
        time.sleep(3)


def watch_volume():
    while True:
        proc = subprocess.Popen(["pactl", "subscribe"], stdout=subprocess.PIPE, text=True)
        for line in proc.stdout:
            if "'change' on sink" in line or "'new' on sink" in line:
                on_volume_event()
        time.sleep(3)


def clamp_db(value):
    try:
        return max(-EQ_LIMIT, min(EQ_LIMIT, float(value)))
    except (TypeError, ValueError):
        return 0.0


def write_registers(writes):
    """Write (register, float) pairs to the speaker's active profile.

    Returns None when every write was acknowledged (`5a 02 02 12 00`), else an error code."""
    path = hidraw_paths().get(4)
    if not path:
        return "not_found"
    try:
        fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
    except PermissionError:
        return "permission"
    try:
        for register, value in writes:
            frame = bytes([0x5A, 0x12, 0x07, 0x01, int(register[:2], 16), int(register[2:], 16)]) + struct.pack("<f", value)
            os.write(fd, frame.ljust(64, b"\0"))
            acknowledged = False
            end = time.time() + 0.6
            while time.time() < end and not acknowledged:
                if select.select([fd], [], [], 0.05)[0]:
                    data = os.read(fd, 64)
                    if data[:4] == b"\x5a\x02\x02\x12":
                        if data[4] != 0:
                            return "rejected"
                        acknowledged = True
            if not acknowledged:
                return "no_reply"
    finally:
        os.close(fd)
    return None


def hw_write(request):
    """Apply {"eqOn": bool, "preamp": dB, "bands": {index: dB}, "effects": {name: bool}}.

    Refused unless the Personal profile is the active one, so the factory profiles stay untouched.
    Bands go first and the on/off switch after them, so a preset never sounds half applied."""
    if load_state().get("profile") != PERSONAL_PROFILE:
        return {"ok": False, "error": "not_personal"}
    if not isinstance(request, dict):
        return {"ok": False, "error": "usage"}
    writes = []
    bands = request.get("bands")
    if isinstance(bands, dict):
        for key, value in bands.items():
            if str(key).isdigit() and int(key) < len(EQ_BANDS):
                writes.append((EQ_BANDS[int(key)], clamp_db(value)))
    if "preamp" in request:
        writes.append((EQ_PREAMP, clamp_db(request["preamp"])))
    if "eqOn" in request:
        writes.append((EQ_ON, 1.0 if request["eqOn"] is True else 0.0))
    effects = request.get("effects")
    if isinstance(effects, dict):
        for name, on in effects.items():
            if name in WRITABLE_EFFECTS:
                writes.append((WRITABLE_EFFECTS[name], 2.0 if on is True else 0.0))
    error = write_registers(writes)
    return {"ok": True} if error is None else {"ok": False, "error": error}


def daemon():
    runtime = os.environ.get("XDG_RUNTIME_DIR") or STATE_DIR
    os.makedirs(runtime, exist_ok=True)
    guard = open(os.path.join(runtime, "katana-omarchy.lock"), "w")
    try:
        fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        emit(event="busy")
        return
    global current_profile
    current_profile = load_state().get("profile")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    for interface in (3, 4):
        threading.Thread(target=reader, args=(interface,), daemon=True).start()
    time.sleep(1)
    pc_to_bar()
    emit(event="ready")
    watch_volume()


def select_profile(number):
    path = hidraw_paths().get(4)
    if not path:
        return {"ok": False, "error": "not_found"}
    try:
        fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
    except PermissionError:
        return {"ok": False, "error": "permission"}
    try:
        end = time.time() + 0.3
        while time.time() < end:
            if select.select([fd], [], [], 0.05)[0]:
                os.read(fd, 64)
        os.write(fd, bytes([0x5A, 0x1A, 0x03, 0x00, 0x02, number]).ljust(64, b"\0"))
        end = time.time() + 1.5
        while time.time() < end:
            if select.select([fd], [], [], 0.05)[0]:
                data = os.read(fd, 64)
                if data[:4] == b"\x5a\x1a\x02\x02" and data[4] & 0x7F == number:
                    save_state(profile=number)
                    return {"ok": True, "profile": number}
    finally:
        os.close(fd)
    return {"ok": False, "error": "no_reply"}


def profile_summary(regs):
    def value(register):
        return regs.get(register)
    return {
        "eqOn": None if value(EQ_ON) is None else value(EQ_ON) >= 0.5,
        "preamp": value(EQ_PREAMP),
        "bands": [value(r) for r in EQ_BANDS],
        "effects": {name: value(r) for name, r in EFFECTS.items()},
    }


def learn():
    """Select every profile twice, so each one's changes are seen after the previous profile's."""
    start = load_state().get("profile")
    for _ in range(2):
        for number in range(PROFILES):
            select_profile(number)
            time.sleep(0.9)
    restored = start if isinstance(start, int) and 0 <= start < PROFILES else 0
    select_profile(restored)
    return {"ok": True, "restored": restored}


def status():
    paths = hidraw_paths()
    state = load_state()
    sink = katana_sink()
    profiles = {n: profile_summary(regs) for n, regs in state.get("profiles", {}).items()}
    return {
        "deviceProfiles": profiles,
        "learned": len(profiles),
        "ok": True,
        "present": bool(paths),
        "readable": bool(paths) and all(os.access(p, os.R_OK | os.W_OK) for p in paths.values()),
        "bar": state.get("bar"),
        "profile": state.get("profile"),
        "percent": sink_percent(sink) if sink else None,
    }


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    try:
        if command == "daemon":
            daemon()
        elif command == "status":
            print(json.dumps(status()))
        elif command == "hw" and len(argv) > 2:
            try:
                request = json.loads(argv[2])
            except ValueError:
                request = None
            print(json.dumps(hw_write(request)))
        elif command == "profile" and len(argv) > 2 and argv[2].isdigit() and int(argv[2]) < PROFILES:
            print(json.dumps(select_profile(int(argv[2]))))
        elif command == "learn":
            print(json.dumps(learn()))
        elif command == "volume" and len(argv) > 2 and argv[2].isdigit():
            sink = katana_sink()
            if sink:
                run("pactl", "set-sink-volume", sink, f"{min(int(argv[2]), BAR_MAX) * 2}%")
            print(json.dumps({"ok": bool(sink)}))
        else:
            print(json.dumps({"ok": False, "error": "usage"}))
            return 2
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

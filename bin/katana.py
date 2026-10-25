#!/usr/bin/env python3
"""Helper for the Katana Omarchy plugin: Creative Sound BlasterX Katana (USB 041e:3247).

    katana.py status          JSON report of what the plugin shows
    katana.py profile N       select stored profile N (0..5)
    katana.py volume N        set the PC volume to bar level N (0..50, 2% each)
    katana.py eq              JSON with the equalizer settings
    katana.py eq set JSON     merge fields (on, preset, preamp, bands, custom) into the equalizer settings
    katana.py daemon          keep PC volume and the Katana's bar in sync and run the equalizer;
                              one JSON event per line

The Katana reports its bar (0..50) as `5a 23 03 00 <level>` over HID. Buttons are reported
on interface 3, changes made from the PC on interface 4. The bar follows the ALSA
"Speakers" control (0..128) through a non-linear curve, measured with a sweep (SPEAKERS).
PipeWire's own software gain is pinned to 1.0 so loudness is applied once, by the Katana.

The equalizer is a PipeWire filter-chain (preamp + 10 bands) that the daemon runs as a child
`pipewire -c` process in front of the Katana and retunes live; settings live in eq.json.
"""
import ctypes
import fcntl
import glob
import json
import os
import re
import select
import signal
import subprocess
import sys
import threading
import time

VID_PID = "041E:3247"
CARD = "Katana"
BAR_MAX = 50
SETTLE = 0.05
PROFILES = 6

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

CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "katana-omarchy")
EQ_FILE = os.path.join(CONFIG_DIR, "eq.json")
EQ_FREQS = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
EQ_NODE = "katana_eq_input"
EQ_LIMIT = 12.0

STATE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "katana-omarchy")
STATE = os.path.join(STATE_DIR, "state.json")

lock = threading.Lock()
timer = None
level = None
node_id = None


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


def save_state(**values):
    state = load_state()
    state.update(values)
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE, "w") as f:
        json.dump(state, f)


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


def follow(path, interface):
    """Read the Katana's HID reports; `5a 23 03 00 NN` is the bar, `5a 1a 02 02 NN` the profile."""
    global level
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
                    save_state(profile=profile)
                    emit(event="profile", profile=profile)


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


def clean_curve(curve):
    curve = curve if isinstance(curve, dict) else {}
    bands = curve.get("bands") if isinstance(curve.get("bands"), list) else []
    bands = [clamp_db(b) for b in bands[:len(EQ_FREQS)]]
    return {"preamp": clamp_db(curve.get("preamp")), "bands": bands + [0.0] * (len(EQ_FREQS) - len(bands))}


def load_eq():
    try:
        with open(EQ_FILE) as f:
            raw = json.load(f)
    except (OSError, ValueError):
        raw = {}
    raw = raw if isinstance(raw, dict) else {}
    cfg = clean_curve(raw)
    cfg["on"] = raw.get("on") is True
    cfg["preset"] = raw.get("preset") if isinstance(raw.get("preset"), str) else "flat"
    cfg["custom"] = clean_curve(raw.get("custom"))
    return cfg


def save_eq(changes):
    """Merge `changes` into eq.json and write it atomically; the daemon notices and applies it."""
    cfg = load_eq()
    if isinstance(changes, dict):
        if "on" in changes:
            cfg["on"] = changes["on"] is True
        if isinstance(changes.get("preset"), str):
            cfg["preset"] = changes["preset"][:40]
        if "preamp" in changes or "bands" in changes:
            cfg.update(clean_curve({"preamp": changes.get("preamp", cfg["preamp"]), "bands": changes.get("bands", cfg["bands"])}))
        if "custom" in changes:
            cfg["custom"] = clean_curve(changes["custom"])
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = EQ_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f)
    os.replace(tmp, EQ_FILE)
    return cfg


def eq_config(sink, cfg):
    """A `pipewire -c` config with a stereo sink (preamp, then one biquad per band) feeding `sink`."""
    nodes = ["{ type = builtin name = pre label = linear control = { Mult = %.5f Add = 0.0 } }" % (10 ** (cfg["preamp"] / 20))]
    for i, (freq, gain) in enumerate(zip(EQ_FREQS, cfg["bands"]), 1):
        label = "bq_lowshelf" if i == 1 else ("bq_highshelf" if i == len(EQ_FREQS) else "bq_peaking")
        q = 0.707 if label != "bq_peaking" else 1.41
        nodes.append("{ type = builtin name = b%d label = %s control = { Freq = %d Q = %.3f Gain = %.2f } }" % (i, label, freq, q, gain))
    links = ['{ output = "pre:Out" input = "b1:In" }']
    links += ['{ output = "b%d:Out" input = "b%d:In" }' % (i, i + 1) for i in range(1, len(EQ_FREQS))]
    return """context.properties = { log.level = 2 }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert support.* = support/libspa-support }
context.modules = [
  { name = libpipewire-module-rt args = { nice.level = -11 } flags = [ ifexists nofail ] }
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-adapter }
  { name = libpipewire-module-filter-chain args = {
      node.description = "Katana EQ"
      media.name = "Katana EQ"
      filter.graph = {
        nodes = [ %s ]
        links = [ %s ]
        inputs = [ "pre:In" ]
        outputs = [ "b%d:Out" ]
      }
      audio.channels = 2
      audio.position = [ FL FR ]
      capture.props = { node.name = "%s" media.class = Audio/Sink node.description = "Katana EQ" }
      playback.props = { node.name = "katana_eq_input.playback" node.passive = true target.object = "%s" }
  } }
]
""" % (" ".join(nodes), " ".join(links), len(EQ_FREQS), EQ_NODE, sink)


def eq_node_id():
    try:
        nodes = json.loads(run("pw-dump") or "[]")
    except ValueError:
        return None
    for node in nodes:
        props = node.get("info", {}).get("props", {})
        if props.get("node.name") == EQ_NODE and props.get("media.class") == "Audio/Sink":
            return str(node["id"])


def eq_tune(nid, cfg):
    params = ['"pre:Mult"', "%.5f" % (10 ** (cfg["preamp"] / 20))]
    for i, gain in enumerate(cfg["bands"], 1):
        params += ['"b%d:Gain"' % i, "%.2f" % gain]
    run("pw-cli", "s", nid, "Props", "{ params = [ %s ] }" % " ".join(params))


def eq_route(to_eq):
    """Make the EQ sink the default output (or hand the default back to the Katana)."""
    sink, default = katana_sink(), run("pactl", "get-default-sink").strip()
    if to_eq and default == sink:
        run("pactl", "set-default-sink", EQ_NODE)
    elif not to_eq and default == EQ_NODE and sink:
        run("pactl", "set-default-sink", sink)


eq_child = None


def die_with_parent():
    """Child-side hook: have the kernel stop the filter if the daemon is killed (PR_SET_PDEATHSIG)."""
    ctypes.CDLL("libc.so.6").prctl(1, signal.SIGTERM)


def eq_conf_path():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR") or STATE_DIR, "katana-eq.conf")


def reap_stale_filters():
    """Stop filters left behind by an earlier daemon that was killed before it could clean up."""
    conf = eq_conf_path()
    for entry in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(entry, "rb") as f:
                args = f.read().split(b"\0")
        except OSError:
            continue
        if len(args) > 2 and os.path.basename(args[0].decode(errors="replace")) == "pipewire" and args[1] == b"-c" and args[2].decode(errors="replace") == conf:
            try:
                os.kill(int(entry.split("/")[2]), signal.SIGTERM)
            except OSError:
                pass


def eq_shutdown():
    """Hand the default output back to the Katana and stop the filter."""
    global eq_child
    if eq_child:
        eq_route(False)
        eq_child.terminate()
        eq_child = None


def eq_manager():
    global eq_child
    child, applied, routed = None, None, False
    conf = eq_conf_path()
    while True:
        cfg = load_eq()
        sink = katana_sink()
        want = cfg["on"] and sink is not None
        if child and child.poll() is not None:
            child, applied, routed = None, None, False
        if want and child is None:
            with open(conf, "w") as f:
                f.write(eq_config(sink, cfg))
            child = eq_child = subprocess.Popen(["pipewire", "-c", conf], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=die_with_parent)
            applied = None
        elif not want and child:
            eq_route(False)
            child.terminate()
            child.wait()
            child = eq_child = None
            applied, routed = None, False
        if child:
            nid = eq_node_id()
            if nid and (applied != (nid, cfg["preamp"], tuple(cfg["bands"]))):
                eq_tune(nid, cfg)
                applied = (nid, cfg["preamp"], tuple(cfg["bands"]))
            if nid and not routed:
                eq_route(True)
                routed = True
        time.sleep(0.25)


def daemon():
    runtime = os.environ.get("XDG_RUNTIME_DIR") or STATE_DIR
    os.makedirs(runtime, exist_ok=True)
    guard = open(os.path.join(runtime, "katana-omarchy.lock"), "w")
    try:
        fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        emit(event="busy")
        return
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    reap_stale_filters()
    for interface in (3, 4):
        threading.Thread(target=reader, args=(interface,), daemon=True).start()
    threading.Thread(target=eq_manager, daemon=True).start()
    time.sleep(1)
    pc_to_bar()
    emit(event="ready")
    try:
        watch_volume()
    finally:
        eq_shutdown()


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


def status():
    paths = hidraw_paths()
    state = load_state()
    sink = katana_sink()
    return {
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
        elif command == "eq":
            if len(argv) > 3 and argv[2] == "set":
                cfg = save_eq(json.loads(argv[3]))
            else:
                cfg = load_eq()
            print(json.dumps(dict(cfg, ok=True)))
        elif command == "profile" and len(argv) > 2 and argv[2].isdigit() and int(argv[2]) < PROFILES:
            print(json.dumps(select_profile(int(argv[2]))))
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

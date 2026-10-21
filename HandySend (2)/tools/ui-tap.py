# Drives the emulator's UI for protocol tests that need a human answer (accept/decline an
# offer). Finds a Button by its label in the layout dump and taps its centre.
#   python3 tools/ui-tap.py 接受 40
import json, subprocess, sys, time

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
TARGET = "127.0.0.1:5555"


def shell(*args):
    return subprocess.run([HDC, "-t", TARGET, "shell", *args], capture_output=True, text=True)


def dump():
    shell("uitest", "dumpLayout", "-p", "/data/local/tmp/d.json")
    raw = shell("cat", "/data/local/tmp/d.json").stdout
    return json.loads(raw[raw.index("{"):])


def find(node, label):
    a = node.get("attributes", {})
    if a.get("type") == "Button" and a.get("text") == label:
        return a.get("bounds", "")
    for c in node.get("children", []) or []:
        r = find(c, label)
        if r:
            return r
    return None


def wait(label, seconds):
    end = time.time() + seconds
    while time.time() < end:
        bounds = find(dump(), label)
        if bounds:
            x1, y1, x2, y2 = [int(v) for v in bounds.replace("][", ",").strip("[]").split(",")]
            shell("uitest", "uiInput", "click", str((x1 + x2) // 2), str((y1 + y2) // 2))
            print(f"tapped {label} at {bounds}", flush=True)
            return True
        time.sleep(0.4)
    print(f"never saw {label}", flush=True)
    return False


if __name__ == "__main__":
    ok = wait(sys.argv[1], int(sys.argv[2]))
    sys.exit(0 if ok else 1)

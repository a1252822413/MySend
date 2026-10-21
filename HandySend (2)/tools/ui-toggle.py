# Taps the n-th Toggle (switch) in the emulator's layout dump, counting from 0.
#   python3 tools/ui-toggle.py 1
import json, subprocess, sys

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
TARGET = "127.0.0.1:5555"


def shell(*args):
    return subprocess.run([HDC, "-t", TARGET, "shell", *args], capture_output=True, text=True)


def dump():
    shell("uitest", "dumpLayout", "-p", "/data/local/tmp/d.json")
    raw = shell("cat", "/data/local/tmp/d.json").stdout
    return json.loads(raw[raw.index("{"):])


def toggles(node, acc):
    a = node.get("attributes", {})
    if a.get("type") in ("Toggle", "Switch"):
        acc.append(a.get("bounds", ""))
    for c in node.get("children", []) or []:
        toggles(c, acc)
    return acc


found = toggles(dump(), [])
index = int(sys.argv[1])
if index >= len(found):
    sys.exit(f"only {len(found)} toggles: {found}")
x1, y1, x2, y2 = [int(v) for v in found[index].replace("][", ",").strip("[]").split(",")]
shell("uitest", "uiInput", "click", str((x1 + x2) // 2), str((y1 + y2) // 2))
print(f"tapped toggle {index} at {found[index]}")

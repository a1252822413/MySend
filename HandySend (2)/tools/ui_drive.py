# Drives the emulator UI by visible text, whatever component type carries it.
# The system file picker renders its rows as Text/Row nodes rather than Buttons, so ui-tap.py
# (Button-only) cannot reach them.
#   python3 tools/ui_drive.py tap 我的手机
#   python3 tools/ui_drive.py input 376 1204 http://10.0.2.2:53318
#   python3 tools/ui_drive.py dump [--grep Download]
import json, subprocess, sys, time

HDC = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
TARGET = "127.0.0.1:5555"


def shell(*args):
    return subprocess.run([HDC, "-t", TARGET, "shell", *args], capture_output=True, text=True)


def tree():
    shell("uitest", "dumpLayout", "-p", "/data/local/tmp/drive.json")
    raw = shell("cat", "/data/local/tmp/drive.json").stdout
    return json.loads(raw[raw.index("{"):])


def boxes(node, label):
    out = []
    a = node.get("attributes", {})
    text = a.get("text", "") or a.get("description", "")
    if label in text:
        b = a.get("bounds", "")
        if b:
            out.append((a.get("type", ""), b))
    for c in node.get("children", []) or []:
        out.extend(boxes(c, label))
    return out


def center(bounds):
    x1, y1, x2, y2 = [int(v) for v in bounds.replace("][", ",").strip("[]").split(",")]
    return (x1 + x2) // 2, (y1 + y2) // 2


def click(x, y):
    shell("uitest", "uiInput", "click", str(x), str(y))


BUNDLE = "io.github.localsendnext.app"


def foreground():
    """Brings our app to front; the emulator also runs Telegram X and it keeps stealing focus."""
    for _ in range(4):
        if boxes(tree(), 'LocalSend'):
            return True
        shell("aa", "start", "-a", "EntryAbility", "-b", BUNDLE)
        time.sleep(4)
    return False


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "tap":
        found = boxes(tree(), sys.argv[2])
        if not found:
            print(f"FAIL not found: {sys.argv[2]}")
            sys.exit(1)
        t, b = found[0]
        x, y = center(b)
        click(x, y)
        print(f"tapped {t} {b} for {sys.argv[2]}")
    elif cmd == "xy":
        click(int(sys.argv[2]), int(sys.argv[3]))
        print(f"tapped {sys.argv[2]},{sys.argv[3]}")
    elif cmd == "input":
        click(int(sys.argv[2]), int(sys.argv[3]))
        shell("uitest", "uiInput", "inputText", sys.argv[2], sys.argv[3], sys.argv[4])
        print(f"typed into {sys.argv[2]},{sys.argv[3]}")
    elif cmd == "list":
        for t, b in boxes(tree(), sys.argv[2]):
            print(f"{t} | {b}")
    elif cmd == "dump":
        needle = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "--grep" else None
        raw = shell("uitest", "dumpLayout", "-p", "/data/local/tmp/drive.json").stdout
        out = shell("cat", "/data/local/tmp/drive.json").stdout
        d = json.loads(out[out.index("{"):])

        def walk(n, i=0):
            a = n.get("attributes", {})
            text = (a.get("text", "") or a.get("description", "")).replace("\n", "\\n")[:70]
            if text:
                line = f'{"  " * i}{a.get("type", "")} | {text} | {a.get("bounds", "")}'
                if needle is None or needle in line:
                    print(line)
            for c in n.get("children", []) or []:
                walk(c, i + 1)
        walk(d)
    else:
        print("usage: tap|xy|input|list|dump")
        sys.exit(1)

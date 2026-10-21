# Drives the system document picker down to /Download and selects one file by name.
#
# The phone's picker returns one uri per invocation and reopens wherever it was last left, so the
# navigation is re-derived from the layout every run instead of replaying fixed coordinates.
#   python3 tools/ui-pick.py a.txt
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_drive import boxes, center, click, foreground, tree

name = sys.argv[1]
if not foreground():
    print("LocalSend is not in the foreground")
    sys.exit(1)

openers = [(t, b) for t, b in boxes(tree(), '选择文档') if t == 'Button']
if not openers:
    print("选择文档 is not on screen")
    sys.exit(1)
click(*center(openers[0][1]))

deadline = time.time() + 60
while time.time() < deadline:
    time.sleep(2)
    nodes = tree()
    tiles = [(t, b) for t, b in boxes(nodes, name) if t == 'Text']
    if tiles:
        click(*center(tiles[0][1]))
        print(f"picked {name}")
        sys.exit(0)
    # Not visible yet: take the one step that moves towards Download.
    for step in ('Download', '我的手机', '浏览'):
        hop = [(t, b) for t, b in boxes(nodes, step) if t in ('Text', 'Row', 'Button')]
        if hop:
            click(*center(hop[0][1]))
            break
    else:
        print("picker shows nothing navigable")
        sys.exit(1)
print(f"timeout waiting for {name}")
sys.exit(1)

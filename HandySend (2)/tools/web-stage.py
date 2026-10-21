#!/usr/bin/env python3
"""Stages the web-share test on the emulator: picks the two pushed sample files and starts the share.

The picker only remembers its folder within one launch and an unattended emulator likes to show
other apps, so every step here re-checks what is actually on screen before it taps: by label where
the picker renders one, by the recorded bounds of this emulator's layout where it does not.
"""
import json
import subprocess
import sys
import time

HERE = '/Users/mbjpeng-yu01/harmonyProjects/localSend/LocalSend-HarmonyNext'
HDC = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc'
TARGET = '127.0.0.1:5555'
BUNDLE = 'io.github.localsendnext.app'

# Bounds recorded from the Pura 90 Pro document picker.
BROWSE = (764, 290)
PHONE = (628, 897)
DOCUMENTS = (240, 1052)
FILE_A = (627, 1250)
FILE_B = (240, 1250)


def hdc(*args):
    return subprocess.run([HDC, '-t', TARGET, 'shell', *args],
                          capture_output=True, text=True).stdout


def tree():
    hdc('uitest', 'dumpLayout', '-p', '/data/local/tmp/stage.json')
    raw = hdc('cat', '/data/local/tmp/stage.json')
    return json.loads(raw[raw.index('{'):])


def texts(node, out):
    a = node.get('attributes', {})
    text = a.get('text') or a.get('description') or ''
    if text:
        out.append(text)
    for child in node.get('children', []) or []:
        texts(child, out)
    return out


def visible(label):
    return any(label in text for text in texts(tree(), []))


def click(x, y):
    hdc('uitest', 'uiInput', 'click', str(x), str(y))


def tap_label(label):
    """Clicks the first node whose text or description contains `label`."""
    def find(node):
        a = node.get('attributes', {})
        text = a.get('text') or a.get('description') or ''
        if label in text:
            bounds = a.get('bounds', '')
            if bounds:
                return bounds
        for child in node.get('children', []) or []:
            hit = find(child)
            if hit:
                return hit
        return None

    bounds = find(tree())
    if bounds is None:
        return False
    x1, y1, x2, y2 = [int(v) for v in bounds.replace('][', ',').strip('[]').split(',')]
    click((x1 + x2) // 2, (y1 + y2) // 2)
    return True


def foreground(tries=6):
    for _ in range(tries):
        if visible('选择文档'):
            return True
        hdc('aa', 'start', '-a', 'EntryAbility', '-b', BUNDLE)
        time.sleep(4)
    return False


def walk_to_documents():
    if not tap_label('选择文档'):
        return False
    time.sleep(6)
    for coordinate in (BROWSE, PHONE, DOCUMENTS):
        click(coordinate[0], coordinate[1])
        time.sleep(2)
    return visible('lsweb')


def main():
    if not foreground():
        print('FAIL: our app never came to the front', file=sys.stderr)
        return 1

    for coordinate, count in ((FILE_A, 1), (FILE_B, 2)):
        if not walk_to_documents():
            print('FAIL: the Documents folder is not showing', file=sys.stderr)
            return 1
        click(coordinate[0], coordinate[1])
        time.sleep(3)
        if not visible(f'已选 {count} 个文件'):
            print(f'FAIL: the app did not record pick {count}', file=sys.stderr)
            return 1

    if not tap_label('开始网页传'):
        print('FAIL: the share button was not found', file=sys.stderr)
        return 1
    time.sleep(3)
    if not visible('停止网页传'):
        print('FAIL: the share did not start', file=sys.stderr)
        return 1
    print('staged: 2 files shared')
    return 0


if __name__ == '__main__':
    sys.exit(main())

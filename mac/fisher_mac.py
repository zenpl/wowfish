#!/usr/bin/env python3
"""WoW 钓鱼助手（听声版）— macOS

原理同 Linux 版：按键抛竿 -> 听系统声音里的咬钩水花声 -> 按"与目标互动"键收竿。
只在魔兽是前台应用时才发按键。安装和权限设置见同目录 README.md。

  python3 fisher_mac.py --list-devices   列出音频输入设备
  python3 fisher_mac.py --calibrate      只看声音电平
  python3 fisher_mac.py                  开始（Ctrl+C 停止）
"""
import argparse
import collections
import queue
import random
import sys
import time

import numpy as np
import sounddevice as sd
import Quartz
from AppKit import NSWorkspace
from Foundation import NSDate, NSRunLoop

RATE = 16000
CHUNK = 800  # 50ms
APP_HINTS = ("world of warcraft", "wow", "魔兽世界", "魔獸世界")

# macOS 虚拟键码（ANSI 键盘）
KEYCODES = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25,
    "7": 26, "minus": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "grave": 50,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
    "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
}


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------- 声音 ----------
def find_device(name):
    """按名字找输入设备；默认找 BlackHole。"""
    want = (name or "blackhole").lower()
    for i, dev in enumerate(sd.query_devices()):
        if dev["max_input_channels"] > 0 and want in dev["name"].lower():
            return i, dev["name"]
    sys.exit(f"找不到名字含 '{want}' 的音频输入设备。先装 BlackHole 并按 README 设置，"
             f"或用 --list-devices 查看后用 --device 指定。")


class AudioMeter:
    """后台持续采集回环设备，把每 50ms 的 RMS（按 16bit 量纲）放进队列。"""

    def __init__(self, device):
        self.q = queue.Queue()
        self.stream = sd.InputStream(device=device, channels=1, samplerate=RATE,
                                     blocksize=CHUNK, dtype="int16", callback=self._cb)
        self.stream.start()

    def _cb(self, indata, frames, t, status):
        a = indata[:, 0].astype(np.float32)
        self.q.put(float(np.sqrt(np.mean(a * a))))

    def flush(self):
        while not self.q.empty():
            self.q.get_nowait()

    def read(self, timeout=1.0):
        try:
            return self.q.get(timeout=timeout)
        except queue.Empty:
            sys.exit("采集不到声音数据，检查音频设备设置")

    def close(self):
        self.stream.stop()
        self.stream.close()


# ---------- 键盘 / 前台应用 ----------
def front_app():
    # 没有事件循环时 NSWorkspace 的前台应用是缓存值，不会更新；先泵一下 run loop
    NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.02))
    app =NSWorkspace.sharedWorkspace().frontmostApplication()
    return (app.localizedName() or "") if app else ""


def wow_focused():
    name = front_app().strip().lower()
    return name in APP_HINTS or "warcraft" in name


def tap(key):
    code = KEYCODES.get(key.lower())
    if code is None:
        sys.exit(f"不认识的按键名: {key}（支持字母、数字、F1-F12、equal、minus、grave）")
    for down in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
        if down:
            time.sleep(random.uniform(0.05, 0.13))


# ---------- 主流程 ----------
def calibrate(meter):
    log("校准模式：在游戏里手动钓几竿，观察水花声出现时的电平。Ctrl+C 退出。")
    hist = collections.deque(maxlen=60)
    n = 0
    while True:
        v = meter.read()
        hist.append(v)
        n += 1
        if n % 4 == 0:
            floor = float(np.median(hist))
            print(f"rms={v:7.0f}  底噪={floor:7.0f}  倍数={v / max(floor, 1):5.1f}  "
                  f"{'#' * min(60, int(v / 40))}", flush=True)


def wait_focus():
    if wow_focused():
        return
    log(f"魔兽不在前台，暂停中……（当前前台应用: {front_app()!r}）")
    while not wow_focused():
        time.sleep(0.5)
    time.sleep(random.uniform(1.0, 2.0))
    log("继续")


def wait_bite(meter, args):
    """抛竿后等水花声。True=咬钩, False=超时/失焦。"""
    meter.flush()
    settle_until = time.time() + args.settle
    floor_buf = []
    while time.time() < settle_until:
        v = meter.read()
        if time.time() > settle_until - 1.0:
            floor_buf.append(v)
    floor = float(np.median(floor_buf)) if floor_buf else 0.0
    recent = collections.deque([floor] * 40, maxlen=40)
    deadline = time.time() + args.timeout - args.settle
    hot = 0
    sec_max, sec_end, trace = 0.0, time.time() + 1, []
    while time.time() < deadline:
        v = meter.read()
        sec_max = max(sec_max, v)
        if time.time() > sec_end:
            trace.append(int(sec_max))
            sec_max, sec_end = 0.0, time.time() + 1
        base = float(np.median(recent))
        thresh = min(args.max_rms, max(args.min_rms, base * args.ratio))
        if v > thresh:
            hot += 1
            if hot >= args.hits:
                log(f"  咬钩！rms={v:.0f} 阈值={thresh:.0f} 底噪={base:.0f}")
                return True
        else:
            hot = 0
            recent.append(v)
        if not wow_focused():
            return False
    if args.debug:
        log(f"  每秒峰值: {trace} 底噪={float(np.median(recent)):.0f}")
    return False


def main():
    ap = argparse.ArgumentParser(description="WoW 钓鱼助手（听声版）macOS")
    ap.add_argument("--cast-key", default="0", help="钓鱼技能的按键 (默认 0)")
    ap.add_argument("--interact-key", default="F10", help="'与目标互动'的按键 (默认 F10)")
    ap.add_argument("--device", default=None, help="音频输入设备名的一部分 (默认 BlackHole)")
    ap.add_argument("--list-devices", action="store_true", help="列出音频设备后退出")
    ap.add_argument("--ratio", type=float, default=3.0, help="声音超过底噪多少倍算咬钩 (默认 3)")
    ap.add_argument("--min-rms", type=float, default=700, help="咬钩阈值下限 (默认 700)")
    ap.add_argument("--max-rms", type=float, default=1800, help="咬钩阈值上限 (默认 1800)")
    ap.add_argument("--hits", type=int, default=2, help="连续多少个 50ms 片段超阈值才触发 (默认 2)")
    ap.add_argument("--settle", type=float, default=2.5, help="抛竿后忽略声音的秒数 (默认 2.5)")
    ap.add_argument("--timeout", type=float, default=30, help="一竿最长等待秒数 (默认 30)")
    ap.add_argument("--minutes", type=float, default=0, help="运行多少分钟后自动停止，0=一直跑 (默认 0)")
    ap.add_argument("--max-misses", type=int, default=0, help="连续多少竿没咬钩就停止，0=永不停 (默认 0)")
    ap.add_argument("--calibrate", action="store_true", help="只显示声音电平，不按键")
    ap.add_argument("--debug", action="store_true", help="超时时打印每秒声音峰值")
    args = ap.parse_args()

    if args.list_devices:
        print(sd.query_devices())
        return
    dev, name = find_device(args.device)
    log(f"监听音频设备: {name}")
    meter = AudioMeter(dev)
    try:
        if args.calibrate:
            calibrate(meter)
            return
        end = time.time() + args.minutes * 60 if args.minutes > 0 else float("inf")
        next_break = time.time() + random.uniform(8, 20) * 60
        casts = bites = misses = 0
        limit = f"运行 {args.minutes:.0f} 分钟" if args.minutes > 0 else "不限时"
        log(f"开始：抛竿={args.cast_key} 互动={args.interact_key}，{limit}。Ctrl+C 停止。")
        while time.time() < end:
            wait_focus()
            if time.time() > next_break:
                rest = random.uniform(20, 90)
                log(f"休息 {rest:.0f} 秒")
                time.sleep(rest)
                next_break = time.time() + random.uniform(8, 20) * 60
                continue
            casts += 1
            log(f"第 {casts} 竿（已钓 {bites}）")
            tap(args.cast_key)
            if wait_bite(meter, args):
                bites += 1
                misses = 0
                time.sleep(random.uniform(0.25, 0.75))
                tap(args.interact_key)
                time.sleep(random.uniform(1.2, 2.8))
            else:
                misses += 1
                log("  没等到咬钩，重抛")
                time.sleep(random.uniform(0.5, 1.5))
                if args.max_misses and misses >= args.max_misses:
                    log(f"连续 {args.max_misses} 竿没听到咬钩，停止。用 --calibrate 检查声音是否进了回环设备。")
                    break
        log(f"结束：共 {casts} 竿，咬钩 {bites} 次")
    except KeyboardInterrupt:
        print()
        log("已停止")
    finally:
        meter.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""WoW 钓鱼助手（听声版）

原理：按键抛竿 -> 监听系统声音输出里的"咬钩水花声" -> 按"与目标互动"键收竿。
不读游戏内存、不找图、不动鼠标，只在魔兽窗口处于前台时发按键。

游戏内准备（一次性）：
  1. 聊天框输入:  /console SoftTargetInteract 3
  2. 按键设置 -> 选中目标 -> "与目标互动" 绑定一个键（默认 F10）
  3. 钓鱼技能放到动作条并绑定一个键（默认 0）
  4. 打开自动拾取；声音设置里关掉音乐和环境音，音效开大
用法：
  ./run.sh --calibrate     先看声音电平，确认水花声能被明显区分
  ./run.sh                 开始钓鱼（切到游戏窗口后才会动作，Ctrl+C 停止）
"""
import argparse
import collections
import queue
import random
import subprocess
import sys
import threading
import time

import numpy as np
from Xlib import X, XK, display
from Xlib.ext import xtest

RATE = 16000
CHUNK = 800  # 50ms
TITLE_HINTS = ("world of warcraft", "魔兽世界", "魔獸世界")


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------- 声音 ----------
def default_sink_name():
    out = subprocess.run(["wpctl", "inspect", "@DEFAULT_AUDIO_SINK@"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "node.name" in line:
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit("找不到默认音频输出设备（wpctl inspect 失败）")


class AudioMeter:
    """后台持续读取声卡输出的回环录音，把每 50ms 的 RMS 放进队列。"""

    def __init__(self, sink):
        self.q = queue.Queue()
        self.proc = subprocess.Popen(
            ["pw-record", "-P", "{ stream.capture.sink = true }", "--target", sink,
             "--rate", str(RATE), "--channels", "1", "--format", "s16",
             "--latency", "20ms", "-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        need = CHUNK * 2
        while True:
            buf = self.proc.stdout.read(need)
            if len(buf) < need:
                self.q.put(None)
                return
            a = np.frombuffer(buf, dtype=np.int16).astype(np.float32)
            self.q.put(float(np.sqrt(np.mean(a * a))))

    def flush(self):
        while not self.q.empty():
            self.q.get_nowait()

    def read(self, timeout=1.0):
        try:
            v = self.q.get(timeout=timeout)
        except queue.Empty:
            sys.exit("录不到声音数据，pw-record 可能没在工作")
        if v is None:
            sys.exit("pw-record 退出了")
        return v

    def close(self):
        self.proc.terminate()


# ---------- 键盘 / 窗口 ----------
class Keyboard:
    def __init__(self):
        self.d = display.Display()
        self.root = self.d.screen().root
        self.a_active = self.d.intern_atom("_NET_ACTIVE_WINDOW")
        self.a_name = self.d.intern_atom("_NET_WM_NAME")

    def active_title(self):
        try:
            p = self.root.get_full_property(self.a_active, X.AnyPropertyType)
            if not p or not p.value[0]:
                return ""
            w = self.d.create_resource_object("window", p.value[0])
            n = w.get_full_property(self.a_name, X.AnyPropertyType)
            if n and n.value:
                v = n.value
                return v.decode("utf-8", "replace") if isinstance(v, bytes) else str(v)
            return w.get_wm_name() or ""
        except Exception:
            return ""

    def active_class(self):
        try:
            p = self.root.get_full_property(self.a_active, X.AnyPropertyType)
            w = self.d.create_resource_object("window", p.value[0])
            return " ".join(w.get_wm_class() or ()).lower()
        except Exception:
            return ""

    def wow_focused(self):
        # Wine 窗口的 WM_CLASS 是 exe 名（wow.exe）；标题需完全等于游戏名，
        # 避免浏览器标签页标题里带 "World of Warcraft" 时误发按键。
        if "wow" in self.active_class():
            return True
        return self.active_title().strip().lower() in TITLE_HINTS

    def tap(self, key):
        sym = XK.string_to_keysym(key)
        if sym == 0:
            sys.exit(f"不认识的按键名: {key}（用 X11 keysym 名，如 F9、1、e、equal）")
        code = self.d.keysym_to_keycode(sym)
        xtest.fake_input(self.d, X.KeyPress, code)
        self.d.sync()
        time.sleep(random.uniform(0.05, 0.13))
        xtest.fake_input(self.d, X.KeyRelease, code)
        self.d.sync()


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
            bar = "#" * min(60, int(v / 40))
            print(f"rms={v:7.0f}  底噪={floor:7.0f}  倍数={v / max(floor, 1):5.1f}  {bar}", flush=True)


def wait_focus(kb):
    if kb.wow_focused():
        return
    log(f"魔兽窗口不在前台，暂停中……（切回游戏自动继续）当前窗口: "
        f"{kb.active_title()!r} class={kb.active_class()!r}")
    while not kb.wow_focused():
        time.sleep(0.5)
    time.sleep(random.uniform(1.0, 2.0))
    log("继续")


def wait_bite(meter, kb, args):
    """抛竿后等待水花声。返回 True=咬钩, False=超时/失焦。"""
    meter.flush()
    # 抛竿音效 + 浮漂落水声过去之后，再采集底噪
    settle_until = time.time() + args.settle
    floor_buf = []
    while time.time() < settle_until:
        v = meter.read()
        if time.time() > settle_until - 1.0:
            floor_buf.append(v)
    floor = float(np.median(floor_buf)) if floor_buf else 0.0
    recent = collections.deque([floor] * 40, maxlen=40)  # 2 秒滚动底噪
    deadline = time.time() + args.timeout - args.settle
    hot = 0
    sec_max, sec_end, trace = 0.0, time.time() + 1, []
    while time.time() < deadline:
        v = meter.read()
        sec_max = max(sec_max, v)
        if time.time() > sec_end:
            trace.append(int(sec_max)); sec_max, sec_end = 0.0, time.time() + 1
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
        if not kb.wow_focused():
            return False
    if args.debug:
        log(f"  每秒峰值: {trace} 底噪={float(np.median(recent)):.0f}")
    return False


def main():
    ap = argparse.ArgumentParser(description="WoW 钓鱼助手（听声版）")
    ap.add_argument("--cast-key", default="0", help="钓鱼技能的按键 (默认 0)")
    ap.add_argument("--interact-key", default="F10", help="'与目标互动'的按键 (默认 F10)")
    ap.add_argument("--ratio", type=float, default=3.0, help="声音超过底噪多少倍算咬钩 (默认 3)")
    ap.add_argument("--min-rms", type=float, default=700, help="咬钩阈值下限 (默认 700)")
    ap.add_argument("--max-rms", type=float, default=1800, help="咬钩阈值上限，底噪再高也不超过它 (默认 1800)")
    ap.add_argument("--hits", type=int, default=2, help="连续多少个 50ms 片段超阈值才触发 (默认 2)")
    ap.add_argument("--settle", type=float, default=2.5, help="抛竿后忽略声音的秒数 (默认 2.5)")
    ap.add_argument("--timeout", type=float, default=30, help="一竿最长等待秒数 (默认 30)")
    ap.add_argument("--minutes", type=float, default=60, help="运行多少分钟后自动停止 (默认 60)")
    ap.add_argument("--lure-key", default=None, help="鱼饵宏的按键（可选）")
    ap.add_argument("--lure-every", type=float, default=10, help="每隔多少分钟上一次鱼饵 (默认 10)")
    ap.add_argument("--sink", default=None, help="音频输出设备 node.name（默认取系统默认输出）")
    ap.add_argument("--calibrate", action="store_true", help="只显示声音电平，不按键")
    ap.add_argument("--debug", action="store_true", help="超时时打印每秒声音峰值，便于调阈值")
    ap.add_argument("--dry-run", action="store_true", help="只检测不按键")
    args = ap.parse_args()

    sink = args.sink or default_sink_name()
    log(f"监听音频输出: {sink}")
    meter = AudioMeter(sink)
    try:
        if args.calibrate:
            calibrate(meter)
            return
        kb = Keyboard()
        tap = (lambda k: log(f"  [dry-run] 按 {k}")) if args.dry_run else kb.tap
        end = time.time() + args.minutes * 60
        next_lure = 0.0
        next_break = time.time() + random.uniform(8, 20) * 60
        casts = bites = misses = 0
        log(f"开始：抛竿={args.cast_key} 互动={args.interact_key}，运行 {args.minutes:.0f} 分钟。Ctrl+C 停止。")
        while time.time() < end:
            wait_focus(kb)
            if time.time() > next_break:
                rest = random.uniform(20, 90)
                log(f"休息 {rest:.0f} 秒")
                time.sleep(rest)
                next_break = time.time() + random.uniform(8, 20) * 60
                continue
            if args.lure_key and time.time() > next_lure:
                log("上鱼饵")
                tap(args.lure_key)
                time.sleep(random.uniform(5.5, 7.0))
                next_lure = time.time() + args.lure_every * 60
            casts += 1
            log(f"第 {casts} 竿（已钓 {bites}）")
            tap(args.cast_key)
            if wait_bite(meter, kb, args):
                bites += 1
                misses = 0
                time.sleep(random.uniform(0.25, 0.75))
                tap(args.interact_key)
                time.sleep(random.uniform(1.2, 2.8))
            else:
                misses += 1
                log("  没等到咬钩，重抛")
                time.sleep(random.uniform(0.5, 1.5))
                if misses >= 6:
                    log("连续 6 竿没听到咬钩，停止。请用 --calibrate 检查声音，"
                        "并确认按键/背包/站位没问题。")
                    break
        log(f"结束：共 {casts} 竿，咬钩 {bites} 次")
    except KeyboardInterrupt:
        print()
        log("已停止")
    finally:
        meter.close()


if __name__ == "__main__":
    main()

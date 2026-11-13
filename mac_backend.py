"""macOS 上的"看屏幕、按键、听声音"。接口和 Linux 版（fisher.py / vision.py 里的 X11 实现）一样，
agent.py 不用关心在哪个系统上跑。

注意：这一份没有在真机上测过（只有 mac/fisher_mac.py 那个独立钓鱼脚本在真机上跑过，这里的前台判断和音量阈值沿用了它的经验）。需要给运行它的终端三个权限（系统设置 → 隐私与安全性）：
  辅助功能（发按键）、屏幕录制（读游戏窗口左上角的信号块）、麦克风（听 BlackHole 回环的游戏声音）。
"""
import queue
import random
import sys
import time

import numpy as np
import Quartz
import sounddevice as sd
from AppKit import NSWorkspace
from Foundation import NSDate, NSRunLoop

_SRGB = Quartz.CGColorSpaceCreateWithName(Quartz.kCGColorSpaceSRGB)
RATE, CHUNK = 16000, 800           # 和 fisher.py 一致：50ms 一段
APP_HINTS = ("world of warcraft", "wow", "魔兽世界", "魔獸世界")

# ANSI 键盘的虚拟键码
KEYCODES = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25,
    "7": 26, "minus": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "grave": 50, "return": 36, "space": 49,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
    "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
}


def _is_wow(name):
    name = (name or "").strip().lower()
    return name in APP_HINTS or "warcraft" in name


# ---------- 窗口 / 截图 ----------
def win_rect():
    """游戏窗口在屏幕上的位置 (x, y, 宽, 高)，单位是"点"（不是 Retina 像素）。"""
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements, Quartz.kCGNullWindowID)
    best = None
    for w in wins or []:
        if w.get("kCGWindowLayer", 0) != 0 or not _is_wow(w.get("kCGWindowOwnerName")):
            continue
        b = w["kCGWindowBounds"]
        if not best or b["Width"] * b["Height"] > best["Width"] * best["Height"]:
            best = b                                   # 同一个程序可能有几个窗口，取最大的那个
    if not best:
        raise SystemExit("没找到魔兽窗口")
    return int(best["X"]), int(best["Y"]), int(best["Width"]), int(best["Height"])


def grab(x, y, w, h):
    """截屏幕上的一块，返回 (h, w, 3) 的 RGB 数组。按"点"取样，所以 Retina 屏上色块大小和 Linux 上一样。"""
    img = Quartz.CGWindowListCreateImage(Quartz.CGRectMake(x, y, w, h), Quartz.kCGWindowListOptionOnScreenOnly,
                                         Quartz.kCGNullWindowID, Quartz.kCGWindowImageNominalResolution)
    if img is None:
        raise RuntimeError("截不到屏幕：检查'屏幕录制'权限")
    width, height = Quartz.CGImageGetWidth(img), Quartz.CGImageGetHeight(img)
    # 截到的像素是显示器色彩空间里的值（P3 屏上 sRGB 纯绿会变成 117,251,76），信号色全对不上。
    # 画进一个 sRGB 位图让系统换算回去，拿到的才是插件设的颜色（真机上踩过）。
    ctx = Quartz.CGBitmapContextCreate(None, width, height, 8, width * 4, _SRGB,
                                       Quartz.kCGImageAlphaNoneSkipLast | Quartz.kCGBitmapByteOrder32Big)
    Quartz.CGContextSetInterpolationQuality(ctx, Quartz.kCGInterpolationNone)
    Quartz.CGContextDrawImage(ctx, Quartz.CGRectMake(0, 0, width, height), img)
    out = Quartz.CGBitmapContextCreateImage(ctx)
    row = Quartz.CGImageGetBytesPerRow(out)
    data = Quartz.CGDataProviderCopyData(Quartz.CGImageGetDataProvider(out))
    a = np.frombuffer(data, dtype=np.uint8).reshape(height, row // 4, 4)[:, :width]
    return a[:, :, :3].astype(np.int16)                # RGBX -> RGB


# ---------- 键盘 / 前台 ----------
class Keyboard:
    def wow_focused(self):
        # 没有事件循环时 NSWorkspace 的前台应用是缓存值，不会更新；先泵一下 run loop（独立版钓鱼脚本在真机上踩过这个坑）
        NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.02))
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        return _is_wow(app.localizedName() if app else "")

    def tap(self, key):
        code = KEYCODES.get(str(key).lower())
        if code is None:
            sys.exit(f"不认识的按键名: {key}（支持字母、数字、F1-F12、equal、minus、grave、return、space）")
        for down in (True, False):
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateKeyboardEvent(None, code, down))
            if down:
                time.sleep(random.uniform(0.05, 0.13))


# ---------- 声音 ----------
def default_sink_name():
    return "blackhole"                                  # 回环虚拟声卡；装法见 mac/README.md


class AudioMeter:
    """持续采集回环设备，把每 50ms 的 RMS（16bit 量纲）放进队列。"""

    def __init__(self, device_hint):
        want = (device_hint or "blackhole").lower()
        dev = next((i for i, d in enumerate(sd.query_devices())
                    if d["max_input_channels"] > 0 and want in d["name"].lower()), None)
        if dev is None:
            sys.exit(f"找不到名字含 '{want}' 的音频输入设备。先装 BlackHole 并按 mac/README.md 设置多输出设备。")
        self.q = queue.Queue()
        self.stream = sd.InputStream(device=dev, channels=1, samplerate=RATE, blocksize=CHUNK, dtype="int16", callback=self._cb)
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
            sys.exit("采集不到声音数据，检查音频设备和麦克风权限")

    def close(self):
        self.stream.stop()
        self.stream.close()

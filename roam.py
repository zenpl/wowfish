#!/usr/bin/env python3
"""沿岸边走边钓（读小地图版）

前提：
  - 小地图设为"随角色旋转"（/console rotateMinimap 1），并放大到最大（小键盘 + 按几次），运行中别改缩放
  - 角色站在岸边、面朝水（就是平时钓鱼的站位）时启动
  - 默认按键：W 前进，A/D 键盘转向
流程：记下当前"离水距离"和水的颜色 -> 钓几竿 -> 转身沿岸走一段 -> 面向水 -> 再钓……
走不动（撞墙/到头）时自动掉头往回走。窗口失焦立刻松开所有按键并暂停。
"""
import argparse
import math
import random
import sys
import time

import numpy as np
from Xlib import X, XK
from Xlib.ext import xtest

import fisher
import vision

R = vision.MM_R
YY, XX = np.mgrid[-R:R + 1, -R:R + 1]
FWD = -YY          # 前方为正
LAT = XX           # 右侧为正
DIST = np.hypot(XX, YY)
log = fisher.log
ARROW = 7          # 中心的角色箭头会盖住小地图，这个半径内的像素不可信
RING = (DIST > ARROW) & (DIST <= ARROW + 3)


class Keys:
    def __init__(self, kb):
        self.kb, self.d, self.down = kb, kb.d, set()

    def _code(self, k):
        return self.d.keysym_to_keycode(XK.string_to_keysym(k))

    def press(self, k):
        if k not in self.down:
            xtest.fake_input(self.d, X.KeyPress, self._code(k)); self.d.sync(); self.down.add(k)

    def release(self, k):
        if k in self.down:
            xtest.fake_input(self.d, X.KeyRelease, self._code(k)); self.d.sync(); self.down.discard(k)

    def release_all(self):
        for k in list(self.down):
            self.release(k)

    def pulse(self, k, sec):
        self.press(k); time.sleep(sec); self.release(k)


class Shore:
    """从小地图里量水的位置。"""

    def __init__(self, color, tol):
        self.color, self.tol = color, tol

    def mask(self):
        self.img = vision.minimap()
        return vision.water_mask(self.img, self.color, self.tol)

    @staticmethod
    def nearest(m, maxr=45):
        """最近水域的 (距离, 角度)。角度：0=正前，+90=正右，单位度。"""
        sel = m & (DIST <= maxr) & (DIST > ARROW)
        if sel.sum() < 4:
            return None, None
        dmin = DIST[sel].min()
        near = sel & (DIST <= dmin + 3)
        ang = math.degrees(math.atan2(LAT[near].mean(), FWD[near].mean()))
        return float(dmin), ang

    @staticmethod
    def in_water(m):
        """箭头周围一圈大部分是水 -> 人已经在水里了。"""
        return m[RING].mean() > 0.6

    @staticmethod
    def lateral(m, side, f0, f1, maxl=45):
        """在前向 [f0,f1] 这条带里，水离我的侧向距离（side=+1 右，-1 左）。"""
        sel = m & (FWD >= f0) & (FWD <= f1) & (LAT * side > 0) & (LAT * side <= maxl) & (DIST > ARROW)
        return float((LAT[sel] * side).min()) if sel.sum() >= 2 else None

    @staticmethod
    def front(m, half=4, maxf=30):
        sel = m & (np.abs(LAT) <= half) & (FWD > ARROW) & (FWD <= maxf)
        return float(FWD[sel].min()) if sel.sum() >= 2 else None


def learn_water(tol):
    """站位面朝水：取正前方一小块的中位色当作水的颜色。"""
    img = vision.minimap()
    best = None
    for dy in range(5, 26):  # 往前找一块颜色均匀的区域
        patch = img[R - dy - 2:R - dy + 3, R - 2:R + 3].reshape(-1, 3)
        spread = patch.std(0).sum()
        if best is None or spread < best[0]:
            best = (spread, np.median(patch, 0))
    color = best[1]
    n = vision.water_mask(img, color, tol).sum()
    log(f"水的颜色={color.astype(int).tolist()} 小地图上该颜色像素={n}")
    if n < 40:
        sys.exit("正前方没认出成片的水，请面朝水站在岸边再启动")
    return color


def turn_to(shore, keys, kb, target, tol=12, timeout=5.0):
    """原地转到"最近的水在 target 度方向"（0=面朝水，±90=水在侧面）。"""
    end = time.time() + timeout
    while time.time() < end:
        if not kb.wow_focused():
            return False
        d, ang = shore.nearest(shore.mask())
        if d is None:
            return False
        err = (ang - target + 180) % 360 - 180   # 正=还要向右转
        if abs(err) <= tol:
            return True
        keys.pulse('d' if err > 0 else 'a', min(0.25, max(0.03, abs(err) / 180.0 * 0.8)))
        time.sleep(0.06)
    return False


def walk(shore, keys, kb, side, target, seconds, verbose=False):
    """沿岸走。返回 'ok' | 'stuck' | 'lost' | 'unfocus'。"""
    end = time.time() + seconds
    prev, still, t_log = None, 0, 0
    keys.press('w')
    try:
        while time.time() < end:
            if not kb.wow_focused():
                return 'unfocus'
            m = shore.mask()
            if shore.in_water(m):
                return 'inwater'
            near = shore.lateral(m, side, -6, 8)
            ahead = shore.lateral(m, side, 10, 26)
            fr = shore.front(m, maxf=int(target * 0.8 + 6))
            dmin, _ = shore.nearest(m)
            if dmin is None or (near is None and ahead is None):
                return 'lost'
            # 卡住检测：小地图画面不再变化
            if prev is not None:
                diff = np.abs(shore.img - prev)[vision.DISK].mean()
                still = still + 1 if diff < 1.2 else 0
                if still >= 12:
                    return 'stuck'
            prev = shore.img
            # 转向量 u：正=朝水那侧转
            if fr is not None or dmin < target * 0.5:
                u = -1.0                                   # 正前方就是水 / 太贴水：往外打
            else:
                n = near if near is not None else ahead
                a = ahead if ahead is not None else n
                u = 0.05 * (n - target) + 0.06 * (a - n)   # 距离误差 + 航向误差
                u = max(-1.0, min(1.0, u))
            if verbose and time.time() - t_log > 0.5:
                t_log = time.time()
                log(f"  near={near} ahead={ahead} front={fr} dmin={dmin:.1f} u={u:+.2f}")
            if abs(u) > 0.12:
                key = ('d' if side > 0 else 'a') if u > 0 else ('a' if side > 0 else 'd')
                keys.pulse(key, 0.02 + 0.10 * abs(u))
            time.sleep(0.05)
        return 'ok'
    finally:
        keys.release_all()


def fish(meter, kb, args, casts):
    got = miss = 0
    for _ in range(casts):
        if not kb.wow_focused():
            break
        kb.tap(args.cast_key)
        if fisher.wait_bite(meter, kb, args):
            got += 1; miss = 0
            time.sleep(random.uniform(0.25, 0.75))
            kb.tap(args.interact_key)
            time.sleep(random.uniform(1.2, 2.8))
        else:
            miss += 1
            time.sleep(random.uniform(0.5, 1.2))
            if miss >= 2:      # 连续两竿没鱼：这个位置可能抛不进水，换地方
                break
    return got


def main():
    ap = argparse.ArgumentParser(description="沿岸边走边钓")
    ap.add_argument("--cast-key", default="0")
    ap.add_argument("--interact-key", default="F10")
    ap.add_argument("--casts", type=int, default=5, help="每个位置钓几竿 (默认 5)")
    ap.add_argument("--walk-seconds", type=float, default=6, help="每次沿岸走多少秒 (默认 6)")
    ap.add_argument("--side", choices=["left", "right"], default="right", help="走的时候水在哪一侧 (默认 right)")
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--water-tol", type=int, default=70, help="水颜色容差 (默认 70)")
    ap.add_argument("--walk-only", action="store_true", help="只走不钓（调试）")
    ap.add_argument("--verbose", action="store_true")
    # 听声参数，同 fisher.py
    ap.add_argument("--ratio", type=float, default=3.0)
    ap.add_argument("--min-rms", type=float, default=700)
    ap.add_argument("--max-rms", type=float, default=1800)
    ap.add_argument("--hits", type=int, default=2)
    ap.add_argument("--settle", type=float, default=2.5)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    kb = fisher.Keyboard()
    keys = Keys(kb)
    side = 1 if args.side == "right" else -1
    log("请切到游戏窗口（角色站岸边、面朝水）……")
    while not kb.wow_focused():
        time.sleep(0.5)
    time.sleep(1.0)
    shore = Shore(learn_water(args.water_tol), args.water_tol)
    d0, a0 = shore.nearest(shore.mask())
    target = d0
    if shore.in_water(shore.mask()):
        sys.exit("角色好像已经站在水里了，请先上岸")
    if target < ARROW + 5:
        sys.exit(f"离水太近或小地图比例太小（{target:.1f}px）。请把小地图放大到最大（小键盘 +），并站在离水边一两步的位置")
    log(f"基准离水距离={target:.1f}px（最近水方向 {a0:+.0f}°）")
    meter = None if args.walk_only else fisher.AudioMeter(fisher.default_sink_name())
    end = time.time() + args.minutes * 60
    total = 0
    try:
        while time.time() < end:
            if not kb.wow_focused():
                keys.release_all()
                log("魔兽窗口不在前台，暂停……")
                while not kb.wow_focused():
                    time.sleep(0.5)
                time.sleep(1.0)
            if not args.walk_only:
                if turn_to(shore, keys, kb, 0):
                    got = fish(meter, kb, args, args.casts)
                    total += got
                    log(f"这个位置钓到 {got}，累计 {total}")
                else:
                    log("没能转到面朝水，直接换位置")
            if not turn_to(shore, keys, kb, 90 * side, tol=25):
                log("没能转到沿岸方向，停止"); break
            res = walk(shore, keys, kb, side, target, args.walk_seconds, args.verbose)
            log(f"走了一段: {res}（水在{'右' if side > 0 else '左'}侧）")
            if res == 'inwater':
                log("检测到角色进水了，停止。请手动上岸"); break
            if res == 'stuck':
                side = -side
                log("走不动了，掉头")
            elif res == 'lost':
                log("附近找不到水了，掉头往回走")
                side = -side
                keys.pulse('d', 1.0)   # 大约转半圈
                keys.pulse('w', 1.5)
                if shore.nearest(shore.mask())[0] is None:
                    log("还是找不到水，停止"); break
            if args.walk_only and res == 'unfocus':
                break
    except KeyboardInterrupt:
        print(); log("已停止")
    finally:
        keys.release_all()
        if meter:
            meter.close()
        log(f"结束，累计钓到 {total}")


if __name__ == "__main__":
    main()

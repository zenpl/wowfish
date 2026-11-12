#!/usr/bin/env python3
"""按键端：盯着游戏窗口左上角的信号色块。品红 = 自动分解（亮着就隔几秒按一次）；蓝色 = 狙击买入/上架（按一次）。

信号由游戏插件 ForeverQuant 控制：在 /fq 的「监控」页点某一行右边的"分解 xN"按钮，
插件会建好分解宏、亮起色块；包里分完了、进战斗、或你再点一次按钮，色块就消失。
色块颜色里带着该按哪个键（绿色通道 = 键序号 x 30），所以这里不用配置按键。

用法：./de.sh --watch      一直开着就行，Ctrl+C 退出。只在魔兽窗口处于前台时按键。
"""
import random
import time

import numpy as np

import fisher
import vision

KEYS = ["F8", "F7", "F6", "F5", "F11", "F12", "F9"]     # 和插件里的 DE_KEYS 顺序一致
log = fisher.log


def read_signal():
    """返回 (要按的键, 类型) 或 (None, None)。在窗口左上角找插件画的纯色信号块。

    品红块 = 分解（"slow"：隔几秒按一次，直到信号消失）；蓝色块 = 买入/上架（"fast"：按一次就够）。
    绿色通道 = 键序号 x 30。
    """
    try:
        x, y, w, h = vision.win_rect()
        img = vision.grab(x, y, 40, 70)                 # 含标题栏在内的左上角
    except Exception:
        return None, None
    r, g, b = img[:, :, 0], img[:, :, 1], img[:, :, 2]
    for kind, hit in (("slow", (r > 243) & (b > 243) & (g < 225)), ("fast", (r < 12) & (b > 243) & (g < 225))):
        pos = vision.solid_block(hit)                    # 必须是一整块纯色方块，防止把风景认成信号
        if pos is None:
            continue
        block = g[pos[0]:pos[0] + 10, pos[1]:pos[1] + 10]
        if int(block.max()) - int(block.min()) > 6:      # 方块内绿色通道必须一致
            continue
        idx = int(round(float(np.median(block)) / 30.0))
        if 1 <= idx <= len(KEYS):
            return KEYS[idx - 1], kind
    return None, None


def main(interval=4.6):
    kb = fisher.Keyboard()
    log("de_watch 已启动：等游戏里的信号（分解 / 买入 / 上架）。Ctrl+C 退出。")
    active, presses, fast_total = False, 0, 0
    try:
        while True:
            key, kind = read_signal() if kb.wow_focused() else (None, None)
            if key and kind == "fast":
                # 买入/上架：按一次，然后等信号消失（插件收到按键会立刻撤掉），最多等 3 秒
                time.sleep(random.uniform(0.15, 0.4))
                kb.tap(key)
                fast_total += 1
                log(f"买入/上架信号：按了 {key}（累计 {fast_total} 次）")
                t0 = time.time()
                while time.time() - t0 < 3 and read_signal()[1] == "fast":
                    time.sleep(0.2)
                time.sleep(0.3)
            elif key:
                if not active:
                    active, presses = True, 0
                    log(f"收到分解信号，开始按 {key}")
                    time.sleep(random.uniform(0.6, 1.2))
                    continue
                kb.tap(key)
                presses += 1
                if presses % 10 == 0:
                    log(f"已按 {presses} 次")
                time.sleep(max(3.8, random.gauss(interval, 0.35)))
            else:
                if active:
                    active = False
                    log(f"分解信号消失，停止。这一轮按了 {presses} 次")
                time.sleep(0.3)
    except KeyboardInterrupt:
        print()
        log("已退出")


if __name__ == "__main__":
    main()

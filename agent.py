#!/usr/bin/env python3
"""统一的电脑端程序：钓鱼、分解、扫货（狙击买入）、上架、行情分析，一个程序全包。

所有功能都在游戏里开关，这里只管"看信号、按键"：
  左上角主信号块   品红 = 分解（隔几秒按一次）；蓝色 = 买入/上架（按一次）。颜色里带着该按哪个键。
  钓鱼请求块       黄色 = 请钓鱼。游戏里 /fq fish 开关。
  状态块           绿 = 正常；红 = 背包满；橙 = 角色死亡。钓鱼时看不到它超过 8 秒 = 掉线/读条，停手。
另外会顺带启动行情分析（~/forever-quant 的 python3 -m quant auto），游戏里扫描存盘后自动分析。

用法：./agent.sh            一直开着就行，Ctrl+C 退出。只在魔兽窗口处于前台时按键。
      ./agent.sh --cast-key 0 --interact-key F10     钓鱼用的两个键（默认就是这两个）
"""
import argparse
import os
import random
import subprocess
import sys
import time

import numpy as np

import fisher
import vision

KEYS = ["F8", "F7", "F6", "F5", "F11", "F12", "F9"]     # 和插件里的 DE_KEYS 顺序一致
log = fisher.log


def read_screen():
    """读左上角一小片，返回 {'press': (键, 'slow'|'fast') 或 None, 'fish': bool, 'guard': 'ok'|'full'|'dead'|None}。"""
    out = {"press": None, "fish": False, "guard": None}
    try:
        x, y, w, h = vision.win_rect()
        img = vision.grab(x, y, 40, 170 if sys.platform == "darwin" else 130)      # macOS 窗口有标题栏，信号块靠下一点
    except (Exception, SystemExit):          # 游戏没开时找不到窗口，不能因此让常驻程序退出
        return out
    r, g, b = img[:, :, 0], img[:, :, 1], img[:, :, 2]
    for kind, hit in (("slow", (r > 243) & (b > 243) & (g < 225)), ("fast", (r < 12) & (b > 243) & (g < 225))):
        pos = vision.solid_block(hit)                    # 必须是一整块纯色方块，防止把风景认成信号
        if pos is None:
            continue
        block = g[pos[0]:pos[0] + 10, pos[1]:pos[1] + 10]
        if int(block.max()) - int(block.min()) > 6:
            continue
        idx = int(round(float(np.median(block)) / 30.0))
        if 1 <= idx <= len(KEYS):
            out["press"] = (KEYS[idx - 1], kind)
            break
    out["fish"] = vision.solid_block((r > 243) & (g > 243) & (b < 12)) is not None
    for name, m in (("ok", (g > 243) & (r < 12) & (b < 12)), ("full", (r > 243) & (g < 12) & (b < 12)),
                    ("dead", (r > 243) & (g > 116) & (g < 140) & (b < 12))):
        if vision.solid_block(m) is not None:
            out["guard"] = name
            break
    return out


class Analysis:
    """行情分析子进程（forever-quant 的 quant auto）。挂了会自动重启。"""

    def __init__(self, enabled):
        here = os.path.dirname(os.path.abspath(__file__))
        self.dir = os.path.join(here, "forever-quant")              # 仓库里自带的那份；老的装法放在 ~/forever-quant
        if not os.path.isdir(self.dir):
            self.dir = os.path.expanduser("~/forever-quant")
        self.enabled = enabled and os.path.isdir(self.dir)
        self.proc, self.next_try = None, 0
        self.log_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "analysis.log")

    def tick(self):
        if not self.enabled or (self.proc and self.proc.poll() is None) or time.time() < self.next_try:
            return
        self.next_try = time.time() + 30
        out = open(self.log_path, "a", encoding="utf-8")
        self.proc = subprocess.Popen([sys.executable, "-u", "-m", "quant", "auto"], cwd=self.dir, stdout=out, stderr=subprocess.STDOUT)
        log(f"行情分析已启动（输出在 {self.log_path}）")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


class Fishing:
    """听声钓鱼，每次调用 step() 钓一竿。"""

    def __init__(self, kb, args):
        self.kb, self.args, self.meter = kb, args, None
        self.casts = self.bites = self.misses = 0
        self.started = None
        self.missing_since = None
        self.next_break = time.time() + random.uniform(8, 20) * 60

    def begin(self):
        if self.meter is None:
            self.meter = fisher.AudioMeter(fisher.default_sink_name())
        self.casts = self.bites = self.misses = 0
        self.started = time.time()
        self.next_break = time.time() + random.uniform(8, 20) * 60
        log(f"开始钓鱼：抛竿={self.args.cast_key} 互动={self.args.interact_key}")

    def end(self, why):
        if self.started:
            mins = (time.time() - self.started) / 60
            log(f"钓鱼结束（{why}）：{mins:.0f} 分钟，{self.casts} 竿，咬钩 {self.bites} 次"
                + (f"，平均每小时 {self.bites / mins * 60:.0f} 条" if mins >= 1 else ""))
        self.started = None

    def blocked(self, scr):
        """返回不能钓的原因，可以钓返回 None。"""
        if scr["guard"] == "full":
            return "背包满了"
        if scr["guard"] == "dead":
            return "角色死亡"
        if scr["guard"] is None:
            self.missing_since = self.missing_since or time.time()
            if time.time() - self.missing_since > 8:
                return "看不到状态块（掉线、读条或回到了登录界面）"
            return "wait"
        self.missing_since = None
        return None

    def poll(self):
        """等咬钩的时候约每半秒被问一次：顺手处理动作键信号（在线心跳、扔垃圾鱼），再回答"还要不要钓"。
        以前等咬钩时不看这个信号，一竿最长 30 秒，心跳只亮 3 秒，基本都错过，游戏里就显示"没连上"。"""
        scr = read_screen()
        p = scr["press"]
        if p and p[1] == "fast" and time.time() - getattr(self, "last_fast", 0) > 1.5:
            self.kb.tap(p[0])
            self.last_fast = time.time()
        return not scr["fish"]

    def step(self):
        a = self.args
        if time.time() > self.next_break:
            rest = random.uniform(20, 90)
            log(f"休息 {rest:.0f} 秒")
            time.sleep(rest)
            self.next_break = time.time() + random.uniform(8, 20) * 60
            return
        self.casts += 1
        log(f"第 {self.casts} 竿（已钓 {self.bites}）")
        self.kb.tap(a.cast_key)
        if fisher.wait_bite(self.meter, self.kb, a, should_stop=self.poll):
            self.bites += 1
            self.misses = 0
            time.sleep(random.uniform(0.25, 0.75))
            self.kb.tap(a.interact_key)
            time.sleep(random.uniform(1.2, 2.8))
        else:
            self.misses += 1
            log("  没等到咬钩，重抛")
            time.sleep(random.uniform(0.5, 1.5))
            if self.misses >= 8:
                log("  连续 8 竿没咬钩，歇 60 秒。检查站位、声音、鱼竿。")
                time.sleep(60)
                self.misses = 0


def main():
    ap = argparse.ArgumentParser(description="WoW 助手：钓鱼 / 分解 / 买入 / 上架 / 行情分析，一个程序")
    ap.add_argument("--cast-key", default="0", help="钓鱼技能的按键 (默认 0)")
    ap.add_argument("--interact-key", default="F10", help="'与目标互动'的按键 (默认 F10)")
    ap.add_argument("--de-interval", type=float, default=4.6, help="自动分解两次按键的平均间隔秒数 (默认 4.6)")
    ap.add_argument("--no-analysis", action="store_true", help="不启动行情分析")
    ap.add_argument("--ratio", type=float, default=3.0)
    ap.add_argument("--min-rms", type=float, default=700)
    ap.add_argument("--max-rms", type=float, default=1800)
    ap.add_argument("--hits", type=int, default=2)
    ap.add_argument("--settle", type=float, default=2.5)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    log_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(log_dir, exist_ok=True)
    fisher.LOG_FILE = open(os.path.join(log_dir, time.strftime("agent-%Y%m%d.log")), "a", encoding="utf-8")
    fisher.LOG_FILE.write(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} 启动 =====\n")

    kb = fisher.Keyboard()
    fishing = Fishing(kb, args)
    analysis = Analysis(not args.no_analysis)
    log("agent 已启动：钓鱼 / 分解 / 买入 / 上架都由游戏里的开关控制。Ctrl+C 退出。")
    de_active, de_presses, fast_total, fish_on, fish_block_said = False, 0, 0, False, None
    try:
        while True:
            analysis.tick()
            if not kb.wow_focused():
                time.sleep(0.5)
                continue
            scr = read_screen()

            # 1) 买入 / 上架：按一次，等信号消失
            if scr["press"] and scr["press"][1] == "fast":
                key = scr["press"][0]
                time.sleep(random.uniform(0.15, 0.4))
                kb.tap(key)
                fast_total += 1
                # 这个键也是每分钟一次的在线心跳，所以不逐条记日志，只在第一次和每 30 次报一下
                if fast_total == 1 or fast_total % 30 == 0:
                    log(f"动作键 {key} 已按 {fast_total} 次（买入 / 上架 / 在线心跳共用）")
                t0 = time.time()
                while time.time() - t0 < 3:
                    p = read_screen()["press"]
                    if not p or p[1] != "fast":
                        break
                    time.sleep(0.2)
                time.sleep(0.3)
                continue

            # 2) 分解：信号亮着就隔几秒按一次
            if scr["press"]:
                key = scr["press"][0]
                if not de_active:
                    de_active, de_presses = True, 0
                    log(f"收到分解信号，开始按 {key}")
                    time.sleep(random.uniform(0.6, 1.2))
                    continue
                kb.tap(key)
                de_presses += 1
                if de_presses % 10 == 0:
                    log(f"分解已按 {de_presses} 次")
                time.sleep(max(3.8, random.gauss(args.de_interval, 0.35)))
                continue
            if de_active:
                de_active = False
                log(f"分解信号消失，停止。这一轮按了 {de_presses} 次")

            # 3) 钓鱼
            if scr["fish"]:
                if not fish_on:
                    fish_on, fish_block_said = True, None
                    fishing.begin()
                why = fishing.blocked(scr)
                if why == "wait":
                    time.sleep(1)
                elif why:
                    if fish_block_said != why:
                        fish_block_said = why
                        log(f"钓鱼暂停：{why}")
                    time.sleep(2)
                else:
                    fish_block_said = None
                    fishing.step()
                continue
            if fish_on:
                fish_on = False
                fishing.end("游戏里关掉了")
            time.sleep(0.3)
    except KeyboardInterrupt:
        print()
        if fish_on:
            fishing.end("手动退出")
        log("已退出")
    finally:
        analysis.stop()
        if fishing.meter:
            fishing.meter.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""自动分解：隔几秒按一次分解宏的键，按够数量就停。

游戏内准备（一次性）：打开拍卖行插件 ForeverQuant 后输入  /fq demacro
  它会建一个宏「FQ分解」（/cast 分解 + /use 指定物品）并绑到 F8。
  先手动按一次 F8，确认确实分解了一件、战利品自动进包，再用这个脚本。
  需要开着自动拾取。

用法：
  ./de.sh 50              分解 50 件（切到游戏窗口后才开始，Ctrl+C 停止）
  ./de.sh 50 --key F8     宏绑在别的键上时指定
只在魔兽窗口处于前台时按键；窗口切走会暂停，切回来继续。
"""
import argparse
import random
import time

import fisher

log = fisher.log


def main():
    ap = argparse.ArgumentParser(description="自动分解（按分解宏的键）")
    ap.add_argument("count", type=int, help="要分解多少件")
    ap.add_argument("--key", default="F8", help="分解宏绑定的键 (默认 F8)")
    ap.add_argument("--interval", type=float, default=4.6,
                    help="两次按键的平均间隔秒数；要大于施法 3 秒 + 拾取时间 (默认 4.6)")
    ap.add_argument("--dry-run", action="store_true", help="只打印不按键")
    args = ap.parse_args()
    if args.interval < 3.8:
        ap.error("间隔太短，上一件还没分解完就会被打断；至少 3.8 秒")

    kb = fisher.Keyboard()
    log(f"准备分解 {args.count} 件，按键 {args.key}，间隔约 {args.interval:.1f} 秒，"
        f"预计 {args.count * args.interval / 60:.1f} 分钟。切到游戏窗口后开始，Ctrl+C 停止。")
    done = 0
    next_break = random.randint(25, 45)
    try:
        while done < args.count:
            if not kb.wow_focused():
                log("魔兽窗口不在前台，暂停……（切回游戏自动继续）")
                while not kb.wow_focused():
                    time.sleep(0.5)
                time.sleep(random.uniform(1.0, 2.0))
                log("继续")
            if args.dry_run:
                log(f"[dry-run] 按 {args.key}")
            else:
                kb.tap(args.key)
            done += 1
            if done % 10 == 0 or done == args.count:
                log(f"已按 {done}/{args.count}")
            if done >= args.count:
                break
            time.sleep(max(3.8, random.gauss(args.interval, 0.35)))
            if done >= next_break:          # 偶尔停一下
                rest = random.uniform(6, 20)
                log(f"停 {rest:.0f} 秒")
                time.sleep(rest)
                next_break = done + random.randint(25, 45)
        log(f"完成：共按了 {done} 次。检查背包确认都分解了；被打断的那几件再跑一次补上。")
    except KeyboardInterrupt:
        print()
        log(f"已停止，按了 {done} 次")


if __name__ == "__main__":
    main()

"""调试: 在游戏里执行 重载 -> 开拍卖行 -> /fq scan -> 重载存盘。角色需站在拍卖师面前。"""
import sys, time
import fisher, wintool, gshot, typer, vision
kb = fisher.Keyboard()
def focus():
    for _ in range(8):
        if kb.wow_focused(): return
        wintool.focus(); time.sleep(1.2)
    sys.exit('cannot focus game: ' + kb.active_title())
def say(cmd, wait):
    focus(); kb.tap('Return'); time.sleep(0.7); typer.type_text(kb.d, cmd); time.sleep(0.3); kb.tap('Return'); time.sleep(wait)
out = sys.argv[1]
say('/reload', 15)
focus(); x, y, w, h = vision.win_rect(); print('win', w, h)
gshot.click(int(w * float(sys.argv[2])), int(h * float(sys.argv[3])), 3); time.sleep(2.5)
focus(); kb.tap('F10'); time.sleep(2.5)      # 再用"与目标互动"键补一次，防止鼠标点到别的玩家
say('/fq scan', int(sys.argv[4]) if len(sys.argv) > 4 else 55)
focus(); x, y, w, h = vision.win_rect()
gshot.game(out, 1.0, (0, int(h * 0.5), 760, int(h * 0.92)))
say('/reload', 15)

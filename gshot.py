"""调试: 截游戏窗口。 gshot.py out.png [scale] [x0 y0 x1 y1 (窗口内坐标)]"""
import sys
import wintool, vision
from PIL import Image
def game(path, scale=0.5, box=None):
    x, y, w, h = vision.win_rect()
    wintool.shot(path + '.full.png', 1.0)
    im = Image.open(path + '.full.png').crop((x, y, x + w, y + h))
    if box: im = im.crop(box)
    im.resize((int(im.width * scale), int(im.height * scale))).save(path)
def click(wx, wy, button=1):
    x, y, _, _ = vision.win_rect(); wintool.click(x + wx, y + wy, button)
if __name__ == '__main__':
    a = sys.argv
    game(a[1], float(a[2]) if len(a) > 2 else 0.5, tuple(int(v) for v in a[3:7]) if len(a) > 6 else None)

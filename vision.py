"""小地图读图：截取小地图、提取水域掩码。约定小地图已设为随角色旋转（上=面朝方向）。"""
import sys

import numpy as np

MAC = sys.platform == "darwin"
if not MAC:
    from Xlib import X, display
    d = display.Display(); root = d.screen().root
# 小地图圆心相对游戏窗口右上角的偏移，以及可用半径（像素）
MM_DX, MM_Y, MM_R = 118, 173, 78

def wow_window():
    for wid in root.get_full_property(d.intern_atom('_NET_CLIENT_LIST'), X.AnyPropertyType).value:
        w = d.create_resource_object('window', wid)
        n = w.get_full_property(d.intern_atom('_NET_WM_NAME'), X.AnyPropertyType)
        t = n.value.decode('utf8', 'replace') if n else ''
        if t.strip().lower() in ('world of warcraft', '魔兽世界', '魔獸世界'):
            return w
    raise SystemExit('没找到魔兽窗口')

def win_rect():
    w = wow_window(); g = w.get_geometry(); t = w.translate_coords(root, 0, 0)
    return -t.x, -t.y, g.width, g.height

def grab(x, y, w, h):
    raw = root.get_image(x, y, w, h, X.ZPixmap, 0xffffffff)
    a = np.frombuffer(raw.data, dtype=np.uint8).reshape(h, w, 4)
    return a[:, :, 2::-1].astype(np.int16)  # RGB

if MAC:                         # macOS：找窗口和截图换成 Quartz 的实现（接口相同）
    from mac_backend import grab, win_rect  # noqa: F811,E402


def minimap():
    """返回 (2R+1)x(2R+1) 的 RGB 小地图，圆心在正中。"""
    x, y, w, h = win_rect()
    cx, cy = x + w - MM_DX, y + MM_Y
    return grab(cx - MM_R, cy - MM_R, 2 * MM_R + 1, 2 * MM_R + 1)

_yy, _xx = np.mgrid[-MM_R:MM_R + 1, -MM_R:MM_R + 1]
DISK = (_xx ** 2 + _yy ** 2) <= MM_R ** 2

def water_mask(img, color, tol=60):
    diff = np.abs(img - np.array(color, dtype=np.int16)).sum(axis=2)
    return (diff < tol) & DISK


def solid_block(mask, size=10):
    """mask 里有没有一个 size x size 的方块几乎全是 True（至少 97%）。

    用来认插件画的纯色信号块：风景里就算有相近的颜色，也很难凑出一整块纯色方块。
    返回 (行, 列) 或 None。
    """
    m = mask.astype(np.int32)
    h, w = m.shape
    if h < size or w < size:
        return None
    c = np.zeros((h + 1, w + 1), dtype=np.int32)
    c[1:, 1:] = m.cumsum(0).cumsum(1)
    sums = c[size:, size:] - c[:-size, size:] - c[size:, :-size] + c[:-size, :-size]
    idx = np.argwhere(sums >= int(size * size * 0.97))
    return tuple(idx[0]) if len(idx) else None

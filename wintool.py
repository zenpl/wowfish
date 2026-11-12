"""调试小工具: focus = 把魔兽窗口切到前台; shot <file> = 截屏"""
import sys, time
from Xlib import X, display, protocol
from PIL import Image
d = display.Display(); root = d.screen().root
def wow():
    for wid in root.get_full_property(d.intern_atom('_NET_CLIENT_LIST'), X.AnyPropertyType).value:
        w = d.create_resource_object('window', wid)
        n = w.get_full_property(d.intern_atom('_NET_WM_NAME'), X.AnyPropertyType)
        t = n.value.decode('utf8', 'replace') if n else ''
        if t.strip().lower() in ('world of warcraft', '魔兽世界', '魔獸世界'): return w
    sys.exit('没找到魔兽窗口')
def focus():
    w = wow()
    ev = protocol.event.ClientMessage(window=w, client_type=d.intern_atom('_NET_ACTIVE_WINDOW'),
                                      data=(32, [2, X.CurrentTime, 0, 0, 0]))
    root.send_event(ev, event_mask=X.SubstructureRedirectMask | X.SubstructureNotifyMask); d.sync()
def shot(path, scale=0.5):
    g = root.get_geometry()
    raw = root.get_image(0, 0, g.width, g.height, X.ZPixmap, 0xffffffff)
    im = Image.frombytes('RGB', (g.width, g.height), raw.data, 'raw', 'BGRX')
    im.resize((int(g.width*scale), int(g.height*scale))).save(path)
if __name__ == '__main__':
    if sys.argv[1] == 'focus': focus()
    else: shot(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 0.5)

def click(x, y, button=1):
    from Xlib.ext import xtest
    xtest.fake_input(d, X.MotionNotify, x=x-3, y=y-2); d.sync(); time.sleep(0.15)
    xtest.fake_input(d, X.MotionNotify, x=x, y=y); d.sync(); time.sleep(0.25)
    xtest.fake_input(d, X.ButtonPress, button); d.sync(); time.sleep(0.08)
    xtest.fake_input(d, X.ButtonRelease, button); d.sync()
OX, OY = 1350, 130
def crop(path, box=(0, 0, 1930, 1105)):
    shot(path + '.full.png', 1.0)
    Image.open(path + '.full.png').crop((OX+box[0], OY+box[1], OX+box[2], OY+box[3])).save(path)

import time, random
from Xlib import X, XK
from Xlib.ext import xtest
NAMES = {' ':'space','/':'slash','(':'parenleft',')':'parenright','"':'quotedbl',',':'comma','_':'underscore','.':'period','=':'equal',';':'semicolon'}
def type_text(d, text):
    shift = d.keysym_to_keycode(XK.XK_Shift_L)
    for ch in text:
        if ch in '()':  # 专用括号键码 Wine 不认，强制用 Shift+9/0
            code, need = d.keysym_to_keycode(XK.string_to_keysym('9' if ch == '(' else '0')), True
        else:
            sym = XK.string_to_keysym(NAMES.get(ch, ch))
            code = d.keysym_to_keycode(sym)
            need = d.keycode_to_keysym(code, 0) != sym
        if need: xtest.fake_input(d, X.KeyPress, shift)
        xtest.fake_input(d, X.KeyPress, code); d.sync(); time.sleep(0.03)
        xtest.fake_input(d, X.KeyRelease, code)
        if need: xtest.fake_input(d, X.KeyRelease, shift)
        d.sync(); time.sleep(random.uniform(0.03, 0.06))

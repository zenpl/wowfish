"""读取本机 QuestieDB 插件里的物品/NPC 数据（哪些商人卖、在哪）。

数据存在 QuestieDB_Forever.toc 的元数据行里：
    ## X-Item-<物品ID>-<字段号>: <base64(CBOR)>      表字段（14 = 出售该物品的商人 NPC ID 列表）
    ## X-Npc-<NPC ID>-S: <base64(CBOR 映射)>          标量字段打包（1 名称 9 主要地区 13 友好阵营 14 头衔）
    ## X-Npc-<NPC ID>-7: ...                         刷新点 {地区ID: [[x, y], ...]}
"""
import base64
import os
import re
import struct
from pathlib import Path


def cbor(data):
    """最小 CBOR 解码器（整数、字节串、文本、数组、映射、简单值、浮点），够读 QuestieDB 用。"""
    def read(i):
        b = data[i]; major, info = b >> 5, b & 31; i += 1
        if major == 7:
            if info == 25: return struct.unpack(">e", data[i:i + 2])[0], i + 2
            if info == 26: return struct.unpack(">f", data[i:i + 4])[0], i + 4
            if info == 27: return struct.unpack(">d", data[i:i + 8])[0], i + 8
            return {20: False, 21: True, 22: None, 23: None}.get(info), i
        if info < 24: n = info
        elif info == 24: n = data[i]; i += 1
        elif info == 25: n = int.from_bytes(data[i:i + 2], "big"); i += 2
        elif info == 26: n = int.from_bytes(data[i:i + 4], "big"); i += 4
        elif info == 27: n = int.from_bytes(data[i:i + 8], "big"); i += 8
        else: raise ValueError("不支持的 CBOR 长度编码")
        if major == 0: return n, i
        if major == 1: return -1 - n, i
        if major == 2: return data[i:i + n], i + n
        if major == 3: return data[i:i + n].decode("utf-8", "replace"), i + n
        if major == 4:
            out = []
            for _ in range(n):
                v, i = read(i); out.append(v)
            return out, i
        if major == 5:
            out = {}
            for _ in range(n):
                k, i = read(i); v, i = read(i); out[k] = v
            return out, i
        if major == 6: return read(i)          # 标签：忽略，直接读内容
    return read(0)[0]


def toc_path(cfg):
    return Path(os.path.expanduser(cfg["addon"]["addons_dir"])) / "QuestieDB" / "QuestieDB_Forever.toc"


def load_raw(path, prefixes=("Item", "Npc", "l10n-zhCN")):
    """返回 {键: 原始字符串}，键如 'Item-6330-14'。分块的值（~N~ + 编号分片）会被拼起来。"""
    raw = {}
    pat = re.compile(r"^## X-((?:%s)-[^:]+): (.*)$" % "|".join(prefixes))
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = pat.match(line.rstrip("\n"))
            if m:
                raw[m.group(1)] = m.group(2)
    return raw


def value(raw, key):
    v = raw.get(key)
    if v is None:
        return None
    m = re.match(r"^~(\d+)~$", v)
    if m:                                     # 分块：key-1 … key-N 依次拼接
        v = "".join(raw.get(f"{key}-{i}", "") for i in range(1, int(m.group(1)) + 1))
    try:
        return cbor(base64.b64decode(v))
    except Exception:
        return None


def text(v):
    return v.decode("utf-8", "replace") if isinstance(v, bytes) else v


def l10n(raw, locale, entity):
    """本地化块：分块的 base64(zlib(CBOR))。返回解码后的对象，读不了返回 None。"""
    import zlib
    key = f"l10n-{locale}-{entity}"
    v = raw.get(key)
    if v is None:
        return None
    m = re.match(r"^~(\d+)~$", v)
    if m:
        v = "".join(raw.get(f"{key}-{i}", "") for i in range(1, int(m.group(1)) + 1))
    try:
        return cbor(zlib.decompress(base64.b64decode(v)))
    except Exception:
        return None


def zone_names(cfg):
    """地区 ID -> 中文名（没有中文就用英文）。来自 Questie 自带的地区表和翻译。"""
    root = Path(os.path.expanduser(cfg["addon"]["addons_dir"])) / "Questie" / "Localization"
    en = {}
    f = root / "lookups" / "lookupZones.lua"
    if f.exists():
        txt = f.read_text(encoding="utf-8", errors="replace")
        txt = txt[txt.find("l10n.zoneLookup"):]         # 前面还有一张大陆表，编号会和地区撞车
        for m in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]+)"', txt):
            en.setdefault(int(m.group(1)), m.group(2))
    zh = {}
    for f in (root / "Translations" / "Zones").glob("*.lua"):
        txt = f.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(r'\["([^"]+)"\]\s*=\s*\{(.*?)\n\s*\}', txt, re.S):
            z = re.search(r'\["zhCN"\]\s*=\s*"([^"]+)"', m.group(2))
            if z:
                zh[m.group(1)] = z.group(1)
    return {zid: zh.get(name, name) for zid, name in en.items()}


def area_to_uimap(cfg):
    """地区 ID -> 游戏地图 ID（设置导航点要用）。来自 QuestieDB 的对照表。"""
    f = Path(os.path.expanduser(cfg["addon"]["addons_dir"])) / "QuestieDB" / "support" / "Forever" / "Zones" / "areaIdToUiMapId.lua"
    out = {}
    if f.exists():
        for m in re.finditer(r"\[(\d+)\]\s*=\s*(\d+)", f.read_text(encoding="utf-8", errors="replace")):
            if int(m.group(2)):
                out.setdefault(int(m.group(1)), int(m.group(2)))
    return out


class VendorDB:
    """查某个物品由哪些商人出售。"""

    def __init__(self, cfg):
        self.raw = load_raw(toc_path(cfg))
        self.zones = zone_names(cfg)
        self.uimap = area_to_uimap(cfg)
        loc = l10n(self.raw, "zhCN", "Npc")
        self.npc_zh = loc if isinstance(loc, dict) else {}

    def item_known(self, item_id):
        return f"Item-{item_id}-S" in self.raw

    def vendors(self, item_id, faction="H"):
        """返回对该阵营友好的商人列表 [{id, name, zone, x, y}]。物品不在库里返回 None。"""
        if not self.item_known(item_id):
            return None
        out = []
        for npc in value(self.raw, f"Item-{item_id}-14") or []:
            s = value(self.raw, f"Npc-{npc}-S") or {}
            friendly = text(s.get(13)) or ""
            if faction not in friendly:
                continue
            spawns = value(self.raw, f"Npc-{npc}-7") or {}
            zid = s.get(9) or (next(iter(spawns)) if spawns else None)
            xy = (spawns.get(zid) or [[None, None]])[0] if isinstance(spawns, dict) else [None, None]
            zh = self.npc_zh.get(npc)
            name = text(zh[0] if isinstance(zh, list) and zh else zh) if zh else text(s.get(1))
            out.append(dict(id=npc, name=name or text(s.get(1)) or f"NPC {npc}", zone=self.zones.get(zid, f"地区{zid}"),
                            x=xy[0], y=xy[1], area=zid, map=self.uimap.get(zid, 0)))
        return out

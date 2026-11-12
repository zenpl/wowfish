import os
import tempfile
import unittest

from quant import database, gear

S = dict(ah_cut=0.05, min_roi=0.15, min_unit_profit=100)


def row(item, suffix, buyout, name, owner="A", tl=4, level=22, sub=2, loc="INVTYPE_CHEST", unique=1):
    return f"{item}|{suffix}|{unique}|1|{buyout}|{buyout - 10}|{level}|{tl}|4|{sub}|{loc}|{owner}|{name}"


def sv(lines):
    body = "".join(f'"{l}", -- [{i}]\n' for i, l in enumerate(lines, 1))
    return "\nForeverQuantDB = {\n[\"log\"] = {\n" + body + "},\n}\n"


def scan(t, rows, status="complete"):
    return [f"#SCAN|{t}|Horde|R|0|0"] + rows + [f"#END|{t + 60}|{status}|3|{len(rows)}"]


def market(cheap_monkey=True):
    rows = []
    for i in range(8):      # 猴之：正常挂 6000 左右
        rows.append(row(100, 600, 6000 + i * 100, "Bandit Jerkin of the Monkey", owner=f"M{i}", unique=i))
    for i in range(8):      # 鲸之：正常挂 800 左右
        rows.append(row(100, 845, 800 + i * 10, "Bandit Jerkin of the Whale", owner=f"W{i}", unique=i))
    if cheap_monkey:        # 错标：猴之按鲸之的价挂
        rows.append(row(100, 600, 900, "Bandit Jerkin of the Monkey", owner="Oops", unique=99))
    return rows


class TestGear(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = database.connect(os.path.join(self.dir.name, "t.sqlite"))

    def tearDown(self):
        self.db.close(); self.dir.cleanup()

    def test_parse_and_import(self):
        lines = scan(1000, market()) + scan(5000, market(), status="partial") + ["#SCAN|9000|Horde|R|0|0", row(1, 0, 5, "x")]
        scans = gear.parse_scans(gear.parse_log(sv(lines)))
        self.assertEqual(len(scans), 2)                         # 没有 #END 的那次被丢弃
        self.assertEqual(gear.import_scans(self.db, scans), 2)
        self.assertEqual(gear.import_scans(self.db, scans), 0)  # 重复导入不重复入库
        self.assertEqual(len(gear.latest_scans(self.db)), 1)    # partial 不参与分析

    def test_escaped_names(self):
        txt = sv([l.replace("Monkey", 'Mon\\"key') for l in scan(1000, market())])
        scans = gear.parse_scans(gear.parse_log(txt))
        self.assertTrue(any('Mon"key' in r[12] for r in scans[0]["rows"]))

    def test_vendor_arbitrage(self):
        lines = scan(1000, market())
        lines[-1:-1] = ["#VENDOR|500|0|10|40|80|100|Cheap Thing", "#VENDOR|501|0|10|3|110|100|Not Cheap",
                        "#VENDOR|502|600|20|1|10|500|Bandit Jerkin of the Monkey", "#VSTAT|9000|12"]
        gear.import_scans(self.db, gear.parse_scans(gear.parse_log(sv(lines))))
        sid = gear.latest_scans(self.db)[0]["id"]
        hits, checked, unknown = gear.vendor_arbitrage(self.db, sid)
        self.assertEqual([(h["item_id"], h["profit"]) for h in hits], [(502, 490), (500, 20)])   # 高于收购价的那条不算
        self.assertEqual((checked, unknown), (9000, 12))
        self.assertEqual(len(gear.load(self.db, sid)), len(market()))       # 不影响绿装行

    def test_recipe_resale(self):
        lines = scan(1000, market())
        lines[-1:-1] = ["#RECIPE|900|5|12|2000|100|Recipe: Good Stew",      # 进价 400，卖 2000
                        "#RECIPE|901|5|3|450|100|Recipe: Thin Margin",       # 进价 400，卖 450：不够
                        "#RECIPE|902|6|1|9000|0|Recipe: No Vendor Price",    # 商人价 0：不算
                        "#RECIPE|903|2|4|3000|100|Pattern: Slow Seller",
                        "#RECIPE|904|2|4|3000|100|Pattern: Not In Database"]
        gear.import_scans(self.db, gear.parse_scans(gear.parse_log(sv(lines))))
        sid = gear.latest_scans(self.db)[0]["id"]
        recs = gear.recipe_resale(self.db, sid, S, {900: 10.0, 903: 0.1})
        self.assertEqual([r["item_id"] for r in recs][:2], [900, 903])           # 净赚 x 日销 高的排前面
        r = recs[0]
        self.assertEqual((r["cost"], r["target"], r["profession"]), (400, 1940, "烹饪"))
        self.assertEqual(r["net"], int(1940 * 0.95) - 400)

        class FakeVendors:
            def vendors(self, item_id, faction):
                return {900: [dict(id=1, name="Cook", zone="奥格瑞玛", x=57.4, y=53.0)], 903: []}.get(item_id)
        recs = gear.recipe_resale(self.db, sid, S, {900: 10.0, 903: 0.1}, vendor_db=FakeVendors())
        src = {r["item_id"]: r["source"] for r in recs}
        self.assertEqual((src[900], src[903], src[904]), ("vendor", "none", "unknown"))
        self.assertEqual(recs[0]["vendors"], "奥格瑞玛 57,53 Cook")

    def test_rule_based_screen(self):
        RULE = dict(max_level=34, leather=["of the Monkey", "of the Wolf", "of the Tiger"], confirmed=["leather"],
                    floor_ratio=1.3, min_gap=3.0)
        def r(suffix, price, name, level=22): return row(300, suffix, price, "Bandit Pants " + name, owner=name, level=level, loc="INVTYPE_LEGS")
        base = [r(1, 1450, "of Defense"), r(2, 1500, "of Shadow Resistance"), r(600, 5540, "of the Monkey"),
                r(601, 900000, "of the Tiger")]                      # 最后一个是乱挂的天价
        self.db.executescript(gear.SCHEMA)
        for sid, label in ((1, "of Defense"), (2, "of Shadow Resistance"), (600, "of the Monkey"), (601, "of the Tiger"), (602, "of the Wolf")):
            self.db.execute("INSERT OR REPLACE INTO gear_suffixes VALUES(?,?)", (sid, label))
        rows = self._rows(1000, base + [r(602, 1000, "of the Wolf")])
        cands = gear.find_by_rule(rows, S, RULE)
        self.assertEqual([c.name for c in cands], ["Bandit Pants of the Wolf"])
        c = cands[0]
        self.assertEqual(c.target_price, int(5540 * 0.95))           # 比同件装备上最便宜的热门后缀再低 5%，天价单不算
        self.assertEqual(c.unit_profit, int(int(5540 * 0.95) * 0.95) - 1000)
        self.assertTrue(any("成交验证" in n for n in c.notes))
        # 冷门后缀再便宜也不报；热门后缀但已经不在地板价附近也不报
        rows = self._rows(2000, base + [r(602, 3000, "of the Wolf")])
        self.assertEqual(gear.find_by_rule(rows, S, RULE), [])
        # 超过等级上限不看
        rows = self._rows(3000, [dict_row for dict_row in [r(1, 1450, "of Defense", 40), r(2, 1500, "of Shadow Resistance", 40),
                                 r(600, 5540, "of the Monkey", 40), r(601, 6000, "of the Tiger", 40), r(602, 1000, "of the Wolf", 40)]])
        self.assertEqual(gear.find_by_rule(rows, S, RULE), [])

    def test_rule_twink_jewelry_weapon(self):
        self.db.executescript(gear.SCHEMA)
        for sid, label in ((1, "of Defense"), (2, "of Shadow Resistance"), (600, "of the Monkey"), (601, "of the Tiger"),
                           (603, "of Stamina"), (604, "of the Eagle")):
            self.db.execute("INSERT OR REPLACE INTO gear_suffixes VALUES(?,?)", (sid, label))
        RULE = dict(max_level=34, leather=["of the Monkey", "of the Tiger"], jewelry_cloak=["of the Eagle", "of the Monkey"],
                    weapon=["of the Monkey", "of the Tiger"], confirmed=["leather"], floor_ratio=1.3, min_gap=3.0,
                    twink_min_req=37, twink_max_req=39, twink_extra=["of Stamina"])
        def agg(item, suffix, price, name, ilvl, req, cls=4, sub=2, loc="INVTYPE_LEGS"):
            return f"{item}|{suffix}|0|1|{price}|{req}|{ilvl}|0|{cls}|{sub}|{loc}||X {name}"
        def item(iid, cheap_suffix, cheap_name, ilvl, req, **kw):
            return [agg(iid, 1, 1450, "of Defense", ilvl, req, **kw), agg(iid, 2, 1500, "of Shadow Resistance", ilvl, req, **kw),
                    agg(iid, 600, 6000, "of the Monkey", ilvl, req, **kw), agg(iid, 601, 7000, "of the Tiger", ilvl, req, **kw),
                    agg(iid, cheap_suffix, 1000, cheap_name, ilvl, req, **kw)]
        rows = self._rows(1000,
            item(400, 603, "of Stamina", 44, 39)                                  # 39 级档皮甲：耐力之算热门，且不受等级上限限制
            + item(401, 603, "of Stamina", 44, 36)                                # 需求 36：不是小号档，44 级又超上限 -> 不看
            + item(402, 603, "of Stamina", 22, 17)                                # 普通低级皮甲：耐力之不是热门 -> 不报
            + item(403, 604, "of the Eagle", 22, 17, loc="INVTYPE_FINGER", sub=0)  # 戒指：雄鹰之
            + item(404, 604, "of the Eagle", 22, 17, cls=2, sub=10, loc="INVTYPE_2HWEAPON"))   # 武器规则里没有雄鹰之 -> 不报
        cands = gear.find_by_rule(rows, S, RULE)
        got = {c.item_id: c for c in cands}
        self.assertEqual(sorted(got), [400, 403])
        self.assertTrue(any("39 级战场" in n for n in got[400].notes))
        self.assertTrue(any("首饰/披风" in n for n in got[403].notes))
        self.assertEqual(rows[0]["req_level"], 39)

    def test_hot_suffixes_from_common_sense_and_data(self):
        rule = dict(wants=dict(leather=dict(primary=["agi", "ap"], secondary=["str"]),
                               cloth=dict(primary=["sp"], secondary=["int"])),
                    suffix_stats={"灵猴之": ["agi", "sta"], "孤狼之": ["agi", "spi"], "猛虎之": ["str", "agi"], "野熊之": ["str", "sta"],
                                  "野猪之": ["str", "spi"], "能量之": ["ap"], "雄鹰之": ["int", "sta"], "暗影惩戒之": ["sp"],
                                  "巫师之": ["int", "sta", "sp"], "治疗之": ["heal"], "火焰防护之": ["res"]},
                    data_premium=2.0)
        leather = gear.hot_suffixes(rule, "leather")
        self.assertEqual(set(leather), {"灵猴之", "孤狼之", "猛虎之", "能量之"})      # 野熊、野猪只有一个次要属性，不算
        cloth = gear.hot_suffixes(rule, "cloth")
        self.assertEqual(set(cloth), {"暗影惩戒之", "巫师之"})                        # 雄鹰只有智力，法伤优先
        # 数据补充：布甲上治疗之挂价明显偏贵 -> 也算热门；样本太少或溢价不够的不算
        prem = {("布甲", "治疗之"): (3.7, 33), ("布甲", "雄鹰之"): (1.2, 100), ("布甲", "火焰防护之"): (5.0, 3), ("皮甲", "治疗之"): (1.9, 40)}
        cloth = gear.hot_suffixes(rule, "cloth", prem)
        self.assertEqual(cloth["治疗之"], "数据")
        self.assertNotIn("雄鹰之", cloth); self.assertNotIn("火焰防护之", cloth)
        self.assertNotIn("治疗之", gear.hot_suffixes(rule, "leather", prem))
        self.assertEqual(gear.hot_suffixes(dict(leather=["x之"]), "leather"), {"x之": "名单"})     # 旧写法仍然可用

    def test_effect_items(self):
        def agg(item, price, effect="", ilvl=22):
            return f"{item}|0|0|1|{price}|18|{ilvl}|0|4|2|INVTYPE_LEGS|{effect}|Item{item}"
        rows = self._rows(1000, [agg(500 + i, 3000 + i * 100) for i in range(8)]
                          + [agg(600, 900, "装备： 使你的攻击强度提高6点。"), agg(601, 3200, "装备： 贵的特效装"), agg(602, 800)])
        rule = dict(effect_max_ratio=0.5)
        cands = gear.find_effect_items(rows, S, rule)
        self.assertEqual([c.item_id for c in cands], [600])           # 贵的特效装不报；便宜但没特效的也不报
        self.assertEqual(cands[0].strategy, "EFFECT")
        self.assertTrue(cands[0].notes[0].startswith("特效：装备"))

    def test_uncertain_suffix_not_confirmed(self):
        self.db.executescript(gear.SCHEMA)
        for sid, label in ((1, "防御之"), (2, "暗影防护之"), (10, "灵猴之"), (11, "野兽之"), (12, "敏捷之")):
            self.db.execute("INSERT OR REPLACE INTO gear_suffixes VALUES(?,?)", (sid, label))
        rule = dict(max_level=34, confirmed=["leather"], uncertain=["野兽之"], floor_ratio=1.3, min_gap=3.0,
                    wants=dict(leather=dict(primary=["agi", "crit"], secondary=[])),
                    suffix_stats={"灵猴之": ["agi", "sta"], "野兽之": ["crit", "sta"], "敏捷之": ["agi"], "防御之": ["def"], "暗影防护之": ["res"]})
        def agg(item, suffix, price, name):
            return f"{item}|{suffix}|0|1|{price}|18|22|0|4|2|INVTYPE_LEGS||{name}"
        # 两件装备各有一个便宜的热门后缀（同一件上有两个都便宜时会互相当成竞争者，各自都不报）
        rows = self._rows(1000, [agg(700, 1, 1400, "防御之X"), agg(700, 2, 1500, "暗影防护之X"), agg(700, 10, 6000, "灵猴之X"),
                                 agg(700, 11, 1000, "野兽之X"),
                                 agg(701, 1, 1400, "防御之Y"), agg(701, 2, 1500, "暗影防护之Y"), agg(701, 10, 6000, "灵猴之Y"),
                                 agg(701, 12, 1100, "敏捷之X")])
        cands = {c.name: c for c in gear.find_by_rule(rows, S, rule)}
        self.assertTrue(any("规则有成交验证" in n for n in cands["敏捷之X"].notes))
        self.assertTrue(any("没有成交验证" in n for n in cands["野兽之X"].notes))
        self.assertTrue(any("推断" in n for n in cands["野兽之X"].notes))
        self.assertGreater(cands["敏捷之X"].score, cands["野兽之X"].score)

    def test_ignore_and_highlight(self):
        rule = dict(wants=dict(leather=dict(primary=["agi", "ap"], secondary=["str"]), cloth=dict(primary=["sp"], secondary=["int"])),
                    suffix_stats={"灵猴之": ["agi", "sta"], "强盗之": ["agi", "sta", "ap"], "能量之": ["ap"], "巫师之": ["int", "sta", "sp"],
                                  "引导者之": ["int", "sp"], "暗影惩戒之": ["sp"], "骑士之": ["sta", "sp", "def"]},
                    ignore=["引导者之"], highlight_melee_stats=["agi", "str"], highlight_caster_stats=["int"], highlight_bonus=15,
                    max_level=34, confirmed=["leather"], floor_ratio=1.3, min_gap=3.0)
        self.assertEqual(gear.highlight_suffixes(rule), {"强盗之", "巫师之"})      # 能量只有攻强、骑士没有智力、引导者被忽略
        self.assertNotIn("引导者之", gear.hot_suffixes(rule, "cloth"))
        self.assertNotIn("引导者之", gear.hot_suffixes(rule, "cloth", {("布甲", "引导者之"): (9.0, 99)}))   # 数据再好看也不追
        self.db.executescript(gear.SCHEMA)
        for sid, label in ((1, "防御之"), (2, "暗影防护之"), (10, "灵猴之"), (11, "强盗之")):
            self.db.execute("INSERT OR REPLACE INTO gear_suffixes VALUES(?,?)", (sid, label))
        def agg(item, suffix, price, name):
            return f"{item}|{suffix}|0|1|{price}|18|22|0|4|2|INVTYPE_LEGS||{name}"
        rows = self._rows(1000, [agg(800, 1, 1400, "防御之A"), agg(800, 2, 1500, "暗影防护之A"), agg(800, 11, 6000, "强盗之A"), agg(800, 10, 1000, "灵猴之A"),
                                 agg(801, 1, 1400, "防御之B"), agg(801, 2, 1500, "暗影防护之B"), agg(801, 10, 6000, "灵猴之B"), agg(801, 11, 1000, "强盗之B")])
        cands = {c.name: c for c in gear.find_by_rule(rows, S, rule)}
        self.assertTrue(cands["强盗之B"].highlight); self.assertFalse(cands["灵猴之A"].highlight)
        self.assertAlmostEqual(cands["强盗之B"].score - cands["灵猴之A"].score, 15, places=1)    # 同样的价差，重点后缀多 15 分
        self.assertTrue(cands["强盗之B"].notes[0].startswith("★"))

    def test_role_budget_model(self):
        rule = dict(roles=dict(caster=dict(int=1.0, sp=1.0, spi=0.8, sta=0.7), melee=dict(agi=1.0, ap=1.0, sta=0.7),
                               paladin=dict(str=1.0, ap=1.0, sta=0.8, int=0.5)),
                    wearers=dict(cloth=["caster"], leather=["melee"], mail=["paladin", "melee"]),
                    hot_min_value=0.5, no_main_penalty=0.5, ignore=["引导者之"],
                    suffix_stats={"智力之": ["int"], "雄鹰之": ["int", "sta"], "夜枭之": ["int", "spi"], "猎鹰之": ["agi", "int"],
                                  "巨鲸之": ["sta", "spi"], "精神之": ["spi"], "巫师之": ["int", "sta", "sp"], "暗影惩戒之": ["sp"],
                                  "引导者之": ["int", "sp"], "灵猴之": ["agi", "sta"], "孤狼之": ["agi", "spi"], "强盗之": ["agi", "sta", "ap"],
                                  "能量之": ["ap"], "野熊之": ["str", "sta"], "猛虎之": ["str", "agi"], "巨猿之": ["str", "int"],
                                  "火焰防护之": ["res"]})
        v = lambda key, label: gear.suffix_value(rule, key, label)
        # 玩家举的例子：智力 10 全在主属性上；智力+耐力基本都算数；智力+敏捷有一半浪费
        self.assertEqual(v("cloth", "智力之"), (1.0, False, "caster"))
        self.assertEqual(v("cloth", "雄鹰之")[0], 0.85)
        self.assertEqual(v("cloth", "夜枭之")[0], 0.9)
        self.assertEqual(v("cloth", "猎鹰之")[0], 0.5)
        self.assertEqual(v("cloth", "巫师之"), (0.9, True, "caster"))          # 智力+法伤两个主属性：重点
        # 没有主属性的减半：精神+耐力虽然都想要，但没有智力/法伤
        self.assertEqual(v("cloth", "巨鲸之")[0], 0.375)
        self.assertEqual(v("cloth", "精神之")[0], 0.4)
        self.assertEqual(v("leather", "强盗之"), (0.9, True, "melee"))
        self.assertEqual(v("leather", "孤狼之")[0], 0.5)                        # 敏捷算数，精神浪费
        self.assertEqual(v("leather", "野熊之")[0], 0.175)                      # 近战不要力量，且没有主属性
        self.assertEqual(v("mail", "野熊之"), (0.9, False, "paladin"))
        self.assertEqual(v("mail", "巨猿之")[0], 0.75)                          # 圣骑：力量 + 半个智力
        self.assertEqual(v("mail", "猛虎之")[:2], (0.5, False))                 # 力量和敏捷分属两个角色，各算一半
        cloth, leather, mail = (set(gear.hot_suffixes(rule, k)) for k in ("cloth", "leather", "mail"))
        self.assertEqual(cloth, {"智力之", "雄鹰之", "夜枭之", "猎鹰之", "巫师之", "暗影惩戒之", "巨猿之"})   # 巨鲸、精神不够；引导者被忽略
        self.assertEqual(leather, {"灵猴之", "孤狼之", "强盗之", "能量之", "猎鹰之", "猛虎之"})
        self.assertIn("野熊之", mail); self.assertNotIn("火焰防护之", mail)
        # 德鲁伊：皮甲加上野德和法系德
        druid = dict(rule, roles=dict(rule["roles"], feral=dict(str=1.0, agi=1.0, ap=1.0, sta=0.7)),
                     wearers=dict(rule["wearers"], leather=["melee", "feral", "caster"]))
        dv = lambda label: gear.suffix_value(druid, "leather", label)
        self.assertEqual(dv("野熊之"), (0.85, False, "feral"))
        self.assertEqual(dv("雄鹰之"), (0.85, False, "caster"))
        self.assertEqual(dv("猛虎之"), (1.0, False, "feral"))                   # 力量+敏捷野德都要，但没有攻强，不加星
        self.assertEqual(dv("强盗之")[:2], (0.9, True))                         # 敏捷+攻强：重点
        # 主属性很多的职业不会满地星标：没有攻强/法伤的不加，浪费多的也不加
        pal = dict(rule, roles=dict(paladin=dict(str=1.0, sta=1.0, int=1.0, ap=1.0)), wearers=dict(mail=["paladin"]))
        self.assertEqual(gear.suffix_value(pal, "mail", "野熊之"), (1.0, False, "paladin"))
        self.assertEqual(gear.suffix_value(pal, "mail", "巨猿之")[:2], (1.0, False))
        self.assertEqual(gear.suffix_value(pal, "mail", "强盗之")[:2], (0.667, False))   # 有攻强和耐力，但敏捷浪费了
        self.assertEqual(dv("巨猿之")[:2], (0.5, False))                        # 力量和智力分属野德和法系德
        d2 = dict(druid, confirmed=["leather:melee"], uncertain=["野兽之"])
        self.assertTrue(gear.is_confirmed(d2, "leather", "强盗之"))
        self.assertFalse(gear.is_confirmed(d2, "leather", "野熊之"))
        self.assertFalse(gear.is_confirmed(d2, "leather", "暗影惩戒之"))
        self.assertTrue(gear.is_confirmed(dict(d2, confirmed=["leather"]), "leather", "野熊之"))

    def test_alternatives_and_scarcity(self):
        rule = dict(roles=dict(melee=dict(agi=1.0, ap=1.0, sta=0.5)), wearers=dict(leather=["melee"]), hot_min_value=0.5,
                    suffix_stats={"孤狼之": ["agi", "spi"], "灵猴之": ["agi", "sta"], "敏捷之": ["agi"], "防御之": ["def"], "暗影防护之": ["res"]},
                    max_level=34, floor_ratio=1.3, min_gap=3.0, alt_level_range=3, scarcity_bonus=10, comp_margin=0.15)
        self.db.executescript(gear.SCHEMA)
        for sid, label in ((1, "防御之"), (2, "暗影防护之"), (10, "孤狼之"), (11, "灵猴之"), (12, "敏捷之")):
            self.db.execute("INSERT OR REPLACE INTO gear_suffixes VALUES(?,?)", (sid, label))
        def agg(item, suffix, price, name, ilvl=22, loc="INVTYPE_LEGS"):
            return f"{item}|{suffix}|0|1|{price}|18|{ilvl}|0|4|2|{loc}||{name}"
        # 一条裤子：灵猴之（敏捷+耐力，75%）挂在地板价，同件上的孤狼之（敏捷+精神，50%）挂 6500
        pants = [agg(900, 1, 1400, "防御之裤"), agg(900, 2, 1500, "暗影防护之裤"), agg(900, 11, 1000, "灵猴之裤"), agg(900, 10, 6500, "孤狼之裤")]
        # 情况一：同部位相近等级里没有对近战同样好或更好的 -> 稀缺；目标价按同件装备上较弱的那个后缀
        rows = self._rows(1000, pants)
        c = [x for x in gear.find_by_rule(rows, S, rule) if x.buy_price == 1000][0]
        self.assertEqual(c.target_price, int(6500 * 0.95))
        self.assertTrue(any(n.startswith("稀缺") for n in c.notes))
        # 情况二：隔壁有一条纯敏捷的裤子（更好，物品等级差 2）只卖 2000 -> 目标价被它压住
        rows = self._rows(2000, pants + [agg(901, 12, 2000, "敏捷之别的裤", ilvl=24), agg(902, 12, 900, "敏捷之太远的裤", ilvl=30),
                                         agg(903, 12, 500, "敏捷之手套", loc="INVTYPE_HAND"), agg(904, 10, 300, "孤狼之更差的裤", ilvl=23)])
        c2 = [x for x in gear.find_by_rule(rows, S, rule) if x.buy_price == 1000][0]
        self.assertEqual(c2.target_price, int(2000 * 0.95))            # 等级差太远的、别的部位的、比自己差的都不算替代品
        self.assertTrue(any("替代品" in n and "还有 1 件" in n for n in c2.notes))
        self.assertAlmostEqual(c.score - c2.score - (c.unit_profit - c2.unit_profit) / 10000 * 40, 10, places=0)   # 稀缺加 10 分

    def test_need_stat_restricts_alternatives(self):
        rule = dict(roles=dict(paladin=dict(str=1.0, sta=1.0, int=1.0, ap=1.0)), wearers=dict(mail=["paladin"]), hot_min_value=0.5,
                    suffix_stats={"雄鹰之": ["int", "sta"], "巨猿之": ["str", "int"], "野熊之": ["str", "sta"], "防御之": ["def"], "暗影防护之": ["res"]},
                    max_level=34, floor_ratio=1.3, min_gap=3.0, alt_level_range=3, scarcity_bonus=10, need_bonus=5, comp_margin=0.15,
                    need_stats=dict(mail=["int"]))
        self.db.executescript(gear.SCHEMA)
        for sid, label in ((1, "防御之"), (2, "暗影防护之"), (20, "雄鹰之"), (21, "巨猿之"), (22, "野熊之")):
            self.db.execute("INSERT OR REPLACE INTO gear_suffixes VALUES(?,?)", (sid, label))
        def agg(item, suffix, price, name, ilvl=22):
            return f"{item}|{suffix}|0|1|{price}|18|{ilvl}|0|4|3|INVTYPE_LEGS||{name}"
        # 一条锁甲裤：雄鹰之（智力+耐力）挂地板价，同件上的巨猿之挂 6000；隔壁有一条很便宜的野熊之（力量+耐力，对圣骑同样 100%）
        rows = self._rows(1000, [agg(950, 1, 1400, "防御之锁裤"), agg(950, 2, 1500, "暗影防护之锁裤"), agg(950, 20, 1000, "雄鹰之锁裤"),
                                 agg(950, 21, 6000, "巨猿之锁裤"), agg(951, 22, 1200, "野熊之别的锁裤", ilvl=23)])
        c = [x for x in gear.find_by_rule(rows, S, rule) if x.name == "雄鹰之锁裤"][0]
        self.assertEqual(c.target_price, int(6000 * 0.95))        # 便宜的野熊之不带智力，不算替代品，压不住目标价
        self.assertTrue(any(n.startswith("特定需求") for n in c.notes))
        self.assertTrue(any("还有 1 件" in n for n in c.notes))     # 只有同件上的巨猿之（也带智力）算
        # 对照：不设特定需求时，野熊之算同样好的替代品，目标价被压到 1200 以下，没利润，候选消失
        plain = dict(rule, need_stats={})
        self.assertEqual([x for x in gear.find_by_rule(rows, S, plain) if x.name == "雄鹰之锁裤"], [])
        self.assertEqual(gear.needed_stats(rule, "mail", "巨猿之"), {"int"})
        self.assertEqual(gear.needed_stats(rule, "leather", "巨猿之"), set())

    def test_main_stat_is_absolute(self):
        # 新写法：主属性固定 1.0；副属性写得再高也压到 0.9，永远不和主属性齐平
        rule = dict(roles=dict(druid=dict(main=["str"], secondary=dict(int=1.0, sta=0.7), premium=["ap", "heal"])),
                    wearers=dict(leather=["druid"]), no_main_penalty=0.5, premium_stats=["ap", "sp", "heal"],
                    suffix_stats={"力量之": ["str"], "智力之": ["int"], "巨猿之": ["str", "int"], "野熊之": ["str", "sta"],
                                  "能量之": ["ap"], "治疗之": ["heal"], "暗影惩戒之": ["sp"]})
        w = gear.role_weights(rule, "druid")
        self.assertEqual((w["str"], w["int"], w["sta"], w["ap"]), (1.0, 0.9, 0.7, 1.0))
        v = lambda label: gear.suffix_value(rule, "leather", label)[0]
        self.assertEqual(v("力量之"), 1.0)
        self.assertLess(v("巨猿之"), 1.0)                       # 力量+智力：智力那一半打折，比纯力量低一点
        self.assertEqual(v("巨猿之"), 0.95)
        self.assertEqual(v("智力之"), 0.45)                     # 只有副属性，没有主属性：再减半
        self.assertGreater(v("野熊之"), v("智力之"))
        self.assertEqual(v("能量之"), 1.0)                      # 好词缀按 1.0 计入，不受"必须带主属性"的惩罚
        self.assertEqual(v("暗影惩戒之"), 0)                    # 这个职业没列法伤，就不算
        self.assertTrue(gear.is_premium(rule, "leather", "治疗之")); self.assertFalse(gear.is_premium(rule, "leather", "暗影惩戒之"))
        # 旧写法仍然可用
        old = dict(rule, roles=dict(druid=dict(str=1.0, int=0.8)))
        self.assertEqual(gear.role_weights(old, "druid"), dict(str=1.0, int=0.8))

    def test_demand_index_multi_role(self):
        rule = dict(roles=dict(melee=dict(main=["agi"], secondary=dict(sta=0.5), premium=["ap"]),
                               druid=dict(main=["str"], secondary=dict(int=0.8, sta=0.3), premium=["ap", "sp", "heal"])),
                    wearers=dict(leather=["melee", "druid"], cloth=["druid"]), hot_min_value=0.5, no_main_penalty=0.5,
                    multi_role_factor=0.5, multi_role_bonus=10,
                    suffix_stats={"能量之": ["ap"], "敏捷之": ["agi"], "猛虎之": ["str", "agi"], "巨猿之": ["str", "int"], "防御之": ["def"]})
        d = lambda label: gear.demand_index(rule, "leather", label)
        self.assertEqual(d("能量之"), (1.5, [("melee", 1.0), ("druid", 1.0)]))      # 攻强：盗贼和德鲁伊都 100% 想要
        self.assertEqual(d("敏捷之"), (1.0, [("melee", 1.0)]))                      # 只有盗贼要
        self.assertEqual(d("猛虎之")[0], 0.75)                                      # 两边各要一半：0.5 + 0.5 x 0.5
        self.assertEqual(d("巨猿之"), (0.9, [("druid", 0.9)]))
        self.assertEqual(d("防御之"), (0, []))
        self.assertEqual(gear.demand_index(rule, "cloth", "能量之"), (1.0, [("druid", 1.0)]))   # 只有一个职业穿，就没有叠加

    def test_main_weight_downweights_without_penalty(self):
        rule = dict(roles=dict(mage=dict(main=["int", "sp_fire", "sp_arcane"], main_weight=dict(sp_arcane=0.7), secondary=dict(spi=0.8))),
                    wearers=dict(cloth=["mage"]), no_main_penalty=0.5, hot_min_value=0.5,
                    premium_stats=["sp_fire", "sp_arcane"],
                    suffix_stats={"火焰惩戒之": ["sp_fire"], "奥法惩戒之": ["sp_arcane"], "精神之": ["spi"]})
        self.assertEqual(gear.suffix_value(rule, "cloth", "火焰惩戒之")[0], 1.0)
        self.assertEqual(gear.suffix_value(rule, "cloth", "奥法惩戒之")[0], 0.7)     # 降权，但没有被"没有主属性"再减半
        self.assertEqual(gear.suffix_value(rule, "cloth", "精神之")[0], 0.4)         # 真正的副属性才减半
        self.assertEqual(gear.premium_strength(rule, "cloth", "奥法惩戒之"), 0.7)
        self.assertIn("奥法惩戒之", gear.hot_suffixes(rule, "cloth"))

    def test_suffix_labels_learned(self):
        zh = [row(200 + i, 77, 500, n, owner=f"Z{i}") for i, n in enumerate(["野熊之七彩戒指", "野熊之礼节斗篷", "野熊之皮甲", "野熊之护腿"])]
        gear.import_scans(self.db, gear.parse_scans(scan(1000, market() + zh)))
        gear.learn_suffix_labels(self.db)
        known = {r["suffix_id"]: r["label"] for r in self.db.execute("SELECT * FROM gear_suffixes")}
        self.assertEqual(known[600], "of the Monkey")
        self.assertEqual(known[77], "野熊之")
        self.assertEqual(gear.suffix_label(0, known), "")
        self.assertEqual(gear.suffix_label(999, known), "后缀999")

    def test_sell_through_aggregated(self):
        def agg(item, qty): return f"{item}|600|0|{qty}|5000|0|22|0|4|2|INVTYPE_CHEST||Bandit Jerkin of the Monkey"
        prev = self._rows(1000, [agg(1, 5), agg(2, 3), agg(3, 1)])
        cur = self._rows(9000, [agg(1, 2), agg(2, 4)])
        st = gear.sell_through(prev, cur, 8000)
        self.assertEqual(st[("皮甲", "后缀600")], (4, 9))          # 5->2 少 3，3->4 不算，1->0 少 1

    def _rows(self, t, rows, learn=False):
        gear.import_scans(self.db, gear.parse_scans(scan(t, rows)))
        if learn:
            gear.learn_suffix_labels(self.db)
        return gear.load(self.db, self.db.execute("SELECT id FROM gear_scans WHERE scanned_at=?", (t,)).fetchone()[0])

    def test_finds_mispriced_popular_suffix(self):
        rows = self._rows(1000, market(), learn=True)
        prem = gear.suffix_premium(rows)
        self.assertGreater(prem[("皮甲", "of the Monkey")][0], 1.2)
        self.assertLess(prem[("皮甲", "of the Whale")][0], 1.0)
        cands = gear.find_mispriced(rows, S, prem)
        self.assertEqual(len(cands), 1)
        c = cands[0]
        self.assertEqual((c.buy_price, c.name), (900, "Bandit Jerkin of the Monkey"))
        self.assertEqual(c.target_price, int(6200 * 0.97))   # 8 个同类单的下四分位是 6200
        self.assertTrue(any("Oops" in n for n in c.notes))

    def test_no_signal_without_mispricing(self):
        rows = self._rows(1000, market(cheap_monkey=False), learn=True)
        self.assertEqual(gear.find_mispriced(rows, S, gear.suffix_premium(rows)), [])

    def test_cheap_unpopular_suffix_ignored(self):
        rows = self._rows(1000, market(cheap_monkey=False) + [row(100, 845, 300, "Bandit Jerkin of the Whale", owner="Z", unique=77)], learn=True)
        self.assertEqual(gear.find_mispriced(rows, S, gear.suffix_premium(rows)), [])

    def test_sell_through(self):
        before = market()
        after = [r for r in before if "|M0|" not in r and "|M1|" not in r]      # 两单猴之消失
        short = row(100, 600, 6500, "Bandit Jerkin of the Monkey", owner="Exp", tl=1, unique=50)   # 快过期的，不算
        prev = self._rows(1000, before + [short], learn=True)
        cur = self._rows(4600, after)
        st = gear.sell_through(prev, cur, 3600)
        self.assertEqual(st[("皮甲", "of the Monkey")], (2, 9))
        self.assertEqual(st[("皮甲", "of the Whale")], (0, 8))


if __name__ == "__main__":
    unittest.main()

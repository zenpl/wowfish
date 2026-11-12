import os
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load(path=None):
    p = Path(path or os.environ.get("FQ_CONFIG") or ROOT / "config.toml")
    with open(p, "rb") as f:
        cfg = tomllib.load(f)
    local = p.parent / "local.toml"            # 本机的设置（安装脚本写的，比如插件目录）盖在 config.toml 上面，不进仓库
    if local.exists():
        with open(local, "rb") as f:
            for section, values in tomllib.load(f).items():
                if isinstance(values, dict) and isinstance(cfg.get(section), dict):
                    cfg[section].update(values)
                else:
                    cfg[section] = values
    cfg["db_path"] = os.environ.get("FQ_DB") or str(ROOT / "data" / "market.sqlite")
    return cfg


def silver(copper):
    """装备用的计价：舍掉铜的零头，最小单位是银。'1g 23s' / '45s'；不足 1 银显示 '<1s'。"""
    copper = int(copper)
    sign = "-" if copper < 0 else ""
    copper = abs(copper)
    g, s = copper // 10000, copper // 100 % 100
    if g:
        return f"{sign}{g}g {s}s" if s else f"{sign}{g}g"
    return f"{sign}{s}s" if s else "<1s"


def gold(copper):
    """铜币 -> '1g 23s 45c'。"""
    copper = int(round(copper))
    sign = "-" if copper < 0 else ""
    copper = abs(copper)
    g, s, c = copper // 10000, copper // 100 % 100, copper % 100
    parts = ([f"{g}g"] if g else []) + ([f"{s}s"] if s or g else []) + [f"{c}c"]
    return sign + " ".join(parts)

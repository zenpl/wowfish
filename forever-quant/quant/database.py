import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
    item_id INTEGER PRIMARY KEY,
    name TEXT,
    quality TEXT,
    vendor_price INTEGER
);
CREATE TABLE IF NOT EXISTS snapshots (
    id INTEGER PRIMARY KEY,
    market TEXT NOT NULL,
    captured_at INTEGER NOT NULL,      -- 行情本身的时间（来自数据源）
    fetched_at INTEGER NOT NULL,       -- 我们拉取的时间
    source TEXT NOT NULL,
    etag TEXT,
    UNIQUE(market, captured_at, source)
);
CREATE TABLE IF NOT EXISTS quotes (
    snapshot_id INTEGER NOT NULL REFERENCES snapshots(id),
    item_id INTEGER NOT NULL,
    median INTEGER,                    -- 当前挂单中位价
    min_buyout INTEGER,
    quantity INTEGER,                  -- 在售总数量
    median7d INTEGER,
    median30d INTEGER,
    low INTEGER,                       -- 数据源给出的历史区间下沿
    high INTEGER,
    sold_per_day REAL,                 -- 预估日销量（估计值，不是真实成交）
    PRIMARY KEY(snapshot_id, item_id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS signals (
    id INTEGER PRIMARY KEY,
    snapshot_id INTEGER NOT NULL REFERENCES snapshots(id),
    item_id INTEGER NOT NULL,
    generated_at INTEGER NOT NULL,
    strategy TEXT NOT NULL,
    buy_price INTEGER NOT NULL,        -- 每件最高买入价
    target_price INTEGER NOT NULL,     -- 每件目标卖出价
    max_quantity INTEGER NOT NULL,
    expected_profit INTEGER NOT NULL,  -- 整笔预期净利润
    score REAL NOT NULL,
    status TEXT NOT NULL DEFAULT 'NEW',
    UNIQUE(snapshot_id, item_id, strategy)
);
CREATE TABLE IF NOT EXISTS trades (
    id INTEGER PRIMARY KEY,
    item_id INTEGER NOT NULL,
    bought_at INTEGER NOT NULL,
    sold_at INTEGER,
    quantity INTEGER NOT NULL,
    cost INTEGER NOT NULL,             -- 买入总成本
    proceeds INTEGER,                  -- 卖出到手总额（已扣抽成）
    fees INTEGER NOT NULL DEFAULT 0,   -- 押金损失等其他费用
    status TEXT NOT NULL DEFAULT 'HOLDING',   -- HOLDING / SOLD / WRITTEN_OFF
    note TEXT
);
CREATE INDEX IF NOT EXISTS idx_quotes_item ON quotes(item_id);
"""


def connect(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.executescript(SCHEMA)
    return db


def latest_snapshot(db, market):
    return db.execute(
        "SELECT * FROM snapshots WHERE market=? ORDER BY captured_at DESC LIMIT 1", (market,)
    ).fetchone()


def item_name(db, item_id):
    r = db.execute("SELECT name FROM items WHERE item_id=?", (item_id,)).fetchone()
    return (r["name"] if r and r["name"] else f"item:{item_id}")

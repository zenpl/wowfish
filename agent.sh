#!/bin/sh
# 统一的电脑端程序：钓鱼 / 分解 / 买入 / 上架 / 行情分析。一直开着，功能在游戏里开关。
exec "$(dirname "$0")/.venv/bin/python" "$(dirname "$0")/agent.py" "$@"

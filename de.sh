#!/bin/sh
# ./de.sh 50 [--key F7]  按固定次数分解；./de.sh --watch  盯着游戏里的信号，由插件按钮控制开始和停止
d="$(dirname "$0")"
if [ "$1" = "--watch" ]; then exec "$d/.venv/bin/python" "$d/de_watch.py"; fi
exec "$d/.venv/bin/python" "$d/disenchant.py" "$@"

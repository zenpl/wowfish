#!/bin/bash
# 一键启动 macOS 版钓鱼助手：从任何目录都能运行，额外参数原样传给 fisher_mac.py。
# 阈值可用环境变量覆盖：MIN_RMS=80 MAX_RMS=400 ./fish.sh
set -e
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
    echo "首次运行，创建虚拟环境并安装依赖……"
    python3 -m venv .venv
    .venv/bin/pip install -q numpy sounddevice pyobjc-framework-Quartz pyobjc-framework-Cocoa
fi

exec .venv/bin/python fisher_mac.py \
    --min-rms "${MIN_RMS:-60}" --max-rms "${MAX_RMS:-300}" "$@"

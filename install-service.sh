#!/bin/sh
# Linux：把电脑端程序装成登录后自动启动的后台服务（systemd 用户服务）。只需运行一次。
# 卸载： systemctl --user disable --now wow-agent.service && rm ~/.config/systemd/user/wow-agent.service
set -e
d="$(cd "$(dirname "$0")" && pwd)"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/wow-agent.service <<EOF
[Unit]
Description=WoW 助手电脑端程序（钓鱼 / 分解 / 买入 / 上架 / 行情分析；功能在游戏插件里开关）
After=graphical-session.target

[Service]
WorkingDirectory=$d
ExecStart=$d/agent.sh
Environment=DISPLAY=${DISPLAY:-:0}
Environment=XAUTHORITY=${XAUTHORITY:-/run/user/$(id -u)/gdm/Xauthority}
Environment=PYTHONUNBUFFERED=1
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
# 手动开着的那个先停掉，免得两个一起按键
pkill -f "$d/agent.py" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable --now wow-agent.service
sleep 3
systemctl --user --no-pager status wow-agent.service | head -8
echo
echo "已安装。以后登录桌面它会自己启动，崩了 5 秒后自己重启。"
echo "看日志： journalctl --user -u wow-agent.service -f     或  $d/logs/agent-日期.log"

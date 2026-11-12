#!/usr/bin/env bash
# 一键安装（Linux / macOS）。两种用法：
#   已经 clone 了：        ./install.sh
#   还没 clone：           curl -fsSL https://raw.githubusercontent.com/zenpl/wowfish/main/install.sh | bash
# 可选环境变量：
#   WOW_ADDONS=/path/to/Interface/AddOns   自动找不到游戏插件目录时手动指定
#   WOWFISH_DIR=~/wowfish                  用 curl 安装时 clone 到哪里（默认 ~/wowfish）
# 做的事：建 Python 虚拟环境并装依赖 → 找到游戏的插件目录并把 ForeverQuant 链接进去 → 记下本机设置 → 打印游戏内还要做的几步。
# 不会装成开机自启；Linux 上想要自启，装完后自己运行 ./install-service.sh。
set -euo pipefail

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m注意：\033[0m%s\n' "$*"; }
die()  { printf '\033[1;31m失败：\033[0m%s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=mac ;;
    *)      die "只支持 Linux 和 macOS" ;;
esac

# ---- 0. 拿到代码（curl | bash 的情况）
if [ -f "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/agent.py" ]; then
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    command -v git >/dev/null || die "需要 git"
    ROOT="${WOWFISH_DIR:-$HOME/wowfish}"
    if [ -d "$ROOT/.git" ]; then
        say "更新 $ROOT"; git -C "$ROOT" pull --ff-only
    else
        say "下载到 $ROOT"; git clone https://github.com/zenpl/wowfish.git "$ROOT"
    fi
fi
cd "$ROOT"

# ---- 1. Python（行情分析要 3.11 以上）
PY=""
for c in python3.13 python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    [ "$OS" = mac ] && die "需要 Python 3.11 以上： brew install python@3.12"
    die "需要 Python 3.11 以上（Ubuntu: sudo apt install python3 python3-venv）"
fi
say "用 $($PY --version) 建虚拟环境 .venv 并装依赖"
"$PY" -m venv .venv || die "建虚拟环境失败（Ubuntu/Debian 先装： sudo apt install python3-venv）"
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r "requirements-$OS.txt"

# ---- 2. 系统层面的前提
if [ "$OS" = linux ]; then
    command -v pw-record >/dev/null || warn "没找到 pw-record（PipeWire）。听声钓鱼需要它： sudo apt install pipewire-bin 之类"
    [ "${XDG_SESSION_TYPE:-}" = wayland ] && warn "当前是 Wayland 会话。发按键和读屏用的是 X11，Wayland 下不工作；登录时请选 Xorg 会话"
else
    if ! .venv/bin/python -c 'import sounddevice as s, sys; sys.exit(0 if any("blackhole" in d["name"].lower() for d in s.query_devices()) else 1)' 2>/dev/null; then
        warn "没找到 BlackHole 虚拟声卡（听声钓鱼需要）： brew install blackhole-2ch ，然后按 mac/README.md 第 2 步设置多输出设备"
    fi
    warn "macOS 需要给终端三个权限（系统设置 → 隐私与安全性）：辅助功能、屏幕录制、麦克风"
fi

# ---- 3. 找游戏的插件目录
find_addons() {
    local roots=() d
    if [ "$OS" = mac ]; then
        roots=("/Applications/World of Warcraft" "$HOME/Applications/World of Warcraft")
    else
        while IFS= read -r d; do roots+=("$d"); done < <(
            find "$HOME/Games" "$HOME/.wine" "$HOME/.local/share/lutris" "$HOME/.var/app" "$HOME/.steam" "$HOME/.local/share/Steam" \
                -maxdepth 9 -type d -name "World of Warcraft" 2>/dev/null)
    fi
    for d in ${roots[@]+"${roots[@]}"}; do          # 优先 _forever_，其次别的版本目录
        for flavor in _forever_ _classic_era_ _classic_ _retail_; do
            [ -d "$d/$flavor/Interface/AddOns" ] && { echo "$d/$flavor/Interface/AddOns"; return 0; }
        done
    done
    return 1
}
ADDONS="${WOW_ADDONS:-$(find_addons || true)}"
if [ -z "$ADDONS" ] || [ ! -d "$ADDONS" ]; then
    warn "没找到游戏的插件目录。找到后重新运行： WOW_ADDONS=\"/…/World of Warcraft/_forever_/Interface/AddOns\" ./install.sh"
else
    say "插件目录： $ADDONS"
    src="$ROOT/forever-quant/addon/ForeverQuant"
    [ -f "$src/Recommendations.lua" ] || cp "$src/Recommendations.default.lua" "$src/Recommendations.lua"
    dst="$ADDONS/ForeverQuant"
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        warn "$dst 已经存在而且不是链接，没有动它。要用这一份的话先把它移走再重新运行"
    else
        ln -sfn "$src" "$dst"
        say "已把插件链接到游戏： $dst"
    fi
    printf '# 本机设置，由 install.sh 生成；不进仓库\n[addon]\naddons_dir = "%s"\n' "$ADDONS" > "$ROOT/forever-quant/local.toml"
fi
mkdir -p logs forever-quant/data

cat <<EOF

$(say "装好了。")
启动电脑端程序（一直开着，功能都在游戏里开关）：
    $ROOT/agent.sh

游戏里一次性的设置：
  1. 登录角色（已在线的话重新登录一次，新插件要重登才加载），输入 /fq 打开面板
  2. 聊天框输入：/console SoftTargetInteract 3 ；按键设置里把「与目标互动」绑到 F10
  3. 钓鱼技能放到按 0 触发的动作条格子；打开自动拾取；游戏用窗口模式
  4. 打开拍卖行，点「扫描整个拍卖行」，扫完 /reload 一次，电脑端会自动出第一份分析
详细说明见 README.md。
EOF

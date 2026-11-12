# WoW 钓鱼助手 — macOS 版

> 现在推荐用仓库根目录的 `install.sh` + `agent.sh`（功能在游戏插件里开关）。这一页保留的是声卡和权限的设置步骤，
> 以及早期只会钓鱼的独立脚本 `fisher_mac.py`。两者在 macOS 上都没有实测过。

听声钓鱼：按键抛竿 → 听到咬钩水花声 → 按"与目标互动"键收竿。

> 这一版是从 Linux 版移植的，**没有在 Mac 上实测过**。阈值默认值来自 Linux 上的实测，
> Mac 上音量量纲可能不同，第一次请先跑 `--calibrate`。

## 1. 安装

```bash
brew install blackhole-2ch          # 虚拟声卡，用来"听"系统声音
python3 -m venv .venv
.venv/bin/pip install numpy sounddevice pyobjc-framework-Quartz pyobjc-framework-Cocoa
```

## 2. 让系统声音同时进 BlackHole

macOS 不能直接录系统输出，需要绕一下：

1. 打开"音频 MIDI 设置"（Audio MIDI Setup）
2. 左下角 `+` → 创建"多输出设备"
3. 勾选你的耳机/扬声器 **和** BlackHole 2ch（耳机/扬声器排在第一个）
4. 系统设置 → 声音 → 输出，选这个"多输出设备"

注意：用多输出设备时，系统音量键不能调音量，要在游戏里调。

## 3. 权限

系统设置 → 隐私与安全性：

- **辅助功能**：加入你运行脚本的终端（Terminal / iTerm），否则发不出按键
- **麦克风**：允许同一个终端，否则读不到 BlackHole 的声音

## 4. 游戏内设置（一次性）

1. 聊天框输入 `/console SoftTargetInteract 3`
2. 设置选项 → 控制 → 勾选"开启交互按键"，把"与目标互动"绑到 `F10`
3. 钓鱼技能放到按 `0` 触发的动作条格子上
4. 打开自动拾取；关掉音乐和环境音，音效开大

Mac 键盘的 F10 默认是系统功能键：要么在系统设置 → 键盘里打开"将 F1、F2 等键用作标准功能键"，
要么把互动键绑成别的键，再用 `--interact-key` 指定。

## 5. 使用

```bash
.venv/bin/python fisher_mac.py --calibrate   # 手动钓几竿，看水花声是否明显高于底噪
.venv/bin/python fisher_mac.py               # 开始，切到游戏才会动作，Ctrl+C 停止
.venv/bin/python fisher_mac.py --debug       # 漏竿时打印每秒声音峰值，用来调阈值
```

常用参数：`--cast-key`、`--interact-key`、`--minutes`、`--min-rms` / `--max-rms`（咬钩阈值范围）、
`--device`（音频设备名，默认找 BlackHole）。

## 排查

- 一直显示"魔兽不在前台"：日志里会打印当前前台应用名，把它告诉我，或改脚本顶部的 `APP_HINTS`
- `--calibrate` 里 rms 一直是 0：声音没进 BlackHole，检查第 2 步
- 按键没反应：检查辅助功能权限

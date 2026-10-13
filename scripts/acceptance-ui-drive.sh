#!/usr/bin/env bash
# 全新首启后的 UI 驱动验收（1600x900 横屏雷电坐标；其它设备需重校）
# 前置：acceptance-clean-install.sh 已到 01-boot 截图（dsh 已加载、弹窗在）
set -uo pipefail
DEV="${DEV:-emulator-5554}"
SH() { adb -s "$DEV" shell "$@"; }
SHOT() { adb -s "$DEV" exec-out screencap -p > "/d/dsh-android/TMP/${PREFIX:-final}-$1.png"; echo "  截图 ${PREFIX:-final}-$1.png"; }
TAP() { SH "input tap $1 $2"; sleep "${3:-1.2}"; }
PREFIX="${1:-final}"

echo "[A] 关 dsh 预览版说明（继续按钮）"
TAP 1113 694 2
SHOT 02-after-dsh-notice

echo "[B] 关 OFM 欢迎（稍后再说）"
TAP 1122 712 1.5
SHOT 03-after-ofm-notice

echo "[C] 浮动 + 新会话"
TAP 1526 830 2

echo "[D] 打开模型选择器 → 免费 tab → 第 4 行(MiMo V2.6)"
TAP 97 822 1.5
TAP 181 517 1.5
TAP 800 745 1.5
SHOT 04-model-selected

echo "[E] 输入 hello 并发送"
TAP 800 700 1
SH "input text 'hello'"
sleep 0.5
TAP 1526 745 12
SHOT 05-reply-streaming
sleep 15
SHOT 06-reply-done
echo "完成：核对 05/06 截图应见模型回答"

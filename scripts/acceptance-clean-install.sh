#!/usr/bin/env bash
# dsh-android 全新安装终验：卸载清数据 → 装指定 APK → 首启引导 → 轮询 dsh token 就绪
# 用法: acceptance-clean-install.sh <apk路径> [截图前缀]
# 截图输出到 TMP/，由人（或 agent）逐屏核对。
set -uo pipefail
APK="${1:?用法: $0 <apk> [prefix]}"
PREFIX="${2:-clean}"
DEV="${DEV:-emulator-5554}"
SH() { adb -s "$DEV" shell "$@"; }
SU() { adb -s "$DEV" shell "su -c '$1'"; }
SHOT() { adb -s "$DEV" exec-out screencap -p > "/d/dsh-android/TMP/${PREFIX}-$1.png"; }
TAP() { SH "input tap $1 $2"; sleep "${3:-1}"; }

echo "[1] 卸载旧版（清全部数据，模拟新用户）"
adb -s "$DEV" uninstall com.termux >/dev/null 2>&1

echo "[2] 安装 $APK"
adb -s "$DEV" install -r "$APK" | tail -1

echo "[3] 启动 DshWebActivity"
SH "am start -n com.termux/com.termux.app.dsh.DshWebActivity" >/dev/null

echo "[4] 等待首启解包 + dsh token（最多 8 分钟）"
ok=""
for i in $(seq 1 96); do
  sleep 5
  T=$(SU "grep -o 'token=.*' /data/data/com.termux/files/home/.dsh-web.log 2>/dev/null | tail -1" | tr -d '\r')
  if [ -n "$T" ]; then ok=1; echo "  token 就绪：${T:0:18}... (${i}0s 量级)"; break; fi
  [ $((i % 12)) -eq 0 ] && echo "  等待中 ($((i*5))s) $(SU 'ls /data/data/com.termux/files/usr/bin/bash 2>/dev/null' >/dev/null && echo bash已解出 || echo 解包中)"
done
[ -z "$ok" ] && { echo "FAIL: 8 分钟未见 token"; SH "dumpsys window | grep mCurrentFocus"; exit 1; }

sleep 25   # 等 WebView 加载 + 弹窗出现
SHOT "01-boot"
echo "[5] 截图完成：${PREFIX}-01-boot.png（应见 dsh 预览版说明弹窗）"
echo "    后续人工/脚本驱动：关弹窗→新会话→选免费模型→发消息→等回答"

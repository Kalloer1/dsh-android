#!/usr/bin/env bash
# dsh-android adb 验收线（在 PC Git Bash 跑，手机 USB 已连）
# 用法：ACCEPT_ADB=/d/tools/platform-tools/adb.exe bash scripts/acceptance-adb.sh /path/to/app.apk
set -uo pipefail
ADB="${ACCEPT_ADB:-adb}"
APK="${1:?用法: acceptance-adb.sh <apk路径>}"
PKG=com.termux
ACT=$PKG/.app.dsh.DshWebActivity   # com.termux/com.termux.app.dsh.DshWebActivity
S(){ echo "== $*"; }
OUT="$(dirname "$APK")/accept-$(date +%H%M%S)"; mkdir -p "$OUT"

S "0. 安装（-g 预授权）"; $ADB install -r -g "$APK" || { S "FAIL install"; exit 1; }
S "1. 清日志并启动"; $ADB logcat -c
MSYS_NO_PATHCONV=1 $ADB shell am start -n com.termux/com.termux.app.dsh.DshWebActivity || exit 1

S "2. 等首启解 bootstrap（最多 300s，每 10s 探测 3080 端口）"
ok=0
for i in $(seq 1 30); do
    sleep 10
    if MSYS_NO_PATHCONV=1 $ADB shell ss -ltn 2>/dev/null | grep -q ":3080"; then ok=1; break; fi
    S "  ${i}0s: 3080 未监听，继续等"
done
$ADB logcat -d > "$OUT/logcat.txt"
if [[ $ok -eq 1 ]]; then S "OK dsh web 已监听 127.0.0.1:3080"; else S "FAIL 300s 未监听（见 $OUT/logcat.txt）"; fi

S "3. token 与 HTTP 检查（设备侧 loopback）"
TOKENLINE=$(MSYS_NO_PATHCONV=1 $ADB shell "cat /data/data/com.termux/files/home/.dsh-web.log 2>/dev/null" | grep -o "http://127.0.0.1:3080/?token=[^ ]*" | head -1)
if [[ -n "$TOKENLINE" ]]; then S "OK token 行存在: ${TOKENLINE:0:52}..."; else S "FAIL 无 token 行"; fi
CODE=$(MSYS_NO_PATHCONV=1 $ADB shell "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/ 2>/dev/null || toybox wget -q -O - http://127.0.0.1:3080/ >/dev/null 2>&1 && echo wget-ok || echo no-http-tool")
S "无 token 访问返回: $CODE（期望 401 或工具缺失说明）"

S "4. 前台服务通知在否"; $ADB shell dumpsys notification --noredact 2>/dev/null | grep -c "dsh web" | sed 's/^/dsh web 通知计数: /'
S "5. 截图首屏"; MSYS_NO_PATHCONV=1 $ADB exec-out screencap -p > "$OUT/screen1.png"; S "  $OUT/screen1.png"
S "6. TermuxService/dsh 关键日志摘录"
grep -aE "DshWeb|dsh web|bootstrap|System error|FATAL" "$OUT/logcat.txt" | tail -25

S "7. 杀 App 重开：会话持久探针"
$ADB shell am force-stop com.termux; sleep 2
MSYS_NO_PATHCONV=1 $ADB shell am start -n com.termux/com.termux.app.dsh.DshWebActivity >/dev/null; sleep 25
MSYS_NO_PATHCONV=1 $ADB shell ss -ltn | grep -q ":3080" && S "OK 重启后服务自动拉起" || S "FAIL 重启后 3080 未监听"
MSYS_NO_PATHCONV=1 $ADB exec-out screencap -p > "$OUT/screen2.png"
S "验收数据在 $OUT"

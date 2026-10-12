#!/usr/bin/env bash
# 本地快速构建 dsh-android APK（打种 zip 从最近一次 CI run 的仓库 main.cpp 拿不了——
# zip 不发布为 artifact；因此策略：本地能全跑就跑 dpkg 步骤（需 WSL/Git Bash 无 dpkg 时
# 用 --official 模式：跳过打种，直接用官方 bootstrap，只验证 Java/Manifest/UI 改动）。
#
# 用法：
#   scripts/build-local.sh              # 官方 bootstrap 模式（快，验证 App 层改动）
#   scripts/build-local.sh --seeded     # 完整打种模式（需要 bash 里有 dpkg-deb/zip，
#                                       #   且 ANDROID_NDK_HOME 已装——Git Bash 一般不满足，用 WSL）
set -euo pipefail
export JAVA_HOME="${JAVA_HOME:-D:\\tools\\jdk17}"
export ANDROID_HOME="${ANDROID_HOME:-D:\\tools\\android-sdk}"
export PATH="/d/tools/jdk17/bin:$PATH"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "${1:-}" == "--seeded" ]]; then
    command -v dpkg-deb >/dev/null || { echo "需要 dpkg-deb（WSL 或 Termux-Linux）"; exit 1; }
    export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14206865}"
    bash scripts/seed-bootstrap.sh
    ./gradlew assembleRelease -PdshSeededBootstrap
else
    ./gradlew assembleRelease
fi
echo
echo "APK: app/build/outputs/apk/release/"
ls -la app/build/outputs/apk/release/*.apk 2>/dev/null
